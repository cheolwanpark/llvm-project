// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "VPlanBackendCostModel.h"
#include "llvm/ADT/APInt.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/Analysis/TargetTransformInfo.h"
#include "llvm/IR/DerivedTypes.h"
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

std::optional<uint64_t> VPExactCost::ceilDivide(VPExactCost B) const {
  if (!Valid || !B.Valid || !B.N)
    return std::nullopt;
  APInt Num = APInt(128, N) * APInt(128, B.D);
  APInt Den = APInt(128, D) * APInt(128, B.N);
  APInt Q, R;
  APInt::udivrem(Num, Den, Q, R);
  if (!R.isZero())
    ++Q;
  if (!Q.isIntN(64))
    return std::nullopt;
  return Q.getZExtValue();
}

Expected<VPMIRCost>
llvm::priceVPlanMIR(const VPlanBackendObservation &O, const TargetMIRInfo &Info,
                    unsigned Width,
                    SmallVectorImpl<VPlanBackendFailure> *Failures) {
  if (!O.succeeded() || !O.IterationMapping ||
      O.Stage != "post-frame-lowering" || O.Loops.empty() || !Width)
    return vplanBackendError(VPlanBackendFailureGroup::Integrity,
                             "invalid MIR body/stage/iteration mapping", "",
                             O.Stage);
  VPMIRCost R;
  R.Model = Info.getModelName().str();
  R.Revision = Info.getRevision().str();
  R.CPU = Info.getCPU().str();
  R.NominalVLEN = Info.getNominalVLEN();
  SmallDenseSet<uint64_t, 8> IDs;
  for (const auto &L : O.Loops) {
    if (!L.ID || !IDs.insert(L.ID).second || !L.MIRBody || !L.IterationWidth ||
        L.IterationWidth > UINT32_MAX)
      return vplanBackendError(VPlanBackendFailureGroup::Integrity,
                               "invalid MIR loop iteration mapping", "",
                               O.Stage);
    auto PriceLoop = [&]() -> Expected<VPMIRLoopCost> {
      VPMIRLoopCost P;
      P.ID = L.ID;
      P.IterationWidth = L.IterationWidth;
      for (const auto &MI : *L.MIRBody) {
        auto Cost = Info.getInstructionCost(MI);
        if (!Cost)
          return Cost.takeError();
        VPExactCost C =
            VPExactCost::ratio(Cost->Numerator, Cost->Denominator) * 4;
        if (!C.isValid())
          return vplanBackendError(VPlanBackendFailureGroup::Pricing,
                                   "invalid MIR direct cost", "", O.Stage);
        P.RawBody = P.RawBody + C;
        if (MI.Spill)
          P.RawSpill = P.RawSpill + C;
        P.Instructions.push_back(std::move(*Cost));
      }
      P.Body = P.RawBody.normalize(Width, L.IterationWidth);
      P.Spill = P.RawSpill.normalize(Width, L.IterationWidth);
      if (!P.Body.isValid() || !P.Spill.isValid())
        return vplanBackendError(VPlanBackendFailureGroup::Pricing,
                                 "MIR loop cost overflow", "", O.Stage);
      return P;
    };
    auto P = PriceLoop();
    if (!P) {
      auto Failure = takeVPlanBackendFailure(
          P.takeError(), VPlanBackendFailureGroup::Pricing, "", O.Stage);
      if (L.TrackingID)
        Failure.TrackingID = L.TrackingID;
      Failure.ObservationID = L.ID;
      if (Failures)
        Failures->push_back(std::move(Failure));
      continue;
    }
    R.Loops.push_back(std::move(*P));
  }
  if (R.Loops.empty())
    return vplanBackendError(VPlanBackendFailureGroup::Pricing,
                             "no-priced-target-loop", "", O.Stage);
  for (auto &P : R.Loops) {
    P.Body = P.Body.normalize(1, R.Loops.size());
    P.Spill = P.Spill.normalize(1, R.Loops.size());
    R.Body = R.Body + P.Body;
    R.Spill = R.Spill + P.Spill;
  }
  if (!R.Body.isValid() || !R.Spill.isValid())
    return vplanBackendError(VPlanBackendFailureGroup::Pricing,
                             "invalid or overflowing MIR direct cost", "",
                             O.Stage);
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
    const VPlanBackendObservation &O, const TargetTransformInfo &TTI,
    LLVMContext &Context, unsigned Width, InstructionCost &RawCost,
    SmallVectorImpl<VPSpillCost> *AccessCosts,
    SmallVectorImpl<VPSpillLoopCost> *LoopCosts,
    SmallVectorImpl<VPlanBackendFailure> *Failures) {
  if (!O.succeeded() || !O.IterationMapping ||
      O.Stage != "post-stack-slot-coloring" || O.Loops.empty() || !Width)
    return vplanBackendError(VPlanBackendFailureGroup::Integrity,
                             "invalid backend loop/iteration mapping", "",
                             O.Stage);
  int64_t TotalRawQuarters = 0;
  bool RawValid = true;
  SmallVector<VPSpillLoopCost> Included;
  SmallVector<VPSpillCost> IncludedAccesses;
  SmallDenseSet<uint64_t, 8> IDs;
  VPExactCost Total;
  for (const auto &L : O.Loops) {
    uint64_t Wobs = L.IterationWidth;
    if (!L.ID || !IDs.insert(L.ID).second || !Wobs || Wobs > UINT32_MAX)
      return vplanBackendError(VPlanBackendFailureGroup::Integrity,
                               "invalid backend iteration width", "", O.Stage);
    SmallVector<VPSpillCost> LoopAccesses;
    auto PriceLoop = [&]() -> Expected<VPSpillLoopCost> {
      SmallVector<VPSpillCost> Prices;
      int64_t RawQuarters = 0;
      for (const auto &A : L.Spills) {
        if (!A.MinBytes || A.MinBytes > UINT32_MAX || !A.Alignment ||
            !isPowerOf2_64(A.Alignment) ||
            A.Alignment > Value::MaximumAlignment || !A.WholeRegister ||
            !isPowerOf2_32(A.RegisterGroup) || A.RegisterGroup > 8)
          return vplanBackendError(VPlanBackendFailureGroup::Integrity,
                                   "unsupported vector spill access", "",
                                   O.Stage);
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
          return vplanBackendError(VPlanBackendFailureGroup::Pricing,
                                   "spill units overflow", "", O.Stage);
        I->Registers += A.RegisterGroup;
        ++I->Accesses;
      }

      for (auto &P : Prices) {
        auto Cost = TTI.getRegisterClassSpillReloadCost(
            P.ClassID, P.IsLoad, {P.Registers, P.Accesses},
            TargetTransformInfo::TCK_RecipThroughput);
        if (!Cost.isValid() || Cost < 0 ||
            AddOverflow(RawQuarters, Cost.getQuarterValue(), RawQuarters))
          return vplanBackendError(VPlanBackendFailureGroup::Pricing,
                                   "invalid or overflowing vector spill cost",
                                   "", O.Stage);
        if (AccessCosts)
          LoopAccesses.push_back(
              {P.ClassID, P.IsLoad, P.Registers, P.Accesses, Cost, L.ID, Wobs});
      }
      auto Raw = InstructionCost(RawQuarters / 4) +
                 InstructionCost(RawQuarters % 4) / 4;
      auto Normalized =
          VPExactCost::ratio(RawQuarters, 1).normalize(Width, Wobs);
      if (!Normalized.isValid())
        return vplanBackendError(VPlanBackendFailureGroup::Pricing,
                                 "spill loop cost overflow", "", O.Stage);
      if (RawValid)
        RawValid =
            !AddOverflow(TotalRawQuarters, RawQuarters, TotalRawQuarters);
      return VPSpillLoopCost{L.ID, Wobs, Raw, Normalized};
    };
    auto P = PriceLoop();
    if (!P) {
      auto Failure = takeVPlanBackendFailure(
          P.takeError(), VPlanBackendFailureGroup::Pricing, "", O.Stage);
      if (L.TrackingID)
        Failure.TrackingID = L.TrackingID;
      Failure.ObservationID = L.ID;
      if (Failures)
        Failures->push_back(std::move(Failure));
      continue;
    }
    Included.push_back(std::move(*P));
    IncludedAccesses.append(LoopAccesses);
  }
  if (Included.empty())
    return vplanBackendError(VPlanBackendFailureGroup::Pricing,
                             "no-priced-target-loop", "", O.Stage);
  for (auto &P : Included) {
    P.Cost = P.Cost.normalize(1, Included.size());
    Total = Total + P.Cost;
  }
  if (!Total.isValid())
    return vplanBackendError(VPlanBackendFailureGroup::Pricing,
                             "vector spill normalization overflow", "",
                             O.Stage);
  RawCost = RawValid ? InstructionCost(TotalRawQuarters / 4) +
                           InstructionCost(TotalRawQuarters % 4) / 4
                     : InstructionCost::getInvalid();
  if (AccessCosts)
    AccessCosts->append(IncludedAccesses);
  if (LoopCosts)
    LoopCosts->append(Included);

  return Total;
}
VPExactCost llvm::composeVPlanMIRCost(const VPMIRCost &Cost,
                                      InstructionCost EstimatedSpill,
                                      bool UseEstimatedSpill) {
  return UseEstimatedSpill
             ? Cost.Body - Cost.Spill + VPExactCost(EstimatedSpill)
             : Cost.Body;
}
