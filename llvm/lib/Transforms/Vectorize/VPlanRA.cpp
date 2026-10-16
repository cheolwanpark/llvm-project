//===- VPlanRA.cpp - Fixed transport for backend-informed VPlan research ---===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "llvm/Transforms/Vectorize/VPlanRA.h"
#include "VPlan.h"
#include "VPlanRACostModel.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/VirtualFileSystem.h"
#include "llvm/Support/raw_ostream.h"

using namespace llvm;
static cl::opt<VPlanPipelineStage> Pipeline(
    "vplan-pipeline", cl::Hidden, cl::init(VPlanPipelineStage::Full),
    cl::values(clEnumValN(VPlanPipelineStage::Full, "full", "Normal pipeline"),
               clEnumValN(VPlanPipelineStage::Prepare, "prepare", "Stop before LV"),
               clEnumValN(VPlanPipelineStage::Resume, "resume", "Resume before LV")));
static cl::opt<std::string> Manifest("vplan-candidates-output", cl::Hidden,
                                    cl::desc("Write VPlan RA candidate manifest"));
static cl::opt<std::string> Probe("vplan-probe-candidate", cl::Hidden,
                                 cl::desc("Materialize an enumerated candidate"));
static cl::opt<std::string> FeedbackPath("vplan-ra-feedback", cl::Hidden,
                                        cl::desc("Read candidate RA feedback"));
static cl::opt<std::string> RunID("vplan-ra-run-id", cl::Hidden,
                                 cl::desc("Checkpoint/compiler/options digest"));
static cl::opt<std::string> FeaturesOutput("vplan-ra-features-output", cl::Hidden,
                                          cl::desc("Write post-RA observations"));

namespace {
struct Transport {
  json::Array Candidates;
  json::Array Selections;
  StringMap<json::Object> Feedback;
  StringMap<bool> Consumed;
  bool Loaded = false;
  bool ProbeSelected = false;
};
Transport &state() {
  static Transport S;
  return S;
}
std::string vfName(ElementCount VF) {
  return (Twine(VF.isScalable() ? "s" : "f") +
          Twine(VF.getKnownMinValue())).str();
}
void loadFeedback(vfs::FileSystem &FS) {
  auto &S = state();
  if (S.Loaded)
    return;
  S.Loaded = true;
  if (FeedbackPath.empty())
    return;
  auto Buffer = FS.getBufferForFile(FeedbackPath);
  if (!Buffer)
    reportFatalUsageError(Twine("cannot read VPlan RA feedback: ") + FeedbackPath.getValue());
  auto Parsed = json::parse((*Buffer)->getBuffer());
  if (!Parsed)
    reportFatalUsageError(Twine("invalid VPlan RA feedback: ") + toString(Parsed.takeError()));
  auto *Root = Parsed->getAsObject();
  if (!Root || Root->getInteger("version") != 1 ||
      Root->getString("run_id") != StringRef(RunID))
    reportFatalUsageError("VPlan RA feedback version/run mismatch");
  auto *Rows = Root->getArray("candidates");
  if (!Rows)
    reportFatalUsageError("missing VPlan RA feedback candidates");
  for (auto &Row : *Rows) {
    auto *O = Row.getAsObject();
    auto ID = O ? O->getString("id") : std::nullopt;
    const auto *Selection = O ? O->getObject("selection") : nullptr;
    if (!ID || !O->getObject("features") || !Selection ||
        Selection->getString("id") != ID ||
        !Selection->getInteger("ic") || *Selection->getInteger("ic") < 1 ||
        !Selection->getString("epilogue_vf") ||
        !Selection->getBoolean("emitted") ||
        !S.Feedback.try_emplace(*ID, *O).second)
      reportFatalUsageError("invalid/duplicate VPlan RA feedback candidate");
  }
}
} // namespace

void llvm::initializeVPlanRA(vfs::FileSystem &FS) { loadFeedback(FS); }

VPlanPipelineStage llvm::getVPlanPipelineStage() { return Pipeline; }
bool llvm::vplanRAEnabled() {
  return !Manifest.empty() || !Probe.empty() || !FeedbackPath.empty();
}
StringRef llvm::getVPlanRAProbe() { return Probe.getValue(); }
StringRef llvm::getVPlanRARunID() { return RunID.getValue(); }
StringRef llvm::getVPlanRAFeaturesOutput() { return FeaturesOutput.getValue(); }

void llvm::writeVPlanRAJSON(StringRef Path, json::Value Value) {
  std::error_code EC;
  raw_fd_ostream OS(Path, EC, sys::fs::OF_Text);
  if (EC)
    reportFatalUsageError(Twine("cannot write VPlan RA artifact: ") + EC.message());
  OS << Value << '\n';
  OS.close();
  if (OS.has_error())
    reportFatalUsageError("failed to write VPlan RA artifact");
}

