//===- VPlanBackendFeedback.h - Candidate backend queries ---------*- C++
//-*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_VECTORIZE_VPLANBACKENDFEEDBACK_H
#define LLVM_TRANSFORMS_VECTORIZE_VPLANBACKENDFEEDBACK_H

#include "llvm/IR/PassManager.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/JSON.h"
#include "llvm/Support/TypeSize.h"
#include <functional>

namespace llvm {
class BasicBlock;

/// Identity is local to a planning invocation, not a persistent cache key.
/// Probe geometry is always IC=1 without a separate vector epilogue.
struct VPlanBackendCandidate {
  std::string ID;
  unsigned PlanIndex;
  ElementCount VF;
  bool ScalarTail;
  bool InterleaveOnlyWhenForced;
  bool VectorizeOnlyWhenForced;
};

/// Explicit per-pass state for materializing a candidate on a disposable clone.
/// It never changes command-line options or the external RA transport.
struct VPlanBackendProbe {
  const VPlanBackendCandidate &Candidate;
  BasicBlock *Header;
  bool Emitted = false;
  std::string Error;
  json::Value ScalarCost = nullptr;
  json::Object MiddleEnd;
};

/// A dependency-inverted service: Vectorize does not link CodeGen or Passes.
/// The provider owns cloning, fresh analyses and the backend invocation.
/// Results own their data; no MachineFunction/Instruction pointers escape the
/// query.
class VPlanBackendFeedback {
public:
  using Query = std::function<Expected<json::Object>(
      const Function &, const BasicBlock &, const VPlanBackendCandidate &)>;

  explicit VPlanBackendFeedback(Query Q = {}) : QueryCandidate(std::move(Q)) {}

  Expected<json::Object> get(const Function &F, const BasicBlock &Header,
                             const VPlanBackendCandidate &Candidate) const {
    if (!QueryCandidate)
      return createStringError("backend feedback provider unavailable");
    return QueryCandidate(F, Header, Candidate);
  }

  bool invalidate(Function &, const PreservedAnalyses &,
                  FunctionAnalysisManager::Invalidator &) {
    // Only a service handle; observations are scoped to the caller's plan.
    return false;
  }

private:
  Query QueryCandidate;
};

class VPlanBackendFeedbackAnalysis
    : public AnalysisInfoMixin<VPlanBackendFeedbackAnalysis> {
  friend AnalysisInfoMixin<VPlanBackendFeedbackAnalysis>;
  LLVM_ABI static AnalysisKey Key;
  VPlanBackendFeedback::Query Query;

public:
  using Result = VPlanBackendFeedback;
  explicit VPlanBackendFeedbackAnalysis(VPlanBackendFeedback::Query Q = {})
      : Query(std::move(Q)) {}
  Result run(Function &, FunctionAnalysisManager &) { return Result(Query); }
};

LLVM_ABI bool vplanBackendFeedbackEnabled();
/// Diagnostic oracle: retain the gate's decision but query every candidate.
LLVM_ABI bool vplanBackendFeedbackForceAll();
/// Optional diagnostic JSONL/stderr output of the data stored in LV, after the
/// synchronous query returns and before the original VF selection runs.
LLVM_ABI void printVPlanBackendFeedback(const json::Object &Result);
} // namespace llvm

#endif
