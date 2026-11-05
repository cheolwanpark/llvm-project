// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "VPlanBackendCostModel.h"
#include "LoopVectorizationPlanner.h"
#include "VPlan.h"
#include "VPlanCostReport.h"
#include "VPlanRegisterUsageBounds.h"
#include "llvm/ADT/APInt.h"
#include "llvm/ADT/ScopeExit.h"
#include "llvm/Analysis/VPlanCostProfile.h"
#include "llvm/Analysis/VectorUtils.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/SaveAndRestore.h"
#include <numeric>
using namespace llvm;
namespace {
void printCostTiming(StringRef ID, const VPlanFeedbackTimer &Timer) {
  if (!Timer.Enabled)
    return;
  json::Object O{{"candidate", ID}};
  for (const auto &P : Timer.Phases) {
    O[P.Phase + "_wall_seconds"] = P.Wall;
    O[P.Phase + "_cpu_seconds"] = P.CPU;
  }
  errs() << "VPLAN-BACKEND-COST-TIMING: " << json::Value(std::move(O)) << '\n';
}

void addMIRFields(json::Object &Row, const VPMIRCost &M) {
  Row["mir_model"] = M.Model;
  Row["mir_revision"] = M.Revision;
  Row["mir_cost_schema"] = "direct-instruction-cost-v1";
  Row["mir_cpu"] = M.CPU;
  Row["mir_nominal_vlen"] = M.NominalVLEN;
  Row["mir_body_quarters_numerator"] = M.Body.numerator();
  Row["mir_body_quarters_denominator"] = M.Body.denominator();
  Row["mir_spill_quarters_numerator"] = M.Spill.numerator();
  Row["mir_spill_quarters_denominator"] = M.Spill.denominator();
  unsigned Unknown = 0;
  json::Array Loops;
  for (const auto &L : M.Loops) {
    json::Array Ops;
    for (const auto &I : L.Instructions) {
      Unknown += I.Unknown;
      Ops.push_back(json::Object{{"rule", I.Rule},
                                 {"unknown", I.Unknown},
                                 {"numerator", I.Numerator},
                                 {"denominator", I.Denominator}});
    }
    Loops.push_back(json::Object{
        {"id", L.ID},
        {"iteration_width", L.IterationWidth},
        {"raw_body_quarters_numerator", L.RawBody.numerator()},
        {"raw_body_quarters_denominator", L.RawBody.denominator()},
        {"raw_spill_quarters_numerator", L.RawSpill.numerator()},
        {"raw_spill_quarters_denominator", L.RawSpill.denominator()},
        {"body_quarters_numerator", L.Body.numerator()},
        {"body_quarters_denominator", L.Body.denominator()},
        {"spill_quarters_numerator", L.Spill.numerator()},
        {"spill_quarters_denominator", L.Spill.denominator()},
        {"instructions", std::move(Ops)}});
  }
  Row["unknown_instruction_count"] = Unknown;
  Row["mir_loops"] = std::move(Loops);
}

void addScalarFields(json::Object &Row, const VPBackendScalarCostEntry &S) {
  Row["scalar_cost_source"] = S.Source;
  Row["scalar_profile"] = S.Profile;
  Row["scalar_revision"] = S.Revision;
  Row["scalar_quarters_numerator"] = S.Body.numerator();
  Row["scalar_quarters_denominator"] = S.Body.denominator();
}
} // namespace
void VPlanBackendCostModel::fail(StringRef Reason) {
  if (Failed)
    return;
  Failed = true;
  Failure = Reason.str();
  Costs.clear();
  ScalarEntry.reset();
  Rows.clear();
  Pruned.clear();
}
const VPBackendCostEntry *VPlanBackendCostModel::lookup(const VPlan &Plan,
                                                        ElementCount VF,
                                                        bool Epilogue) const {
  if (Failed)
    return nullptr;
  for (auto &C : Costs)
    if (C.Plan == &Plan && C.VF == VF && C.IsEpilogue == Epilogue)
      return &C;
  return nullptr;
}
VPlanBackendCostModel::PreparedCandidate VPlanBackendCostModel::prepareCost(
    VPlan &Plan, VPlanBackendCandidate C, InstructionCost Native,
    InstructionCost Profile, InstructionCost Ev, unsigned Width,
    InstructionCost EstimatedSpill) const {
  auto Bound = computeVPlanRegisterUsageBound(Plan, C.VF, TTI);
  Bound.applyInterleave(C.IC);
  bool Query =
      Mode.MIR || (!Mode.EstimatedSpill &&
                   (Bound.shouldQuery() || vplanBackendFeedbackForceAll()));
  C.Observation.StopAfter =
      Mode.MIR ? VPlanBackendStopAfter::MIR : VPlanBackendStopAfter::Spill;
  C.Observation.CaptureMIRText = Report && Report->isDetailed();
  return {&Plan,          std::move(C), Native, Profile, Ev,
          EstimatedSpill, Width,        Bound,  Query};
}

