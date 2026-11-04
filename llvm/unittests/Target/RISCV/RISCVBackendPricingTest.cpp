// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVCostSheet.h"
#include "llvm/Analysis/VPlanCostProfile.h"
#include "llvm/AsmParser/Parser.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Module.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Target/TargetMachine.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/SaveAndRestore.h"
#include "llvm/Transforms/Vectorize/VPlanBackendFeedback.h"
#include "gtest/gtest.h"
#include <array>
#include <tuple>
using namespace llvm;
namespace {
VPlanMIRInstruction instruction(StringRef Opcode, unsigned Group = 0,
                                unsigned SEW = 0) {
  VPlanMIRInstruction I;
  I.Opcode = I.BaseOpcode = Opcode.str();
  I.Vector = Group != 0;
  I.LMUL8 = Group;
  I.SEW = SEW;
  return I;
}
void price(const RISCVCostSheet &Sheet, const VPlanMIRInstruction &I,
           int64_t Expected, bool Unknown = false) {
  auto C = Sheet.getInstructionCost(I);
  ASSERT_TRUE(bool(C)) << toString(C.takeError());
  EXPECT_EQ(C->Numerator, Expected);
  EXPECT_EQ(C->Denominator, 1);
  EXPECT_EQ(C->Unknown, Unknown);
}
class RISCVBackendPricing : public testing::Test {
protected:
  LLVMContext Context;
  std::unique_ptr<TargetMachine> TM;
  std::unique_ptr<Module> M;
  Function *F;
  void SetUp() override {
    LLVMInitializeRISCVTargetInfo();
    LLVMInitializeRISCVTarget();
    LLVMInitializeRISCVTargetMC();
    Triple TT("riscv64-unknown-elf");
    std::string Error;
    auto *T = TargetRegistry::lookupTarget("", TT, Error);
    ASSERT_NE(T, nullptr);
    TM.reset(T->createTargetMachine(TT, "generic-rv64", "+v", TargetOptions(),
                                    std::nullopt));
    SMDiagnostic Diagnostic;
    M = parseAssemblyString("define void @f() { ret void }", Diagnostic,
                            Context);
    ASSERT_TRUE(M);
    M->setDataLayout(TM->createDataLayout());
    F = M->getFunction("f");
  }
};
} // namespace

TEST_F(RISCVBackendPricing, ExactProfilesAndNativeFallback) {
  for (auto [CPU, Scale, Profile, Model] :
       {std::tuple{"xiangshan-kunminghu", 2u, "xiangshan-v2-128",
                   "xiangshan-direct-v1"},
        std::tuple{"saturn-shuttle-v256d128", 4u, "saturn-shuttle-v256d128",
                   "saturn-shuttle-direct-v1"},
        std::tuple{"spacemit-x60", 4u, "spacemit-k1-256",
                   "spacemit-k1-direct-v1"}}) {
    SCOPED_TRACE(CPU);
    F->addFnAttr("tune-cpu", CPU);
    for (unsigned Mode : {0u, 1u, 2u}) {
      bool Exact = Mode == 0;
      F->removeFnAttr(Attribute::VScaleRange);
      if (Mode != 1)
        F->addFnAttr(Attribute::getWithVScaleRangeArgs(
            Context, Exact ? Scale : Scale * 2, Exact ? Scale : Scale * 2));
      auto TTI = TM->getTargetTransformInfo(*F);
      EXPECT_EQ(TTI.getVPlanCostProfileName(), Exact ? Profile : "native");
      auto MIR = TM->getTargetMIRInfo(*F);
      ASSERT_TRUE(MIR);
      EXPECT_EQ(MIR->getModelName(), Exact ? Model : "riscv-generic-direct-v1");
    }
  }
  F->addFnAttr("target-features", "-v,-zve32x,-zve32f,-zve64x,-zve64f,-zve64d");
  EXPECT_EQ(TM->getTargetTransformInfo(*F).getVPlanCostProfileName(), "native");
  EXPECT_FALSE(TM->getTargetMIRInfo(*F));
}

