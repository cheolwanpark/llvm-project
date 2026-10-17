//===- VPlanReductionFission.cpp - Reduction fission pipeline -------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "VPlanReductionFission.h"
#include "VPlanCFG.h"
#include "VPlanHelpers.h"
#include "VPlanTransforms.h"
#include "VPlanUtils.h"
#include "VPlanVerifier.h"
#include "llvm/ADT/PostOrderIterator.h"
#include "llvm/Analysis/LoopAccessAnalysis.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/ScalarEvolutionExpressions.h"
#include "llvm/Analysis/VectorUtils.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Debug.h"
#include "llvm/Transforms/Utils/BasicBlockUtils.h"
#include "llvm/Transforms/Utils/LoopUtils.h"
#include "llvm/Transforms/Vectorize/LoopVectorizationLegality.h"
#include <limits>

using namespace llvm;
#define DEBUG_TYPE "vplan-reduction-fission"

// Fission is an optional transaction inside LoopVectorize. Analyze and verify
// independent producer/accumulator VPlans before modifying IR, prepare all four
// vector/scalar stages, then emit them and retire the original loop. Policy and
// graph rewriting live in the adjacent Analysis and Transforms files.

static cl::opt<bool> EnableVPlanReductionFission(
    "enable-vplan-reduction-fission", cl::init(false), cl::Hidden,
    cl::desc("Enable experimental VPlan reduction fission planning"));

static cl::opt<unsigned> VPlanReductionFissionMinChainDepth(
    "vplan-reduction-fission-min-chain-depth", cl::init(8), cl::Hidden,
    cl::desc("Minimum producer dependency depth for reduction fission"));

static cl::opt<bool> VPlanReductionFissionCombineAddContributions(
    "vplan-reduction-fission-combine-add-contributions", cl::init(true),
    cl::Hidden,
    cl::desc("Consider combining private integer-add scratch contributions"));

static cl::opt<unsigned> VPlanReductionFissionForceProducerVF(
    "vplan-reduction-fission-force-producer-vf", cl::init(0), cl::Hidden,
    cl::desc("Experimental producer scalable VF minimum; requires an explicit "
             "accumulator VF and bypasses register-pressure headroom only"));

static cl::opt<unsigned> VPlanReductionFissionForceAccumulatorVF(
    "vplan-reduction-fission-force-accumulator-vf", cl::init(0), cl::Hidden,
    cl::desc(
        "Experimental accumulator scalable VF minimum; requires an "
        "explicit producer VF and bypasses register-pressure headroom only"));

static cl::opt<unsigned> VPlanReductionFissionMinReductions(
    "vplan-reduction-fission-min-reductions", cl::init(4), cl::Hidden,
    cl::desc("Minimum number of reductions for reduction fission"));

static cl::opt<unsigned> VPlanReductionFissionMinPressurePercent(
    "vplan-reduction-fission-min-pressure-percent", cl::init(100), cl::Hidden,
    cl::desc("Minimum register pressure as a percentage of capacity"));

static cl::opt<unsigned long long> VPlanReductionFissionMaxScratchBytes(
    "vplan-reduction-fission-max-scratch-bytes", cl::init(64 * 1024),
    cl::Hidden,
    cl::desc("Maximum static scratch storage for reduction fission"));

static cl::opt<unsigned> VPlanReductionFissionMaxDuplicatedRecipes(
    "vplan-reduction-fission-max-duplicated-recipes", cl::init(8), cl::Hidden,
    cl::desc("Maximum recipes duplicated by reduction fission"));

static cl::opt<unsigned> VPlanReductionFissionMaxScalableVFMultiplier(
    "vplan-reduction-fission-max-scalable-vf-multiplier", cl::init(8),
    cl::Hidden,
    cl::desc("Maximum scalable VF multiple explored by reduction fission"));

void llvm::saveReductionFissionPlan(VPlan &Plan,
                                    SmallVectorImpl<VPlanPtr> &Plans) {
  if (EnableVPlanReductionFission && !Plan.isOuterLoop() &&
      any_of(Plan.vectorFactors(),
             [](ElementCount VF) { return VF.isScalable(); }))
    Plans.emplace_back(Plan.duplicate());
}