bool VPlanBackendCostModel::add(VPlan &Plan, VPlanBackendCandidate C,
                                InstructionCost Native, InstructionCost Profile,
                                InstructionCost Ev, unsigned Width,
                                InstructionCost EstimatedSpill) {
  if (Failed)
    return false;
  if (!Width || !C.IC || Width > UINT32_MAX / C.IC) {
    fail("candidate iteration width overflow");
    return false;
  }
  VPlanFeedbackTimer Timer(vplanBackendFeedbackTimingEnabled());
  auto ReportTime = scope_exit([&] { printCostTiming(C.ID, Timer); });
  auto Prepared =
      prepareCost(Plan, C, Native, Profile, Ev, Width, EstimatedSpill);
  Timer.mark("gate");
  std::optional<VPlanBackendProbeResult> Result;
  if (Prepared.Query && Native.isValid() && Profile.isValid() && Ev.isValid()) {
    Result.emplace(Feedback.get(F, Header, Prepared.Candidate));
    Timer.mark("query_total");
  }
  return applyCost(Prepared, std::move(Result), Timer);
}

bool llvm::vplanStrictlyCheaper(VPExactCost A, unsigned WidthA, VPExactCost B,
                                unsigned WidthB, VPExactCost Scalar,
                                unsigned TC, bool ScalarTail) {
  if (!WidthA || !WidthB || !A.isValid() || !B.isValid() || !Scalar.isValid())
    return false;
  auto ScoreA = TC ? vplanCostForTripCount(WidthA, A, Scalar, TC, ScalarTail)
                   : A * WidthB;
  auto ScoreB = TC ? vplanCostForTripCount(WidthB, B, Scalar, TC, ScalarTail)
                   : B * WidthA;
  return ScoreA.isValid() && ScoreB.isValid() && ScoreA < ScoreB;
}

VPlanBackendCostModel::EvaluatedCost VPlanBackendCostModel::evaluateObservation(
    const PreparedCandidate &P, const VPlanBackendProbeResult &Result) const {
  EvaluatedCost E;
  if (!Result.Observation) {
    E.Error = Result.Cancelled ? "backend probe cancelled" : Result.Failure;
    return E;
  }
  const auto &O = *Result.Observation;
  const auto &C = P.Candidate;
  if (O.Candidate != C.ID || O.VF != C.VF || O.IC != C.IC ||
      O.IsEpilogue != C.IsEpilogue || O.Kind != C.Kind)
    E.Error = "backend observation identity mismatch";
  else if (const auto &Facts = Mode.MIR ? O.MIR : O.Spill; !Facts.succeeded())
    E.Error = Facts.Failure.empty() ? "required observation unavailable"
                                    : Facts.Failure;
  else if (Facts.Loops.empty() || any_of(Facts.Loops, [&](const auto &L) {
             return !L.IterationWidth ||
                    L.IterationWidth % (uint64_t(P.Width) * C.IC);
           }))
    E.Error = "observed iteration width disagrees with requested IC";
  else {
    if (Mode.MIR) {
      auto Cost = priceVPlanMIR(O.MIR, *MIRInfo, P.Width);
      if (!Cost)
        E.Error = toString(Cost.takeError());
      else
        E.MIR = std::move(*Cost);
    } else {
      auto Spill = priceVPlanVectorSpills(
          O.Spill, TTI, F.getContext(), P.Width, E.Raw,
          Report && Report->isDetailed() ? &E.AccessCosts : nullptr,
          Mode.DefaultTTI, &E.SpillLoops);
      if (!Spill)
        E.Error = toString(Spill.takeError());
      else
        E.Spill = *Spill;
    }
  }
  return E;
}

void VPlanBackendCostModel::recordObservation(
    const VPlanBackendProbeResult &Result) {
  if (!Result.Observation)
    return;
  const auto &O = *Result.Observation;
  if (vplanBackendFeedbackOutputEnabled() &&
      llvm::none_of(Observed, [&](const auto &Old) {
        return Old.Candidate == O.Candidate;
      }))
    Observed.push_back(O);
}

// Decision state for a single model's candidate set. It requests cancellation;
// the provider continues to own execution, cleanup and joining.
struct VPlanBackendCostModel::PruningState {
  ArrayRef<PreparedCandidate> Candidates;
  std::optional<VPBackendPruningContext> Context;
  struct CandidateState {
    VPExactCost Lower, Rank;
    bool Eligible = false, Dominated = false;
    std::shared_ptr<VPlanBackendProbeControl> Control;
  };
  SmallVector<CandidateState, 0> States;
  std::optional<VPExactCost> Best;
  unsigned Basis = 0, BasisWidth = 1;
  VPExactCost BasisCost;
  SmallVector<unsigned> Order;
  VPExactCost score(VPExactCost Body, unsigned Width) const {
    if (Context->MaxTripCount)
      return vplanCostForTripCount(Width, Body, VPExactCost(Context->Scalar),
                                   Context->MaxTripCount,
                                   Candidates.front().Candidate.ScalarTail);
    int64_t Den;
    if (MulOverflow(Body.denominator(), int64_t(Width), Den))
      return VPExactCost::ratio(-1, 1);
    return VPExactCost::ratio(Body.numerator(), Den);
  }
  void reject() {
    if (!Best)
      return;
    for (unsigned I = 0; I < Candidates.size(); ++I) {
      auto &S = States[I];
      if (Candidates[I].Query && S.Lower.isValid() && *Best < S.Lower) {
        S.Dominated = true;
        S.Control->Cancellation.Requested.store(true,
                                                std::memory_order_relaxed);
      }
    }
  }

