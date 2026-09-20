//===- ReductionFission.cpp - Experimental LV distribution
//-----------------===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "ReductionFission.h"
#include "llvm/ADT/FloatingPointMode.h"
#include "llvm/Analysis/AliasAnalysis.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/MemoryBuiltins.h"
#include "llvm/Analysis/OptimizationRemarkEmitter.h"
#include "llvm/Analysis/PostDominators.h"
#include "llvm/Analysis/ScalarEvolutionExpressions.h"
#include "llvm/Analysis/TargetLibraryInfo.h"
#include "llvm/Analysis/TargetTransformInfo.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/MDBuilder.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/KnownFPClass.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/TargetParser/Triple.h"
#include "llvm/Transforms/Utils/BuildLibCalls.h"
#include "llvm/Transforms/Utils/LoopUtils.h"
#include "llvm/Transforms/Utils/ScalarEvolutionExpander.h"
#include "llvm/Transforms/Utils/ValueMapper.h"
#include "llvm/Transforms/Vectorize/LoopVectorizationLegality.h"

using namespace llvm;

static cl::opt<unsigned> StackBudget(
    "reduction-fission-stack-budget", cl::Hidden, cl::init(16384),
    cl::desc("Maximum aggregate static alloca bytes in a function when placing "
             "reduction fission scratch on the stack (0 disables)"));

static Type *getBufferType(Value *V) {
  // A scalar i1 occupies a byte, unlike packed vector masks.
  return V->getType()->isIntegerTy(1) ? Type::getInt8Ty(V->getContext())
                                      : V->getType();
}

// This bounds IR storage, not the final frame (which may also contain spills).
// Reject unknown existing stack use, and charge all allocations, including
// scratch for previously transformed loops. No dynamic alloca is introduced.
static bool fitsOnStack(Function &F, ArrayRef<Value *> Inputs,
                        const SCEV *BackedgeCount) {
  if (!StackBudget || F.hasFnAttribute(Attribute::Naked))
    return false;
  const auto *BTC = dyn_cast<SCEVConstant>(BackedgeCount);
  if (!BTC)
    return false;
  const DataLayout &DL = F.getDataLayout();
  APInt Count = BTC->getAPInt().zextOrTrunc(DL.getPointerSizeInBits());
  bool Overflow;
  Count = Count.uadd_ov(APInt(Count.getBitWidth(), 1), Overflow);
  if (Overflow || Count.ugt(StackBudget))
    return false;

  uint64_t Used = 0;
  auto Charge = [&](uint64_t Size, Align Alignment) {
    if (Size > StackBudget || Alignment.value() > StackBudget)
      return false;
    uint64_t Padded = alignTo(Size, Alignment);
    if (Padded > StackBudget - Used)
      return false;
    Used += Padded;
    return true;
  };
  for (Instruction &I : instructions(F))
    if (auto *AI = dyn_cast<AllocaInst>(&I)) {
      auto Size = AI->getAllocationSize(DL);
      if (!AI->isStaticAlloca() || !Size || Size->isScalable() ||
          !Charge(Size->getFixedValue(), AI->getAlign()))
        return false;
    }
  for (Value *V : Inputs) {
    Type *Ty = getBufferType(V);
    uint64_t ElementSize = DL.getTypeAllocSize(Ty).getFixedValue();
    if (ElementSize > StackBudget / Count.getZExtValue() ||
        !Charge(ElementSize * Count.getZExtValue(), DL.getPrefTypeAlign(Ty)))
      return false;
  }
  return true;
}

// Vectorization may preserve a finite-distance memory recurrence at a small VF.
// Full fission's policy is stricter: no such recurrence may remain in Map.
// Find cycles in SSA plus memory value flow, rather than rejecting ordinary
// loop-independent, anti-, or acyclic flow dependences.
static StringRef checkMapMemoryRecurrences(Loop *L, const LoopAccessInfo &LAI,
                                           ScalarEvolution &SE) {
  const MemoryDepChecker &DC = LAI.getDepChecker();
  const auto *Deps = DC.getDependences();
  if (!Deps)
    return "memory dependence information is incomplete for Map recurrence "
           "analysis";
  DenseMap<Instruction *, SmallVector<Instruction *, 2>> Flow;
  SmallVector<std::pair<Instruction *, Instruction *>> Carried;
  bool HasUnknownFlow = false;
  for (const auto &Dep : *Deps) {
    Instruction *Src = Dep.getSource(DC);
    Instruction *Dst = Dep.getDestination(DC);
    if (Dep.isForward() && isa<StoreInst>(Src) && isa<LoadInst>(Dst))
      Flow[Src].push_back(Dst);
    else if (Dep.isBackward() && isa<LoadInst>(Src) && isa<StoreInst>(Dst)) {
      Flow[Dst].push_back(Src);
      Carried.emplace_back(Dst, Src);
    } else if (Dep.Type == MemoryDepChecker::Dependence::Unknown) {
      // Runtime checks can eliminate a dependence on the vector path, but the
      // scalar Map path must not retain a possible recurrence either.
      if (isa<LoadInst>(Src) && isa<StoreInst>(Dst))
        std::swap(Src, Dst);
      if (isa<StoreInst>(Src) && isa<LoadInst>(Dst)) {
        Flow[Src].push_back(Dst);
        Carried.emplace_back(Src, Dst);
        HasUnknownFlow = true;
      }
    }
  }

  // LAA may omit locally safe same-address forward dependences. They can still
  // connect a cycle containing another, loop-carried memory flow edge.
  const auto &Memory = DC.getMemoryInstructions();
  for (unsigned I = 0; I < Memory.size(); ++I) {
    auto *Store = dyn_cast<StoreInst>(Memory[I]);
    if (!Store)
      continue;
    for (unsigned J = I + 1; J < Memory.size(); ++J)
      if (auto *Load = dyn_cast<LoadInst>(Memory[J]);
          Load && SE.getSCEV(Store->getPointerOperand()) ==
                      SE.getSCEV(Load->getPointerOperand()))
        Flow[Store].push_back(Load);
  }

  // A retry using runtime checks clears LAA's recorded dependences. Include
  // those unresolved flows too: checks do not rule out a recurrence on the
  // scalar Map path. Acyclic uncertain aliasing remains eligible.
  const RuntimePointerChecking *Checks = LAI.getRuntimePointerChecking();
  auto AddPotentialFlow = [&](Value *StorePtr, Value *LoadPtr) {
    for (Instruction *Store : DC.getInstructionsForAccess(StorePtr, true))
      for (Instruction *Load : DC.getInstructionsForAccess(LoadPtr, false)) {
        Flow[Store].push_back(Load);
        Carried.emplace_back(Store, Load);
        HasUnknownFlow = true;
      }
  };
  for (unsigned I = 0; I < Checks->Pointers.size(); ++I)
    for (unsigned J = I + 1; J < Checks->Pointers.size(); ++J)
      if (Checks->needsChecking(I, J)) {
        AddPotentialFlow(Checks->Pointers[I].PointerValue,
                         Checks->Pointers[J].PointerValue);
        AddPotentialFlow(Checks->Pointers[J].PointerValue,
                         Checks->Pointers[I].PointerValue);
      }
  if (Carried.empty())
    return {};

  // A stored value can depend on a load through control as well as SSA: a
  // conditional store changes future state, and a join PHI chooses its value.
  // Do not connect a branch to unrelated instructions after its postdominator.
  PostDominatorTree PDT(*L->getHeader()->getParent());
  for (BasicBlock *BB : L->blocks()) {
    auto *Branch = dyn_cast<BranchInst>(BB->getTerminator());
    if (BB == L->getLoopLatch() || !Branch || !Branch->isConditional())
      continue;
    auto *Node = PDT.getNode(BB);
    BasicBlock *Join =
        Node && Node->getIDom() ? Node->getIDom()->getBlock() : nullptr;
    SmallVector<BasicBlock *> Work{Branch->getSuccessor(0),
                                   Branch->getSuccessor(1)};
    SmallPtrSet<BasicBlock *, 16> Seen;
    while (!Work.empty()) {
      BasicBlock *Controlled = Work.pop_back_val();
      if (Controlled == Join || Controlled == L->getHeader() ||
          !L->contains(Controlled) || !Seen.insert(Controlled).second)
        continue;
      for (Instruction &I : *Controlled)
        Flow[Branch].push_back(&I);
      if (Controlled != L->getLoopLatch())
        append_range(Work, successors(Controlled));
    }
    if (Join && L->contains(Join))
      for (PHINode &Phi : Join->phis())
        if (!Phi.hasConstantValue())
          Flow[Branch].push_back(&Phi);
  }

  for (auto [Store, Load] : Carried) {
    SmallVector<Instruction *> Work{Load};
    SmallPtrSet<Instruction *, 32> Seen;
    while (!Work.empty()) {
      Instruction *I = Work.pop_back_val();
      if (I == Store)
        return HasUnknownFlow
                   ? "cannot exclude a loop-carried memory recurrence in Map"
                   : "true loop-carried memory recurrence would remain in Map";
      if (!Seen.insert(I).second)
        continue;
      for (User *U : I->users())
        if (auto *UseI = dyn_cast<Instruction>(U); UseI && L->contains(UseI))
          Work.push_back(UseI);
      if (auto It = Flow.find(I); It != Flow.end())
        append_range(Work, It->second);
    }
  }
  return {};
}

