// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_TRANSFORMS_VECTORIZE_VPLANBACKENDCOSTMODEL_H
#define LLVM_TRANSFORMS_VECTORIZE_VPLANBACKENDCOSTMODEL_H
#include "llvm/ADT/SmallVector.h"
#include "llvm/Support/InstructionCost.h"
#include "llvm/Transforms/Vectorize/VPlanBackendFeedback.h"
namespace llvm {
class LLVMContext;
class VPlan;
class TargetTransformInfo;
class LoopVectorizationPlanner;
struct VFSelectionContext;
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
  bool operator<(VPExactCost B) const;
  bool operator<=(VPExactCost B) const;
  bool operator==(VPExactCost B) const;
};
struct VPBackendCostEntry {
  const VPlan *Plan;
  ElementCount VF;
  unsigned IC;
  bool IsEpilogue;
  InstructionCost Native, Profile, EstimatedVectorSpill;
  VPExactCost Body;
};
/// All state belongs to one original loop. Preparation is transactional: on
/// failure discard every score before native selection can observe the table.
class VPlanBackendCostModel {
  SmallVector<VPBackendCostEntry> Costs;
  const VPlanBackendFeedback &Feedback;
  const TargetTransformInfo &TTI;
  Function &F;
  BasicBlock &Header;
  unsigned LoopIndex = 0, Invocation = 0;
  bool InterleaveOnly = false, VectorizeOnly = false;
  bool Failed = false;
  std::string Failure;

public:
  VPlanBackendCostModel(const VPlanBackendFeedback &Feedback,
                        const TargetTransformInfo &TTI, Function &F,
                        BasicBlock &Header)
      : Feedback(Feedback), TTI(TTI), F(F), Header(Header) {}
  bool prepare(LoopVectorizationPlanner &LVP, VFSelectionContext &Config,
               unsigned UserIC, unsigned Invocation, unsigned LoopIndex,
               bool InterleaveOnlyWhenForced, bool VectorizeOnlyWhenForced,
               ElementCount ForcedEpilogue);
  bool prepareEpilogue(LoopVectorizationPlanner &LVP,
                       VFSelectionContext &Config, VPlan &MainPlan,
                       ElementCount MainVF, unsigned MainIC, VPlan &Plan,
                       ElementCount VF);
  bool add(VPlan &Plan, VPlanBackendCandidate Candidate, InstructionCost Native,
           InstructionCost Profile, InstructionCost Ev, unsigned Width);
  const VPBackendCostEntry *lookup(const VPlan &Plan, ElementCount VF,
                                   bool Epilogue = false) const;
  void fail(StringRef Reason);
  void selection(ElementCount VF, unsigned IC, ElementCount Epilogue,
                 bool Emitted) const;
  bool failed() const { return Failed; }
  StringRef failure() const { return Failure; }
};
/// Strict adapter for the in-process facts; no cost rules live in the backend.
LLVM_ABI_FOR_TEST Expected<VPExactCost>
priceVPlanVectorSpills(const json::Object &Observation,
                       const TargetTransformInfo &TTI, LLVMContext &Context,
                       unsigned Width, InstructionCost &RawCost);
} // namespace llvm
#endif
