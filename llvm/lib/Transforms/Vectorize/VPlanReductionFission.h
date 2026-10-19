//===- VPlanReductionFission.h - Reduction fission pipeline -----*- C++ -*-===//
//-*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_VECTORIZE_VPLANREDUCTIONFISSION_H
#define LLVM_TRANSFORMS_VECTORIZE_VPLANREDUCTIONFISSION_H

#include "VPlan.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/TargetTransformInfo.h"
#include "llvm/Support/Alignment.h"
#include "llvm/Support/Error.h"
#include <memory>
#include <optional>

namespace llvm {

class VPReductionPHIRecipe;
class VPRecipeBase;
class VPBasicBlock;
class VPValue;
class VPlan;
class DataLayout;
class ScalarEvolution;
class SCEV;
class Type;

/// Unit-weight structural properties of the recipe DAG producing a VPValue.
/// Live-ins and loop-header phis are boundaries and therefore have depth zero.
struct VPDependencyMetrics {
  unsigned RecipeCount = 0;
  unsigned CriticalPathDepth = 0;
  unsigned MaxLevelWidth = 0;
  unsigned IndependentRootCount = 0;
  unsigned RecurrenceCount = 0;
};

/// Collect recipes needed to produce \p Root. Header phis are excluded from
/// \p Slice and recorded separately in \p Recurrences.
void collectVPProducerSlice(VPValue &Root,
                            SmallPtrSetImpl<const VPRecipeBase *> &Slice,
                            SmallPtrSetImpl<const VPRecipeBase *> &Recurrences);

/// Calculate unit-weight dependency metrics for the DAG producing \p Root.
/// If supplied, \p AllowedRecipes restricts which non-boundary recipes belong
/// to the DAG.
VPDependencyMetrics calculateVPDependencyMetrics(
    VPValue &Root,
    const SmallPtrSetImpl<const VPRecipeBase *> *AllowedRecipes = nullptr);

/// Register-pressure components used to identify overflows caused by
/// loop-live reduction accumulators.
struct VPRegisterPressureBreakdown {
  SmallMapVector<unsigned, unsigned, 4> LoopInvariantRegs;
  SmallMapVector<unsigned, unsigned, 4> AccumulatorRegs;
  SmallMapVector<unsigned, unsigned, 4> PeakNonAccumulatorRegs;
  SmallMapVector<unsigned, unsigned, 4> PeakTotalRegs;
  SmallMapVector<unsigned, unsigned, 4> Capacity;
  SmallMapVector<unsigned, unsigned, 4> AccumulatorOverlapSurplus;

  bool hasAccumulatorCausedOverflow() const;
  bool exceedsCapacity() const;
};

struct VPRegisterPressureOptions {
  const SmallPtrSetImpl<const VPRecipeBase *> *AllowedRecipes = nullptr;
  const SmallPtrSetImpl<const VPReductionPHIRecipe *> *LoopLiveAccumulators =
      nullptr;
  /// Discover reduction PHIs when no explicit accumulator set is supplied.
  /// Producer-only stage analysis disables this.
  bool TreatReductionsAsLoopLive = true;
};

/// Estimate vector-register pressure for a VF, keeping reduction accumulators
/// live across the vector loop.
VPRegisterPressureBreakdown
calculateRegisterPressureForPlan(VPlan &Plan, ElementCount VF,
                                 const TargetTransformInfo &TTI,
                                 const VPRegisterPressureOptions &Options = {});

/// Store a vector producer result to a full-trip-count fission scratch slot.
class VPFissionScratchStoreRecipe final : public VPRecipeBase {
  unsigned SlotID;
  Type *ElementType;
  Align Alignment;

public:
  VPFissionScratchStoreRecipe(unsigned SlotID, Type *ElementType,
                              Align Alignment, VPValue *Base, VPValue *Index,
                              VPValue *StoredValue, VPValue *Mask)
      : VPRecipeBase(VPRecipeBase::VPFissionScratchStoreSC,
                     {Base, Index, StoredValue, Mask}),
        SlotID(SlotID), ElementType(ElementType), Alignment(Alignment) {}

