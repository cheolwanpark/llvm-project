// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "VPlanBackendProbePruning.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/Transforms/Utils/Local.h"
#include "llvm/Transforms/Vectorize/VPlanBackendFeedback.h"
using namespace llvm;
// Private probe CFG reduction. See BACKEND_FEEDBACK.md.
cl::opt<bool> llvm::PruneLoopRegions(
    "vplan-backend-prune-cfg", cl::Hidden, cl::init(true),
    cl::desc(
        "Experimentally shorten probe paths exclusive of the selected loop"));
cl::opt<bool>
    llvm::PruningTrace("vplan-backend-pruning-trace", cl::Hidden,
                       cl::init(false),
                       cl::desc("Report experimental probe pruning sizes"));
cl::opt<bool> llvm::PruningDumpIR(
    "vplan-backend-pruning-dump-ir", cl::Hidden, cl::init(false),
    cl::desc("Dump experimental probe IR before/after pruning and suffix"));

// Passive diagnostics: count every instruction in the marked body, including
// nested blocks. Zero means no unique marked loop.
ProbeIRSize llvm::getProbeIRSize(Function &F, FunctionAnalysisManager &FAM) {
  ProbeIRSize Size{F.getInstructionCount(), unsigned(F.size()), 0, 0};
  auto [Selected, Reason] =
      findVPlanBackendObservedLoop(F, FAM.getResult<LoopAnalysis>(F));
  if (Selected)
    for (BasicBlock *BB : Selected->blocks()) {
      Size.LoopInstructions += BB->size();
      ++Size.LoopBlocks;
    }
  return Size;
}

// A large function can retain a syntactically present but infeasible loop that
// the suffix eliminates after region reduction. Preserve the original probe
// for that case rather than changing the existing mapping/failure policy.
// Recognize only exact, invertible integer switch selectors and direct ICmps;
// this is not a replacement for general path-sensitive constant propagation.
static bool
hasInfeasibleSwitchGuard(Loop &Selected, DominatorTree &DT, LoopInfo &LI,
                         const SmallPtrSetImpl<BasicBlock *> &Ancestors) {
  for (BasicBlock *BB : Ancestors) {
    auto *SI = dyn_cast<SwitchInst>(BB->getTerminator());
    if (!SI || LI.getLoopFor(BB) || !DT.dominates(BB, Selected.getHeader()) ||
        Ancestors.contains(SI->getDefaultDest()))
      continue;
    SmallVector<std::pair<Value *, APInt>> Facts;
    for (auto Case : SI->cases()) {
      if (!Ancestors.contains(Case.getCaseSuccessor()))
        continue;
      Value *Root = SI->getCondition();
      APInt Known = Case.getCaseValue()->getValue();
      while (true) {
        if (auto *BO = dyn_cast<BinaryOperator>(Root)) {
          auto *C0 = dyn_cast<ConstantInt>(BO->getOperand(0));
          auto *C1 = dyn_cast<ConstantInt>(BO->getOperand(1));
          if (BO->getOpcode() == Instruction::Add && (C0 || C1))
            Known -= (C0 ? C0 : C1)->getValue();
          else if (BO->getOpcode() == Instruction::Xor && (C0 || C1))
            Known ^= (C0 ? C0 : C1)->getValue();
          else if (BO->getOpcode() == Instruction::Sub && C1)
            Known += C1->getValue();
          else if (BO->getOpcode() == Instruction::Sub && C0)
            Known = C0->getValue() - Known;
          else
            break;
          Root = BO->getOperand(C0 ? 1 : 0);
          continue;
        }
        auto *II = dyn_cast<IntrinsicInst>(Root);
        if (!II ||
            (II->getIntrinsicID() != Intrinsic::fshl &&
             II->getIntrinsicID() != Intrinsic::fshr) ||
            II->getArgOperand(0) != II->getArgOperand(1))
          break;
        auto *Amount = dyn_cast<ConstantInt>(II->getArgOperand(2));
        if (!Amount)
          break;
        unsigned N = Amount->getValue().urem(Known.getBitWidth());
        Known = II->getIntrinsicID() == Intrinsic::fshl ? Known.rotr(N)
                                                        : Known.rotl(N);
        Root = II->getArgOperand(0);
      }
      Facts.emplace_back(Root, std::move(Known));
    }
    if (Facts.empty())
      continue;
    for (BasicBlock *Guard : Ancestors) {
      auto *BI = dyn_cast<CondBrInst>(Guard->getTerminator());
      if (!BI || LI.getLoopFor(Guard) || !DT.dominates(BB, Guard) ||
          !DT.dominates(Guard, Selected.getHeader()))
        continue;
      auto *Cmp = dyn_cast<ICmpInst>(BI->getCondition());
      if (!Cmp)
        continue;
      bool Impossible = all_of(Facts, [&](const auto &Fact) {
        auto Operand = [&](Value *V) -> const APInt * {
          if (V == Fact.first)
            return &Fact.second;
          if (auto *C = dyn_cast<ConstantInt>(V))
            return &C->getValue();
          return nullptr;
        };
        const APInt *A = Operand(Cmp->getOperand(0));
        const APInt *B = Operand(Cmp->getOperand(1));
        if (!A || !B)
          return false;
        bool Taken = ICmpInst::compare(*A, *B, Cmp->getPredicate());
        return !Ancestors.contains(BI->getSuccessor(Taken ? 0 : 1));
      });
      if (Impossible)
        return true;
    }
  }
  return false;
}

