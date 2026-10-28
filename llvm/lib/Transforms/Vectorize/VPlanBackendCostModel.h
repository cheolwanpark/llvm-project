// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_TRANSFORMS_VECTORIZE_VPLANBACKENDCOSTMODEL_H
#define LLVM_TRANSFORMS_VECTORIZE_VPLANBACKENDCOSTMODEL_H
#include "VPlanRegisterUsageBounds.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Support/InstructionCost.h"
#include "llvm/Transforms/Vectorize/VPlanBackendFeedback.h"
namespace llvm {
class LLVMContext;
class VPlan;
class TargetTransformInfo;
class LoopVectorizationPlanner;
class VFSelectionContext;
class VPlanCostReport;
/// Exact rational in quarter-cost units. Checked arithmetic never silently
/// saturates or rounds a ranking score. Conversion is only for legacy clients.
class LLVM_ABI_FOR_TEST VPExactCost {
  int64_t N = 0, D = 1;
  bool Valid = true;

public:
  VPExactCost() = default;
  VPExactCost(InstructionCost C) : Valid(C.isValid()) {
    if (Valid)
      N = C.getQuarterValue();
  }
  static VPExactCost ratio(int64_t N, int64_t D);
  bool isValid() const { return Valid; }
  int64_t numerator() const { return N; }
  int64_t denominator() const { return D; }
  operator InstructionCost() const;
  VPExactCost operator+(VPExactCost B) const;
  VPExactCost operator-(VPExactCost B) const;
  VPExactCost operator*(unsigned B) const;
  VPExactCost normalize(unsigned Width, uint64_t ObservedWidth) const;
  bool operator<(VPExactCost B) const;
  bool operator<=(VPExactCost B) const;
  void print(raw_ostream &OS, unsigned Divisor = 1) const;
  bool operator==(VPExactCost B) const;
};
/// The numeric objective shared by normal selection and lower-bound proofs.
/// Callers retain all eligibility, forced-selection and tie-breaking policies.
template <typename CostT>
CostT vplanCostForTripCount(unsigned Width, CostT Body, CostT Scalar,
                           unsigned TC, bool ScalarTail) {
  if (ScalarTail)
    return Body * (TC / Width) + Scalar * (TC % Width);
  return Body * divideCeil(TC, Width);
}

struct VPBackendPruningContext {
  bool Enabled = false;
  bool VectorIncumbents = false;
  VPExactCost Scalar;
  unsigned MaxTripCount = 0;
};
LLVM_ABI_FOR_TEST bool vplanStrictlyCheaper(
    VPExactCost A, unsigned WidthA, VPExactCost B, unsigned WidthB,
    VPExactCost Scalar, unsigned MaxTripCount, bool ScalarTail);

struct VPMIRCost {
  std::string Model, Revision;
  VPExactCost RawBody, RawSpill, Body, Spill;
  std::vector<MIRInstructionCost> Instructions;
};
LLVM_ABI_FOR_TEST Expected<VPMIRCost>
priceVPlanMIR(const VPlanBackendResult &Observation, const TargetMIRInfo &Info,
              unsigned Width);
struct VPBackendCostEntry {
  const VPlan *Plan;
  ElementCount VF;
  unsigned IC;
  bool IsEpilogue;
  InstructionCost Native, Profile, EstimatedVectorSpill;
  VPExactCost Body;
  InstructionCost EstimatedSpill;
  std::optional<VPMIRCost> MIR;
};
/// All state belongs to one original loop. Preparation is transactional: on
/// failure discard every score before native selection can observe the table.
class LLVM_ABI_FOR_TEST VPlanBackendCostModel {
  friend class VPlanBackendCostModelTestAccess;
  enum class CandidateState { Pending, Exact, Pruned };
  struct PreparedCandidate {
    VPlan *Plan;
    VPlanBackendCandidate Candidate;
    InstructionCost Native, Profile, Ev;
    InstructionCost EstimatedSpill;
    unsigned Width;
    VPRegisterUsageBound Bound;
    bool Query;
    CandidateState State = CandidateState::Pending;
    VPExactCost LowerBound;
    bool Eligible = false;
    bool Queried = false;
    std::string PruningBasis;
    VPExactCost BasisCost;
    unsigned BasisWidth = 0;
    std::optional<VPlanBackendResult> Observation;
  };
  SmallVector<VPBackendCostEntry, 0> Costs;
  SmallVector<PreparedCandidate, 0> Candidates;
  VPBackendPruningContext Pruning;
  const VPlanBackendFeedback &Feedback;
  const TargetTransformInfo &TTI;
  Function &F;
  BasicBlock &Header;
  unsigned LoopIndex = 0, Invocation = 0;
  bool InterleaveOnly = false, VectorizeOnly = false;
  VPlanCostReport *Report;
  std::unique_ptr<TargetMIRInfo> MIRInfo;
  bool Failed = false;
  std::string Failure;
  VPlanBackendMode Mode;
  SmallVector<json::Object, 0> Rows;