  VPFissionScratchStoreRecipe *clone() override {
    return new VPFissionScratchStoreRecipe(SlotID, ElementType, Alignment,
                                           getOperand(0), getOperand(1),
                                           getStoredValue(), getMask());
  }

  VP_CLASSOF_IMPL(VPRecipeBase::VPFissionScratchStoreSC)

  unsigned getSlotID() const { return SlotID; }
  Type *getElementType() const { return ElementType; }
  Align getAlignment() const { return Alignment; }
  VPValue *getStoredValue() const { return getOperand(2); }
  VPValue *getMask() const { return getOperand(3); }

  void execute(VPTransformState &State) override;
  InstructionCost computeCost(ElementCount VF,
                              VPCostContext &Ctx) const override;

#if !defined(NDEBUG) || defined(LLVM_ENABLE_DUMP)
  void printRecipe(raw_ostream &O, const Twine &Indent,
                   VPSlotTracker &SlotTracker) const override;
#endif

  bool usesFirstLaneOnly(const VPValue *Op) const override {
    assert(is_contained(operands(), Op) && "Op must be an operand");
    return Op != getStoredValue() && Op != getMask();
  }
};

/// Load a vector contribution from a full-trip-count fission scratch slot.
class VPFissionScratchLoadRecipe final : public VPSingleDefRecipe {
  unsigned SlotID;
  Type *ElementType;
  Align Alignment;

public:
  VPFissionScratchLoadRecipe(unsigned SlotID, Type *ElementType,
                             Align Alignment, VPValue *Base, VPValue *Index,
                             VPValue *Mask)
      : VPSingleDefRecipe(VPRecipeBase::VPFissionScratchLoadSC,
                          {Base, Index, Mask}, ElementType),
        SlotID(SlotID), ElementType(ElementType), Alignment(Alignment) {}

  VPFissionScratchLoadRecipe *clone() override {
    return new VPFissionScratchLoadRecipe(SlotID, ElementType, Alignment,
                                          getOperand(0), getOperand(1),
                                          getMask());
  }

  VP_CLASSOF_IMPL(VPRecipeBase::VPFissionScratchLoadSC)

  unsigned getSlotID() const { return SlotID; }
  Type *getElementType() const { return ElementType; }
  Align getAlignment() const { return Alignment; }
  VPValue *getMask() const { return getOperand(2); }

  void execute(VPTransformState &State) override;
  InstructionCost computeCost(ElementCount VF,
                              VPCostContext &Ctx) const override;

#if !defined(NDEBUG) || defined(LLVM_ENABLE_DUMP)
  void printRecipe(raw_ostream &O, const Twine &Indent,
                   VPSlotTracker &SlotTracker) const override;
#endif