  PruningState(ArrayRef<PreparedCandidate> Candidates,
               std::optional<VPBackendPruningContext> Context)
      : Candidates(Candidates), Context(Context), States(Candidates.size()) {
    for (const auto &P : Candidates)
      if (P.Candidate.ScalarTail != Candidates.front().Candidate.ScalarTail ||
          P.Candidate.VF.isScalable() !=
              Candidates.front().Candidate.VF.isScalable() ||
          !(VPExactCost(P.Profile) - VPExactCost(P.Ev)).isValid())
        this->Context.reset();
    Context = this->Context;
    if (Context && Context->UseScalar) {
      auto S = score(VPExactCost(Context->Scalar), 1);
      if (S.isValid()) {
        Best = S;
        BasisCost = VPExactCost(Context->Scalar);
      }
    }
    if (Context)
      for (unsigned I = 0; I < Candidates.size(); ++I) {
        const auto &P = Candidates[I];
        auto &S = States[I];
        auto B = VPExactCost(P.Profile) - VPExactCost(P.Ev);
        S.Lower = score(B, P.Width);
        S.Rank = VPExactCost::ratio(B.numerator(), P.Width);
        S.Eligible = P.Eligible;
        S.Control = std::make_shared<VPlanBackendProbeControl>();
        if (!P.Query && S.Eligible && S.Lower.isValid() &&
            (!Best || S.Lower < *Best)) {
          Best = S.Lower;
          Basis = I + 1;
          BasisWidth = P.Width;
          BasisCost = B;
        }
      }
    reject();
    for (unsigned I = 0; I < Candidates.size(); ++I)
      if (Candidates[I].Query && !States[I].Dominated)
        Order.push_back(I);
    if (Context)
      llvm::stable_sort(Order, [&](unsigned A, unsigned B) {
        return States[A].Rank < States[B].Rank;
      });
  }

  void completed(unsigned I, const EvaluatedCost &E) {
    auto &S = States[I];
    if (!E.Error.empty() || !S.Eligible)
      return;
    const auto &P = Candidates[I];
    auto Body = VPExactCost(P.Profile) - VPExactCost(P.Ev) + E.Spill;
    auto Cost = score(Body, P.Width);
    if (Cost.isValid() && (!Best || Cost < *Best)) {
      Best = Cost;
      Basis = I + 1;
      BasisWidth = P.Width;
      BasisCost = Body;
      reject();
    }
  }
};

