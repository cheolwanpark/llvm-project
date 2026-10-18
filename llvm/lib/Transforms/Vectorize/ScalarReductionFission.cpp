//===- ScalarReductionFission.cpp - Bounded scalar reduction fission -------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// A deliberately small, pre-legality path. Keep the original scalar producer,
// materialize its contributions, and create an ordered scalar consumer. Normal
// LV subsequently considers each loop independently, including when a scalar
// helper prevents construction of a vector VPlan for the original loop.
//
//===----------------------------------------------------------------------===//

#include "VPlanReductionFission.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/MapVector.h"
#include "llvm/Analysis/IVDescriptors.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/OptimizationRemarkEmitter.h"
#include "llvm/Analysis/ScalarEvolution.h"
#include "llvm/Analysis/ScalarEvolutionExpressions.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/DataLayout.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/Support/CheckedArithmetic.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Errc.h"
#include "llvm/Support/MathExtras.h"
#include "llvm/Support/raw_ostream.h"
#include <algorithm>

using namespace llvm;

static cl::opt<bool> EnableScalarReductionFission(
    "enable-scalar-reduction-fission", cl::init(true), cl::Hidden,
    cl::desc("Try bounded scalar-IR splitting under reduction fission; disable "
             "to isolate the VPlan-only pipeline"));

static constexpr StringLiteral ProducerMD =
    "llvm.loop.reduction_fission.producer";
static constexpr StringLiteral ConsumerMD =
    "llvm.loop.reduction_fission.consumer";

StringRef llvm::getScalarReductionFissionStage(const Loop &L) {
  if (findOptionMDForLoop(&L, ProducerMD))
    return "producer";
  if (findOptionMDForLoop(&L, ConsumerMD))
    return "consumer";
  return {};
}

// Compact participation needs exactly one update arm and a two-input latch
// merge. Do not extend this recognition when admitting larger producer CFGs.
static bool hasSingleDiamondProducerCFG(const Loop &L, BasicBlock *Latch) {
  BasicBlock *Header = L.getHeader();
  if (L.getNumBlocks() == 1)
    return Latch == Header;
  if ((L.getNumBlocks() != 3 && L.getNumBlocks() != 4) || !Latch ||
      Latch == Header)
    return false;
  auto *Branch = dyn_cast<BranchInst>(Header->getTerminator());
  if (!Branch || !Branch->isConditional())
    return false;
  BasicBlock *Left = Branch->getSuccessor(0);
  BasicBlock *Right = Branch->getSuccessor(1);
  if (L.getNumBlocks() != ((Left == Latch || Right == Latch) ? 3u : 4u))
    return false;
  if (Left == Right || Left == Header || Right == Header ||
      !L.contains(Left) || !L.contains(Right) ||
      pred_size(Latch) != 2)
    return false;
  for (BasicBlock *Arm : {Left, Right}) {
    if (Arm == Latch)
      continue;
    auto *ArmBranch = dyn_cast<BranchInst>(Arm->getTerminator());
    if (Arm->getSinglePredecessor() != Header || !ArmBranch ||
        !ArmBranch->isUnconditional() || ArmBranch->getSuccessor(0) != Latch)
      return false;
  }
  return L.getExitingBlock() == Latch;
}

// Remove the latch's backedge/exit and require an acyclic branch-only graph.
// Every other successor stays in the loop, so the latch is the only possible
// sink. Processing every block from the header proves that every iteration
// reaches it exactly once. This includes serial/nested/asymmetric diamonds,
// without if-conversion, path enumeration or moving arm-local operations.
static bool hasAcyclicProducerCFG(const Loop &L, BasicBlock *Latch) {
  // Preserve the existing single-block path and its later exit diagnostics.
  if (L.getNumBlocks() == 1)
    return Latch == L.getHeader();
  if (!Latch || L.getExitingBlock() != Latch)
    return false;
  DenseMap<BasicBlock *, unsigned> IncomingEdges;
  for (BasicBlock *BB : L.blocks()) {
    if (!isa<BranchInst>(BB->getTerminator()))
      return false;
    if (BB == Latch)
      continue;
    for (BasicBlock *Succ : successors(BB)) {
      if (!L.contains(Succ) || Succ == L.getHeader())
        return false;
      ++IncomingEdges[Succ];
    }
  }
  SmallVector<BasicBlock *, 8> Ready{L.getHeader()};
  for (unsigned I = 0; I != Ready.size(); ++I) {
    BasicBlock *BB = Ready[I];
    if (BB == Latch)
      continue;
    for (BasicBlock *Succ : successors(BB))
      if (--IncomingEdges[Succ] == 0)
        Ready.push_back(Succ);
  }
  return Ready.size() == L.getNumBlocks();
}