  bool usesFirstLaneOnly(const VPValue *Op) const override {
    assert(is_contained(operands(), Op) && "Op must be an operand");
    return Op != getMask();
  }
};

class AssumptionCache;
class AAResults;
class LoopVectorizationLegality;
class OptimizationRemarkEmitter;
class PredicatedScalarEvolution;

/// LLVM 23's widened intrinsic recipes require a vector VF. Scalar companions
/// use this recipe to retain intrinsic identity, flags and metadata, including
/// intrinsics synthesized by VPlan without an underlying scalar call.
class VPFissionScalarIntrinsicRecipe final : public VPRecipeWithIRFlags,
                                             public VPIRMetadata {
  Intrinsic::ID ID;

public:
  explicit VPFissionScalarIntrinsicRecipe(const VPWidenIntrinsicRecipe &R)
      : VPRecipeWithIRFlags(VPFissionScalarIntrinsicSC, R.operands(),
                            R.getScalarType(), R, R.getDebugLoc()),
        VPIRMetadata(R), ID(R.getVectorIntrinsicID()) {}

  VP_CLASSOF_IMPL(VPFissionScalarIntrinsicSC)
  VPFissionScalarIntrinsicRecipe *clone() override {
    return new VPFissionScalarIntrinsicRecipe(ID, operands(), getScalarType(),
                                              *this, *this, getDebugLoc());
  }
  void execute(VPTransformState &State) override;
  bool usesFirstLaneOnly(const VPValue *) const override { return true; }
  InstructionCost computeCost(ElementCount, VPCostContext &) const override {
    return 0;
  }
#if !defined(NDEBUG) || defined(LLVM_ENABLE_DUMP)
  void printRecipe(raw_ostream &O, const Twine &Indent,
                   VPSlotTracker &SlotTracker) const override;
#endif

private:
  VPFissionScalarIntrinsicRecipe(Intrinsic::ID ID, ArrayRef<VPValue *> Ops,
                                 Type *Ty, const VPIRFlags &Flags,
                                 const VPIRMetadata &MD, DebugLoc DL)
      : VPRecipeWithIRFlags(VPFissionScalarIntrinsicSC, Ops, Ty, Flags, DL),
        VPIRMetadata(MD), ID(ID) {}
};

/// The only connection to LoopVectorize. No legacy cost-model or inner-loop
/// vectorizer implementation is needed by the fission pipeline.
struct VPReductionFissionContext {
  Loop &L;
  LoopInfo &LI;
  DominatorTree &DT;
  PredicatedScalarEvolution &PSE;
  AssumptionCache &AC;
  AAResults &AA;
  const TargetTransformInfo &TTI;
  LoopVectorizationLegality &Legal;
  OptimizationRemarkEmitter &ORE;
  unsigned WidestType;
  bool FPReordering = false;
  bool HintReordering = false;
};

/// When enabled, retain a scalable plan before target-specific tail lowering.
/// Fission builds full-chunk stages with independent scalar remainders, so it
/// must not inherit EVL induction or tail-specific memory recipes.
void saveReductionFissionPlan(VPlan &Plan, SmallVectorImpl<VPlanPtr> &Plans);

/// Whether the optional reduction-fission pipeline is enabled.
bool isReductionFissionEnabled();

/// Whether this loop was emitted by either fission path. Ordinary LV may still
/// vectorize it, but it must not become a new fission candidate, including when
/// explicit follow-up metadata re-enables vectorization on a later LV run.
bool isReductionFissionStage(const Loop &L);

/// Retain stage provenance and the original target location when ordinary LV
/// applies explicit follow-up hints that replace the loop ID.
void preserveReductionFissionStageMetadata(MDNode *OriginalID, Loop &L);

/// Split a bounded scalar loop before querying whole-loop vectorizability.
/// On success L remains the producer; the returned sibling is the consumer.
/// Oversized single-block loops become siblings inside a bounded chunk loop.
/// Neither stage has been vectorized. Both must go through normal LV planning.
Loop *tryScalarReductionFission(Loop &L, LoopInfo &LI, DominatorTree &DT,
                               ScalarEvolution &SE,
                               OptimizationRemarkEmitter &ORE);

/// Empty for ordinary loops; otherwise the scalar-IR fission stage name.
StringRef getScalarReductionFissionStage(const Loop &L);

uint64_t getReductionFissionMaxScratchBytes();

/// A single ordinary fadd of an independent contribution. Accumulator FMA,
/// prefix uses and strict FP require separate support.
bool isSupportedFissionFAdd(PHINode &Phi, const RecurrenceDescriptor &Rdx,
                            const Loop &L);

/// Returns false without changing IR or baseline plans when no candidate is
/// selected. On success the original loop is erased and must not be used again.
bool tryReductionFission(ArrayRef<std::unique_ptr<VPlan>> Plans,
                         ElementCount BaselineVF,
                         VPReductionFissionContext &Context);

/// Keep a stage result live through VPlan simplification and collect the scalar
/// IR value at execution. This produces no IR and is never part of the body.
class VPFissionLiveOutRecipe final : public VPRecipeBase {
  Value *Result = nullptr;

public:
  explicit VPFissionLiveOutRecipe(VPValue *V)
      : VPRecipeBase(VPFissionLiveOutSC, V) {}
  VP_CLASSOF_IMPL(VPFissionLiveOutSC)
  VPFissionLiveOutRecipe *clone() override {
    return new VPFissionLiveOutRecipe(getOperand(0));
  }
  void execute(VPTransformState &State) override;
  Value *getResult() const {
    assert(Result);
    return Result;
  }
  bool usesFirstLaneOnly(const VPValue *) const override { return true; }
  InstructionCost computeCost(ElementCount, VPCostContext &) const override {
    return 0;
  }
#if !defined(NDEBUG) || defined(LLVM_ENABLE_DUMP)
  void printRecipe(raw_ostream &O, const Twine &Indent,
                   VPSlotTracker &SlotTracker) const override;
#endif
};

/// Validate the locally defined recipes without spreading their invariants
/// across the general VPlan verifier.
bool verifyReductionFissionRecipe(const VPRecipeBase &R);

enum class VPReductionFissionRejectReason {
  NonConstantTripCount,
  TripCountOverflow,
  UnsafeTripCountExpansion,
  UnsafeStageInput,
  MemoryDependence,
  UnsupportedReduction,
  UnsupportedRecipe,
  CrossPartitionDependence,
  ScratchLimit,
};

StringRef
getVPReductionFissionRejectReasonName(VPReductionFissionRejectReason Reason);

/// An accumulator-independent input to the recurrence update graph.
struct VPReductionProducerInput {
  VPValue *Value = nullptr;
  SmallPtrSet<const VPRecipeBase *, 16> Recipes;
  VPDependencyMetrics Dependency;
  bool IsVarying = false;
  /// Preferred long cut, or a nonempty varying fallback when none is long.
  bool IsLong = false;
};

struct VPReductionProducerSlice {
  VPReductionPHIRecipe *Accumulator = nullptr;
  /// Kept verbatim, including operand order, masks, casts and fused operations.
  SmallPtrSet<const VPRecipeBase *, 16> Updates;
  SmallVector<VPReductionProducerInput, 4> Inputs;
};

struct VPReductionFissionPartition {
  SmallPtrSet<const VPRecipeBase *, 32> ProducerRecipes;
  SmallPtrSet<const VPRecipeBase *, 32> AccumulatorRecipes;
  SmallVector<VPValue *, 4> FrontierValues;
  unsigned DuplicatedRecipeCount = 0;
};

struct VPReductionFissionConfig {
  /// Cut preference only; short producers are also eligible.
  unsigned MinimumLongProducerDepth = 8;
};

struct VPReductionFissionAnalysis {
  SmallVector<VPReductionProducerSlice, 8> Slices;
  VPReductionFissionPartition Partition;
  std::optional<VPReductionFissionRejectReason> RejectReason;

