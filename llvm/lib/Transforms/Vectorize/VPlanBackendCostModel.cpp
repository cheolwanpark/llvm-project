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
} // namespace
VPExactCost VPExactCost::ratio(int64_t N, int64_t D) {
  VPExactCost R;
  if (N < 0 || D <= 0) {
    R.Valid = false;
    return R;
  }
  int64_t G = std::gcd(N, D);
  R.N = N / G;
  R.D = D / G;
  return R;
}
VPExactCost::operator InstructionCost() const {
  if (!Valid)
    return InstructionCost::getInvalid();
  // Same truncation as InstructionCost::getValue at legacy integer consumers.
  return InstructionCost(N / D / 4) + InstructionCost((N / D) % 4) / 4;
}
VPExactCost VPExactCost::operator+(VPExactCost B) const {
  int64_t G = std::gcd(D, B.D), A1, B1, Sum, Den;
  if (!Valid || !B.Valid || MulOverflow(N, B.D / G, A1) ||
      MulOverflow(B.N, D / G, B1) || AddOverflow(A1, B1, Sum) ||
      MulOverflow(D, B.D / G, Den))
    return ratio(-1, 1);
  return ratio(Sum, Den);
}
VPExactCost VPExactCost::operator-(VPExactCost B) const {
  B.N = -B.N;
  return *this + B;
}
VPExactCost VPExactCost::operator*(unsigned B) const {
  int64_t Product;
  int64_t G = std::gcd(D, int64_t(B));
  if (!Valid || MulOverflow(N, int64_t(B) / G, Product))
    return ratio(-1, 1);
  return ratio(Product, D / G);
}
bool VPExactCost::operator<(VPExactCost B) const {
  if (!Valid || !B.Valid)
    return Valid && !B.Valid;
  return (APInt(128, N) * APInt(128, B.D)).ult(APInt(128, B.N) * APInt(128, D));
}
bool VPExactCost::operator==(VPExactCost B) const {
  return Valid == B.Valid && (!Valid || APInt(128, N) * APInt(128, B.D) ==
                                            APInt(128, B.N) * APInt(128, D));
}
bool VPExactCost::operator<=(VPExactCost B) const {
  return *this < B || *this == B;
}

void VPExactCost::print(raw_ostream &OS, unsigned Divisor) const {
  if (!Valid) {
    OS << "Invalid";
    return;
  }
  assert(Divisor);
  // Convert quarter units to model units without overflowing a 64-bit
  // denominator or truncating the value used by the ranking comparison.
  int64_t G = std::gcd(N, int64_t(4));
  int64_t Num = N / G;
  APInt Den = APInt(128, D) * APInt(128, 4 / G);
  G = std::gcd(Num, int64_t(Divisor));
  Num /= G;
  Den *= APInt(128, Divisor / G);
  OS << Num;
  if (Den != 1)
    OS << '/' << Den;
}

