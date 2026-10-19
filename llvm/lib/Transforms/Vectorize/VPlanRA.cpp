//===- VPlanRA.cpp - Fixed transport for backend-informed VPlan research ---===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "llvm/Transforms/Vectorize/VPlanRA.h"
#include "VPlan.h"
#include "llvm/ADT/APInt.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/ScalarEvolution.h"
#include "llvm/Analysis/ScalarEvolutionExpressions.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/IntrinsicInst.h"
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

namespace {
IntrusiveRefCntPtr<vfs::FileSystem> InputFS;
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
  if (!Root || Root->getInteger("version") != 2 ||
      Root->getString("run_id") != StringRef(RunID))
    reportFatalUsageError("VPlan RA feedback version/run mismatch");
  auto *Rows = Root->getArray("candidates");
  if (!Rows)
    reportFatalUsageError("missing VPlan RA feedback candidates");
  for (auto &Row : *Rows) {
    auto *O = Row.getAsObject();
    auto ID = O ? O->getString("id") : std::nullopt;
    const auto *Selection = O ? O->getObject("selection") : nullptr;
    if (!ID || !O->getObject("cost") || !Selection ||
        Selection->getString("id") != ID || !Selection->getInteger("ic") ||
        *Selection->getInteger("ic") < 1 ||
        !Selection->getString("epilogue_vf") ||
        !Selection->getBoolean("emitted") ||
        !S.Feedback.try_emplace(*ID, *O).second)
      reportFatalUsageError("invalid/duplicate VPlan RA feedback candidate");
  }
}
} // namespace

void llvm::initializeVPlanRA(vfs::FileSystem &FS) {
  InputFS = &FS;
  loadFeedback(FS);
}
Expected<json::Value> llvm::readVPlanRAJSON(StringRef Path) {
  auto FS = InputFS ? InputFS : vfs::getRealFileSystem();
  auto Buffer = FS->getBufferForFile(Path);
  if (!Buffer)
    return errorCodeToError(Buffer.getError());
  return json::parse((*Buffer)->getBuffer());
}

VPlanPipelineStage llvm::getVPlanPipelineStage() { return Pipeline; }
bool llvm::vplanRAEnabled() {
  return !Manifest.empty() || !Probe.empty() || !FeedbackPath.empty();
}
StringRef llvm::getVPlanRAProbe() { return Probe.getValue(); }
StringRef llvm::getVPlanRARunID() { return RunID.getValue(); }
bool llvm::vplanRAHasFeedback() { return !FeedbackPath.empty(); }

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
void VPlanRAContext::recordCandidate(const VPlan &Plan, ElementCount VF) {
  auto ID = candidateID(Plan, VF);
  state().Candidates.push_back(
      json::Object{{"id", ID},
                   {"function", FunctionName},
                   {"loop", LoopIndex},
                   {"vf", vfName(VF)},
                   {"probeable", true},
                   {"scalar_tail", Plan.hasScalarTail()}});
  if (!FeedbackPath.empty()) {
    auto It = state().Feedback.find(ID);
    if (It == state().Feedback.end())
      reportFatalUsageError(Twine("missing backend cost for ") + ID);
    (void)parseBackendCost(*It->second.getObject("cost"));
    Feedback.try_emplace(ID, It->second);
    state().Consumed[ID] = true;
  }
}
VPlanBackendCost VPlanRAContext::cost(const VPlan &Plan,
                                      ElementCount VF) const {
  auto It = Feedback.find(candidateID(Plan, VF));
  if (It == Feedback.end())
    reportFatalUsageError("unregistered backend cost request");
  return parseBackendCost(*It->second.getObject("cost"));
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
    writeVPlanRAJSON(Manifest,
                     json::Object{{"version", 2},
                                  {"run_id", std::string(RunID)},
                                  {"triple", M.getTargetTriple().str()},
                                  {"candidates", std::move(S.Candidates)},
                                  {"selections", std::move(S.Selections)}});
  S = Transport();
}