void ReductionFission::planContribution(Reduction &R) {
  // Combining existing output streams would add an owned full-trip buffer.
  // Prefer their zero-scratch representation; each accumulator still gets its
  // own reducer. This is a storage-driven multi-input fallback, not fusion.
  bool HasProduct = any_of(R.Slice, [](Instruction *I) {
    auto *II = dyn_cast<IntrinsicInst>(I);
    return II && II->getIntrinsicID() == Intrinsic::fmuladd;
  });
  // Raw multiplicands are not contribution streams: the independent product
  // of an fmuladd still belongs in Map, even if its factors could be reloaded.
  if (!HasProduct && !R.Inputs.empty() &&
      all_of(R.Inputs, [&](Value *V) { return Streams.contains(V); })) {
    R.ContributionReason = "existing streams avoid owned scratch";
    return;
  }
  unsigned Opcode;
  Intrinsic::ID CombineIntrinsic = Intrinsic::not_intrinsic;
  switch (R.Descriptor.getRecurrenceKind()) {
  case RecurKind::Add:
    Opcode = Instruction::Add;
    break;
  case RecurKind::Mul:
    Opcode = Instruction::Mul;
    break;
  case RecurKind::And:
    Opcode = Instruction::And;
    break;
  case RecurKind::Or:
    Opcode = Instruction::Or;
    break;
  case RecurKind::Xor:
    Opcode = Instruction::Xor;
    break;
  case RecurKind::FAdd:
  case RecurKind::FMulAdd:
    Opcode = Instruction::FAdd;
    break;
  case RecurKind::FMul:
    Opcode = Instruction::FMul;
    break;
  case RecurKind::SMin:
    Opcode = Instruction::Call;
    CombineIntrinsic = Intrinsic::smin;
    break;
  case RecurKind::SMax:
    Opcode = Instruction::Call;
    CombineIntrinsic = Intrinsic::smax;
    break;
  case RecurKind::UMin:
    Opcode = Instruction::Call;
    CombineIntrinsic = Intrinsic::umin;
    break;
  case RecurKind::UMax:
    Opcode = Instruction::Call;
    CombineIntrinsic = Intrinsic::umax;
    break;
  case RecurKind::FMin:
    Opcode = Instruction::Call;
    CombineIntrinsic = Intrinsic::minnum;
    break;
  case RecurKind::FMax:
    Opcode = Instruction::Call;
    CombineIntrinsic = Intrinsic::maxnum;
    break;
  case RecurKind::FMinimum:
    Opcode = Instruction::Call;
    CombineIntrinsic = Intrinsic::minimum;
    break;
  case RecurKind::FMaximum:
    Opcode = Instruction::Call;
    CombineIntrinsic = Intrinsic::maximum;
    break;
  default:
    R.ContributionReason = "recurrence is not a homogeneous binary combine";
    return;
  }

  SmallVector<Instruction *, 4> Chain;
  FastMathFlags FMF = FastMathFlags::getFast();
  bool Invariant = true;
  Value *Current = R.Descriptor.getLoopExitInstr();
  Instruction *Guard = nullptr;
  // A skipped update contributes the combine identity. The contribution is
  // selected at the original join; its loads and arithmetic stay on their
  // original paths. More complicated dependent PHIs keep the slice fallback.
  if (auto *P = dyn_cast<PHINode>(Current)) {
    R.ContributionReason = "join is not a single optionally executed chain";
    if (P->getNumIncomingValues() != 2)
      return;
    if (P->getIncomingValue(0) == R.Phi)
      Current = P->getIncomingValue(1);
    else if (P->getIncomingValue(1) == R.Phi)
      Current = P->getIncomingValue(0);
    else
      return;
    Guard = P;
  } else if (auto *S = dyn_cast<SelectInst>(Current)) {
    R.ContributionReason = "select is not a single optionally executed chain";
    if (S->getTrueValue() == R.Phi)
      Current = S->getFalseValue();
    else if (S->getFalseValue() == R.Phi)
      Current = S->getTrueValue();
    else
      return;
    Guard = S;
  }
  while (Current != R.Phi) {
    R.ContributionReason = "dependent slice changes type or has an inner join";
    auto *I = dyn_cast<Instruction>(Current);
    if (!I || !R.Slice.contains(I) || I->getType() != R.Phi->getType())
      return;
    if (isa<FPMathOperator>(I)) {
      R.ContributionReason = "an FP operation lacks reassociation permission";
      if (!CombineIntrinsic && !I->hasAllowReassoc())
        return;
      FMF &= I->getFastMathFlags();
    }
    auto IsDependent = [&](Value *V) {
      auto *Def = dyn_cast<Instruction>(V);
      return Def && R.Slice.contains(Def);
    };
    if (auto *II = dyn_cast<IntrinsicInst>(I);
        II && II->getIntrinsicID() == Intrinsic::fmuladd &&
        Opcode == Instruction::FAdd) {
      // fmuladd permits separately rounded multiplication and addition. fma
      // does not, and is deliberately not accepted here.
      R.ContributionReason = "multiply-add product depends on the accumulator";
      if (IsDependent(II->getArgOperand(0)) ||
          IsDependent(II->getArgOperand(1)) ||
          !IsDependent(II->getArgOperand(2)))
        return;
      Invariant &= L->isLoopInvariant(II->getArgOperand(0)) &&
                   L->isLoopInvariant(II->getArgOperand(1));
      Current = II->getArgOperand(2);
    } else if (CombineIntrinsic) {
      auto *II = dyn_cast<IntrinsicInst>(I);
      R.ContributionReason =
          "dependent min/max is not a homogeneous intrinsic chain";
      if (!II || II->getIntrinsicID() != CombineIntrinsic)
        return;
      bool Left = IsDependent(II->getArgOperand(0));
      bool Right = IsDependent(II->getArgOperand(1));
      if (Left == Right)
        return;
      Invariant &= L->isLoopInvariant(II->getArgOperand(Left ? 1 : 0));
      Current = II->getArgOperand(Left ? 0 : 1);
    } else {
      R.ContributionReason = "dependent slice mixes combine operations";
      auto *BO = dyn_cast<BinaryOperator>(I);
      if (!BO || BO->getOpcode() != Opcode)
        return;
      bool Left = IsDependent(BO->getOperand(0));
      bool Right = IsDependent(BO->getOperand(1));
      R.ContributionReason = "combine does not contain the accumulator once";
      if (Left == Right)
        return;
      Invariant &= L->isLoopInvariant(BO->getOperand(Left ? 1 : 0));
      Current = BO->getOperand(Left ? 0 : 1);
    }
    Chain.push_back(I);
  }
  R.ContributionReason = "dependent instructions remain outside the chain";
  if (Chain.empty() ||
      Chain.size() + 1 + unsigned(Guard != nullptr) != R.Slice.size())
    return;
  if ((CombineIntrinsic == Intrinsic::minnum ||
       CombineIntrinsic == Intrinsic::maxnum) &&
      (!FMF.noNaNs() || !FMF.noSignedZeros())) {
    R.ContributionReason = "minnum/maxnum reassociation requires nnan and nsz";
    return;
  }
  // An ordinary single combine already has a minimal contribution. Keeping
  // it unchanged also retains opportunities to reuse a narrower input stream.
  if (!Guard && L->getNumBlocks() == 1 && Chain.size() == 1 &&
      (isa<BinaryOperator>(Chain.front()) || CombineIntrinsic)) {
    R.ContributionReason = "already a single scalar contribution";
    return;
  }
  R.ContributionReason = Guard ? "conditional scalar contribution with identity"
                               : "homogeneous associative scalar contribution";
  R.CombineOpcode = Opcode;
  R.CombineIntrinsic = CombineIntrinsic;
  R.ContributionChain.assign(Chain.rbegin(), Chain.rend());
  R.ContributionFMF = FMF;
  // Unlike rewrite permissions, nnan/ninf do not follow from intersecting the
  // original flags. For example, summing contributions can overflow even when
  // their original updates, interleaved with the accumulator, stayed finite.
  if (!CombineIntrinsic) {
    R.ContributionFMF.setNoNaNs(false);
    R.ContributionFMF.setNoInfs(false);
  }
  if (Guard && !CombineIntrinsic) {
    // The original operation's flags impose no constraints on an accumulator
    // when its update is skipped. Preserve special initial values there.
    R.ContributionFMF.setNoSignedZeros(false);
  }
  R.ContributionGuard = Guard;
  R.ContributionInvariant = Invariant && !Guard;
  R.Inputs.clear();
  // Use the update only as a typed storage-plan key during read-only analysis.
  // execute() replaces it with the accumulator-independent contribution.
  R.Inputs.insert(R.Descriptor.getLoopExitInstr());
}