Expected<VPExactCost> llvm::priceVPlanVectorSpills(
    const VPlanBackendResult &O, const TargetTransformInfo &TTI,
    LLVMContext &Context, unsigned Width, InstructionCost &RawCost,
    SmallVectorImpl<InstructionCost> *AccessCosts) {
  if (!O.IterationMapping || O.Stage != "post-stack-slot-coloring")
    return createStringError("invalid backend loop/iteration mapping");
  uint64_t Wobs = O.IterationWidth;
  if (!Wobs || Wobs > INT64_MAX || !Width || Wobs % Width)
    return createStringError("invalid backend iteration width");
  int64_t RawQuarters = 0;
  for (const auto &A : O.Spills) {
    if (!A.MinBytes || A.MinBytes > UINT32_MAX || !A.Alignment ||
        !isPowerOf2_64(A.Alignment) || A.Alignment > Value::MaximumAlignment ||
        !A.WholeRegister || !isPowerOf2_32(A.RegisterGroup) ||
        A.RegisterGroup > 8)
      return createStringError("unsupported vector spill access");
    Type *Ty = VectorType::get(Type::getInt8Ty(Context),
                               ElementCount::get(A.MinBytes, A.Scalable));
    TargetTransformInfo::SpillReloadAccess Access{
        A.IsLoad,       Ty, Align(A.Alignment), A.AddressSpace, A.WholeRegister,
        A.RegisterGroup};
    VPlanCostProfileScope Scope(true);
    auto Cost = TTI.getSpillReloadCost(
        Access, TargetTransformInfo::TCK_RecipThroughput);
    if (!Cost.isValid() || Cost < 0 ||
        AddOverflow(RawQuarters, Cost.getQuarterValue(), RawQuarters))
      return createStringError("invalid or overflowing vector spill cost");
    if (AccessCosts)
      AccessCosts->push_back(Cost);
  }
  RawCost =
      InstructionCost(RawQuarters / 4) + InstructionCost(RawQuarters % 4) / 4;
  int64_t Numerator;
  if (MulOverflow(RawQuarters, int64_t(Width), Numerator))
    return createStringError("vector spill normalization overflow");
  return VPExactCost::ratio(Numerator, Wobs);
}
void VPlanBackendCostModel::fail(StringRef Reason) {
  if (Failed)
    return;
  Failed = true;
  Failure = Reason.str();
  Costs.clear();
  Pruned.clear();
  if (vplanBackendFeedbackOutputEnabled())
    writeVPlanBackendFeedback(
        json::Object{{"model", "tti-real-vector-spill-v1"},
                     {"status", "native-fallback"},
                     {"function", F.getName()},
                     {"loop", LoopIndex},
                     {"reason", Failure}});
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
    InstructionCost Profile, InstructionCost Ev, unsigned Width) const {
  auto Bound = computeVPlanRegisterUsageBound(Plan, C.VF, TTI);
  Bound.applyInterleave(C.IC);
  bool Query = Bound.shouldQuery() || vplanBackendFeedbackForceAll();
  return {&Plan, std::move(C), Native, Profile, Ev, Width, Bound, Query};
}

bool VPlanBackendCostModel::add(VPlan &Plan, VPlanBackendCandidate C,
                                InstructionCost Native, InstructionCost Profile,
                                InstructionCost Ev, unsigned Width) {
  if (Failed)
    return false;
  VPlanFeedbackTimer Timer(vplanBackendFeedbackTimingEnabled());
  auto ReportTime = scope_exit([&] { printCostTiming(C.ID, Timer); });
  auto Prepared = prepareCost(Plan, C, Native, Profile, Ev, Width);
  Timer.mark("gate");
  std::optional<VPlanBackendProbeResult> Result;
  if (Prepared.Query && Native.isValid() && Profile.isValid() && Ev.isValid()) {
    Result.emplace(Feedback.get(F, Header, C));
    Timer.mark("query_total");
  }
  return applyCost(Prepared, std::move(Result), Timer);
}

VPlanBackendCostModel::EvaluatedCost VPlanBackendCostModel::evaluateObservation(
    const PreparedCandidate &P, const VPlanBackendProbeResult &Result) const {
  EvaluatedCost E;
  if (!Result.Observation) {
    E.Error = Result.Failure;
    return E;
  }
  const auto &O = *Result.Observation;
  const auto &C = P.Candidate;
  if (O.Candidate != C.ID || O.VF != C.VF || O.IC != C.IC ||
      O.IsEpilogue != C.IsEpilogue)
    E.Error = "backend observation identity mismatch";
  else if (!O.IterationWidth || O.IterationWidth % (uint64_t(P.Width) * C.IC))
    E.Error = "observed iteration width disagrees with requested IC";
  else {
    auto Spill = priceVPlanVectorSpills(
        O, TTI, F.getContext(), P.Width, E.Raw,
        Report && Report->isDetailed() ? &E.AccessCosts : nullptr);
    if (!Spill)
      E.Error = toString(Spill.takeError());
    else
      E.Spill = *Spill;
  }
  return E;
}

