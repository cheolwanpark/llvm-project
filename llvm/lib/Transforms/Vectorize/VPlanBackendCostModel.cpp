// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "VPlanBackendCostModel.h"
#include "LoopVectorizationPlanner.h"
#include "VPlan.h"
#include "VPlanRegisterUsageBounds.h"
#include "llvm/ADT/APInt.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/Analysis/VPlanCostProfile.h"
#include "llvm/Analysis/VectorUtils.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/Module.h"
#include <numeric>
using namespace llvm;
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

Expected<VPExactCost> llvm::priceVPlanVectorSpills(
    const json::Object &O, const TargetTransformInfo &TTI, LLVMContext &Context,
    unsigned Width, InstructionCost &RawCost) {
  if (O.getBoolean("iteration_mapping") != true || !O.getString("error") ||
      !O.getString("error")->empty())
    return createStringError("invalid backend loop/iteration mapping");
  auto Wobs = O.getInteger("iteration_width");
  auto *Order = O.getArray("body_order");
  auto *Instructions = O.getArray("instructions");
  if (!Wobs || *Wobs <= 0 || !Width || *Wobs % Width || !Order ||
      Order->empty() || !Instructions)
    return createStringError("invalid backend body or iteration width");
  int64_t RawQuarters = 0;
  SmallDenseSet<int64_t> Seen;
  for (const auto &ID : *Order) {
    auto Index = ID.getAsInteger();
    if (!Index || *Index < 0 || uint64_t(*Index) >= Instructions->size() ||
        !Seen.insert(*Index).second)
      return createStringError("invalid backend body order");
    auto *I = (*Instructions)[*Index].getAsObject();
    if (!I || I->getInteger("id") != Index || I->getString("role") != "body")
      return createStringError("backend body identity mismatch");
    if (I->getBoolean("meta") == true)
      continue;
    auto *Memory = I->getArray("memory");
    if (!Memory)
      return createStringError("missing memory facts");
    bool Spill = any_of(*Memory, [](const json::Value &V) {
      auto *M = V.getAsObject();
      return M && M->getBoolean("spill_slot") == true;
    });
    if (!Spill)
      continue;
    auto *Operands = I->getArray("operands");
    if (!Operands)
      return createStringError("missing spill register facts");
    unsigned Group = 0;
    for (auto &V : *Operands) {
      auto *R = V.getAsObject();
      if (!R)
        return createStringError("invalid spill register");
      auto G = R->getInteger("group8");
      if (!G || !*G)
        continue;
      if (*G < 8 || *G > 64 || *G % 8 || R->getBoolean("physical") != true ||
          R->getInteger("subregister") != 0)
        return createStringError("unsupported spill register group");
      Group = std::max(Group, unsigned(*G / 8));
    }
    if (!Group) {
      if (I->getBoolean("vector") == true)
        return createStringError("vector spill without physical group");
      continue; // Scalar spills retain the middle-end estimate.
    }
    if (I->getBoolean("registers_complete") != true || Memory->size() != 1)
      return createStringError("incomplete vector spill access");
    auto *M = Memory->front().getAsObject();
    auto Load = I->getBoolean("load"), Store = I->getBoolean("store");
    auto Alignment = M->getInteger("alignment");
    auto AS = M->getInteger("address_space");
    auto Whole = I->getBoolean("whole_register");
    if (!Load || !Store || *Load == *Store || !Alignment || *Alignment <= 0 ||
        !isPowerOf2_64(*Alignment) || !AS || *AS < 0 || !Whole || !*Whole ||
        !isPowerOf2_32(Group))
      return createStringError("unsupported vector spill access");
    // A scalable RVV register has 64 minimum bits in LLVM's type model.
    // Use the actual instruction group, never the size of the stack slot.
    Type *Ty = ScalableVectorType::get(Type::getInt8Ty(Context), Group * 8);
    TargetTransformInfo::SpillReloadAccess Access{
        *Load, Ty, Align(*Alignment), unsigned(*AS), true, Group};
    VPlanCostProfileScope Scope(true);
    auto Cost = TTI.getSpillReloadCost(
        Access, TargetTransformInfo::TCK_RecipThroughput);
    if (!Cost.isValid() || Cost < 0 ||
        AddOverflow(RawQuarters, Cost.getQuarterValue(), RawQuarters))
      return createStringError("invalid or overflowing vector spill cost");
  }
  RawCost =
      InstructionCost(RawQuarters / 4) + InstructionCost(RawQuarters % 4) / 4;
  int64_t Numerator;
  if (MulOverflow(RawQuarters, int64_t(Width), Numerator))
    return createStringError("vector spill normalization overflow");
  return VPExactCost::ratio(Numerator, *Wobs);
}
void VPlanBackendCostModel::fail(StringRef Reason) {
  if (Failed)
    return;
  Failed = true;
  Failure = Reason.str();
  Costs.clear();
  printVPlanBackendFeedback(json::Object{{"model", "tti-real-vector-spill-v1"},
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
bool VPlanBackendCostModel::add(VPlan &Plan, VPlanBackendCandidate C,
                                InstructionCost Native, InstructionCost Profile,
                                InstructionCost Ev, unsigned Width) {
  if (Failed)
    return false;
  auto Bound = computeVPlanRegisterUsageBound(Plan, C.VF, TTI);
  Bound.applyInterleave(C.IC);
  bool Query = Bound.shouldQuery() || vplanBackendFeedbackForceAll();
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
  VPExactCost Spill;
  InstructionCost Raw;
  std::string Error;
  if (!Native.isValid() || !Profile.isValid() || !Ev.isValid())
    Error = "invalid TTI candidate cost";
  else if (Query) {
    auto O = Feedback.get(F, Header, C);
    if (!O) {
      Error = toString(O.takeError());
      Row["status"] = "unavailable";
      Row["reason"] = Error;
    } else {
      auto Wobs = O->getInteger("iteration_width");
      if (!Wobs || *Wobs <= 0 || uint64_t(*Wobs) % (uint64_t(Width) * C.IC))
        Error = "observed iteration width disagrees with requested IC";
      else {
        auto S = priceVPlanVectorSpills(*O, TTI, F.getContext(), Width, Raw);
        if (!S)
          Error = toString(S.takeError());
        else
          Spill = *S;
      }
      Row["observation"] = std::move(*O);
      Row["status"] = "collected";
    }
  } else {
    Row["status"] = "skipped";
    Row["reason"] = Bound.Reason;
  }
  VPExactCost Body = VPExactCost(Profile) - VPExactCost(Ev) + Spill;
  if (!Body.isValid() && Error.empty())
    Error = "invalid or overflowing hybrid cost";
  if (Error.empty()) {
    Costs.push_back(
        {&Plan, C.VF, C.IC, C.IsEpilogue, Native, Profile, Ev, Body});
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
  printVPlanBackendFeedback(Row);
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
  for (auto [PlanIndex, Plan] : enumerate(LVP.getPlans()))
    for (ElementCount VF : Plan->vectorFactors()) {
      if (VF.isScalar())
        continue;
      InstructionCost Ev;
      auto Native = LVP.backendCandidateCost(*Plan, VF, false, Ev);
      if (!Native.isValid()) {
        fail("invalid native candidate cost");
        return false;
      }
      unsigned IC = LVP.selectInterleaveCount(*Plan, VF, Native);
      if (UserIC)
        IC = UserIC;
      IC = LVP.limitBackendIC(*Plan, IC);
      uint64_t Width =
          uint64_t(VF.getKnownMinValue()) *
          (VF.isScalable() ? Config.getVScaleForTuning().value_or(1) : 1);
      if (!IC || !Width || Width > UINT32_MAX / IC) {
        fail("candidate iteration width overflow");
        return false;
      }
      auto Profile = LVP.backendCandidateCost(*Plan, VF, true, Ev);
      if (!Profile.isValid() || !Ev.isValid()) {
        fail("invalid profile candidate cost");
        return false;
      }
      std::string ID =
          (F.getName() + ":" + Twine(Invocation) + ":" + Twine(LoopIndex) +
           ":" + Twine(PlanIndex) + ":" + (VF.isScalable() ? "s" : "f") +
           Twine(VF.getKnownMinValue()) + ":ic" + Twine(IC) + ":main")
              .str();
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
      if (!add(*Plan, C, Native, Profile, Ev,
               (VF.getKnownMinValue() *
                (VF.isScalable() ? Config.getVScaleForTuning().value_or(1)
                                 : 1))))
        return false;
    }
  return true;
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
  printVPlanBackendFeedback(
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