bool ReductionFission::sameContribution(const Reduction &A,
                                        const Reduction &B) {
  if (!A.CombineOpcode || A.CombineOpcode != B.CombineOpcode ||
      A.CombineIntrinsic != B.CombineIntrinsic ||
      A.Phi->getType() != B.Phi->getType() ||
      A.ContributionFMF != B.ContributionFMF ||
      A.ContributionChain.size() != B.ContributionChain.size())
    return false;
  if (A.ContributionGuard || B.ContributionGuard) {
    if (auto *AP = dyn_cast_or_null<PHINode>(A.ContributionGuard)) {
      auto *BP = dyn_cast_or_null<PHINode>(B.ContributionGuard);
      if (!BP)
        return false;
      for (unsigned I = 0; I != 2; ++I) {
        int J = BP->getBasicBlockIndex(AP->getIncomingBlock(I));
        if (J < 0 || (AP->getIncomingValue(I) == A.Phi) !=
                         (BP->getIncomingValue(J) == B.Phi))
          return false;
      }
    } else {
      auto *AS = dyn_cast_or_null<SelectInst>(A.ContributionGuard);
      auto *BS = dyn_cast_or_null<SelectInst>(B.ContributionGuard);
      if (!AS || !BS || AS->getCondition() != BS->getCondition() ||
          (AS->getTrueValue() == A.Phi) != (BS->getTrueValue() == B.Phi))
        return false;
    }
  }
  auto SameTerm = [&](Instruction *AI, Instruction *BI) {
    auto *AC = dyn_cast<IntrinsicInst>(AI);
    auto *BC = dyn_cast<IntrinsicInst>(BI);
    if ((AC && AC->getIntrinsicID() == Intrinsic::fmuladd) ||
        (BC && BC->getIntrinsicID() == Intrinsic::fmuladd))
      return AC && BC &&
             ((AC->getArgOperand(0) == BC->getArgOperand(0) &&
               AC->getArgOperand(1) == BC->getArgOperand(1)) ||
              (AC->getArgOperand(0) == BC->getArgOperand(1) &&
               AC->getArgOperand(1) == BC->getArgOperand(0)));
    auto Term = [](Instruction *I, const Reduction &R) {
      auto *Left = dyn_cast<Instruction>(I->getOperand(0));
      return I->getOperand(Left && R.Slice.contains(Left) ? 1 : 0);
    };
    return Term(AI, A) == Term(BI, B);
  };
  // All accepted combines are associative and commutative (with the checked
  // FP permissions). Compare multisets so operand order does not duplicate
  // storage; retain multiplicity, e.g. x+x must not share storage with x+y.
  SmallVector<Instruction *, 4> Unmatched(B.ContributionChain);
  for (Instruction *AI : A.ContributionChain) {
    auto It =
        find_if(Unmatched, [&](Instruction *BI) { return SameTerm(AI, BI); });
    if (It == Unmatched.end())
      return false;
    Unmatched.erase(It);
  }
  return true;
}

SmallVector<ElementCount, 8>
ReductionFission::getLegalVFs(const Reduction &R,
                              const TargetTransformInfo &TTI) const {
  SmallVector<ElementCount, 8> Choices;
  bool Scalable =
      Triple(L->getHeader()->getModule()->getTargetTriple()).isRISCV();
  for (unsigned N = 1; N <= VectorizerParams::MaxVectorWidth; N *= 2) {
    ElementCount VF = ElementCount::get(N, Scalable);
    if (VF.isScalar())
      continue;
    auto TypeLegal = [&](Type *Ty) {
      return Ty->isVoidTy() || (VectorType::isValidElementType(Ty) &&
                                TTI.isTypeLegal(VectorType::get(Ty, VF)));
    };
    // Check logical contribution and recurrence types. Narrow storage encodings
    // are extending loads, whose operation legality is checked separately; a
    // subregister memory type need not itself occupy a native vector register.
    bool TypesLegal =
        TypeLegal(R.Phi->getType()) &&
        all_of(R.Inputs, [&](Value *V) { return TypeLegal(V->getType()); }) &&
        (R.CombineOpcode || all_of(R.Slice, [&](Instruction *I) {
           return TypeLegal(I->getType());
         }));
    if (TypesLegal && TTI.isLegalToVectorizeReduction(R.Descriptor, VF))
      Choices.push_back(VF);
  }
  return Choices;
}

