//===- VPlanRA.cpp - Fixed transport for backend-informed VPlan research
//---===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "llvm/Transforms/Vectorize/VPlanRA.h"
#include "VPlan.h"
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
    cl::values(
        clEnumValN(VPlanPipelineStage::Full, "full", "Normal pipeline"),
        clEnumValN(VPlanPipelineStage::Prepare, "prepare", "Stop before LV"),
        clEnumValN(VPlanPipelineStage::Resume, "resume", "Resume before LV")));
static cl::opt<std::string>
    Manifest("vplan-candidates-output", cl::Hidden,
             cl::desc("Write VPlan RA candidate manifest"));
static cl::opt<std::string>
    Probe("vplan-probe-candidate", cl::Hidden,
          cl::desc("Materialize an enumerated candidate"));
static cl::opt<std::string>
    SelectionPath("vplan-selection-input", cl::Hidden,
                  cl::desc("Read Python-selected VPlan candidates"));
static cl::opt<std::string>
    RunID("vplan-ra-run-id", cl::Hidden,
          cl::desc("Checkpoint/compiler/options digest"));
namespace {
struct Transport {
  json::Array Candidates, Loops, Selections, Failures;
  json::Array ExpectedCandidates, ExpectedLoops;
  StringMap<json::Object> Choices;
  StringMap<bool> Consumed;
  bool Loaded = false, ProbeSelected = false, ProbeFailed = false;
};
Transport &state() {
  static Transport S;
  return S;
}
std::string vfName(ElementCount VF) {
  return (Twine(VF.isScalable() ? "s" : "f") + Twine(VF.getKnownMinValue()))
      .str();
}
std::string loopKey(StringRef F, int64_t Index) {
  return (F + ":" + Twine(Index)).str();
}
void loadSelection(vfs::FileSystem &FS) {
  auto &S = state();
  if (S.Loaded)
    return;
  S.Loaded = true;
  if (SelectionPath.empty())
    return;
  auto Buffer = FS.getBufferForFile(SelectionPath);
  if (!Buffer)
    reportFatalUsageError("cannot read VPlan selection input");
  auto Parsed = json::parse((*Buffer)->getBuffer());
  if (!Parsed)
    reportFatalUsageError(Twine(toString(Parsed.takeError())));
  auto *Root = Parsed->getAsObject();
  if (!Root || Root->getInteger("version") != 4 ||
      Root->getString("run_id") != StringRef(RunID))
    reportFatalUsageError("VPlan selection version/run mismatch");
  auto *Rows = Root->getArray("selections");
  auto *Candidates = Root->getArray("candidates");
  auto *Loops = Root->getArray("loops");
  if (!Rows || !Candidates || !Loops)
    reportFatalUsageError("missing VPlan selection context");
  S.ExpectedCandidates = *Candidates;
  S.ExpectedLoops = *Loops;
  for (auto &Row : *Rows) {
    auto *O = Row.getAsObject();
    auto F = O ? O->getString("function") : std::nullopt;
    auto L = O ? O->getInteger("loop") : std::nullopt;
    auto Scalar = O ? O->getBoolean("scalar") : std::nullopt;
    if (!F || !L || *L < 0 || !Scalar || O->getInteger("ic") != 1 ||
        O->getString("epilogue_vf") != "f0" ||
        (!*Scalar && !O->getString("id")) || (*Scalar && O->get("id")) ||
        !S.Choices.try_emplace(loopKey(*F, *L), *O).second)
      reportFatalUsageError("invalid/duplicate VPlan selection");
  }
}
} // namespace
void llvm::initializeVPlanRA(vfs::FileSystem &FS) { loadSelection(FS); }
VPlanPipelineStage llvm::getVPlanPipelineStage() { return Pipeline; }
bool llvm::vplanRAEnabled() {
  return !Manifest.empty() || !Probe.empty() || !SelectionPath.empty();
}
StringRef llvm::getVPlanRAProbe() { return Probe.getValue(); }
StringRef llvm::getVPlanRARunID() { return RunID.getValue(); }
void llvm::writeVPlanRAJSON(StringRef Path, json::Value Value) {
  std::error_code EC;
  raw_fd_ostream OS(Path, EC, sys::fs::OF_Text);
  if (EC)
    reportFatalUsageError(Twine("cannot write VPlan artifact: ") +
                          EC.message());
  OS << Value << '\n';
  OS.close();
  if (OS.has_error())
    reportFatalUsageError("failed to write VPlan artifact");
}
VPlanRAContext::VPlanRAContext(const Function &F, unsigned Index)
    : FunctionName(F.getName().str()), LoopIndex(Index),
      Prefix((F.getName() + ":" + Twine(Index) + ":").str()) {
  if (RunID.empty())
    reportFatalUsageError("VPlan RA requires -vplan-ra-run-id");
  if (!Probe.empty() && !SelectionPath.empty())
    reportFatalUsageError("VPlan probe cannot consume selection input");
  if (!state().Loaded)
    loadSelection(*vfs::getRealFileSystem());
  LoopPosition = state().Loops.size();
  state().Loops.push_back(json::Object{{"function", FunctionName},
                                       {"loop", LoopIndex},
                                       {"scalar_cost", nullptr},
                                       {"max_trip_count", 0},
                                       {"exact_trip_count", 0}});
  if (!SelectionPath.empty()) {
    auto Key = loopKey(FunctionName, LoopIndex);
    auto It = state().Choices.find(Key);
    if (It == state().Choices.end())
      reportFatalUsageError("missing loop selection");
    if (*It->second.getBoolean("scalar")) {
      state().Selections.push_back(json::Object(It->second));
      state().Consumed[Key] = true;
    } else {
      SelectedID = It->second.getString("id")->str();
    }
  }
}
void VPlanRAContext::setLoopInfo(InstructionCost Scalar, unsigned Max,
                                 unsigned Exact) {
  auto &O = *state().Loops[LoopPosition].getAsObject();
  if (Scalar.isValid() && Scalar >= 0) {
    int64_t Whole = Scalar.getValue();
    O["scalar_cost"] =
        double(Whole) + double(((Scalar - Whole) * 4).getValue()) / 4;
  }
  O["max_trip_count"] = Max;
  O["exact_trip_count"] = Exact;
}
void VPlanRAContext::registerPlan(const VPlan &Plan) { Plans.push_back(&Plan); }
std::string VPlanRAContext::candidateID(const VPlan &Plan,
                                        ElementCount VF) const {
  auto It = llvm::find(Plans, &Plan);
  assert(It != Plans.end() && "unregistered VPlan candidate");
  return Prefix + std::to_string(It - Plans.begin()) + ":" + vfName(VF);
}
bool VPlanRAContext::isRequested(const VPlan &Plan, ElementCount VF) const {
  auto ID = candidateID(Plan, VF);
  return (!Probe.empty() && Probe == ID) || SelectedID == ID;
}
bool VPlanRAContext::probesThisLoop() const {
  return !Probe.empty() && StringRef(Probe).starts_with(Prefix);
}
bool VPlanRAContext::hasRequest() const {
  return probesThisLoop() || !SelectedID.empty();
}
void VPlanRAContext::recordCandidate(const VPlan &Plan, ElementCount VF,
                                     unsigned Width, json::Object MiddleEnd) {
  if (VF.isScalar())
    return;
  state().Candidates.push_back(
      json::Object{{"id", candidateID(Plan, VF)},
                   {"function", FunctionName},
                   {"loop", LoopIndex},
                   {"vf", vfName(VF)},
                   {"estimated_width", Width},
                   {"middle_end", std::move(MiddleEnd)},
                   {"probeable", true},
                   {"scalar_tail", Plan.hasScalarTail()}});
}
void VPlanRAContext::failure(StringRef Reason) {
  auto ID = probesThisLoop() ? getVPlanRAProbe() : StringRef(SelectedID);
  state().Failures.push_back(
      json::Object{{"id", ID.str()}, {"reason", Reason.str()}});
  if (probesThisLoop())
    state().ProbeFailed = true;
  if (!SelectionPath.empty())
    reportFatalUsageError(Twine("selected VPlan rejected: ") + Reason);
}
void VPlanRAContext::selection(const VPlan &Plan, ElementCount VF, unsigned IC,
                               ElementCount EpilogueVF, bool Emitted) {
  auto ID = candidateID(Plan, VF);
  if (!isRequested(Plan, VF) || IC != 1 ||
      EpilogueVF != ElementCount::getFixed(0) || !Emitted)
    reportFatalUsageError("VPlan selection replay mismatch");
  state().Selections.push_back(
      json::Object{{"function", FunctionName},
                   {"loop", LoopIndex},
                   {"scalar", false},
                   {"id", ID},
                   {"ic", IC},
                   {"epilogue_vf", vfName(EpilogueVF)}});
  if (probesThisLoop())
    state().ProbeSelected = true;
  if (!SelectionPath.empty())
    state().Consumed[loopKey(FunctionName, LoopIndex)] = true;
}
void llvm::finishVPlanRA(Module &M) {
  if (!vplanRAEnabled())
    return;
  if (!state().Loaded)
    loadSelection(*vfs::getRealFileSystem());
  auto &S = state();
  if (!Probe.empty() && !S.ProbeSelected && !S.ProbeFailed)
    reportFatalUsageError("VPlan probe candidate was not materialized");
  if (!SelectionPath.empty() &&
      (S.Consumed.size() != S.Choices.size() ||
       json::Value(json::Array(S.Candidates)) !=
           json::Value(json::Array(S.ExpectedCandidates)) ||
       json::Value(json::Array(S.Loops)) !=
           json::Value(json::Array(S.ExpectedLoops))))
    reportFatalUsageError(
        "unexpected/stale VPlan selection or candidate context changed");
  if (!Manifest.empty())
    writeVPlanRAJSON(Manifest,
                     json::Object{{"version", 4},
                                  {"run_id", std::string(RunID)},
                                  {"triple", M.getTargetTriple().str()},
                                  {"loops", std::move(S.Loops)},
                                  {"candidates", std::move(S.Candidates)},
                                  {"selections", std::move(S.Selections)},
                                  {"failures", std::move(S.Failures)}});
  S = Transport();
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