static std::optional<VPReductionFissionCandidate>
planReductionFission(ArrayRef<VPlanPtr> VPlans, ElementCount ActualBaselineVF,
                     VPReductionFissionContext &Ctx) {
  Loop *OrigLoop = &Ctx.L;
  auto *Legal = &Ctx.Legal;
  auto &PSE = Ctx.PSE;
  const auto &TTI = Ctx.TTI;
  auto DebugReject = [&](StringRef Reason) {
    DEBUG_WITH_TYPE("vplan-reduction-fission",
                    dbgs() << "LV-FISSION: "
                           << OrigLoop->getHeader()->getParent()->getName()
                           << ": rejected: " << Reason << "\n");
  };

  bool ForceStageVFs = VPlanReductionFissionForceProducerVF != 0 ||
                       VPlanReductionFissionForceAccumulatorVF != 0;
  if (ForceStageVFs &&
      (!isPowerOf2_32(VPlanReductionFissionForceProducerVF) ||
       !isPowerOf2_32(VPlanReductionFissionForceAccumulatorVF))) {
    DebugReject("invalid-forced-stage-vf-pair");
    return std::nullopt;
  }

  // Only single-block loops without runtime memory versioning are supported.
  if (OrigLoop->getNumBlocks() != 1) {
    DebugReject("not-single-block");
    return std::nullopt;
  }
  if (!Legal->getLAI()->getRuntimePointerChecking()->getChecks().empty()) {
    DebugReject("runtime-memory-check");
    return std::nullopt;
  }
  // Horizontal fission executes all producer reads before any accumulator
  // work. Until partition dependence directions are modeled, accept only a
  // read-only loop body. Absence of runtime alias checks is not sufficient.
  for (Instruction &I : *OrigLoop->getHeader()) {
    if (auto *Load = dyn_cast<LoadInst>(&I); Load && !Load->isSimple()) {
      DebugReject("non-simple-load");
      return std::nullopt;
    }
    if (!I.isTerminator() && I.mayHaveSideEffects()) {
      DebugReject("side-effecting-loop");
      return std::nullopt;
    }
    if (auto *Call = dyn_cast<CallBase>(&I);
        Call && (Call->isConvergent() || Call->cannotDuplicate())) {
      DebugReject("non-duplicable-call");
      return std::nullopt;
    }
  }
  if (!PSE.getPredicate().isAlwaysTrue()) {
    DebugReject("runtime-scev-check");
    return std::nullopt;
  }

  ScalarEvolution &SE = *PSE.getSE();
  const SCEV *BackedgeCount = SE.getBackedgeTakenCount(OrigLoop);
  if (isa<SCEVCouldNotCompute>(BackedgeCount)) {
    DebugReject("non-constant-trip-count");
    return std::nullopt;
  }
  const SCEV *ExactTripCount =
      SE.getAddExpr(BackedgeCount, SE.getOne(BackedgeCount->getType()));
  if (!isa<SCEVConstant>(ExactTripCount)) {
    DebugReject("non-constant-trip-count");
    return std::nullopt;
  }

  for (const VPlanPtr &PlanPtr : VPlans) {
    VPlan &Plan = *PlanPtr;
    SmallVector<ElementCount, 8> VFs;
    for (ElementCount VF : Plan.vectorFactors())
      if (VF.isVector())
        VFs.push_back(VF);
    if (VFs.empty())
      continue;

    // Removing loop-live accumulators may permit a wider producer VF.
    bool HasScalableVF = false;
    unsigned LargestScalableVF = 0;
    for (ElementCount VF : VFs)
      if (VF.isScalable()) {
        unsigned Width = VF.getKnownMinValue();
        LargestScalableVF = std::max(LargestScalableVF, Width);
        HasScalableVF = true;
      }
    if (!HasScalableVF)
      continue;
    erase_if(VFs, [](ElementCount VF) { return !VF.isScalable(); });
    unsigned WidestType = Ctx.WidestType;
    unsigned RegisterVF = std::max<uint64_t>(
        1u, llvm::bit_floor(
                TTI.getRegisterBitWidth(TargetTransformInfo::RGK_ScalableVector)
                    .getKnownMinValue() /
                WidestType));
    // Fractional-register VFs must not shrink the search bound. Use the
    // target's register width and widened data type, not the first plan VF.
    // Compute in 64 bits so even an extreme user multiplier cannot wrap.
    uint64_t Limit =
        uint64_t(RegisterVF) * VPlanReductionFissionMaxScalableVFMultiplier;
    for (uint64_t Width = uint64_t(LargestScalableVF) * 2;
         Width <= Limit && Width <= std::numeric_limits<unsigned>::max();
         Width *= 2)
      VFs.push_back(ElementCount::getScalable(Width));

    SmallVector<VPFissionVFPressure, 8> BaselinePressure;
    std::optional<VPReductionFissionAnalysis> Analysis;
    for (ElementCount VF : VFs) {
      if (!isLegalReductionFissionVF(Plan, VF, TTI))
        continue;
      VPRegisterPressureBreakdown Pressure =
          calculateRegisterPressureForPlan(Plan, VF, TTI);
      BaselinePressure.push_back({VF, Pressure});
      DEBUG_WITH_TYPE("vplan-reduction-fission",
                      dbgs() << "LV-FISSION: "
                             << OrigLoop->getHeader()->getParent()->getName()
                             << ": pressure: vf=" << VF << " accumulator="
                             << (Pressure.AccumulatorRegs.empty()
                                     ? 0
                                     : Pressure.AccumulatorRegs.begin()->second)
                             << " total="
                             << (Pressure.PeakTotalRegs.empty()
                                     ? 0
                                     : Pressure.PeakTotalRegs.begin()->second)
                             << " capacity="
                             << (Pressure.Capacity.empty()
                                     ? 0
                                     : Pressure.Capacity.begin()->second)
                             << "\n");

      bool MeetsPressureThreshold =
          any_of(Pressure.PeakTotalRegs, [&](const auto &Entry) {
            uint64_t Capacity = Pressure.Capacity.lookup(Entry.first);
            return Capacity &&
                   uint64_t(Entry.second) * 100 >=
                       Capacity * VPlanReductionFissionMinPressurePercent;
          });
      if (Analysis || !MeetsPressureThreshold)
        continue;
      VPReductionFissionConfig Config;
      Config.MinimumReductionCount = VPlanReductionFissionMinReductions;
      Config.MinimumLongProducerDepth = VPlanReductionFissionMinChainDepth;
      VPReductionFissionAnalysis A =
          analyzeVPReductionFission(Plan, Pressure, Config);
      if (A.isCandidate()) {
        Analysis = std::move(A);
      } else {
        DebugReject(getVPReductionFissionRejectReasonName(*A.RejectReason));
        if (*A.RejectReason == VPReductionFissionRejectReason::TooFewReductions)
          return std::nullopt;
      }
    }
    if (!Analysis)
      continue;

    Expected<VPScratchPlan> Scratch =
        buildScratchPlan(Analysis->Partition.FrontierValues, ExactTripCount,
                         OrigLoop->getHeader()->getDataLayout(),
                         VPlanReductionFissionMaxScratchBytes);
    if (!Scratch) {
      DebugReject(toString(Scratch.takeError()));
      continue;
    }

    Expected<VPReductionFissionCandidate> Candidate =
        buildReductionFissionStagePlans(Plan, *Analysis, *Scratch, VFs);
    if (!Candidate) {
      DebugReject(toString(Candidate.takeError()));
      continue;
    }

    simplifyReductionFissionTail(*Candidate->AccumulatorPlan);
    DEBUG_WITH_TYPE("vplan-reduction-fission",
                    dbgs() << "LV-FISSION: duplicated recipes="
                           << Candidate->Partition.DuplicatedRecipeCount
                           << "\n");
    if (!verifyVPlanIsValid(*Candidate->ProducerPlan) ||
        !verifyVPlanIsValid(*Candidate->AccumulatorPlan) ||
        !verifyVPlanIsValid(*Candidate->ProducerRemainder.Plan) ||
        !verifyVPlanIsValid(*Candidate->AccumulatorRemainder.Plan)) {
      DebugReject("invalid-stage-plan");
      continue;
    }

    SmallVector<VPFissionVFPressure, 8> ProducerPressure;
    SmallVector<VPFissionVFPressure, 8> AccumulatorPressure;
    for (ElementCount VF : VFs) {
      if (!isLegalReductionFissionVF(*Candidate->ProducerPlan, VF, TTI) ||
          !isLegalReductionFissionVF(*Candidate->AccumulatorPlan, VF, TTI))
        continue;
      ProducerPressure.push_back({VF, calculateRegisterPressureForPlan(
                                          *Candidate->ProducerPlan, VF, TTI)});
      AccumulatorPressure.push_back(
          {VF, calculateRegisterPressureForPlan(*Candidate->AccumulatorPlan, VF,
                                                TTI)});
      DEBUG_WITH_TYPE(
          "vplan-reduction-fission",
          dbgs() << "LV-FISSION: "
                 << OrigLoop->getHeader()->getParent()->getName()
                 << ": split-pressure: vf=" << VF << " producer="
                 << (ProducerPressure.back().Pressure.PeakTotalRegs.empty()
                         ? 0
                         : ProducerPressure.back()
                               .Pressure.PeakTotalRegs.begin()
                               ->second)
                 << " accumulator="
                 << (AccumulatorPressure.back().Pressure.PeakTotalRegs.empty()
                         ? 0
                         : AccumulatorPressure.back()
                               .Pressure.PeakTotalRegs.begin()
                               ->second)
                 << "\n");
    }

    if (ForceStageVFs) {
      // Forced widths must already satisfy stage legality.
      erase_if(ProducerPressure, [&](const VPFissionVFPressure &P) {
        return P.VF !=
               ElementCount::getScalable(VPlanReductionFissionForceProducerVF);
      });
      erase_if(AccumulatorPressure, [&](const VPFissionVFPressure &P) {
        return P.VF != ElementCount::getScalable(
                           VPlanReductionFissionForceAccumulatorVF);
      });
      if (ProducerPressure.empty() || AccumulatorPressure.empty()) {
        DebugReject("forced-stage-vf-not-legal");
        continue;
      }
    }

    VPReductionFissionDecision Decision = selectReductionFissionConfiguration(
        ActualBaselineVF, BaselinePressure, ProducerPressure,
        AccumulatorPressure, Scratch->TotalBytes,
        VPlanReductionFissionMaxScratchBytes,
        Candidate->Partition.DuplicatedRecipeCount,
        VPlanReductionFissionMaxDuplicatedRecipes,
        /*AllowPressureOverflow=*/ForceStageVFs);
    if (!Decision.SelectFission) {
      DebugReject(getVPReductionFissionRejectReasonName(*Decision.Reason));
      continue;
    }

    // Accept a combined cut only if it saves scratch at the selected VF pair.
    if (VPlanReductionFissionCombineAddContributions) {
      auto Combined = buildReductionFissionStagePlans(
          Plan, *Analysis, *Scratch, VFs, /*CombineAddContributions=*/true);
      if (!Combined) {
        DebugReject(toString(Combined.takeError()));
      } else if (Combined->Scratch.TotalBytes < Candidate->Scratch.TotalBytes &&
                 verifyVPlanIsValid(*Combined->ProducerPlan) &&
                 verifyVPlanIsValid(*Combined->AccumulatorPlan) &&
                 verifyVPlanIsValid(*Combined->ProducerRemainder.Plan) &&
                 verifyVPlanIsValid(*Combined->AccumulatorRemainder.Plan)) {
        ElementCount PVF = Decision.Fission->ProducerVF;
        ElementCount AVF = Decision.Fission->AccumulatorVF;
        if (isLegalReductionFissionVF(*Combined->ProducerPlan, PVF, TTI) &&
            isLegalReductionFissionVF(*Combined->AccumulatorPlan, AVF, TTI)) {
          VPFissionVFPressure PP{PVF, calculateRegisterPressureForPlan(
                                          *Combined->ProducerPlan, PVF, TTI)};
          VPFissionVFPressure AP{
              AVF, calculateRegisterPressureForPlan(*Combined->AccumulatorPlan,
                                                    AVF, TTI)};
          auto CombinedDecision = selectReductionFissionConfiguration(
              ActualBaselineVF, BaselinePressure, {PP}, {AP},
              Combined->Scratch.TotalBytes,
              VPlanReductionFissionMaxScratchBytes,
              Combined->Partition.DuplicatedRecipeCount,
              VPlanReductionFissionMaxDuplicatedRecipes,
              /*AllowPressureOverflow=*/ForceStageVFs);
          if (CombinedDecision.SelectFission) {
            DEBUG_WITH_TYPE(
                "vplan-reduction-fission",
                dbgs()
                    << "LV-FISSION: combined-add-contributions: scratch-bytes="
                    << Candidate->Scratch.TotalBytes << " -> "
                    << Combined->Scratch.TotalBytes << "\n");
            *Candidate = std::move(*Combined);
          } else {
            DebugReject(getVPReductionFissionRejectReasonName(
                *CombinedDecision.Reason));
          }
        }
      }
    }

    Candidate->Selected = Decision.Fission;
    uint64_t SelectedScratchBytes = Candidate->Scratch.TotalBytes;
    DEBUG_WITH_TYPE(
        "vplan-reduction-fission",
        dbgs() << "LV-FISSION: "
               << OrigLoop->getHeader()->getParent()->getName()
               << ": candidate: reductions=" << Analysis->Slices.size()
               << " scratch-bytes=" << SelectedScratchBytes
               << " baseline-vf=" << Decision.BaselineVF
               << " producer-vf=" << Decision.Fission->ProducerVF
               << " accumulator-vf=" << Decision.Fission->AccumulatorVF
               << "\n");
    LLVM_DEBUG(dbgs() << "LV: retained atomic reduction-fission candidate: "
                      << "producer VF " << Decision.Fission->ProducerVF
                      << ", accumulator VF " << Decision.Fission->AccumulatorVF
                      << "\n");
    return std::move(*Candidate);
  }
  return std::nullopt;
}