bool ReductionFission::analyze(LoopVectorizationLegality &Legal,
                               ScalarEvolution &SE, DominatorTree &DT,
                               const TargetTransformInfo &TTI, AAResults &AA,
                               const TargetLibraryInfo &TLI) {
  auto Reject = [&](StringRef Reason) {
    Failure = Reason.str();
    return false;
  };
  if (Legal.getReductionVars().empty())
    return Reject("no recognized reduction");
  if (!L->isLoopSimplifyForm() || !L->getUniqueExitBlock() ||
      L->getExitingBlock() != L->getLoopLatch())
    return Reject("requires a countable loop with a unique latch exit");
  for (BasicBlock *BB : L->blocks())
    if (!isa<BranchInst>(BB->getTerminator()))
      return Reject("unsupported non-branch control flow");
  for (PHINode &P : L->getHeader()->phis())
    if (!Legal.getReductionVars().count(&P) &&
        !Legal.getInductionVars().count(&P))
      return Reject("true loop-carried recurrence would remain in Map");
  if (StringRef Reason = checkMapMemoryRecurrences(L, *Legal.getLAI(), SE);
      !Reason.empty())
    return Reject(Reason);
  BackedgeCount = SE.getBackedgeTakenCount(L);
  if (isa<SCEVCouldNotCompute>(BackedgeCount) ||
      !BackedgeCount->getType()->isIntegerTy())
    return Reject("exact runtime trip count is not computable");
  const DataLayout &DL = L->getHeader()->getModule()->getDataLayout();
  if (BackedgeCount->getType()->getIntegerBitWidth() >
      DL.getPointerSizeInBits())
    return Reject("trip count is wider than the buffer address space");
  SCEVExpander Exp(SE, "fission");
  if (!Exp.isSafeToExpandAt(BackedgeCount,
                            L->getLoopPreheader()->getTerminator()))
    return Reject("trip count cannot be safely materialized at loop entry");

  DenseMap<Instruction *, PHINode *> Owner;
  for (auto &[Phi, Desc] : Legal.getReductionVars()) {
    if (Desc.isOrdered())
      return Reject("ordered reduction cannot use a vector accumulator and "
                    "final collapse");
    Reduction R{Phi, Desc, {}, {}};
    R.Slice.insert(Phi);
    for (unsigned I = 0; I != R.Slice.size(); ++I) {
      Instruction *V = R.Slice[I];
      if (Owner.contains(V) && Owner[V] != Phi)
        return Reject("accumulators depend on one another");
      Owner[V] = Phi;
      for (User *U : V->users()) {
        auto *UseI = dyn_cast<Instruction>(U);
        if (!UseI)
          return Reject("non-instruction observes an accumulator");
        if (!L->contains(UseI)) {
          if (V != Desc.getLoopExitInstr() || !isa<PHINode>(UseI))
            return Reject(
                "intermediate accumulator is observed outside its recurrence");
          continue;
        }
        if (UseI == Phi)
          continue;
        if ((isa<PHINode>(UseI) && UseI->getParent() == L->getHeader()) ||
            UseI->isTerminator() || UseI->mayReadOrWriteMemory() ||
            UseI->mayHaveSideEffects())
          return Reject(
              "accumulator affects Map control, memory, or another recurrence");
        R.Slice.insert(UseI);
      }
    }
    // Slice discovery follows dependencies, not an opcode-specific pattern.
    // Every dependent instruction must contribute to this recurrence's update.
    SmallPtrSet<Instruction *, 16> ReachesUpdate;
    SmallVector<Instruction *> Work{Desc.getLoopExitInstr()};
    while (!Work.empty()) {
      Instruction *I = Work.pop_back_val();
      if (!R.Slice.contains(I) || !ReachesUpdate.insert(I).second)
        continue;
      if (I == Phi)
        continue;
      for (Value *Op : I->operands())
        if (auto *OI = dyn_cast<Instruction>(Op))
          Work.push_back(OI);
    }
    if (ReachesUpdate.size() != R.Slice.size())
      return Reject("intermediate accumulator has uses outside its update");
    for (Instruction *I : R.Slice) {
      if (I == Phi)
        continue;
      for (Value *Op : I->operands()) {
        if (auto *OI = dyn_cast<Instruction>(Op); OI && R.Slice.contains(OI))
          continue;
        if (L->isLoopInvariant(Op))
          continue;
        if (!Op->getType()->isIntegerTy() &&
            !Op->getType()->isFloatingPointTy())
          return Reject("separation boundary has a non-scalar contribution");
        R.Inputs.insert(Op);
      }
    }
    // Reproduce the original per-iteration control path in each reduction.
    // Conditions are independent of every accumulator (checked above); buffer
    // them so Map effects/loads are never re-executed by a reduction loop.
    for (BasicBlock *BB : L->blocks()) {
      auto *Branch = cast<BranchInst>(BB->getTerminator());
      if (BB != L->getLoopLatch() && Branch->isConditional() &&
          !L->isLoopInvariant(Branch->getCondition()))
        R.Inputs.insert(Branch->getCondition());
    }
    Reductions.push_back(std::move(R));
  }
  // Reuse an existing, contiguous stream only when every iteration accesses
  // a distinct location and no Map write can change it after its defining
  // load/store. Whole-object alias queries cover other iterations as well.
  // Keep conditional paths on scratch: availability and control replay need
  // separate proofs. A read-only loop can have an empty Map after reuse.
  if (L->getNumBlocks() == 1) {
    auto TryStream = [&](Value *V, Value *Ptr, Align Alignment,
                         Instruction *Writer, Type *StoredType, ElementCount VF,
                         unsigned ExtendOpcode = 0) {
      if (StoredType->getScalarSizeInBits() % 8 != 0)
        return false;
      // Scalable reducers use predicated loads. If that load is unsupported
      // (for example an underaligned RVV float stream), keep aligned scratch
      // rather than losing a viable Map + maximum-width reducer combination.
      if (VF.isScalable() &&
          !TTI.isLegalMaskedLoad(VectorType::get(StoredType, VF), Alignment,
                                 Ptr->getType()->getPointerAddressSpace()))
        return false;
      const auto *AR = dyn_cast<SCEVAddRecExpr>(SE.getSCEV(Ptr));
      if (!AR || AR->getLoop() != L || !AR->isAffine() ||
          !SE.isLoopInvariant(AR->getStart(), L))
        return false;
      if (!AR->hasNoUnsignedWrap()) {
        // GEP canonicalization can lose nuw, e.g. A[i] followed by a negative
        // byte offset. A constant traversal starting at a global object and
        // wholly within its minimum size provides the same non-wrapping proof.
        Value *Base = getUnderlyingObject(Ptr);
        const auto *BTC = dyn_cast<SCEVConstant>(BackedgeCount);
        ObjectSizeOpts Options;
        Options.EvalMode = ObjectSizeOpts::Mode::Min;
        uint64_t Size;
        uint64_t ElementBytes = DL.getTypeAllocSize(StoredType).getFixedValue();
        if (!isa<GlobalVariable>(Base) || !BTC ||
            AR->getStart() != SE.getSCEV(Base) ||
            !getObjectSize(Base, Size, DL, &TLI, Options) ||
            !BTC->getAPInt().ult(Size / ElementBytes))
          return false;
      }
      const auto *Step = dyn_cast<SCEVConstant>(AR->getStepRecurrence(SE));
      if (!Step || Step->getAPInt() != DL.getTypeAllocSize(StoredType) ||
          !Exp.isSafeToExpandAt(AR->getStart(),
                                L->getLoopPreheader()->getTerminator()))
        return false;
      MemoryLocation Loc = MemoryLocation::getBeforeOrAfter(Ptr);
      for (Instruction &I : *L->getHeader())
        if (&I != Writer && isModSet(AA.getModRefInfo(&I, Loc)))
          return false;
      Streams[V] = {AR->getStart(), Alignment, StoredType, ExtendOpcode};
      return true;
    };
    for (Reduction &R : Reductions) {
      auto Choices = getLegalVFs(R, TTI);
      if (Choices.empty())
        continue;
      ElementCount VF = Choices.back();
      for (Value *V : R.Inputs) {
        if (Streams.contains(V))
          continue;
        if (auto *Load = dyn_cast<LoadInst>(V);
            Load && Load->isSimple() &&
            TryStream(V, Load->getPointerOperand(), Load->getAlign(), nullptr,
                      Load->getType(), VF))
          continue;
        // Exact extensions provide a lossless storage encoding. Read the
        // original narrower stream and reconstruct the logical contribution
        // at its load, without allocating a widened copy. Never truncate an
        // arbitrary computed value based only on its reducer's demanded type.
        if (auto *Cast = dyn_cast<CastInst>(V);
            Cast && (Cast->getOpcode() == Instruction::SExt ||
                     Cast->getOpcode() == Instruction::ZExt ||
                     Cast->getOpcode() == Instruction::FPExt)) {
          auto *Load = dyn_cast<LoadInst>(Cast->getOperand(0));
          if (Load && L->contains(Load) && Load->isSimple()) {
            // Storage reuse must not make the maximum logical VF unsupported.
            // Otherwise keep the original Map conversion and widened scratch.
            if (TTI.getCastInstrCost(
                       Cast->getOpcode(), VectorType::get(V->getType(), VF),
                       VectorType::get(Load->getType(), VF),
                       TargetTransformInfo::CastContextHint::Normal)
                    .isValid() &&
                TryStream(V, Load->getPointerOperand(), Load->getAlign(),
                          nullptr, Load->getType(), VF, Cast->getOpcode()))
              continue;
          }
        }
        for (User *U : V->users())
          if (auto *Store = dyn_cast<StoreInst>(U);
              Store && L->contains(Store) && Store->isSimple() &&
              Store->getValueOperand() == V &&
              TryStream(V, Store->getPointerOperand(), Store->getAlign(), Store,
                        V->getType(), VF))
            break;
      }
    }
  }
  for (Reduction &R : Reductions) {
    planContribution(R);
    if (R.Phi->getType()->isFloatingPointTy()) {
      SmallVector<Value *> Work{R.Descriptor.getLoopExitInstr()};
      SmallPtrSet<Value *, 8> Seen;
      bool CanSkipUpdate = false;
      while (!Work.empty()) {
        Value *V = Work.pop_back_val();
        if (V == R.Phi) {
          CanSkipUpdate = true;
          break;
        }
        if (!Seen.insert(V).second)
          continue;
        if (auto *P = dyn_cast<PHINode>(V))
          append_range(Work, P->incoming_values());
        else if (auto *S = dyn_cast<SelectInst>(V)) {
          auto *Condition = dyn_cast<Instruction>(S->getCondition());
          // The compare in a min/max idiom itself observes the accumulator;
          // this is not an independent condition skipping its update.
          if (!Condition || !R.Slice.contains(Condition)) {
            Work.push_back(S->getTrueValue());
            Work.push_back(S->getFalseValue());
          }
        }
      }
      if (CanSkipUpdate) {
        Function *F = L->getHeader()->getParent();
        if (F->getDenormalMode(R.Phi->getType()->getFltSemantics()) !=
            DenormalMode::getIEEE())
          return Reject("conditional FP identities require IEEE denormal mode");

        // A skipped scalar update copies all bits of its initial NaN. Even an
        // identity FP operation could instead quiet it or change its payload.
        // For NaN-absorbing recurrences, retaining the original NaN also is a
        // permitted result when an update executes (unchanged NaN propagation).
        RecurKind Kind = R.Descriptor.getRecurrenceKind();
        bool AbsorbsNaN = Kind == RecurKind::FAdd || Kind == RecurKind::FMul ||
                          Kind == RecurKind::FMulAdd ||
                          Kind == RecurKind::FMinimum ||
                          Kind == RecurKind::FMaximum;
        KnownFPClass InitialClass = computeKnownFPClass(
            R.Descriptor.getRecurrenceStartValue(), DL, fcAllFlags, &TLI,
            nullptr, L->getLoopPreheader()->getTerminator(), &DT);
        R.PreserveInitialNaN = AbsorbsNaN && !InitialClass.isKnownNeverNaN();
        if (R.CombineIntrinsic) {
          // For these intrinsic chains, nnan/ninf constrain the accumulator
          // operand of every active update. An exceptional initializer can
          // therefore be returned unchanged: all-skipped execution requires
          // that result, while an active update would produce poison.
          R.PreserveInitialNaN |=
              R.ContributionFMF.noNaNs() && !InitialClass.isKnownNeverNaN();
          R.PreserveInitialInf = R.ContributionFMF.noInfs() &&
                                 !InitialClass.isKnownNeverInfinity();
          // nsz permits either zero sign after an active update, but must not
          // change a zero copied through an all-skipped source loop.
          R.PreserveInitialZero = R.ContributionFMF.noSignedZeros() &&
                                  !InitialClass.isKnownNeverZero();
        }

        // A slice fallback's horizontal collapse uses the recurrence FMF
        // unconditionally. Without a restore, those flags must also hold for
        // an initializer returned unchanged by an all-skipped execution.
        FastMathFlags FMF = R.Descriptor.getFastMathFlags();
        FPClassTest Forbidden = fcNone;
        if (!R.CombineOpcode) {
          if (!R.PreserveInitialNaN)
            Forbidden |= fcNan;
          if (FMF.noInfs())
            Forbidden |= fcInf;
          if (FMF.noSignedZeros())
            Forbidden |= fcZero;
        }
        if (!InitialClass.isKnownNever(Forbidden))
          return Reject("conditional fallback cannot preserve the initial FP "
                        "value");
      }
    }
    // RVV legal types extend through LMUL=8, independent of tuning preferences.
    R.LegalVFs = getLegalVFs(R, TTI);
    if (R.LegalVFs.empty())
      return Reject("target cannot lower this recurrence with legal vector "
                    "accumulator types");
    R.VF = R.LegalVFs.back();
  }
  // Storage sharing does not change the number or order of reduction loops.
  // Match plans before budgeting scratch so sharing can also avoid heap use.
  for (unsigned I = 0; I != Reductions.size(); ++I) {
    Reduction &R = Reductions[I];
    for (unsigned J = 0; J != I; ++J)
      if (sameContribution(R, Reductions[J])) {
        R.SharedContributionWith = J;
        R.Inputs = Reductions[J].Inputs;
        break;
      }
  }
  SetVector<Value *> ScratchInputs;
  for (Reduction &R : Reductions)
    for (Value *V : R.Inputs)
      if (!R.ContributionInvariant && !Streams.contains(V))
        ScratchInputs.insert(V);
  // With owned storage, count/byte overflow takes the allocation-failure path.
  // Without storage there is no allocation failure to justify such a trap.
  // Require a representable count rather than changing a full-width (2^N)
  // recurrence into a zero-trip reduction or an unconditional trap.
  if (ScratchInputs.empty() &&
      BackedgeCount->getType()->getIntegerBitWidth() ==
          DL.getPointerSizeInBits() &&
      !SE.isKnownPredicateAt(
          CmpInst::ICMP_NE, BackedgeCount,
          SE.getConstant(APInt::getMaxValue(DL.getPointerSizeInBits())),
          L->getLoopPreheader()->getTerminator()))
    return Reject(
        "scratch-free iteration count may overflow the reducer index");
  Function *F = L->getHeader()->getParent();
  if (!ScratchInputs.empty() &&
      !fitsOnStack(*F, ScratchInputs.getArrayRef(), BackedgeCount) &&
      (!isLibFuncEmittable(F->getParent(), &TLI, LibFunc_malloc) ||
       !isLibFuncEmittable(F->getParent(), &TLI, LibFunc_free)))
    return Reject("heap scratch requires available malloc and free builtins");
  return true;
}

