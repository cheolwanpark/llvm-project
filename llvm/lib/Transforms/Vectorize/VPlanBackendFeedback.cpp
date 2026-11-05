//===- VPlanBackendFeedback.cpp - Candidate backend queries ----------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Vectorize/VPlanBackendFeedback.h"
#include "llvm/Analysis/RelatedBlockAnalysis.h"
#include "llvm/IR/Function.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/raw_ostream.h"

using namespace llvm;

static cl::opt<bool> EnableBackendCostModel(
    "vplan-backend", cl::Hidden, cl::init(false),
    cl::desc("Select VF using scoped TTI and actual vector spill costs"));
static cl::opt<bool>
    UseMIR("use-mir", cl::Hidden, cl::init(false),
           cl::desc("Use target MIR direct cost for VPlan backend body costs"));
static cl::opt<bool> UseEstimatedSpill(
    "use-estimated-spill", cl::Hidden, cl::init(false),
    cl::desc("Use estimated spill costs in VPlan backend selection"));
static cl::opt<bool> UseDefaultTTI(
    "use-default-tti", cl::Hidden, cl::init(false),
    cl::desc("Use default TTI for all VPlan backend TTI queries"));
bool llvm::vplanBackendUseMIR() { return EnableBackendCostModel && UseMIR; }
bool llvm::vplanBackendUseEstimatedSpill() {
  return EnableBackendCostModel && UseEstimatedSpill;
}
bool llvm::vplanBackendUseDefaultTTI() {
  return EnableBackendCostModel && UseDefaultTTI;
}
StringRef VPlanBackendMode::name() const {
  if (MIR)
    return EstimatedSpill ? "mir-me-spill-v1" : "mir-v1";
  if (DefaultTTI)
    return EstimatedSpill ? "llvm-v1" : "llvm-real-vector-spill-v1";
  return EstimatedSpill ? "tti-v1" : "tti-real-vector-spill-v1";
}
StringRef llvm::vplanBackendModelName() {
  return VPlanBackendMode::requested().name();
}
static cl::opt<std::string> FeedbackOutput(
    "vplan-backend-jsonl", cl::Hidden,
    cl::desc("Append candidate feedback as JSONL (diagnostic only)"));
static cl::opt<bool> ForceAllFeedback(
    "vplan-backend-force-all", cl::Hidden,
    cl::desc("Query every candidate, retaining the register-bound decision"));

static cl::opt<bool>
    TimeFeedback("vplan-backend-time", cl::Hidden,
                 cl::desc("Print per-candidate spill probe phase timings"));
bool llvm::vplanBackendFeedbackTimingEnabled() { return TimeFeedback; }

StringRef
llvm::vplanBackendObservationStatusName(VPlanBackendObservationStatus Status) {
  switch (Status) {
  case VPlanBackendObservationStatus::NotCollected:
    return "not_collected";
  case VPlanBackendObservationStatus::NotRequested:
    return "not_requested";
  case VPlanBackendObservationStatus::Succeeded:
    return "succeeded";
  case VPlanBackendObservationStatus::Failed:
    return "failed";
  }
  llvm_unreachable("invalid observation status");
}

