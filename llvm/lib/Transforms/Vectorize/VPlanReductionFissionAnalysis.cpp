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
#include "llvm/Analysis/AliasAnalysis.h"
#include "llvm/Analysis/LoopAccessAnalysis.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/ScalarEvolutionExpressions.h"
#include "llvm/Analysis/TargetTransformInfo.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/Analysis/VectorUtils.h"
#include "llvm/IR/AttributeMask.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/Errc.h"
#include "llvm/Support/MathExtras.h"
#include "llvm/Transforms/Utils/ScalarEvolutionExpander.h"
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

Expected<VPFissionTripCountInfo>
llvm::analyzeFissionTripCount(Loop &L, ScalarEvolution &SE,
                              IntegerType *IndexTy) {
  auto Fail =
      [](VPReductionFissionRejectReason R) -> Expected<VPFissionTripCountInfo> {
    return createStringError(errc::invalid_argument,
                             getVPReductionFissionRejectReasonName(R));
  };
  const SCEV *BTC = SE.getBackedgeTakenCount(&L);
  if (isa<SCEVCouldNotCompute>(BTC))
    return Fail(VPReductionFissionRejectReason::NonConstantTripCount);
  const auto *MaxBTC = dyn_cast<SCEVConstant>(BTC);
  if (!MaxBTC)
    MaxBTC = dyn_cast<SCEVConstant>(SE.getConstantMaxBackedgeTakenCount(&L));
  if (!MaxBTC)
    return Fail(VPReductionFissionRejectReason::NonConstantTripCount);
  // An unconstrained 64-bit count cannot have a representable capacity. A
  // narrow all-ones maximum is useful, however: i8 255 backedges needs 256
  // scratch elements, not zero and not an unknown-size allocation.
  if (!isa<SCEVConstant>(BTC) && MaxBTC->getAPInt().isAllOnes() &&
      MaxBTC->getAPInt().getBitWidth() >= 64)
    return Fail(VPReductionFissionRejectReason::NonConstantTripCount);

  // Extend before adding: an i8 backedge count of 255 means 256 iterations.
  APInt MaxTC = MaxBTC->getAPInt().zext(MaxBTC->getAPInt().getBitWidth() + 1);
  ++MaxTC;
  if (MaxTC.getActiveBits() > 64 ||
      MaxTC.getActiveBits() > IndexTy->getBitWidth())
    return Fail(VPReductionFissionRejectReason::TripCountOverflow);
  const SCEV *TC = SE.getTripCountFromExitCount(BTC);
  TC = SE.getTruncateOrZeroExtend(TC, IndexTy);
  SCEVExpander Expander(SE, "fission");
  if (!SE.isLoopInvariant(TC, &L) || !L.getLoopPreheader() ||
      !Expander.isSafeToExpandAt(TC, L.getLoopPreheader()->getTerminator()))
    return Fail(VPReductionFissionRejectReason::UnsafeTripCountExpansion);
  return VPFissionTripCountInfo{TC, MaxTC.getZExtValue()};
}

