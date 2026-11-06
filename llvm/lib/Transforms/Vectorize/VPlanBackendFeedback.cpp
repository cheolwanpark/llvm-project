//===- VPlanBackendFeedback.cpp - Candidate backend queries
//----------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Vectorize/VPlanBackendFeedback.h"
#include "llvm/Analysis/LoopBackedgeAnalysis.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/Function.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/raw_ostream.h"

using namespace llvm;

static cl::opt<bool>
    EnableBackendCostModel("vplan-backend", cl::Hidden, cl::init(false),
                           cl::desc("Select VF using scoped TTI and observed "
                                    "scalar and vector spill costs"));
static cl::opt<bool>
    UseMIR("use-mir", cl::Hidden, cl::init(false),
           cl::desc("Use target MIR direct cost for VPlan backend body costs"));
static cl::opt<bool> UseEstimatedSpill(
    "use-estimated-spill", cl::Hidden, cl::init(false),
    cl::desc("Use estimated spill costs in VPlan backend selection"));
bool llvm::vplanBackendUseMIR() { return EnableBackendCostModel && UseMIR; }
bool llvm::vplanBackendUseEstimatedSpill() {
  return EnableBackendCostModel && UseEstimatedSpill;
}
StringRef VPlanBackendMode::name() const {
  if (MIR)
    return EstimatedSpill ? "mir-me-spill-v2" : "mir-v2";
  return EstimatedSpill ? "llvm-v1" : "llvm-real-spill-v2";
}
StringRef llvm::vplanBackendModelName() {
  return VPlanBackendMode::requested().name();
}
static cl::opt<std::string> FeedbackOutput(
    "vplan-backend-jsonl", cl::Hidden,
    cl::desc("Append candidate feedback as JSONL (diagnostic only)"));
static cl::opt<bool>
    ForceAllFeedback("vplan-backend-force-all", cl::Hidden,
                     cl::desc("Bypass candidate cost lower-bound pruning"));

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

