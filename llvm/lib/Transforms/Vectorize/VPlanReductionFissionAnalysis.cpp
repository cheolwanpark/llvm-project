//===- VPlanReductionFissionAnalysis.cpp - Fission analysis ---------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "VPlan.h"
#include "VPlanCFG.h"
#include "VPlanHelpers.h"
#include "VPlanReductionFission.h"
#include "VPlanUtils.h"
#include "llvm/ADT/PostOrderIterator.h"
#include "llvm/Analysis/TargetTransformInfo.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/Analysis/VectorUtils.h"
#include "llvm/IR/AttributeMask.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/MathExtras.h"
#include <functional>

using namespace llvm;

#define DEBUG_TYPE "vplan-reduction-fission"

namespace {

void collectVPProducerSliceImpl(
    VPValue &Value, SmallPtrSetImpl<const VPRecipeBase *> &Slice,
    SmallPtrSetImpl<const VPRecipeBase *> &Recurrences,
    const SmallPtrSetImpl<const VPRecipeBase *> *AllowedRecipes) {
  const VPRecipeBase *Recipe = Value.getDefiningRecipe();
  if (!Recipe)
    return;
  if (isa<VPHeaderPHIRecipe>(Recipe)) {
    Recurrences.insert(Recipe);
    return;
  }
  if ((AllowedRecipes && !AllowedRecipes->contains(Recipe)) ||
      !Slice.insert(Recipe).second)
    return;
  for (VPValue *Operand : Recipe->operands())
    collectVPProducerSliceImpl(*Operand, Slice, Recurrences, AllowedRecipes);
}

} // namespace

void llvm::collectVPProducerSlice(
    VPValue &Root, SmallPtrSetImpl<const VPRecipeBase *> &Slice,
    SmallPtrSetImpl<const VPRecipeBase *> &Recurrences) {
  collectVPProducerSliceImpl(Root, Slice, Recurrences, nullptr);
}

VPDependencyMetrics llvm::calculateVPDependencyMetrics(
    VPValue &Root,
    const SmallPtrSetImpl<const VPRecipeBase *> *AllowedRecipes) {
  SmallPtrSet<const VPRecipeBase *, 16> Slice;
  SmallPtrSet<const VPRecipeBase *, 4> Recurrences;
  collectVPProducerSliceImpl(Root, Slice, Recurrences, AllowedRecipes);

  DenseMap<const VPRecipeBase *, unsigned> Depths;
  std::function<unsigned(const VPRecipeBase *)> CalculateDepth =
      [&](const VPRecipeBase *Recipe) -> unsigned {
    auto It = Depths.find(Recipe);
    if (It != Depths.end())
      return It->second;

    unsigned OperandDepth = 0;
    for (VPValue *Operand : Recipe->operands()) {
      const VPRecipeBase *OperandRecipe = Operand->getDefiningRecipe();
      if (OperandRecipe && Slice.contains(OperandRecipe))
        OperandDepth = std::max(OperandDepth, CalculateDepth(OperandRecipe));
    }
    unsigned Depth = OperandDepth + 1;
    Depths.insert({Recipe, Depth});
    return Depth;
  };

  VPDependencyMetrics Metrics;
  Metrics.RecipeCount = Slice.size();
  Metrics.RecurrenceCount = Recurrences.size();
  SmallVector<unsigned, 8> LevelWidths(1, 0);
  for (const VPRecipeBase *Recipe : Slice) {
    unsigned Depth = CalculateDepth(Recipe);
    Metrics.CriticalPathDepth = std::max(Metrics.CriticalPathDepth, Depth);
    if (LevelWidths.size() <= Depth)
      LevelWidths.resize(Depth + 1, 0);
    ++LevelWidths[Depth];

    bool HasRecipeDependency = any_of(Recipe->operands(), [&](VPValue *Op) {
      const VPRecipeBase *Def = Op->getDefiningRecipe();
      return Def && Slice.contains(Def);
    });
    Metrics.IndependentRootCount += !HasRecipeDependency;
  }
  for (unsigned Width : LevelWidths)
    Metrics.MaxLevelWidth = std::max(Metrics.MaxLevelWidth, Width);
  return Metrics;
}

bool VPRegisterPressureBreakdown::hasAccumulatorCausedOverflow() const {
  return any_of(AccumulatorOverlapSurplus,
                [](const auto &Entry) { return Entry.second != 0; });
}

bool VPRegisterPressureBreakdown::exceedsCapacity() const {
  return any_of(PeakTotalRegs, [&](const auto &Entry) {
    return Entry.second > Capacity.lookup(Entry.first);
  });
}

