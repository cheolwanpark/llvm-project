//===- VPlanBackendFeedback.cpp - Candidate backend queries
//-----------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Vectorize/VPlanBackendFeedback.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/ScalarEvolution.h"
#include "llvm/Analysis/ScalarEvolutionExpressions.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/PseudoProbe.h"
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

static cl::opt<bool> RegionProbes(
    "vplan-backend-region-probes", cl::Hidden, cl::init(true),
    cl::desc("Insert backend region probes for loop-first spill and MIR "
             "observation, including fully unrolled bodies"));

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
  json::Object Result{
      {"schema", O.MIRBody ? "mir-body-observation-v1" : "rvv-vector-spill-v1"},
      {"stage", O.Stage},
      {"iteration_width", O.IterationWidth},
      {"iteration_mapping", O.IterationMapping},
      {"spills", std::move(Accesses)}};
  if (!O.StructuralFailure.empty())
    Result["structural_failure"] = O.StructuralFailure;
  if (!O.MarkerFailure.empty())
    Result["marker_failure"] = O.MarkerFailure;
  if (O.RegionProbeCount) {
    Result["scope"] = "probe-region";
    Result["region_granularity"] = "machine-path";
    Result["region_probe_count"] = O.RegionProbeCount;
  }
  if (O.MIRBody) {
    Result.erase("spills");
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
  Result["observation_schema"] = "independent-observations-v2";
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
void llvm::markVPlanBackendLoop(Loop &L, StringRef ID, ScalarEvolution &SE) {
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
  Ops.push_back(tag(C, "llvm.loop.vplan.backend.candidate", ID));
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
    Phi.setMetadata("vplan.backend.induction",
                    MDNode::get(C, {ConstantAsMetadata::get(ConstantInt::get(
                                        Type::getInt64Ty(C), Step.first)),
                                    ConstantAsMetadata::get(ConstantInt::get(
                                        Type::getInt1Ty(C), Step.second))}));
    return;
  }
}

// Count matching markers, even repeated markers on the same loop, so both
// pruning and passive diagnostics require exactly one observation identity.
VPlanBackendObservedLoop llvm::findVPlanBackendObservedLoop(Function &F,
                                                            LoopInfo &LI) {
  if (!F.hasFnAttribute("vplan.backend.candidate"))
    return {nullptr, "missing-observed-loop"};
  StringRef ID = F.getFnAttribute("vplan.backend.candidate").getValueAsString();
  Loop *Selected = nullptr;
  for (Loop *L : LI.getLoopsInPreorder()) {
    auto *MD = L->getLoopID();
    if (!MD)
      continue;
    for (const auto &Op : drop_begin(MD->operands())) {
      auto *N = dyn_cast_or_null<MDNode>(Op);
      if (!N || N->getNumOperands() != 2)
        continue;
      auto *Key = dyn_cast<MDString>(N->getOperand(0));
      auto *Value = dyn_cast<MDString>(N->getOperand(1));
      if (!Key || !Value ||
          Key->getString() != "llvm.loop.vplan.backend.candidate" ||
          Value->getString() != ID)
        continue;
      if (Selected)
        return {nullptr, "ambiguous-observed-loop"};
      Selected = L;
    }
  }
  return {Selected, Selected ? "" : "missing-observed-loop"};
}

