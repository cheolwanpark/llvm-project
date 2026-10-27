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

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/TargetMIRInfo.h"
#include "llvm/IR/PassManager.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/JSON.h"
#include "llvm/Support/TypeSize.h"
#include "llvm/Support/VPlanBackendResult.h"
#include <functional>

namespace llvm {
class BasicBlock;
class Loop;
class ScalarEvolution;

/// Identity is local to a planning invocation, not a persistent cache key.
/// Geometry is explicit and local to this planning invocation.
struct VPlanBackendCandidate {
  std::string ID;
  unsigned PlanIndex;
  ElementCount VF;
  bool ScalarTail;
  bool InterleaveOnlyWhenForced;
  bool VectorizeOnlyWhenForced;
  unsigned IC = 1;
  bool IsEpilogue = false;
  // Epilogue probes materialize the selected main and the requested epilogue.
  unsigned MainPlanIndex = 0;
  ElementCount MainVF = ElementCount::getFixed(1);
  unsigned MainIC = 1;
  ElementCount EpilogueVF = ElementCount::getFixed(0);
  VPlanBackendObservationOptions Observation;
};

/// Explicit per-pass state for materializing a candidate on a disposable clone.
/// It never changes command-line options during materialization.
struct VPlanBackendProbe {
  const VPlanBackendCandidate &Candidate;
  BasicBlock *Header;
  bool Emitted = false;
  std::string Error;
};

/// A completed query, including diagnostics owned independently of its context.
/// Errors are consumed into strings at the provider boundary so discarding an
/// unneeded speculative suffix never leaves unchecked llvm::Errors behind.
struct VPlanBackendProbeResult {
  std::optional<VPlanBackendResult> Observation;
  std::string Failure;
  std::string Diagnostics;

  VPlanBackendProbeResult(Expected<VPlanBackendResult> Result,
                          std::string Diagnostics = {})
      : Diagnostics(std::move(Diagnostics)) {
    if (Result)
      Observation = std::move(*Result);
    else
      Failure = toString(Result.takeError());
  }

  Expected<VPlanBackendResult> takeResult() {
    if (!Observation)
      return createStringError(Failure);
    return std::move(*Observation);
  }
};

/// A dependency-inverted service: Vectorize does not link CodeGen or Passes.
/// The provider owns cloning, fresh analyses and the backend invocation.
/// Results own their data; no MachineFunction/Instruction pointers escape the
/// query.
class VPlanBackendFeedback {
public:
  using Batch = SmallVector<VPlanBackendProbeResult>;
  using Query = std::function<Expected<Batch>(
      const Function &, const BasicBlock &, ArrayRef<VPlanBackendCandidate>)>;
  using BatchPolicy = std::function<bool(const Function &)>;

  using MIRInfoProvider =
      std::function<std::unique_ptr<TargetMIRInfo>(const Function &)>;
  explicit VPlanBackendFeedback(Query Q = {}, BatchPolicy Policy = {},
                                MIRInfoProvider MIRInfo = {})
      : QueryCandidates(std::move(Q)), Policy(std::move(Policy)),
        MIRInfo(std::move(MIRInfo)) {}
  std::unique_ptr<TargetMIRInfo> getMIRInfo(const Function &F) const {
    return MIRInfo ? MIRInfo(F) : nullptr;
  }

  /// Called once at the start of main-candidate preparation. The provider may
  /// reset its per-loop serial-query diagnostic accounting here.
  bool canBatch(const Function &F) const { return Policy && Policy(F); }

  Expected<Batch> getBatch(const Function &F, const BasicBlock &Header,
                           ArrayRef<VPlanBackendCandidate> Candidates) const {
    if (Candidates.empty())
      return Batch();
    if (!QueryCandidates)
      return createStringError("backend feedback provider unavailable");
    auto Results = QueryCandidates(F, Header, Candidates);
    if (!Results)
      return Results.takeError();
    if (Results->size() != Candidates.size())
      return createStringError("backend feedback batch size mismatch");
    return Results;
  }

  Expected<VPlanBackendResult>
  get(const Function &F, const BasicBlock &Header,
      const VPlanBackendCandidate &Candidate) const {
    auto Results = getBatch(F, Header, {Candidate});
    if (!Results)
      return Results.takeError();
    errs() << Results->front().Diagnostics;
    return Results->front().takeResult();
  }

  bool invalidate(Function &, const PreservedAnalyses &,
                  FunctionAnalysisManager::Invalidator &) {
    // Only a service handle; observations are scoped to the caller's plan.
    return false;
  }

private:
  Query QueryCandidates;
  BatchPolicy Policy;
  MIRInfoProvider MIRInfo;
};

class VPlanBackendFeedbackAnalysis
    : public AnalysisInfoMixin<VPlanBackendFeedbackAnalysis> {
  friend AnalysisInfoMixin<VPlanBackendFeedbackAnalysis>;
  LLVM_ABI static AnalysisKey Key;
  VPlanBackendFeedback::Query Query;
  VPlanBackendFeedback::BatchPolicy Policy;
  VPlanBackendFeedback::MIRInfoProvider MIRInfo;

public:
  using Result = VPlanBackendFeedback;
  explicit VPlanBackendFeedbackAnalysis(
      VPlanBackendFeedback::Query Q = {},
      VPlanBackendFeedback::BatchPolicy Policy = {},
      VPlanBackendFeedback::MIRInfoProvider MIRInfo = {})
      : Query(std::move(Q)), Policy(std::move(Policy)),
        MIRInfo(std::move(MIRInfo)) {}
  Result run(Function &, FunctionAnalysisManager &) {
    return Result(Query, Policy, MIRInfo);
  }
};

LLVM_ABI bool vplanBackendFeedbackEnabled();
LLVM_ABI bool vplanBackendUseMIR();
LLVM_ABI bool vplanBackendUseEstimatedSpill();
LLVM_ABI bool vplanBackendUseDefaultTTI();
LLVM_ABI StringRef vplanBackendModelName();
LLVM_ABI bool vplanBackendFeedbackTimingEnabled();
LLVM_ABI json::Object summarizeVPlanBackendResult(const VPlanBackendResult &R);
/// Diagnostic oracle: retain the gate's decision but query every candidate.
LLVM_ABI bool vplanBackendFeedbackForceAll();
LLVM_ABI bool vplanBackendFeedbackOutputEnabled();
/// Append diagnostics only when a JSONL destination was requested.
LLVM_ABI void writeVPlanBackendFeedback(const json::Object &Result);
LLVM_ABI void markVPlanBackendLoop(Loop &L, StringRef ID, ScalarEvolution &SE);
LLVM_ABI void finalizeVPlanBackendIterationMapping(Function &F,
                                                   FunctionAnalysisManager &AM);
} // namespace llvm

#endif
