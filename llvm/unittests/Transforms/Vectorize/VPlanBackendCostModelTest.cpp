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
json::Object observation() {
  auto V =
      json::parse(R"({"iteration_mapping":true,"iteration_width":64,"error":"",
    "body_order":[0,1,2],"instructions":[
    {"id":0,"role":"body","meta":false,"load":false,"store":true,"vector":true,
     "registers_complete":true,"whole_register":true,
     "operands":[{"group8":16,"physical":true,"subregister":0}],
     "memory":[{"spill_slot":true,"alignment":16,"address_space":0}]},
    {"id":1,"role":"body","meta":false,"vector":false,
     "operands":[{"group8":0}],"memory":[{"spill_slot":true}]},
    {"id":2,"role":"body","meta":false,"vector":true,
     "operands":[{"group8":64}],"memory":[{"spill_slot":false}]},
    {"id":3,"role":"setup","meta":false,"vector":true,
     "operands":[{"group8":64}],"memory":[{"spill_slot":true}]}]})");
  EXPECT_TRUE(bool(V));
  return std::move(*V->getAsObject());
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
  O["iteration_mapping"] = false;
  auto Bad = priceVPlanVectorSpills(O, TTI, C, 1, Raw);
  EXPECT_FALSE(bool(Bad));
  consumeError(Bad.takeError());
  O = observation();
  (*O.getArray("instructions"))[0].getAsObject()->erase("whole_register");
  Bad = priceVPlanVectorSpills(O, TTI, C, 1, Raw);
  EXPECT_FALSE(bool(Bad));
  consumeError(Bad.takeError());
}

TEST(VPlanBackendCost, SplitSegmentSpillsPriceEachAccessNotTheSlot) {
  TargetTransformInfo TTI(std::make_unique<TestTTI>());
  LLVMContext C;
  InstructionCost Raw;
  auto O = observation();
  auto *Instructions = O.getArray("instructions");
  auto *First = (*Instructions)[0].getAsObject();
  auto *Memory = First->getArray("memory")->front().getAsObject();
  (*Memory)["stack_slot"] = 7;
  (*Memory)["bytes"] = 4096; // The slot can describe the entire segment.
  json::Object Second(*First);
  Second["id"] = 4;
  Instructions->push_back(std::move(Second));
  O["body_order"] = json::Array{0, 4};
  auto Cost = priceVPlanVectorSpills(O, TTI, C, 1, Raw);
  ASSERT_TRUE(bool(Cost));
  EXPECT_EQ(Raw, 6); // Two group-2 stores, each costs 2+1.
  EXPECT_EQ(*Cost, VPExactCost::ratio(24, 64));
}