TEST_F(RISCVBackendPricing, ComparisonScopePreservesNativeAndMIR) {
  F->addFnAttr("tune-cpu", "xiangshan-kunminghu");
  F->addFnAttr(Attribute::getWithVScaleRangeArgs(Context, 2, 2));
  auto TTI = TM->getTargetTransformInfo(*F);
  auto *Ty = ScalableVectorType::get(Type::getFloatTy(Context), 4);
  auto Kind = TargetTransformInfo::TCK_RecipThroughput;
  auto Native = TTI.getArithmeticInstrCost(Instruction::FAdd, Ty, Kind);
  auto Latency = TTI.getArithmeticInstrCost(Instruction::FAdd, Ty,
                                            TargetTransformInfo::TCK_Latency);
  {
    VPlanCostProfileScope Tuned(true);
    EXPECT_EQ(TTI.getArithmeticInstrCost(Instruction::FAdd, Ty, Kind), 2);
    EXPECT_EQ(TTI.getArithmeticInstrCost(Instruction::FAdd, Ty,
                                         TargetTransformInfo::TCK_Latency),
              Latency);
    EXPECT_EQ(TTI.getArithmeticInstrCost(Instruction::SDiv,
                                         Type::getInt64Ty(Context), Kind),
              23);
    VPlanCostProfileScope NativeProbe(false);
    EXPECT_EQ(TTI.getArithmeticInstrCost(Instruction::FAdd, Ty, Kind), Native);
    EXPECT_EQ(TM->getTargetMIRInfo(*F)->getModelName(), "xiangshan-direct-v1");
  }
  EXPECT_EQ(TTI.getArithmeticInstrCost(Instruction::FAdd, Ty, Kind), Native);
}

TEST(RISCVBackendSheets, PricesGeometryAndUnknownAreDistinct) {
  XiangShanCostSheet XS;
  SaturnCostSheet Saturn;
  SpacemitK1CostSheet K1;
  RISCVCostSheet Generic(256);
  for (const RISCVCostSheet *Sheet :
       std::array<const RISCVCostSheet *, 2>{&Saturn, &K1}) {
    price(*Sheet, instruction("VFMACC_VV", 16, 32), 2);
    price(*Sheet, instruction("VFADD_VV", 16, 32), 4);
  }
  price(XS, instruction("VADD_VX", 32, 32), 5);
  price(XS, instruction("DIV"), 23);
  price(Generic, instruction("DIV"), 4);
  price(Generic, instruction("VADD_VV", 1, 32), 1);
  for (const RISCVCostSheet *Sheet :
       std::array<const RISCVCostSheet *, 2>{&XS, &Generic}) {
    price(*Sheet, instruction("UNSUPPORTED_OPCODE"), 1, true);
    auto Bad = Sheet->getInstructionCost(instruction("VADD_VV", 3, 32));
    EXPECT_FALSE(bool(Bad));
    consumeError(Bad.takeError());
  }
  auto TooNarrow = XS.getInstructionCost(instruction("VADD_VV", 1, 32));
  EXPECT_FALSE(bool(TooNarrow));
  consumeError(TooNarrow.takeError());
  auto Segment = instruction("VLSEG2E32_V", 16, 32);
  Segment.Load = true;
  price(XS, Segment, 129);
  price(Generic, Segment, 32);
  Segment.BaseOpcode = "VLOXEI16_V";
  Segment.IndexEMUL8 = 8;
  Segment.IndexEEW = 16;
  price(XS, Segment, 33);
  Segment.IndexEMUL8 = 16;
  auto InvalidIndex = XS.getInstructionCost(Segment);
  EXPECT_FALSE(bool(InvalidIndex));
  consumeError(InvalidIndex.takeError());
}

