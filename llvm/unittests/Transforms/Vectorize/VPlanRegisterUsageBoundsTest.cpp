//===- VPlanRegisterUsageBoundsTest.cpp
//------------------------------------===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

#include "../lib/Transforms/Vectorize/VPlanRegisterUsageBounds.h"
#include "VPlanTestBase.h"
#include "llvm/Analysis/TargetTransformInfoImpl.h"
#include <limits>
#include <random>

using namespace llvm;

TEST(VPlanRegisterUsageBounds, LifetimeExamplesAndOverflow) {
  SmallVector<VPRegisterLifetimeCounts> Chain(100, {1, 1});
  Chain.front().GuaranteedKills = 0;
  EXPECT_EQ(boundVPlanLiveValues(0, Chain), 2u);
  EXPECT_EQ(boundVPlanLiveValues(3, Chain), 5u);
  EXPECT_EQ(boundVPlanLiveValues(0, {{2, 0}, {1, 2}}), 3u);
  EXPECT_EQ(boundVPlanLiveValues(0, {}), 0u);
  EXPECT_FALSE(
      boundVPlanLiveValues(std::numeric_limits<uint64_t>::max(), {{1, 0}}));
  VPRegisterUsageBound B;
  EXPECT_TRUE(B.shouldQuery());
  B.Known = true;
  B.Usage = 31;
  EXPECT_FALSE(B.shouldQuery());
  B.Usage = 32;
  EXPECT_TRUE(B.shouldQuery());
}

TEST(VPlanRegisterUsageBounds, ExhaustivePrefixesOfSmallDAGs) {
  // Independent liveness oracle. Vary multi-output recipes, non-data ordering
  // constraints, fan-out and live-outs; enumerate every legal prefix.
  std::mt19937 Random(20261026);
  for (unsigned N = 1; N <= 9; ++N) {
    for (unsigned Trial = 0; Trial < 150; ++Trial) {
      unsigned Persistent = Random() % 4;
      SmallVector<unsigned> Pred(N, 0), Producer, Users;
      SmallVector<bool> LiveOut;
      SmallVector<VPRegisterLifetimeCounts> Counts(N);
      for (unsigned R = 0; R < N; ++R) {
        for (unsigned V = 0; V < Producer.size(); ++V)
          if (Random() % 4 == 0) {
            Users[V] |= 1u << R;
            Pred[R] |= 1u << Producer[V];
          }
        for (unsigned P = 0; P < R; ++P)
          if (Random() % 8 == 0)
            Pred[R] |= 1u << P;
        Counts[R].Definitions = Random() % 4;
        for (unsigned I = 0; I < Counts[R].Definitions; ++I) {
          Producer.push_back(R);
          Users.push_back(0);
          LiveOut.push_back(Random() % 6 == 0);
        }
      }
      for (unsigned V = 0; V < Producer.size(); ++V) {
        LiveOut[V] = LiveOut[V] || !Users[V];
        if (!LiveOut[V] && isPowerOf2_32(Users[V]))
          ++Counts[countr_zero(Users[V])].GuaranteedKills;
      }
      auto Bound = boundVPlanLiveValues(Persistent, Counts);
      ASSERT_TRUE(Bound);
      for (unsigned S = 0; S < (1u << N); ++S) {
        bool Legal = true;
        for (unsigned R = 0; R < N; ++R)
          if ((S & (1u << R)) && (S & Pred[R]) != Pred[R])
            Legal = false;
        if (!Legal)
          continue;
        unsigned Live = Persistent;
        for (unsigned V = 0; V < Producer.size(); ++V)
          if ((S & (1u << Producer[V])) && (LiveOut[V] || (Users[V] & ~S)))
            ++Live;
        ASSERT_LE(Live, *Bound);
        for (unsigned R = 0; R < N; ++R)
          if (!(S & (1u << R)) && (S & Pred[R]) == Pred[R])
            ASSERT_LE(Live + Counts[R].Definitions, *Bound);
      }
    }
  }
}