void llvm::finalizeVPlanBackendIterationMapping(Function &F,
                                                FunctionAnalysisManager &AM) {
  if (!F.hasFnAttribute("vplan.backend.candidate"))
    return;
  // Require codegen to retain every pair surviving the IR suffix. Otherwise a
  // lost pair could silently shrink the normalization denominator.
  if (F.hasFnAttribute("vplan.backend.region-guid")) {
    uint64_t GUID = 0, Begins = 0, Ends = 0;
    SmallPtrSet<const BasicBlock *, 8> Marked;
    bool Valid = !F.getFnAttribute("vplan.backend.region-guid")
                      .getValueAsString()
                      .getAsInteger(10, GUID);
    for (auto &BB : F)
      for (auto &I : BB)
        if (auto *Probe = dyn_cast<PseudoProbeInst>(&I)) {
          if (Probe->getFuncGuid()->getZExtValue() != GUID)
            continue;
          Marked.insert(&BB);
          if (Probe->getIndex()->equalsInt(1))
            ++Begins;
          else if (Probe->getIndex()->equalsInt(2))
            ++Ends;
          else
            Valid = false;
        }
    F.addFnAttr("vplan.backend.region-count",
                std::to_string(Valid && Begins == Ends ? Begins : 0));
    // Prove a finite execution path before counting pairs. Keep the minimal
    // marked subpath; setup and exit computations cannot inherit its frequency.
    SmallVector<const BasicBlock *, 8> Path;
    SmallPtrSet<const BasicBlock *, 8> Seen;
    const BasicBlock *BB = &F.getEntryBlock();
    bool Isolated = Valid && Begins && Begins == Ends;
    while (Isolated) {
      if (!Seen.insert(BB).second || succ_size(BB) > 1 ||
          pred_size(BB) > (Path.empty() ? 0u : 1u)) {
        Isolated = false;
        break;
      }
      Path.push_back(BB);
      if (succ_empty(BB))
        break;
      BB = *succ_begin(BB);
    }
    unsigned First = Path.size(), End = 0;
    for (unsigned I = 0; I < Path.size(); ++I)
      if (Marked.erase(Path[I])) {
        First = std::min(First, I);
        End = I + 1;
      }
    Isolated &= Marked.empty() && First < End;
    for (const auto &Block : F) {
      if (Isolated &&
          is_contained(ArrayRef(Path).slice(First, End - First), &Block))
        continue;
      for (const auto &I : Block)
        if (!isa<DbgInfoIntrinsic>(I) && !isa<UncondBrInst>(I) &&
            !isa<ReturnInst>(I))
          Isolated = false;
    }
    F.addFnAttr("vplan.backend.region-isolated", Isolated ? "1" : "0");
  }
  F.addFnAttr("vplan.backend.iteration-mapping", "0");
  auto &LI = AM.getResult<LoopAnalysis>(F);
  auto &SE = AM.getResult<ScalarEvolutionAnalysis>(F);
  auto [Selected, Reason] = findVPlanBackendObservedLoop(F, LI);
  if (!Selected || !Selected->isInnermost())
    return;
  // Width witnesses must describe every block of one repeated iteration.
  SmallPtrSet<const BasicBlock *, 8> LoopPath;
  const BasicBlock *Current = Selected->getHeader();
  const BasicBlock *Previous = nullptr;
  while (true) {
    if (!Selected->contains(Current) || !LoopPath.insert(Current).second)
      return;
    if (Previous && (pred_size(Current) != 1 ||
                     *pred_begin(Current) != Previous))
      return;
    if (Current == Selected->getLoopLatch())
      break;
    if (succ_size(Current) != 1)
      return;
    Previous = Current;
    Current = *succ_begin(Current);
  }
  if (LoopPath.size() != Selected->getNumBlocks())
    return;
  uint64_t Ratio = 0;
  for (auto &Phi : Selected->getHeader()->phis()) {
    auto *MD = Phi.getMetadata("vplan.backend.induction");
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
  if (!Ratio && Selected->getLoopLatch()) {
    IntrinsicInst *VL = nullptr;
    bool Multiple = false;
    for (auto *BB : Selected->blocks())
      for (auto &I : *BB)
        if (auto *II = dyn_cast<IntrinsicInst>(&I))
          if (II->getIntrinsicID() ==
              Intrinsic::experimental_get_vector_length) {
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
      (F.hasFnAttribute("vplan.backend.materialized-width")
           ? F.getFnAttribute("vplan.backend.materialized-width")
           : F.getFnAttribute("vplan.backend.width"))
          .getValueAsString()
          .getAsInteger(10, Width) ||
      Width > UINT32_MAX / Ratio)
    return;
  F.addFnAttr("vplan.backend.width", std::to_string(Width * Ratio));
  F.addFnAttr("vplan.backend.iteration-mapping", "1");
}

bool llvm::vplanBackendRegionProbesEnabled() { return RegionProbes; }

void llvm::setVPlanBackendCandidate(Function &F, const VPlanBackendCandidate &C,
                                    uint64_t MaterializedWidth) {
  F.addFnAttr("vplan.backend.candidate", C.ID);
  F.addFnAttr("vplan.backend.ic", std::to_string(C.IC));
  F.addFnAttr("vplan.backend.role",
              C.Kind == VPlanBackendCandidateKind::ScalarBaseline
                  ? "scalar-baseline"
              : C.IsEpilogue ? "epilogue"
                             : "main");
  F.addFnAttr("vplan.backend.vf", std::to_string(C.VF.getKnownMinValue()));
  F.addFnAttr("vplan.backend.scalable", C.VF.isScalable() ? "1" : "0");
  F.addFnAttr("vplan.backend.materialized-width",
              std::to_string(MaterializedWidth));
  F.addFnAttr("vplan.backend.width", std::to_string(MaterializedWidth));
}