VPlanRAContext::VPlanRAContext(const Function &F, unsigned Index)
    : FunctionName(F.getName().str()), LoopIndex(Index),
      Prefix((F.getName() + ":" + Twine(Index) + ":").str()) {
  if (RunID.empty())
    reportFatalUsageError("VPlan RA requires -vplan-ra-run-id");
  if (!Probe.empty() && !FeedbackPath.empty())
    reportFatalUsageError("VPlan RA probe cannot consume feedback");
  if (!state().Loaded)
    loadFeedback(*vfs::getRealFileSystem());
}

void VPlanRAContext::registerPlan(const VPlan &Plan) { Plans.push_back(&Plan); }

std::string VPlanRAContext::candidateID(const VPlan &Plan, ElementCount VF) const {
  auto It = llvm::find(Plans, &Plan);
  assert(It != Plans.end() && "unregistered VPlan RA candidate");
  return Prefix + std::to_string(It - Plans.begin()) + ":" + vfName(VF);
}
bool VPlanRAContext::isProbe(const VPlan &Plan, ElementCount VF) const {
  return !Probe.empty() && Probe == candidateID(Plan, VF);
}
bool VPlanRAContext::probesThisLoop() const {
  return !Probe.empty() && StringRef(Probe).starts_with(Prefix);
}
void VPlanRAContext::recordCost(const VPlan &Plan, ElementCount VF,
                              InstructionCost Cost) {
  auto ID = candidateID(Plan, VF);
  OriginalCosts[ID] = Cost;
  std::string Text;
  raw_string_ostream OS(Text);
  OS << Cost;
  state().Candidates.push_back(json::Object{
      {"id", ID}, {"function", FunctionName}, {"loop", LoopIndex},
      {"vf", vfName(VF)}, {"body_cost", Text}, {"probeable", Cost.isValid()},
      {"scalar_tail", Plan.hasScalarTail()}});
  if (Cost.isValid() && !FeedbackPath.empty()) {
    auto It = state().Feedback.find(ID);
    if (It == state().Feedback.end())
      reportFatalUsageError(Twine("missing VPlan RA feedback for ") + ID);
    Feedback.try_emplace(ID, It->second);
    state().Consumed[ID] = true;
  }
}
InstructionCost VPlanRAContext::originalCost(const VPlan &Plan,
                                           ElementCount VF) const {
  return OriginalCosts.lookup(candidateID(Plan, VF));
}
InstructionCost VPlanRAContext::adjust(const VPlan &Plan, ElementCount VF,
                                     InstructionCost Cost) const {
  if (FeedbackPath.empty() || !Cost.isValid())
    return Cost;
  auto It = Feedback.find(candidateID(Plan, VF));
  if (It == Feedback.end())
    reportFatalUsageError("unregistered VPlan RA cost request");
  auto Adjusted = costWithRAFeatures(Plan, VF, Cost,
                                    *It->second.getObject("features"));
  if (!Adjusted.isValid() || Adjusted < 0)
    reportFatalUsageError("RA cost hook must return a valid nonnegative cost");
  return Adjusted;
}
void VPlanRAContext::selection(const VPlan &Plan, ElementCount VF, unsigned IC,
                               ElementCount EpilogueVF, bool Emitted) {
  auto ID = candidateID(Plan, VF);
  json::Object Selection{{"id", ID}, {"ic", IC},
                         {"epilogue_vf", vfName(EpilogueVF)},
                         {"emitted", Emitted}};
  state().Selections.push_back(std::move(Selection));
  if (isProbe(Plan, VF))
    state().ProbeSelected = true;
  if (!FeedbackPath.empty()) {
    auto It = Feedback.find(ID);
    if (It == Feedback.end())
      reportFatalUsageError("selected candidate has no VPlan RA feedback");
    const auto *Expected = It->second.getObject("selection");
    if (Expected->getInteger("ic") != int64_t(IC) ||
        Expected->getString("epilogue_vf") != vfName(EpilogueVF) ||
        (Emitted && Expected->getBoolean("emitted") != true))
      reportFatalUsageError("final VPlan configuration differs from RA probe");
  }
}
void llvm::finishVPlanRA(Module &M) {
  if (!vplanRAEnabled())
    return;
  if (!state().Loaded)
    loadFeedback(*vfs::getRealFileSystem());
  auto &S = state();
  if (!Probe.empty() && !S.ProbeSelected)
    reportFatalUsageError(Twine("VPlan RA probe was not materialized: ") + Probe.getValue());
  if (S.Consumed.size() != S.Feedback.size())
    reportFatalUsageError("unexpected/stale VPlan RA feedback candidates");
  if (!Manifest.empty())
    writeVPlanRAJSON(Manifest, json::Object{
        {"version", 1}, {"run_id", std::string(RunID)},
        {"triple", M.getTargetTriple().str()},
        {"candidates", std::move(S.Candidates)},
        {"selections", std::move(S.Selections)}});
  S = Transport();
}
