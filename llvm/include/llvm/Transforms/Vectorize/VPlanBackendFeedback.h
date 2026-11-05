//===- VPlanBackendFeedback.h - Candidate backend queries ---------*- C++ -*-===//
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
#include "llvm/Support/ScopedPassCancellation.h"
#include "llvm/Support/TypeSize.h"
#include "llvm/Support/VPlanBackendResult.h"
#include <functional>
#include <memory>
#include <tuple>

namespace llvm {
class BasicBlock;
class Loop;

struct VPlanBackendProbeResult;
/// Completion runs on the calling compiler thread, after worker cleanup.
struct VPlanBackendProbeControl {
  PassCancellation Cancellation;
  bool Started = false; // Worker-owned until completion.
  std::function<void(const VPlanBackendProbeResult &)> Completed;
};

/// Identity is local to a planning invocation, not a persistent cache key.
/// Geometry is explicit and local to this planning invocation.
struct VPlanBackendCandidateIdentity {
  std::string ID;
  unsigned PlanIndex = 0;
  ElementCount VF = ElementCount::getFixed(1);
  unsigned IC = 1;
  bool IsEpilogue = false;
  VPlanBackendCandidateKind Kind = VPlanBackendCandidateKind::Vector;
  bool operator==(const VPlanBackendCandidateIdentity &B) const {
    return std::tie(ID, PlanIndex, VF, IC, IsEpilogue, Kind) ==
           std::tie(B.ID, B.PlanIndex, B.VF, B.IC, B.IsEpilogue, B.Kind);
  }
};

struct VPlanBackendMaterializationContext {
  bool ScalarTail = false;
  bool InterleaveOnlyWhenForced = false;
  bool VectorizeOnlyWhenForced = false;
  unsigned MainPlanIndex = 0;
  ElementCount MainVF = ElementCount::getFixed(1);
  unsigned MainIC = 1;
  ElementCount EpilogueVF = ElementCount::getFixed(0);
  bool operator==(const VPlanBackendMaterializationContext &B) const {
    return std::tie(ScalarTail, InterleaveOnlyWhenForced,
                    VectorizeOnlyWhenForced, MainPlanIndex, MainVF, MainIC,
                    EpilogueVF) ==
           std::tie(B.ScalarTail, B.InterleaveOnlyWhenForced,
                    B.VectorizeOnlyWhenForced, B.MainPlanIndex, B.MainVF,
                    B.MainIC, B.EpilogueVF);
  }
};

/// One execution request. Only the identity and materialization context belong
/// in a raw observation key; options and callbacks describe this execution.
struct VPlanBackendCandidate : VPlanBackendCandidateIdentity,
                               VPlanBackendMaterializationContext {
  VPlanBackendObservationOptions Observation{};
  std::shared_ptr<VPlanBackendProbeControl> Control{};

  VPlanBackendCandidate(std::string ID, unsigned PlanIndex, ElementCount VF,
                        bool ScalarTail, bool InterleaveOnlyWhenForced,
                        bool VectorizeOnlyWhenForced)
      : VPlanBackendCandidateIdentity{std::move(ID), PlanIndex, VF},
        VPlanBackendMaterializationContext{ScalarTail, InterleaveOnlyWhenForced,
                                           VectorizeOnlyWhenForced} {}
};

/// Explicit per-pass state for materializing a candidate on a disposable clone.
/// It never changes command-line options during materialization.
struct VPlanBackendProbe {
  const VPlanBackendCandidate &Candidate;
  BasicBlock *Header;
  bool Emitted = false;
  std::optional<VPlanBackendFailure> Error = std::nullopt;
};

/// A completed query, including diagnostics owned independently of its context.
/// Errors are consumed into owned records at the provider boundary so
/// discarding an unneeded speculative suffix never leaves unchecked
/// llvm::Errors behind.
struct VPlanBackendProbeResult {
  std::optional<VPlanBackendResult> Observation;
  std::optional<VPlanBackendFailure> Failure;
  std::string Diagnostics;
  bool Cancelled = false;

  VPlanBackendProbeResult(Expected<VPlanBackendResult> Result,
                          std::string Diagnostics = {})
      : Diagnostics(std::move(Diagnostics)) {
    if (Result)
      Observation = std::move(*Result);
    else
      Failure = takeVPlanBackendFailure(
          Result.takeError(), VPlanBackendFailureGroup::Execution, "", "probe");
  }

  Expected<VPlanBackendResult> takeResult() {
    if (!Observation)
      return vplanBackendError(*Failure);
    return std::move(*Observation);
  }
};

/// A dependency-inverted service: Vectorize does not link CodeGen or Passes.
/// The provider owns cloning, fresh analyses and the backend invocation.
/// Results own their data; no MachineFunction/Instruction pointers escape the
/// query.
class VPlanBackendFeedback {
public:
  using Batch = SmallVector<VPlanBackendProbeResult, 0>;
  using Query = std::function<Expected<Batch>(
      const Function &, const BasicBlock &, ArrayRef<VPlanBackendCandidate>)>;
  using BatchPolicy = std::function<bool(const Function &)>;
  using InvocationSetup = std::function<void()>;