// Scalar emission counts completed iterations; it never expands a trip-count
// expression. Use ordinary SE, without predicates or runtime versioning, only
// to bound storage and prove that the private counters cannot wrap.
static Expected<uint64_t>
getScalarFissionMaxTripCount(Loop &L, ScalarEvolution &SE, IntegerType *CountTy) {
  const SCEV *BTC = SE.getBackedgeTakenCount(&L);
  auto *MaxBTC =
      dyn_cast<SCEVConstant>(SE.getConstantMaxBackedgeTakenCount(&L));
  const SCEV *GuardedBTC =
      isa<SCEVCouldNotCompute>(BTC) ? nullptr : SE.applyLoopGuards(BTC, &L);
  if (!MaxBTC && !GuardedBTC)
    return createStringError(errc::invalid_argument, "non-constant-trip-count");
  APInt MaxBackedges = MaxBTC ? MaxBTC->getAPInt()
                             : SE.getUnsignedRangeMax(GuardedBTC);
  if (MaxBTC && GuardedBTC) {
    // Relational exit analysis can lose the correlation between a runtime
    // start and end in its constant maximum. The exact count's range, under
    // existing entry guards, is an equally unconditional storage bound. This
    // rewrites only an analysis expression; no guard or expression is emitted.
    APInt RangeMax = SE.getUnsignedRangeMax(GuardedBTC);
    unsigned Width = std::max(MaxBackedges.getBitWidth(), RangeMax.getBitWidth());
    MaxBackedges = APIntOps::umin(MaxBackedges.zextOrTrunc(Width),
                                RangeMax.zextOrTrunc(Width));
  }
  if (MaxBackedges.isAllOnes() && MaxBackedges.getBitWidth() >= 64 &&
      !isa<SCEVConstant>(BTC))
    return createStringError(errc::invalid_argument, "non-constant-trip-count");
  APInt MaxTC = MaxBackedges.zext(MaxBackedges.getBitWidth() + 1);
  ++MaxTC;
  if (MaxTC.getActiveBits() > 64 ||
      MaxTC.getActiveBits() > CountTy->getBitWidth())
    return createStringError(errc::invalid_argument, "trip-count-overflow");
  return MaxTC.getZExtValue();
}

// A strict relational comparison must exit when its operands are equal. For
// bounds of the form start + step * span, recover span by cancelling just the
// constant SCEV factor. This is a termination witness, not a claim that the
// loop executes span iterations: a signed or wrapping control can exit earlier.
// The original producer and its completed/participating counters decide that.
// No monotonicity, nowrap flags, relational trip formula or runtime test is
// needed. Check the equality in modular arithmetic before using its range.
static const SCEV *getScalarFissionExitWitness(Loop &L, ScalarEvolution &SE,
                                             PHINode *IV, Value *Next,
                                             ICmpInst *Compare) {
  auto *Branch = cast<BranchInst>(L.getLoopLatch()->getTerminator());
  auto Pred = Branch->getSuccessor(0) == L.getHeader()
                  ? Compare->getPredicate()
                  : Compare->getInversePredicate();
  if (Pred != ICmpInst::ICMP_ULT && Pred != ICmpInst::ICMP_UGT &&
      Pred != ICmpInst::ICMP_SLT && Pred != ICmpInst::ICMP_SGT)
    return nullptr;
  // Equality takes the exiting edge, independently of operand order/polarity.
  unsigned Op =
      Compare->getOperand(0) == IV || Compare->getOperand(0) == Next ? 0 : 1;
  const auto *AR = dyn_cast<SCEVAddRecExpr>(SE.getSCEV(IV));
  if (!AR || AR->getLoop() != &L || !AR->isAffine())
    return nullptr;
  const SCEV *Step = AR->getStepRecurrence(SE);
  const SCEV *Distance = SE.getMinusSCEV(
      SE.getSCEV(Compare->getOperand(1 - Op)), AR->getStart());
  const SCEV *Span = nullptr;
  if (Step->isOne())
    Span = Distance;
  else if (auto *Product = dyn_cast<SCEVMulExpr>(Distance);
           Product && Product->getOperand(0) == Step) {
    SmallVector<SCEVUse, 2> Factors(drop_begin(Product->operands()));
    Span = SE.getMulExpr(Factors);
  }
  if (!Span)
    return nullptr;
  const SCEV *Witness = Compare->getOperand(Op) == Next
                            ? SE.getMinusSCEV(Span, SE.getOne(IV->getType()))
                            : Span;
  const auto *TestAR = dyn_cast<SCEVAddRecExpr>(
      SE.getSCEV(Compare->getOperand(Op)));
  if (!TestAR || TestAR->getLoop() != &L || !TestAR->isAffine() ||
      !SE.getMinusSCEV(TestAR->evaluateAtIteration(Witness, SE),
                       SE.getSCEV(Compare->getOperand(1 - Op)))
           ->isZero())
    return nullptr;
  return Witness;
}