SmallVector<ElementCount> ReductionFission::getReductionVFs() const {
  SmallVector<ElementCount> Result;
  for (const Reduction &R : Reductions)
    Result.push_back(R.VF);
  return Result;
}

void ReductionFission::emitPlanRemarks(OptimizationRemarkEmitter &ORE) const {
  for (unsigned I = 0; I != Reductions.size(); ++I) {
    const Reduction &R = Reductions[I];
    std::string Accumulator, Initial;
    raw_string_ostream AccumulatorOS(Accumulator), InitialOS(Initial);
    R.Phi->printAsOperand(AccumulatorOS, false);
    R.Descriptor.getRecurrenceStartValue()->printAsOperand(InitialOS, false);
    unsigned Borrowed =
        count_if(R.Inputs, [&](Value *V) { return Streams.contains(V); });
    unsigned Scratch = R.ContributionInvariant ? 0 : R.Inputs.size() - Borrowed;
    ORE.emit([&]() {
      return OptimizationRemarkAnalysis("loop-vectorize",
                                        "ReductionFissionContribution",
                                        R.Phi->getDebugLoc(), L->getHeader())
             << "reduction " << ore::NV("Index", I)
             << " accumulator=" << ore::NV("Accumulator", Accumulator)
             << " initial=" << ore::NV("Initial", Initial)
             << " type=" << ore::NV("Type", R.Phi->getType()) << ": "
             << ore::NV("Reason", R.ContributionReason)
             << "; scratch streams=" << ore::NV("ScratchStreams", Scratch)
             << "; borrowed streams=" << ore::NV("BorrowedStreams", Borrowed)
             << "; shared contribution="
             << ore::NV("SharedContribution",
                        R.SharedContributionWith.has_value());
    });
  }
}