  PreparedCandidate prepareCost(VPlan &Plan, VPlanBackendCandidate Candidate,
                                InstructionCost Native, InstructionCost Profile,
                                InstructionCost Ev, unsigned Width,
                                InstructionCost EstimatedSpill = 0) const;
  bool applyCost(PreparedCandidate &Prepared,
                 std::optional<VPlanBackendProbeResult> Result,
                 VPlanFeedbackTimer &Timer);
  bool addBatch(ArrayRef<PreparedCandidate *> Wave);
  bool prune(PreparedCandidate &P);
  void reportPruned(const PreparedCandidate &P);
  bool evaluatePrepared(unsigned Capacity);

public:
  VPlanBackendCostModel(const VPlanBackendFeedback &Feedback,
                        const TargetTransformInfo &TTI, Function &F,
                        BasicBlock &Header, VPlanCostReport *Report = nullptr,
                        VPlanBackendMode Mode = VPlanBackendMode::requested())
      : Feedback(Feedback), TTI(TTI), F(F), Header(Header), Report(Report),
        Mode(Mode) {}
  bool prepare(LoopVectorizationPlanner &LVP, VFSelectionContext &Config,
               unsigned UserIC, unsigned Invocation, unsigned LoopIndex,
               bool InterleaveOnlyWhenForced, bool VectorizeOnlyWhenForced,
               ElementCount ForcedEpilogue);
  bool prepareEpilogue(LoopVectorizationPlanner &LVP,
                       VFSelectionContext &Config, VPlan &MainPlan,
                       ElementCount MainVF, unsigned MainIC, VPlan &Plan,
                       ElementCount VF);
  bool add(VPlan &Plan, VPlanBackendCandidate Candidate, InstructionCost Native,
           InstructionCost Profile, InstructionCost Ev, unsigned Width,
           InstructionCost EstimatedSpill = 0);
  const VPBackendCostEntry *lookup(const VPlan &Plan, ElementCount VF,
                                   bool Epilogue = false) const;
  bool isPruned(const VPlan &Plan, ElementCount VF) const;
  void fail(StringRef Reason);
  void commit(VPlanBackendMode Requested, StringRef Reason);
  void selection(ElementCount VF, unsigned IC, ElementCount Epilogue,
                 bool Emitted) const;
  bool failed() const { return Failed; }
  StringRef failure() const { return Failure; }
};
/// Strict adapter for vector-spill facts; the observer never assigns prices.
LLVM_ABI_FOR_TEST Expected<VPExactCost>
priceVPlanVectorSpills(const VPlanBackendResult &Observation,
                       const TargetTransformInfo &TTI, LLVMContext &Context,
                       unsigned Width, InstructionCost &RawCost,
                       SmallVectorImpl<InstructionCost> *AccessCosts = nullptr);
} // namespace llvm
#endif