bool VPlanBackendCostModel::addBatch(
    ArrayRef<PreparedCandidate> Candidates,
    std::optional<VPBackendPruningContext> Context) {
  if (Candidates.empty())
    return true;
  PruningState Pruning(Candidates, Context);
  Context = Pruning.Context;
  auto &States = Pruning.States;
  const auto &Order = Pruning.Order;
  struct QueryOutcome {
    std::optional<EvaluatedCost> Evaluated;
    std::optional<VPlanBackendProbeResult> Result;
  };
  SmallVector<QueryOutcome, 0> Outcomes(Candidates.size());
  SmallVector<VPlanBackendCandidate> Queries;
  for (unsigned I : Order) {
    auto &S = States[I];
    if (Context)
      S.Control->Completed = [&, I](const VPlanBackendProbeResult &R) {
        auto &S = States[I];
        if (S.Dominated || R.Cancelled)
          return;
        recordObservation(R);
        Outcomes[I].Evaluated = evaluateObservation(Candidates[I], R);
        Pruning.completed(I, *Outcomes[I].Evaluated);
      };
    auto C = Candidates[I].Candidate;
    C.Control = S.Control;
    Queries.push_back(std::move(C));
  }
  auto Results = Feedback.getBatch(F, Header, Queries);
  std::string BatchFailure;
  if (!Results)
    BatchFailure = toString(Results.takeError());
  for (unsigned J = 0; J < Order.size(); ++J) {
    auto &Outcome = Outcomes[Order[J]];
    if (BatchFailure.empty())
      Outcome.Result = std::move((*Results)[J]);
    else
      Outcome.Result.emplace(createStringError(BatchFailure));
  }
  VPlanFeedbackTimer Timer(false);
  for (unsigned I = 0; I < Candidates.size(); ++I) {
    const auto &P = Candidates[I];
    auto &S = States[I];
    if (S.Dominated) {
      Pruned.emplace_back(P.Plan, P.Candidate.VF);
      if (Outcomes[I].Result)
        errs() << Outcomes[I].Result->Diagnostics;
      if (Report) {
        Report->skip(*P.Plan, P.Candidate.VF, "backend-lower-bound");
        VP_COST_SUMMARY(Report, OS << "  backend-pruned candidate="
                                   << P.Candidate.ID << '\n');
      }
      if (vplanBackendFeedbackOutputEnabled())
        Rows.push_back(json::Object{
            {"model", Mode.name()},
            {"candidate", P.Candidate.ID},
            {"function", F.getName()},
            {"loop", LoopIndex},
            {"plan", P.Candidate.PlanIndex},
            {"vf", P.Candidate.VF.getKnownMinValue()},
            {"scalable", P.Candidate.VF.isScalable()},
            {"ic", P.Candidate.IC},
            {"role", "main"},
            {"score_kind",
             Context->MaxTripCount ? "whole-loop" : "cost-per-lane"},
            {"status", "pruned"},
            {"reason", "backend-lower-bound"},
            {"execution", !S.Control->Started             ? "not-started"
                          : Outcomes[I].Result->Cancelled ? "cancelled"
                                                          : "completed"},
            {"queried", S.Control->Started},
            {"pruning_basis", Pruning.Basis
                                  ? Candidates[Pruning.Basis - 1].Candidate.ID
                                  : "scalar"},
            {"basis_width", Pruning.BasisWidth},
            {"tti_width", P.Width},
            {"max_trip_count", Context->MaxTripCount},
            {"scalar_tail", P.Candidate.ScalarTail},
            {"scalar_quarters_numerator",
             VPExactCost(Context->Scalar).numerator()},
            {"scalar_quarters_denominator",
             VPExactCost(Context->Scalar).denominator()},
            {"basis_quarters_numerator", Pruning.BasisCost.numerator()},
            {"basis_quarters_denominator", Pruning.BasisCost.denominator()},
            {"lower_bound_quarters_numerator",
             (VPExactCost(P.Profile) - VPExactCost(P.Ev)).numerator()},
            {"lower_bound_quarters_denominator",
             (VPExactCost(P.Profile) - VPExactCost(P.Ev)).denominator()},
            {"score_lower_bound_quarters_numerator", S.Lower.numerator()},
            {"score_lower_bound_quarters_denominator", S.Lower.denominator()}});
      if (vplanBackendFeedbackOutputEnabled() && ScalarEntry)
        addScalarFields(Rows.back(), *ScalarEntry);
      if (vplanBackendFeedbackOutputEnabled() && Outcomes[I].Result &&
          Outcomes[I].Result->Observation)
        Rows.back()["observation"] = summarizeVPlanBackendResult(
            *Outcomes[I].Result->Observation, Mode.MIR);
      continue;
    }
    if (!applyCost(P, std::move(Outcomes[I].Result), Timer,
                   Outcomes[I].Evaluated ? &*Outcomes[I].Evaluated : nullptr))
      return false;
  }
  return true;
}