VPRegisterPressureBreakdown llvm::calculateRegisterPressureForPlan(
    VPlan &Plan, ElementCount VF, const TargetTransformInfo &TTI,
    const VPRegisterPressureOptions &Options) {
  SmallVector<VPRecipeBase *, 64> Recipes;
  ReversePostOrderTraversal<VPBlockDeepTraversalWrapper<VPBlockBase *>> RPOT(
      Plan.getVectorLoopRegion());
  for (VPBasicBlock *VPBB : VPBlockUtils::blocksOnly<VPBasicBlock>(RPOT)) {
    if (!VPBB->getParent())
      break;
    for (VPRecipeBase &Recipe : *VPBB)
      if (!Options.AllowedRecipes || Options.AllowedRecipes->contains(&Recipe))
        Recipes.push_back(&Recipe);
    if (VPBB == Plan.getVectorLoopRegion()->getExiting())
      break;
  }

  DenseMap<const VPRecipeBase *, unsigned> RecipeIndices;
  DenseMap<const VPRecipeBase *, unsigned> LastUses;
  for (auto [Index, Recipe] : enumerate(Recipes))
    RecipeIndices[Recipe] = Index;
  for (auto [Index, Recipe] : enumerate(Recipes))
    for (VPValue *Operand : Recipe->operands())
      if (const VPRecipeBase *Def = Operand->getDefiningRecipe();
          RecipeIndices.contains(Def))
        LastUses[Def] = Index;
  const auto LastBodyUses = LastUses;
  // Middle-block reduction finalization (and other live-outs) consumes values
  // after the last body recipe. Keep these intervals open through loop exit.
  for (VPRecipeBase *Recipe : Recipes)
    for (VPValue *Def : Recipe->definedValues())
      if (any_of(Def->users(), [&](VPUser *U) {
            return !RecipeIndices.contains(cast<VPRecipeBase>(U));
          }))
        LastUses[Recipe] = Recipes.size();

  auto AddValueUsage = [&](VPValue *Def,
                           SmallMapVector<unsigned, unsigned, 4> &Usage) {
    // LLVM 23 models the scalar canonical IV as a region value, not a PHI
    // recipe. Do not mistake it for a vector loop-invariant live-in.
    if (Def == Plan.getVectorLoopRegion()->getCanonicalIV())
      return;
    Type *ScalarTy = Def->getScalarType();
    unsigned ClassID = TTI.getRegisterClassForType(true, ScalarTy);
    if (!VectorType::isValidElementType(ScalarTy) ||
        (VF.isScalable() && !ScalarTy->isIntegerTy(1) &&
         !TTI.isElementTypeLegalForScalableVector(ScalarTy)))
      return;
    unsigned Registers = TTI.getRegUsageForType(VectorType::get(ScalarTy, VF));
    Usage[ClassID] = SaturatingAdd(Usage[ClassID], Registers);
  };
  auto AddRecipeUsage = [&](const VPRecipeBase *Recipe,
                            SmallMapVector<unsigned, unsigned, 4> &Usage) {
    if (isa<VPDerivedIVRecipe, VPScalarIVStepsRecipe>(Recipe))
      return;
    for (VPValue *Def : Recipe->definedValues()) {
      // Scalar addresses, canonical indices and loop-control values do not
      // occupy vector register groups. This analysis models vector pressure.
      if (!isa<VPReductionPHIRecipe, VPWidenLoadRecipe>(Recipe) &&
          vputils::onlyFirstLaneUsed(Def))
        continue;
      AddValueUsage(Def, Usage);
    }
  };

  VPRegisterPressureBreakdown Result;
  // Live-ins can be rematerialized, so do not make the union of every splat
  // live across the whole loop. Account for the maximum number consumed by a
  // single recipe instead. This catches multi-operand FMA temporaries without
  // pessimistically keeping unrelated constants alive together.
  for (VPRecipeBase *Recipe : Recipes) {
    SmallPtrSet<VPValue *, 4> RecipeInvariantValues;
    SmallMapVector<unsigned, unsigned, 4> RecipeInvariantUsage;
    for (VPValue *Operand : Recipe->operands())
      if (!Operand->getDefiningRecipe() && !Recipe->usesScalars(Operand) &&
          RecipeInvariantValues.insert(Operand).second)
        AddValueUsage(Operand, RecipeInvariantUsage);
    for (const auto &Entry : RecipeInvariantUsage)
      Result.LoopInvariantRegs[Entry.first] =
          std::max(Result.LoopInvariantRegs[Entry.first], Entry.second);
  }
  // Explicit preheader vector definitions are not scalar splats that this
  // model can rematerialize on demand. Keep their union live, excluding PHI
  // initialization, whose storage is already charged to the accumulator.
  SmallPtrSet<VPValue *, 8> ExternalVectors;
  for (VPRecipeBase *Recipe : Recipes) {
    if (isa<VPHeaderPHIRecipe>(Recipe))
      continue;
    for (VPValue *Operand : Recipe->operands())
      if (const VPRecipeBase *Def = Operand->getDefiningRecipe();
          Def && !RecipeIndices.contains(Def) &&
          !Recipe->usesFirstLaneOnly(Operand) &&
          ExternalVectors.insert(Operand).second)
        AddValueUsage(Operand, Result.LoopInvariantRegs);
  }

  SmallPtrSet<const VPReductionPHIRecipe *, 8> DiscoveredAccumulators;
  const SmallPtrSetImpl<const VPReductionPHIRecipe *> *LoopLiveAccumulators =
      Options.LoopLiveAccumulators;
  if (!LoopLiveAccumulators && Options.TreatReductionsAsLoopLive) {
    for (VPRecipeBase *Recipe : Recipes)
      if (auto *Accumulator = dyn_cast<VPReductionPHIRecipe>(Recipe))
        DiscoveredAccumulators.insert(Accumulator);
    LoopLiveAccumulators = &DiscoveredAccumulators;
  }
  if (LoopLiveAccumulators)
    for (const VPReductionPHIRecipe *Accumulator : *LoopLiveAccumulators)
      if (!Options.AllowedRecipes ||
          Options.AllowedRecipes->contains(Accumulator))
        AddRecipeUsage(Accumulator, Result.AccumulatorRegs);

  DenseMap<const VPRecipeBase *, unsigned> AccumulatorBackedgeUpdates;
  if (LoopLiveAccumulators)
    for (const VPReductionPHIRecipe *Accumulator : *LoopLiveAccumulators)
      if (Accumulator->getNumOperands() > 1)
        if (const VPRecipeBase *Update =
                Accumulator->getOperand(1)->getDefiningRecipe())
          AccumulatorBackedgeUpdates[Update] =
              std::max(AccumulatorBackedgeUpdates.lookup(Update),
                       LastBodyUses.lookup(Accumulator));

  for (const auto &Entry : Result.AccumulatorRegs)
    Result.Capacity[Entry.first] = TTI.getNumberOfRegisters(Entry.first);

  for (unsigned Index = 0; Index < Recipes.size(); ++Index) {
    SmallMapVector<unsigned, unsigned, 4> NonAccumulatorUsage;
    for (const auto &Entry : Result.LoopInvariantRegs)
      NonAccumulatorUsage[Entry.first] = 0;
    for (VPRecipeBase *Recipe : Recipes) {
      if (LoopLiveAccumulators && LoopLiveAccumulators->contains(
                                      dyn_cast<VPReductionPHIRecipe>(Recipe)))
        continue;
      auto DefIt = RecipeIndices.find(Recipe);
      auto UseIt = LastUses.find(Recipe);
      if (auto It = AccumulatorBackedgeUpdates.find(Recipe);
          It != AccumulatorBackedgeUpdates.end()) {
        // A backedge update may reuse the loop-live accumulator register only
        // after the previous value dies. Tail selects can keep both alive.
        if (It->second <= DefIt->second || Index > It->second)
          continue;
      }
      // Include a value at its definition point. Its output register overlaps
      // the recipe operands while the instruction is being formed; omitting
      // that point underestimates precisely the peak that causes spills in a
      // wide reduction loop.
      if (DefIt == RecipeIndices.end() || UseIt == LastUses.end() ||
          DefIt->second > Index || UseIt->second < Index)
        continue;
      AddRecipeUsage(Recipe, NonAccumulatorUsage);
    }

    for (const auto &Entry : NonAccumulatorUsage) {
      unsigned ClassID = Entry.first;
      unsigned NonAccumulator =
          SaturatingAdd(Entry.second, Result.LoopInvariantRegs.lookup(ClassID));
      Result.PeakNonAccumulatorRegs[ClassID] =
          std::max(Result.PeakNonAccumulatorRegs[ClassID], NonAccumulator);
      unsigned Total =
          SaturatingAdd(NonAccumulator, Result.AccumulatorRegs[ClassID]);
      Result.PeakTotalRegs[ClassID] =
          std::max(Result.PeakTotalRegs[ClassID], Total);
      unsigned Capacity = TTI.getNumberOfRegisters(ClassID);
      Result.Capacity[ClassID] = Capacity;
      if (NonAccumulator <= Capacity && Total > Capacity)
        Result.AccumulatorOverlapSurplus[ClassID] = std::max(
            Result.AccumulatorOverlapSurplus[ClassID], Total - Capacity);
    }
  }

  // A loop containing only accumulators still has their loop-live pressure.
  for (const auto &Entry : Result.AccumulatorRegs) {
    unsigned ClassID = Entry.first;
    unsigned Total =
        SaturatingAdd(Entry.second, Result.LoopInvariantRegs.lookup(ClassID));
    Result.PeakTotalRegs[ClassID] =
        std::max(Result.PeakTotalRegs[ClassID], Total);
    unsigned Capacity = Result.Capacity.lookup(ClassID);
    if (Total > Capacity)
      Result.AccumulatorOverlapSurplus[ClassID] =
          std::max(Result.AccumulatorOverlapSurplus[ClassID], Total - Capacity);
  }
  return Result;
}