// Prepare only the supported, full-chunk stage plans. Their bounds and the
// scalar resume values are bound by the executor; no baseline runtime checks or
// epilogue-vectorization policy is inherited here.
static VPBasicBlock *prepareStage(VPlan &Plan, ElementCount VF,
                                  PredicatedScalarEvolution &PSE) {
  Plan.setVF(VF);
  VPBasicBlock *VectorPH = Plan.getVectorPreheader();
  VPlanTransforms::unrollByUF(Plan, 1);
  VPlanTransforms::materializePacksAndUnpacks(Plan);
  VPlanTransforms::materializeBroadcasts(Plan);
  VPlanTransforms::replicateByVF(Plan, VF);
  // The caller owns the stage bounds. In particular, never fold the scalar
  // stage's backedge using the original constant trip count: it starts at the
  // runtime rounded-down vector bound.
  VPlanTransforms::simplifyRecipes(Plan);
  VPlanTransforms::removeDeadRecipes(Plan);
  VPlanTransforms::convertToConcreteRecipes(Plan);
  VPlanTransforms::dissolveLoopRegions(Plan);
  VPlanTransforms::materializeBackedgeTakenCount(Plan, VectorPH);
  VPlanTransforms::materializeFactors(Plan, VectorPH, VF);
  VPlanTransforms::expandSCEVsToVPInstructions(Plan, *PSE.getSE());
  VPlanTransforms::simplifyRecipes(Plan);
  VPlanTransforms::removeDeadRecipes(Plan);
  assert(verifyVPlanIsValid(Plan) && "invalid prepared fission stage");
  return VectorPH;
}