bool VPlanBackendCostModel::applyCost(
    const PreparedCandidate &P, std::optional<VPlanBackendProbeResult> Result,
    VPlanFeedbackTimer &Timer, const EvaluatedCost *Evaluated) {
  const auto &C = P.Candidate;
  const auto &Bound = P.Bound;
  auto Native = P.Native, Profile = P.Profile, Ev = P.Ev;
  unsigned Width = P.Width;
  bool Query = P.Query;
  VPExactCost Spill;
  InstructionCost Raw;
  std::string Error;
  std::optional<VPlanBackendResult> Observation;
  SmallVector<VPSpillCost> AccessCosts;
  SmallVector<VPSpillLoopCost> SpillLoops;
  std::optional<VPMIRCost> MIRCost;
  if (!Native.isValid() || !Profile.isValid() || !Ev.isValid() ||
      !P.EstimatedSpill.isValid())
    Error = "invalid TTI candidate cost";
  else if (Query) {
    assert(Result && "missing required backend query result");
    errs() << Result->Diagnostics;
    recordObservation(*Result);
    auto E = Evaluated ? *Evaluated : evaluateObservation(P, *Result);
    Error = std::move(E.Error);
    Spill = E.Spill;
    Raw = E.Raw;
    AccessCosts = std::move(E.AccessCosts);
    SpillLoops = std::move(E.SpillLoops);
    MIRCost = std::move(E.MIR);
    Observation = std::move(Result->Observation);
    Timer.mark(Mode.MIR ? "mir_pricing" : "spill_pricing");
  }

  VPExactCost Body = VPExactCost(Profile);
  if (Mode.MIR) {
    if (MIRCost) {
      Body =
          composeVPlanMIRCost(*MIRCost, P.EstimatedSpill, Mode.EstimatedSpill);
    } else
      Body = VPExactCost::ratio(-1, 1);
  } else if (!Mode.EstimatedSpill)
    Body = Body - VPExactCost(Ev) + Spill;
  if (!Body.isValid() && Error.empty())
    Error = "invalid or overflowing hybrid cost";
  if (Error.empty()) {
    Costs.push_back({P.Plan, C.VF, C.IC, C.IsEpilogue, Native, Profile, Ev,
                     Body, P.EstimatedSpill, std::move(MIRCost)});
    if (Report)
      Report->backendCost(
          Costs.back(), Bound, Observation ? &*Observation : nullptr,
          AccessCosts, Width, TTI.getVPlanCostProfileName(), Raw, Spill, Mode);
  }
  // Serialization is entirely optional. The selection and text report use
  // the owned C++ observation and the exact values computed above.
  if (vplanBackendFeedbackOutputEnabled()) {
    json::Object Gate{{"known", Bound.Known},
                      {"reason", Bound.Reason},
                      {"would_skip", !Bound.shouldQuery()},
                      {"force_all", vplanBackendFeedbackForceAll()},
                      {"queried", Query},
                      {"budget", 32}};
    if (Bound.Known) {
      Gate["peak_bound"] = Bound.Peak;
      Gate["max_register_group"] = Bound.MaxRegisterGroup;
      Gate["has_mask"] = Bound.HasMask;
      Gate["usage_bound"] = Bound.Usage;
      Gate["usage_before_ic"] = Bound.UsageBeforeIC;
    }
    if (!Bound.Recipe.empty())
      Gate["recipe"] = Bound.Recipe;
    if (Bound.Opcode)
      Gate["opcode"] = *Bound.Opcode;
    json::Object Row{{"model", Mode.name()},
                     {"cost_source", Query                 ? "observation"
                                     : Mode.EstimatedSpill ? "estimated"
                                                           : "gate"},
                     {"use_mir", Mode.MIR},
                     {"use_estimated_spill", Mode.EstimatedSpill},
                     {"use_default_tti", Mode.DefaultTTI},
                     {"candidate", C.ID},
                     {"feedback_point", "middle-end-before-vf-selection"},
                     {"function", F.getName()},
                     {"loop", LoopIndex},
                     {"plan", C.PlanIndex},
                     {"tti_profile", TTI.getVPlanCostProfileName()},
                     {"vf", C.VF.getKnownMinValue()},
                     {"scalable", C.VF.isScalable()},
                     {"ic", C.IC},
                     {"role", C.IsEpilogue ? "epilogue" : "main"},
                     {"vector_epilogue", C.EpilogueVF.isVector()},
                     {"register_usage_bound", std::move(Gate)}};
    if (Observation) {
      Row["real_spill_used"] =
          !Mode.MIR && !Mode.EstimatedSpill && Error.empty();
      Row["real_spill_unused_reason"] = Mode.EstimatedSpill
                                            ? "estimated-spill-requested"
                                        : Mode.MIR ? "mir-body-pricing"
                                                   : "";
      Row["status"] = "collected";
      Row["observation"] = summarizeVPlanBackendResult(*Observation, Mode.MIR);
    } else {
      Row["status"] = Query ? "unavailable" : "skipped";
      Row["reason"] = Query                 ? StringRef(Error)
                      : Mode.EstimatedSpill ? "estimated-spill-no-probe"
                                            : Bound.Reason;
    }
    if (Error.empty()) {
      Row["native_body_quarters"] = Native.getQuarterValue();
      Row["profile_body_quarters"] = Profile.getQuarterValue();
      Row["estimated_vector_spill_quarters"] = Ev.getQuarterValue();
      Row["estimated_total_spill_quarters"] =
          P.EstimatedSpill.getQuarterValue();
      if (!Mode.MIR) {
        Row["raw_vector_spill_sum_quarters"] = Raw.getQuarterValue();
        json::Array Loops;
        for (const auto &L : SpillLoops)
          Loops.push_back(json::Object{
              {"id", L.ID},
              {"iteration_width", L.IterationWidth},
              {"raw_spill_quarters", L.Raw.getQuarterValue()},
              {"spill_quarters_numerator", L.Cost.numerator()},
              {"spill_quarters_denominator", L.Cost.denominator()}});
        Row["spill_loops"] = std::move(Loops);
      }
      if (Costs.back().MIR)
        addMIRFields(Row, *Costs.back().MIR);
      if (ScalarEntry)
        addScalarFields(Row, *ScalarEntry);
      Row["tti_width"] = Width;
      if (!Mode.MIR) {
        Row["normalized_vector_spill_quarters_numerator"] = Spill.numerator();
        Row["normalized_vector_spill_quarters_denominator"] =
            Spill.denominator();
      }
      Row["body_quarters_numerator"] = Body.numerator();
      Row["body_quarters_denominator"] = Body.denominator();
    } else
      Row["cost_failure"] = Error;
    Rows.push_back(std::move(Row));
  }
  Timer.mark("hybrid_cost_and_summary");
  if (!Error.empty()) {
    fail(Error);
    return false;
  }
  return true;
}

