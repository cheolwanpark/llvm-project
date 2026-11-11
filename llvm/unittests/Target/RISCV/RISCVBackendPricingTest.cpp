// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVGenericMIRInfo.h"
#include "RISCVInstrInfo.h"
#include "llvm/AsmParser/Parser.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Module.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/SaveAndRestore.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Target/TargetMachine.h"
#include "llvm/Transforms/Vectorize/VPlanBackendFeedback.h"
#include "gtest/gtest.h"
using namespace llvm;
namespace {
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

TEST_F(RISCVBackendPricing, NativeModelsAndOperationRelationships) {
  for (auto [CPU, Scale] : {std::pair{"xiangshan-kunminghu", 2u},
                            std::pair{"saturn-shuttle-v256d128", 4u}}) {
    F->addFnAttr("tune-cpu", CPU);
    F->addFnAttr(Attribute::getWithVScaleRangeArgs(Context, Scale, Scale));
    EXPECT_EQ(TM->getTargetTransformInfo(*F).getVPlanCostProfileName(),
              "native");
    auto MIR = TM->getTargetMIRInfo(*F);
    ASSERT_TRUE(MIR);
    EXPECT_EQ(MIR->getRevision(), "generic-mirinfo-native-v1");
    auto cost = [&](unsigned Opcode, unsigned Group = 16) {
      VPlanMIRInstruction I;
      I.BaseOpcodeID = Opcode;
      I.LMUL8 = Group;
      I.SEW = 32;
      auto C = MIR->getInstructionCost(I);
      EXPECT_TRUE(bool(C));
      if (!C) {
        consumeError(C.takeError());
        return int64_t(-1);
      }
      return C->Numerator;
    };
    EXPECT_EQ(cost(RISCV::VFADD_VV), 2 * cost(RISCV::VFMACC_VV));
    EXPECT_EQ(cost(RISCV::VFSQRT_V), cost(RISCV::VFMACC_VV));
    EXPECT_GE(cost(RISCV::VADD_VV, 32), cost(RISCV::VADD_VV, 16));
    EXPECT_EQ(cost(RISCV::VFWCVT_F_F_V), cost(RISCV::VADD_VV, 32));
    EXPECT_EQ(cost(RISCV::VFNCVT_F_F_W), cost(RISCV::VADD_VV));
    EXPECT_EQ(cost(RISCV::VLSE32_V, 32), 2 * cost(RISCV::VLSE32_V, 16));
    EXPECT_LE(cost(RISCV::VFREDUSUM_VS), cost(RISCV::VFREDOSUM_VS));
    F->addFnAttr("target-features",
                 "+v,+f,+d,+experimental-zvvmm,"
                 "+experimental-zvvfmm,+experimental-zvvmtls,"
                 "+experimental-zvvmttls");
    MIR = TM->getTargetMIRInfo(*F);
    EXPECT_EQ(cost(RISCV::VWMMACC_VV), 2 * cost(RISCV::VMMACC_VV));
    EXPECT_EQ(cost(RISCV::VFMMACC_VV), cost(RISCV::VMMACC_VV));
    EXPECT_EQ(cost(RISCV::VMTTL_V), cost(RISCV::VMTL_V));
    VPlanMIRInstruction Bad;
    auto Failed = MIR->getInstructionCost(Bad);
    EXPECT_FALSE(bool(Failed));
    consumeError(Failed.takeError());
    Bad.BaseOpcodeID = RISCV::VADD_VV;
    Bad.LMUL8 = 4;
    Bad.SEW = 64; // Invalid even when the nominal VLEN provides whole lanes.
    Failed = MIR->getInstructionCost(Bad);
    EXPECT_FALSE(bool(Failed));
    consumeError(Failed.takeError());
  }
}

// The service's execution control exposes whether a raw query was reused;
// prices and report text are deliberately absent from this cache check.
TEST_F(RISCVBackendPricing, RawReuseRequiresMatchingMaterializationContext) {
  auto &Options = cl::getRegisteredOptions();
  auto &Prune = static_cast<cl::opt<bool> *>(Options["vplan-backend-prune-cfg"])
                    ->getValue();
  SaveAndRestore SavedPrune(Prune, false);
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
    })",
                          Error, Context);
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
  auto Service = FAM.getResult<VPlanBackendFeedbackAnalysis>(*F).bind(
      PB.createVPlanBackendPipelineConfig(OptimizationLevel::O2,
                                          ThinOrFullLTOPhase::None));
  auto *Header = F->getEntryBlock().getTerminator()->getSuccessor(0);
  VPlanBackendCandidate Candidate{"scalar", 0,     ElementCount::getFixed(1),
                                  true,     false, false};
  Candidate.Kind = VPlanBackendCandidateKind::ScalarBaseline;
  Candidate.Observation.CollectMIR = true;
  auto query = [&](bool Starts, bool Succeeds = true) {
    Candidate.Control = std::make_shared<VPlanBackendProbeControl>();
    auto R = Service.get(*F, *Header, Candidate);
    ASSERT_TRUE(bool(R)) << toString(R.takeError());
    EXPECT_EQ(R->Spill.succeeded(), Succeeds);
    EXPECT_EQ(Candidate.Control->Started, Starts);
  };
  Service.beginInvocation();
  query(true);
  query(false);
  Candidate.Observation.CollectMIR = false;
  query(false); // MIR collected the earlier slot in this same pipeline.
  Candidate.Observation.CollectMIR = true;
  Candidate.ScalarTail = false;
  query(true);
  Candidate.ScalarTail = true;
  Prune = true;
  Candidate.Observation.CollectMIR = false;
  // Both modes retain the same CFG and reuse the scalar spill observation.
  query(false);
  Candidate.Observation.CollectMIR = true;
  query(false); // MIR always keeps the full CFG.
  Service.beginInvocation();
  query(true);
}