int64_t llvm::costQuarters(InstructionCost C) {
  assert(C.isValid() && C >= 0);
  int64_t Whole = C.getValue();
  return Whole * 4 + ((C - Whole) * 4).getValue();
}
json::Object llvm::serializeBackendCost(const VPlanBackendCost &C) {
  return json::Object{{"body_quarters", costQuarters(C.Body)},
                      {"scalar_quarters", costQuarters(C.ScalarBody)},
                      {"score_quarters", costQuarters(C.Score)},
                      {"divisor", C.Divisor},
                      {"width", C.Width},
                      {"scalar_width", C.ScalarWidth},
                      {"kind", C.Kind},
                      {"breakdown", json::Object(C.Breakdown)}};
}
VPlanBackendCost llvm::parseBackendCost(const json::Object &O) {
  auto Read = [&](StringRef Key) {
    auto Q = O.getInteger(Key);
    if (!Q || *Q < 0)
      reportFatalUsageError("invalid backend cost numerator");
    return InstructionCost(*Q / 4) + InstructionCost(*Q % 4) / 4;
  };
  VPlanBackendCost C;
  C.Body = Read("body_quarters");
  C.ScalarBody = Read("scalar_quarters");
  C.Score = Read("score_quarters");
  auto D = O.getInteger("divisor");
  auto K = O.getString("kind");
  if (!D || *D <= 0 || uint64_t(*D) > UINT32_MAX || !K ||
      (*K != "whole-loop" && *K != "cost-per-lane"))
    reportFatalUsageError("invalid backend cost denominator/kind");
  auto W = O.getInteger("width"), SW = O.getInteger("scalar_width");
  if (!W || !SW || *W <= 0 || *SW <= 0 || uint64_t(*W) > UINT32_MAX ||
      uint64_t(*SW) > UINT32_MAX)
    reportFatalUsageError("invalid backend iteration width");
  C.Width = *W;
  C.ScalarWidth = *SW;
  C.Divisor = *D;
  C.Kind = K->str();
  if (auto *B = O.getObject("breakdown"))
    C.Breakdown = *B;
  return C;
}
bool llvm::backendCostLess(const VPlanBackendCost &A,
                           const VPlanBackendCost &B) {
  if (A.Kind != B.Kind)
    reportFatalUsageError("inconsistent backend score kinds");
  return (APInt(128, costQuarters(A.Score)) * B.Divisor)
      .ult(APInt(128, costQuarters(B.Score)) * A.Divisor);
}

static MDNode *tag(LLVMContext &C, StringRef Key, StringRef Value) {
  return MDNode::get(C, {MDString::get(C, Key), MDString::get(C, Value)});
}
// An affine step is a positive constant, optionally multiplied by vscale.
static std::pair<uint64_t, bool> stepFactor(const SCEV *S) {
  if (isa<SCEVVScale>(S))
    return {1, true};
  if (auto *C = dyn_cast<SCEVConstant>(S))
    return C->getAPInt().isStrictlyPositive() &&
                   C->getAPInt().getActiveBits() <= 32
               ? std::make_pair(C->getAPInt().getZExtValue(), false)
               : std::make_pair(uint64_t(0), false);
  if (auto *M = dyn_cast<SCEVMulExpr>(S)) {
    uint64_t Factor = 1;
    bool Scalable = false;
    for (const SCEV *Op : M->operands()) {
      auto Part = stepFactor(Op);
      if (!Part.first || (Scalable && Part.second) ||
          Factor > UINT32_MAX / Part.first)
        return {0, false};
      Factor *= Part.first;
      Scalable |= Part.second;
    }
    return {Factor, Scalable};
  }
  return {0, false};
}
void llvm::markVPlanRALoop(Loop &L, StringRef ID, ScalarEvolution &SE) {
  auto &C = L.getHeader()->getContext();
  SmallVector<Metadata *> Ops{nullptr};
  if (auto *Old = L.getLoopID())
    for (const auto &Op : drop_begin(Old->operands())) {
      auto *N = dyn_cast_or_null<MDNode>(Op);
      if (N && N->getNumOperands())
        if (auto *S = dyn_cast<MDString>(N->getOperand(0)))
          if (S->getString().starts_with("llvm.loop.vplan."))
            continue;
      Ops.push_back(Op);
    }
  Ops.push_back(tag(C, "llvm.loop.vplan.candidate", ID));
  auto *MD = MDNode::getDistinct(C, Ops);
  MD->replaceOperandWith(0, MD);
  L.setLoopID(MD);
  // Affine integer IVs give a stable, cost-free normalization witness.
  for (auto &Phi : L.getHeader()->phis()) {
    if (!Phi.getType()->isIntegerTy())
      continue;
    auto *AR = dyn_cast<SCEVAddRecExpr>(SE.getSCEV(&Phi));
    if (!AR || AR->getLoop() != &L || !AR->isAffine())
      continue;
    auto Step = stepFactor(AR->getStepRecurrence(SE));
    if (!Step.first)
      continue;
    Phi.setMetadata("vplan.ra.induction",
                    MDNode::get(C, {ConstantAsMetadata::get(ConstantInt::get(
                                        Type::getInt64Ty(C), Step.first)),
                                    ConstantAsMetadata::get(ConstantInt::get(
                                        Type::getInt1Ty(C), Step.second))}));
    return;
  }
}

