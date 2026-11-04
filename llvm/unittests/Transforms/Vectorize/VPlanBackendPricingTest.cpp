// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "../lib/Transforms/Vectorize/VPlanBackendCostModel.h"
#include "../lib/Transforms/Vectorize/VPlanAnalysis.h"
#include "llvm/Analysis/TargetTransformInfoImpl.h"
#include "llvm/IR/LLVMContext.h"
#include "gtest/gtest.h"
using namespace llvm;

namespace {
// Nonlinear group prices expose accidental aggregation across physical groups;
// different directions/classes expose accidental reuse of a store/vector price.
class ClassPrices : public TargetTransformInfoImplBase {
  inline static const DataLayout DL{""};
public:
  ClassPrices() : TargetTransformInfoImplBase(DL) {}
  unsigned getRegisterClassForType(bool Vector, Type *) const override {
    return Vector;
  }
  unsigned getNumberOfRegisters(unsigned) const override { return 2; }
  InstructionCost getRegisterClassSpillReloadCost(
      unsigned Class, bool Load, TargetTransformInfo::SpillReloadUnits U,
      TargetTransformInfo::TargetCostKind) const override {
    if (!U.Accesses)
      return 0;
    EXPECT_EQ(U.Registers % U.Accesses, 0u);
    return int64_t(U.Accesses * (Class ? (U.Registers == U.Accesses ? 3 : 8)
                                            : 11) * (Load ? 2 : 1));
  }
};
class FractionPrices : public TargetMIRInfo {
public:
  StringRef getModelName() const override { return "fraction"; }
  StringRef getRevision() const override { return "test"; }
  Expected<MIRInstructionCost>
  getInstructionCost(const VPlanMIRInstruction &I) const override {
    if (I.Opcode == "invalid")
      return createStringError("invalid geometry");
    return MIRInstructionCost{"body", I.Opcode == "unknown", I.Spill ? 5 : 7, 3};
  }
};
}

TEST(VPlanBackendPricing, SpillClassesDirectionsAndPhysicalGroups) {
  TargetTransformInfo TTI(std::make_unique<ClassPrices>());
  LLVMContext C;
  VPRegisterUsage Usage;
  Usage.MaxLocalUsers[0] = 3;
  Usage.MaxLocalUsers[1] = 4;
  InstructionCost Vector;
  EXPECT_EQ(Usage.spillCost(TTI, TargetTransformInfo::TCK_RecipThroughput, 0,
                            nullptr, &Vector), 51);
  EXPECT_EQ(Vector, 18);
  VPlanBackendObservation O;
  O.Status = VPlanBackendObservationStatus::Succeeded;
  O.IterationMapping = true;
  O.IterationWidth = 24;
  // Two split-segment stores plus a group-4 reload, not the stack slot size.
  O.Spills = {{false, 8, true, 8, 0, true, 1, true},
              {false, 8, true, 8, 0, true, 1, true},
              {true, 32, true, 8, 0, true, 4, false}};
  InstructionCost Raw;
  auto Price = priceVPlanVectorSpills(O, TTI, C, 4, Raw);
  ASSERT_TRUE(bool(Price)) << toString(Price.takeError());
  EXPECT_EQ(Raw, 22);
  EXPECT_EQ(*Price, VPExactCost::ratio(44, 3));
  O.Spills.back().RegisterGroup = 3;
  auto Invalid = priceVPlanVectorSpills(O, TTI, C, 4, Raw);
  EXPECT_FALSE(bool(Invalid));
  consumeError(Invalid.takeError());
}

TEST(VPlanBackendPricing, ZeroRequiresAnObservedMappedBody) {
  TargetTransformInfo TTI(std::make_unique<ClassPrices>());
  LLVMContext C;
  for (auto Status : {VPlanBackendObservationStatus::Succeeded,
                      VPlanBackendObservationStatus::Failed,
                      VPlanBackendObservationStatus::NotCollected,
                      VPlanBackendObservationStatus::NotRequested}) {
    VPlanBackendObservation O;
    O.Status = Status;
    O.IterationMapping = true;
    O.IterationWidth = 8;
    InstructionCost Raw;
    auto Cost = priceVPlanVectorSpills(O, TTI, C, 4, Raw);
    EXPECT_EQ(bool(Cost), O.succeeded());
    if (Cost)
      EXPECT_EQ(*Cost, VPExactCost());
    else
      consumeError(Cost.takeError());
  }
}

TEST(VPlanBackendPricing, MIRNormalizesScalarAndVectorSpillSlotsOnce) {
  VPlanBackendObservation O;
  O.Status = VPlanBackendObservationStatus::Succeeded;
  O.Stage = "post-frame-lowering";
  O.IterationMapping = true;
  O.IterationWidth = 24;
  O.MIRBody.emplace(3);
  (*O.MIRBody)[0].Opcode = "unknown";
  (*O.MIRBody)[0].Load = true; // Ordinary stack load contributes to R, not S.
  (*O.MIRBody)[1].Spill = true;
  (*O.MIRBody)[2].Spill = (*O.MIRBody)[2].Vector = true;
  for (unsigned Width : {1u, 4u}) {
    auto Price = priceVPlanMIR(O, FractionPrices(), Width);
    ASSERT_TRUE(bool(Price)) << toString(Price.takeError());
    EXPECT_EQ(Price->Body, VPExactCost::ratio(17 * Width, 18));
    EXPECT_EQ(Price->Spill, VPExactCost::ratio(5 * Width, 9));
    EXPECT_TRUE(Price->Instructions.front().Unknown);
    EXPECT_EQ(composeVPlanMIRCost(*Price, 2, false), Price->Body);
    EXPECT_EQ(composeVPlanMIRCost(*Price, 2, true),
              VPExactCost::ratio(7 * Width, 18) + VPExactCost(InstructionCost(2)));
  }
  O.MIRBody->front().Opcode = "invalid";
  auto Invalid = priceVPlanMIR(O, FractionPrices(), 1);
  EXPECT_FALSE(bool(Invalid));
  consumeError(Invalid.takeError());
}

TEST(VPlanBackendPricing, FractionalTailRankingAndCheckedArithmetic) {
  auto Scalar = VPExactCost::ratio(1, 3);
  auto Vector = VPExactCost::ratio(1, 2);
  EXPECT_EQ(vplanCostForTripCount(4, Vector, Scalar, 11, true),
            VPExactCost::ratio(2, 1));
  EXPECT_EQ(vplanCostForTripCount(4, Vector, Scalar, 11, false),
            VPExactCost::ratio(3, 2));
  EXPECT_TRUE(vplanStrictlyCheaper(Vector, 4, Scalar, 1, Scalar, 11, true));
  EXPECT_FALSE(vplanStrictlyCheaper(Vector, 4, Vector, 4, Scalar, 11, true));
  EXPECT_EQ(Scalar.ceilDivide(VPExactCost::ratio(1, 4)), 2u);
  auto Huge = VPExactCost::ratio(INT64_MAX, 1);
  EXPECT_FALSE((Huge + Scalar).isValid());
  EXPECT_FALSE(Huge.normalize(2, 1).isValid());
  EXPECT_EQ(Huge.normalize(2, 2), Huge);
  EXPECT_FALSE((Scalar - Vector).isValid());
  EXPECT_FALSE(VPExactCost::ratio(1, 0).isValid());
  EXPECT_FALSE(vplanStrictlyCheaper(Vector, 4, Huge, 8, Scalar, 0, true));
  EXPECT_FALSE(vplanCostForTripCount(4, Huge, Scalar, 11, false).isValid());
}