TEST_F(RISCVBackendPricing, InlineAsmPricesUseIRArguments) {
  SMDiagnostic Error;
  M = parseAssemblyString(R"(
    define void @f(ptr %p, i64 %n) vscale_range(2,2) {
    entry: br label %loop
    loop:
      %i = phi i64 [0, %entry], [%next, %loop]
      call void asm sideeffect "", ""()
      call void asm sideeffect "", "r,r"(ptr %p, i64 %i)
      %next = add nuw i64 %i, 1
      %done = icmp eq i64 %next, %n
      br i1 %done, label %exit, label %loop
    exit: ret void
    })",
                          Error, Context);
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
  auto Service = FAM.getResult<VPlanBackendFeedbackAnalysis>(*F).bind(
      PB.createVPlanBackendPipelineConfig(OptimizationLevel::O2,
                                          ThinOrFullLTOPhase::None));
  auto *Header = F->getEntryBlock().getTerminator()->getSuccessor(0);
  VPlanBackendCandidate Candidate{"scalar", 0,     ElementCount::getFixed(1),
                                  true,     false, false};
  Candidate.Kind = VPlanBackendCandidateKind::ScalarBaseline;
  Candidate.Observation.CollectMIR = true;
  Service.beginInvocation();
  auto Observed = Service.get(*F, *Header, Candidate);
  ASSERT_TRUE(bool(Observed)) << toString(Observed.takeError());
  ASSERT_TRUE(Observed->MIR.succeeded());
  auto Info = TM->getTargetMIRInfo(*F);
  unsigned Asms = 0;
  for (const auto &Loop : Observed->MIR.Loops)
    for (const auto &MI : *Loop.MIRBody)
      if (MI.InlineAsmArguments) {
        auto Cost = Info->getInstructionCost(MI);
        ASSERT_TRUE(bool(Cost)) << toString(Cost.takeError());
        EXPECT_EQ(Cost->Numerator,
                  (*MI.InlineAsmArguments + 1) * Cost->Denominator);
        ++Asms;
      }
  EXPECT_EQ(Asms, 2u);
}