namespace {
class BoundTTI : public TargetTransformInfoImplCRTPBase<BoundTTI> {
public:
  explicit BoundTTI(const DataLayout &DL)
      : TargetTransformInfoImplCRTPBase(DL) {}
  TypeSize getRegisterBitWidth(TTI::RegisterKind K) const override {
    return K == TTI::RGK_ScalableVector ? TypeSize::getScalable(64)
                                        : TypeSize::getFixed(128);
  }
  bool isElementTypeLegalForScalableVector(Type *T) const override {
    return !T->isIntegerTy(1);
  }
  bool isTypeLegal(Type *) const override { return true; }
  unsigned getNumberOfParts(Type *) const override { return 1; }
  unsigned getRegUsageForType(Type *T) const override {
    auto *VT = cast<VectorType>(T);
    unsigned Bits =
        VT->getScalarSizeInBits() * VT->getElementCount().getKnownMinValue();
    return divideCeil(Bits, VT->isScalableTy() ? 64u : 128u);
  }
};

class BoundsTest : public VPlanTestBase {
protected:
  std::pair<VPlan *, VPBasicBlock *> makePlan() {
    M->setTargetTriple(Triple("riscv64-unknown-elf"));
    auto &P = getPlan();
    auto *B = P.createVPBasicBlock("body");
    auto *R =
        P.createLoopRegion(Type::getInt64Ty(C), DebugLoc(), "vector", B, B);
    VPBlockUtils::connectBlocks(P.getEntry(), R);
    VPBlockUtils::connectBlocks(R, P.getScalarHeader());
    return {&P, B};
  }
  VPRegisterUsageBound analyze(VPlan &P, ElementCount VF) {
    TargetTransformInfo TTI(std::make_unique<BoundTTI>(M->getDataLayout()));
    return computeVPlanRegisterUsageBound(P, VF, TTI);
  }
};
} // namespace

TEST_F(BoundsTest, DuplicateUsesChainAndWidths) {
  auto [P, B] = makePlan();
  auto *X = new VPInstructionWithType(VPInstruction::StepVector, {},
                                      Type::getInt32Ty(C));
  B->appendRecipe(X);
  VPValue *Prev = X;
  for (unsigned I = 0; I < 100; ++I) {
    auto *Next = new VPWidenRecipe(Instruction::Add, {Prev, Prev});
    B->appendRecipe(Next);
    Prev = Next;
  }
  auto Small = analyze(*P, ElementCount::getScalable(1));
  ASSERT_TRUE(Small.Known) << Small.Reason.str();
  EXPECT_EQ(Small.Peak, 2u);
  EXPECT_EQ(Small.MaxRegisterGroup, 1u);
  EXPECT_FALSE(Small.shouldQuery());
  auto Large = analyze(*P, ElementCount::getScalable(16));
  EXPECT_EQ(Large.MaxRegisterGroup, 8u);
  EXPECT_EQ(Large.Usage, 16u);
  auto Fixed = analyze(*P, ElementCount::getFixed(8));
  EXPECT_EQ(Fixed.MaxRegisterGroup, 2u);
}

TEST_F(BoundsTest, MasksAreValuesPlusOneReservation) {
  auto [P, B] = makePlan();
  auto *X = new VPInstructionWithType(VPInstruction::StepVector, {},
                                      Type::getInt32Ty(C));
  B->appendRecipe(X);
  auto *P0 =
      new VPWidenRecipe(Instruction::ICmp, {X, X}, VPIRFlags(CmpInst::ICMP_EQ));
  auto *P1 =
      new VPWidenRecipe(Instruction::ICmp, {X, X}, VPIRFlags(CmpInst::ICMP_NE));
  B->appendRecipe(P0);
  B->appendRecipe(P1);
  B->appendRecipe(new VPWidenRecipe(Instruction::And, {P0, P1}));
  auto R = analyze(*P, ElementCount::getScalable(2));
  ASSERT_TRUE(R.Known) << R.Reason.str();
  EXPECT_TRUE(R.HasMask);
  EXPECT_GE(R.Peak, 3u);
  EXPECT_EQ(R.Usage, (R.Peak + 1) * R.MaxRegisterGroup);
}