bool VPlanBackendCostModel::addBatch(
    ArrayRef<PreparedCandidate> Candidates, LoopVectorizationPlanner *LVP,
    std::optional<VPBackendPruningContext> Context) {
  if (Candidates.empty())
    return true;
  for (const auto &P : Candidates)
    if (P.Candidate.ScalarTail != Candidates.front().Candidate.ScalarTail ||
        P.Candidate.VF.isScalable() !=
            Candidates.front().Candidate.VF.isScalable() ||
        !(VPExactCost(P.Profile) - VPExactCost(P.Ev)).isValid())
      Context.reset();
  auto Score = [&](VPExactCost Body, unsigned Width) {
    if (Context->MaxTripCount)
      return getVPlanCostForTripCount(Context->MaxTripCount, Width,
                                      Candidates.front().Candidate.ScalarTail,
                                      Body, Context->Scalar);
    int64_t Den;
    if (MulOverflow(Body.denominator(), int64_t(Width), Den))
      return VPExactCost::ratio(-1, 1);
    return VPExactCost::ratio(Body.numerator(), Den);
  };
  struct CandidateState {
    VPExactCost Lower, Rank;
    bool Eligible = false, Dominated = false;
    std::shared_ptr<VPlanBackendProbeControl> Control;
    std::optional<EvaluatedCost> Evaluated;
    std::optional<VPlanBackendProbeResult> Result;
  };
  SmallVector<CandidateState, 0> States(Candidates.size());
  std::optional<VPExactCost> Best;
  if (Context && Context->UseScalar) {
    auto S = Score(VPExactCost(Context->Scalar), 1);
    if (S.isValid())
      Best = S;
  }
  if (Context)
    for (unsigned I = 0; I < Candidates.size(); ++I) {
      const auto &P = Candidates[I];
      auto &S = States[I];
      auto B = VPExactCost(P.Profile) - VPExactCost(P.Ev);
      S.Lower = Score(B, P.Width);
      S.Rank = VPExactCost::ratio(B.numerator(), P.Width);
      S.Eligible = LVP->backendPruningEligible(*P.Plan, P.Candidate.VF);
      S.Control = std::make_shared<VPlanBackendProbeControl>();
      if (!P.Query && S.Eligible && S.Lower.isValid() &&
          (!Best || S.Lower < *Best))
        Best = S.Lower;
    }
  auto Reject = [&] {
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
  };
  Reject();
  SmallVector<unsigned> Order;
  for (unsigned I = 0; I < Candidates.size(); ++I)
    if (Candidates[I].Query && !States[I].Dominated)
      Order.push_back(I);
  if (Context)
    llvm::stable_sort(Order, [&](unsigned A, unsigned B) {
      return States[A].Rank < States[B].Rank;
    });
  SmallVector<VPlanBackendCandidate> Queries;
  for (unsigned I : Order) {
    auto &S = States[I];
    if (Context)
      S.Control->Completed = [&, I](const VPlanBackendProbeResult &R) {
        auto &S = States[I];
        if (S.Dominated || R.Cancelled)
          return;
        S.Evaluated = evaluateObservation(Candidates[I], R);
        if (!S.Evaluated->Error.empty() || !S.Eligible)
          return;
        const auto &P = Candidates[I];
        auto Cost = Score(VPExactCost(P.Profile) - VPExactCost(P.Ev) +
                              S.Evaluated->Spill,
                          P.Width);
        if (Cost.isValid() && (!Best || Cost < *Best)) {
          Best = Cost;
          Reject();
        }
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
    auto &S = States[Order[J]];
    if (BatchFailure.empty())
      S.Result = std::move((*Results)[J]);
    else
      S.Result.emplace(createStringError(BatchFailure));
  }
  VPlanFeedbackTimer Timer(false);
  for (unsigned I = 0; I < Candidates.size(); ++I) {
    const auto &P = Candidates[I];
    auto &S = States[I];
    if (S.Dominated) {
      Pruned.emplace_back(P.Plan, P.Candidate.VF);
      if (vplanBackendFeedbackOutputEnabled())
        writeVPlanBackendFeedback(json::Object{
            {"model", "tti-real-vector-spill-v1"},
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
            {"execution", !S.Control->Started   ? "not-started"
                          : S.Result->Cancelled ? "cancelled"
                                                : "completed"},
            {"lower_bound_quarters_numerator", S.Lower.numerator()},
            {"lower_bound_quarters_denominator", S.Lower.denominator()}});
      continue;
    }
    if (!applyCost(P, std::move(S.Result), Timer,
                   S.Evaluated ? &*S.Evaluated : nullptr))
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
  SmallVector<InstructionCost> AccessCosts;
  if (!Native.isValid() || !Profile.isValid() || !Ev.isValid())
    Error = "invalid TTI candidate cost";
  else if (Query) {
    assert(Result && "missing required backend query result");
    errs() << Result->Diagnostics;
    auto E = Evaluated ? *Evaluated : evaluateObservation(P, *Result);
    Error = std::move(E.Error);
    Spill = E.Spill;
    Raw = E.Raw;
    AccessCosts = std::move(E.AccessCosts);
    Observation = std::move(Result->Observation);
    Timer.mark("spill_pricing");
  }

  VPExactCost Body = VPExactCost(Profile) - VPExactCost(Ev) + Spill;
  if (!Body.isValid() && Error.empty())
    Error = "invalid or overflowing hybrid cost";
  if (Error.empty()) {
    Costs.push_back(
        {P.Plan, C.VF, C.IC, C.IsEpilogue, Native, Profile, Ev, Body});
    if (Report)
      Report->backendCost(Costs.back(), Bound,
                          Observation ? &*Observation : nullptr, AccessCosts,
                          Width, TTI.getVPlanCostProfileName(), Raw, Spill);
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
    json::Object Row{{"model", "tti-real-vector-spill-v1"},
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
      Row["status"] = "collected";
      Row["observation"] = summarizeVPlanBackendResult(*Observation);
    } else {
      Row["status"] = Query ? "unavailable" : "skipped";
      Row["reason"] = Query ? StringRef(Error) : Bound.Reason;
    }
    if (Error.empty()) {
      Row["native_body_quarters"] = Native.getQuarterValue();
      Row["profile_body_quarters"] = Profile.getQuarterValue();
      Row["estimated_vector_spill_quarters"] = Ev.getQuarterValue();
      Row["raw_vector_spill_quarters"] = Raw.getQuarterValue();
      Row["tti_width"] = Width;
      Row["normalized_vector_spill_quarters_numerator"] = Spill.numerator();
      Row["normalized_vector_spill_quarters_denominator"] = Spill.denominator();
      Row["body_quarters_numerator"] = Body.numerator();
      Row["body_quarters_denominator"] = Body.denominator();
    } else
      Row["cost_failure"] = Error;
    writeVPlanBackendFeedback(Row);
  }
  Timer.mark("hybrid_cost_and_summary");
  if (!Error.empty()) {
    fail(Error);
    return false;
  }
  return true;
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
  auto Pruning = !vplanBackendFeedbackForceAll() ? LVP.backendPruningContext()
                                                 : std::nullopt;
  const bool Batch = Feedback.canBatch(F) || Pruning.has_value();
  SmallVector<PreparedCandidate> Pending;
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
        auto Profile = LVP.backendCandidateCost(*Plan, VF, true, Ev);
        if (!Profile.isValid() || !Ev.isValid()) {
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
        if (Batch)
          Pending.push_back(prepareCost(*Plan, std::move(C), Native, Profile,
                                        Ev, unsigned(Width)));
        else if (!add(*Plan, std::move(C), Native, Profile, Ev,
                      unsigned(Width)))
          return false;
      }
    return true;
  };
  bool Prepared = Prepare();
  // Earlier query/pricing failures take precedence over a later preparation
  // error. Only the successfully prepared prefix can have work dispatched.
  if (Batch && !addBatch(Pending, &LVP,
                         PreparationError.empty() ? Pruning : std::nullopt))
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
  auto Profile = LVP.backendCandidateCost(Plan, VF, true, Ev);
  if (!Native.isValid() || !Profile.isValid() || !Ev.isValid()) {
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
  return add(Plan, C, Native, Profile, Ev,
             (VF.getKnownMinValue() *
              (VF.isScalable() ? Config.getVScaleForTuning().value_or(1) : 1)));
}

void VPlanBackendCostModel::selection(ElementCount VF, unsigned IC,
                                      ElementCount Epilogue,
                                      bool Emitted) const {
  if (!vplanBackendFeedbackOutputEnabled())
    return;
  writeVPlanBackendFeedback(
      json::Object{{"model", "tti-real-vector-spill-v1"},
                   {"status", "selected"},
                   {"function", F.getName()},
                   {"loop", LoopIndex},
                   {"vf", VF.getKnownMinValue()},
                   {"scalable", VF.isScalable()},
                   {"ic", IC},
                   {"epilogue_vf", Epilogue.getKnownMinValue()},
                   {"epilogue_scalable", Epilogue.isScalable()},
                   {"emitted", Emitted}});
}
