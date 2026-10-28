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
  for (const auto &MI : *O.MIRBody) {
    auto Cost = Info.getInstructionCost(MI);
    if (!Cost)
      return Cost.takeError();
    if (Cost->Demands.empty())
      return createStringError("empty MIR service expansion");
    VPExactCost C;
    for (const auto &D : Cost->Demands)
      C = C + VPExactCost::ratio(D.Numerator, D.Denominator) * 4;
    R.RawBody = R.RawBody + C;
    if (MI.Spill)
      R.RawSpill = R.RawSpill + C;
    R.Instructions.push_back(std::move(*Cost));
  }
  R.Body = R.RawBody.normalize(Width, O.IterationWidth);
  R.Spill = R.RawSpill.normalize(Width, O.IterationWidth);
  if (!R.Body.isValid() || !R.Spill.isValid())
    return createStringError("invalid or overflowing MIR service demand");
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
  Rows.clear();
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

bool VPlanBackendCostModel::isPruned(const VPlan &Plan, ElementCount VF) const {
  return !Failed && any_of(Candidates, [&](const auto &P) {
    return P.Plan == &Plan && P.Candidate.VF == VF &&
           P.State == CandidateState::Pruned;
  });
}

bool VPlanBackendCostModel::prune(PreparedCandidate &P) {
  if (!Pruning.Enabled || !P.Eligible)
    return false;
  auto Cheaper = [&](VPExactCost Body, unsigned Width) {
    return vplanStrictlyCheaper(Body, Width, P.LowerBound, P.Width,
                               Pruning.Scalar, Pruning.MaxTripCount,
                               P.Candidate.ScalarTail);
  };
  if (Cheaper(Pruning.Scalar, 1)) {
    P.PruningBasis = "scalar";
    P.BasisCost = Pruning.Scalar;
    P.BasisWidth = 1;
  } else if (Pruning.VectorIncumbents)
    for (const auto &K : Candidates) {
      if (K.State != CandidateState::Exact || !K.Eligible)
        continue;
      const auto *Cost = lookup(*K.Plan, K.Candidate.VF);
      if (Cost && Cheaper(Cost->Body, K.Width)) {
        P.PruningBasis = K.Candidate.ID;
        P.BasisCost = Cost->Body;
        P.BasisWidth = K.Width;
        break;
      }
    }
  if (P.PruningBasis.empty())
    return false;
  P.State = CandidateState::Pruned;
  return true;
}

void VPlanBackendCostModel::reportPruned(const PreparedCandidate &P) {
  if (Report) {
    Report->skip(*P.Plan, P.Candidate.VF, "backend-lower-bound-pruned");
    VP_COST_SUMMARY(Report, OS << "  backend-pruned candidate=" << P.Candidate.ID
                              << " queried=" << P.Queried << " lower_bound=";
                    P.LowerBound.print(OS);
                    OS << " basis=" << P.PruningBasis << '\n');
  }
  if (!vplanBackendFeedbackOutputEnabled())
    return;
  json::Object Row{{"model", Mode.name()}, {"status", "pruned"},
                   {"function", F.getName()}, {"loop", LoopIndex},
                   {"candidate", P.Candidate.ID},
                   {"plan", P.Candidate.PlanIndex},
                   {"vf", P.Candidate.VF.getKnownMinValue()},
                   {"scalable", P.Candidate.VF.isScalable()},
                   {"ic", P.Candidate.IC}, {"role", "main"},
                   {"queried", P.Queried}, {"pruning_basis", P.PruningBasis},
                   {"tti_width", P.Width}, {"basis_width", P.BasisWidth},
                   {"max_trip_count", Pruning.MaxTripCount},
                   {"scalar_tail", P.Candidate.ScalarTail},
                   {"scalar_quarters_numerator", Pruning.Scalar.numerator()},
                   {"scalar_quarters_denominator", Pruning.Scalar.denominator()},
                   {"basis_quarters_numerator", P.BasisCost.numerator()},
                   {"basis_quarters_denominator", P.BasisCost.denominator()},
                   {"lower_bound_quarters_numerator", P.LowerBound.numerator()},
                   {"lower_bound_quarters_denominator", P.LowerBound.denominator()}};
  if (P.Observation)
    Row["observation"] = summarizeVPlanBackendResult(*P.Observation);
  Rows.push_back(std::move(Row));
}

bool VPlanBackendCostModel::addBatch(ArrayRef<PreparedCandidate *> Wave) {
  SmallVector<VPlanBackendCandidate> Queries;
  for (auto *P : Wave) {
    P->Queried = true;
    Queries.push_back(P->Candidate);
  }
  VPlanFeedbackTimer Timer(vplanBackendFeedbackTimingEnabled());
  auto Results = Feedback.getBatch(F, Header, Queries);
  Timer.mark("query_total");
  std::string BatchFailure;
  if (!Results)
    BatchFailure = toString(Results.takeError());
  // Results are owned and ordered, even if workers completed out of order.
  // Destroy the complete wave before the caller starts another selection attempt.
  for (auto [I, P] : enumerate(Wave)) {
    if (Failed)
      continue;
    std::optional<VPlanBackendProbeResult> Result;
    if (!BatchFailure.empty())
      Result.emplace(createStringError(BatchFailure));
    else
      Result = std::move((*Results)[I]);
    if (prune(*P)) {
      // Retain successful speculative observations without pricing them or
      // promoting them to incumbents. Failure strings need no Error consumer.
      errs() << Result->Diagnostics;
      P->Observation = std::move(Result->Observation);
      reportPruned(*P);
      continue;
    }
    if (applyCost(*P, std::move(Result), Timer))
      P->State = CandidateState::Exact;
    printCostTiming(P->Candidate.ID, Timer);
  }
  return !Failed;
}

