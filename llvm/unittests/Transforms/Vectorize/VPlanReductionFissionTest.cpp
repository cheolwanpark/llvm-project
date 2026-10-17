//===- VPlanReductionFissionTest.cpp - Reduction fission tests ------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "../lib/Transforms/Vectorize/VPlanReductionFission.h"
#include "../lib/Transforms/Vectorize/VPlan.h"
#include "../lib/Transforms/Vectorize/VPlanVerifier.h"
#include "VPlanTestBase.h"
#include "llvm/IR/Constants.h"
#include "gtest/gtest.h"

namespace llvm {
namespace {

using VPlanReductionFissionTest = VPlanTestBase;

TEST_F(VPlanReductionFissionTest, DuplicateMapsSymbolicAndRegionValues) {
  VPlan &Plan = getPlan();
  auto *Body = Plan.createVPBasicBlock("body");
  auto *Region =
      Plan.createLoopRegion(Plan.getIndexType(), {}, "loop", Body, Body);
  auto *Mask = Region->createHeaderMask();
  VPBlockUtils::connectBlocks(Plan.getEntry(), Region);
  VPBlockUtils::connectBlocks(Region, Plan.getScalarHeader());
  auto *Increment = new VPInstruction(
      Instruction::Add, {Region->getCanonicalIV(), &Plan.getVFxUF()},
      VPIRFlags::getDefaultFlags(Instruction::Add));
  Body->appendRecipe(Increment);
  Body->appendRecipe(new VPInstruction(
      VPInstruction::BranchOnCount, {Increment, &Plan.getVectorTripCount()}));
  auto *BTC = Plan.getOrCreateBackedgeTakenCount();
  DenseMap<VPValue *, VPValue *> Values;
  std::unique_ptr<VPlan> Copy(Plan.duplicate(&Values));
  EXPECT_EQ(Values.lookup(Region->getCanonicalIV()),
            Copy->getVectorLoopRegion()->getCanonicalIV());
  EXPECT_EQ(Values.lookup(Mask), Copy->getVectorLoopRegion()->getHeaderMask());
  EXPECT_EQ(Values.lookup(&Plan.getVF()), &Copy->getVF());
  EXPECT_EQ(Values.lookup(&Plan.getUF()), &Copy->getUF());
  EXPECT_EQ(Values.lookup(&Plan.getVFxUF()), &Copy->getVFxUF());
  EXPECT_EQ(Values.lookup(&Plan.getVectorTripCount()),
            &Copy->getVectorTripCount());
  EXPECT_EQ(Values.lookup(BTC), Copy->getBackedgeTakenCount());
  auto *ClonedIncrement = cast<VPInstruction>(Values.lookup(Increment));
  EXPECT_EQ(ClonedIncrement->getOperand(0),
            Copy->getVectorLoopRegion()->getCanonicalIV());
  EXPECT_EQ(ClonedIncrement->getOperand(1), &Copy->getVFxUF());
  EXPECT_EQ(Increment->getOperand(0), Region->getCanonicalIV());
  EXPECT_EQ(Increment->getOperand(1), &Plan.getVFxUF());
}

TEST_F(VPlanReductionFissionTest, AnalysisClassifiesLongAndShortProducers) {
  VPlan &Plan = getPlan();
  VPBasicBlock *Body = Plan.getEntry();
  VPValue *Zero = Plan.getOrAddLiveIn(ConstantInt::get(Type::getInt32Ty(C), 0));

  auto BuildChain = [&](unsigned Depth) -> VPValue * {
    VPValue *Value = Zero;
    for (unsigned I = 0; I != Depth; ++I) {
      auto *Next =
          new VPInstruction(Instruction::Add, {Value, Zero},
                            VPIRFlags::getDefaultFlags(Instruction::Add));
      Body->appendRecipe(Next);
      Value = Next;
    }
    return Value;
  };
  VPValue *Long0 = BuildChain(8);
  VPValue *Long1 = BuildChain(8);
  VPValue *Short = BuildChain(1);

  SmallVector<VPReductionPHIRecipe *, 6> Accumulators;
  SmallVector<VPReductionRecipe *, 6> Updates;
  for (unsigned I = 0; I != 6; ++I) {
    auto *Phi = new VPReductionPHIRecipe(nullptr, RecurKind::Add, *Zero, *Zero,
                                         RdxUnordered{1}, {});
    VPValue *Contribution = I < 3 ? Long0 : (I < 5 ? Long1 : Short);
    auto *Update = new VPReductionRecipe(RecurKind::Add, FastMathFlags(), Phi,
                                         Contribution, nullptr, RdxInLoop{});
    Phi->setOperand(1, Update);
    Body->appendRecipe(Phi);
    Body->appendRecipe(Update);
    Accumulators.push_back(Phi);
    Updates.push_back(Update);
  }

  VPRegisterPressureBreakdown Pressure;
  Pressure.AccumulatorOverlapSurplus[1] = 1;
  VPReductionFissionConfig Config;
  Config.MinimumReductionCount = 5;
  Config.MinimumLongProducerDepth = 8;
  VPReductionFissionAnalysis Analysis =
      analyzeVPReductionFission(Plan, Pressure, Config);

  ASSERT_TRUE(Analysis.isCandidate());
  EXPECT_EQ(Analysis.Slices.size(), 6u);
  for (VPReductionPHIRecipe *Accumulator : Accumulators)
    EXPECT_TRUE(Analysis.Partition.AccumulatorRecipes.contains(Accumulator));
  for (VPReductionRecipe *Update : Updates)
    EXPECT_TRUE(Analysis.Partition.AccumulatorRecipes.contains(Update));
  EXPECT_TRUE(
      Analysis.Partition.ProducerRecipes.contains(Long0->getDefiningRecipe()));
  EXPECT_TRUE(
      Analysis.Partition.ProducerRecipes.contains(Long1->getDefiningRecipe()));
  EXPECT_FALSE(
      Analysis.Partition.ProducerRecipes.contains(Short->getDefiningRecipe()));
  EXPECT_TRUE(Analysis.Partition.AccumulatorRecipes.contains(
      Short->getDefiningRecipe()));
  EXPECT_EQ(Analysis.Partition.FrontierValues.size(), 2u);
  EXPECT_TRUE(is_contained(Analysis.Partition.FrontierValues, Long0));
  EXPECT_TRUE(is_contained(Analysis.Partition.FrontierValues, Long1));

  VPRegisterPressureBreakdown NoOverflow;
  Analysis = analyzeVPReductionFission(Plan, NoOverflow, Config);
  ASSERT_TRUE(Analysis.RejectReason.has_value());
  EXPECT_EQ(*Analysis.RejectReason,
            VPReductionFissionRejectReason::NoAccumulatorPressureOverflow);

  Config.MinimumReductionCount = 7;
  Analysis = analyzeVPReductionFission(Plan, Pressure, Config);
  ASSERT_TRUE(Analysis.RejectReason.has_value());
  EXPECT_EQ(*Analysis.RejectReason,
            VPReductionFissionRejectReason::TooFewReductions);

  Config.MinimumReductionCount = 5;
  Config.MinimumLongProducerDepth = 9;
  Analysis = analyzeVPReductionFission(Plan, Pressure, Config);
  ASSERT_TRUE(Analysis.RejectReason.has_value());
  EXPECT_EQ(*Analysis.RejectReason,
            VPReductionFissionRejectReason::NoLongProducer);
}

TEST_F(VPlanReductionFissionTest,
       AnalysisAcceptsOrdinaryWidenedReductionUpdate) {
  VPlan &Plan = getPlan();
  VPValue *Zero = Plan.getOrAddLiveIn(ConstantInt::get(Type::getInt32Ty(C), 0));
  auto *Producer0 =
      new VPInstruction(Instruction::Mul, {Zero, Zero},
                        VPIRFlags::getDefaultFlags(Instruction::Mul));
  auto *Producer1 =
      new VPInstruction(Instruction::Add, {Producer0, Zero},
                        VPIRFlags::getDefaultFlags(Instruction::Add));
  auto *Phi = new VPReductionPHIRecipe(nullptr, RecurKind::Add, *Zero, *Zero,
                                       RdxUnordered{1}, {});
  auto *Update =
      new VPInstruction(Instruction::Add, {Phi, Producer1},
                        VPIRFlags::getDefaultFlags(Instruction::Add));
  Phi->setOperand(1, Update);
  Plan.getEntry()->appendRecipe(Phi);
  Plan.getEntry()->appendRecipe(Producer0);
  Plan.getEntry()->appendRecipe(Producer1);
  Plan.getEntry()->appendRecipe(Update);

  VPRegisterPressureBreakdown Pressure;
  Pressure.AccumulatorOverlapSurplus[1] = 1;
  VPReductionFissionConfig Config;
  Config.MinimumReductionCount = 1;
  Config.MinimumLongProducerDepth = 2;
  VPReductionFissionAnalysis Analysis =
      analyzeVPReductionFission(Plan, Pressure, Config);

  ASSERT_TRUE(Analysis.isCandidate());
  ASSERT_EQ(Analysis.Slices.size(), 1u);
  ASSERT_EQ(Analysis.Slices[0].Inputs.size(), 1u);
  EXPECT_EQ(Analysis.Slices[0].Inputs[0].Value, Producer1);
  EXPECT_TRUE(Analysis.Slices[0].Updates.contains(Update));
}

TEST_F(VPlanReductionFissionTest, AnalysisRejectsCoupledAccumulatorGraphs) {
  VPlan &Plan = getPlan();
  auto *Body = Plan.getEntry();
  auto *Zero = Plan.getOrAddLiveIn(ConstantInt::get(Type::getInt32Ty(C), 0));
  auto *Phi0 = new VPReductionPHIRecipe(nullptr, RecurKind::Add, *Zero, *Zero,
                                        RdxUnordered{1}, {});
  auto *Phi1 = new VPReductionPHIRecipe(nullptr, RecurKind::Add, *Zero, *Zero,
                                        RdxUnordered{1}, {});
  auto *Long0 = new VPInstruction(Instruction::Mul, {Zero, Zero},
                                  VPIRFlags::getDefaultFlags(Instruction::Mul));
  auto *Long1 = new VPInstruction(Instruction::Add, {Long0, Zero},
                                  VPIRFlags::getDefaultFlags(Instruction::Add));
  auto *Update0 =
      new VPInstruction(Instruction::Add, {Phi0, Long1},
                        VPIRFlags::getDefaultFlags(Instruction::Add));
  auto *Coupled =
      new VPInstruction(Instruction::Add, {Update0, Phi1},
                        VPIRFlags::getDefaultFlags(Instruction::Add));
  auto *Update1 =
      new VPInstruction(Instruction::Add, {Phi1, Long1},
                        VPIRFlags::getDefaultFlags(Instruction::Add));
  Phi0->setOperand(1, Coupled);
  Phi1->setOperand(1, Update1);
  for (VPRecipeBase *R : SmallVector<VPRecipeBase *, 8>{
           Phi0, Phi1, Long0, Long1, Update0, Coupled, Update1})
    Body->appendRecipe(R);
  VPRegisterPressureBreakdown Pressure;
  Pressure.AccumulatorOverlapSurplus[1] = 1;
  VPReductionFissionConfig Config;
  Config.MinimumReductionCount = 2;
  Config.MinimumLongProducerDepth = 2;
  auto A = analyzeVPReductionFission(Plan, Pressure, Config);
  ASSERT_TRUE(A.RejectReason);
  EXPECT_EQ(*A.RejectReason,
            VPReductionFissionRejectReason::CrossPartitionDependence);
  EXPECT_EQ(Phi0->getBackedgeValue(), Coupled);
  EXPECT_EQ(Coupled->getOperand(1), Phi1);
}

TEST_F(VPlanReductionFissionTest, PreviewDuplicateReturnsValueMapping) {
  VPlan &Plan = getPlan();
  VPValue *Zero = Plan.getOrAddLiveIn(ConstantInt::get(Type::getInt32Ty(C), 0));
  auto *Producer =
      new VPInstruction(Instruction::Add, {Zero, Zero},
                        VPIRFlags::getDefaultFlags(Instruction::Add));
  Plan.getEntry()->appendRecipe(Producer);

  DenseMap<VPValue *, VPValue *> DuplicateMap;
  std::unique_ptr<VPlan> Duplicate(Plan.duplicate(&DuplicateMap));
  ASSERT_TRUE(DuplicateMap.contains(Producer));
  EXPECT_NE(DuplicateMap.lookup(Producer), Producer);
  EXPECT_TRUE(isa<VPInstruction>(DuplicateMap.lookup(Producer)));
}

TEST_F(VPlanReductionFissionTest, MultiUpdateKeepsShortInputsAndUpdateOrder) {
  VPlan &Plan = getPlan();
  auto *Body = Plan.getEntry();
  auto *Zero = Plan.getOrAddLiveIn(ConstantInt::get(Type::getInt32Ty(C), 0));
  auto *Phi = new VPReductionPHIRecipe(nullptr, RecurKind::Add, *Zero, *Zero,
                                       RdxUnordered{1}, {});
  auto *Long0 = new VPInstruction(Instruction::Mul, {Zero, Zero},
                                  VPIRFlags::getDefaultFlags(Instruction::Mul));
  auto *Long1 = new VPInstruction(Instruction::Add, {Long0, Zero},
                                  VPIRFlags::getDefaultFlags(Instruction::Add));
  auto *Short = new VPInstruction(Instruction::Sub, {Zero, Zero},
                                  VPIRFlags::getDefaultFlags(Instruction::Sub));
  auto *First = new VPInstruction(Instruction::Add, {Phi, Long1},
                                  VPIRFlags::getDefaultFlags(Instruction::Add));
  auto *Last = new VPInstruction(Instruction::Add, {First, Short},
                                 VPIRFlags::getDefaultFlags(Instruction::Add));
  Phi->setOperand(1, Last);
  for (VPRecipeBase *R :
       SmallVector<VPRecipeBase *>{Phi, Long0, Long1, Short, First, Last})
    Body->appendRecipe(R);
  VPRegisterPressureBreakdown Pressure;
  Pressure.AccumulatorOverlapSurplus[1] = 1;
  auto A = analyzeVPReductionFission(Plan, Pressure, {1, 2});
  ASSERT_TRUE(A.isCandidate());
  EXPECT_EQ(A.Slices.size(), 1u);
  EXPECT_EQ(A.Partition.FrontierValues, (SmallVector<VPValue *, 4>{Long1}));
  for (auto *R : {First, Last, Short}) {
    EXPECT_TRUE(A.Partition.AccumulatorRecipes.contains(R));
    EXPECT_FALSE(A.Partition.ProducerRecipes.contains(R));
  }
  // Analysis must neither reassociate nor mutate the baseline recurrence.
  EXPECT_EQ(Phi->getBackedgeValue(), Last);
  EXPECT_EQ(Last->getOperand(0), First);
  EXPECT_EQ(First->getOperand(0), Phi);
}

TEST_F(VPlanReductionFissionTest, FusedUpdateAndDependentSelectStayTogether) {
  VPlan &Plan = getPlan();
  auto *Body = Plan.getEntry();
  auto *Zero = Plan.getOrAddLiveIn(ConstantFP::get(Type::getDoubleTy(C), 0));
  auto *Phi = new VPReductionPHIRecipe(nullptr, RecurKind::FAdd, *Zero, *Zero,
                                       RdxUnordered{1}, {});
  auto *Long0 =
      new VPInstruction(Instruction::FMul, {Zero, Zero},
                        VPIRFlags::getDefaultFlags(Instruction::FMul));
  auto *Long1 =
      new VPInstruction(Instruction::FAdd, {Long0, Zero},
                        VPIRFlags::getDefaultFlags(Instruction::FAdd));
  auto *FMA = new VPWidenIntrinsicRecipe(Intrinsic::fma, {Long1, Zero, Phi},
                                         Type::getDoubleTy(C));
  auto *Cond = new VPInstruction(Instruction::FCmp, {Phi, Zero},
                                 VPIRFlags(CmpInst::FCMP_OLT, FastMathFlags()));
  auto *Select =
      new VPInstruction(Instruction::Select, {Cond, FMA, Phi},
                        VPIRFlags::getDefaultFlags(Instruction::Select));
  Phi->setOperand(1, Select);
  for (VPRecipeBase *R :
       SmallVector<VPRecipeBase *>{Phi, Long0, Long1, FMA, Cond, Select})
    Body->appendRecipe(R);
  VPRegisterPressureBreakdown Pressure;
  Pressure.AccumulatorOverlapSurplus[1] = 1;
  auto A = analyzeVPReductionFission(Plan, Pressure, {1, 2});
  ASSERT_TRUE(A.isCandidate());
  EXPECT_EQ(A.Partition.FrontierValues, (SmallVector<VPValue *, 4>{Long1}));
  for (VPRecipeBase *R : SmallVector<VPRecipeBase *>{FMA, Cond, Select}) {
    EXPECT_TRUE(A.Partition.AccumulatorRecipes.contains(R));
    EXPECT_FALSE(A.Partition.ProducerRecipes.contains(R));
  }
  EXPECT_EQ(FMA->getOperand(2), Phi);
  EXPECT_EQ(Phi->getBackedgeValue(), Select);
}

TEST_F(VPlanReductionFissionTest, NonAddRecurrenceUsesSamePartitionAnalysis) {
  VPlan &Plan = getPlan();
  auto *Zero = Plan.getOrAddLiveIn(ConstantInt::get(Type::getInt32Ty(C), 0));
  auto *Phi = new VPReductionPHIRecipe(nullptr, RecurKind::Xor, *Zero, *Zero,
                                       RdxUnordered{1}, {});
  auto *Long0 = new VPInstruction(Instruction::Mul, {Zero, Zero},
                                  VPIRFlags::getDefaultFlags(Instruction::Mul));
  auto *Long1 = new VPInstruction(Instruction::Add, {Long0, Zero},
                                  VPIRFlags::getDefaultFlags(Instruction::Add));
  auto *Update =
      new VPInstruction(Instruction::Xor, {Phi, Long1},
                        VPIRFlags::getDefaultFlags(Instruction::Xor));
  Phi->setOperand(1, Update);
  for (VPRecipeBase *R : SmallVector<VPRecipeBase *>{Phi, Long0, Long1, Update})
    Plan.getEntry()->appendRecipe(R);
  VPRegisterPressureBreakdown Pressure;
  Pressure.AccumulatorOverlapSurplus[1] = 1;
  auto A = analyzeVPReductionFission(Plan, Pressure, {1, 2});
  ASSERT_TRUE(A.isCandidate());
  EXPECT_EQ(A.Partition.FrontierValues, (SmallVector<VPValue *, 4>{Long1}));
  EXPECT_TRUE(A.Partition.AccumulatorRecipes.contains(Update));
}

TEST_F(VPlanReductionFissionTest, PreviewBuildsAtomicPrunedPlans) {
  VPlan &Plan = getPlan();
  Plan.resetTripCount(Plan.getConstantInt(64, 16));
  auto *Body = Plan.createVPBasicBlock("body");
  auto *Region =
      Plan.createLoopRegion(Plan.getIndexType(), {}, "loop", Body, Body);
  auto *Middle = Plan.createVPBasicBlock("middle");
  VPBlockUtils::connectBlocks(Plan.getEntry(), Region);
  VPBlockUtils::connectBlocks(Region, Middle);
  VPBlockUtils::connectBlocks(Middle, Plan.getScalarHeader());
  VPValue *Zero = Plan.getOrAddLiveIn(ConstantInt::get(Type::getInt32Ty(C), 0));
  auto *Long0 = new VPInstruction(Instruction::Add, {Zero, Zero},
                                  VPIRFlags::getDefaultFlags(Instruction::Add));
  auto *Long1 = new VPInstruction(Instruction::Mul, {Long0, Zero},
                                  VPIRFlags::getDefaultFlags(Instruction::Mul));
  auto *Short = new VPInstruction(Instruction::Sub, {Zero, Zero},
                                  VPIRFlags::getDefaultFlags(Instruction::Sub));
  auto *Accumulator =
      new VPInstruction(Instruction::Add, {Long1, Short},
                        VPIRFlags::getDefaultFlags(Instruction::Add));
  Body->appendRecipe(Long0);
  Body->appendRecipe(Long1);
  Body->appendRecipe(Short);
  Body->appendRecipe(Accumulator);
  auto *Increment = new VPInstruction(
      Instruction::Add, {Region->getCanonicalIV(), &Plan.getVFxUF()},
      VPIRFlags::getDefaultFlags(Instruction::Add));
  Body->appendRecipe(Increment);
  Body->appendRecipe(new VPInstruction(
      VPInstruction::BranchOnCount, {Increment, &Plan.getVectorTripCount()}));

  VPReductionFissionAnalysis Analysis;
  auto &Partition = Analysis.Partition;
  Partition.ProducerRecipes.insert(Long0);
  Partition.ProducerRecipes.insert(Long1);
  Partition.AccumulatorRecipes.insert(Short);
  Partition.AccumulatorRecipes.insert(Accumulator);
  Partition.FrontierValues.push_back(Long1);
  VPScratchPlan Scratch;
  Scratch.Slots.push_back({Long1, Type::getInt32Ty(C), 16, Align(4), 0, 64});
  Scratch.TotalBytes = 64;

  Expected<VPReductionFissionCandidate> Candidate =
      buildReductionFissionStagePlans(
          Plan, Analysis, Scratch,
          {ElementCount::getScalable(4), ElementCount::getScalable(8)});
  ASSERT_TRUE(static_cast<bool>(Candidate));
  ASSERT_NE(Candidate->ProducerPlan, nullptr);
  ASSERT_NE(Candidate->AccumulatorPlan, nullptr);

  unsigned ProducerInstructions = 0;
  unsigned ProducerStores = 0;
  for (VPRecipeBase &R :
       *Candidate->ProducerPlan->getVectorLoopRegion()->getEntryBasicBlock()) {
    ProducerInstructions += isa<VPInstruction>(&R);
    ProducerStores += isa<VPFissionScratchStoreRecipe>(&R);
  }
  EXPECT_EQ(ProducerInstructions, 4u);
  EXPECT_EQ(ProducerStores, 1u);

  unsigned AccumulatorInstructions = 0;
  unsigned AccumulatorLoads = 0;
  for (VPRecipeBase &R : *Candidate->AccumulatorPlan->getVectorLoopRegion()
                              ->getEntryBasicBlock()) {
    AccumulatorInstructions += isa<VPInstruction>(&R);
    AccumulatorLoads += isa<VPFissionScratchLoadRecipe>(&R);
  }
  EXPECT_EQ(AccumulatorInstructions, 4u);
  EXPECT_EQ(AccumulatorLoads, 1u);
  EXPECT_EQ(range_size(Candidate->ProducerPlan->vectorFactors()), 2u);
  EXPECT_EQ(range_size(Candidate->AccumulatorPlan->vectorFactors()), 2u);
  EXPECT_EQ(Accumulator->getOperand(0), Long1);
  EXPECT_EQ(range_size(*Body), 6u);
  EXPECT_TRUE(verifyVPlanIsValid(*Candidate->ProducerPlan));
  EXPECT_TRUE(verifyVPlanIsValid(*Candidate->AccumulatorPlan));
}

TEST_F(VPlanReductionFissionTest, CombinedAddCutIsPrivateAndConservative) {
  enum Case {
    Plain,
    ThreeTerms,
    Reversed,
    NUW,
    NSW,
    RootNSW,
    Floating,
    Shared,
    IntermediateUser,
    ShortInput,
    MixedWidth
  };
  for (Case K : {Plain, ThreeTerms, Reversed, NUW, NSW, RootNSW, Floating,
                 Shared, IntermediateUser, ShortInput, MixedWidth}) {
    SCOPED_TRACE(static_cast<int>(K));
    VPlan &Plan = getPlan();
    Type *Ty = K == Floating ? Type::getDoubleTy(C) : Type::getInt32Ty(C);
    auto *Zero = Plan.getOrAddLiveIn(Constant::getNullValue(Ty));
    auto *Seed = Plan.getOrAddLiveIn(
        K == Floating ? static_cast<Constant *>(ConstantFP::get(Ty, 17.0))
                      : ConstantInt::get(Ty, 17));
    auto *IndexZero =
        Plan.getOrAddLiveIn(ConstantInt::get(Type::getInt64Ty(C), 0));
    auto *TC = Plan.getOrAddLiveIn(ConstantInt::get(Type::getInt64Ty(C), 17));
    Plan.resetTripCount(TC);
    auto *Start = new VPInstruction(
        VPInstruction::ReductionStartVector,
        {Seed, Zero, Plan.getConstantInt(32, 1)},
        VPIRFlags::getDefaultFlags(VPInstruction::ReductionStartVector));
    Plan.getEntry()->appendRecipe(Start);
    auto *Body = Plan.createVPBasicBlock("vector.body");
    auto *Region = Plan.createLoopRegion(Plan.getIndexType(), {}, "vector loop",
                                         Body, Body);
    auto *IV = Region->getCanonicalIV();
    auto *Next =
        new VPInstruction(Instruction::Add, {IV, &Plan.getVFxUF()},
                          VPIRFlags::getDefaultFlags(Instruction::Add));

    RecurKind Kind = K == Floating ? RecurKind::FAdd : RecurKind::Add;
    auto *Phi = new VPReductionPHIRecipe(nullptr, Kind, *Start, *Start,
                                         RdxUnordered{1}, {});

    Body->appendRecipe(Phi);
    VPReductionPHIRecipe *OtherPhi = nullptr;
    VPValue *OtherSeed = nullptr;
    if (K == Shared || K == MixedWidth) {
      VPValue *OtherStart = Start;
      if (K == MixedWidth) {
        OtherSeed =
            Plan.getOrAddLiveIn(ConstantInt::get(Type::getInt64Ty(C), 19));
        OtherStart = new VPInstruction(
            VPInstruction::ReductionStartVector,
            {OtherSeed, IndexZero, IndexZero},
            VPIRFlags::getDefaultFlags(VPInstruction::ReductionStartVector));
        Plan.getEntry()->appendRecipe(OtherStart->getDefiningRecipe());
      }
      OtherPhi = new VPReductionPHIRecipe(
          nullptr, K == MixedWidth ? RecurKind::Xor : Kind, *OtherStart,
          *OtherStart, RdxUnordered{1}, {});
      Body->appendRecipe(OtherPhi);
    }
    unsigned AddOp = K == Floating ? Instruction::FAdd : Instruction::Add;
    unsigned MulOp = K == Floating ? Instruction::FMul : Instruction::Mul;
    auto *A = new VPInstruction(MulOp, {Zero, Seed},
                                VPIRFlags::getDefaultFlags(MulOp));
    auto *B = new VPInstruction(MulOp, {Seed, Seed},
                                VPIRFlags::getDefaultFlags(MulOp));
    Body->appendRecipe(A);
    Body->appendRecipe(B);
    auto *First =
        new VPInstruction(AddOp, {Phi, A}, VPIRFlags::getDefaultFlags(AddOp));
    if (K == NUW || K == NSW) {
      VPIRFlags Flags(VPIRFlags::WrapFlagsTy{K == NUW, K == NSW});
      First->transferFlags(Flags);
    }
    auto *Last =
        new VPInstruction(AddOp,
                          K == Reversed ? ArrayRef<VPValue *>({B, First})
                                        : ArrayRef<VPValue *>({First, B}),
                          VPIRFlags::getDefaultFlags(AddOp));
    if (K == RootNSW) {
      VPIRFlags Flags(VPIRFlags::WrapFlagsTy{false, true});
      Last->transferFlags(Flags);
    }
    Body->appendRecipe(First);
    Body->appendRecipe(Last);
    VPInstruction *Root = Last;
    if (K == ThreeTerms) {
      auto *D = new VPInstruction(MulOp, {Seed, Zero},
                                  VPIRFlags::getDefaultFlags(MulOp));
      Body->appendRecipe(D);
      Root = new VPInstruction(AddOp, {Last, D},
                               VPIRFlags::getDefaultFlags(AddOp));
      Body->appendRecipe(Root);
    } else if (K == ShortInput) {
      Root = new VPInstruction(AddOp, {Last, Seed},
                               VPIRFlags::getDefaultFlags(AddOp));
      Body->appendRecipe(Root);
    } else if (K == IntermediateUser) {
      Body->appendRecipe(new VPInstruction(MulOp, {First, Seed},
                                           VPIRFlags::getDefaultFlags(MulOp)));
    }
    Phi->setOperand(1, Root);
    VPInstruction *OtherUpdate = nullptr;
    if (OtherPhi) {
      VPValue *OtherInput = A;
      if (K == MixedWidth) {
        OtherInput =
            new VPInstruction(Instruction::Mul, {OtherSeed, OtherSeed},
                              VPIRFlags::getDefaultFlags(Instruction::Mul));
        Body->appendRecipe(OtherInput->getDefiningRecipe());
      }
      OtherUpdate = new VPInstruction(
          K == MixedWidth ? unsigned(Instruction::Xor) : AddOp,
          {OtherPhi, OtherInput},
          VPIRFlags::getDefaultFlags(
              K == MixedWidth ? unsigned(Instruction::Xor) : AddOp));
      OtherPhi->setOperand(1, OtherUpdate);
      Body->appendRecipe(OtherUpdate);
    }
    Body->appendRecipe(Next);
    Body->appendRecipe(new VPInstruction(
        VPInstruction::BranchOnCount, {Next, TC},
        VPIRFlags::getDefaultFlags(VPInstruction::BranchOnCount)));

    auto *Middle = Plan.createVPBasicBlock("middle.block");
    Middle->appendRecipe(new VPInstruction(
        VPInstruction::ComputeReductionResult, {Root},
        VPIRFlags(Phi->getRecurrenceKind(), false, false, {})));
    if (OtherPhi)
      Middle->appendRecipe(new VPInstruction(
          VPInstruction::ComputeReductionResult, {OtherUpdate},
          VPIRFlags(OtherPhi->getRecurrenceKind(), false, false, {})));
    VPBlockUtils::connectBlocks(Plan.getEntry(), Region);
    VPBlockUtils::connectBlocks(Region, Middle);
    VPBlockUtils::connectBlocks(Middle, Plan.getScalarHeader());
    Plan.addVF(ElementCount::getScalable(4));
    VPRegisterPressureBreakdown Pressure;
    Pressure.AccumulatorOverlapSurplus[1] = 1;
    auto Analysis = analyzeVPReductionFission(Plan, Pressure, {1, 1});
    ASSERT_TRUE(Analysis.isCandidate());

    auto Scratch = buildScratchPlan(Analysis.Partition.FrontierValues, 17,
                                    DataLayout("e-p:64:64-i64:64"), 1024);
    ASSERT_TRUE(static_cast<bool>(Scratch));
    unsigned OldSlots = K == ThreeTerms || K == MixedWidth ? 3 : 2;
    ASSERT_EQ(Scratch->Slots.size(), OldSlots);
    auto Original = buildReductionFissionStagePlans(
        Plan, Analysis, *Scratch, {ElementCount::getScalable(4)});
    auto Combined = buildReductionFissionStagePlans(
        Plan, Analysis, *Scratch, {ElementCount::getScalable(4)}, true);
    ASSERT_TRUE(static_cast<bool>(Original));
    ASSERT_TRUE(static_cast<bool>(Combined));
    bool CanCombine =
        K == Plain || K == ThreeTerms || K == Reversed || K == MixedWidth;
    unsigned NewSlots = K == MixedWidth ? 2 : CanCombine ? 1 : OldSlots;
    EXPECT_EQ(Combined->Scratch.Slots.size(), NewSlots);
    EXPECT_EQ(Original->Scratch.Slots.size(), OldSlots);
    EXPECT_EQ(Phi->getBackedgeValue(), Root);
    EXPECT_EQ(First->getOperand(0), Phi);
    EXPECT_EQ(Last->getOperand(K == Reversed ? 1 : 0), First);
    EXPECT_EQ(Combined->Scratch.TotalBytes,
              K == MixedWidth ? 208u
                              : NewSlots * 17 * (K == Floating ? 8u : 4u));
    if (K == MixedWidth) {
      EXPECT_EQ(Combined->Scratch.Slots[0].Offset, 0u);
      EXPECT_EQ(Combined->Scratch.Slots[1].Offset, 72u);
      EXPECT_EQ(Combined->Scratch.Slots[1].Alignment, Align(8));
    }
    for (VPlan *P :
         {Combined->ProducerPlan.get(), Combined->AccumulatorPlan.get(),
          Combined->ProducerRemainder.Plan.get(),
          Combined->AccumulatorRemainder.Plan.get()})
      EXPECT_TRUE(verifyVPlanIsValid(*P));
    for (VPlan *P : {Combined->ProducerPlan.get(),
                     Combined->ProducerRemainder.Plan.get()}) {
      unsigned Stores = 0;
      for (VPRecipeBase &R : *P->getVectorLoopRegion()->getEntryBasicBlock()) {
        if (auto *S = dyn_cast<VPFissionScratchStoreRecipe>(&R)) {
          ASSERT_LT(S->getSlotID(), Combined->Scratch.Slots.size());
          const auto &Slot = Combined->Scratch.Slots[S->getSlotID()];
          EXPECT_EQ(S->getElementType(), Slot.ElementType);
          EXPECT_EQ(S->getAlignment(), Slot.Alignment);
          ++Stores;
        }
        if (auto *I = dyn_cast<VPInstruction>(&R);
            I && I->getName() == "fission.contribution")
          EXPECT_FALSE(I->hasNoUnsignedWrap() || I->hasNoSignedWrap());
      }
      EXPECT_EQ(Stores, Combined->Scratch.Slots.size());
    }
    for (VPlan *P : {Combined->AccumulatorPlan.get(),
                     Combined->AccumulatorRemainder.Plan.get()}) {
      unsigned Loads = 0;
      for (VPRecipeBase &R : *P->getVectorLoopRegion()->getEntryBasicBlock())
        if (auto *L = dyn_cast<VPFissionScratchLoadRecipe>(&R)) {
          ASSERT_LT(L->getSlotID(), Combined->Scratch.Slots.size());
          const auto &Slot = Combined->Scratch.Slots[L->getSlotID()];
          EXPECT_EQ(L->getElementType(), Slot.ElementType);
          EXPECT_EQ(L->getAlignment(), Slot.Alignment);
          ++Loads;
        }
      EXPECT_EQ(Loads, Combined->Scratch.Slots.size());
    }
  }
}

TEST_F(VPlanReductionFissionTest, PreviewRejectsScratchTypeMismatch) {
  VPlan &Plan = getPlan();
  auto *Body = Plan.createVPBasicBlock("body");
  auto *Region =
      Plan.createLoopRegion(Plan.getIndexType(), {}, "loop", Body, Body);
  VPBlockUtils::connectBlocks(Plan.getEntry(), Region);
  VPBlockUtils::connectBlocks(Region, Plan.getScalarHeader());
  VPValue *Zero = Plan.getOrAddLiveIn(ConstantInt::get(Type::getInt32Ty(C), 0));
  auto *Producer =
      new VPInstruction(Instruction::Add, {Zero, Zero},
                        VPIRFlags::getDefaultFlags(Instruction::Add));
  auto *Accumulator =
      new VPInstruction(Instruction::Sub, {Producer, Zero},
                        VPIRFlags::getDefaultFlags(Instruction::Sub));
  Body->appendRecipe(Producer);
  Body->appendRecipe(Accumulator);

  VPReductionFissionAnalysis Analysis;
  auto &Partition = Analysis.Partition;
  Partition.ProducerRecipes.insert(Producer);
  Partition.AccumulatorRecipes.insert(Accumulator);
  Partition.FrontierValues.push_back(Producer);
  VPScratchPlan Scratch;
  Scratch.Slots.push_back({Producer, Type::getInt64Ty(C), 4, Align(8), 0, 32});
  Scratch.TotalBytes = 32;

  Expected<VPReductionFissionCandidate> Candidate =
      buildReductionFissionStagePlans(Plan, Analysis, Scratch,
                                      {ElementCount::getScalable(4)});
  EXPECT_FALSE(static_cast<bool>(Candidate));
  consumeError(Candidate.takeError());
}

TEST_F(VPlanReductionFissionTest, PreviewBuildsIndependentVectorRegions) {
  VPlan &Baseline = getPlan();
  VPValue *Zero =
      Baseline.getOrAddLiveIn(ConstantInt::get(Type::getInt32Ty(C), 0));
  VPValue *IndexZero =
      Baseline.getOrAddLiveIn(ConstantInt::get(Type::getInt64Ty(C), 0));
  VPValue *TripCount =
      Baseline.getOrAddLiveIn(ConstantInt::get(Type::getInt64Ty(C), 17));
  Baseline.resetTripCount(TripCount);
  auto *ReductionStart = new VPInstruction(
      VPInstruction::ReductionStartVector,
      {Zero, Zero, Baseline.getConstantInt(32, 1)},
      VPIRFlags::getDefaultFlags(VPInstruction::ReductionStartVector));
  Baseline.getEntry()->appendRecipe(ReductionStart);

  VPBasicBlock *Body = Baseline.createVPBasicBlock("vector.body");
  auto *Region = Baseline.createLoopRegion(Baseline.getIndexType(), {},
                                           "vector loop", Body, Body);
  auto *CanonicalIV = Region->getCanonicalIV();
  auto *IndexNext =
      new VPInstruction(Instruction::Add, {CanonicalIV, &Baseline.getVFxUF()},
                        VPIRFlags::getDefaultFlags(Instruction::Add));

  auto *WideIV = new VPWidenCanonicalIVRecipe(CanonicalIV);
  auto *ActiveMask = new VPInstruction(
      VPInstruction::ActiveLaneMask, {WideIV, TripCount, &Baseline.getVF()},
      VPIRFlags::getDefaultFlags(VPInstruction::ActiveLaneMask));
  auto *LongProducer =
      new VPInstruction(Instruction::Add, {Zero, Zero},
                        VPIRFlags::getDefaultFlags(Instruction::Add));
  auto *Accumulator =
      new VPReductionPHIRecipe(nullptr, RecurKind::Add, *ReductionStart,
                               *ReductionStart, RdxUnordered{1}, {});
  auto *Update =
      new VPInstruction(Instruction::Add, {Accumulator, LongProducer},
                        VPIRFlags::getDefaultFlags(Instruction::Add));
  Accumulator->setOperand(1, Update);
  auto *Branch = new VPInstruction(
      VPInstruction::BranchOnCount, {IndexNext, TripCount},
      VPIRFlags::getDefaultFlags(VPInstruction::BranchOnCount));

  Body->appendRecipe(Accumulator);
  Body->appendRecipe(WideIV);
  Body->appendRecipe(ActiveMask);
  Body->appendRecipe(LongProducer);
  Body->appendRecipe(Update);
  Body->appendRecipe(IndexNext);
  Body->appendRecipe(Branch);

  VPBasicBlock *Middle = Baseline.createVPBasicBlock("middle.block");
  auto *ReductionResult = new VPInstruction(
      VPInstruction::ComputeReductionResult, {Update},
      VPIRFlags(Accumulator->getRecurrenceKind(), false, false, {}));
  Middle->appendRecipe(ReductionResult);
  auto *ExitIR = BasicBlock::Create(C, "exit", F);
  auto *ExitPhi = PHINode::Create(Type::getInt32Ty(C), 1, "result", ExitIR);
  ExitPhi->addIncoming(ConstantInt::get(Type::getInt32Ty(C), 0), ScalarHeader);
  ReturnInst::Create(C, ExitIR);
  auto *Exit = Baseline.createVPIRBasicBlock(ExitIR);
  cast<VPIRPhi>(&Exit->front())->addIncoming(ReductionResult);
  VPBlockUtils::connectBlocks(Baseline.getEntry(), Region);
  VPBlockUtils::connectBlocks(Region, Middle);
  VPBlockUtils::connectBlocks(Middle, Exit);
  VPBlockUtils::connectBlocks(Exit, Baseline.getScalarHeader());
  Baseline.addVF(ElementCount::getScalable(4));

  VPRegisterPressureBreakdown Pressure;
  Pressure.AccumulatorOverlapSurplus[1] = 1;
  VPReductionFissionConfig Config;
  Config.MinimumReductionCount = 1;
  Config.MinimumLongProducerDepth = 1;
  VPReductionFissionAnalysis Analysis =
      analyzeVPReductionFission(Baseline, Pressure, Config);
  ASSERT_TRUE(Analysis.isCandidate());

  // Derived scalar IVs are loop control, not duplicated producer work.
  auto *DerivedIV =
      new VPDerivedIVRecipe(InductionDescriptor::IK_IntInduction, nullptr,
                            IndexZero, CanonicalIV, IndexZero);
  DerivedIV->insertBefore(LongProducer);
  Analysis.Partition.ProducerRecipes.insert(DerivedIV);
  Analysis.Partition.AccumulatorRecipes.insert(DerivedIV);

  VPScratchPlan Scratch;
  Scratch.Slots.push_back(
      {LongProducer, Type::getInt32Ty(C), 17, Align(4), 0, 68});
  Scratch.TotalBytes = 68;
  Expected<VPReductionFissionCandidate> Candidate =
      buildReductionFissionStagePlans(Baseline, Analysis, Scratch,
                                      {ElementCount::getScalable(4)});
  ASSERT_TRUE(static_cast<bool>(Candidate));
  EXPECT_EQ(Candidate->Partition.DuplicatedRecipeCount, 0u);
  EXPECT_TRUE(verifyVPlanIsValid(*Candidate->ProducerPlan));
  EXPECT_TRUE(verifyVPlanIsValid(*Candidate->AccumulatorPlan));
  EXPECT_NE(Candidate->ProducerPlan->getVectorLoopRegion(), nullptr);
  EXPECT_NE(Candidate->AccumulatorPlan->getVectorLoopRegion(), nullptr);
  bool HasReductionResult = false;
  for (VPBlockBase *Block :
       vp_depth_first_deep(Candidate->AccumulatorPlan->getEntry()))
    if (auto *VPBB = dyn_cast<VPBasicBlock>(Block))
      HasReductionResult |= any_of(*VPBB, [](VPRecipeBase &Recipe) {
        auto *Instruction = dyn_cast<VPInstruction>(&Recipe);
        return Instruction && Instruction->getOpcode() ==
                                  VPInstruction::ComputeReductionResult;
      });
  EXPECT_TRUE(HasReductionResult);
  ASSERT_EQ(Candidate->AccumulatorLiveOuts.size(), 1u);
  EXPECT_EQ(Candidate->AccumulatorLiveOuts.front().first, ExitPhi);
  EXPECT_EQ(Candidate->AccumulatorLiveOuts.front()
                .second->getDefiningRecipe()
                ->getParent()
                ->getName(),
            "middle.block");
  VPReductionPHIRecipe *StageAccumulator = nullptr;
  for (VPRecipeBase &Recipe :
       *Candidate->AccumulatorPlan->getVectorLoopRegion()->getEntryBasicBlock())
    if (auto *Reduction = dyn_cast<VPReductionPHIRecipe>(&Recipe)) {
      StageAccumulator = Reduction;
      break;
    }
  ASSERT_NE(StageAccumulator, nullptr);
  ASSERT_NE(StageAccumulator->getStartValue()->getDefiningRecipe(), nullptr);
  EXPECT_EQ(StageAccumulator->getStartValue()
                ->getDefiningRecipe()
                ->getParent()
                ->getPlan(),
            Candidate->AccumulatorPlan.get());

  auto GetScratchMask = [](VPlan &Plan) -> VPValue * {
    for (VPRecipeBase &Recipe :
         *Plan.getVectorLoopRegion()->getEntryBasicBlock()) {
      if (auto *Store = dyn_cast<VPFissionScratchStoreRecipe>(&Recipe))
        return Store->getMask();
      if (auto *Load = dyn_cast<VPFissionScratchLoadRecipe>(&Recipe))
        return Load->getMask();
    }
    return nullptr;
  };
  for (VPlan *Stage :
       {Candidate->ProducerPlan.get(), Candidate->AccumulatorPlan.get()}) {
    VPValue *Mask = GetScratchMask(*Stage);
    ASSERT_NE(Mask, nullptr);
    ASSERT_TRUE(isa<VPIRValue>(Mask));
    EXPECT_EQ(Mask->getLiveInIRValue(), ConstantInt::getTrue(C));
  }
  EXPECT_TRUE(verifyVPlanIsValid(*Candidate->ProducerRemainder.Plan));
  EXPECT_TRUE(verifyVPlanIsValid(*Candidate->AccumulatorRemainder.Plan));
  EXPECT_TRUE(Candidate->ProducerRemainder.Plan->hasScalarVFOnly());
  EXPECT_TRUE(Candidate->AccumulatorRemainder.Plan->hasScalarVFOnly());
  ASSERT_EQ(Candidate->AccumulatorRemainder.Reductions.size(), 1u);
  EXPECT_EQ(Candidate->AccumulatorRemainder.Reductions.front().VectorResult,
            Candidate->AccumulatorLiveOuts.front().second);
}

TEST_F(VPlanReductionFissionTest, SelectorUnlocksLargerProducerVF) {
  auto Pressure = [](unsigned Peak, unsigned Capacity) {
    VPRegisterPressureBreakdown Result;
    Result.PeakTotalRegs[1] = Peak;
    Result.Capacity[1] = Capacity;
    return Result;
  };
  SmallVector<VPFissionVFPressure, 2> Baseline = {
      {ElementCount::getScalable(4), Pressure(4, 8)},
      {ElementCount::getScalable(8), Pressure(10, 8)}};
  SmallVector<VPFissionVFPressure, 2> Producer = {
      {ElementCount::getScalable(4), Pressure(3, 8)},
      {ElementCount::getScalable(8), Pressure(6, 8)}};
  SmallVector<VPFissionVFPressure, 2> Accumulator = {
      {ElementCount::getScalable(4), Pressure(3, 8)},
      {ElementCount::getScalable(8), Pressure(9, 8)}};

  VPReductionFissionDecision Decision = selectReductionFissionConfiguration(
      ElementCount::getScalable(4), Baseline, Producer, Accumulator,
      /*ScratchBytes=*/128,
      /*MaximumScratchBytes=*/1024, /*DuplicatedRecipeCount=*/0,
      /*MaximumDuplicatedRecipes=*/2);
  EXPECT_TRUE(Decision.SelectFission);
  EXPECT_EQ(Decision.BaselineVF, ElementCount::getScalable(4));
  ASSERT_TRUE(Decision.Fission.has_value());
  EXPECT_EQ(Decision.Fission->ProducerVF, ElementCount::getScalable(8));
  EXPECT_EQ(Decision.Fission->AccumulatorVF, ElementCount::getScalable(4));
}

TEST_F(VPlanReductionFissionTest, SelectorComparesAgainstActualBaselineVF) {
  auto Pressure = [](unsigned Peak) {
    VPRegisterPressureBreakdown Result;
    Result.PeakTotalRegs[1] = Peak;
    Result.Capacity[1] = 32;
    return Result;
  };
  // The ordinary vectorizer has selected VF 8, even though the pressure-only
  // heuristic would select VF 4. Do not lower the producer VF to that value.
  SmallVector<VPFissionVFPressure, 2> Baseline = {
      {ElementCount::getScalable(8), Pressure(40)},
      {ElementCount::getScalable(4), Pressure(20)}};
  SmallVector<VPFissionVFPressure, 1> Producer = {
      {ElementCount::getScalable(4), Pressure(12)}};
  SmallVector<VPFissionVFPressure, 1> Accumulator = {
      {ElementCount::getScalable(4), Pressure(16)}};
  auto Decision = selectReductionFissionConfiguration(
      ElementCount::getScalable(8), Baseline, Producer, Accumulator, 128, 1024,
      0, 2);
  EXPECT_FALSE(Decision.SelectFission);
  EXPECT_EQ(Decision.BaselineVF, ElementCount::getScalable(8));
  EXPECT_EQ(Decision.Reason,
            VPReductionFissionRejectReason::ProducerVFDecrease);
}

TEST_F(VPlanReductionFissionTest, SelectorAllowsSameVFWithLowerPressure) {
  auto Pressure = [](unsigned Peak) {
    VPRegisterPressureBreakdown Result;
    Result.PeakTotalRegs[1] = Peak;
    Result.Capacity[1] = 32;
    return Result;
  };
  SmallVector<VPFissionVFPressure, 2> Baseline = {
      {ElementCount::getScalable(2), Pressure(28)},
      {ElementCount::getScalable(4), Pressure(55)}};
  SmallVector<VPFissionVFPressure, 2> Producer = {
      {ElementCount::getScalable(2), Pressure(18)},
      {ElementCount::getScalable(4), Pressure(35)}};
  SmallVector<VPFissionVFPressure, 2> Accumulator = {
      {ElementCount::getScalable(2), Pressure(25)},
      {ElementCount::getScalable(4), Pressure(49)}};

  auto Decision = selectReductionFissionConfiguration(
      ElementCount::getScalable(2), Baseline, Producer, Accumulator, 16384,
      65536, 0, 8);
  ASSERT_TRUE(Decision.SelectFission);
  ASSERT_TRUE(Decision.Fission.has_value());
  EXPECT_EQ(Decision.BaselineVF, ElementCount::getScalable(2));
  EXPECT_EQ(Decision.Fission->ProducerVF, ElementCount::getScalable(2));
  EXPECT_EQ(Decision.Fission->AccumulatorVF, ElementCount::getScalable(2));
}

TEST_F(VPlanReductionFissionTest, SelectorRejectsSameVFWithoutLowerPressure) {
  auto Pressure = [](unsigned Peak) {
    VPRegisterPressureBreakdown Result;
    Result.PeakTotalRegs[1] = Peak;
    Result.Capacity[1] = 32;
    return Result;
  };
  SmallVector<VPFissionVFPressure, 1> Baseline = {
      {ElementCount::getScalable(2), Pressure(28)}};
  SmallVector<VPFissionVFPressure, 1> Producer = {
      {ElementCount::getScalable(2), Pressure(18)}};
  SmallVector<VPFissionVFPressure, 1> Accumulator = {
      {ElementCount::getScalable(2), Pressure(28)}};
  auto Decision = selectReductionFissionConfiguration(
      ElementCount::getScalable(2), Baseline, Producer, Accumulator, 128, 1024,
      0, 2);
  EXPECT_FALSE(Decision.SelectFission);
  EXPECT_EQ(Decision.Reason,
            VPReductionFissionRejectReason::FissionPressureNotReduced);
}

TEST_F(VPlanReductionFissionTest, ExplicitPressureOverflowKeepsResourceLimits) {
  auto Pressure = [](unsigned Peak) {
    VPRegisterPressureBreakdown Result;
    Result.PeakTotalRegs[1] = Peak;
    Result.Capacity[1] = 32;
    return Result;
  };
  SmallVector<VPFissionVFPressure, 2> Baseline = {
      {ElementCount::getScalable(2), Pressure(28)},
      {ElementCount::getScalable(4), Pressure(55)}};
  SmallVector<VPFissionVFPressure, 1> Producer = {
      {ElementCount::getScalable(4), Pressure(35)}};
  SmallVector<VPFissionVFPressure, 1> Accumulator = {
      {ElementCount::getScalable(2), Pressure(25)}};

  auto Select = [&](bool AllowOverflow, uint64_t Scratch, unsigned Duplicates) {
    return selectReductionFissionConfiguration(
        ElementCount::getScalable(2), Baseline, Producer, Accumulator, Scratch,
        65536, Duplicates, 8, AllowOverflow);
  };
  EXPECT_FALSE(Select(false, 16384, 0).SelectFission);
  auto Forced = Select(true, 16384, 0);
  ASSERT_TRUE(Forced.SelectFission);
  ASSERT_TRUE(Forced.Fission.has_value());
  EXPECT_EQ(Forced.Fission->ProducerVF, ElementCount::getScalable(4));
  EXPECT_EQ(Forced.Fission->AccumulatorVF, ElementCount::getScalable(2));
  EXPECT_EQ(Select(true, 65537, 0).Reason,
            VPReductionFissionRejectReason::ScratchLimit);
  EXPECT_EQ(Select(true, 16384, 9).Reason,
            VPReductionFissionRejectReason::CrossPartitionDependence);
}

TEST_F(VPlanReductionFissionTest, SelectorRejectsNewUncomparedPressureClass) {
  auto Pressure = [](unsigned ClassID, unsigned Peak, unsigned Capacity) {
    VPRegisterPressureBreakdown Result;
    Result.PeakTotalRegs[ClassID] = Peak;
    Result.Capacity[ClassID] = Capacity;
    return Result;
  };
  SmallVector<VPFissionVFPressure, 2> Baseline = {
      {ElementCount::getScalable(4), Pressure(1, 4, 8)},
      {ElementCount::getScalable(8), Pressure(1, 10, 8)}};
  SmallVector<VPFissionVFPressure, 2> Producer = {
      {ElementCount::getScalable(8), Pressure(2, 6, 8)}};
  SmallVector<VPFissionVFPressure, 2> Accumulator = {
      {ElementCount::getScalable(4), Pressure(1, 3, 8)}};

  VPReductionFissionDecision Decision = selectReductionFissionConfiguration(
      ElementCount::getScalable(4), Baseline, Producer, Accumulator, 128, 1024,
      0, 2);
  EXPECT_FALSE(Decision.SelectFission);
  ASSERT_TRUE(Decision.Reason.has_value());
  EXPECT_EQ(*Decision.Reason,
            VPReductionFissionRejectReason::FissionPressureNotReduced);
}

TEST_F(VPlanReductionFissionTest, SelectorRequiresRegisterHeadroom) {
  auto Pressure = [](unsigned Peak) {
    VPRegisterPressureBreakdown Result;
    Result.PeakTotalRegs[1] = Peak;
    Result.Capacity[1] = 8;
    return Result;
  };
  SmallVector<VPFissionVFPressure, 2> Baseline = {
      {ElementCount::getScalable(2), Pressure(4)},
      {ElementCount::getScalable(4), Pressure(8)}};
  SmallVector<VPFissionVFPressure, 2> Producer = {
      {ElementCount::getScalable(2), Pressure(3)},
      {ElementCount::getScalable(4), Pressure(6)}};
  SmallVector<VPFissionVFPressure, 2> Accumulator = {
      {ElementCount::getScalable(2), Pressure(4)},
      {ElementCount::getScalable(4), Pressure(8)}};

  VPReductionFissionDecision Decision = selectReductionFissionConfiguration(
      ElementCount::getScalable(2), Baseline, Producer, Accumulator,
      /*ScratchBytes=*/128,
      /*MaximumScratchBytes=*/1024, /*DuplicatedRecipeCount=*/0,
      /*MaximumDuplicatedRecipes=*/2);
  EXPECT_TRUE(Decision.SelectFission);
  ASSERT_TRUE(Decision.Fission.has_value());
  EXPECT_EQ(Decision.Fission->ProducerVF, ElementCount::getScalable(4));
  EXPECT_EQ(Decision.Fission->AccumulatorVF, ElementCount::getScalable(2));
}

TEST_F(VPlanReductionFissionTest, ScratchLayoutRequiresBoundedConstantStorage) {
  VPlan &Plan = getPlan();
  VPValue *I32Frontier =
      Plan.getOrAddLiveIn(ConstantInt::get(Type::getInt32Ty(C), 1));
  VPValue *I64Frontier =
      Plan.getOrAddLiveIn(ConstantInt::get(Type::getInt64Ty(C), 2));
  DataLayout DL("e-p:64:64-i64:64-n32:64");

  SmallVector<VPValue *, 3> Frontiers = {I32Frontier, I64Frontier, I32Frontier};
  Expected<VPScratchPlan> Scratch = buildScratchPlan(Frontiers, 10, DL, 1024);
  ASSERT_TRUE(static_cast<bool>(Scratch));
  ASSERT_EQ(Scratch->Slots.size(), 2u);
  EXPECT_EQ(Scratch->Slots[0].Frontier, I32Frontier);
  EXPECT_EQ(Scratch->Slots[0].Offset, 0u);
  EXPECT_EQ(Scratch->Slots[0].Bytes, 40u);
  EXPECT_EQ(Scratch->Slots[1].Frontier, I64Frontier);
  EXPECT_EQ(Scratch->Slots[1].Offset, 40u);
  EXPECT_EQ(Scratch->Slots[1].Bytes, 80u);
  EXPECT_EQ(Scratch->TotalBytes, 120u);

  auto ExpectFailure = [](Expected<VPScratchPlan> Result) {
    EXPECT_FALSE(static_cast<bool>(Result));
    consumeError(Result.takeError());
  };
  ExpectFailure(buildScratchPlan(Frontiers, std::nullopt, DL, 1024));
  ExpectFailure(buildScratchPlan(Frontiers, 0, DL, 1024));
  ExpectFailure(buildScratchPlan({I64Frontier}, UINT64_MAX, DL, UINT64_MAX));
  ExpectFailure(buildScratchPlan({I64Frontier, I32Frontier}, UINT64_MAX / 8, DL,
                                 UINT64_MAX));
  ExpectFailure(buildScratchPlan(Frontiers, 10, DL, 119));
}

TEST_F(VPlanReductionFissionTest, ScratchRecipesPreserveSlotMetadata) {
  VPlan &Plan = getPlan();
  VPValue *Base =
      Plan.getOrAddLiveIn(ConstantPointerNull::get(PointerType::getUnqual(C)));
  VPValue *Index =
      Plan.getOrAddLiveIn(ConstantInt::get(Type::getInt64Ty(C), 0));
  VPValue *Value =
      Plan.getOrAddLiveIn(ConstantInt::get(Type::getInt32Ty(C), 1));
  VPValue *Mask = Plan.getOrAddLiveIn(ConstantInt::getTrue(Type::getInt1Ty(C)));

  auto *Store = new VPFissionScratchStoreRecipe(
      3, Type::getInt32Ty(C), Align(4), Base, Index, Value, Mask);
  auto *Load = new VPFissionScratchLoadRecipe(3, Type::getInt32Ty(C), Align(4),
                                              Base, Index, Mask);
  EXPECT_EQ(Store->getSlotID(), 3u);
  EXPECT_EQ(Store->getElementType(), Type::getInt32Ty(C));
  EXPECT_EQ(Store->getOperand(0), Base);
  EXPECT_EQ(Store->getOperand(1), Index);
  EXPECT_EQ(Store->getStoredValue(), Value);
  EXPECT_EQ(Store->getMask(), Mask);
  EXPECT_FALSE(Store->usesFirstLaneOnly(Mask));
  EXPECT_EQ(Load->getSlotID(), 3u);
  EXPECT_EQ(Load->getElementType(), Type::getInt32Ty(C));
  EXPECT_EQ(Load->getOperand(0), Base);
  EXPECT_EQ(Load->getOperand(1), Index);
  EXPECT_EQ(Load->getMask(), Mask);
  EXPECT_FALSE(Load->usesFirstLaneOnly(Mask));

  std::unique_ptr<VPRecipeBase> StoreClone(Store->clone());
  std::unique_ptr<VPRecipeBase> LoadClone(Load->clone());
  EXPECT_EQ(cast<VPFissionScratchStoreRecipe>(StoreClone.get())->getSlotID(),
            3u);
  EXPECT_EQ(cast<VPFissionScratchLoadRecipe>(LoadClone.get())->getSlotID(), 3u);

  delete Store;
  delete Load;
}

} // namespace
} // namespace llvm