static void prepareCandidate(VPReductionFissionCandidate &C,
                             PredicatedScalarEvolution &PSE) {
  C.ProducerMiddle = C.ProducerPlan->getMiddleBlock();
  C.AccumulatorMiddle = C.AccumulatorPlan->getMiddleBlock();
  C.ProducerVectorPH =
      prepareStage(*C.ProducerPlan, C.Selected->ProducerVF, PSE);
  C.AccumulatorVectorPH =
      prepareStage(*C.AccumulatorPlan, C.Selected->AccumulatorVF, PSE);
  for (auto *R : {&C.ProducerRemainder, &C.AccumulatorRemainder}) {
    R->Middle = R->Plan->getMiddleBlock();
    R->Preheader = prepareStage(*R->Plan, ElementCount::getFixed(1), PSE);
  }
}

// Stage wrappers start empty: the only instructions moved here were created
// by stage preparation, and the existing IR blocks contain only branches.
static void bindStageBlock(VPlan &Plan, VPBasicBlock *VPBB, BasicBlock *IRBB) {
  auto *Wrapper = Plan.createEmptyVPIRBasicBlock(IRBB);
  for (auto &R : make_early_inc_range(*VPBB))
    R.moveBefore(*Wrapper, Wrapper->end());
  VPBlockUtils::reassociateBlocks(VPBB, Wrapper);
}