SmallVector<SmallVector<ElementCount, 8>>
ReductionFission::getReductionVFChoices() const {
  SmallVector<SmallVector<ElementCount, 8>> Result;
  for (const Reduction &R : Reductions)
    Result.emplace_back(R.LegalVFs.rbegin(), R.LegalVFs.rend());
  return Result;
}

static void setGeneratedHints(Loop *L, ElementCount VF, bool IsReduction) {
  LLVMContext &C = L->getHeader()->getContext();
  SmallVector<Metadata *> MD{nullptr};
  // The Map retains the original memory instructions and their access groups.
  // Preserve unrelated loop contracts and follow-up metadata there. Reductions
  // receive independent IDs, using scratch or a proven stable Map stream.
  if (!IsReduction)
    if (MDNode *OldID = L->getLoopID())
      for (unsigned I = 1; I != OldID->getNumOperands(); ++I) {
        auto *Node = dyn_cast_or_null<MDNode>(OldID->getOperand(I));
        auto *Key = Node && Node->getNumOperands()
                        ? dyn_cast_or_null<MDString>(Node->getOperand(0))
                        : nullptr;
        if (Key && (Key->getString() == "llvm.loop.vectorize.width" ||
                    Key->getString() == "llvm.loop.vectorize.scalable.enable" ||
                    Key->getString() == "llvm.loop.vectorize.enable" ||
                    Key->getString() == "llvm.loop.interleave.count" ||
                    Key->getString() == "llvm.loop.isvectorized"))
          continue;
        MD.push_back(OldID->getOperand(I));
      }
  auto AddInt = [&](StringRef Key, unsigned Value) {
    MD.push_back(MDNode::get(
        C, {MDString::get(C, Key), ConstantAsMetadata::get(ConstantInt::get(
                                       Type::getInt32Ty(C), Value))}));
  };
  MD.push_back(MDNode::get(
      C, MDString::get(C, "llvm.loop.reduction.fission.generated")));
  if (IsReduction)
    MD.push_back(MDNode::get(
        C, MDString::get(C, "llvm.loop.reduction.fission.reduction")));
  AddInt("llvm.loop.vectorize.width", VF.getKnownMinValue());
  AddInt("llvm.loop.vectorize.scalable.enable", VF.isScalable());
  AddInt("llvm.loop.vectorize.enable", 1);
  AddInt("llvm.loop.interleave.count", 1);
  MDNode *ID = MDNode::getDistinct(C, MD);
  ID->replaceOperandWith(0, ID);
  L->setLoopID(ID);
}

void ReductionFission::setReductionVF(Loop *L, ElementCount VF) {
  setGeneratedHints(L, VF, true);
}

