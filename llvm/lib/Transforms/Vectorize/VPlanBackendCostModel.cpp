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
VPExactCost VPExactCost::normalize(unsigned Width,
                                   uint64_t ObservedWidth) const {
  if (!Valid || !Width || !ObservedWidth || ObservedWidth > INT64_MAX)
    return ratio(-1, 1);
  uint64_t ScaleGCD = std::gcd(uint64_t(Width), ObservedWidth);
  Width /= ScaleGCD;
  ObservedWidth /= ScaleGCD;
  int64_t G1 = std::gcd(N, int64_t(ObservedWidth));
  int64_t G2 = std::gcd(int64_t(Width), D), Num, Den;
  if (MulOverflow(N / G1, int64_t(Width) / G2, Num) ||
      MulOverflow(D / G2, int64_t(ObservedWidth) / G1, Den))
    return ratio(-1, 1);
  return ratio(Num, Den);
}

Expected<VPMIRCost> llvm::priceVPlanMIR(const VPlanBackendResult &O,
                                        const TargetMIRInfo &Info,
                                        unsigned Width) {
  if (!O.IterationMapping || O.Stage != "post-frame-lowering" || !O.MIRBody ||
      O.MIRBody->empty() || !Width || !O.IterationWidth ||
      O.IterationWidth > INT64_MAX || O.IterationWidth % Width)
    return createStringError("invalid MIR body/stage/iteration mapping");
  VPMIRCost R;
  R.Model = Info.getModelName().str();
  R.Revision = Info.getRevision().str();
  R.CPU = Info.getCPU().str();
  R.NominalVLEN = Info.getNominalVLEN();
  for (const auto &MI : *O.MIRBody) {
    auto Cost = Info.getInstructionCost(MI);
    if (!Cost)
      return Cost.takeError();
    VPExactCost C = VPExactCost::ratio(Cost->Numerator, Cost->Denominator) * 4;
    if (!C.isValid())
      return createStringError("invalid MIR direct cost");
    R.RawBody = R.RawBody + C;
    if (MI.Spill)
      R.RawSpill = R.RawSpill + C;
    R.Instructions.push_back(std::move(*Cost));
  }
  R.Body = R.RawBody.normalize(Width, O.IterationWidth);
  R.Spill = R.RawSpill.normalize(Width, O.IterationWidth);
  if (!R.Body.isValid() || !R.Spill.isValid())
    return createStringError("invalid or overflowing MIR direct cost");
  return R;
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
    SmallVectorImpl<VPSpillCost> *AccessCosts) {
  if (!O.IterationMapping || O.Stage != "post-stack-slot-coloring")
    return createStringError("invalid backend loop/iteration mapping");
  uint64_t Wobs = O.IterationWidth;
  if (!Wobs || Wobs > INT64_MAX || !Width || Wobs % Width)
    return createStringError("invalid backend iteration width");
  SmallVector<VPSpillCost> Prices;
  int64_t RawQuarters = 0;
  for (const auto &A : O.Spills) {
    if (!A.MinBytes || A.MinBytes > UINT32_MAX || !A.Alignment ||
        !isPowerOf2_64(A.Alignment) || A.Alignment > Value::MaximumAlignment ||
        !A.WholeRegister || !isPowerOf2_32(A.RegisterGroup) ||
        A.RegisterGroup > 8)
      return createStringError("unsupported vector spill access");
    Type *Ty = VectorType::get(Type::getInt8Ty(Context),
                               ElementCount::get(A.MinBytes, A.Scalable));
    unsigned ClassID = TTI.getRegisterClassForType(true, Ty);
    auto I = llvm::find_if(Prices, [&](const VPSpillCost &P) {
      return P.ClassID == ClassID && P.IsLoad == A.IsLoad &&
             P.Registers / P.Accesses == A.RegisterGroup;
    });
    if (I == Prices.end()) {
      Prices.push_back({ClassID, A.IsLoad});
      I = std::prev(Prices.end());
    }
    if (I->Registers > uint64_t(INT64_MAX) - A.RegisterGroup ||
        I->Accesses == uint64_t(INT64_MAX))
      return createStringError("spill units overflow");
    I->Registers += A.RegisterGroup;
    ++I->Accesses;
  }
  VPlanCostProfileScope Scope(true);
  for (auto &P : Prices) {
    auto Cost = TTI.getRegisterClassSpillReloadCost(
        P.ClassID, P.IsLoad, {P.Registers, P.Accesses},
        TargetTransformInfo::TCK_RecipThroughput);
    if (!Cost.isValid() || Cost < 0 ||
        AddOverflow(RawQuarters, Cost.getQuarterValue(), RawQuarters))
      return createStringError("invalid or overflowing vector spill cost");
    if (AccessCosts)
      AccessCosts->push_back({P.ClassID, P.IsLoad, P.Registers, P.Accesses, Cost});
  }
  RawCost =
      InstructionCost(RawQuarters / 4) + InstructionCost(RawQuarters % 4) / 4;
  auto Normalized = VPExactCost::ratio(RawQuarters, 1).normalize(Width, Wobs);
  if (!Normalized.isValid())
    return createStringError("vector spill normalization overflow");
  return Normalized;
}
void VPlanBackendCostModel::fail(StringRef Reason) {
  if (Failed)
    return;
  Failed = true;
  Failure = Reason.str();
  Costs.clear();
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
  bool Query = Mode.MIR ||
               (!Mode.EstimatedSpill &&
                (Bound.shouldQuery() || vplanBackendFeedbackForceAll()));
  C.Observation.Kind = Mode.MIR
                           ? VPlanBackendObservationKind::MIRBody
                           : VPlanBackendObservationKind::VectorSpills;
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

bool llvm::vplanStrictlyCheaper(VPExactCost A, unsigned WidthA,
                                VPExactCost B, unsigned WidthB,
                                VPExactCost Scalar, unsigned TC,
                                bool ScalarTail) {
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
  if (Result.Cancelled || !Result.Observation) {
    E.Error = Result.Cancelled ? "backend probe cancelled" : Result.Failure;
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
    if (Mode.MIR) {
      auto Cost = priceVPlanMIR(O, *MIRInfo, P.Width);
      if (!Cost)
        E.Error = toString(Cost.takeError());
      else
        E.MIR = std::move(*Cost);
    } else {
      auto Spill = priceVPlanVectorSpills(
          O, TTI, F.getContext(), P.Width, E.Raw,
          Report && Report->isDetailed() ? &E.AccessCosts : nullptr);
      if (!Spill)
        E.Error = toString(Spill.takeError());
      else
        E.Spill = *Spill;
    }
  }
  return E;
}

bool VPlanBackendCostModel::addBatch(
    ArrayRef<PreparedCandidate> Candidates,
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
      return vplanCostForTripCount(Width, Body, VPExactCost(Context->Scalar),
                                   Context->MaxTripCount,
                                   Candidates.front().Candidate.ScalarTail);
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
  unsigned Basis = 0, BasisWidth = 1;
  VPExactCost BasisCost;
  if (Context && Context->UseScalar) {
    auto S = Score(VPExactCost(Context->Scalar), 1);
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
      S.Lower = Score(B, P.Width);
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
          Basis = I + 1;
          BasisWidth = P.Width;
          BasisCost =
              VPExactCost(P.Profile) - VPExactCost(P.Ev) + S.Evaluated->Spill;
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
      if (S.Result)
        errs() << S.Result->Diagnostics;
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
            {"execution", !S.Control->Started   ? "not-started"
                          : S.Result->Cancelled ? "cancelled"
                                                : "completed"},
            {"queried", S.Control->Started},
            {"pruning_basis",
             Basis ? Candidates[Basis - 1].Candidate.ID : "scalar"},
            {"basis_width", BasisWidth},
            {"tti_width", P.Width},
            {"max_trip_count", Context->MaxTripCount},
            {"scalar_tail", P.Candidate.ScalarTail},
            {"scalar_quarters_numerator",
             VPExactCost(Context->Scalar).numerator()},
            {"scalar_quarters_denominator",
             VPExactCost(Context->Scalar).denominator()},
            {"basis_quarters_numerator", BasisCost.numerator()},
            {"basis_quarters_denominator", BasisCost.denominator()},
            {"lower_bound_quarters_numerator",
             (VPExactCost(P.Profile) - VPExactCost(P.Ev)).numerator()},
            {"lower_bound_quarters_denominator",
             (VPExactCost(P.Profile) - VPExactCost(P.Ev)).denominator()},
            {"score_lower_bound_quarters_numerator", S.Lower.numerator()},
            {"score_lower_bound_quarters_denominator", S.Lower.denominator()}});
      if (vplanBackendFeedbackOutputEnabled() && S.Result &&
          S.Result->Observation)
        Rows.back()["observation"] =
            summarizeVPlanBackendResult(*S.Result->Observation);
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
  SmallVector<VPSpillCost> AccessCosts;
  std::optional<VPMIRCost> MIRCost;
  if (!Native.isValid() || !Profile.isValid() || !Ev.isValid() ||
      !P.EstimatedSpill.isValid())
    Error = "invalid TTI candidate cost";
  else if (Query) {
    assert(Result && "missing required backend query result");
    errs() << Result->Diagnostics;
    auto E = Evaluated ? *Evaluated : evaluateObservation(P, *Result);
    Error = std::move(E.Error);
    Spill = E.Spill;
    Raw = E.Raw;
    AccessCosts = std::move(E.AccessCosts);
    MIRCost = std::move(E.MIR);
    Observation = std::move(Result->Observation);
    Timer.mark(Mode.MIR ? "mir_pricing" : "spill_pricing");
  }

  VPExactCost Body = VPExactCost(Profile);
  if (Mode.MIR) {
    if (MIRCost) {
      Body = MIRCost->Body;
      if (Mode.EstimatedSpill)
        Body = Body - MIRCost->Spill + VPExactCost(P.EstimatedSpill);
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
      Report->backendCost(Costs.back(), Bound,
                          Observation ? &*Observation : nullptr, AccessCosts,
                          Width, TTI.getVPlanCostProfileName(), Raw, Spill, Mode);
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
                     {"cost_source", Query ? "observation"
                                     : Mode.EstimatedSpill ? "estimated" : "gate"},
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
      Row["status"] = "collected";
      Row["observation"] = summarizeVPlanBackendResult(*Observation);
    } else {
      Row["status"] = Query ? "unavailable" : "skipped";
      Row["reason"] = Query ? StringRef(Error)
                      : Mode.EstimatedSpill
                          ? "estimated-spill-no-probe"
                          : Bound.Reason;
    }
    if (Error.empty()) {
      Row["native_body_quarters"] = Native.getQuarterValue();
      Row["profile_body_quarters"] = Profile.getQuarterValue();
      Row["estimated_vector_spill_quarters"] = Ev.getQuarterValue();
      Row["estimated_total_spill_quarters"] =
          P.EstimatedSpill.getQuarterValue();
      if (!Mode.MIR)
        Row["raw_vector_spill_quarters"] = Raw.getQuarterValue();
      if (Costs.back().MIR) {
        const auto &M = *Costs.back().MIR;
        Row["mir_model"] = M.Model;
        Row["mir_revision"] = M.Revision;
        Row["mir_cost_schema"] = "direct-instruction-cost-v1";
        Row["mir_cpu"] = M.CPU;
        Row["mir_nominal_vlen"] = M.NominalVLEN;
        Row["mir_body_quarters_numerator"] = M.Body.numerator();
        Row["mir_body_quarters_denominator"] = M.Body.denominator();
        Row["mir_spill_quarters_numerator"] = M.Spill.numerator();
        Row["mir_spill_quarters_denominator"] = M.Spill.denominator();
        json::Array Ops;
        for (const auto &I : M.Instructions) {
          Ops.push_back(json::Object{{"rule", I.Rule},
                                     {"unknown", I.Unknown},
                                     {"numerator", I.Numerator},
                                     {"denominator", I.Denominator}});
        }
        Row["mir_costs"] = std::move(Ops);
      }
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
  if (Mode.MIR) {
    MIRInfo = Feedback.getMIRInfo(F);
    if (!MIRInfo) {
      fail("target has no MIR cost sheet");
      return false;
    }
  }
  if (Mode.needsProbe())
    Feedback.beginInvocation();
  auto Pruning =
      !Mode.MIR && !Mode.EstimatedSpill && !vplanBackendFeedbackForceAll()
          ? LVP.backendPruningContext()
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
        auto Profile = LVP.backendCandidateCost(*Plan, VF, !Mode.DefaultTTI, Ev,
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
  auto Profile = LVP.backendCandidateCost(
      Plan, VF, !Mode.DefaultTTI, Ev, &EstimatedSpill);
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
  uint64_t Width = uint64_t(VF.getKnownMinValue()) *
                   (VF.isScalable() ? Config.getVScaleForTuning().value_or(1) : 1);
  if (!Width || Width > UINT32_MAX) {
    fail("epilogue iteration width overflow");
    return false;
  }
  return add(Plan, C, Native, Profile, Ev, unsigned(Width), EstimatedSpill);
}

void VPlanBackendCostModel::commit(VPlanBackendMode Requested, StringRef Reason) {
  assert(!Failed);
  for (const auto &Row : Rows)
    writeVPlanBackendFeedback(Row);
  Rows.clear();
  if (!Reason.empty()) {
    if (vplanBackendFeedbackOutputEnabled())
      writeVPlanBackendFeedback(json::Object{
          {"model", Mode.name()}, {"requested_model", Requested.name()},
          {"effective_model", Mode.name()}, {"status", "estimated-fallback"},
          {"function", F.getName()}, {"loop", LoopIndex}, {"reason", Reason}});
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
  writeVPlanBackendFeedback(
      json::Object{{"model", Mode.name()},
                   {"requested_model", VPlanBackendMode::requested().name()},
                   {"effective_model", Mode.name()},
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