bool VPlanBackendCostModel::applyScalar(const VPlanBackendCandidate &C,
                                        InstructionCost EstimatedSpill,
                                        VPlanBackendProbeResult Result) {
  errs() << Result.Diagnostics;
  if (!EstimatedSpill.isValid() || EstimatedSpill < 0) {
    fail("invalid scalar estimated spill cost");
    return false;
  }
  PreparedCandidate P{nullptr, C, 0, 0, 0, EstimatedSpill, 1, {}, true};
  recordObservation(Result);
  auto E = evaluateObservation(P, Result);
  if (!E.Error.empty() || !E.MIR) {
    fail("scalar baseline: " + E.Error);
    return false;
  }
  auto Body = composeVPlanMIRCost(*E.MIR, EstimatedSpill, Mode.EstimatedSpill);
  if (!Body.isValid()) {
    fail("invalid or overflowing scalar MIR cost");
    return false;
  }
  ScalarEntry = VPBackendScalarCostEntry{
      Body,
      EstimatedSpill,
      Mode.EstimatedSpill ? "mir-estimated-spill" : "mir",
      E.MIR->Model,
      E.MIR->Revision,
      std::move(E.MIR)};
  if (Report)
    Report->backendScalarCost(*ScalarEntry, &*Result.Observation);
  if (vplanBackendFeedbackOutputEnabled()) {
    json::Object Row{
        {"model", Mode.name()},
        {"cost_source", "observation"},
        {"scalar_cost_source", ScalarEntry->Source},
        {"scalar_profile", ScalarEntry->Profile},
        {"scalar_revision", ScalarEntry->Revision},
        {"use_mir", true},
        {"use_estimated_spill", Mode.EstimatedSpill},
        {"use_default_tti", Mode.DefaultTTI},
        {"candidate", C.ID},
        {"function", F.getName()},
        {"loop", LoopIndex},
        {"vf", 1},
        {"scalable", false},
        {"ic", 1},
        {"role", "scalar-baseline"},
        {"status", "collected"},
        {"tti_profile", TTI.getVPlanCostProfileName()},
        {"tti_width", 1},
        {"observation", summarizeVPlanBackendResult(*Result.Observation, true)},
        {"estimated_total_spill_quarters", EstimatedSpill.getQuarterValue()},
        {"body_quarters_numerator", Body.numerator()},
        {"body_quarters_denominator", Body.denominator()}};
    addMIRFields(Row, *ScalarEntry->MIR);
    Rows.push_back(std::move(Row));
  }
  return true;
}