/// Preserve every path through the observed loop, including its consumers.
/// Only paths that cannot execute that loop may return early, using the
/// function's existing return value. This remains an empirical experiment:
/// shortening alternative paths can change global register allocation.
PruningResult llvm::pruneLoopRegions(Function &F,
                                     FunctionAnalysisManager &FAM) {
  auto &LI = FAM.getResult<LoopAnalysis>(F);
  auto &DT = FAM.getResult<DominatorTreeAnalysis>(F);
  auto [Selected, Reason] = findVPlanBackendObservedLoop(F, LI);
  if (!Selected)
    return {0, Reason};
  auto HasVectorRepresentation = [](Type *Ty) {
    return Ty->isVectorTy() || Ty->isAggregateType() || Ty->isTargetExtTy();
  };
  if (HasVectorRepresentation(F.getReturnType()) ||
      any_of(F.args(), [&](const Argument &A) {
        return HasVectorRepresentation(A.getType());
      }))
    return {0, "vector-region-abi"};
  for (BasicBlock *BB : Selected->blocks())
    for (Instruction &I : *BB)
      if (HasVectorRepresentation(I.getType()))
        for (User *U : I.users())
          if (auto *Use = dyn_cast<Instruction>(U))
            if (!Selected->contains(Use))
              return {0, "vector-region-live-out"};
  ReturnInst *Return = nullptr;
  unsigned ReturnCount = 0;
  for (BasicBlock &BB : F) {
    if (BB.hasAddressTaken() || BB.isEHPad() ||
        isa<InvokeInst, CallBrInst, IndirectBrInst>(BB.getTerminator()))
      return {0, "unsupported-region-control"};
    if (auto *RI = dyn_cast<ReturnInst>(BB.getTerminator())) {
      if (Return && Return->getReturnValue() != RI->getReturnValue())
        return {0, "different-return-values"};
      Return = RI;
      ++ReturnCount;
    }
  }
  if (!Return)
    return {0, "no-existing-return"};
  Value *ReturnValue = Return->getReturnValue();
  auto *ReturnDef = dyn_cast_or_null<Instruction>(ReturnValue);
  // A canonical return PHI can name an exact existing return value even where
  // the PHI itself does not dominate. Propagate outcomes backward, merging
  // differing/unknown values to nullptr. This never invents a loop input or
  // selects one of several possible return values on an excluded path.
  DenseMap<BasicBlock *, Value *> ReturnOutcomes;
  bool HasReturnOutcomes = false;
  if (auto *Phi = dyn_cast_or_null<PHINode>(ReturnDef)) {
    if (ReturnCount == 1 && Phi->getParent() == Return->getParent()) {
      HasReturnOutcomes = true;
      SmallVector<BasicBlock *> Pending;
      auto Merge = [&](BasicBlock *BB, Value *V) {
        auto [It, Inserted] = ReturnOutcomes.try_emplace(BB, V);
        if (Inserted) {
          Pending.push_back(BB);
        } else if (It->second && It->second != V) {
          It->second = nullptr;
          Pending.push_back(BB);
        }
      };
      for (unsigned N = 0; N != Phi->getNumIncomingValues(); ++N) {
        Value *V = Phi->getIncomingValue(N);
        if (!isa<Constant, Argument>(V) || isa<UndefValue, PoisonValue>(V))
          V = nullptr;
        Merge(Phi->getIncomingBlock(N), V);
      }
      for (BasicBlock &BB : F)
        if (isa<UnreachableInst>(BB.getTerminator()))
          Merge(&BB, nullptr);
      while (!Pending.empty()) {
        BasicBlock *BB = Pending.pop_back_val();
        Value *V = ReturnOutcomes.lookup(BB);
        for (BasicBlock *Pred : predecessors(BB))
          Merge(Pred, V);
      }
    }
  }
  // Compute each closure from the observed header alone. Closing predecessors
  // of descendants would pull mutually exclusive paths through a shared exit
  // back into the region. Return preservation below adds no traversal seeds.
  auto Reachable = [&](bool Forward) {
    SmallPtrSet<BasicBlock *, 32> Seen;
    SmallVector<BasicBlock *> Pending{Selected->getHeader()};
    Seen.insert(Selected->getHeader());
    while (!Pending.empty()) {
      BasicBlock *BB = Pending.pop_back_val();
      auto Visit = [&](BasicBlock *Next) {
        if (Seen.insert(Next).second)
          Pending.push_back(Next);
      };
      if (Forward)
        for (BasicBlock *Succ : successors(BB))
          Visit(Succ);
      else
        for (BasicBlock *Pred : predecessors(BB))
          Visit(Pred);
    }
    return Seen;
  };
  auto DescendantsSeen = Reachable(true);
  auto AncestorsSeen = Reachable(false);
  SmallPtrSet<BasicBlock *, 32> Keep(DescendantsSeen.begin(),
                                     DescendantsSeen.end());
  Keep.insert(AncestorsSeen.begin(), AncestorsSeen.end());
  if (hasInfeasibleSwitchGuard(*Selected, DT, LI, AncestorsSeen))
    return {0, "infeasible-switch-guard"};
  // Do not replace non-returning paths or create a new return operand.
  for (BasicBlock &BB : F)
    if (isa<UnreachableInst>(BB.getTerminator()) ||
        (HasReturnOutcomes
             ? !ReturnOutcomes.lookup(&BB)
             : ReturnDef && (ReturnDef->getParent() == &BB ||
                             !DT.dominates(ReturnDef->getParent(), &BB))))
      Keep.insert(&BB);
  // Keep real inputs on every retained edge. PHI inputs on a removed edge
  // disappear with that edge; never substitute a value for a retained use.
  auto HasRetainedDefinition = [&](Value *V) {
    auto *Def = dyn_cast<Instruction>(V);
    return !Def || Keep.contains(Def->getParent());
  };
  for (BasicBlock *BB : Keep)
    for (Instruction &I : *BB) {
      if (auto *Phi = dyn_cast<PHINode>(&I)) {
        for (unsigned N = 0; N != Phi->getNumIncomingValues(); ++N)
          if (Keep.contains(Phi->getIncomingBlock(N)) &&
              !HasRetainedDefinition(Phi->getIncomingValue(N)))
            return {0, "retained-phi-input-outside-region"};
      } else if (!all_of(I.operands(), HasRetainedDefinition)) {
        return {0, "retained-input-outside-region"};
      }
    }
  for (BasicBlock *BB : Keep) {
    if (Selected->contains(BB) || !AncestorsSeen.contains(BB))
      continue;
    bool InCycle = DescendantsSeen.contains(BB);
    for (Instruction &I : *BB) {
      bool VectorResult = HasVectorRepresentation(I.getType());
      // Independent vector lifetimes may precede or follow the loop, but a
      // surrounding cycle or a vector value crossing it prevents pruning.
      if (InCycle && (VectorResult || any_of(I.operands(), [&](const Value *V) {
                        return HasVectorRepresentation(V->getType());
                      })))
        return {0, "cyclic-vector-context"};
      if (!VectorResult)
        continue;
      for (User *U : I.users())
        if (auto *Use = dyn_cast<Instruction>(U))
          if (!Selected->contains(Use) &&
              DescendantsSeen.contains(Use->getParent()))
            return {0, "vector-live-through-context"};
    }
  }
  SmallVector<BasicBlock *> Drop;
  for (BasicBlock &BB : F)
    if (!Keep.contains(&BB))
      Drop.push_back(&BB);
  if (Drop.empty())
    return {0, "no-exclusive-region"};
  if (none_of(Drop, [](BasicBlock *BB) { return BB->size() > 1; }))
    return {0, "no-exclusive-instructions"};
  // The checks above guarantee that only PHI inputs on removed edges need a
  // definition in Drop. Determine the entire region before changing anything.
  unsigned Before = F.getInstructionCount();
  for (BasicBlock *BB : Drop) {
    for (BasicBlock *Succ : successors(BB))
      Succ->removePredecessor(BB, /*KeepOneInputPHIs=*/true);
  }
  for (BasicBlock *BB : Drop)
    for (Instruction &I : *BB)
      I.dropAllReferences();
  for (BasicBlock *BB : Drop) {
    while (!BB->empty())
      BB->back().eraseFromParent();
    ReturnInst::Create(
        F.getContext(),
        HasReturnOutcomes ? ReturnOutcomes.lookup(BB) : ReturnValue, BB);
  }
  removeUnreachableBlocks(F);
  return {Before - F.getInstructionCount(), "existing-return-regions"};
}