TEST(RISCVBackendSheets, SpillGroupsAndDirections) {
  XiangShanCostSheet XS;
  for (bool Load : {false, true}) {
    EXPECT_EQ(XS.spillCost(true, Load, {4, 1}), 5);
    EXPECT_EQ(XS.spillCost(true, Load, {4, 4}), 8);
    EXPECT_EQ(XS.spillCost(false, Load, {4, 4}), Load ? 4 : 8);
    EXPECT_EQ(XS.spillCost(true, Load, {0, 0}), 0);
    EXPECT_FALSE(XS.spillCost(true, Load, {4, 0}).isValid());
  }
}

// The service's execution control exposes whether a raw query was reused;
// prices and report text are deliberately absent from this cache check.
TEST_F(RISCVBackendPricing, RawReuseRequiresMatchingMaterializationContext) {
  auto &Options = cl::getRegisteredOptions();
  auto &Prune = static_cast<cl::opt<bool> *>(Options["vplan-backend-prune-cfg"])->getValue();
  auto &Markers = static_cast<cl::opt<bool> *>(Options["vplan-backend-region-probes"])->getValue();
  SaveAndRestore SavedPrune(Prune, false);
  SaveAndRestore SavedMarkers(Markers, true);
  SMDiagnostic Error;
  M = parseAssemblyString(R"(
    define void @f(ptr %p, i64 %n) vscale_range(2,2) {
    entry: br label %loop
    loop:
      %i = phi i64 [0, %entry], [%next, %loop]
      %q = getelementptr i32, ptr %p, i64 %i
      store i32 7, ptr %q
      %next = add nuw i64 %i, 1
      %done = icmp eq i64 %next, %n
      br i1 %done, label %exit, label %loop
    exit: ret void
    })", Error, Context);
  ASSERT_TRUE(M);
  M->setDataLayout(TM->createDataLayout());
  M->setTargetTriple(TM->getTargetTriple());
  F = M->getFunction("f");
  PassBuilder PB(TM.get());
  LoopAnalysisManager LAM;
  FunctionAnalysisManager FAM;
  CGSCCAnalysisManager CGAM;
  ModuleAnalysisManager MAM;
  PB.registerModuleAnalyses(MAM);
  PB.registerCGSCCAnalyses(CGAM);
  PB.registerFunctionAnalyses(FAM);
  PB.registerLoopAnalyses(LAM);
  PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);
  auto &Service = FAM.getResult<VPlanBackendFeedbackAnalysis>(*F);
  auto *Header = F->getEntryBlock().getTerminator()->getSuccessor(0);
  VPlanBackendCandidate Candidate{"scalar", 0, ElementCount::getFixed(1),
                                  true, false, false};
  Candidate.Kind = VPlanBackendCandidateKind::ScalarBaseline;
  Candidate.Observation.StopAfter = VPlanBackendStopAfter::MIR;
  auto query = [&](bool Starts, bool Succeeds = true) {
    Candidate.Control = std::make_shared<VPlanBackendProbeControl>();
    auto R = Service.get(*F, *Header, Candidate);
    ASSERT_TRUE(bool(R)) << toString(R.takeError());
    EXPECT_EQ(R->Spill.succeeded(), Succeeds) << R->Spill.Failure;
    EXPECT_EQ(Candidate.Control->Started, Starts);
  };
  Service.beginInvocation();
  query(true);
  query(false);
  Candidate.Observation.StopAfter = VPlanBackendStopAfter::Spill;
  query(false); // MIR collected the earlier slot in this same pipeline.
  Candidate.Observation.StopAfter = VPlanBackendStopAfter::MIR;
  Candidate.ScalarTail = false;
  query(true);
  Candidate.ScalarTail = true;
  Prune = true;
  Candidate.Observation.StopAfter = VPlanBackendStopAfter::Spill;
  // Scalar materialization requires MIR. A CFG-context mismatch must execute
  // and reject this request, rather than return the cached valid spill slot.
  query(true, false);
  Candidate.Observation.StopAfter = VPlanBackendStopAfter::MIR;
  query(false); // MIR always keeps the full CFG.
  Markers = false;
  query(true);
  Service.beginInvocation();
  query(true);
}