bool llvm::verifyFissionMemorySchedule(
    const VPReductionFissionCandidate &Candidate,
    VPReductionFissionContext &Ctx) {
  SmallVector<Instruction *> Accesses;
  SmallPtrSet<StoreInst *, 8> Stores;
  for (Instruction &I : *Ctx.L.getHeader()) {
    if (isa<LoadInst, StoreInst>(I))
      Accesses.push_back(&I);
    if (auto *S = dyn_cast<StoreInst>(&I))
      Stores.insert(S);
  }
  for (StoreInst *S : Stores) {
    if (!S->isSimple())
      return false;
    // A nonzero, nonwrapping stride proves independence between this store's
    // iterations. This query must not introduce unverified predicates.
    auto Stride = getPtrStride(Ctx.PSE, S->getValueOperand()->getType(),
                               S->getPointerOperand(), &Ctx.L, Ctx.DT,
                               DenseMap<Value *, const SCEV *>(),
                               /*Assume=*/false, /*ShouldCheckWrap=*/true);
    if (!Stride || *Stride == 0)
      return false;
    // Compare entire underlying objects, not the two addresses at one
    // iteration (A[i] and A[i+1] can be NoAlias and still carry dependence).
    MemoryLocation StoreObject = MemoryLocation::getBeforeOrAfter(
        getUnderlyingObject(S->getPointerOperand()));
    for (Instruction *I : Accesses) {
      if (I == S)
        continue;
      MemoryLocation OtherObject = MemoryLocation::getBeforeOrAfter(
          getUnderlyingObject(getLoadStorePointerOperand(I)));
      if (!Ctx.AA.isNoAlias(StoreObject, OtherObject))
        return false;
    }
  }

  for (auto [Plan, IsProducer] :
       {std::pair{Candidate.ProducerPlan.get(), true},
        {Candidate.ProducerRemainder.Plan.get(), true},
        {Candidate.AccumulatorPlan.get(), false},
        {Candidate.AccumulatorRemainder.Plan.get(), false}}) {
    SmallPtrSet<StoreInst *, 8> Seen;
    for (VPRecipeBase &R : *Plan->getVectorLoopRegion()->getEntryBasicBlock()) {
      Instruction *I = nullptr;
      if (auto *S = dyn_cast<VPWidenStoreRecipe>(&R))
        I = &S->getIngredient();
      else if (auto *L = dyn_cast<VPWidenLoadRecipe>(&R))
        I = &L->getIngredient();
      else if (auto *Rep = dyn_cast<VPReplicateRecipe>(&R))
        I = dyn_cast_or_null<Instruction>(Rep->getUnderlyingValue());
      if (!I || !isa<LoadInst, StoreInst>(I))
        continue;
      if (!is_contained(Accesses, I))
        return false;
      if (auto *S = dyn_cast<StoreInst>(I))
        if (IsProducer || !Seen.insert(S).second)
          return false;
    }
    if (!IsProducer && Seen.size() != Stores.size())
      return false;
  }
  return true;
}

bool llvm::isSupportedFissionFAdd(PHINode &Phi, const RecurrenceDescriptor &Rdx,
                                  const Loop &L) {
  if (Rdx.getRecurrenceKind() != RecurKind::FAdd ||
      Rdx.getRecurrenceType() != Phi.getType() ||
      Rdx.hasUsesOutsideReductionChain() || Rdx.IntermediateStore ||
      Phi.getFunction()->hasFnAttribute(Attribute::StrictFP))
    return false;
  auto *Update = dyn_cast<BinaryOperator>(Rdx.getLoopExitInstr());
  if (!Update || Update->getOpcode() != Instruction::FAdd ||
      count(Update->operands(), &Phi) != 1 ||
      Phi.getIncomingValueForBlock(L.getLoopLatch()) != Update)
    return false;
  for (User *U : Phi.users())
    if (U != Update)
      return false;
  for (User *U : Update->users())
    if (U != &Phi && L.contains(cast<Instruction>(U)))
      return false;
  return true;
}

