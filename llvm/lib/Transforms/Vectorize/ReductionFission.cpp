//===- ReductionFission.cpp - Experimental LV distribution
//-----------------===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "ReductionFission.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/PostDominators.h"
#include "llvm/Analysis/ScalarEvolutionExpressions.h"
#include "llvm/Analysis/TargetTransformInfo.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/MDBuilder.h"
#include "llvm/IR/Module.h"
#include "llvm/TargetParser/Triple.h"
#include "llvm/Transforms/Utils/LoopUtils.h"
#include "llvm/Transforms/Utils/ScalarEvolutionExpander.h"
#include "llvm/Transforms/Utils/ValueMapper.h"
#include "llvm/Transforms/Vectorize/LoopVectorizationLegality.h"

using namespace llvm;

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

bool ReductionFission::analyze(LoopVectorizationLegality &Legal,
                               ScalarEvolution &SE, DominatorTree &DT,
                               const TargetTransformInfo &TTI) {
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
    if (R.Inputs.empty()) {
      // Constant/invariant contributions are legal too. Materialize one at the
      // separation boundary so the Map still has a real contribution stream.
      for (Instruction *I : R.Slice) {
        if (I == Phi)
          continue;
        for (Value *Op : I->operands())
          if (L->isLoopInvariant(Op) && (Op->getType()->isIntegerTy() ||
                                         Op->getType()->isFloatingPointTy()))
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
    if (R.Inputs.empty())
      return Reject("recurrence has no scalar contribution to materialize");
    bool Scalable =
        Triple(L->getHeader()->getModule()->getTargetTriple()).isRISCV();
    // Probe actual type legality, including every widened intermediate type.
    // RVV legal types extend through LMUL=8 regardless of tuning preferences.
    for (unsigned N = 1; N <= VectorizerParams::MaxVectorWidth; N *= 2) {
      ElementCount VF = ElementCount::get(N, Scalable);
      if (VF.isScalar())
        continue;
      auto TypeLegal = [&](Type *Ty) {
        return Ty->isVoidTy() || (VectorType::isValidElementType(Ty) &&
                                  TTI.isTypeLegal(VectorType::get(Ty, VF)));
      };
      bool TypesLegal =
          TypeLegal(Phi->getType()) &&
          all_of(R.Inputs, [&](Value *V) { return TypeLegal(V->getType()); }) &&
          all_of(R.Slice,
                 [&](Instruction *I) { return TypeLegal(I->getType()); });
      if (TypesLegal && TTI.isLegalToVectorizeReduction(Desc, VF)) {
        R.VF = VF;
        R.LegalVFs.push_back(VF);
      }
    }
    if (!R.VF.isVector())
      return Reject("target cannot lower this recurrence with legal vector "
                    "accumulator types");
    Reductions.push_back(std::move(R));
  }
  return true;
}

SmallVector<ElementCount> ReductionFission::getReductionVFs() const {
  SmallVector<ElementCount> Result;
  for (const Reduction &R : Reductions)
    Result.push_back(R.VF);
  return Result;
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
  // operate only on fresh scratch storage and receive independent loop IDs.
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

SmallVector<Loop *>
ReductionFission::execute(const LoopVectorizationCandidate &Candidate,
                          LoopInfo &LI, ScalarEvolution &SE,
                          DominatorTree &DT) {
  assert(Candidate.Transform == LoopVectorizationCandidate::Kind::Fission);
  BasicBlock *Map = L->getHeader();
  BasicBlock *MapLatch = L->getLoopLatch();
  Function *F = Map->getParent();
  Module *M = F->getParent();
  // Heap scratch storage introduces effects absent from a pure scalar kernel.
  F->setMemoryEffects(MemoryEffects::unknown());
  for (Attribute::AttrKind Kind :
       {Attribute::NoFree, Attribute::NoSync, Attribute::NoUnwind,
        Attribute::Speculatable, Attribute::WillReturn})
    F->removeFnAttr(Kind);
  LLVMContext &C = F->getContext();
  const DataLayout &DL = M->getDataLayout();
  BasicBlock *Pre = L->getLoopPreheader();
  BasicBlock *Exit = L->getUniqueExitBlock();
  Type *IndexTy = DL.getIntPtrType(C);
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
    Inputs.insert_range(R.Inputs);
  DenseMap<Value *, Value *> Sizes, Buffers;
  auto BufferType = [&](Value *V) -> Type * {
    // Scalar i1 memory occupies a byte. Explicit byte buffers avoid packed
    // mask-vector loads accidentally describing a different memory layout.
    return V->getType()->isIntegerTy(1) ? Type::getInt8Ty(C) : V->getType();
  };
  for (Value *V : Inputs) {
    auto *Mul = Entry.CreateIntrinsic(
        Intrinsic::umul_with_overflow, {IndexTy},
        {TC, ConstantInt::get(IndexTy, DL.getTypeAllocSize(BufferType(V)))});
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
  FunctionCallee Malloc = M->getOrInsertFunction(
      "malloc", FunctionType::get(PointerType::getUnqual(C), {IndexTy}, false));
  Value *Failed = ConstantInt::getFalse(C);
  for (Value *V : Inputs) {
    auto *Buf = Alloc.CreateCall(Malloc, {Sizes[V]}, "fission.buffer");
    Buf->addRetAttr(Attribute::NoAlias);
    Buffers[V] = Buf;
    Failed = Alloc.CreateOr(Failed, Alloc.CreateIsNull(Buf));
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
    Value *Ptr = Store.CreateGEP(BufferType(V), Buffers[V], Index);
    Value *Data = V->getType()->isIntegerTy(1)
                      ? Store.CreateZExt(V, Type::getInt8Ty(C))
                      : V;
    Store.CreateStore(Data, Ptr);
  }

  SmallVector<Loop *> Result{L};
  BasicBlock *Previous = MapLatch;
  DenseMap<Value *, Value *> FinalValues;
  for (Reduction &R : Reductions) {
    BasicBlock *RP = BasicBlock::Create(C, "fission.reduce.preheader", F, Exit);
    ValueToValueMapTy VM;
    for (BasicBlock *BB : L->blocks())
      VM[BB] = BasicBlock::Create(C, "fission.reduce", F, Exit);
    auto *RB = cast<BasicBlock>(VM[Map]);
    auto *Latch = cast<BasicBlock>(VM[MapLatch]);
    auto *RL = LI.AllocateLoop();
    if (Loop *Parent = L->getParentLoop()) {
      Parent->addChildLoop(RL);
      Parent->addBasicBlockToLoop(RP, LI);
    } else
      LI.addTopLevelLoop(RL);
    RL->addBasicBlockToLoop(RB, LI);
    for (BasicBlock *BB : L->blocks())
      if (BB != Map)
        RL->addBasicBlockToLoop(cast<BasicBlock>(VM[BB]), LI);
    IRBuilder<>(RP).CreateBr(RB);
    Previous->getTerminator()->replaceSuccessorWith(Exit, RP);
    IRBuilder<> Header(RB);
    auto *RI = Header.CreatePHI(IndexTy, 2, "fission.reduce.index");
    RI->addIncoming(ConstantInt::get(IndexTy, 0), RP);
    auto *Acc = Header.CreatePHI(R.Phi->getType(), 2, "fission.acc");
    Acc->addIncoming(R.Descriptor.getRecurrenceStartValue(), RP);
    VM[R.Phi] = Acc;
    VM[MapPre] = RP;
    SmallVector<Instruction *> ToRemap;
    for (BasicBlock *BB : L->blocks()) {
      BasicBlock *Copy = cast<BasicBlock>(VM[BB]);
      IRBuilder<> B(Copy);
      for (Instruction &I : *BB) {
        if (&I == R.Phi)
          continue;
        if (R.Slice.contains(&I)) {
          Instruction *Clone = I.clone();
          B.Insert(Clone, I.getName() + ".fission");
          VM[&I] = Clone;
          ToRemap.push_back(Clone);
        }
      }
      // All PHIs must precede loads. The precise position of independent
      // calculations within a block is immaterial: scratch loads cannot alias
      // Map storage, and execute on exactly the original control path.
      B.SetInsertPoint(Copy, Copy->getFirstInsertionPt());
      for (Value *V : R.Inputs) {
        BasicBlock *DefinitionBlock =
            L->isLoopInvariant(V) ? Map : cast<Instruction>(V)->getParent();
        if (DefinitionBlock != BB)
          continue;
        Value *Ptr = B.CreateGEP(BufferType(V), Buffers[V], RI);
        Value *Data = B.CreateLoad(BufferType(V), Ptr, "fission.contribution");
        VM[V] = V->getType()->isIntegerTy(1)
                    ? B.CreateTrunc(Data, Type::getInt1Ty(C))
                    : Data;
      }
      if (BB != MapLatch) {
        Instruction *Branch = BB->getTerminator()->clone();
        Branch->insertInto(Copy, Copy->end());
        ToRemap.push_back(Branch);
      }
    }
    for (Instruction *I : ToRemap)
      RemapInstruction(I, VM, RF_IgnoreMissingLocals | RF_NoModuleLevelChanges);
    Value *Update = VM[R.Descriptor.getLoopExitInstr()];
    Acc->addIncoming(Update, Latch);
    IRBuilder<> B(Latch);
    Value *RN = B.CreateNUWAdd(RI, ConstantInt::get(IndexTy, 1));
    RI->addIncoming(RN, Latch);
    B.CreateCondBr(B.CreateICmpNE(RN, TC), RB, Exit);
    FinalValues[R.Descriptor.getLoopExitInstr()] = Update;
    Previous = Latch;
    setGeneratedHints(RL, R.VF, true);
    Result.push_back(RL);
  }
  BasicBlock *Cleanup = BasicBlock::Create(C, "fission.cleanup", F, Exit);
  Previous->getTerminator()->replaceSuccessorWith(Exit, Cleanup);
  if (Loop *Parent = L->getParentLoop())
    Parent->addBasicBlockToLoop(Cleanup, LI);
  IRBuilder<> Clean(Cleanup);
  FunctionCallee Free = M->getOrInsertFunction(
      "free", FunctionType::get(Type::getVoidTy(C), {PointerType::getUnqual(C)},
                                false));
  for (Value *V : Inputs)
    Clean.CreateCall(Free, {Buffers[V]});
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
  for (Loop *Generated : Result)
    formLCSSARecursively(*Generated, DT, &LI, &SE);
  return Result;
}