static json::Object summarizeObservation(const VPlanBackendObservation &O,
                                         bool MIR) {
  json::Object Result{
      {"schema", MIR ? "mir-body-observation-v6" : "register-spill-v6"},
      {"stage", O.Stage},
      {"iteration_mapping", O.IterationMapping},
      {"composition", "uniform-loop-mean"},
      {"loop_count", O.Loops.size()}};
  Result["mapping_kind"] = "backedge-loops";
  Result["region_granularity"] = "natural-loop-block-set";
  Result["body_cost_semantics"] = "static-block-sum";
  Result["selected_block_count"] = O.SelectedBlockCount;
  Result["materialized_width"] = O.MaterializedWidth;
  Result["mapping_policy_revision"] = O.MappingPolicyRevision;
  Result["normalization_policy_revision"] = O.NormalizationPolicyRevision;
  json::Array Loops;
  for (const auto &L : O.Loops) {
    json::Object Loop{{"id", L.ID},
                      {"tracking_id", L.TrackingID},
                      {"iteration_width", L.IterationWidth},
                      {"selected_block_count", L.SelectedBlockCount}};
    if (!MIR) {
      json::Array Accesses;
      for (const auto &A : L.Spills)
        Accesses.push_back(json::Object{
            {"load", A.IsLoad},
            {"class", A.Kind == VPlanSpillAccess::RegisterKind::Vector
                          ? "vector"
                      : A.Kind == VPlanSpillAccess::RegisterKind::Integer
                          ? "integer"
                          : "floating-point"},
            {"bytes", A.MinBytes},
            {"scalable", A.Scalable},
            {"alignment", A.Alignment},
            {"address_space", A.AddressSpace},
            {"whole_register", A.WholeRegister},
            {"register_group", A.RegisterGroup},
            {"segment_lowering", A.FromSegment}});
      Loop["spills"] = std::move(Accesses);
    }
    if (L.MIRBody) {
      json::Array Body;
      for (const auto &MI : *L.MIRBody) {
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
                        {"memory_alignment", MI.MemoryAlignment},
                        {"address_space", MI.AddressSpace},
                        {"call", MI.Call},
                        {"matrix_lambda", MI.MatrixLambda},
                        {"register_groups8", std::move(Groups)}};
        if (MI.InlineAsmArguments)
          Op["inline_asm_arguments"] = *MI.InlineAsmArguments;
        if (!MI.Text.empty())
          Op["mir"] = MI.Text;
        Body.push_back(std::move(Op));
      }
      Loop["body"] = std::move(Body);
    }
    Loops.push_back(std::move(Loop));
  }
  Result["loops"] = std::move(Loops);
  Result["status"] = vplanBackendObservationStatusName(O.Status);
  return Result;
}
json::Object llvm::summarizeVPlanBackendResult(const VPlanBackendResult &R) {
  auto SpillObservation = summarizeObservation(R.Spill, false);
  auto MIRObservation = summarizeObservation(R.MIR, true);
  json::Object Result;
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
  Result["observation_schema"] = "backedge-loop-observations-v5";
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

void llvm::registerVPlanBackendRegion(Function &F, Loop *L, uint64_t Width) {
  auto *T = LoopBackedgeTracking::get(&F);
  if (!T)
    return;
  T->Identity =
      F.getFnAttribute("vplan.backend.candidate").getValueAsString().str();
  T->Role = F.getFnAttribute("vplan.backend.role").getValueAsString().str();
  T->MaterializedWidth = Width;
  if (!L) {
    T->fail("unsupported-finite-body");
    return;
  }
  registerTrackedLoop(*T, *L, Width);
}

void llvm::setVPlanBackendCandidate(Function &F,
                                    const VPlanBackendCandidate &C) {
  if (auto *T = LoopBackedgeTracking::get(&F))
    T->CaptureFailures = C.Observation.CaptureFailures;
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

json::Array
llvm::summarizeVPlanBackendFailures(ArrayRef<VPlanBackendFailure> Failures) {
  std::vector<VPlanBackendFailure> Sorted(Failures.begin(), Failures.end());
  llvm::sort(Sorted);
  Sorted.erase(std::unique(Sorted.begin(), Sorted.end()), Sorted.end());
  json::Array Groups;
  for (unsigned G = 0; G != 6; ++G) {
    json::Array Items;
    for (const auto &F : Sorted) {
      if (unsigned(F.Group) != G)
        continue;
      json::Object Item{
          {"candidate", F.Candidate}, {"stage", F.Stage}, {"detail", F.Detail}};
      if (F.TrackingID)
        Item["tracking_id"] = *F.TrackingID;
      if (F.ObservationID)
        Item["observation_id"] = *F.ObservationID;
      Items.push_back(std::move(Item));
    }
    if (!Items.empty())
      Groups.push_back(json::Object{
          {"id", vplanBackendFailureGroupName(VPlanBackendFailureGroup(G))},
          {"count", Items.size()},
          {"items", std::move(Items)}});
  }
  return Groups;
}
void llvm::emitVPlanBackendFailures(StringRef Function, unsigned Invocation,
                                    unsigned Loop, VPlanBackendMode Requested,
                                    StringRef Effective,
                                    const json::Array &Attempts) {
  if (!vplanBackendFeedbackOutputEnabled() ||
      llvm::none_of(Attempts, [](const json::Value &A) {
        auto *Groups = A.getAsObject()->getArray("failures");
        return Groups && !Groups->empty();
      }))
    return;
  writeVPlanBackendFeedback(
      json::Object{{"schema", "vplan-backend-failures-v1"},
                   {"status", "backend-failures"},
                   {"function", Function},
                   {"invocation", Invocation},
                   {"loop", Loop},
                   {"requested_model", Requested.name()},
                   {"effective_model", Effective},
                   {"requested_estimated_spill", Requested.EstimatedSpill},
                   {"attempts", json::Array(Attempts)}});
}