bool llvm::isLegalReductionFissionVF(VPlan &Plan, ElementCount VF,
                                     const TargetTransformInfo &TTI) {
  if (!VF.isVector() || Plan.hasEarlyExit())
    return false;
  VPBasicBlock *Body = Plan.getVectorLoopRegion()->getEntryBasicBlock();
  if (Body != Plan.getVectorLoopRegion()->getExitingBasicBlock())
    return false;
  SmallVector<VPRecipeBase *, 64> Recipes;
  for (VPBasicBlock *Block : {Plan.getVectorPreheader(), Body})
    for (VPRecipeBase &R : *Block)
      Recipes.push_back(&R);
  for (VPRecipeBase *Recipe : Recipes) {
    VPRecipeBase &R = *Recipe;
    // These forms are parametric in VF. Other forms (replication, interleave
    // groups, scaled/ordered reductions, recurrences) need separate replanning.
    if (!isa<VPInstruction, VPReductionPHIRecipe, VPWidenRecipe,
             VPWidenCastRecipe, VPWidenGEPRecipe, VPWidenLoadRecipe,
             VPWidenCallRecipe, VPWidenIntrinsicRecipe,
             VPWidenCanonicalIVRecipe, VPScalarIVStepsRecipe, VPDerivedIVRecipe,
             VPVectorPointerRecipe, VPReplicateRecipe,
             VPFissionScratchLoadRecipe, VPFissionScratchStoreRecipe>(R)) {
      LLVM_DEBUG({
        dbgs() << "LV-FISSION: unsupported recipe at VF " << VF << "\n";
        R.dump();
      });
      return false;
    }
    // Consecutive addresses are represented by a uniform scalar GEP even in
    // an otherwise fully widened plan. Do not admit lane-wise replication.
    if (auto *Replicate = dyn_cast<VPReplicateRecipe>(&R))
      if (!Replicate->isSingleScalar() || Replicate->isPredicated() ||
          !isa<GetElementPtrInst>(Replicate->getUnderlyingValue()))
        return false;
    if (auto *Phi = dyn_cast<VPReductionPHIRecipe>(&R)) {
      if (Phi->isInLoop() || Phi->isOrdered() || Phi->getVFScaleFactor() != 1 ||
          Phi->getRecurrenceKind() == RecurKind::AnyOf ||
          RecurrenceDescriptor::isFindIVRecurrenceKind(
              Phi->getRecurrenceKind()))
        return false;
    }
    // Stage tails may replace operands with zero or poison in inactive lanes.
    if (isa<VPWidenRecipe, VPWidenCallRecipe, VPWidenIntrinsicRecipe>(R))
      if (auto *I = dyn_cast_or_null<Instruction>(
              cast<VPSingleDefRecipe>(&R)->getUnderlyingValue());
          I && !isSafeToSpeculativelyExecuteWithVariableReplaced(
                   I, /*IgnoreUBImplyingAttrs=*/false))
        return false;
    if (auto *I = dyn_cast<VPInstruction>(&R))
      if (I->getOpcode() == Instruction::UDiv ||
          I->getOpcode() == Instruction::SDiv ||
          I->getOpcode() == Instruction::URem ||
          I->getOpcode() == Instruction::SRem)
        return false;
    if (auto *Call = dyn_cast<VPWidenCallRecipe>(&R)) {
      Function *Variant = Call->getVectorVariant();
      AttributeMask UBAttrs = AttributeFuncs::getUBImplyingAttributes();
      // The actual vector callee can have a stronger argument contract than
      // its scalar counterpart. Inactive lanes may be poison, so validate the
      // variant itself instead of inferring its safety from the scalar call.
      if (!Variant->isSpeculatable() || !Variant->doesNotAccessMemory() ||
          Variant->isConvergent() || Variant->cannotDuplicate() ||
          any_of(Variant->getAttributes(), [&](AttributeSet AS) {
            return AttrBuilder(Variant->getContext(), AS).overlaps(UBAttrs);
          }))
        return false;
      FunctionType *FT = Variant->getFunctionType();
      if (auto *VT = dyn_cast<VectorType>(FT->getReturnType());
          !VT || VT->getElementCount() != VF)
        return false;
      for (Type *Ty : FT->params())
        if (auto *VT = dyn_cast<VectorType>(Ty);
            VT && VT->getElementCount() != VF)
          return false;
    }
    if (auto *Intrinsic = dyn_cast<VPWidenIntrinsicRecipe>(&R)) {
      Intrinsic::ID ID = Intrinsic->getVectorIntrinsicID();
      if (!isTriviallyVectorizable(ID) || R.mayHaveSideEffects() ||
          R.mayReadFromMemory())
        return false;
      SmallVector<Type *, 4> ParamTypes;
      for (auto [I, Op] : enumerate(Intrinsic->operands())) {
        Type *Ty = Op->getScalarType();
        ParamTypes.push_back(isVectorIntrinsicWithScalarOpAtArg(ID, I, &TTI)
                                 ? Ty
                                 : VectorType::get(Ty, VF));
      }
      FastMathFlags FMF = Intrinsic->hasFastMathFlags()
                              ? Intrinsic->getFastMathFlagsOrNone()
                              : FastMathFlags();
      IntrinsicCostAttributes Attrs(
          ID, VectorType::get(Intrinsic->getScalarType(), VF), ParamTypes, FMF,
          dyn_cast_or_null<IntrinsicInst>(Intrinsic->getUnderlyingValue()));
      // Check lowering support at this VF.
      if (!TTI.getIntrinsicInstrCost(Attrs, TTI::TCK_CodeSize).isValid())
        return false;
    }
    for (VPValue *Def : R.definedValues()) {
      Type *Ty = Def->getScalarType();
      if (isa<VPDerivedIVRecipe, VPScalarIVStepsRecipe>(R) ||
          vputils::onlyFirstLaneUsed(Def))
        continue;
      if (!VectorType::isValidElementType(Ty) ||
          (VF.isScalable() && !Ty->isIntegerTy(1) &&
           !TTI.isElementTypeLegalForScalableVector(Ty)) ||
          !TTI.isTypeLegal(VectorType::get(Ty, VF))) {
        LLVM_DEBUG({
          dbgs() << "LV-FISSION: illegal vector element " << *Ty << " at VF "
                 << VF << "\n";
          R.dump();
        });
        return false;
      }
    }
    if (auto *Load = dyn_cast<VPWidenLoadRecipe>(&R)) {
      auto *Ty = VectorType::get(Load->getScalarType(), VF);
      auto *IRLoad = cast<LoadInst>(Load->getUnderlyingValue());
      if (!Load->isConsecutive() ||
          !TTI.isLegalMaskedLoad(Ty, IRLoad->getAlign(),
                                 IRLoad->getPointerAddressSpace()))
        return false;
    }
    if (auto *Load = dyn_cast<VPFissionScratchLoadRecipe>(&R))
      if (!TTI.isLegalMaskedLoad(VectorType::get(Load->getElementType(), VF),
                                 Load->getAlignment(), 0))
        return false;
    if (auto *Store = dyn_cast<VPFissionScratchStoreRecipe>(&R))
      if (!TTI.isLegalMaskedStore(VectorType::get(Store->getElementType(), VF),
                                  Store->getAlignment(), 0))
        return false;
  }
  return true;
}