static json::Object summarizeObservation(const VPlanBackendObservation &O) {
  json::Array Accesses;
  for (const auto &A : O.Spills)
    Accesses.push_back(json::Object{{"load", A.IsLoad},
                                    {"bytes", A.MinBytes},
                                    {"scalable", A.Scalable},
                                    {"alignment", A.Alignment},
                                    {"address_space", A.AddressSpace},
                                    {"whole_register", A.WholeRegister},
                                    {"register_group", A.RegisterGroup},
                                    {"segment_lowering", A.FromSegment}});
  bool MIR = O.Stage == "post-frame-lowering";
  json::Object Result{
      {"schema", MIR ? "mir-body-observation-v2" : "rvv-vector-spill-v2"},
      {"stage", O.Stage},
      {"iteration_width", O.IterationWidth},
      {"iteration_mapping", O.IterationMapping},
      {"spills", std::move(Accesses)}};
  Result["mapping_kind"] = "related-blocks";
  Result["region_granularity"] = "machine-block-set";
  Result["body_cost_semantics"] = "static-block-sum";
  Result["mapping_status"] = O.MappingSucceeded         ? "succeeded"
                             : O.MappingFailure.empty() ? "not_collected"
                                                        : "failed";
  Result["mapping_failure"] = O.MappingFailure;
  Result["normalization_status"] = O.NormalizationSucceeded ? "succeeded"
                                   : O.NormalizationFailure.empty()
                                       ? "not_collected"
                                       : "failed";
  Result["normalization_failure"] = O.NormalizationFailure;
  Result["selected_block_count"] = O.SelectedBlockCount;
  Result["mixed_origin_block_count"] = O.MixedOriginBlockCount;
  Result["unresolved_block_count"] = O.UnresolvedBlockCount;
  Result["normalization_basis"] = O.NormalizationBasis;
  Result["trip_count_kind"] = O.TripCountKind;
  Result["trip_count_domain"] = "materialized-body";
  Result["trip_count_value"] = O.TripCount;
  Result["materialized_width"] = O.MaterializedWidth;
  Result["mapping_policy_revision"] = O.MappingPolicyRevision;
  Result["normalization_policy_revision"] = O.NormalizationPolicyRevision;
  if (MIR)
    Result.erase("spills");
  if (O.MIRBody) {
    json::Array Body;
    for (const auto &MI : *O.MIRBody) {
      json::Array Groups;
      for (auto G : MI.RegisterGroups8)
        Groups.push_back(G);
      json::Object Op{{"opcode", MI.Opcode},
                      {"base_opcode", MI.BaseOpcode},
                      {"vector", MI.Vector},
                      {"pseudo", MI.Pseudo},
                      {"configuration", MI.Configuration},
                      {"load", MI.Load},
                      {"store", MI.Store},
                      {"spill_slot", MI.Spill},
                      {"lmul8", MI.LMUL8},
                      {"sew", MI.SEW},
                      {"index_emul8", MI.IndexEMUL8},
                      {"index_eew", MI.IndexEEW},
                      {"register_groups8", std::move(Groups)}};
      if (!MI.Text.empty())
        Op["mir"] = MI.Text;
      Body.push_back(std::move(Op));
    }
    Result["body"] = std::move(Body);
  }
  Result["status"] = vplanBackendObservationStatusName(O.Status);
  Result["failure"] = O.Failure;
  return Result;
}
json::Object llvm::summarizeVPlanBackendResult(const VPlanBackendResult &R,
                                               bool MIR) {
  auto SpillObservation = summarizeObservation(R.Spill);
  auto MIRObservation = summarizeObservation(R.MIR);
  // Keep the legacy projection without serializing its payload twice.
  auto Result = json::Object(MIR && R.MIR.succeeded() ? MIRObservation
                                                      : SpillObservation);
  Result["candidate"] = R.Candidate;
  Result["vf"] = R.VF.getKnownMinValue();
  Result["scalable"] = R.VF.isScalable();
  Result["ic"] = R.IC;
  Result["observation_role"] =
      R.Kind == VPlanBackendCandidateKind::ScalarBaseline ? "scalar-baseline"
      : R.IsEpilogue                                      ? "epilogue"
                                                          : "main";
  Result["spill_observation"] = std::move(SpillObservation);
  Result["mir_observation"] = std::move(MIRObservation);
  Result["observation_schema"] = "related-block-observations-v3";
  return Result;
}

AnalysisKey VPlanBackendFeedbackAnalysis::Key;

bool llvm::vplanBackendFeedbackOutputEnabled() {
  return !FeedbackOutput.empty();
}

bool llvm::vplanBackendFeedbackEnabled() { return EnableBackendCostModel; }

bool llvm::vplanBackendFeedbackForceAll() { return ForceAllFeedback; }

void llvm::writeVPlanBackendFeedback(const json::Object &Result) {
  if (FeedbackOutput.empty())
    return;
  std::error_code EC;
  raw_fd_ostream OS(FeedbackOutput, EC, sys::fs::OF_Append | sys::fs::OF_Text);
  if (EC)
    reportFatalUsageError(Twine("cannot write VPlan backend feedback: ") +
                          EC.message());
  OS << json::Value(json::Object(Result)) << '\n';
  OS.close();
  if (OS.has_error())
    reportFatalUsageError("failed to write VPlan backend feedback");
}

void llvm::registerVPlanBackendRegion(Function &F, ArrayRef<BasicBlock *> Body,
                                     Loop *L, ScalarEvolution &SE,
                                     uint64_t Width) {
  auto *T = RelatedBlockTracking::get(&F);
  if (!T)
    return;
  T->seed(Body, F.getFnAttribute("vplan.backend.candidate").getValueAsString(),
          F.getFnAttribute("vplan.backend.role").getValueAsString(), Width, !L);
  if (L) {
    auto Trip = getRelatedBlockTripCount(*L, SE);
    auto &N = T->Region.Normalization;
    N.TripCount = Trip.Value;
    N.TripCountKind = !Trip.Value       ? "unknown"
                      : Trip.UpperBound ? "upper-bound"
                                        : "exact";
  }
}

void llvm::setVPlanBackendCandidate(Function &F, const VPlanBackendCandidate &C) {
  F.addFnAttr("vplan.backend.candidate", C.ID);
  F.addFnAttr("vplan.backend.ic", std::to_string(C.IC));
  F.addFnAttr("vplan.backend.role",
              C.Kind == VPlanBackendCandidateKind::ScalarBaseline
                  ? "scalar-baseline"
              : C.IsEpilogue ? "epilogue"
                             : "main");
  F.addFnAttr("vplan.backend.vf", std::to_string(C.VF.getKnownMinValue()));
  F.addFnAttr("vplan.backend.scalable", C.VF.isScalable() ? "1" : "0");
}