static void
executeReductionFissionCandidate(VPReductionFissionCandidate &Candidate,
                                 VPReductionFissionContext &Context) {
  const VPFissionConfiguration &Config = *Candidate.Selected;
  Loop *OrigLoop = &Context.L;
  auto *LI = &Context.LI;
  auto *DT = &Context.DT;
  auto *ORE = &Context.ORE;
  const auto &TTI = Context.TTI;
  IRBuilder<> Builder(OrigLoop->getHeader()->getContext());
  Function *F = OrigLoop->getHeader()->getParent();
  BasicBlock *OriginalPreheader = OrigLoop->getLoopPreheader();
  BasicBlock *OriginalHeader = OrigLoop->getHeader();
  BasicBlock *OriginalExit = OrigLoop->getUniqueExitBlock();
  assert(OriginalPreheader && OriginalExit &&
         "reduction fission requires a preheader and unique exit");

  IRBuilder<> EntryBuilder(&*F->getEntryBlock().getFirstInsertionPt());
  SmallVector<AllocaInst *, 4> ScratchAllocas;
  for (const VPScratchSlot &Slot : Candidate.Scratch.Slots) {
    auto *StorageTy = ArrayType::get(Slot.ElementType, Slot.ElementCount);
    AllocaInst *Storage =
        EntryBuilder.CreateAlloca(StorageTy, nullptr, "fission.scratch");
    Storage->setAlignment(Slot.Alignment);
    ScratchAllocas.push_back(Storage);
  }

  LLVMContext &Ctx = F->getContext();
  BasicBlock *ProducerPH =
      BasicBlock::Create(Ctx, "vector.fission.producer.ph", F, OriginalHeader);
  BasicBlock *ProducerExitPH = BasicBlock::Create(
      Ctx, "vector.fission.producer.exit.ph", F, OriginalHeader);
  BasicBlock *AccumulatorPH = BasicBlock::Create(
      Ctx, "vector.fission.accumulator.ph", F, OriginalHeader);
  BasicBlock *AccumulatorExitPH = BasicBlock::Create(
      Ctx, "vector.fission.accumulator.exit.ph", F, OriginalHeader);
  BasicBlock *FissionDone =
      BasicBlock::Create(Ctx, "vector.fission.done", F, OriginalHeader);
  if (Loop *Parent = OrigLoop->getParentLoop())
    for (BasicBlock *BB : {ProducerPH, ProducerExitPH, AccumulatorPH,
                           AccumulatorExitPH, FissionDone})
      Parent->addBasicBlockToLoop(BB, *LI);
  UncondBrInst::Create(ProducerExitPH, ProducerPH);
  UncondBrInst::Create(AccumulatorPH, ProducerExitPH);
  UncondBrInst::Create(AccumulatorExitPH, AccumulatorPH);
  UncondBrInst::Create(FissionDone, AccumulatorExitPH);
  UncondBrInst::Create(OriginalExit, FissionDone);
  auto *PreheaderBranch = OriginalPreheader->getTerminator();
  for (unsigned I = 0; I != PreheaderBranch->getNumSuccessors(); ++I)
    if (PreheaderBranch->getSuccessor(I) == OriginalHeader)
      PreheaderBranch->setSuccessor(I, ProducerPH);
  for (PHINode &Phi : OriginalHeader->phis())
    Phi.removeIncomingValue(OriginalPreheader, /*DeletePHIIfEmpty=*/false);
  DT->recalculate(*F);

  auto ExecuteStage = [&](VPlan &Plan, ElementCount VF, VPBasicBlock *VectorPH,
                          VPBasicBlock *Middle, BasicBlock *Incoming,
                          BasicBlock *StagePH, BasicBlock *StageExitPH,
                          BasicBlock *Continuation, StringRef BodyName,
                          Value *End, Value *Start) {
    cast<VPIRBasicBlock>(Plan.getEntry())->setIRBasicBlock(Incoming);
    Plan.getScalarHeader()->setIRBasicBlock(Continuation);
    cast<VPBasicBlock>(VectorPH->getSingleSuccessor())->setName(BodyName);
    Middle->setName((BodyName + ".middle").str());

    VPTransformState State(&TTI, VF, LI, DT, &Context.AC, Builder, &Plan,
                           OrigLoop->getParentLoop());
    IRBuilderBase &B = State.Builder;
    B.SetInsertPoint(StagePH->getTerminator());
    if (Start) {
      auto *IV = cast<VPPhi>(
          &*cast<VPBasicBlock>(VectorPH->getSingleSuccessor())->begin());
      IV->setOperand(0, Plan.getOrAddLiveIn(Start));
    }
    State.CFG.PrevBB = StagePH;
    Plan.getVectorTripCount().replaceAllUsesWith(Plan.getOrAddLiveIn(End));
    ReversePostOrderTraversal<VPBlockShallowTraversalWrapper<VPBlockBase *>>
        RPOT(Plan.getEntry());
    for (VPBasicBlock *VPBB : VPBlockUtils::blocksOnly<VPBasicBlock>(RPOT))
      for (VPRecipeBase &R : *VPBB) {
        unsigned SlotID;
        if (auto *Load = dyn_cast<VPFissionScratchLoadRecipe>(&R))
          SlotID = Load->getSlotID();
        else if (auto *Store = dyn_cast<VPFissionScratchStoreRecipe>(&R))
          SlotID = Store->getSlotID();
        else
          continue;
        R.setOperand(0, Plan.getOrAddLiveIn(ScratchAllocas[SlotID]));
      }

    bindStageBlock(Plan, VectorPH, StagePH);
    bindStageBlock(Plan, Plan.getScalarPreheader(), StageExitPH);
    Plan.execute(&State);
    if (VPBasicBlock *Header = vputils::getFirstLoopHeader(Plan, State.VPDT)) {
      Loop *StageLoop = LI->getLoopFor(State.CFG.VPBB2IRBB[Header]);
      MDNode *OriginalID = OrigLoop->getLoopID();
      auto Followup = makeFollowupLoopID(
          OriginalID,
          {"llvm.loop.vectorize.followup_all",
           VF.isScalar() ? "llvm.loop.vectorize.followup_epilogue"
                         : "llvm.loop.vectorize.followup_vectorized"});
      if (Followup)
        StageLoop->setLoopID(*Followup);
      else {
        if (OriginalID)
          StageLoop->setLoopID(OriginalID);
        LoopVectorizeHints Hints(StageLoop, true, *ORE);
        Hints.setAlreadyVectorized();
      }
      // Disable further transformation of a runtime-sized scalar remainder.
      if (VF.isScalar())
        StageLoop->addStringLoopAttribute("llvm.loop.unroll.runtime.disable");
    }
  };

  auto ExecuteWithRemainder = [&](VPlan &Plan, ElementCount VF,
                                  VPBasicBlock *VectorPH, VPBasicBlock *Middle,
                                  VPFissionScalarRemainder &Remainder,
                                  BasicBlock *Incoming, BasicBlock *StagePH,
                                  BasicBlock *StageExitPH,
                                  BasicBlock *Continuation, StringRef Name) {
    auto CreateBlock = [&](const Twine &Suffix) {
      BasicBlock *BB = BasicBlock::Create(
          Ctx, "scalar.fission." + Name + Suffix, F, Continuation);
      if (Loop *Parent = OrigLoop->getParentLoop())
        Parent->addBasicBlockToLoop(BB, *LI);
      return BB;
    };
    BasicBlock *ScalarCheck = CreateBlock(".check");
    BasicBlock *ScalarPH = CreateBlock(".ph");
    BasicBlock *ScalarExit = CreateBlock(".exit");
    UncondBrInst::Create(ScalarPH, ScalarCheck);
    UncondBrInst::Create(ScalarExit, ScalarPH);
    UncondBrInst::Create(Continuation, ScalarExit);
    cast<UncondBrInst>(StageExitPH->getTerminator())->setSuccessor(ScalarCheck);
    IRBuilder<> B(Incoming->getTerminator());
    Value *TripCount = Plan.getTripCount()->getLiveInIRValue();
    Value *RuntimeVF = getRuntimeVF(B, TripCount->getType(), VF);
    Value *VectorTC = B.CreateSub(TripCount, B.CreateURem(TripCount, RuntimeVF),
                                  "fission.vector.trip.count");
    DT->recalculate(*F);
    ExecuteStage(Plan, VF, VectorPH, Middle, Incoming, StagePH, StageExitPH,
                 ScalarCheck, ("vector.fission." + Name + ".body").str(),
                 VectorTC, nullptr);

    B.SetInsertPoint(Incoming->getTerminator());
    Value *SkipVector =
        B.CreateICmpEQ(VectorTC, ConstantInt::get(TripCount->getType(), 0));
    ReplaceInstWithInst(Incoming->getTerminator(),
                        CondBrInst::Create(SkipVector, ScalarCheck, StagePH));
    SmallVector<Value *, 8> ResumeValues;
    B.SetInsertPoint(ScalarCheck->getTerminator());
    for (auto &Reduction : Remainder.Reductions) {
      Value *VectorResult = Reduction.VectorExport->getResult();
      Value *Initial = Reduction.Start->getLiveInIRValue();
      auto *Resume = B.CreatePHI(Initial->getType(), 2, "fission.resume.rdx");
      Resume->addIncoming(Initial, Incoming);
      Resume->addIncoming(VectorResult, StageExitPH);
      Reduction.ScalarPhi->setOperand(0,
                                      Remainder.Plan->getOrAddLiveIn(Resume));
      ResumeValues.push_back(Resume);
    }
    DT->recalculate(*F);
    ExecuteStage(
        *Remainder.Plan, ElementCount::getFixed(1), Remainder.Preheader,
        Remainder.Middle, ScalarCheck, ScalarPH, ScalarExit, Continuation,
        ("scalar.fission." + Name + ".body").str(), TripCount, VectorTC);
    B.SetInsertPoint(ScalarCheck->getTerminator());
    Value *SkipScalar = B.CreateICmpEQ(VectorTC, TripCount);
    ReplaceInstWithInst(ScalarCheck->getTerminator(),
                        CondBrInst::Create(SkipScalar, Continuation, ScalarPH));
    DenseMap<VPValue *, Value *> Results;
    B.SetInsertPoint(&*Continuation->getFirstInsertionPt());
    for (auto [Reduction, Resume] : zip(Remainder.Reductions, ResumeValues)) {
      Value *ScalarResult = Reduction.ScalarExport->getResult();
      auto *Result = B.CreatePHI(Resume->getType(), 2, "fission.result");
      Result->addIncoming(Resume, ScalarCheck);
      Result->addIncoming(ScalarResult, ScalarExit);
      Results[Reduction.VectorResult] = Result;
    }
    DT->recalculate(*F);
    return Results;
  };

  ExecuteWithRemainder(*Candidate.ProducerPlan, Config.ProducerVF,
                       Candidate.ProducerVectorPH, Candidate.ProducerMiddle,
                       Candidate.ProducerRemainder, OriginalPreheader,
                       ProducerPH, ProducerExitPH, AccumulatorPH, "producer");

  // The accumulator needs its own incoming check block: the producer's scalar
  // exit is not executed on the no-remainder path.
  BasicBlock *AccumulatorVectorPH =
      SplitBlock(AccumulatorPH, AccumulatorPH->getTerminator(), DT, LI, nullptr,
                 "vector.fission.accumulator.vector.ph");
  auto AccumulatorResults = ExecuteWithRemainder(
      *Candidate.AccumulatorPlan, Config.AccumulatorVF,
      Candidate.AccumulatorVectorPH, Candidate.AccumulatorMiddle,
      Candidate.AccumulatorRemainder, AccumulatorPH, AccumulatorVectorPH,
      AccumulatorExitPH, FissionDone, "accumulator");
  for (auto [ExitPhi, StageValue] : Candidate.AccumulatorLiveOuts) {
    Value *Result = AccumulatorResults.lookup(StageValue);
    assert(Result && "missing fission remainder live-out");
    ExitPhi->addIncoming(Result, FissionDone);
  }
  DT->recalculate(*F);
  // All original live-outs now have an incoming fission result. Remove the
  // unreachable scalar loop only after updating every exit and invalidating SE.
  auto &SE = *Context.PSE.getSE();
  for (PHINode &Phi : OriginalExit->phis()) {
    SE.forgetValue(&Phi);
    Phi.removeIncomingValue(OriginalHeader, /*DeletePHIIfEmpty=*/false);
  }
  SE.forgetLoop(OrigLoop);
  SE.forgetBlockAndLoopDispositions();
  LI->erase(OrigLoop);
  LI->removeBlock(OriginalHeader);
  OriginalHeader->dropAllReferences();
  OriginalHeader->eraseFromParent();
  DT->recalculate(*F);
}

bool llvm::tryReductionFission(ArrayRef<VPlanPtr> Plans,
                               ElementCount BaselineVF,
                               VPReductionFissionContext &Context) {
  if (!EnableVPlanReductionFission)
    return false;
  auto Candidate = planReductionFission(Plans, BaselineVF, Context);
  if (!Candidate)
    return false;
  prepareCandidate(*Candidate, Context.PSE);
  executeReductionFissionCandidate(*Candidate, Context);
  return true;
}