  bool isCandidate() const { return !RejectReason.has_value(); }
};

struct VPScratchSlot {
  VPValue *Frontier = nullptr;
  Type *ElementType = nullptr;
  uint64_t ElementCount = 0;
  Align Alignment;
  uint64_t Offset = 0;
  uint64_t Bytes = 0;
};

struct VPScratchPlan {
  SmallVector<VPScratchSlot, 4> Slots;
  uint64_t TotalBytes = 0;
};

struct VPFissionConfiguration {
  ElementCount ProducerVF;
  ElementCount AccumulatorVF;
};

/// Execution uses ExactTripCount; scratch allocation uses MaxTripCount only.
struct VPFissionTripCountInfo {
  const SCEV *ExactTripCount = nullptr;
  uint64_t MaxTripCount = 0;
};

Expected<VPFissionTripCountInfo>
analyzeFissionTripCount(Loop &L, ScalarEvolution &SE, IntegerType *IndexTy);

/// A VF=1 copy of a stage, entered at that stage's rounded-down vector bound.
struct VPFissionScalarRemainder {
  std::unique_ptr<VPlan> Plan;
  VPBasicBlock *Preheader = nullptr;
  VPBasicBlock *Middle = nullptr;
  /// Track reduction results across the vector and scalar stages.
  struct Reduction {
    VPValue *VectorResult;
    VPReductionPHIRecipe *ScalarPhi;
    VPValue *Start;
    VPFissionLiveOutRecipe *VectorExport;
    VPFissionLiveOutRecipe *ScalarExport;
  };
  SmallVector<Reduction, 8> Reductions;
};

/// Atomic producer and accumulator VPlan pair.
struct VPReductionFissionCandidate {
  VPFissionTripCountInfo TripCount;
  std::unique_ptr<VPlan> ProducerPlan;
  std::unique_ptr<VPlan> AccumulatorPlan;
  VPFissionScalarRemainder ProducerRemainder;
  VPFissionScalarRemainder AccumulatorRemainder;
  VPReductionFissionPartition Partition;
  VPScratchPlan Scratch;
  /// Original exit PHIs and their exported accumulator-stage results.
  SmallVector<std::pair<PHINode *, VPValue *>, 8> AccumulatorLiveOuts;
  VPBasicBlock *ProducerVectorPH = nullptr;
  VPBasicBlock *ProducerMiddle = nullptr;
  VPBasicBlock *AccumulatorVectorPH = nullptr;
  VPBasicBlock *AccumulatorMiddle = nullptr;
  std::optional<VPFissionConfiguration> Selected;
};

/// Validate the final stage bodies, including dependencies cloned into both
/// stages. No run-time alias checks or new SCEV predicates are introduced.
bool verifyFissionMemorySchedule(const VPReductionFissionCandidate &Candidate,
                                 VPReductionFissionContext &Context);

struct VPFissionVFPressure {
  ElementCount VF;
  VPRegisterPressureBreakdown Pressure;
};

struct VPReductionFissionDecision {
  bool SelectFission = false;
  ElementCount BaselineVF = ElementCount::getFixed(1);
  std::optional<VPFissionConfiguration> Fission;
  std::optional<VPReductionFissionRejectReason> Reason;
};

VPReductionFissionAnalysis
analyzeVPReductionFission(VPlan &Plan,
                          const VPReductionFissionConfig &Config = {});

/// Check the VF-independent supported recipe subset before stage construction.
bool isSupportedReductionFissionPlan(VPlan &Plan,
                                    const TargetTransformInfo &TTI);

/// Check the supported, VF-independent recipe subset and target memory/type
/// legality. In particular, a vector-call variant is legal only at its own VF.
bool isLegalReductionFissionVF(VPlan &Plan, ElementCount VF,
                               const TargetTransformInfo &TTI);

/// Remove only reduction tail selects whose scratch identity is proven safe.
void simplifyReductionFissionTail(VPlan &Plan);

/// Build stack scratch storage for a proven constant capacity. This is not
/// necessarily the number of iterations executed by either stage.
Expected<VPScratchPlan> buildScratchPlan(ArrayRef<VPValue *> FrontierValues,
                                         std::optional<uint64_t> MaxTripCount,
                                         const DataLayout &DL,
                                         uint64_t MaximumBytes);

Expected<VPScratchPlan> buildScratchPlan(ArrayRef<VPValue *> FrontierValues,
                                         const SCEV *MaxTripCount,
                                         const DataLayout &DL,
                                         uint64_t MaximumBytes);

/// Build independent vector stages and scalar companions. Optionally combine
/// private, unflagged integer-add scratch contributions in the new stages only;
/// the caller must recheck the resulting candidate's legality and pressure.
Expected<VPReductionFissionCandidate> buildReductionFissionStagePlans(
    VPlan &Baseline, const VPReductionFissionAnalysis &Analysis,
    const VPScratchPlan &Scratch, ArrayRef<ElementCount> CandidateVFs,
    bool CombineAddContributions = false);

/// Select stage VFs independently from their legal sets, preferring the largest
/// with register headroom, otherwise the smallest legal VF. The baseline VF is
/// recorded for diagnostics only; pressure improvement is not required.
VPReductionFissionDecision selectReductionFissionConfiguration(
    ElementCount ActualBaselineVF, ArrayRef<VPFissionVFPressure> Producer,
    ArrayRef<VPFissionVFPressure> Accumulator, uint64_t ScratchBytes,
    uint64_t MaximumScratchBytes, unsigned DuplicatedRecipeCount,
    unsigned MaximumDuplicatedRecipes);

} // namespace llvm

#endif // LLVM_TRANSFORMS_VECTORIZE_VPLANREDUCTIONFISSION_H