  using MIRInfoProvider =
      std::function<std::unique_ptr<TargetMIRInfo>(const Function &)>;
  explicit VPlanBackendFeedback(Query Q = {}, BatchPolicy Policy = {},
                                MIRInfoProvider MIRInfo = {},
                                InvocationSetup Setup = {})
      : QueryCandidates(std::move(Q)), Policy(std::move(Policy)),
        MIRInfo(std::move(MIRInfo)), Setup(std::move(Setup)) {}
  std::unique_ptr<TargetMIRInfo> getMIRInfo(const Function &F) const {
    return MIRInfo ? MIRInfo(F) : nullptr;
  }

  /// Reset per-invocation diagnostics independently of capacity queries.
  void beginInvocation() const {
    if (Setup)
      Setup();
  }
  bool canBatch(const Function &F) const { return Policy && Policy(F); }

  Expected<Batch> getBatch(const Function &F, const BasicBlock &Header,
                           ArrayRef<VPlanBackendCandidate> Candidates) const {
    if (Candidates.empty())
      return Batch();
    if (!QueryCandidates)
      return vplanBackendError(VPlanBackendFailureGroup::Availability,
                               "backend feedback provider unavailable", "",
                               "input");
    auto Results = QueryCandidates(F, Header, Candidates);
    if (!Results)
      return Results.takeError();
    if (Results->size() != Candidates.size())
      return vplanBackendError(VPlanBackendFailureGroup::Integrity,
                               "backend feedback batch size mismatch", "",
                               "probe");
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
  InvocationSetup Setup;
};

class VPlanBackendFeedbackAnalysis
    : public AnalysisInfoMixin<VPlanBackendFeedbackAnalysis> {
  friend AnalysisInfoMixin<VPlanBackendFeedbackAnalysis>;
  LLVM_ABI static AnalysisKey Key;
  VPlanBackendFeedback::Query Query;
  VPlanBackendFeedback::BatchPolicy Policy;
  VPlanBackendFeedback::MIRInfoProvider MIRInfo;
  VPlanBackendFeedback::InvocationSetup Setup;

public:
  using Result = VPlanBackendFeedback;
  explicit VPlanBackendFeedbackAnalysis(
      VPlanBackendFeedback::Query Q = {},
      VPlanBackendFeedback::BatchPolicy Policy = {},
      VPlanBackendFeedback::MIRInfoProvider MIRInfo = {},
      VPlanBackendFeedback::InvocationSetup Setup = {})
      : Query(std::move(Q)), Policy(std::move(Policy)),
        MIRInfo(std::move(MIRInfo)), Setup(std::move(Setup)) {}
  Result run(Function &, FunctionAnalysisManager &) {
    return Result(Query, Policy, MIRInfo, Setup);
  }
};

LLVM_ABI bool vplanBackendFeedbackEnabled();
LLVM_ABI bool vplanBackendUseMIR();
LLVM_ABI bool vplanBackendUseEstimatedSpill();
LLVM_ABI bool vplanBackendUseDefaultTTI();
struct VPlanBackendMode {
  bool MIR = false, EstimatedSpill = false, DefaultTTI = false;
  LLVM_ABI StringRef name() const;
  bool needsProbe() const { return MIR || !EstimatedSpill; }
  static VPlanBackendMode requested() {
    return {vplanBackendUseMIR(), vplanBackendUseEstimatedSpill(),
            vplanBackendUseDefaultTTI()};
  }
};
LLVM_ABI StringRef vplanBackendModelName();
LLVM_ABI bool vplanBackendFeedbackTimingEnabled();
LLVM_ABI StringRef
vplanBackendObservationStatusName(VPlanBackendObservationStatus Status);
LLVM_ABI json::Object summarizeVPlanBackendResult(const VPlanBackendResult &R);
/// Diagnostic oracle: retain the gate's decision but query every candidate.
LLVM_ABI bool vplanBackendFeedbackForceAll();
LLVM_ABI bool vplanBackendFeedbackOutputEnabled();
/// Append diagnostics only when a JSONL destination was requested.
LLVM_ABI void writeVPlanBackendFeedback(const json::Object &Result);
LLVM_ABI json::Array
summarizeVPlanBackendFailures(ArrayRef<VPlanBackendFailure> Failures);
LLVM_ABI void emitVPlanBackendFailures(StringRef Function, unsigned Invocation,
                                       unsigned Loop,
                                       VPlanBackendMode Requested,
                                       StringRef Effective,
                                       const json::Array &Attempts);
LLVM_ABI void setVPlanBackendCandidate(Function &F,
                                       const VPlanBackendCandidate &Candidate);
LLVM_ABI void registerVPlanBackendRegion(Function &F, Loop *L, uint64_t Width);
} // namespace llvm

#endif