bool VPlanBackendCostModel::evaluatePrepared(unsigned Capacity) {
  assert(Capacity && "probe capacity must be positive");
  VPlanFeedbackTimer Timer(false);
  // Every gate cost is available before the first lower-bound proof/query.
  for (auto &P : Candidates)
    if (!P.Query) {
      if (!applyCost(P, std::nullopt, Timer))
        return false;
      P.State = CandidateState::Exact;
    }
  SmallVector<PreparedCandidate *> Order;
  for (auto &P : Candidates)
    if (P.State == CandidateState::Pending)
      Order.push_back(&P);
  llvm::stable_sort(Order, [](const auto *A, const auto *B) {
    return A->Width < B->Width;
  });
  SmallVector<PreparedCandidate *> Wave;
  for (auto *P : Order) {
    if (prune(*P)) {
      reportPruned(*P);
      continue;
    }
    Wave.push_back(P);
    if (Wave.size() == Capacity) {
      if (!addBatch(Wave))
        return false;
      Wave.clear();
    }
  }
  if (!Wave.empty() && !addBatch(Wave))
    return false;
  assert(none_of(Candidates, [](const auto &P) {
    return P.State == CandidateState::Pending;
  }));
  return true;
}

bool VPlanBackendCostModel::applyCost(
    PreparedCandidate &P, std::optional<VPlanBackendProbeResult> Result,
    VPlanFeedbackTimer &Timer) {
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
  std::optional<VPMIRCost> MIRCost;
  if (!Native.isValid() || !Profile.isValid() || !Ev.isValid() ||
      !P.EstimatedSpill.isValid())
    Error = "invalid TTI candidate cost";
  else if (Query) {
    assert(Result && "missing required backend query result");
    errs() << Result->Diagnostics;
    auto O = Result->takeResult();
    if (!O)
      Error = toString(O.takeError());
    else {
      auto Wobs = O->IterationWidth;
      if (O->Candidate != C.ID || O->VF != C.VF || O->IC != C.IC ||
          O->IsEpilogue != C.IsEpilogue)
        Error = "backend observation identity mismatch";
      else if (!Wobs || Wobs % (uint64_t(Width) * C.IC))
        Error = "observed iteration width disagrees with requested IC";
      else if (Mode.MIR) {
        if (!MIRInfo)
          Error = "target has no MIR service model";
        else {
          auto Cost = priceVPlanMIR(*O, *MIRInfo, Width);
          if (!Cost)
            Error = toString(Cost.takeError());
          else
            MIRCost = std::move(*Cost);
        }
      } else {
        auto S = priceVPlanVectorSpills(
            *O, TTI, F.getContext(), Width, Raw,
            Report && Report->isDetailed() ? &AccessCosts : nullptr);
        if (!S)
          Error = toString(S.takeError());
        else
          Spill = *S;
      }
      Timer.mark(Mode.MIR ? "mir_pricing" : "spill_pricing");
      Observation = std::move(*O);
    }
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
        Row["mir_body_quarters_numerator"] = M.Body.numerator();
        Row["mir_body_quarters_denominator"] = M.Body.denominator();
        Row["mir_spill_quarters_numerator"] = M.Spill.numerator();
        Row["mir_spill_quarters_denominator"] = M.Spill.denominator();
        json::Array Ops;
        for (const auto &I : M.Instructions) {
          json::Array Demands;
          for (const auto &D : I.Demands)
            Demands.push_back(json::Object{{"service", D.Service},
                                           {"numerator", D.Numerator},
                                           {"denominator", D.Denominator}});
          Ops.push_back(json::Object{{"rule", I.Rule},
                                     {"unknown", I.Unknown},
                                     {"demands", std::move(Demands)}});
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
  P.Observation = std::move(Observation);
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
      fail("target has no MIR service model");
      return false;
    }
  }
  if (Mode.needsProbe())
    Feedback.beginInvocation();
  const unsigned Capacity = Mode.needsProbe() ? Feedback.batchCapacity(F) : 1;
  if (!Mode.MIR && !Mode.EstimatedSpill && !vplanBackendFeedbackForceAll())
    Pruning = LVP.backendPruningContext();
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
        auto Profile = LVP.backendCandidateCost(
            *Plan, VF, !Mode.DefaultTTI, Ev, &EstimatedSpill);
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
        auto P = prepareCost(*Plan, std::move(C), Native, Profile, Ev,
                             unsigned(Width), EstimatedSpill);
        Preparation.mark("gate");
        printCostTiming(ID, Preparation);
        P.LowerBound = VPExactCost(Profile) - VPExactCost(Ev);
        if (!Mode.MIR && !Mode.EstimatedSpill && !P.LowerBound.isValid()) {
          PreparationError = "invalid or overflowing lower bound";
          return false;
        }
        P.Eligible = LVP.candidateRejection(*Plan, VF).empty();
        Candidates.push_back(std::move(P));
      }
    return true;
  };
  if (!Prepare()) {
    fail(PreparationError);
    return false;
  }
  return evaluatePrepared(Capacity);
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