static std::optional<uint64_t> getScalarFissionScratchBytes(
    uint64_t MaxTripCount, const MapVector<Value *, AllocaInst *> &Scratch,
    const DataLayout &DL) {
  uint64_t ScratchBytes = 0;
  for (const auto &[Contribution, Slot] : Scratch) {
    Type *Ty = Contribution->getType();
    uint64_t Bytes = DL.getTypeAllocSize(Ty).getFixedValue();
    uint64_t Alignment = DL.getABITypeAlign(Ty).value();
    auto Padded = checkedAddUnsigned(ScratchBytes, Alignment - 1);
    auto Total = Padded ? checkedMulAddUnsigned(
                              MaxTripCount, Bytes,
                              *Padded & ~(Alignment - 1))
                        : std::nullopt;
    if (!Total || *Total > getReductionFissionMaxScratchBytes() ||
        !isUIntN(DL.getIndexSizeInBits(DL.getAllocaAddrSpace()) - 1, *Total))
      return std::nullopt;
    ScratchBytes = *Total;
  }
  return ScratchBytes;
}

Loop *llvm::tryScalarReductionFission(Loop &L, LoopInfo &LI, DominatorTree &DT,
                                     ScalarEvolution &SE,
                                     OptimizationRemarkEmitter &ORE) {
  if (!isReductionFissionEnabled() || !EnableScalarReductionFission ||
      !getScalarReductionFissionStage(L).empty())
    return nullptr;

  BasicBlock *Header = L.getHeader();
  Function *F = Header->getParent();
  auto Reject = [&](StringRef Reason) -> Loop * {
    ORE.emit([&]() {
      return OptimizationRemarkMissed("vplan-reduction-fission", "Rejected",
                                      L.getStartLoc(), Header)
             << "scalar-IR reduction fission rejected: "
             << ore::NV("Reason", Reason);
    });
    return nullptr;
  };

  BasicBlock *Latch = L.getLoopLatch();
  if (!hasAcyclicProducerCFG(L, Latch) || !L.isLoopSimplifyForm() ||
      !L.hasDedicatedExits() || !L.isLCSSAForm(DT))
    return Reject("scalar-unsupported-cfg");
  if (F->hasFnAttribute(Attribute::StrictFP))
    return Reject("scalar-strict-fp");
  auto *Branch = dyn_cast<BranchInst>(Latch->getTerminator());
  BasicBlock *Exit = L.getUniqueExitBlock();
  if (!Branch || !Branch->isConditional() || !Exit ||
      !((Branch->getSuccessor(0) == Header && Branch->getSuccessor(1) == Exit) ||
        (Branch->getSuccessor(1) == Header && Branch->getSuccessor(0) == Exit)))
    return Reject("scalar-unsupported-exit");
  BasicBlock *Preheader = L.getLoopPreheader();
  auto *Compare = dyn_cast<ICmpInst>(Branch->getCondition());
  if (!Compare)
    return Reject("scalar-unsupported-exit");
  // Identify the control recurrence independently of the reduction PHIs.
  // Only a direct comparison of this IV (or its backedge value) against an
  // invariant is admitted. SE must recognize an integer affine induction with
  // an invariant start and constant nonzero step, without assumed predicates.
  PHINode *IV = nullptr;
  for (PHINode &Phi : Header->phis()) {
    if (!Phi.getType()->isIntegerTy())
      continue;
    Value *Backedge = Phi.getIncomingValueForBlock(Latch);
    bool ControlsExit = false;
    for (unsigned Op = 0; Op != 2; ++Op)
      ControlsExit |= (Compare->getOperand(Op) == &Phi ||
                       Compare->getOperand(Op) == Backedge) &&
                      L.isLoopInvariant(Compare->getOperand(1 - Op));
    if (!ControlsExit)
      continue;
    InductionDescriptor ID;
    if (!InductionDescriptor::isInductionPHI(&Phi, &L, &SE, ID) ||
        ID.getKind() != InductionDescriptor::IK_IntInduction ||
        !ID.getConstIntStepValue() || ID.getConstIntStepValue()->isZero() ||
        !ID.getInductionBinOp() || !L.isLoopInvariant(ID.getStartValue()) || IV)
      return Reject("scalar-unsupported-exit");
    IV = &Phi;
  }
  if (!IV)
    return Reject("scalar-unsupported-exit");
  auto *Next = cast<BinaryOperator>(IV->getIncomingValueForBlock(Latch));
  // Keep the existing zero/one equality case small: its IV already is the
  // ordinal and the invariant equality bound is the completed count. All other
  // controls keep their original arithmetic/flags, predicate and polarity only
  // in the producer; the consumer never clones a noncanonical induction.
  bool CanonicalCount = L.getCanonicalInductionVariable() == IV &&
                        Compare->isEquality() &&
                        Compare->getOperand(0) == Next;
  struct Reduction {
    PHINode *Phi;
    BinaryOperator *Update;
    // Conditional recurrences merge an arm-local update with the unchanged
    // header accumulator. This merge, rather than Update, is their live-out.
    PHINode *Merge;
    Value *Contribution;
    unsigned ContributionOperand;
    PHINode *ConsumerPhi = nullptr;
  };
  SmallVector<Reduction, 4> Reductions;
  SmallPtrSet<Instruction *, 8> ReductionInsts;
  BasicBlock *ParticipationArm = nullptr;
  bool SingleDiamond = hasSingleDiamondProducerCFG(L, Latch);
  // Recognize extractable recurrences independently of producer header state.
  // A delay, or even a reduction-shaped recurrence used by the producer, can
  // stay in place. Prove closure using direct uses before selecting anything:
  // the first edge out of moved state would otherwise reach a predicate,
  // address, contribution, retained recurrence or another accumulator. No DAG
  // traversal or dependence on header PHI order is needed.
  StringRef FailureReason;
  auto RecognizeReduction = [&](PHINode &Phi) -> std::optional<Reduction> {
    auto Fail = [&](StringRef Reason) -> std::optional<Reduction> {
      if (FailureReason.empty())
        FailureReason = Reason;
      return std::nullopt;
    };
    Value *Backedge = Phi.getIncomingValueForBlock(Latch);
    auto *Merge = dyn_cast<PHINode>(Backedge);
    BinaryOperator *Update = nullptr;
    if (Merge) {
      if (!SingleDiamond)
        return Fail("scalar-unsupported-cfg");
      if (Merge->getParent() != Latch || Merge->getNumIncomingValues() != 2)
        return Fail("scalar-unsupported-recurrence");
      int Bypass = Merge->getIncomingValue(0) == &Phi ? 0 : 1;
      BasicBlock *Arm = Merge->getIncomingBlock(1 - Bypass);
      Update = dyn_cast<BinaryOperator>(Merge->getIncomingValue(1 - Bypass));
      if (Merge->getIncomingValue(Bypass) != &Phi || !Update ||
          Update->getParent() != Arm || Arm == Header || Arm == Latch ||
          !L.contains(Arm) || !Update->hasOneUse() ||
          *Update->user_begin() != Merge || Phi.getNumUses() != 2)
        return Fail("scalar-unsupported-recurrence");
      for (User *U : Phi.users())
        if (U != Update && U != Merge)
          return Fail("scalar-reduction-feedback");
    } else {
      Update = dyn_cast<BinaryOperator>(Backedge);
      if (!Update ||
          (Update->getParent() != Latch &&
           !(SingleDiamond && Update->getParent() == Header)) ||
          !Phi.hasOneUse() || *Phi.user_begin() != Update)
        return Fail("scalar-unsupported-recurrence");
    }
    Type *Ty = Phi.getType();
    if (!((Ty->isIntegerTy() && Update->getOpcode() == Instruction::Add) ||
          ((Ty->isFloatTy() || Ty->isDoubleTy()) &&
           Update->getOpcode() == Instruction::FAdd)) ||
        (Update->getOperand(0) != &Phi && Update->getOperand(1) != &Phi))
      return Fail("scalar-unsupported-recurrence");
    unsigned ContributionOperand = Update->getOperand(0) == &Phi ? 1 : 0;
    Value *Contribution = Update->getOperand(ContributionOperand);
    Instruction *Result = Merge ? cast<Instruction>(Merge) : Update;
    for (User *U : Result->users()) {
      if (U == &Phi)
        continue;
      auto *Export = dyn_cast<PHINode>(U);
      if (!Export || Export->getParent() != Exit)
        return Fail("scalar-reduction-feedback");
    }
    return Reduction{&Phi, Update, Merge, Contribution, ContributionOperand};
  };
  for (PHINode &Phi : Header->phis()) {
    if (&Phi == IV)
      continue;
    auto R = RecognizeReduction(Phi);
    if (!R) {
      if (!Phi.getType()->isSingleValueType() || Phi.getType()->isVectorTy())
        return Reject("scalar-unsupported-recurrence");
      continue;
    }
    if (R->Merge) {
      BasicBlock *Arm = R->Update->getParent();
      if (ParticipationArm && ParticipationArm != Arm)
        return Reject("scalar-incompatible-participation");
      ParticipationArm = Arm;
    }
    Reductions.push_back(*R);
    ReductionInsts.insert(&Phi);
    ReductionInsts.insert(R->Update);
    if (R->Merge)
      ReductionInsts.insert(R->Merge);
  }
  if (Reductions.empty())
    return Reject(FailureReason.empty() ? "scalar-no-reduction" : FailureReason);
  // Extracted state only flows around its update/bypass recurrence and final
  // LCSSA exports. In particular no predicate, contribution, other reduction or
  // partial-state export can observe it. This needs no recursive DAG walk.
  // Retained state can therefore determine compact participation, addresses or
  // contributions, including through a latch merge of its own. Its PHIs,
  // operations and branches stay in the producer on their original paths;
  // only the closed accumulators below move. The existing common arm and
  // participating counter preserve the exact sequence of contributions.
  for (const Reduction &R : Reductions) {
    if (bool(R.Merge) != bool(ParticipationArm))
      return Reject("scalar-incompatible-participation");
    if (auto *I = dyn_cast<Instruction>(R.Contribution);
        I && ReductionInsts.contains(I))
      return Reject("scalar-reduction-feedback");
  }

  for (BasicBlock *BB : L.blocks()) {
    for (Instruction &I : *BB) {
      for (User *U : I.users()) {
        auto *UI = dyn_cast<Instruction>(U);
        if ((!UI || !L.contains(UI)) && !ReductionInsts.contains(&I))
          return Reject("scalar-unsupported-live-out");
      }
      if (isa<ConstrainedFPIntrinsic>(I))
        return Reject("scalar-strict-fp");
      if (auto *Load = dyn_cast<LoadInst>(&I)) {
        if (!Load->isSimple() || !Load->getType()->isSingleValueType() ||
            Load->getType()->isVectorTy())
          return Reject("scalar-non-simple-load");
        continue;
      }
      if (auto *Call = dyn_cast<CallInst>(&I)) {
        // No name-based libm contracts, errno assumptions, or vector mappings.
        // speculatable excludes observable effects beyond memory (e.g. FP
        // environment observation); willreturn and nounwind exclude termination
        // and exception ordering changes. Keep calls once in the producer.
        if (!Call->getCalledFunction() || Call->isInlineAsm() ||
            Call->hasOperandBundles() || Call->isTailCall() ||
            Call->isConvergent() || Call->cannotDuplicate() ||
            Call->cannotMerge() || Call->isStrictFP() ||
            Call->hasFnAttr(Attribute::ReturnsTwice) ||
            !Call->doesNotAccessMemory() || !Call->doesNotThrow() ||
            !Call->hasFnAttr(Attribute::WillReturn) ||
            !Call->hasFnAttr(Attribute::Speculatable) ||
            !Call->getType()->isSingleValueType() ||
            Call->getType()->isVectorTy())
          return Reject("scalar-unsafe-call");
        continue;
      }
      // A whitelist also excludes fences, stores, atomics, allocas, EH, and
      // special control operations. All retained producer operations execute
      // on precisely the original iterations, in their original order.
      if (isa<PHINode, BinaryOperator, CastInst, GetElementPtrInst, CmpInst,
              SelectInst, FreezeInst, BranchInst>(I) &&
          !I.getType()->isVectorTy())
        continue;
      return Reject("scalar-unsupported-instruction");
    }
  }

  const DataLayout &DL = F->getDataLayout();
  // Identical contribution values share one slot, without any reassociation.
  MapVector<Value *, AllocaInst *> Scratch;
  for (const Reduction &R : Reductions)
    Scratch.insert({R.Contribution, nullptr});
  auto StandardTrip =
      getScalarFissionMaxTripCount(L, SE, cast<IntegerType>(IV->getType()));
  std::optional<uint64_t> MaxTrip;
  const SCEV *Witness = getScalarFissionExitWitness(L, SE, IV, Next, Compare);
  const SCEV *GuardedWitness =
      Witness ? SE.applyLoopGuards(Witness, &L) : nullptr;
  // Diagnose the ordinary proof separately, before refining it. In particular,
  // distinguish an unrecognized induction/CFG/live-out (which never reaches
  // here), an unavailable/oversized count and the later scratch ceiling.
  std::string StandardFailure;
  if (StandardTrip)
    MaxTrip = *StandardTrip;
  else
    StandardFailure = toString(StandardTrip.takeError());
  ORE.emit([&]() {
    auto Print = [](const SCEV *S) {
      std::string Text;
      raw_string_ostream OS(Text);
      if (S)
        OS << *S;
      else
        OS << "unavailable";
      return OS.str();
    };
    const SCEV *BTC = SE.getBackedgeTakenCount(&L);
    const SCEV *GuardedBTC = isa<SCEVCouldNotCompute>(BTC)
                                 ? nullptr
                                 : SE.applyLoopGuards(BTC, &L);
    std::string StandardAdmission = StandardFailure;
    if (MaxTrip)
      StandardAdmission = getScalarFissionScratchBytes(*MaxTrip, Scratch, DL)
                              ? "admitted"
                              : "scalar-scratch-limit";
    return OptimizationRemarkAnalysis("vplan-reduction-fission",
                                      "ScalarFissionBound", L.getStartLoc(),
                                      Header)
           << "scalar-IR admission passed; control "
           << ore::NV("Control", Print(SE.getSCEV(IV)))
           << "; exact backedges " << ore::NV("Exact", Print(BTC))
           << "; constant maximum "
           << ore::NV("ConstantMax",
                      Print(SE.getConstantMaxBackedgeTakenCount(&L)))
           << "; guarded exact " << ore::NV("GuardedExact", Print(GuardedBTC))
           << "; guarded exact unsigned maximum "
           << ore::NV("GuardedExactMax",
                      Print(GuardedBTC ? SE.getConstant(SE.getUnsignedRangeMax(
                                             GuardedBTC))
                                       : nullptr))
           << "; ordinary count proof "
           << ore::NV("OrdinaryCount", MaxTrip ? std::to_string(*MaxTrip)
                                              : StandardFailure)
           << "; ordinary admission "
           << ore::NV("OrdinaryAdmission", StandardAdmission)
           << "; equality witness " << ore::NV("Witness", Print(Witness))
           << "; guarded witness "
           << ore::NV("GuardedWitness", Print(GuardedWitness))
           << "; witness backedge bound "
           << ore::NV("WitnessMax",
                      Print(GuardedWitness
                                ? SE.getConstant(SE.getUnsignedRangeMax(
                                      GuardedWitness))
                                : nullptr));
  });
  if (GuardedWitness) {
    APInt Bound = SE.getUnsignedRangeMax(GuardedWitness);
    // Widen before adding one: even a wrapping original IV must have a
    // representable completed count. All accesses use ordinals below it.
    Bound = Bound.zext(Bound.getBitWidth() + 1) + 1;
    if (Bound.getActiveBits() <= 64 &&
        Bound.getActiveBits() <= IV->getType()->getIntegerBitWidth() &&
        (!MaxTrip || Bound.getZExtValue() < *MaxTrip))
      MaxTrip = Bound.getZExtValue();
  }
  if (!MaxTrip)
    return Reject(StandardFailure);
  uint64_t MaxTripCount = *MaxTrip;
  auto ScratchSize = getScalarFissionScratchBytes(MaxTripCount, Scratch, DL);
  if (!ScratchSize)
    return Reject("scalar-scratch-limit");
  uint64_t ScratchBytes = *ScratchSize;

  ORE.emit([&]() {
    return OptimizationRemark("vplan-reduction-fission", "Selected",
                              L.getStartLoc(), Header)
           << "split " << ore::NV("Path", "scalar-IR")
           << " reduction loop; stage VFs selected independently "
              "by normal vectorization; scratch capacity "
           << ore::NV("MaxTripCount", MaxTripCount) << ", scratch bytes "
           << ore::NV("ScratchBytes", ScratchBytes);
  });

  // All rejection points precede mutation. The original guarded preheader and
  // producer control remain intact. A compact stream can be empty even when
  // the producer runs: its guard exports the original starts without an add.
  SE.forgetTopmostLoop(&L);
  MDNode *OriginalID = L.getLoopID();
  LLVMContext &Ctx = F->getContext();
  BasicBlock *ConsumerGuard =
      ParticipationArm
          ? BasicBlock::Create(Ctx, "scalar.fission.consumer.guard", F, Exit)
          : nullptr;
  BasicBlock *ConsumerPH =
      BasicBlock::Create(Ctx, "scalar.fission.consumer.ph", F, Exit);
  BasicBlock *ConsumerBody =
      BasicBlock::Create(Ctx, "scalar.fission.consumer.body", F, Exit);
  // Keep the consumer's exit dedicated, before joining the zero-count bypass.
  BasicBlock *ConsumerLoopExit =
      ParticipationArm
          ? BasicBlock::Create(Ctx, "scalar.fission.consumer.loopexit", F, Exit)
          : nullptr;
  BasicBlock *ConsumerExit =
      ParticipationArm
          ? BasicBlock::Create(Ctx, "scalar.fission.consumer.exit", F, Exit)
          : Exit;
  BranchInst::Create(ConsumerBody, ConsumerPH);
  Loop *Consumer = LI.AllocateLoop();
  if (Loop *Parent = L.getParentLoop()) {
    Parent->addChildLoop(Consumer);
    Parent->addBasicBlockToLoop(ConsumerPH, LI);
    if (ConsumerGuard) {
      Parent->addBasicBlockToLoop(ConsumerGuard, LI);
      Parent->addBasicBlockToLoop(ConsumerLoopExit, LI);
      Parent->addBasicBlockToLoop(ConsumerExit, LI);
    }
  } else {
    LI.addTopLevelLoop(Consumer);
  }
  Consumer->addBasicBlockToLoop(ConsumerBody, LI);

  IRBuilder<> EntryBuilder(&*F->getEntryBlock().getFirstInsertionPt());
  Value *ProducerIndex = IV;
  Value *ConsumerCount = Compare->getOperand(1);
  if (ParticipationArm) {
    // Before original iteration i, 0 <= count <= i. An update stores at count
    // then increments once; a bypass retains count. Thus every store index is
    // < N <= MaxTripCount and the final count P <= N fits the original IV type
    // (getScalarFissionMaxTripCount checks representability). Full-trip
    // allocation and the checked byte/index ceiling bound every compact GEP.
    auto *Count = PHINode::Create(IV->getType(), 2, "fission.participating",
                                 &*Header->begin());
    Count->addIncoming(ConstantInt::get(IV->getType(), 0), Preheader);
    IRBuilder<> ArmBuilder(ParticipationArm->getTerminator());
    Value *CountNext = ArmBuilder.CreateAdd(
        Count, ConstantInt::get(IV->getType(), 1), "fission.participating.next",
        /*HasNUW=*/true);
    auto *CountMerge = PHINode::Create(
        IV->getType(), 2, "fission.participating.merge", &*Latch->begin());
    for (BasicBlock *Pred : predecessors(Latch))
      CountMerge->addIncoming(Pred == ParticipationArm ? CountNext : Count, Pred);
    Count->addIncoming(CountMerge, Latch);
    ProducerIndex = Count;
    IRBuilder<> GuardBuilder(ConsumerGuard);
    auto *CountExport = GuardBuilder.CreatePHI(IV->getType(), 1,
                                              "fission.participating.count");
    CountExport->addIncoming(CountMerge, Latch);
    ConsumerCount = CountExport;
    Value *Empty = GuardBuilder.CreateICmpEQ(
        CountExport, ConstantInt::get(IV->getType(), 0), "fission.empty");
    GuardBuilder.CreateCondBr(Empty, ConsumerExit, ConsumerPH);
  } else if (!CanonicalCount) {
    // Before iteration i, ordinal == i. The DAG proof gives exactly one
    // increment per completed iteration, including the exiting iteration.
    // 1 <= N <= MaxTripCount fits CountTy, so ordinal+1 is nuw, and every store
    // uses 0 <= ordinal < N. The checked byte/pointer-index ceiling bounds all
    // casts and inbounds GEPs. Entry bypasses never enter this consumer.
    auto *Ordinal = PHINode::Create(IV->getType(), 2, "fission.ordinal",
                                   &*Header->begin());
    Ordinal->addIncoming(ConstantInt::get(IV->getType(), 0), Preheader);
    IRBuilder<> LatchBuilder(Branch);
    Value *Completed = LatchBuilder.CreateAdd(
        Ordinal, ConstantInt::get(IV->getType(), 1), "fission.completed",
        /*HasNUW=*/true);
    Ordinal->addIncoming(Completed, Latch);
    ProducerIndex = Ordinal;
    // A dedicated single-edge producer exit provides valid LCSSA without
    // expanding (or speculating) the original trip expression.
    auto *CountExport = PHINode::Create(
        IV->getType(), 1, "fission.completed.count", &*ConsumerPH->begin());
    CountExport->addIncoming(Completed, Latch);
    ConsumerCount = CountExport;
  }
  // Unconditional merged contributions are available at the latch. Compact
  // contributions stay in their original arm; no inactive operation is moved.
  IRBuilder<> ProducerBuilder(ParticipationArm
                                  ? ParticipationArm->getTerminator()
                                  : Branch);
  for (auto &[Contribution, Slot] : Scratch) {
    auto *Array = ArrayType::get(Contribution->getType(), MaxTripCount);
    Slot = EntryBuilder.CreateAlloca(Array, DL.getAllocaAddrSpace(), nullptr,
                                    "scalar.fission.scratch");
    Value *Index = ProducerBuilder.CreateZExtOrTrunc(
        ProducerIndex, DL.getIndexType(Slot->getType()), "fission.producer.index");
    Value *Address = ProducerBuilder.CreateInBoundsGEP(
        Array, Slot, {ProducerBuilder.getInt32(0), Index});
    ProducerBuilder.CreateStore(Contribution, Address);
  }

  IRBuilder<> B(ConsumerBody);
  B.SetCurrentDebugLocation(Branch->getDebugLoc());
  PHINode *ConsumerIV = B.CreatePHI(IV->getType(), 2, "fission.consumer.iv");
  ConsumerIV->addIncoming(ConstantInt::get(IV->getType(), 0), ConsumerPH);
  DenseMap<Value *, Value *> ConsumerUpdates;
  for (Reduction &R : Reductions) {
    R.ConsumerPhi = B.CreatePHI(R.Phi->getType(), 2, R.Phi->getName() + ".consume");
    R.ConsumerPhi->addIncoming(R.Phi->getIncomingValueForBlock(Preheader),
                               ConsumerPH);
  }
  DenseMap<Value *, Value *> Contributions;
  for (auto [Contribution, Slot] : Scratch) {
    Value *Index = B.CreateZExtOrTrunc(
        ConsumerIV, DL.getIndexType(Slot->getType()), "fission.consumer.index");
    Value *Address = B.CreateInBoundsGEP(
        Slot->getAllocatedType(), Slot, {B.getInt32(0), Index});
    Contributions[Contribution] =
        B.CreateLoad(Contribution->getType(), Address, "fission.contribution");
  }
  for (Reduction &R : Reductions) {
    // clone keeps flags, operand order, rounding/grouping and source location.
    Instruction *Update = R.Update->clone();
    Update->setOperand(R.ContributionOperand, Contributions[R.Contribution]);
    Update->setOperand(1 - R.ContributionOperand, R.ConsumerPhi);
    B.Insert(Update, R.Update->getName() + ".consume");
    R.ConsumerPhi->addIncoming(Update, ConsumerBody);
    if (ParticipationArm) {
      auto *LoopResult = PHINode::Create(R.Phi->getType(), 1,
                                         R.Phi->getName() + ".lcssa",
                                         ConsumerLoopExit);
      LoopResult->addIncoming(Update, ConsumerBody);
      auto *Result = PHINode::Create(R.Phi->getType(), 2,
                                    R.Phi->getName() + ".result", ConsumerExit);
      Result->addIncoming(R.Phi->getIncomingValueForBlock(Preheader),
                          ConsumerGuard);
      Result->addIncoming(LoopResult, ConsumerLoopExit);
      ConsumerUpdates[R.Merge] = Result;
    } else {
      ConsumerUpdates[R.Update] = Update;
    }
  }
  for (PHINode &Export : Exit->phis()) {
    int Index = Export.getBasicBlockIndex(Latch);
    if (Index >= 0)
      if (Value *Update = ConsumerUpdates.lookup(Export.getIncomingValue(Index)))
        Export.setIncomingValue(Index, Update);
  }
  // The compact consumer iterates exactly P times in original participation
  // order. Noncanonical producers use an independent zero/one consumer,
  // consuming exactly their exported number of completed iterations.
  Value *ConsumerNext;
  if (CanonicalCount) {
    Instruction *ClonedNext = Next->clone();
    ClonedNext->replaceUsesOfWith(IV, ConsumerIV);
    B.Insert(ClonedNext, "fission.consumer.next");
    ConsumerNext = ClonedNext;
  } else {
    ConsumerNext = B.CreateAdd(ConsumerIV, ConstantInt::get(IV->getType(), 1),
                               "fission.consumer.next", /*HasNUW=*/true);
  }
  ConsumerIV->addIncoming(ConsumerNext, ConsumerBody);
  if (ParticipationArm) {
    Value *More = B.CreateICmpNE(ConsumerNext, ConsumerCount,
                               "fission.consumer.more");
    B.CreateCondBr(More, ConsumerBody, ConsumerLoopExit);
    BranchInst::Create(ConsumerExit, ConsumerLoopExit);
    BranchInst::Create(Exit, ConsumerExit);
  } else if (!CanonicalCount) {
    Value *More = B.CreateICmpNE(ConsumerNext, ConsumerCount,
                               "fission.consumer.more");
    B.CreateCondBr(More, ConsumerBody, Exit);
  } else {
    Instruction *Done = Compare->clone();
    Done->setOperand(0, ConsumerNext);
    B.Insert(Done, "fission.consumer.done");
    B.CreateCondBr(Done,
                   Branch->getSuccessor(0) == Header ? ConsumerBody : Exit,
                   Branch->getSuccessor(1) == Header ? ConsumerBody : Exit);
  }
  Branch->setSuccessor(Branch->getSuccessor(0) == Exit ? 0 : 1,
                       ConsumerGuard ? ConsumerGuard : ConsumerPH);
  for (PHINode &Export : Exit->phis())
    Export.replaceIncomingBlockWith(
        Latch, ParticipationArm ? ConsumerExit : ConsumerBody);
  for (Reduction &R : Reductions) {
    R.Update->dropAllReferences();
    R.Phi->dropAllReferences();
    if (R.Merge)
      R.Merge->dropAllReferences();
  }
  for (Reduction &R : Reductions) {
    R.Update->eraseFromParent();
    R.Phi->eraseFromParent();
    if (R.Merge)
      R.Merge->eraseFromParent();
  }
  if (OriginalID)
    Consumer->setLoopID(OriginalID);
  L.addStringLoopAttribute(ProducerMD);
  Consumer->addStringLoopAttribute(ConsumerMD);
  SE.forgetBlockAndLoopDispositions();
  DT.recalculate(*F);
  return Consumer;
}