bool VPlanBackendCostModel::prepareScalar(LoopVectorizationPlanner &LVP) {
  if (!Mode.MIR) {
    auto Scalar = VPExactCost(LVP.backendScalarCost(Mode));
    if (!Scalar.isValid()) {
      fail("invalid scalar baseline cost");
      return false;
    }
    StringRef Profile =
        Mode.DefaultTTI ? "native" : TTI.getVPlanCostProfileName();
    StringRef Revision = Profile == "native" ? "native-tti"
                         : MIRInfo           ? MIRInfo->getRevision()
                                             : "unavailable";
    ScalarEntry = VPBackendScalarCostEntry{
        Scalar, 0, "tti", Profile.str(), Revision.str(), std::nullopt};
    if (Report)
      Report->backendScalarCost(*ScalarEntry, nullptr);
    return true;
  }
  InstructionCost EstimatedSpill = Mode.EstimatedSpill
                                       ? LVP.backendScalarSpillCost(Mode)
                                       : InstructionCost(0);
  if (!EstimatedSpill.isValid() || EstimatedSpill < 0) {
    fail("invalid scalar estimated spill cost");
    return false;
  }
  VPlanBackendCandidate C{(F.getName() + ":" + Twine(Invocation) + ":" +
                           Twine(LoopIndex) + ":scalar-baseline")
                              .str(),
                          0,
                          ElementCount::getFixed(1),
                          true,
                          InterleaveOnly,
                          VectorizeOnly};
  C.Kind = VPlanBackendCandidateKind::ScalarBaseline;
  C.Observation.StopAfter = VPlanBackendStopAfter::MIR;
  C.Observation.CaptureMIRText = Report && Report->isDetailed();
  return applyScalar(C, EstimatedSpill,
                     VPlanBackendProbeResult(Feedback.get(F, Header, C)));
}
bool VPlanBackendCostModel::prepare(LoopVectorizationPlanner &LVP,
                                    VFSelectionContext &Config, unsigned UserIC,
                                    unsigned Invocation, unsigned LoopIndex,
                                    bool InterleaveOnlyWhenForced,
                                    bool VectorizeOnlyWhenForced,
                                    ElementCount ForcedEpilogue) {
  this->LoopIndex = LoopIndex;
  this->Invocation = Invocation;
  InterleaveOnly = InterleaveOnlyWhenForced;
  VectorizeOnly = VectorizeOnlyWhenForced;
  MIRInfo = Feedback.getMIRInfo(F);
  if (Mode.MIR && !MIRInfo) {
    fail("target has no MIR cost sheet");
    return false;
  }
  if (!prepareScalar(LVP))
    return false;
  auto Pruning =
      !Mode.MIR && !Mode.EstimatedSpill && !vplanBackendFeedbackForceAll()
          ? LVP.backendPruningContext(InstructionCost(scalarCost()))
          : std::nullopt;
  const bool Batch =
      Mode.needsProbe() && (Feedback.canBatch(F) || Pruning.has_value());
  SmallVector<PreparedCandidate, 0> Pending;
  std::string PreparationError;
  auto Prepare = [&]() -> bool {
    for (auto [PlanIndex, Plan] : enumerate(LVP.getPlans()))
      for (ElementCount VF : Plan->vectorFactors()) {
        if (VF.isScalar())
          continue;
        VPlanFeedbackTimer Preparation(vplanBackendFeedbackTimingEnabled());
        InstructionCost Ev;
        auto Native = LVP.backendCandidateCost(*Plan, VF, false, Ev);
        if (!Native.isValid()) {
          PreparationError = "invalid native candidate cost";
          return false;
        }
        Preparation.mark("native_cost");
        unsigned IC;
        {
          std::optional<SaveAndRestore<StringRef>> Phase;
          if (Report)
            Phase.emplace(Report->Phase, "backend-native-ic");
          IC = LVP.selectInterleaveCount(*Plan, VF, Native);
        }
        if (UserIC)
          IC = UserIC;
        IC = LVP.limitBackendIC(*Plan, IC);
        uint64_t Width =
            uint64_t(VF.getKnownMinValue()) *
            (VF.isScalable() ? Config.getVScaleForTuning().value_or(1) : 1);
        if (!IC || !Width || Width > UINT32_MAX / IC) {
          PreparationError = "candidate iteration width overflow";
          return false;
        }
        Preparation.mark("native_ic");
        InstructionCost EstimatedSpill;
        auto Profile = Native;
        Ev = 0;
        if (Mode.MIR) {
          if (Mode.EstimatedSpill)
            EstimatedSpill = LVP.backendSpillCost(*Plan, VF, Mode);
        } else
          Profile = LVP.backendCandidateCost(*Plan, VF, !Mode.DefaultTTI, Ev,
                                             &EstimatedSpill);
        if (!Profile.isValid() || !Ev.isValid() || !EstimatedSpill.isValid()) {
          PreparationError = "invalid profile candidate cost";
          return false;
        }
        std::string ID =
            (F.getName() + ":" + Twine(Invocation) + ":" + Twine(LoopIndex) +
             ":" + Twine(PlanIndex) + ":" + (VF.isScalable() ? "s" : "f") +
             Twine(VF.getKnownMinValue()) + ":ic" + Twine(IC) + ":main")
                .str();
        Preparation.mark("profile_cost");
        printCostTiming(ID, Preparation);
        VPlanBackendCandidate C{ID,
                                unsigned(PlanIndex),
                                VF,
                                Plan->hasScalarTail(),
                                InterleaveOnlyWhenForced,
                                VectorizeOnlyWhenForced};
        C.IC = IC;
        if (ForcedEpilogue.isVector()) {
          auto Epilogue = LVP.selectBestEpiloguePlan(*Plan, VF, IC);
          if (Epilogue)
            C.EpilogueVF = Epilogue->getSingleVF();
        }
        if (Batch) {
          auto P = prepareCost(*Plan, std::move(C), Native, Profile, Ev,
                               unsigned(Width), EstimatedSpill);
          P.Eligible = LVP.backendPruningEligible(*Plan, VF);
          Pending.push_back(std::move(P));
        } else if (!add(*Plan, std::move(C), Native, Profile, Ev,
                        unsigned(Width), EstimatedSpill))
          return false;
      }
    return true;
  };
  bool Prepared = Prepare();
  // Earlier query/pricing failures take precedence over a later preparation
  // error. Only the successfully prepared prefix can have work dispatched.
  if (Batch &&
      !addBatch(Pending, PreparationError.empty() ? Pruning : std::nullopt))
    return false;
  if (!PreparationError.empty())
    fail(PreparationError);
  return Prepared && !Failed;
}

