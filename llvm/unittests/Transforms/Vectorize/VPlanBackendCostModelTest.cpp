// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "../lib/Transforms/Vectorize/VPlanBackendCostModel.h"
#include "../lib/Transforms/Vectorize/VPlanAnalysis.h"
#include "../lib/Transforms/Vectorize/VPlanRegisterUsageBounds.h"
#include "llvm/Analysis/TargetTransformInfoImpl.h"
#include "llvm/Analysis/VPlanCostProfile.h"
#include "llvm/IR/LLVMContext.h"
#include "gtest/gtest.h"
using namespace llvm;

TEST(VPlanBackendCost, ExactFractionsAndOverflow) {
  auto A = VPExactCost::ratio(1, 8), B = VPExactCost::ratio(1, 9);
  EXPECT_TRUE(B < A);
  EXPECT_EQ(A * 8, VPExactCost::ratio(1, 1));
  EXPECT_EQ(A + B, VPExactCost::ratio(17, 72));
  EXPECT_EQ(A - B, VPExactCost::ratio(1, 72));
  EXPECT_FALSE((B - A).isValid());
  EXPECT_EQ(VPExactCost(InstructionCost(1) / 4), VPExactCost::ratio(1, 1));
  EXPECT_EQ(InstructionCost(A).getValue(), 0);
  EXPECT_EQ(InstructionCost(VPExactCost::ratio(7, 1)), InstructionCost(7) / 4);
  EXPECT_FALSE((VPExactCost::ratio(INT64_MAX, 1) * 2).isValid());
  EXPECT_FALSE((VPExactCost::ratio(INT64_MAX, 1) + A).isValid());
  EXPECT_FALSE(VPExactCost::ratio(1, 0).isValid());
  EXPECT_TRUE(VPExactCost::ratio(INT64_MAX, 2) <
              VPExactCost::ratio(INT64_MAX, 1));
}
TEST(VPlanBackendCost, ScopeRestoration) {
  EXPECT_FALSE(VPlanCostProfileScope::active());
  {
    VPlanCostProfileScope S(true);
    EXPECT_TRUE(VPlanCostProfileScope::active());
    {
      VPlanCostProfileScope Probe(false);
      EXPECT_FALSE(VPlanCostProfileScope::active());
    }
    EXPECT_TRUE(VPlanCostProfileScope::active());
  }
  EXPECT_FALSE(VPlanCostProfileScope::active());
}
TEST(VPlanBackendCost, InterleaveGateBoundaries) {
  for (auto [Usage, IC, Query] :
       {std::tuple{15u, 2u, false}, std::tuple{16u, 2u, true},
        std::tuple{9u, 4u, true}}) {
    VPRegisterUsageBound B;
    B.Known = true;
    B.Usage = Usage;
    B.applyInterleave(IC);
    EXPECT_EQ(B.UsageBeforeIC, Usage);
    EXPECT_EQ(B.Usage, Usage * IC);
    EXPECT_EQ(B.shouldQuery(), Query);
  }
  VPRegisterUsageBound B;
  B.Known = true;
  B.Usage = UINT64_MAX;
  B.applyInterleave(2);
  EXPECT_FALSE(B.Known);
  EXPECT_TRUE(B.shouldQuery());
}
namespace {
class TestTTI final : public TargetTransformInfoImplBase {
  inline static const DataLayout Layout{""};

public:
  TestTTI() : TargetTransformInfoImplBase(Layout) {}
  unsigned getRegisterClassForType(bool Vector, Type *) const override {
    return Vector;
  }
  unsigned getNumberOfRegisters(unsigned) const override { return 2; }
  InstructionCost getRegisterClassSpillCost(
      unsigned C, TargetTransformInfo::TargetCostKind) const override {
    return C ? 3 : 7;
  }
  InstructionCost getRegisterClassReloadCost(
      unsigned C, TargetTransformInfo::TargetCostKind) const override {
    return C ? 5 : 11;
  }
  InstructionCost
  getSpillReloadCost(const TargetTransformInfo::SpillReloadAccess &A,
                     TargetTransformInfo::TargetCostKind) const override {
    EXPECT_TRUE(VPlanCostProfileScope::active());
    EXPECT_EQ(A.AccessType->getPrimitiveSizeInBits().getKnownMinValue(),
              A.RegisterGroup * 64);
    return A.RegisterGroup + 1;
  }
};
VPlanBackendResult observation() {
  VPlanBackendResult R;
  R.Candidate = "owned:candidate";
  R.IterationMapping = true;
  R.IterationWidth = 64;
  R.Spills.push_back({false, 16, true, 16, 0, true, 2, false});
  return R;
}
} // namespace
TEST(VPlanBackendCost, PreserveScalarEstimatedSpills) {
  TargetTransformInfo TTI(std::make_unique<TestTTI>());
  VPRegisterUsage RU;
  RU.MaxLocalUsers[0] = 3;
  RU.MaxLocalUsers[1] = 4;
  InstructionCost Vector;
  auto Total = RU.spillCost(TTI, TargetTransformInfo::TCK_RecipThroughput, 0,
                            nullptr, &Vector);
  EXPECT_EQ(Vector, 16);
  EXPECT_EQ(Total, 34);
  EXPECT_EQ(VPExactCost(Total) - VPExactCost(Vector) +
                VPExactCost(InstructionCost(3)),
            VPExactCost(InstructionCost(21)));
  RU.spillCost(TTI, TargetTransformInfo::TCK_RecipThroughput, 4, nullptr,
               &Vector);
  EXPECT_EQ(Vector, 0);
}
TEST(VPlanBackendCost, PriceOnlyActualBodyVectorSpills) {
  TargetTransformInfo TTI(std::make_unique<TestTTI>());
  LLVMContext C;
  InstructionCost Raw;
  auto O = observation();
  auto Cost = priceVPlanVectorSpills(O, TTI, C, 1, Raw);
  ASSERT_TRUE(bool(Cost));
  EXPECT_EQ(Raw, 3);
  EXPECT_EQ(*Cost, VPExactCost::ratio(12, 64));
  EXPECT_FALSE(VPlanCostProfileScope::active());
  O.IterationMapping = false;
  auto Bad = priceVPlanVectorSpills(O, TTI, C, 1, Raw);
  EXPECT_FALSE(bool(Bad));
  consumeError(Bad.takeError());
  O = observation();
  O.Spills[0].WholeRegister = false;
  Bad = priceVPlanVectorSpills(O, TTI, C, 1, Raw);
  EXPECT_FALSE(bool(Bad));
  consumeError(Bad.takeError());
}