StringRef llvm::getVPReductionFissionRejectReasonName(
    VPReductionFissionRejectReason Reason) {
  switch (Reason) {
  case VPReductionFissionRejectReason::NotSingleBlock:
    return "not-single-block";
  case VPReductionFissionRejectReason::EarlyExit:
    return "early-exit";
  case VPReductionFissionRejectReason::NonConstantTripCount:
    return "non-constant-trip-count";
  case VPReductionFissionRejectReason::TooFewReductions:
    return "too-few-reductions";
  case VPReductionFissionRejectReason::NoLongProducer:
    return "no-long-producer";
  case VPReductionFissionRejectReason::NoAccumulatorPressureOverflow:
    return "no-accumulator-pressure-overflow";
  case VPReductionFissionRejectReason::RuntimeMemoryCheck:
    return "runtime-memory-check";
  case VPReductionFissionRejectReason::UnsupportedRecipe:
    return "unsupported-recipe";
  case VPReductionFissionRejectReason::UnsupportedLiveOut:
    return "unsupported-live-out";
  case VPReductionFissionRejectReason::CrossPartitionDependence:
    return "cross-partition-dependence";
  case VPReductionFissionRejectReason::ScratchOverflow:
    return "scratch-overflow";
  case VPReductionFissionRejectReason::ScratchLimit:
    return "scratch-limit";
  case VPReductionFissionRejectReason::ProducerPreviewNotVectorizable:
    return "producer-preview-not-vectorizable";
  case VPReductionFissionRejectReason::AccumulatorPreviewNotVectorizable:
    return "accumulator-preview-not-vectorizable";
  case VPReductionFissionRejectReason::NoPressureSafeVF:
    return "no-pressure-safe-vf";
  case VPReductionFissionRejectReason::ProducerVFDecrease:
    return "producer-vf-decrease";
  case VPReductionFissionRejectReason::FissionPressureNotReduced:
    return "fission-pressure-not-reduced";
  }
  llvm_unreachable("unknown reduction fission rejection reason");
}