TEST_F(BoundsTest, UnsupportedOpcodeDoesNotProduceLowBound) {
  auto [P, B] = makePlan();
  auto *X = new VPInstructionWithType(VPInstruction::StepVector, {},
                                      Type::getInt32Ty(C));
  B->appendRecipe(X);
  B->appendRecipe(new VPInstruction(VPInstruction::Reverse, {X}));
  auto R = analyze(*P, ElementCount::getScalable(1));
  EXPECT_FALSE(R.Known);
  EXPECT_TRUE(R.shouldQuery());
  EXPECT_EQ(R.Recipe, "VPInstruction");
  EXPECT_EQ(R.Opcode, VPInstruction::Reverse);
}

TEST_F(BoundsTest, WideningUsesLargestGroupAndMultiStepCastQueries) {
  auto [P, B] = makePlan();
  auto *X = new VPInstructionWithType(VPInstruction::StepVector, {},
                                      Type::getInt32Ty(C));
  B->appendRecipe(X);
  auto *Wide =
      new VPWidenCastRecipe(Instruction::ZExt, X, Type::getInt64Ty(C), nullptr,
                            VPIRFlags::getDefaultFlags(Instruction::ZExt));
  B->appendRecipe(Wide);
  auto R = analyze(*P, ElementCount::getScalable(4));
  ASSERT_TRUE(R.Known) << R.Reason.str();
  EXPECT_EQ(R.Peak, 2u);
  EXPECT_EQ(R.MaxRegisterGroup, 4u);
  EXPECT_EQ(R.Usage, 8u);
  B->appendRecipe(new VPWidenCastRecipe(
      Instruction::Trunc, Wide, Type::getInt8Ty(C), nullptr,
      VPIRFlags::getDefaultFlags(Instruction::Trunc)));
  R = analyze(*P, ElementCount::getScalable(4));
  EXPECT_FALSE(R.Known);
  EXPECT_EQ(R.Recipe, "VPWidenCast");
}

TEST_F(BoundsTest, LoopCarriedValuesAreNotKilledAtTheirOnlyUser) {
  auto [P, B] = makePlan();
  auto *Start = P->getConstantInt(32, 0);
  auto *Phi = new VPWidenPHIRecipe({Start, Start});
  B->appendRecipe(Phi);
  auto *Next = new VPWidenRecipe(Instruction::Add, {Phi, Phi});
  B->appendRecipe(Next);
  Phi->setOperand(1, Next);
  auto R = analyze(*P, ElementCount::getScalable(2));
  ASSERT_TRUE(R.Known) << R.Reason.str();
  // Initial constant, incoming PHI and outgoing backedge value are all counted.
  EXPECT_EQ(R.Peak, 3u);
  EXPECT_EQ(Phi->getOperand(1), Next);
  EXPECT_EQ(std::distance(B->begin(), B->end()), 2);
}

TEST_F(BoundsTest, ConstantDivisionRequiresBackend) {
  auto [P, B] = makePlan();
  auto *X = new VPInstructionWithType(VPInstruction::StepVector, {},
                                      Type::getInt32Ty(C));
  B->appendRecipe(X);
  B->appendRecipe(
      new VPWidenRecipe(Instruction::UDiv, {X, P->getConstantInt(32, 7)}));
  auto R = analyze(*P, ElementCount::getScalable(2));
  EXPECT_FALSE(R.Known);
  EXPECT_EQ(R.Opcode, Instruction::UDiv);
}