std::optional<VPReductionFissionRejectReason>
llvm::checkFissionFPCost(VPlan &Baseline,
                         const VPReductionFissionCandidate &Candidate,
                         const TargetTransformInfo &TTI) {
  // Compare the costs affected by the split: scratch traffic, FP accumulation
  // and register spills. Producer arithmetic is common at ProducerVF. This is
  // deliberately a supplement to, rather than a replacement for, the existing
  // pressure/duplication policy. MaxTripCount is never a frequency estimate.
  struct CostSummary {
    double PerElement = 0;
    double Setup = 0;
    double Tail = 0;
    bool Valid = true;
  };
  auto *Exact = dyn_cast<SCEVConstant>(Candidate.TripCount.ExactTripCount);
  auto Summarize = [&](VPlan &Plan, ElementCount VF) {
    CostSummary Result;
    uint64_t Width =
        uint64_t(VF.getKnownMinValue()) *
        (VF.isScalable() ? TTI.getVScaleForTuning().value_or(1) : 1);
    uint64_t Tail = Exact ? Exact->getAPInt().getZExtValue() % Width : 0;
    auto Add = [&](InstructionCost Cost, double &To, double Divisor = 1) {
      if (!Cost.isValid())
        Result.Valid = false;
      else
        To += double(Cost.getValue()) / Divisor;
    };
    constexpr auto Kind = TTI::TCK_RecipThroughput;
    Type *SpillTy = Candidate.Scratch.Slots.front().ElementType;
    for (VPRecipeBase &R : *Plan.getVectorLoopRegion()->getEntryBasicBlock()) {
      if (auto *L = dyn_cast<VPFissionScratchLoadRecipe>(&R)) {
        Add(TTI.getMemoryOpCost(Instruction::Load,
                                VectorType::get(L->getElementType(), VF),
                                L->getAlignment(), 0, Kind),
            Result.PerElement, Width);
        Add(TTI.getMemoryOpCost(Instruction::Load, L->getElementType(),
                                L->getAlignment(), 0, Kind) *
                Tail,
            Result.Tail);
      }
      if (auto *S = dyn_cast<VPFissionScratchStoreRecipe>(&R)) {
        Add(TTI.getMemoryOpCost(Instruction::Store,
                                VectorType::get(S->getElementType(), VF),
                                S->getAlignment(), 0, Kind),
            Result.PerElement, Width);
        Add(TTI.getMemoryOpCost(Instruction::Store, S->getElementType(),
                                S->getAlignment(), 0, Kind) *
                Tail,
            Result.Tail);
      }
      auto *Phi = dyn_cast<VPReductionPHIRecipe>(&R);
      if (!Phi || Phi->getRecurrenceKind() != RecurKind::FAdd)
        continue;
      auto *Ty = VectorType::get(Phi->getScalarType(), VF);
      InstructionCost Reduction = TTI.getArithmeticReductionCost(
          Instruction::FAdd, Ty, Phi->getFastMathFlagsOrNone(), Kind);
      if (Phi->isInLoop())
        Add(Reduction, Result.PerElement, Width);
      else {
        Add(TTI.getArithmeticInstrCost(Instruction::FAdd, Ty, Kind),
            Result.PerElement, Width);
        Add(Reduction, Result.Setup);
      }
      if (Exact)
        Add(TTI.getArithmeticInstrCost(Instruction::FAdd, Phi->getScalarType(),
                                       Kind) *
                Tail,
            Result.Tail);
    }
    auto Pressure = calculateRegisterPressureForPlan(Plan, VF, TTI);
    for (const auto &[Class, Total] : Pressure.PeakTotalRegs) {
      unsigned Capacity = Pressure.Capacity.lookup(Class);
      if (Total <= Capacity)
        continue;
      bool Vector = Class == TTI.getRegisterClassForType(true, SpillTy);
      Type *Ty = SpillTy;
      if (Vector) {
        unsigned RegBits =
            TTI.getRegisterBitWidth(TargetTransformInfo::RGK_ScalableVector)
                .getKnownMinValue();
        Ty = VectorType::get(
            SpillTy, ElementCount::getScalable(std::max(
                         1u, RegBits / SpillTy->getScalarSizeInBits())));
      }
      InstructionCost Spill =
          TTI.getMemoryOpCost(Instruction::Load, Ty, Align(1), 0, Kind) +
          TTI.getMemoryOpCost(Instruction::Store, Ty, Align(1), 0, Kind);
      Add(Spill * (Total - Capacity), Result.PerElement, Width);
    }
    if (Exact) {
      double N = Exact->getAPInt().getZExtValue();
      Result.PerElement *= (N - Tail) / N;
    }
    return Result;
  };
  auto B = Summarize(Baseline, Candidate.Selected->ProducerVF);
  auto P = Summarize(*Candidate.ProducerPlan, Candidate.Selected->ProducerVF);
  auto A =
      Summarize(*Candidate.AccumulatorPlan, Candidate.Selected->AccumulatorVF);
  if (!B.Valid || !P.Valid || !A.Valid)
    return VPReductionFissionRejectReason::InvalidFissionCost;
  double Before = B.PerElement;
  double After = P.PerElement + A.PerElement;
  if (Exact) {
    double N = Exact->getAPInt().getZExtValue();
    Before += (B.Setup + B.Tail) / N;
    // Two additional entry checks and scalar-tail dispatches. For a dynamic
    // N use steady-state costs; no static capacity is used to amortize these.
    After += (P.Setup + A.Setup + P.Tail + A.Tail + 4) / N;
  }
  if (After >= Before)
    return VPReductionFissionRejectReason::FissionCostNotReduced;
  return std::nullopt;
}

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
    const auto *Phi = dyn_cast<VPReductionPHIRecipe>(Def);
    const auto *Reduction = dyn_cast<VPReductionRecipe>(Def);
    bool IsScalar =
        (Phi && Phi->isInLoop()) || (Reduction && Reduction->isInLoop());
    unsigned ClassID = TTI.getRegisterClassForType(!IsScalar, ScalarTy);
    if (!IsScalar && (!VectorType::isValidElementType(ScalarTy) ||
                      (VF.isScalable() && !ScalarTy->isIntegerTy(1) &&
                       !TTI.isElementTypeLegalForScalableVector(ScalarTy))))
      return;
    unsigned Registers = TTI.getRegUsageForType(
        IsScalar ? ScalarTy : VectorType::get(ScalarTy, VF));
    Usage[ClassID] = SaturatingAdd(Usage[ClassID], Registers);
  };
  auto AddRecipeUsage = [&](const VPRecipeBase *Recipe,
                            SmallMapVector<unsigned, unsigned, 4> &Usage) {
    if (isa<VPDerivedIVRecipe, VPScalarIVStepsRecipe>(Recipe))
      return;
    for (VPValue *Def : Recipe->definedValues()) {
      // Scalar addresses, canonical indices and loop-control values do not
      // occupy vector register groups. This analysis models vector pressure.
      if (!isa<VPReductionPHIRecipe, VPReductionRecipe, VPWidenLoadRecipe>(
              Recipe) &&
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
    if (auto *Rdx = dyn_cast<VPReductionRecipe>(Recipes[Index]);
        Rdx && Rdx->isInLoop()) {
      // The scalar chain does not eliminate the vector temporary used by
      // horizontal reduction lowering.
      Type *Ty = Rdx->getScalarType();
      NonAccumulatorUsage[TTI.getRegisterClassForType(true, Ty)] +=
          TTI.getRegUsageForType(VectorType::get(Ty, VF));
    }
    for (const auto &Entry : Result.LoopInvariantRegs)
      NonAccumulatorUsage.try_emplace(Entry.first, 0);
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
  auto IsTailMask = [&](VPValue *Mask) {
    if (!Mask || Mask == Plan.getVectorLoopRegion()->getHeaderMask() ||
        Mask == Plan.getTrue())
      return true;
    auto *I = dyn_cast<VPInstruction>(Mask);
    return I && I->getOpcode() == VPInstruction::ActiveLaneMask;
  };
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
             VPWidenIntOrFpInductionRecipe, VPWidenStoreRecipe,
             VPReductionRecipe, VPExpandSCEVRecipe, VPWidenCallRecipe,
             VPWidenIntrinsicRecipe, VPWidenCanonicalIVRecipe,
             VPScalarIVStepsRecipe, VPDerivedIVRecipe, VPVectorPointerRecipe,
             VPReplicateRecipe, VPFissionScratchLoadRecipe,
             VPFissionScratchStoreRecipe>(R)) {
      LLVM_DEBUG({
        dbgs() << "LV-FISSION: unsupported recipe at VF " << VF << "\n";
        R.dump();
      });
      return false;
    }
    if (isa<VPExpandSCEVRecipe>(R) && R.getParent() == Body)
      return false;
    if (auto *IV = dyn_cast<VPWidenIntOrFpInductionRecipe>(&R)) {
      if (IV->getInductionDescriptor().getKind() !=
              InductionDescriptor::IK_IntInduction ||
          !IV->getScalarType()->isIntegerTy() ||
          !IV->getStartValue()->isDefinedOutsideLoopRegions() ||
          !IV->getStepValue()->isDefinedOutsideLoopRegions() ||
          !IV->getNoWrapPredicates().empty() ||
          IV->getVFValue() != &Plan.getVF())
        return false;
    }
    // Consecutive addresses are represented by a uniform scalar GEP even in
    // an otherwise fully widened plan. Do not admit lane-wise replication.
    if (auto *Replicate = dyn_cast<VPReplicateRecipe>(&R))
      if (!Replicate->isSingleScalar() || Replicate->isPredicated() ||
          !isa<GetElementPtrInst>(Replicate->getUnderlyingValue()))
        return false;
    if (auto *Phi = dyn_cast<VPReductionPHIRecipe>(&R)) {
      if (Phi->getVFScaleFactor() != 1 ||
          Phi->getRecurrenceKind() == RecurKind::AnyOf ||
          RecurrenceDescriptor::isFindIVRecurrenceKind(
              Phi->getRecurrenceKind()))
        return false;
      if (Phi->isInLoop()) {
        auto *Update = dyn_cast<VPReductionRecipe>(Phi->getBackedgeValue());
        if (Phi->getRecurrenceKind() != RecurKind::FAdd ||
            Phi->hasUsesOutsideReductionChain() || !Update ||
            Update->getChainOp() != Phi ||
            Update->isOrdered() != Phi->isOrdered() ||
            (!Phi->isOrdered() &&
             !Phi->getFastMathFlagsOrNone().allowReassoc()))
          return false;
      }
    }
    if (auto *Rdx = dyn_cast<VPReductionRecipe>(&R)) {
      auto *Phi = dyn_cast<VPReductionPHIRecipe>(Rdx->getChainOp());
      auto *I = Rdx->getUnderlyingInstr();
      if (!Phi || !Rdx->isInLoop() || Rdx->isPartialReduction() ||
          !IsTailMask(Rdx->getCondOp()) ||
          Rdx->getRecurrenceKind() != RecurKind::FAdd ||
          (!Rdx->isOrdered() &&
           !Rdx->getFastMathFlagsOrNone().allowReassoc()) ||
          (I && (I->getOpcode() != Instruction::FAdd ||
                 I->getFunction()->hasFnAttribute(Attribute::StrictFP))))
        return false;
      if (!TTI.getArithmeticReductionCost(
                  Instruction::FAdd, VectorType::get(Rdx->getScalarType(), VF),
                  Rdx->getFastMathFlagsOrNone(), TTI::TCK_RecipThroughput)
               .isValid())
        return false;
      if (any_of(Rdx->users(), [&](VPUser *U) {
            auto *UserR = cast<VPRecipeBase>(U);
            return UserR != Phi && UserR->getParent() == Body;
          }))
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
          (isa<VPReductionPHIRecipe>(R) &&
           cast<VPReductionPHIRecipe>(R).isInLoop()) ||
          (isa<VPReductionRecipe>(R) &&
           cast<VPReductionRecipe>(R).isInLoop()) ||
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
    if (auto *Store = dyn_cast<VPWidenStoreRecipe>(&R)) {
      auto &IRStore = cast<StoreInst>(Store->getIngredient());
      if (!IRStore.isSimple() || !Store->isConsecutive() ||
          !TTI.isLegalMaskedStore(
              VectorType::get(Store->getStoredValue()->getScalarType(), VF),
              IRStore.getAlign(), IRStore.getPointerAddressSpace()))
        return false;
      // Prefix stores require a scan, not a reduction of a complete chunk.
      SmallPtrSet<VPValue *, 16> Seen;
      SmallVector<VPValue *> Worklist{Store->getStoredValue(),
                                      Store->getAddr()};
      while (!Worklist.empty()) {
        VPValue *V = Worklist.pop_back_val();
        if (!Seen.insert(V).second)
          continue;
        if (auto *Def = V->getDefiningRecipe()) {
          if (isa<VPReductionPHIRecipe>(Def))
            return false;
          append_range(Worklist, Def->operands());
        }
      }
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
  case VPReductionFissionRejectReason::TripCountOverflow:
    return "trip-count-overflow";
  case VPReductionFissionRejectReason::UnsafeTripCountExpansion:
    return "unsafe-trip-count-expansion";
  case VPReductionFissionRejectReason::UnsafeStageInput:
    return "unsafe-stage-input";
  case VPReductionFissionRejectReason::MemoryDependence:
    return "memory-dependence";
  case VPReductionFissionRejectReason::UnsupportedReduction:
    return "unsupported-reduction";
  case VPReductionFissionRejectReason::InvalidFissionCost:
    return "invalid-fission-cost";
  case VPReductionFissionRejectReason::FissionCostNotReduced:
    return "fission-cost-not-reduced";
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