ReductionFission::GeneratedLoops
ReductionFission::execute(const LoopVectorizationCandidate &Candidate,
                          LoopInfo &LI, ScalarEvolution &SE,
                          DominatorTree &DT) {
  assert(Candidate.Transform == LoopVectorizationCandidate::Kind::Fission);
  BasicBlock *Map = L->getHeader();
  BasicBlock *MapLatch = L->getLoopLatch();
  Function *F = Map->getParent();
  Module *M = F->getParent();
  LLVMContext &C = F->getContext();
  const DataLayout &DL = M->getDataLayout();
  BasicBlock *Pre = L->getLoopPreheader();
  BasicBlock *Exit = L->getUniqueExitBlock();
  Type *IndexTy = DL.getIntPtrType(C);
  for (Reduction &R : Reductions) {
    if (!R.CombineOpcode)
      continue;
    if (R.SharedContributionWith) {
      R.Contribution = Reductions[*R.SharedContributionWith].Contribution;
      R.Inputs.clear();
      if (!L->isLoopInvariant(R.Contribution))
        R.Inputs.insert(R.Contribution);
      continue;
    }
    IRBuilder<> B(R.ContributionInvariant ? Pre->getTerminator()
                                          : R.Descriptor.getLoopExitInstr());
    B.setFastMathFlags(R.ContributionFMF);
    Value *Contribution = nullptr;
    for (Instruction *I : R.ContributionChain) {
      if (!R.ContributionInvariant)
        B.SetInsertPoint(I);
      Value *Term;
      if (auto *II = dyn_cast<IntrinsicInst>(I);
          II && II->getIntrinsicID() == Intrinsic::fmuladd) {
        // Do not infer poison-generating flags for the newly exposed product
        // from the result of the original multiply-add.
        IRBuilderBase::FastMathFlagGuard Guard(B);
        FastMathFlags ProductFMF = R.ContributionFMF;
        ProductFMF.setNoNaNs(false);
        ProductFMF.setNoInfs(false);
        B.setFastMathFlags(ProductFMF);
        Term = B.CreateFMul(II->getArgOperand(0), II->getArgOperand(1),
                            "fission.product");
      } else {
        auto *Left = dyn_cast<Instruction>(I->getOperand(0));
        Term = I->getOperand(Left && R.Slice.contains(Left) ? 1 : 0);
      }
      // Integer reassociation uses modular arithmetic. In particular, an
      // original nsw/nuw chain does not prove those flags for the new sum of
      // contributions or for its reordered combination with the initial value.
      Contribution =
          Contribution
              ? R.CombineIntrinsic
                    ? B.CreateBinaryIntrinsic(R.CombineIntrinsic, Contribution,
                                              Term, {}, "fission.contribution")
                    : B.CreateBinOp(Instruction::BinaryOps(R.CombineOpcode),
                                    Contribution, Term, "fission.contribution")
              : Term;
    }
    if (Instruction *Guard = R.ContributionGuard) {
      auto *Identity = R.CombineIntrinsic
                           ? cast<Constant>(getRecurrenceIdentity(
                                 R.Descriptor.getRecurrenceKind(),
                                 R.Phi->getType(), R.ContributionFMF))
                           : ConstantExpr::getBinOpIdentity(R.CombineOpcode,
                                                            R.Phi->getType());
      assert(Identity && "normalized combines must have an identity");
      if (auto *P = dyn_cast<PHINode>(Guard)) {
        auto *CP = PHINode::Create(P->getType(), 2, "fission.contribution",
                                   P->getIterator());
        for (unsigned I = 0; I != 2; ++I)
          CP->addIncoming(P->getIncomingValue(I) == R.Phi ? Identity
                                                          : Contribution,
                          P->getIncomingBlock(I));
        Contribution = CP;
      } else {
        auto *S = cast<SelectInst>(Guard);
        B.SetInsertPoint(S);
        B.clearFastMathFlags();
        Contribution = B.CreateSelect(
            S->getCondition(),
            S->getTrueValue() == R.Phi ? Identity : Contribution,
            S->getFalseValue() == R.Phi ? Identity : Contribution,
            "fission.contribution");
      }
    }
    R.Inputs.clear();
    R.Contribution = Contribution;
    if (!L->isLoopInvariant(Contribution))
      R.Inputs.insert(Contribution);
  }
  SCEVExpander Exp(SE, "fission");
  Value *BTC = Exp.expandCodeFor(BackedgeCount, BackedgeCount->getType(),
                                 Pre->getTerminator());
  IRBuilder<> Entry(Pre->getTerminator());
  Value *WideBTC = Entry.CreateZExtOrTrunc(BTC, IndexTy);
  // Keep the original backedge count for allocation-overflow checks. Arithmetic
  // that cannot represent the buffer size traps rather than wrapping an
  // address.
  Value *TC =
      Entry.CreateAdd(WideBTC, ConstantInt::get(IndexTy, 1), "fission.count");
  Value *BadSize = Entry.CreateICmpEQ(TC, ConstantInt::get(IndexTy, 0));
  SetVector<Value *> Inputs;
  for (Reduction &R : Reductions)
    for (Value *V : R.Inputs)
      if (!Streams.contains(V))
        Inputs.insert(V);
  bool UseStack = fitsOnStack(*F, Inputs.getArrayRef(), BackedgeCount);
  bool HasHeap = !UseStack && !Inputs.empty();
  if (HasHeap) {
    // Heap scratch storage introduces effects absent from a pure scalar kernel.
    F->setMemoryEffects(MemoryEffects::unknown());
    for (Attribute::AttrKind Kind :
         {Attribute::NoFree, Attribute::NoSync, Attribute::NoUnwind,
          Attribute::Speculatable, Attribute::WillReturn})
      F->removeFnAttr(Kind);
  }
  DenseMap<Value *, Value *> Sizes, Buffers;
  for (auto &[V, Stream] : Streams)
    Buffers[V] = Exp.expandCodeFor(Stream.Start, Stream.Start->getType(),
                                   Pre->getTerminator());
  for (Value *V : Inputs) {
    auto *Mul = Entry.CreateIntrinsic(
        Intrinsic::umul_with_overflow, {IndexTy},
        {TC, ConstantInt::get(IndexTy, DL.getTypeAllocSize(getBufferType(V)))});
    Sizes[V] = Entry.CreateExtractValue(Mul, 0);
    BadSize = Entry.CreateOr(BadSize, Entry.CreateExtractValue(Mul, 1));
  }
  BasicBlock *Allocate = BasicBlock::Create(C, "fission.allocate", F, Map);
  BasicBlock *Trap =
      BasicBlock::Create(C, "fission.allocation.failure", F, Map);
  IRBuilder<> Fail(Trap);
  Fail.CreateIntrinsic(Intrinsic::trap, ArrayRef<Type *>{},
                       ArrayRef<Value *>{});
  Fail.CreateUnreachable();
  Pre->getTerminator()->eraseFromParent();
  IRBuilder<>(Pre).CreateCondBr(BadSize, Trap, Allocate);
  IRBuilder<> Alloc(Allocate);
  Value *Failed = ConstantInt::getFalse(C);
  if (UseStack) {
    IRBuilder<> Stack(&F->getEntryBlock(), F->getEntryBlock().begin());
    for (Value *V : Inputs) {
      auto *Buf = Stack.CreateAlloca(getBufferType(V), TC, "fission.buffer");
      Buffers[V] = Buf;
      Alloc.CreateLifetimeStart(Buf);
    }
  } else if (HasHeap) {
    FunctionCallee Malloc = M->getOrInsertFunction(
        "malloc",
        FunctionType::get(PointerType::getUnqual(C), {IndexTy}, false));
    for (Value *V : Inputs) {
      auto *Buf = Alloc.CreateCall(Malloc, {Sizes[V]}, "fission.buffer");
      Buf->addRetAttr(Attribute::NoAlias);
      Buffers[V] = Buf;
      Failed = Alloc.CreateOr(Failed, Alloc.CreateIsNull(Buf));
    }
  }
  BasicBlock *MapPre = BasicBlock::Create(C, "fission.map.preheader", F, Map);
  Alloc.CreateCondBr(Failed, Trap, MapPre);
  IRBuilder<>(MapPre).CreateBr(Map);
  for (PHINode &P : Map->phis())
    P.replaceIncomingBlockWith(Pre, MapPre);
  if (Loop *Parent = L->getParentLoop()) {
    Parent->addBasicBlockToLoop(Allocate, LI);
    Parent->addBasicBlockToLoop(MapPre, LI);
  }
  auto *Index = PHINode::Create(IndexTy, 2, "fission.index", Map->begin());
  Index->addIncoming(ConstantInt::get(IndexTy, 0), MapPre);
  IRBuilder<> MapEnd(MapLatch->getTerminator());
  Value *Next =
      MapEnd.CreateNUWAdd(Index, ConstantInt::get(IndexTy, 1), "fission.next");
  Index->addIncoming(Next, MapLatch);
  for (Value *V : Inputs) {
    Instruction *Definition = dyn_cast<Instruction>(V);
    BasicBlock *StoreBlock =
        L->isLoopInvariant(V) ? Map : Definition->getParent();
    IRBuilder<> Store(StoreBlock,
                      L->isLoopInvariant(V) || isa<PHINode>(Definition)
                          ? StoreBlock->getFirstInsertionPt()
                          : std::next(Definition->getIterator()));
    Value *Ptr = Store.CreateGEP(getBufferType(V), Buffers[V], Index);
    Value *Data = V->getType()->isIntegerTy(1)
                      ? Store.CreateZExt(V, Type::getInt8Ty(C))
                      : V;
    Store.CreateStore(Data, Ptr);
  }

  GeneratedLoops Result{L, {}};
  BasicBlock *Previous = MapLatch;
  DenseMap<Value *, Value *> FinalValues;
  for (Reduction &R : Reductions) {
    BasicBlock *RP = BasicBlock::Create(C, "fission.reduce.preheader", F, Exit);
    ValueToValueMapTy VM;
    SmallVector<BasicBlock *> Blocks;
    if (R.CombineOpcode)
      Blocks.push_back(Map);
    else
      append_range(Blocks, L->blocks());
    for (BasicBlock *BB : Blocks)
      VM[BB] = BasicBlock::Create(C, "fission.reduce", F, Exit);
    auto *RB = cast<BasicBlock>(VM[Map]);
    auto *Latch = R.CombineOpcode ? RB : cast<BasicBlock>(VM[MapLatch]);
    auto *RL = LI.AllocateLoop();
    if (Loop *Parent = L->getParentLoop()) {
      Parent->addChildLoop(RL);
      Parent->addBasicBlockToLoop(RP, LI);
    } else
      LI.addTopLevelLoop(RL);
    RL->addBasicBlockToLoop(RB, LI);
    for (BasicBlock *BB : Blocks)
      if (BB != Map)
        RL->addBasicBlockToLoop(cast<BasicBlock>(VM[BB]), LI);
    IRBuilder<>(RP).CreateBr(RB);
    Previous->getTerminator()->replaceSuccessorWith(Exit, RP);
    IRBuilder<> Header(RB);
    auto *RI = Header.CreatePHI(IndexTy, 2, "fission.reduce.index");
    RI->addIncoming(ConstantInt::get(IndexTy, 0), RP);
    auto *Acc = Header.CreatePHI(R.Phi->getType(), 2, "fission.acc");
    Value *Initial = R.Descriptor.getRecurrenceStartValue();
    bool RestoreInitial =
        R.PreserveInitialNaN || R.PreserveInitialInf || R.PreserveInitialZero;
    if (RestoreInitial) {
      // Classification, seeding and restoration must use one consistent value
      // even if the original initializer is undef or poison.
      IRBuilder<> Preheader(RP->getTerminator());
      Initial = Preheader.CreateFreeze(Initial, "fission.initial");
    }
    Acc->addIncoming(Initial, RP);
    VM[R.Phi] = Acc;
    VM[MapPre] = RP;
    SmallVector<Instruction *> ToRemap;
    for (BasicBlock *BB : Blocks) {
      BasicBlock *Copy = cast<BasicBlock>(VM[BB]);
      IRBuilder<> B(Copy);
      for (Instruction &I : *BB) {
        if (&I == R.Phi)
          continue;
        if (!R.CombineOpcode && R.Slice.contains(&I)) {
          Instruction *Clone = I.clone();
          B.Insert(Clone, I.getName() + ".fission");
          VM[&I] = Clone;
          ToRemap.push_back(Clone);
        }
      }
      // All PHIs must precede loads. The precise position of independent
      // calculations within a block is immaterial: contributions are stable
      // after Map, and execute on exactly the original control path.
      B.SetInsertPoint(Copy, Copy->getFirstInsertionPt());
      for (Value *V : R.Inputs) {
        BasicBlock *DefinitionBlock =
            L->isLoopInvariant(V) ? Map : cast<Instruction>(V)->getParent();
        if (!R.CombineOpcode && DefinitionBlock != BB)
          continue;
        auto Stream = Streams.find(V);
        Type *StoredType = Stream == Streams.end() ? getBufferType(V)
                                                   : Stream->second.StoredType;
        Value *Ptr = B.CreateGEP(StoredType, Buffers[V], RI);
        auto *Data = B.CreateLoad(StoredType, Ptr, "fission.contribution");
        Value *Contribution = Data;
        if (Stream != Streams.end()) {
          Data->setAlignment(Stream->second.Alignment);
          if (unsigned Opcode = Stream->second.ExtendOpcode)
            Contribution = B.CreateCast(Instruction::CastOps(Opcode), Data,
                                        V->getType(), "fission.extend");
        } else if (V->getType()->isIntegerTy(1))
          Contribution = B.CreateTrunc(Data, Type::getInt1Ty(C));
        VM[V] = Contribution;
      }
      if (!R.CombineOpcode && BB != MapLatch) {
        Instruction *Branch = BB->getTerminator()->clone();
        Branch->insertInto(Copy, Copy->end());
        ToRemap.push_back(Branch);
      }
    }
    for (Instruction *I : ToRemap)
      RemapInstruction(I, VM, RF_IgnoreMissingLocals | RF_NoModuleLevelChanges);
    IRBuilder<> B(Latch);
    Value *Update;
    if (R.CombineOpcode) {
      B.setFastMathFlags(R.ContributionFMF);
      Value *Contribution = R.Contribution;
      if (!R.Inputs.empty())
        Contribution = VM[R.Contribution];
      Update = R.CombineIntrinsic
                   ? B.CreateBinaryIntrinsic(R.CombineIntrinsic, Acc,
                                             Contribution, {}, "fission.update")
                   : B.CreateBinOp(Instruction::BinaryOps(R.CombineOpcode), Acc,
                                   Contribution, "fission.update");
    } else
      Update = VM[R.Descriptor.getLoopExitInstr()];
    Acc->addIncoming(Update, Latch);
    Value *RN = B.CreateNUWAdd(RI, ConstantInt::get(IndexTy, 1));
    RI->addIncoming(RN, Latch);
    BasicBlock *ReduceExit = Exit;
    Value *Final = Update;
    Previous = Latch;
    if (RestoreInitial) {
      ReduceExit = BasicBlock::Create(C, "fission.reduce.exit", F, Exit);
      if (Loop *Parent = L->getParentLoop())
        Parent->addBasicBlockToLoop(ReduceExit, LI);
      IRBuilder<> Finish(ReduceExit);
      auto *Reduced = Finish.CreatePHI(R.Phi->getType(), 1, "fission.result");
      Reduced->addIncoming(Update, Latch);
      auto IsClass = [&](Value *V, FPClassTest Mask) {
        return Finish.CreateIntrinsic(Intrinsic::is_fpclass, {V->getType()},
                                      {V, Finish.getInt32(Mask)});
      };
      Final = Reduced;
      if (R.PreserveInitialZero) {
        Value *BothZero = Finish.CreateAnd(IsClass(Initial, fcZero),
                                           IsClass(Reduced, fcZero));
        Final = Finish.CreateSelect(BothZero, Initial, Final,
                                    "fission.result.zero");
      }
      FPClassTest Special = fcNone;
      if (R.PreserveInitialNaN)
        Special |= fcNan;
      if (R.PreserveInitialInf)
        Special |= fcInf;
      // Keep this selection outermost: the unselected result (and its zero
      // classification) may be poison for an nnan/ninf initializer.
      if (Special != fcNone)
        Final = Finish.CreateSelect(IsClass(Initial, Special), Initial, Final,
                                    "fission.result.special");
      Finish.CreateBr(Exit);
      Previous = ReduceExit;
    }
    B.CreateCondBr(B.CreateICmpNE(RN, TC), RB, ReduceExit);
    FinalValues[R.Descriptor.getLoopExitInstr()] = Final;
    setGeneratedHints(RL, R.VF, true);
    Result.Reductions.push_back(RL);
  }
  BasicBlock *Cleanup = BasicBlock::Create(C, "fission.cleanup", F, Exit);
  Previous->getTerminator()->replaceSuccessorWith(Exit, Cleanup);
  if (Loop *Parent = L->getParentLoop())
    Parent->addBasicBlockToLoop(Cleanup, LI);
  IRBuilder<> Clean(Cleanup);
  if (UseStack) {
    for (Value *V : Inputs)
      Clean.CreateLifetimeEnd(Buffers[V]);
  } else if (HasHeap) {
    FunctionCallee Free = M->getOrInsertFunction(
        "free", FunctionType::get(Type::getVoidTy(C),
                                  {PointerType::getUnqual(C)}, false));
    for (Value *V : Inputs)
      Clean.CreateCall(Free, {Buffers[V]});
  }
  Clean.CreateBr(Exit);
  // Values produced by earlier loops dominate cleanup, but must be placed in
  // LCSSA before another loop is vectorized.
  for (PHINode &P : Exit->phis()) {
    int I = P.getBasicBlockIndex(MapLatch);
    if (I < 0)
      continue;
    Value *Old = P.getIncomingValue(I);
    if (FinalValues.contains(Old))
      P.setIncomingValue(I, FinalValues[Old]);
    P.setIncomingBlock(I, Cleanup);
  }
  for (Reduction &R : Reductions)
    for (Instruction *I : R.Slice)
      I->dropAllReferences();
  for (Reduction &R : Reductions)
    for (Instruction *I : R.Slice)
      I->eraseFromParent();
  setGeneratedHints(L, Candidate.MapVF, false);
  SE.forgetAllLoops();
  DT.recalculate(*F);
  formLCSSARecursively(*L, DT, &LI, &SE);
  for (Loop *Generated : Result.Reductions)
    formLCSSARecursively(*Generated, DT, &LI, &SE);
  // Reuse may leave only dead loads, induction and control in Map. Exact
  // backedge analysis already proved termination. Remove it only when it has
  // neither observable effects nor live-outs; a failed nonempty Map must still
  // reject the entire function transaction.
  bool EmptyMap = all_of(L->blocks(), [&](BasicBlock *BB) {
    return all_of(*BB, [&](Instruction &I) {
      return !I.mayHaveSideEffects() && all_of(I.users(), [&](User *U) {
        auto *UseI = dyn_cast<Instruction>(U);
        return UseI && L->contains(UseI);
      });
    });
  });
  if (EmptyMap) {
    deleteDeadLoop(L, &DT, &SE, &LI);
    Result.Map = nullptr;
  }
  return Result;
}
