//===- VPlanReductionFissionAnalysisTest.cpp - Fission analysis tests -----===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "../lib/Transforms/Vectorize/VPlan.h"
#include "../lib/Transforms/Vectorize/VPlanReductionFission.h"
#include "VPlanTestBase.h"
#include "llvm/Analysis/TargetTransformInfoImpl.h"
#include "llvm/IR/Constants.h"
#include "gtest/gtest.h"

namespace llvm {
namespace {

using VPlanReductionFissionAnalysisTest = VPlanTestBase;

class RegisterPressureTTI final : public TargetTransformInfoImplBase {
public:
  explicit RegisterPressureTTI(const DataLayout &DL)
      : TargetTransformInfoImplBase(DL) {}

  unsigned getNumberOfRegisters(unsigned ClassID) const override {
    return ClassID == 1 ? 4 : 8;
  }

  unsigned getRegisterClassForType(bool Vector,
                                   Type *Ty = nullptr) const override {
    if (!Vector)
      return 0;
    return Ty && Ty->isIntegerTy(64) ? 2 : 1;
  }

  unsigned getRegUsageForType(Type *Ty) const override {
    auto *VectorTy = dyn_cast<VectorType>(Ty);
    return VectorTy && VectorTy->getElementType()->isIntegerTy(64) ? 2 : 1;
  }