TEST(VPlanBackendCost, SplitSegmentSpillsPriceEachAccessNotTheSlot) {
  TargetTransformInfo TTI(std::make_unique<TestTTI>());
  LLVMContext C;
  InstructionCost Raw;
  auto O = observation();
  O.Spills[0].FromSegment = true;
  O.Spills.push_back(O.Spills[0]);
  auto Cost = priceVPlanVectorSpills(O, TTI, C, 1, Raw);
  ASSERT_TRUE(bool(Cost));
  EXPECT_EQ(Raw, 6); // Two group-2 stores, each costs 2+1.
  EXPECT_EQ(*Cost, VPExactCost::ratio(24, 64));
}

TEST(VPlanBackendCost, ValidateSpillFactsAndEmptyMapping) {
  TargetTransformInfo TTI(std::make_unique<TestTTI>());
  LLVMContext C;
  InstructionCost Raw;
  auto O = observation();
  O.Spills.clear();
  auto Zero = priceVPlanVectorSpills(O, TTI, C, 1, Raw);
  ASSERT_TRUE(bool(Zero));
  EXPECT_EQ(*Zero, VPExactCost());
  for (unsigned Mode = 0; Mode != 7; ++Mode) {
    O = observation();
    switch (Mode) {
    case 0:
      O.IterationWidth = 0;
      break;
    case 1:
      O.IterationMapping = false;
      break;
    case 2:
      O.Stage = "post-frame-lowering";
      break;
    case 3:
      O.Spills[0].Alignment = 3;
      break;
    case 4:
      O.Spills[0].RegisterGroup = 3;
      break;
    case 5:
      O.Spills[0].MinBytes = 0;
      break;
    case 6:
      O.Spills[0].WholeRegister = false;
      break;
    }
    auto Bad = priceVPlanVectorSpills(O, TTI, C, 1, Raw);
    EXPECT_FALSE(bool(Bad));
    consumeError(Bad.takeError());
  }
}

TEST(VPlanBackendCost, ExactReportUnitsAndLargeDenominators) {
  auto Text = [](VPExactCost C, unsigned Divisor = 1) {
    std::string S;
    raw_string_ostream OS(S);
    C.print(OS, Divisor);
    return S;
  };
  EXPECT_EQ(Text(VPExactCost::ratio(1, 3)), "1/12");
  EXPECT_EQ(Text(VPExactCost::ratio(7, 3), 2), "7/24");
  EXPECT_EQ(Text(VPExactCost::ratio(24, 1), 3), "2");
  EXPECT_EQ(Text(VPExactCost::ratio(0, 1)), "0");
  EXPECT_EQ(Text(VPExactCost::ratio(1, INT64_MAX)), "1/36893488147419103228");
  EXPECT_EQ(Text(VPExactCost::ratio(1, 0)), "Invalid");
}
