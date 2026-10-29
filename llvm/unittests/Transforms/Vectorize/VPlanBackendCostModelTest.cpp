// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "../lib/Transforms/Vectorize/VPlanBackendCostModel.h"
#include "../lib/Transforms/Vectorize/VPlan.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Instructions.h"
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

namespace {
class FractionMIRInfo : public TargetMIRInfo {
public:
  StringRef getModelName() const override { return "test-mir"; }
  StringRef getRevision() const override { return "test"; }
  Expected<MIRInstructionCost>
  getInstructionCost(const VPlanMIRInstruction &MI) const override {
    if (MI.Opcode == "invalid")
      return createStringError("invalid geometry");
    return MIRInstructionCost{
        "fraction", false, {{"test", MI.Spill ? 5 : 7, 3}}};
  }
};
} // namespace
TEST(VPlanBackendCost, MIRExactNormalizationAndSpillScope) {
  VPlanBackendResult O;
  O.Stage = "post-frame-lowering";
  O.IterationMapping = true;
  O.IterationWidth = 24;
  O.MIRBody.emplace();
  O.MIRBody->push_back({});
  VPlanMIRInstruction ScalarSpill, VectorSpill;
  ScalarSpill.Load = ScalarSpill.Spill = true;
  VectorSpill = ScalarSpill;
  VectorSpill.Vector = true;
  O.MIRBody->push_back(ScalarSpill);
  O.MIRBody->push_back(VectorSpill);
  auto C = priceVPlanMIR(O, FractionMIRInfo(), 4);
  ASSERT_TRUE(bool(C));
  EXPECT_EQ(C->RawBody, VPExactCost::ratio(68, 3));
  EXPECT_EQ(C->RawSpill, VPExactCost::ratio(40, 3));
  EXPECT_EQ(C->Body, VPExactCost::ratio(34, 9));
  EXPECT_EQ(C->Spill, VPExactCost::ratio(20, 9));
  EXPECT_EQ(C->Body - C->Spill + VPExactCost(InstructionCost(2)),
            VPExactCost::ratio(86, 9));
  EXPECT_FALSE(VPExactCost::ratio(INT64_MAX, 1).normalize(2, 1).isValid());
  EXPECT_EQ(VPExactCost::ratio(INT64_MAX, 1).normalize(2, 2),
            VPExactCost::ratio(INT64_MAX, 1));
  for (unsigned Case = 0; Case < 4; ++Case) {
    auto Bad = O;
    if (Case == 0)
      Bad.Stage = "post-stack-slot-coloring";
    if (Case == 1)
      Bad.IterationWidth = 0;
    if (Case == 2)
      Bad.MIRBody->clear();
    if (Case == 3)
      Bad.MIRBody->front().Opcode = "invalid";
    auto R = priceVPlanMIR(Bad, FractionMIRInfo(), 4);
    EXPECT_FALSE(bool(R));
    if (!R)
      consumeError(R.takeError());
  }
}

TEST(VPlanBackendCost, StrictLowerBoundObjectives) {
  auto C = [](int64_t N) { return VPExactCost(InstructionCost(N)); };
  EXPECT_TRUE(vplanStrictlyCheaper(C(4), 1, C(17), 4, C(4), 0, true));
  EXPECT_FALSE(vplanStrictlyCheaper(C(4), 1, C(16), 4, C(4), 0, true));
  EXPECT_TRUE(vplanStrictlyCheaper(VPExactCost::ratio(1, 3), 4,
                                  VPExactCost::ratio(1, 2), 4, C(4), 0, true));
  // Twenty elements: f16 main=32, f4 main=40. f4 must remain available
  // for an epilogue even though it loses the main comparison.
  EXPECT_TRUE(vplanStrictlyCheaper(C(16), 16, C(8), 4, C(4), 20, true));
  EXPECT_FALSE(vplanStrictlyCheaper(C(4), 1, C(8), 4, C(4), 20, true));
  // Scalar tail and folded tail are distinct objectives. No vector iteration
  // executes at TC=3 with a scalar tail: a tie must not be pruned.
  EXPECT_FALSE(vplanStrictlyCheaper(C(4), 1, C(100), 4, C(4), 3, true));
  EXPECT_TRUE(vplanStrictlyCheaper(C(4), 1, C(100), 4, C(4), 3, false));
  EXPECT_FALSE(vplanStrictlyCheaper(C(1), 4, VPExactCost::ratio(INT64_MAX, 1),
                                   8, C(4), 0, true));
  EXPECT_FALSE(vplanStrictlyCheaper(C(1), 0, C(100), 4, C(4), 0, true));
}

TEST(VPlanBackendCost, SharedTripCountBodyAndTailCosts) {
  EXPECT_EQ(vplanCostForTripCount(4, InstructionCost(3), InstructionCost(2), 10,
                                  true),
            InstructionCost(10));
  EXPECT_EQ(vplanCostForTripCount(4, InstructionCost(3), InstructionCost(2), 10,
                                  false),
            InstructionCost(9));
  EXPECT_EQ(vplanCostForTripCount(4, VPExactCost::ratio(1, 2),
                                  VPExactCost(InstructionCost(2)), 10, true),
            VPExactCost::ratio(17, 1));
  EXPECT_FALSE(vplanCostForTripCount(4, VPExactCost::ratio(INT64_MAX, 1),
                                     VPExactCost(InstructionCost(2)), 10, false)
                   .isValid());
}