void llvm::finalizeVPlanRAIterationMapping(Function &F,
                                           FunctionAnalysisManager &AM) {
  if (!F.hasFnAttribute("vplan.ra.candidate"))
    return;
  F.addFnAttr("vplan.ra.iteration-mapping", "0");
  auto &LI = AM.getResult<LoopAnalysis>(F);
  auto &SE = AM.getResult<ScalarEvolutionAnalysis>(F);
  StringRef ID = F.getFnAttribute("vplan.ra.candidate").getValueAsString();
  Loop *Selected = nullptr;
  for (auto *L : LI.getLoopsInPreorder()) {
    auto *MD = L->getLoopID();
    if (!MD)
      continue;
    for (const auto &Op : drop_begin(MD->operands())) {
      auto *N = dyn_cast_or_null<MDNode>(Op);
      if (!N || N->getNumOperands() != 2)
        continue;
      auto *Key = dyn_cast<MDString>(N->getOperand(0));
      auto *Value = dyn_cast<MDString>(N->getOperand(1));
      if (!Key || !Value || Key->getString() != "llvm.loop.vplan.candidate" ||
          Value->getString() != ID)
        continue;
      if (Selected)
        return;
      Selected = L;
    }
  }
  if (!Selected || !Selected->isInnermost())
    return;
  uint64_t Ratio = 0;
  for (auto &Phi : Selected->getHeader()->phis()) {
    auto *MD = Phi.getMetadata("vplan.ra.induction");
    if (!MD || MD->getNumOperands() != 2)
      continue;
    auto *Base = mdconst::dyn_extract<ConstantInt>(MD->getOperand(0));
    auto *AR = dyn_cast<SCEVAddRecExpr>(SE.getSCEV(&Phi));
    if (!Base || !AR || AR->getLoop() != Selected || !AR->isAffine())
      continue;
    auto Step = stepFactor(AR->getStepRecurrence(SE));
    auto *Scalable = mdconst::dyn_extract<ConstantInt>(MD->getOperand(1));
    if (!Step.first || !Scalable)
      continue;
    uint64_t B = Base->getZExtValue(), S = Step.first;
    if (Scalable->isOne() != Step.second) {
      // A fixed vscale may have been folded since the witness was recorded.
      // Compare both steps in scalar iterations, including the original step,
      // so folding vscale alone does not increase the observed width.
      unsigned VScale = F.getVScaleValue();
      uint64_t &ScalableFactor = Scalable->isOne() ? B : S;
      if (!VScale || ScalableFactor > UINT64_MAX / VScale)
        continue;
      ScalableFactor *= VScale;
    }
    if (B && S % B == 0)
      Ratio = S / B;
  }
  // EVL loops advance by the returned VL, not an affine constant. Prove one
  // get.vector.length operation and an IV increment by that exact value.
  if (!Ratio && Selected->getNumBlocks() == 1) {
    IntrinsicInst *VL = nullptr;
    bool Multiple = false;
    for (auto &I : *Selected->getHeader())
      if (auto *II = dyn_cast<IntrinsicInst>(&I))
        if (II->getIntrinsicID() == Intrinsic::experimental_get_vector_length) {
          if (VL)
            Multiple = true;
          VL = II;
        }
    if (VL && !Multiple)
      for (auto &Phi : Selected->getHeader()->phis()) {
        auto *Next = dyn_cast<BinaryOperator>(
            Phi.getIncomingValueForBlock(Selected->getLoopLatch()));
        if (!Next || Next->getOpcode() != Instruction::Add)
          continue;
        Value *Increment = Next->getOperand(0) == &Phi   ? Next->getOperand(1)
                           : Next->getOperand(1) == &Phi ? Next->getOperand(0)
                                                         : nullptr;
        if (auto *Cast = dyn_cast_or_null<ZExtInst>(Increment))
          Increment = Cast->getOperand(0);
        if (Increment == VL)
          Ratio = 1;
      }
  }
  uint64_t Width = 0;
  if (!Ratio ||
      F.getFnAttribute("vplan.ra.width")
          .getValueAsString()
          .getAsInteger(10, Width) ||
      Width > UINT32_MAX / Ratio)
    return;
  F.addFnAttr("vplan.ra.width", std::to_string(Width * Ratio));
  F.addFnAttr("vplan.ra.iteration-mapping", "1");
}