VPReductionFissionDecision llvm::selectReductionFissionConfiguration(
    ElementCount ActualBaselineVF, ArrayRef<VPFissionVFPressure> Baseline,
    ArrayRef<VPFissionVFPressure> Producer,
    ArrayRef<VPFissionVFPressure> Accumulator, uint64_t ScratchBytes,
    uint64_t MaximumScratchBytes, unsigned DuplicatedRecipeCount,
    unsigned MaximumDuplicatedRecipes, bool AllowPressureOverflow) {
  VPReductionFissionDecision Decision;
  auto LargestSafe =
      [AllowPressureOverflow](ArrayRef<VPFissionVFPressure> Candidates)
      -> const VPFissionVFPressure * {
    const VPFissionVFPressure *Best = nullptr;
    for (const VPFissionVFPressure &Candidate : Candidates) {
      // Reserve registers for masks and target-introduced temporaries.
      bool HasHeadroom =
          all_of(Candidate.Pressure.PeakTotalRegs, [&](const auto &Entry) {
            return Entry.second <
                   Candidate.Pressure.Capacity.lookup(Entry.first);
          });
      if (!HasHeadroom && !AllowPressureOverflow)
        continue;
      if (!Best ||
          Candidate.VF.getKnownMinValue() > Best->VF.getKnownMinValue())
        Best = &Candidate;
    }
    return Best;
  };

  const VPFissionVFPressure *ProducerBest = LargestSafe(Producer);
  const VPFissionVFPressure *AccumulatorBest = LargestSafe(Accumulator);
  Decision.BaselineVF = ActualBaselineVF;
  if (!ProducerBest || !AccumulatorBest) {
    Decision.Reason = VPReductionFissionRejectReason::NoPressureSafeVF;
    return Decision;
  }
  if (ScratchBytes > MaximumScratchBytes) {
    Decision.Reason = VPReductionFissionRejectReason::ScratchLimit;
    return Decision;
  }
  if (DuplicatedRecipeCount > MaximumDuplicatedRecipes) {
    Decision.Reason = VPReductionFissionRejectReason::CrossPartitionDependence;
    return Decision;
  }
  // Require a non-decreasing producer VF and lower peak pressure.
  if (!ElementCount::isKnownGE(ProducerBest->VF, ActualBaselineVF)) {
    Decision.Reason = VPReductionFissionRejectReason::ProducerVFDecrease;
    return Decision;
  }

  const VPFissionVFPressure *FusedAtProducerVF = nullptr;
  for (const VPFissionVFPressure &Candidate : Baseline)
    if (Candidate.VF == ProducerBest->VF) {
      FusedAtProducerVF = &Candidate;
      break;
    }
  if (!FusedAtProducerVF) {
    Decision.Reason = VPReductionFissionRejectReason::FissionPressureNotReduced;
    return Decision;
  }

  bool StrictlyLower = false;
  auto HasNewPressureClass = [&](const VPRegisterPressureBreakdown &Pressure) {
    return any_of(Pressure.PeakTotalRegs, [&](const auto &Entry) {
      return Entry.second != 0 &&
             !FusedAtProducerVF->Pressure.PeakTotalRegs.contains(Entry.first);
    });
  };
  if (HasNewPressureClass(ProducerBest->Pressure) ||
      HasNewPressureClass(AccumulatorBest->Pressure)) {
    Decision.Reason = VPReductionFissionRejectReason::FissionPressureNotReduced;
    return Decision;
  }
  for (const auto &Entry : FusedAtProducerVF->Pressure.PeakTotalRegs) {
    unsigned SplitPeak =
        std::max(ProducerBest->Pressure.PeakTotalRegs.lookup(Entry.first),
                 AccumulatorBest->Pressure.PeakTotalRegs.lookup(Entry.first));
    if (SplitPeak > Entry.second) {
      Decision.Reason =
          VPReductionFissionRejectReason::FissionPressureNotReduced;
      return Decision;
    }
    StrictlyLower |= SplitPeak < Entry.second;
  }
  if (!StrictlyLower) {
    Decision.Reason = VPReductionFissionRejectReason::FissionPressureNotReduced;
    return Decision;
  }

  Decision.SelectFission = true;
  Decision.Fission =
      VPFissionConfiguration{ProducerBest->VF, AccumulatorBest->VF};
  return Decision;
}