  bool isElementTypeLegalForScalableVector(Type *Ty) const override {
    return Ty->isIntegerTy(32) || Ty->isIntegerTy(64);
  }
};

TEST_F(VPlanReductionFissionAnalysisTest, DependencyMetricsForChain) {
  VPlan &Plan = getPlan();
  VPBasicBlock *VPBB = Plan.getEntry();
  Type *I32Ty = Type::getInt32Ty(C);
  VPValue *LiveIn = Plan.getOrAddLiveIn(ConstantInt::get(I32Ty, 1));

  auto *First = new VPInstruction(Instruction::Add, {LiveIn, LiveIn},
                                  VPIRFlags::getDefaultFlags(Instruction::Add));
  auto *Second =
      new VPInstruction(Instruction::Mul, {First, LiveIn},
                        VPIRFlags::getDefaultFlags(Instruction::Mul));
  auto *Root = new VPInstruction(Instruction::Sub, {Second, LiveIn},
                                 VPIRFlags::getDefaultFlags(Instruction::Sub));
  VPBB->appendRecipe(First);
  VPBB->appendRecipe(Second);
  VPBB->appendRecipe(Root);

  VPDependencyMetrics Metrics = calculateVPDependencyMetrics(*Root);
  EXPECT_EQ(Metrics.RecipeCount, 3u);
  EXPECT_EQ(Metrics.CriticalPathDepth, 3u);
  EXPECT_EQ(Metrics.MaxLevelWidth, 1u);
  EXPECT_EQ(Metrics.IndependentRootCount, 1u);
  EXPECT_EQ(Metrics.RecurrenceCount, 0u);
}

TEST_F(VPlanReductionFissionAnalysisTest,
       DependencyMetricsForParallelBranchesAndRecurrence) {
  VPlan &Plan = getPlan();
  VPBasicBlock *VPBB = Plan.getEntry();
  Type *I32Ty = Type::getInt32Ty(C);
  VPValue *LiveIn = Plan.getOrAddLiveIn(ConstantInt::get(I32Ty, 1));

  auto *Phi = new VPReductionPHIRecipe(nullptr, RecurKind::Add, *LiveIn,
                                       *LiveIn, RdxUnordered{1}, {});
  auto *Left = new VPInstruction(Instruction::Add, {LiveIn, LiveIn},
                                 VPIRFlags::getDefaultFlags(Instruction::Add));
  auto *Right = new VPInstruction(Instruction::Sub, {LiveIn, LiveIn},
                                  VPIRFlags::getDefaultFlags(Instruction::Sub));
  auto *Join = new VPInstruction(Instruction::Mul, {Left, Right},
                                 VPIRFlags::getDefaultFlags(Instruction::Mul));
  auto *Root = new VPInstruction(Instruction::Add, {Join, Phi},
                                 VPIRFlags::getDefaultFlags(Instruction::Add));
  Phi->setOperand(1, Root);

  VPBB->appendRecipe(Phi);
  VPBB->appendRecipe(Left);
  VPBB->appendRecipe(Right);
  VPBB->appendRecipe(Join);
  VPBB->appendRecipe(Root);

  VPDependencyMetrics Metrics = calculateVPDependencyMetrics(*Root);
  EXPECT_EQ(Metrics.RecipeCount, 4u);
  EXPECT_EQ(Metrics.CriticalPathDepth, 3u);
  EXPECT_EQ(Metrics.MaxLevelWidth, 2u);
  EXPECT_EQ(Metrics.IndependentRootCount, 2u);
  EXPECT_EQ(Metrics.RecurrenceCount, 1u);
}

TEST_F(VPlanReductionFissionAnalysisTest,
       RegisterPressureAttributesAccumulatorOverflow) {
  VPlan &Plan = getPlan();
  VPBasicBlock *Preheader = Plan.getEntry();
  VPBasicBlock *Body = Plan.createVPBasicBlock("vector.body");
  auto *Region =
      Plan.createLoopRegion(Plan.getIndexType(), {}, "vector loop", Body, Body);

  VPBlockUtils::connectBlocks(Preheader, Region);
  VPBlockUtils::connectBlocks(Region, Plan.getScalarHeader());

  Type *I32Ty = Type::getInt32Ty(C);
  VPValue *Zero = Plan.getOrAddLiveIn(ConstantInt::get(I32Ty, 0));
  auto *Accumulator0 = new VPReductionPHIRecipe(nullptr, RecurKind::Add, *Zero,
                                                *Zero, RdxUnordered{1}, {});
  auto *Accumulator1 = new VPReductionPHIRecipe(nullptr, RecurKind::Add, *Zero,
                                                *Zero, RdxUnordered{1}, {});
  Body->appendRecipe(Accumulator0);
  Body->appendRecipe(Accumulator1);

  auto *Producer0 =
      new VPInstruction(Instruction::Add, {Zero, Zero},
                        VPIRFlags::getDefaultFlags(Instruction::Add));
  auto *Producer1 =
      new VPInstruction(Instruction::Sub, {Zero, Zero},
                        VPIRFlags::getDefaultFlags(Instruction::Sub));
  auto *Producer2 =
      new VPInstruction(Instruction::Mul, {Zero, Zero},
                        VPIRFlags::getDefaultFlags(Instruction::Mul));
  auto *Sink = new VPWidenIntrinsicRecipe(
      Intrinsic::fshl, {Producer0, Producer1, Producer2}, Type::getInt32Ty(C));
  Body->appendRecipe(Producer0);
  Body->appendRecipe(Producer1);
  Body->appendRecipe(Producer2);
  Body->appendRecipe(Sink);
  Accumulator0->setOperand(1, Sink);
  Accumulator1->setOperand(1, Sink);

  SmallPtrSet<const VPReductionPHIRecipe *, 2> Accumulators = {Accumulator0,
                                                               Accumulator1};
  VPRegisterPressureOptions Options;
  Options.LoopLiveAccumulators = &Accumulators;

  DataLayout DL("");
  TargetTransformInfo TTI(std::make_unique<RegisterPressureTTI>(DL));
  VPRegisterPressureBreakdown Breakdown = calculateRegisterPressureForPlan(
      Plan, ElementCount::getFixed(4), TTI, Options);

  constexpr unsigned VectorRC = 1;
  EXPECT_EQ(Breakdown.AccumulatorRegs.lookup(VectorRC), 2u);
  EXPECT_EQ(Breakdown.LoopInvariantRegs.lookup(VectorRC), 1u);
  EXPECT_EQ(Breakdown.PeakNonAccumulatorRegs.lookup(VectorRC), 4u);
  EXPECT_EQ(Breakdown.PeakTotalRegs.lookup(VectorRC), 6u);
  EXPECT_EQ(Breakdown.Capacity.lookup(VectorRC), 4u);
  EXPECT_EQ(Breakdown.AccumulatorOverlapSurplus.lookup(VectorRC), 2u);
  EXPECT_TRUE(Breakdown.exceedsCapacity());
  EXPECT_TRUE(Breakdown.hasAccumulatorCausedOverflow());

  // Without an explicit set, reductions are discovered automatically.
  Options.LoopLiveAccumulators = nullptr;
  Breakdown = calculateRegisterPressureForPlan(Plan, ElementCount::getFixed(4),
                                               TTI, Options);
  EXPECT_EQ(Breakdown.AccumulatorRegs.lookup(VectorRC), 2u);
  EXPECT_TRUE(Breakdown.hasAccumulatorCausedOverflow());

  // A producer-only stage can explicitly suppress reduction liveness.
  Options.TreatReductionsAsLoopLive = false;
  Breakdown = calculateRegisterPressureForPlan(Plan, ElementCount::getFixed(4),
                                               TTI, Options);
  EXPECT_EQ(Breakdown.AccumulatorRegs.lookup(VectorRC), 0u);
  EXPECT_EQ(Breakdown.PeakTotalRegs.lookup(VectorRC), 4u);
  EXPECT_FALSE(Breakdown.exceedsCapacity());
  EXPECT_FALSE(Breakdown.hasAccumulatorCausedOverflow());
}

TEST_F(VPlanReductionFissionAnalysisTest,
       RegisterPressureIncludesWidenedLoadResults) {
  VPlan &Plan = getPlan();
  VPBasicBlock *Body = Plan.createVPBasicBlock("vector.body");
  auto *Region =
      Plan.createLoopRegion(Plan.getIndexType(), {}, "vector loop", Body, Body);

  VPBlockUtils::connectBlocks(Plan.getEntry(), Region);
  VPBlockUtils::connectBlocks(Region, Plan.getScalarHeader());
  Type *I32 = Type::getInt32Ty(C);
  auto *Ptr = PoisonValue::get(PointerType::getUnqual(C));
  auto *IRLoad = new LoadInst(I32, Ptr, "input", false, Align(4),
                              ScalarHeader->getTerminator()->getIterator());
  auto *Load = new VPWidenLoadRecipe(*IRLoad, Plan.getOrAddLiveIn(Ptr), nullptr,
                                     true, VPIRMetadata(), DebugLoc());
  Body->appendRecipe(Load);
  auto *Use = new VPInstruction(Instruction::Add, {Load, Load},
                                VPIRFlags::getDefaultFlags(Instruction::Add));
  Body->appendRecipe(Use);
  DataLayout DL("");
  TargetTransformInfo TTI(std::make_unique<RegisterPressureTTI>(DL));
  auto Pressure =
      calculateRegisterPressureForPlan(Plan, ElementCount::getFixed(4), TTI);
  // Even a single load result with no loop-live accumulator consumes a
  // register.
  EXPECT_GE(Pressure.PeakNonAccumulatorRegs.lookup(1), 1u);
}

TEST_F(VPlanReductionFissionAnalysisTest,
       RegisterPressureIncludesOverlappingAccumulatorUpdate) {
  VPlan &Plan = getPlan();
  VPBasicBlock *Body = Plan.createVPBasicBlock("vector.body");
  auto *Region =
      Plan.createLoopRegion(Plan.getIndexType(), {}, "vector loop", Body, Body);

  VPBlockUtils::connectBlocks(Plan.getEntry(), Region);
  VPBlockUtils::connectBlocks(Region, Plan.getScalarHeader());
  VPValue *Zero = Plan.getOrAddLiveIn(ConstantInt::get(Type::getInt32Ty(C), 0));
  VPValue *Mask = Plan.getOrAddLiveIn(ConstantInt::getTrue(C));
  auto *Phi = new VPReductionPHIRecipe(nullptr, RecurKind::Add, *Zero, *Zero,
                                       RdxUnordered{1}, {});
  auto *Update =
      new VPInstruction(Instruction::Add, {Phi, Zero},
                        VPIRFlags::getDefaultFlags(Instruction::Add));
  auto *Select =
      new VPInstruction(Instruction::Select, {Mask, Update, Phi},
                        VPIRFlags::getDefaultFlags(Instruction::Select));
  Phi->setOperand(1, Update);
  Body->appendRecipe(Phi);
  Body->appendRecipe(Update);
  Body->appendRecipe(Select);
  DataLayout DL("");
  TargetTransformInfo TTI(std::make_unique<RegisterPressureTTI>(DL));
  auto Before =
      calculateRegisterPressureForPlan(Plan, ElementCount::getFixed(4), TTI);
  // A tail select needs both the old accumulator and the updated value. The
  // backedge update cannot simply be charged to the loop-live register.
  Select->eraseFromParent();
  auto After =
      calculateRegisterPressureForPlan(Plan, ElementCount::getFixed(4), TTI);
  EXPECT_GT(Before.PeakTotalRegs.lookup(1), After.PeakTotalRegs.lookup(1));
}

TEST_F(VPlanReductionFissionAnalysisTest,
       RegisterPressureKeepsLiveOutUntilLoopExit) {
  VPlan &Plan = getPlan();
  VPBasicBlock *Body = Plan.createVPBasicBlock("vector.body");
  auto *Region =
      Plan.createLoopRegion(Plan.getIndexType(), {}, "vector loop", Body, Body);
  VPBasicBlock *Middle = Plan.createVPBasicBlock("middle.block");

  VPBlockUtils::connectBlocks(Plan.getEntry(), Region);
  VPBlockUtils::connectBlocks(Region, Middle);
  VPBlockUtils::connectBlocks(Middle, Plan.getScalarHeader());
  VPValue *Zero = Plan.getOrAddLiveIn(ConstantInt::get(Type::getInt32Ty(C), 0));
  auto *LiveOut =
      new VPInstruction(Instruction::Add, {Zero, Zero},
                        VPIRFlags::getDefaultFlags(Instruction::Add));
  auto *Late = new VPInstruction(Instruction::Sub, {Zero, Zero},
                                 VPIRFlags::getDefaultFlags(Instruction::Sub));
  Body->appendRecipe(LiveOut);
  Body->appendRecipe(Late);
  auto *Product =
      new VPInstruction(Instruction::Mul, {Late, Late},
                        VPIRFlags::getDefaultFlags(Instruction::Mul));
  Body->appendRecipe(Product);
  VPValue *Base =
      Plan.getOrAddLiveIn(PoisonValue::get(PointerType::getUnqual(C)));
  VPValue *Mask = Plan.getOrAddLiveIn(ConstantInt::getTrue(C));
  Body->appendRecipe(new VPFissionScratchStoreRecipe(
      0, Type::getInt32Ty(C), Align(4), Base, Zero, Product, Mask));
  auto *OutsideUse = new VPFissionScratchStoreRecipe(
      1, Type::getInt32Ty(C), Align(4), Base, Zero, LiveOut, Mask);
  Middle->appendRecipe(OutsideUse);
  DataLayout DL("");
  TargetTransformInfo TTI(std::make_unique<RegisterPressureTTI>(DL));
  auto Before =
      calculateRegisterPressureForPlan(Plan, ElementCount::getFixed(4), TTI);
  OutsideUse->eraseFromParent();
  auto After =
      calculateRegisterPressureForPlan(Plan, ElementCount::getFixed(4), TTI);
  EXPECT_GT(Before.PeakTotalRegs.lookup(1), After.PeakTotalRegs.lookup(1));
}

TEST_F(VPlanReductionFissionAnalysisTest,
       RegisterPressureIncludesPreheaderVectorValues) {
  VPlan &Plan = getPlan();
  VPValue *Zero = Plan.getOrAddLiveIn(ConstantInt::get(Type::getInt32Ty(C), 0));
  VPValue *Base =
      Plan.getOrAddLiveIn(PoisonValue::get(PointerType::getUnqual(C)));
  VPValue *Mask = Plan.getOrAddLiveIn(ConstantInt::getTrue(C));
  auto *Invariant =
      new VPInstruction(Instruction::Add, {Zero, Zero},
                        VPIRFlags::getDefaultFlags(Instruction::Add));
  Plan.getEntry()->appendRecipe(Invariant);
  VPBasicBlock *Body = Plan.createVPBasicBlock("vector.body");
  auto *Region =
      Plan.createLoopRegion(Plan.getIndexType(), {}, "vector loop", Body, Body);

  VPBlockUtils::connectBlocks(Plan.getEntry(), Region);
  VPBlockUtils::connectBlocks(Region, Plan.getScalarHeader());
  Body->appendRecipe(new VPFissionScratchStoreRecipe(
      0, Type::getInt32Ty(C), Align(4), Base, Zero, Invariant, Mask));
  DataLayout DL("");
  TargetTransformInfo TTI(std::make_unique<RegisterPressureTTI>(DL));
  auto Pressure =
      calculateRegisterPressureForPlan(Plan, ElementCount::getFixed(4), TTI);
  // One preheader vector plus the live-in mask, even with no body definitions.
  EXPECT_EQ(Pressure.LoopInvariantRegs.lookup(1), 2u);
  EXPECT_EQ(Pressure.PeakTotalRegs.lookup(1), 2u);
}

TEST_F(VPlanReductionFissionAnalysisTest,
       RegisterPressureDoesNotWidenScalarCanonicalIV) {
  VPlan &Plan = getPlan();
  VPBasicBlock *Body = Plan.createVPBasicBlock("vector.body");
  auto *Region =
      Plan.createLoopRegion(Plan.getIndexType(), {}, "vector loop", Body, Body);

  VPBlockUtils::connectBlocks(Plan.getEntry(), Region);
  VPBlockUtils::connectBlocks(Region, Plan.getScalarHeader());
  VPValue *Zero = Plan.getOrAddLiveIn(ConstantInt::get(Type::getInt64Ty(C), 0));
  auto *IV = Region->getCanonicalIV();
  auto *WideIV = new VPWidenCanonicalIVRecipe(IV);
  auto *Mask = new VPInstruction(
      VPInstruction::ActiveLaneMask, {WideIV, Zero, &Plan.getVF()},
      VPIRFlags::getDefaultFlags(VPInstruction::ActiveLaneMask));

  Body->appendRecipe(WideIV);
  Body->appendRecipe(Mask);
  DataLayout DL("");
  TargetTransformInfo TTI(std::make_unique<RegisterPressureTTI>(DL));
  auto Pressure = calculateRegisterPressureForPlan(
      Plan, ElementCount::getScalable(16), TTI);
  // WideIV is demanded only in lane zero by the mask; its scalar input does
  // not become a vector simply because the user is a widening recipe.
  EXPECT_EQ(Pressure.PeakTotalRegs.lookup(2), 0u);
}

TEST_F(VPlanReductionFissionAnalysisTest,
       RegisterPressureAccountsForScalableRegisterGroups) {
  VPlan &Plan = getPlan();
  VPBasicBlock *Body = Plan.createVPBasicBlock("vector.body");
  auto *Region =
      Plan.createLoopRegion(Plan.getIndexType(), {}, "vector loop", Body, Body);

  VPBlockUtils::connectBlocks(Plan.getEntry(), Region);
  VPBlockUtils::connectBlocks(Region, Plan.getScalarHeader());

  VPValue *I32Zero =
      Plan.getOrAddLiveIn(ConstantInt::get(Type::getInt32Ty(C), 0));
  VPValue *I64Zero =
      Plan.getOrAddLiveIn(ConstantInt::get(Type::getInt64Ty(C), 0));
  auto *I32Accumulator = new VPReductionPHIRecipe(
      nullptr, RecurKind::Add, *I32Zero, *I32Zero, RdxUnordered{1}, {});
  auto *I64Accumulator = new VPReductionPHIRecipe(
      nullptr, RecurKind::Add, *I64Zero, *I64Zero, RdxUnordered{1}, {});
  Body->appendRecipe(I32Accumulator);
  Body->appendRecipe(I64Accumulator);

  SmallPtrSet<const VPReductionPHIRecipe *, 2> Accumulators = {I32Accumulator,
                                                               I64Accumulator};
  VPRegisterPressureOptions Options;
  Options.LoopLiveAccumulators = &Accumulators;

  DataLayout DL("");
  TargetTransformInfo TTI(std::make_unique<RegisterPressureTTI>(DL));
  VPRegisterPressureBreakdown Breakdown = calculateRegisterPressureForPlan(
      Plan, ElementCount::getScalable(4), TTI, Options);

  EXPECT_EQ(Breakdown.AccumulatorRegs.lookup(1), 1u);
  EXPECT_EQ(Breakdown.AccumulatorRegs.lookup(2), 2u);
  EXPECT_EQ(Breakdown.LoopInvariantRegs.lookup(1), 1u);
  EXPECT_EQ(Breakdown.LoopInvariantRegs.lookup(2), 2u);
  EXPECT_EQ(Breakdown.PeakTotalRegs.lookup(1), 2u);
  EXPECT_EQ(Breakdown.PeakTotalRegs.lookup(2), 4u);
  EXPECT_EQ(Breakdown.Capacity.lookup(1), 4u);
  EXPECT_EQ(Breakdown.Capacity.lookup(2), 8u);
}

} // namespace
} // namespace llvm
