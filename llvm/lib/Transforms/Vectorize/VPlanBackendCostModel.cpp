// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "VPlanBackendCostModel.h"
#include "LoopVectorizationPlanner.h"
#include "VPlan.h"
#include "VPlanCostReport.h"
#include "VPlanRegisterUsageBounds.h"
#include "llvm/ADT/ScopeExit.h"
#include "llvm/Analysis/TargetTransformInfo.h"
#include "llvm/IR/Function.h"
#include "llvm/Support/SaveAndRestore.h"
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
                                 {"evidence", I.Evidence},
                                 {"count_source", I.CountSource},
                                 {"price_group8", I.PriceGroup8},
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
void VPlanBackendCostModel::fail(VPlanBackendFailure Failure) {
  if (Failed)
    return;
  Failed = true;
  Failures.push_back(std::move(Failure));
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
VPlanBackendCostModel::PreparedCandidate
VPlanBackendCostModel::prepareCost(VPlan &Plan, VPlanBackendCandidate C,
                                   InstructionCost Native,
                                   InstructionCost Profile, unsigned Width,
                                   InstructionCost EstimatedSpill) const {
  auto Bound = computeVPlanRegisterUsageBound(Plan, C.VF, TTI);
  Bound.applyInterleave(C.IC);
  // The vector-only bound cannot rule out scalar spills. Keep it diagnostic.
  bool Query = Mode.needsProbe();
  C.Observation.CollectMIR = Mode.MIR;
  C.Observation.CaptureMIRText = Report && Report->isDetailed();
  C.Observation.CaptureFailures = vplanBackendFeedbackOutputEnabled();
  return {&Plan,          std::move(C), Native, Profile,
          EstimatedSpill, Width,        Bound,  Query};
}

bool VPlanBackendCostModel::add(VPlan &Plan, VPlanBackendCandidate C,
                                InstructionCost Native, InstructionCost Profile,
                                unsigned Width,
                                InstructionCost EstimatedSpill) {
  if (Failed)
    return false;
  if (!Width || !C.IC || Width > UINT32_MAX / C.IC) {
    fail("candidate iteration width overflow",
         VPlanBackendFailureGroup::Tracking, C.ID);
    return false;
  }
  VPlanFeedbackTimer Timer(vplanBackendFeedbackTimingEnabled());
  auto ReportTime = scope_exit([&] { printCostTiming(C.ID, Timer); });
  auto Prepared = prepareCost(Plan, C, Native, Profile, Width, EstimatedSpill);
  Timer.mark("gate");
  std::optional<VPlanBackendProbeResult> Result;
  if (Prepared.Query && Native.isValid() && Profile.isValid() &&
      EstimatedSpill.isValid()) {
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
    E.Error = Result.Failure;
    if (E.Error && E.Error->Candidate.empty())
      E.Error->Candidate = P.Candidate.ID;
    return E;
  }
  const auto &O = *Result.Observation;
  const auto &C = P.Candidate;
  const auto &Facts = Mode.MIR ? O.MIR : O.Spill;
  if (O.Candidate != C.ID || O.VF != C.VF || O.IC != C.IC ||
      O.IsEpilogue != C.IsEpilogue || O.Kind != C.Kind)
    E.Error = VPlanBackendFailure{VPlanBackendFailureGroup::Integrity,
                                  "backend observation identity mismatch",
                                  C.ID,
                                  "probe",
                                  {},
                                  {}};
  else if (!Facts.succeeded()) {
    E.Error = O.Failure ? O.Failure : Facts.Failure;
    if (!E.Error)
      E.Error = VPlanBackendFailure{VPlanBackendFailureGroup::Availability,
                                    "required observation unavailable",
                                    C.ID,
                                    Facts.Stage,
                                    {},
                                    {}};
  }
  if (!E.Error) {
    if (Mode.MIR) {
      auto Cost = priceVPlanMIR(
          O.MIR, *MIRInfo, P.Width,
          vplanBackendFeedbackOutputEnabled() ? &E.Failures : nullptr);
      if (!Cost)
        E.Error = takeVPlanBackendFailure(Cost.takeError(),
                                          VPlanBackendFailureGroup::Pricing,
                                          C.ID, O.MIR.Stage);
      else
        E.MIR = std::move(*Cost);
    }
    if (!Mode.EstimatedSpill && !E.Error) {
      auto Spill = priceVPlanSpills(
          O.Spill, TTI, F.getContext(), P.Width, E.Raw,
          Report && Report->isDetailed() ? &E.AccessCosts : nullptr,
          &E.SpillLoops,
          vplanBackendFeedbackOutputEnabled() ? &E.Failures : nullptr);
      if (!Spill)
        E.Error = takeVPlanBackendFailure(Spill.takeError(),
                                          VPlanBackendFailureGroup::Pricing,
                                          C.ID, O.Spill.Stage);
      else {
        E.Spill = *Spill;
        if (Mode.MIR) {
          auto MIRFacts = O.MIR, SpillFacts = O.Spill;
          auto Common = [&](const VPlanBackendLoopObservation &L) {
            return any_of(E.MIR->Loops,
                          [&](const auto &M) {
                            return M.ID == L.ID &&
                                   M.IterationWidth == L.IterationWidth;
                          }) &&
                   any_of(E.SpillLoops, [&](const auto &S) {
                     return S.ID == L.ID &&
                            S.IterationWidth == L.IterationWidth;
                   });
          };
          llvm::erase_if(MIRFacts.Loops,
                         [&](const auto &L) { return !Common(L); });
          llvm::erase_if(SpillFacts.Loops,
                         [&](const auto &L) { return !Common(L); });
          auto M = priceVPlanMIR(MIRFacts, *MIRInfo, P.Width);
          E.SpillLoops.clear();
          E.AccessCosts.clear();
          auto S = priceVPlanSpills(SpillFacts, TTI, F.getContext(), P.Width,
                                    E.Raw, &E.AccessCosts, &E.SpillLoops);
          if (!M || !S) {
            if (!M)
              E.Error = takeVPlanBackendFailure(
                  M.takeError(), VPlanBackendFailureGroup::Pricing, C.ID,
                  O.MIR.Stage);
            if (!S)
              E.Error = takeVPlanBackendFailure(
                  S.takeError(), VPlanBackendFailureGroup::Pricing, C.ID,
                  O.Spill.Stage);
          } else {
            E.MIR = std::move(*M);
            E.Spill = *S;
          }
        }
      }
    }
  }
  for (auto &Failure : E.Failures)
    if (Failure.Candidate.empty())
      Failure.Candidate = C.ID;
  return E;
}

void VPlanBackendCostModel::recordObservation(
    const VPlanBackendProbeResult &Result, StringRef Candidate) {
  auto Add = [&](VPlanBackendFailure Failure) {
    if (Failure.Candidate.empty())
      Failure.Candidate = Candidate.str();
    Failures.push_back(std::move(Failure));
  };
  if (Result.Cancelled)
    return;
  if (Result.Failure)
    Add(*Result.Failure);
  if (!Result.Observation)
    return;
  const auto &O = *Result.Observation;
  if (O.Failure)
    Add(*O.Failure);
  for (const auto *Slot : {&O.Spill, &O.MIR}) {
    if (Slot->Failure)
      Add(*Slot->Failure);
    for (const auto &Failure : Slot->Exclusions)
      Add(Failure);
  }
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
          !(VPExactCost(P.Profile) - VPExactCost(P.EstimatedSpill)).isValid())
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
        auto B = VPExactCost(P.Profile) - VPExactCost(P.EstimatedSpill);
        S.Lower = score(B, P.Width);
        S.Rank = VPExactCost::ratio(B.numerator(), P.Width);
        S.Eligible = P.Eligible;
        S.Control = std::make_shared<VPlanBackendProbeControl>();
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
    if (E.Error || !S.Eligible)
      return;
    const auto &P = Candidates[I];
    auto Body =
        VPExactCost(P.Profile) - VPExactCost(P.EstimatedSpill) + E.Spill;
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
        Outcomes[I].Evaluated = evaluateObservation(Candidates[I], R);
        Pruning.completed(I, *Outcomes[I].Evaluated);
      };
    auto C = Candidates[I].Candidate;
    C.Control = S.Control;
    Queries.push_back(std::move(C));
  }
  auto Results = Feedback.getBatch(F, Header, Queries);
  std::optional<VPlanBackendFailure> BatchFailure;
  if (!Results)
    BatchFailure = takeVPlanBackendFailure(
        Results.takeError(), VPlanBackendFailureGroup::Execution, "", "probe");
  for (unsigned J = 0; J < Order.size(); ++J) {
    auto &Outcome = Outcomes[Order[J]];
    if (!BatchFailure)
      Outcome.Result = std::move((*Results)[J]);
    else
      Outcome.Result.emplace(vplanBackendError(*BatchFailure));
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
            {"invocation", Invocation},
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
             (VPExactCost(P.Profile) - VPExactCost(P.EstimatedSpill))
                 .numerator()},
            {"lower_bound_quarters_denominator",
             (VPExactCost(P.Profile) - VPExactCost(P.EstimatedSpill))
                 .denominator()},
            {"score_lower_bound_quarters_numerator", S.Lower.numerator()},
            {"score_lower_bound_quarters_denominator", S.Lower.denominator()}});
      if (vplanBackendFeedbackOutputEnabled() && ScalarEntry)
        addScalarFields(Rows.back(), *ScalarEntry);
      if (vplanBackendFeedbackOutputEnabled() && Outcomes[I].Result &&
          Outcomes[I].Result->Observation)
        Rows.back()["observation"] =
            summarizeVPlanBackendResult(*Outcomes[I].Result->Observation);
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
  auto Native = P.Native, Profile = P.Profile;
  unsigned Width = P.Width;
  bool Query = P.Query;
  VPExactCost Spill;
  InstructionCost Raw;
  std::optional<VPlanBackendFailure> Error;
  std::optional<VPlanBackendResult> Observation;
  SmallVector<VPSpillCost> AccessCosts;
  SmallVector<VPSpillLoopCost> SpillLoops;
  std::optional<VPMIRCost> MIRCost;
  if (!Native.isValid() || !Profile.isValid() || !P.EstimatedSpill.isValid())
    Error = VPlanBackendFailure{VPlanBackendFailureGroup::Pricing,
                                "invalid TTI candidate cost",
                                C.ID,
                                "selection",
                                {},
                                {}};
  else if (Query) {
    assert(Result && "missing required backend query result");
    errs() << Result->Diagnostics;
    recordObservation(*Result, C.ID);
    auto E = Evaluated ? *Evaluated : evaluateObservation(P, *Result);
    Error = std::move(E.Error);
    Failures.append(E.Failures);
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
      Body = composeVPlanMIRCost(*MIRCost, Mode.EstimatedSpill
                                               ? VPExactCost(P.EstimatedSpill)
                                               : Spill);
    } else
      Body = VPExactCost::ratio(-1, 1);
  } else if (!Mode.EstimatedSpill)
    Body = Body - VPExactCost(P.EstimatedSpill) + Spill;
  if (!Body.isValid() && !Error)
    Error = VPlanBackendFailure{VPlanBackendFailureGroup::Pricing,
                                "invalid or overflowing hybrid cost",
                                C.ID,
                                "selection",
                                {},
                                {}};
  if (!Error) {
    Costs.push_back({P.Plan, C.VF, C.IC, C.IsEpilogue, Native, Profile, Body,
                     P.EstimatedSpill, std::move(MIRCost)});
    if (Report)
      Report->backendCost(Costs.back(), Bound,
                          Observation ? &*Observation : nullptr, AccessCosts,
                          SpillLoops.size(), Width,
                          TTI.getVPlanCostProfileName(), Raw, Spill, Mode);
  }
  // Serialization is entirely optional. The selection and text report use
  // the owned C++ observation and the exact values computed above.
  if (vplanBackendFeedbackOutputEnabled()) {
    json::Object Gate{{"enabled", false},
                      {"hypothetical", true},
                      {"known", Bound.Known},
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
                     {"cost_source", Query ? "observation" : "estimated"},
                     {"use_mir", Mode.MIR},
                     {"use_estimated_spill", Mode.EstimatedSpill},
                     {"candidate", C.ID},
                     {"feedback_point", "middle-end-before-vf-selection"},
                     {"function", F.getName()},
                     {"loop", LoopIndex},
                     {"invocation", Invocation},
                     {"plan", C.PlanIndex},
                     {"tti_profile", TTI.getVPlanCostProfileName()},
                     {"vf", C.VF.getKnownMinValue()},
                     {"scalable", C.VF.isScalable()},
                     {"ic", C.IC},
                     {"role", C.IsEpilogue ? "epilogue" : "main"},
                     {"vector_epilogue", C.EpilogueVF.isVector()},
                     {"register_usage_bound", std::move(Gate)}};
    if (Observation) {
      Row["real_spill_used"] = !Mode.EstimatedSpill && !Error;
      Row["real_spill_unused_reason"] =
          Mode.EstimatedSpill ? "estimated-spill-requested" : "";
      Row["status"] = "collected";
      Row["observation"] = summarizeVPlanBackendResult(*Observation);
    } else {
      Row["status"] = Query ? "unavailable" : "skipped";
      Row["reason"] = Query                 ? StringRef("")
                      : Mode.EstimatedSpill ? "estimated-spill-no-probe"
                                            : Bound.Reason;
    }
    if (!Error) {
      Row["native_body_quarters"] = Native.getQuarterValue();
      Row["profile_body_quarters"] = Profile.getQuarterValue();
      Row["estimated_total_spill_quarters"] =
          P.EstimatedSpill.getQuarterValue();
      {
        Row["raw_spill_sum_quarters"] = Raw.isValid()
                                            ? json::Value(Raw.getQuarterValue())
                                            : json::Value(nullptr);
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
      {
        Row["normalized_spill_quarters_numerator"] = Spill.numerator();
        Row["normalized_spill_quarters_denominator"] = Spill.denominator();
      }
      Row["body_quarters_numerator"] = Body.numerator();
      Row["body_quarters_denominator"] = Body.denominator();
    }
    Rows.push_back(std::move(Row));
  }
  Timer.mark("hybrid_cost_and_summary");
  if (Error) {
    fail(*Error);
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
  PreparedCandidate P{nullptr, C, 0, 0, EstimatedSpill, 1, {}, true};
  recordObservation(Result, C.ID);
  auto E = evaluateObservation(P, Result);
  Failures.append(E.Failures);
  if (E.Error || (Mode.MIR && !E.MIR)) {
    if (E.Error)
      fail(*E.Error);
    else
      fail("scalar MIR cost unavailable",
           VPlanBackendFailureGroup::Availability, C.ID);
    return false;
  }
  auto Body =
      Mode.MIR ? composeVPlanMIRCost(*E.MIR, Mode.EstimatedSpill
                                                 ? VPExactCost(EstimatedSpill)
                                                 : E.Spill)
               : ScalarEntry->Body + E.Spill;
  if (!Body.isValid()) {
    fail("invalid or overflowing scalar MIR cost");
    return false;
  }
  ScalarEntry = VPBackendScalarCostEntry{
      Body,
      EstimatedSpill,
      Mode.MIR
          ? (Mode.EstimatedSpill ? "mir-estimated-spill" : "mir-observed-spill")
          : "tti-observed-spill",
      Mode.MIR ? E.MIR->Model : "native",
      Mode.MIR ? E.MIR->Revision : "native-tti",
      std::move(E.MIR),
      E.Spill};
  if (Report)
    Report->backendScalarCost(*ScalarEntry, &*Result.Observation);
  if (vplanBackendFeedbackOutputEnabled()) {
    json::Object Row{
        {"model", Mode.name()},
        {"cost_source", "observation"},
        {"scalar_cost_source", ScalarEntry->Source},
        {"scalar_profile", ScalarEntry->Profile},
        {"scalar_revision", ScalarEntry->Revision},
        {"use_mir", Mode.MIR},
        {"use_estimated_spill", Mode.EstimatedSpill},
        {"candidate", C.ID},
        {"function", F.getName()},
        {"loop", LoopIndex},
        {"invocation", Invocation},
        {"vf", 1},
        {"scalable", false},
        {"ic", 1},
        {"role", "scalar-baseline"},
        {"status", "collected"},
        {"tti_profile", TTI.getVPlanCostProfileName()},
        {"tti_width", 1},
        {"observation", summarizeVPlanBackendResult(*Result.Observation)},
        {"estimated_total_spill_quarters", EstimatedSpill.getQuarterValue()},
        {"body_quarters_numerator", Body.numerator()},
        {"body_quarters_denominator", Body.denominator()}};
    if (ScalarEntry->MIR)
      addMIRFields(Row, *ScalarEntry->MIR);
    Row["normalized_spill_quarters_numerator"] = E.Spill.numerator();
    Row["normalized_spill_quarters_denominator"] = E.Spill.denominator();
    if (!Mode.MIR)
      Row["profile_body_quarters"] =
          InstructionCost(Body - E.Spill).getQuarterValue();
    Rows.push_back(std::move(Row));
  }
  return true;
}

bool VPlanBackendCostModel::prepareScalar(LoopVectorizationPlanner &LVP) {
  if (!Mode.MIR && Mode.EstimatedSpill) {
    auto Scalar = VPExactCost(LVP.backendScalarCost(Mode));
    if (!Scalar.isValid()) {
      fail("invalid scalar baseline cost");
      return false;
    }
    StringRef Profile = "native", Revision = "native-tti";
    ScalarEntry = VPBackendScalarCostEntry{
        Scalar, 0, "tti", Profile.str(), Revision.str(), std::nullopt, {}};
    if (Report)
      Report->backendScalarCost(*ScalarEntry, nullptr);
    return true;
  }
  InstructionCost EstimatedSpill =
      Mode.EstimatedSpill ? LVP.backendScalarSpillCost() : InstructionCost(0);
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
  C.Observation.CollectMIR = Mode.MIR;
  C.Observation.CaptureMIRText = Report && Report->isDetailed();
  C.Observation.CaptureFailures = vplanBackendFeedbackOutputEnabled();
  if (!Mode.MIR)
    ScalarEntry =
        VPBackendScalarCostEntry{VPExactCost(LVP.backendScalarCost(Mode)),
                                 0,
                                 "tti-observed-spill",
                                 "native",
                                 "native-tti",
                                 std::nullopt,
                                 {}};
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
    fail("target has no MIR pricing service",
         VPlanBackendFailureGroup::Availability);
    return false;
  }
  if (!prepareScalar(LVP))
    return false;
  auto Pruning =
      !Mode.MIR && !Mode.EstimatedSpill && !vplanBackendFeedbackForceAll()
          ? LVP.backendPruningContext(scalarCost())
          : std::nullopt;
  const bool Batch =
      Mode.needsProbe() && (Feedback.canBatch(F) || Pruning.has_value());
  SmallVector<PreparedCandidate, 0> Pending;
  std::optional<VPlanBackendFailure> PreparationError;
  auto Prepare = [&]() -> bool {
    for (auto [PlanIndex, Plan] : enumerate(LVP.getPlans()))
      for (ElementCount VF : Plan->vectorFactors()) {
        if (VF.isScalar())
          continue;
        VPlanFeedbackTimer Preparation(vplanBackendFeedbackTimingEnabled());
        InstructionCost EstimatedSpill;
        auto Native = LVP.backendCandidateCost(*Plan, VF, EstimatedSpill);
        if (!Native.isValid()) {
          PreparationError =
              VPlanBackendFailure{VPlanBackendFailureGroup::Pricing,
                                  "invalid native candidate cost",
                                  "",
                                  "selection",
                                  {},
                                  {}};
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
          PreparationError =
              VPlanBackendFailure{VPlanBackendFailureGroup::Tracking,
                                  "candidate iteration width overflow",
                                  "",
                                  "selection",
                                  {},
                                  {}};
          return false;
        }
        Preparation.mark("native_ic");
        auto Profile = Native;
        if (Mode.MIR && !Mode.EstimatedSpill)
          EstimatedSpill = 0;
        if (!EstimatedSpill.isValid()) {
          PreparationError =
              VPlanBackendFailure{VPlanBackendFailureGroup::Pricing,
                                  "invalid candidate spill estimate",
                                  "",
                                  "selection",
                                  {},
                                  {}};
          return false;
        }
        std::string ID =
            (F.getName() + ":" + Twine(Invocation) + ":" + Twine(LoopIndex) +
             ":" + Twine(PlanIndex) + ":" + (VF.isScalable() ? "s" : "f") +
             Twine(VF.getKnownMinValue()) + ":ic" + Twine(IC) + ":main")
                .str();
        Preparation.mark("candidate_setup");
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
          auto P = prepareCost(*Plan, std::move(C), Native, Profile,
                               unsigned(Width), EstimatedSpill);
          P.Eligible = LVP.backendPruningEligible(*Plan, VF);
          Pending.push_back(std::move(P));
        } else if (!add(*Plan, std::move(C), Native, Profile, unsigned(Width),
                        EstimatedSpill))
          return false;
      }
    return true;
  };
  bool Prepared = Prepare();
  // Earlier query/pricing failures take precedence over a later preparation
  // error. Only the successfully prepared prefix can have work dispatched.
  if (Batch && !addBatch(Pending, !PreparationError ? Pruning : std::nullopt))
    return false;
  if (PreparationError)
    fail(*PreparationError);
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
  InstructionCost EstimatedSpill;
  auto Native = LVP.backendCandidateCost(Plan, VF, EstimatedSpill);
  auto Profile = Native;
  if (Mode.MIR && !Mode.EstimatedSpill)
    EstimatedSpill = 0;
  if (!Native.isValid() || !EstimatedSpill.isValid()) {
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
  Preparation.mark("native_cost");
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
    fail("epilogue iteration width overflow",
         VPlanBackendFailureGroup::Tracking, C.ID);
    return false;
  }
  return add(Plan, C, Native, Profile, unsigned(Width), EstimatedSpill);
}

json::Object VPlanBackendCostModel::attemptSummary() const {
  json::Array Observations;
  for (const auto &O : Observed)
    Observations.push_back(summarizeVPlanBackendResult(O));
  return json::Object{{"model", Mode.name()},
                      {"use_estimated_spill", Mode.EstimatedSpill},
                      {"status", Failed ? "failed" : "succeeded"},
                      {"failures", summarizeVPlanBackendFailures(Failures)},
                      {"observations", std::move(Observations)}};
}

void VPlanBackendCostModel::commit() {
  assert(!Failed);
  for (const auto &Row : Rows)
    writeVPlanBackendFeedback(Row);
  Rows.clear();
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
                   {"use_estimated_spill", Mode.EstimatedSpill},
                   {"effective_model", Mode.name()},
                   {"status", "selected"},
                   {"function", F.getName()},
                   {"loop", LoopIndex},
                   {"invocation", Invocation},
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