bool VPlanBackendCostModel::prepareEpilogue(
    LoopVectorizationPlanner &LVP, VFSelectionContext &Config, VPlan &MainPlan,
    ElementCount MainVF, unsigned MainIC, VPlan &Plan, ElementCount VF) {
  if (lookup(Plan, VF, true))
    return true;
  unsigned PI = 0, MPI = 0;
  for (auto [Index, P] : enumerate(LVP.getPlans())) {
    if (P.get() == &Plan)
      PI = Index;
    if (P.get() == &MainPlan)
      MPI = Index;
  }
  VPlanFeedbackTimer Preparation(vplanBackendFeedbackTimingEnabled());
  InstructionCost Ev;
  auto Native = LVP.backendCandidateCost(Plan, VF, false, Ev);
  InstructionCost EstimatedSpill;
  auto Profile = Native;
  Ev = 0;
  if (Mode.MIR) {
    if (Mode.EstimatedSpill)
      EstimatedSpill = LVP.backendSpillCost(Plan, VF, Mode);
  } else
    Profile = LVP.backendCandidateCost(Plan, VF, !Mode.DefaultTTI, Ev,
                                       &EstimatedSpill);
  if (!Native.isValid() || !Profile.isValid() || !Ev.isValid() ||
      !EstimatedSpill.isValid()) {
    fail("invalid epilogue TTI cost");
    return false;
  }
  VPlanBackendCandidate C{
      (F.getName() + ":" + Twine(Invocation) + ":" + Twine(LoopIndex) + ":" +
       Twine(PI) + ":" + (VF.isScalable() ? "s" : "f") +
       Twine(VF.getKnownMinValue()) + ":ic1:epilogue:main" + Twine(MPI) + ":" +
       (MainVF.isScalable() ? "s" : "f") + Twine(MainVF.getKnownMinValue()) +
       ":ic" + Twine(MainIC))
          .str(),
      PI,
      VF,
      Plan.hasScalarTail(),
      InterleaveOnly,
      VectorizeOnly};
  Preparation.mark("native_and_profile_cost");
  printCostTiming(C.ID, Preparation);
  C.IsEpilogue = true;
  C.IC = 1;
  C.MainPlanIndex = MPI;
  C.MainVF = MainVF;
  C.MainIC = MainIC;
  C.EpilogueVF = VF;
  uint64_t Width =
      uint64_t(VF.getKnownMinValue()) *
      (VF.isScalable() ? Config.getVScaleForTuning().value_or(1) : 1);
  if (!Width || Width > UINT32_MAX) {
    fail("epilogue iteration width overflow");
    return false;
  }
  return add(Plan, C, Native, Profile, Ev, unsigned(Width), EstimatedSpill);
}

json::Object VPlanBackendCostModel::attemptSummary() const {
  json::Array Observations;
  for (const auto &O : Observed)
    Observations.push_back(summarizeVPlanBackendResult(O));
  return json::Object{{"model", Mode.name()},
                      {"use_estimated_spill", Mode.EstimatedSpill},
                      {"use_default_tti", Mode.DefaultTTI},
                      {"status", Failed ? "failed" : "succeeded"},
                      {"reason", Failure},
                      {"observations", std::move(Observations)}};
}

void VPlanBackendCostModel::commit(VPlanBackendMode Requested, StringRef Reason,
                                   const json::Array &Attempts) {
  assert(!Failed);
  for (const auto &Row : Rows)
    writeVPlanBackendFeedback(Row);
  Rows.clear();
  if (!Reason.empty()) {
    if (vplanBackendFeedbackOutputEnabled())
      writeVPlanBackendFeedback(
          json::Object{{"model", Mode.name()},
                       {"requested_model", Requested.name()},
                       {"attempts", json::Array(Attempts)},
                       {"requested_estimated_spill", Requested.EstimatedSpill},
                       {"requested_default_tti", Requested.DefaultTTI},
                       {"effective_model", Mode.name()},
                       {"status", Mode.EstimatedSpill ? "estimated-fallback"
                                                      : "real-spill-fallback"},
                       {"function", F.getName()},
                       {"loop", LoopIndex},
                       {"reason", Reason}});
    VP_COST_SUMMARY(Report, OS << "  backend-fallback requested_model="
                               << Requested.name() << " effective_model="
                               << Mode.name() << " reason=" << Reason << '\n');
  }
}

void VPlanBackendCostModel::selection(ElementCount VF, unsigned IC,
                                      ElementCount Epilogue,
                                      bool Emitted) const {
  if (!vplanBackendFeedbackOutputEnabled())
    return;
  const auto Requested = VPlanBackendMode::requested();
  json::Object Row{{"model", Mode.name()},
                   {"requested_model", Requested.name()},
                   {"requested_estimated_spill", Requested.EstimatedSpill},
                   {"requested_default_tti", Requested.DefaultTTI},
                   {"use_estimated_spill", Mode.EstimatedSpill},
                   {"use_default_tti", Mode.DefaultTTI},
                   {"effective_model", Mode.name()},
                   {"status", "selected"},
                   {"function", F.getName()},
                   {"loop", LoopIndex},
                   {"vf", VF.getKnownMinValue()},
                   {"scalable", VF.isScalable()},
                   {"ic", IC},
                   {"epilogue_vf", Epilogue.getKnownMinValue()},
                   {"epilogue_scalable", Epilogue.isScalable()},
                   {"emitted", Emitted}};
  if (ScalarEntry)
    addScalarFields(Row, *ScalarEntry);
  writeVPlanBackendFeedback(Row);
}