// VF1 materialization must still receive SLP from its own continuation, even
// after other pipelines are constructed and the builders have been destroyed.
TEST_F(RISCVBackendPricing, ContinuationOwnsSLPConfiguration) {
  SMDiagnostic Error;
  M = parseAssemblyString(R"(
    define void @f(ptr noalias %a, ptr noalias %b, i64 %n) vscale_range(2,2) {
    entry: br label %loop
    loop:
      %i = phi i64 [0, %entry], [%next, %loop]
      %a0 = getelementptr float, ptr %a, i64 %i
      %a1 = getelementptr float, ptr %a0, i64 1
      %a2 = getelementptr float, ptr %a0, i64 2
      %a3 = getelementptr float, ptr %a0, i64 3
      %b0 = getelementptr float, ptr %b, i64 %i
      %b1 = getelementptr float, ptr %b0, i64 1
      %b2 = getelementptr float, ptr %b0, i64 2
      %b3 = getelementptr float, ptr %b0, i64 3
      %x0 = load float, ptr %a0
      %x1 = load float, ptr %a1
      %x2 = load float, ptr %a2
      %x3 = load float, ptr %a3
      %y0 = fadd float %x0, 1.0
      %y1 = fadd float %x1, 1.0
      %y2 = fadd float %x2, 1.0
      %y3 = fadd float %x3, 1.0
      store float %y0, ptr %b0
      store float %y1, ptr %b1
      store float %y2, ptr %b2
      store float %y3, ptr %b3
      %next = add nuw i64 %i, 4
      %done = icmp eq i64 %next, %n
      br i1 %done, label %exit, label %loop
    exit: ret void
    })",
                          Error, Context);
  ASSERT_TRUE(M);
  M->setDataLayout(TM->createDataLayout());
  M->setTargetTriple(TM->getTargetTriple());
  F = M->getFunction("f");
  FunctionAnalysisManager FAM;
  std::shared_ptr<const VPlanBackendPipelineConfig> Enabled, Disabled;
  {
    PipelineTuningOptions PTO;
    PTO.SLPVectorization = true;
    PTO.LoopUnrolling = false;
    PassBuilder PB(TM.get(), PTO);
    PB.registerFunctionAnalyses(FAM);
    Enabled = PB.createVPlanBackendPipelineConfig(OptimizationLevel::O3,
                                                  ThinOrFullLTOPhase::None);
    PTO.SLPVectorization = false;
    PassBuilder Other(TM.get(), PTO);
    Disabled = Other.createVPlanBackendPipelineConfig(OptimizationLevel::O3,
                                                      ThinOrFullLTOPhase::None);
  }
  auto &Factory = FAM.getResult<VPlanBackendFeedbackAnalysis>(*F);
  auto On = Factory.bind(Enabled);
  auto Off = Factory.bind(Disabled);
  auto *Header = F->getEntryBlock().getTerminator()->getSuccessor(0);
  VPlanBackendCandidate C{"scalar", 0,     ElementCount::getFixed(1),
                          true,     false, false};
  C.Kind = VPlanBackendCandidateKind::ScalarBaseline;
  C.Observation.CollectMIR = true;
  for (auto *Service : {&On, &Off, &On}) {
    Service->beginInvocation();
    auto R = Service->get(*F, *Header, C);
    ASSERT_TRUE(bool(R)) << toString(R.takeError());
    ASSERT_TRUE(R->MIR.succeeded());
    bool Vector = false;
    for (const auto &Loop : R->MIR.Loops)
      for (const auto &MI : *Loop.MIRBody)
        Vector |= MI.Vector && !MI.Configuration;
    EXPECT_EQ(Vector, Service == &On);
  }
  auto Missing = Factory.bind(nullptr);
  auto R = Missing.get(*F, *Header, C);
  ASSERT_FALSE(bool(R));
  EXPECT_NE(
      toString(R.takeError()).find("continuation configuration unavailable"),
      std::string::npos);
}