VPReductionFissionAnalysis
llvm::analyzeVPReductionFission(VPlan &Plan,
                                const VPRegisterPressureBreakdown &Pressure,
                                const VPReductionFissionConfig &Config) {
  VPReductionFissionAnalysis Result;
  SmallVector<VPRecipeBase *, 64> Recipes;
  ReversePostOrderTraversal<VPBlockDeepTraversalWrapper<VPBlockBase *>> RPOT(
      Plan.getEntry());
  for (VPBasicBlock *VPBB : VPBlockUtils::blocksOnly<VPBasicBlock>(RPOT))
    for (VPRecipeBase &Recipe : *VPBB)
      Recipes.push_back(&Recipe);

  // Reduction PHIs are supplied by LV's recurrence analysis. Propagate their
  // dependence through the existing recipe graph, rather than recognizing
  // particular spellings of the final update. Stop at the recurrence PHIs;
  // their backedges are visited separately below.
  SmallPtrSet<const VPRecipeBase *, 32> InPlan(Recipes.begin(), Recipes.end());
  SmallPtrSet<const VPRecipeBase *, 32> Dependent;
  SmallVector<VPRecipeBase *, 32> Worklist;
  for (VPRecipeBase *R : Recipes)
    if (isa<VPReductionPHIRecipe>(R)) {
      Dependent.insert(R);
      Worklist.push_back(R);
    }
  for (unsigned I = 0; I != Worklist.size(); ++I)
    for (VPValue *Def : Worklist[I]->definedValues())
      for (VPUser *U : Def->users()) {
        auto *R = dyn_cast<VPRecipeBase>(U);
        if (R && InPlan.contains(R) && !isa<VPHeaderPHIRecipe>(R) &&
            Dependent.insert(R).second)
          Worklist.push_back(R);
      }

  for (VPRecipeBase *Recipe : Recipes) {
    auto *Accumulator = dyn_cast<VPReductionPHIRecipe>(Recipe);
    if (!Accumulator || Accumulator->getNumOperands() < 2)
      continue;
    VPReductionProducerSlice Slice;
    Slice.Accumulator = Accumulator;
    SmallPtrSet<VPValue *, 8> SeenInputs;
    bool SawAccumulator = false;
    std::function<bool(VPValue *)> Visit = [&](VPValue *V) {
      if (V == Accumulator) {
        SawAccumulator = true;
        return true;
      }
      VPRecipeBase *R = V->getDefiningRecipe();
      if (!R)
        return true;
      if (isa<VPReductionPHIRecipe>(R))
        return false;
      if (!Dependent.contains(R)) {
        if (!SeenInputs.insert(V).second)
          return true;
        VPReductionProducerInput Input;
        Input.Value = V;
        SmallPtrSet<const VPRecipeBase *, 4> Recurrences;
        collectVPProducerSlice(*V, Input.Recipes, Recurrences);
        if (any_of(Recurrences, [](const VPRecipeBase *Phi) {
              return isa<VPReductionPHIRecipe>(Phi);
            }))
          return false;
        Input.Dependency = calculateVPDependencyMetrics(*V, &Input.Recipes);
        Input.IsLong = Input.Dependency.CriticalPathDepth >=
                       Config.MinimumLongProducerDepth;
        Slice.Inputs.push_back(std::move(Input));
        return true;
      }
      if (R->mayHaveSideEffects() ||
          (isa<VPReductionRecipe>(R) &&
           cast<VPReductionRecipe>(R)->isPartialReduction()))
        return false;
      if (!Slice.Updates.insert(R).second)
        return true;
      return all_of(R->operands(), Visit);
    };
    if (!Visit(Accumulator->getBackedgeValue()) || !SawAccumulator) {
      Result.RejectReason =
          VPReductionFissionRejectReason::CrossPartitionDependence;
      return Result;
    }
    Result.Slices.push_back(std::move(Slice));
  }

  if (Result.Slices.size() < Config.MinimumReductionCount) {
    Result.RejectReason = VPReductionFissionRejectReason::TooFewReductions;
    return Result;
  }
  SmallVector<const VPReductionProducerInput *, 16> Inputs;
  for (const auto &Slice : Result.Slices)
    for (const auto &Input : Slice.Inputs)
      Inputs.push_back(&Input);
  if (!any_of(Inputs, [](const auto *Input) { return Input->IsLong; })) {
    Result.RejectReason = VPReductionFissionRejectReason::NoLongProducer;
    return Result;
  }
  if (!Pressure.hasAccumulatorCausedOverflow()) {
    Result.RejectReason =
        VPReductionFissionRejectReason::NoAccumulatorPressureOverflow;
    return Result;
  }

  SmallPtrSet<VPValue *, 8> SeenFrontier;
  DenseMap<const VPRecipeBase *, unsigned> LongSliceMembership;
  for (const auto *Input : Inputs)
    if (Input->IsLong)
      for (const VPRecipeBase *Recipe : Input->Recipes)
        ++LongSliceMembership[Recipe];

  SmallPtrSet<const VPRecipeBase *, 32> SharedLongRecipes;
  for (const auto &[Recipe, Membership] : LongSliceMembership)
    if (Membership > 1)
      SharedLongRecipes.insert(Recipe);

  // Cut at the last shared values to avoid materializing private suffixes.
  for (const VPRecipeBase *Recipe : Recipes) {
    if (!SharedLongRecipes.contains(Recipe))
      continue;
    // Keep shared input loads in the accumulator stage.
    if (Recipe->mayReadFromMemory())
      continue;
    for (VPValue *Def : Recipe->definedValues()) {
      bool CrossesToSuffix = any_of(Def->users(), [&](VPUser *User) {
        auto *UserRecipe = dyn_cast<VPRecipeBase>(User);
        return UserRecipe && !SharedLongRecipes.contains(UserRecipe) &&
               LongSliceMembership.contains(UserRecipe);
      });
      bool IsLong = calculateVPDependencyMetrics(*Def).CriticalPathDepth >=
                    Config.MinimumLongProducerDepth;
      if (CrossesToSuffix && IsLong && SeenFrontier.insert(Def).second)
        Result.Partition.FrontierValues.push_back(Def);
    }
  }

  // Build the producer from the dependency closure of the cut values.
  for (VPValue *Frontier : Result.Partition.FrontierValues) {
    SmallPtrSet<const VPRecipeBase *, 4> Recurrences;
    SmallPtrSet<const VPRecipeBase *, 16> FrontierSlice;
    collectVPProducerSlice(*Frontier, FrontierSlice, Recurrences);
    Result.Partition.ProducerRecipes.insert(FrontierSlice.begin(),
                                            FrontierSlice.end());
  }

  for (VPReductionProducerSlice &Slice : Result.Slices) {
    Result.Partition.AccumulatorRecipes.insert(Slice.Accumulator);
    Result.Partition.AccumulatorRecipes.insert(Slice.Updates.begin(),
                                               Slice.Updates.end());
  }
  for (const auto *Input : Inputs) {
    if (Input->IsLong) {
      bool CoveredBySharedWaist =
          any_of(Result.Partition.FrontierValues, [&](VPValue *Frontier) {
            return Input->Recipes.contains(Frontier->getDefiningRecipe());
          });
      if (!CoveredBySharedWaist) {
        Result.Partition.ProducerRecipes.insert(Input->Recipes.begin(),
                                                Input->Recipes.end());
        if (SeenFrontier.insert(Input->Value).second)
          Result.Partition.FrontierValues.push_back(Input->Value);
      }
    } else {
      Result.Partition.AccumulatorRecipes.insert(Input->Recipes.begin(),
                                                 Input->Recipes.end());
    }
  }

  // Keep every recipe not selected for the producer stage in the accumulator
  // stage. This includes short contribution chains and loop-control recipes.
  for (VPRecipeBase *Recipe : Recipes)
    if (!Result.Partition.ProducerRecipes.contains(Recipe))
      Result.Partition.AccumulatorRecipes.insert(Recipe);

  if (Result.Partition.ProducerRecipes.empty() ||
      Result.Partition.AccumulatorRecipes.empty() ||
      Result.Partition.FrontierValues.empty())
    Result.RejectReason =
        VPReductionFissionRejectReason::CrossPartitionDependence;
  return Result;
}