namespace llvm {
class VPlanBackendCostModelTestAccess {
public:
  using Prepared = VPlanBackendCostModel::PreparedCandidate;
  static Prepared candidate(VPlan &Plan, unsigned VF, InstructionCost Body,
                            bool Query = true, bool Eligible = true) {
    VPlanBackendCandidate C{"vf" + std::to_string(VF),
                            0,
                            ElementCount::getFixed(VF),
                            true,
                            false,
                            false};
    return {&Plan, C, Body, Body, 0, 0, VF, {}, Query, Eligible};
  }
  static bool run(VPlanBackendCostModel &M, ArrayRef<Prepared> Cs,
                  std::optional<VPBackendPruningContext> Context) {
    return M.addBatch(Cs, Context);
  }
};
} // namespace llvm
namespace {
class BackendSchedulerTest : public testing::Test {
protected:
  LLVMContext Context;
  Module M{"scheduler", Context};
  Function *F = Function::Create(FunctionType::get(Type::getVoidTy(Context), false),
                                 GlobalValue::ExternalLinkage, "f", M);
  BasicBlock *Header = [&] {
    auto *BB = BasicBlock::Create(Context, "header", F);
    UncondBrInst::Create(BB, BB);
    return BB;
  }();
  VPlan Plan{Header, Type::getInt32Ty(Context)};
  TargetTransformInfo TTI{std::make_unique<TestTTI>()};
  SmallVector<unsigned> Started;
  unsigned FailVF = 0;
  bool Malformed = false;
  VPlanBackendFeedback Feedback{[&](const Function &, const BasicBlock &,
                                   ArrayRef<VPlanBackendCandidate> Cs)
                                   -> Expected<VPlanBackendFeedback::Batch> {
    VPlanBackendFeedback::Batch Results;
    for (const auto &C : Cs) {
      Started.push_back(C.VF.getKnownMinValue());
      if (C.Control)
        C.Control->Started = true;
      if (C.VF.getKnownMinValue() == FailVF) {
        Results.emplace_back(createStringError("injected required failure"));
      } else {
        VPlanBackendResult O;
        O.Candidate = C.ID;
        O.VF = C.VF;
        O.IC = C.IC;
        O.IsEpilogue = C.IsEpilogue;
        O.IterationMapping = true;
        O.IterationWidth = C.VF.getKnownMinValue();
        Results.emplace_back(std::move(O));
      }
    }
    // Publish high-ranked failures before the low-ranked winner, modeling
    // out-of-order physical completion. Only final dominance resolves errors.
    for (unsigned I = Cs.size(); I; --I)
      if (Cs[I - 1].Control && Cs[I - 1].Control->Completed)
        Cs[I - 1].Control->Completed(Results[I - 1]);
    if (Malformed)
      Results.clear();
    return Results;
  }};
  using Access = VPlanBackendCostModelTestAccess;
};
} // namespace
TEST_F(BackendSchedulerTest, LateGateAndIneligibleGate) {
  for (bool Eligible : {true, false}) {
    Started.clear();
    VPlanBackendCostModel Costs(Feedback, TTI, *F, *Header);
    SmallVector<Access::Prepared, 0> Cs{
        Access::candidate(Plan, 4, 20),
        Access::candidate(Plan, 8, 8, false, Eligible)};
    ASSERT_TRUE(Access::run(Costs, Cs, VPBackendPruningContext{100, 0, true}));
    EXPECT_EQ(Started.empty(), Eligible);
    EXPECT_EQ(Costs.isPruned(Plan, ElementCount::getFixed(4)), Eligible);
    ASSERT_NE(Costs.lookup(Plan, ElementCount::getFixed(8)), nullptr);
  }
}
TEST_F(BackendSchedulerTest, CostOrderTiesAndDeferredDominatedFailure) {
  FailVF = 4;
  VPlanBackendCostModel Costs(Feedback, TTI, *F, *Header);
  SmallVector<Access::Prepared, 0> Cs{Access::candidate(Plan, 4, 20),
                                      Access::candidate(Plan, 8, 4),
                                      Access::candidate(Plan, 2, 1)};
  ASSERT_TRUE(Access::run(Costs, Cs, VPBackendPruningContext{100, 0, true}));
  ASSERT_EQ(Started.size(), 3u);
  EXPECT_EQ(Started[0], 8u);
  EXPECT_EQ(Started[1], 2u);
  EXPECT_TRUE(Costs.isPruned(Plan, ElementCount::getFixed(4)));
  EXPECT_NE(Costs.lookup(Plan, ElementCount::getFixed(8)), nullptr);
  EXPECT_NE(Costs.lookup(Plan, ElementCount::getFixed(2)), nullptr);
}
TEST_F(BackendSchedulerTest, RequiredFailureAndMalformedBatchDiscardCosts) {
  for (bool BadBatch : {false, true}) {
    Malformed = BadBatch;
    FailVF = BadBatch ? 0 : 4;
    VPlanBackendCostModel Costs(Feedback, TTI, *F, *Header);
    SmallVector<Access::Prepared, 0> Cs{Access::candidate(Plan, 2, 2),
                                        Access::candidate(Plan, 4, 20)};
    EXPECT_FALSE(Access::run(Costs, Cs, std::nullopt));
    EXPECT_EQ(Costs.lookup(Plan, ElementCount::getFixed(2)), nullptr);
    EXPECT_TRUE(Costs.failed());
  }
}
TEST_F(BackendSchedulerTest, EstimatedModeNeverCallsProvider) {
  VPlanBackendCostModel Costs(Feedback, TTI, *F, *Header, nullptr,
                              {false, true, false});
  SmallVector<Access::Prepared, 0> Cs{Access::candidate(Plan, 4, 500, false)};
  ASSERT_TRUE(Access::run(Costs, Cs, std::nullopt));
  EXPECT_TRUE(Started.empty());
  ASSERT_NE(Costs.lookup(Plan, ElementCount::getFixed(4)), nullptr);
  EXPECT_EQ(Costs.lookup(Plan, ElementCount::getFixed(4))->Body,
            VPExactCost(InstructionCost(500)));
}
