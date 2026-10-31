// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "XiangShanV2TargetTransformInfo.h"
#include "llvm/Analysis/VPlanCostProfile.h"
#include "llvm/AsmParser/Parser.h"
#include "llvm/IR/Verifier.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/SaveAndRestore.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Transforms/Vectorize/LoopVectorize.h"
#include "llvm/Transforms/Vectorize/VPlanBackendFeedback.h"
#include "gtest/gtest.h"
using namespace llvm;
namespace {
class ExposedTTI : public XiangShanV2TTIImpl {
public:
  using RISCVTTIImpl::getRISCVInstructionCost;
  using XiangShanV2TTIImpl::XiangShanV2TTIImpl;
};
class XiangShanV2TTITest : public testing::Test {
protected:
  LLVMContext C;
  std::unique_ptr<TargetMachine> TM;
  std::unique_ptr<Module> M;
  Function *F;
  void SetUp() override {
    LLVMInitializeRISCVTargetInfo();
    LLVMInitializeRISCVTarget();
    LLVMInitializeRISCVTargetMC();
    Triple TT("riscv64-unknown-elf");
    std::string E;
    auto *T = TargetRegistry::lookupTarget("", TT, E);
    ASSERT_NE(T, nullptr);
    TM.reset(T->createTargetMachine(TT, "xiangshan-kunminghu", "+v",
                                    TargetOptions(), std::nullopt));
    SMDiagnostic D;
    M = parseAssemblyString("define void @f() vscale_range(2,2) { ret void }",
                            D, C);
    ASSERT_NE(M, nullptr);
    M->setDataLayout(TM->createDataLayout());
    F = M->getFunction("f");
  }
};
} // namespace
TEST_F(XiangShanV2TTITest, ArithmeticMemoryAndSpillScopes) {
  auto TTI = TM->getTargetTransformInfo(*F);
  EXPECT_EQ(TTI.getVPlanCostProfileName(), "xiangshan-v2-128");
  auto *FT = ScalableVectorType::get(Type::getFloatTy(C), 4);
  auto *IT = ScalableVectorType::get(Type::getInt32Ty(C), 4);
  auto Kind = TargetTransformInfo::TCK_RecipThroughput;
  auto Native = TTI.getArithmeticInstrCost(Instruction::FAdd, FT, Kind);
  auto Latency = TTI.getArithmeticInstrCost(Instruction::FDiv, FT,
                                            TargetTransformInfo::TCK_Latency);
  EXPECT_EQ(Native, 4);
  {
    VPlanCostProfileScope S(true);
    EXPECT_EQ(TTI.getArithmeticInstrCost(Instruction::FAdd, FT, Kind), 2);
    EXPECT_EQ(TTI.getArithmeticInstrCost(Instruction::FDiv, FT, Kind), 20);
    EXPECT_EQ(TTI.getArithmeticInstrCost(Instruction::SDiv, IT, Kind), 34);
    EXPECT_EQ(TTI.getArithmeticInstrCost(Instruction::UDiv, IT, Kind), 34);
    EXPECT_EQ(TTI.getMemoryOpCost(Instruction::Load, FT, Align(4), 0, Kind), 3);
    EXPECT_EQ(TTI.getArithmeticInstrCost(Instruction::FDiv, FT,
                                         TargetTransformInfo::TCK_Latency),
              Latency);
    for (unsigned Group : {1, 2, 4, 8})
      for (bool Load : {false, true}) {
        auto *Ty = ScalableVectorType::get(Type::getInt8Ty(C), Group * 8);
        EXPECT_EQ(
            TTI.getRegisterClassSpillReloadCost(
                TTI.getRegisterClassForType(true, Ty), Load, {Group, 1}, Kind),
            Group + 1);
      }
    {
      VPlanCostProfileScope P(false);
      EXPECT_EQ(TTI.getArithmeticInstrCost(Instruction::FAdd, FT, Kind),
                Native);
    }
  }
  EXPECT_EQ(TTI.getArithmeticInstrCost(Instruction::FAdd, FT, Kind), Native);
}
TEST_F(XiangShanV2TTITest, MemoryPathsAndUniformTransfer) {
  auto TTI = TM->getTargetTransformInfo(*F);
  auto *FT = ScalableVectorType::get(Type::getFloatTy(C), 4);
  auto K = TargetTransformInfo::TCK_RecipThroughput;
  VPlanCostProfileScope S(true);
  EXPECT_EQ(
      TTI.getArithmeticInstrCost(
          Instruction::FAdd, FT, K,
          {TargetTransformInfo::OK_AnyValue, TargetTransformInfo::OP_None},
          {TargetTransformInfo::OK_UniformValue, TargetTransformInfo::OP_None}),
      3);
  for (auto ID : {Intrinsic::experimental_vp_strided_load,
                  Intrinsic::experimental_vp_strided_store})
    EXPECT_EQ(TTI.getMemIntrinsicInstrCost(
                  MemIntrinsicCostAttributes(ID, FT, Align(4)), K),
              10);
  for (auto ID : {Intrinsic::masked_gather, Intrinsic::masked_scatter})
    EXPECT_EQ(TTI.getMemIntrinsicInstrCost(
                  MemIntrinsicCostAttributes(ID, FT, Align(4)), K),
              8);
  EXPECT_EQ(TTI.getInterleavedMemoryOpCost(Instruction::Load, FT, 2, {0, 1},
                                           Align(4), 0, K),
            65);
  EXPECT_EQ(TTI.getInterleavedMemoryOpCost(Instruction::Store, FT, 2, {},
                                           Align(4), 0, K),
            33);
}
TEST_F(XiangShanV2TTITest, EffectiveTuneAndVectorLength) {
  auto *FT = ScalableVectorType::get(Type::getFloatTy(C), 4);
  VPlanCostProfileScope S(true);
  for (StringRef Tune : {"generic-rv64", "xiangshan-nanhu"}) {
    F->addFnAttr("tune-cpu", Tune);
    auto TTI = TM->getTargetTransformInfo(*F);
    EXPECT_EQ(TTI.getVPlanCostProfileName(), "native");
    EXPECT_EQ(
        TTI.getArithmeticInstrCost(Instruction::FAdd, FT,
                                   TargetTransformInfo::TCK_RecipThroughput),
        4);
    EXPECT_EQ(TTI.getRegisterClassSpillReloadCost(
                  TTI.getRegisterClassForType(true, FT), true, {2, 1},
                  TargetTransformInfo::TCK_RecipThroughput),
              2);
  }
  F->addFnAttr("target-cpu", "generic-rv64");
  F->addFnAttr("tune-cpu", "xiangshan-kunminghu");
  EXPECT_EQ(TM->getTargetTransformInfo(*F).getVPlanCostProfileName(),
            "xiangshan-v2-128");
  F->removeFnAttr(Attribute::VScaleRange);
  EXPECT_EQ(TM->getTargetTransformInfo(*F).getVPlanCostProfileName(), "native");
  F->addFnAttr(Attribute::getWithVScaleRangeArgs(C, 4, 4));
  EXPECT_EQ(TM->getTargetTransformInfo(*F).getVPlanCostProfileName(), "native");
}
TEST_F(XiangShanV2TTITest, OpcodeFormulaBoundariesAndInternalDispatch) {
  ExposedTTI TTI(static_cast<RISCVTargetMachine *>(TM.get()), *F);
  auto K = TargetTransformInfo::TCK_RecipThroughput;
  auto Cost = [&](unsigned Op, MVT VT) {
    return TTI.getRISCVInstructionCost({Op}, VT, K);
  };
  auto NativeGather = Cost(RISCV::VRGATHER_VV, MVT::nxv4i32);
  VPlanCostProfileScope S(true);
  for (auto [VT, L] : {std::pair{MVT::nxv2i32, 1}, std::pair{MVT::nxv4i32, 2},
                       std::pair{MVT::nxv8i32, 4}}) {
    for (unsigned Op : {RISCV::VSLIDEUP_VI, RISCV::VSLIDEUP_VX,
                        RISCV::VSLIDEDOWN_VI, RISCV::VSLIDEDOWN_VX})
      EXPECT_EQ(Cost(Op, VT), L * (L + 1) / 2 + 1);
    EXPECT_EQ(Cost(RISCV::VRGATHER_VI, VT), L * L + 1);
    EXPECT_EQ(Cost(RISCV::VNSRL_WI, VT), 2 * L + 1);
  }
  for (auto [VT, Div, Sqrt] :
       {std::tuple{MVT::nxv4f16, 8, 7}, std::tuple{MVT::nxv2f32, 10, 10},
        std::tuple{MVT::nxv1f64, 15, 17}}) {
    EXPECT_EQ(Cost(RISCV::VFDIV_VV, VT), Div);
    EXPECT_EQ(Cost(RISCV::VFDIV_VF, VT), Div + 1);
    EXPECT_EQ(Cost(RISCV::VFRDIV_VF, VT), Div + 1);
    EXPECT_EQ(Cost(RISCV::VFSQRT_V, VT), Sqrt);
  }
  for (auto [VT, Div] :
       {std::pair{MVT::nxv8i8, 11}, std::pair{MVT::nxv4i16, 13},
        std::pair{MVT::nxv2i32, 17}, std::pair{MVT::nxv1i64, 25}}) {
    EXPECT_EQ(Cost(RISCV::VDIV_VV, VT), Div);
    EXPECT_EQ(Cost(RISCV::VREM_VV, VT), Div);
  }
  EXPECT_EQ(Cost(RISCV::VRGATHER_VV, MVT::nxv4i32), NativeGather);
  EXPECT_EQ(Cost(RISCV::VDIVU_VV, MVT::nxv4i32), 34);
}

// Exercise the normally target-disabled epilogue comparison without changing
// production RISC-V preferences. The probe still uses the real native target.
namespace {
class EpilogueTTI : public XiangShanV2TTIImpl {
public:
  using XiangShanV2TTIImpl::XiangShanV2TTIImpl;
  bool preferEpilogueVectorization(ElementCount) const override { return true; }
  unsigned getEpilogueVectorizationMinVF() const override { return 1; }
};
} // namespace
TEST_F(XiangShanV2TTITest, EpilogueObservationsAndTransactionalFallback) {
  auto &Opts = cl::getRegisteredOptions();
  auto &Enable = *static_cast<cl::opt<bool> *>(Opts["vplan-backend"]);
  auto &ForceAll =
      *static_cast<cl::opt<bool> *>(Opts["vplan-backend-force-all"]);
  auto &IC = *static_cast<cl::opt<unsigned> *>(Opts["force-vector-interleave"]);
  SaveAndRestore<bool> SaveEnable(Enable.getValue());
  SaveAndRestore<bool> SaveForceAll(ForceAll.getValue(), true);
  SaveAndRestore<unsigned> SaveIC(IC.getValue(), 2);
  unsigned EpilogueQueries = 0, MainQueries = 0;
  auto Run = [&](bool Enabled, unsigned FailureMode) {
    unsigned ThisMainQueries = 0;
    Enable = Enabled;
    SMDiagnostic D;
    auto Module = parseAssemblyString(R"(
      target triple = "riscv64-unknown-elf"
      define void @kernel(ptr noalias %a, ptr noalias %b, i64 %n) vscale_range(2,2) {
      entry: br label %loop
      loop:
        %iv = phi i64 [0, %entry], [%next, %loop]
        %p = getelementptr float, ptr %a, i64 %iv
        %q = getelementptr float, ptr %b, i64 %iv
        %x = load float, ptr %p, align 4
        %y = fadd float %x, 1.0
        store float %y, ptr %q, align 4
        %next = add nuw i64 %iv, 1
        %done = icmp eq i64 %next, %n
        br i1 %done, label %exit, label %loop, !llvm.loop !0
      exit: ret void
      }
      !0 = distinct !{!0, !1, !2}
      !1 = !{!"llvm.loop.vectorize.scalable.enable", i1 false}
      !2 = !{!"llvm.loop.vectorize.enable", i1 true}
    )",
                                      D, C);
    EXPECT_TRUE(Module);
    Module->setDataLayout(TM->createDataLayout());
    auto &Fn = *Module->getFunction("kernel");
    PassBuilder PB(TM.get());
    LoopAnalysisManager LAM;
    FunctionAnalysisManager FAM;
    CGSCCAnalysisManager CGAM;
    ModuleAnalysisManager MAM;
    FAM.registerPass([&] {
      return TargetIRAnalysis([&](const Function &F) {
        return TargetTransformInfo(std::make_unique<EpilogueTTI>(
            static_cast<RISCVTargetMachine *>(TM.get()), F));
      });
    });
    PB.registerModuleAnalyses(MAM);
    PB.registerCGSCCAnalyses(CGAM);
    PB.registerFunctionAnalyses(FAM);
    PB.registerLoopAnalyses(LAM);
    PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);
    auto &Service = FAM.getResult<VPlanBackendFeedbackAnalysis>(Fn);
    Service = VPlanBackendFeedback(
        [&, Native = Service](const Function &F, const BasicBlock &H,
                              ArrayRef<VPlanBackendCandidate> Candidates)
            -> Expected<VPlanBackendFeedback::Batch> {
          VPlanBackendFeedback::Batch Results;
          for (const auto &Candidate : Candidates) {
            auto Query = [&]() -> Expected<VPlanBackendResult> {
              EXPECT_FALSE(VPlanCostProfileScope::active());
              if (Candidate.IsEpilogue) {
                ++EpilogueQueries;
                EXPECT_EQ(Candidate.IC, 1u);
                EXPECT_EQ(Candidate.MainIC, 2u);
                if (FailureMode == 1)
                  return createStringError("injected epilogue failure");
              } else {
                ++MainQueries;
                if (++ThisMainQueries == 2 && FailureMode == 2)
                  return createStringError(
                      "injected second main candidate failure");
              }
              auto O = Native.get(F, H, Candidate);
              EXPECT_TRUE(bool(O));
              if (O) {
                EXPECT_TRUE(O->IterationMapping);
                EXPECT_EQ(O->Stage, "post-stack-slot-coloring");
                EXPECT_EQ(O->IsEpilogue, Candidate.IsEpilogue);
                EXPECT_EQ(O->IC, Candidate.IC);
                if (FailureMode == 3)
                  O->Candidate = "incorrect identity";
                if (FailureMode == 4)
                  O->IterationMapping = false;
              }
              return O;
            };
            Results.emplace_back(Query());
          }
          return Results;
        });
    FunctionPassManager FPM;
    FPM.addPass(LoopVectorizePass());
    FPM.run(Fn, FAM);
    EXPECT_FALSE(verifyModule(*Module, &errs()));
    std::string IR;
    raw_string_ostream OS(IR);
    Module->print(OS, nullptr);
    return IR;
  };
  auto Native = Run(false, false);
  EXPECT_EQ(MainQueries, 0u);
  EXPECT_EQ(EpilogueQueries, 0u);
  auto Hybrid = Run(true, false);
  EXPECT_GT(MainQueries, 0u);
  EXPECT_GT(EpilogueQueries, 0u);
  EXPECT_NE(Hybrid.find("vec.epilog"), std::string::npos);
  for (unsigned FailureMode : {1u, 2u, 3u, 4u}) {
    auto Fallback = Run(true, FailureMode);
    EXPECT_EQ(Fallback, Native) << "failure mode " << FailureMode;
  }
}

TEST_F(XiangShanV2TTITest, MIRSheetSelectionUsesEffectiveTuneAndVLEN) {
  auto Info = TM->getTargetMIRInfo(*F);
  ASSERT_TRUE(Info);
  EXPECT_EQ(Info->getModelName(), "xiangshan-direct-v1");
  F->addFnAttr("tune-cpu", "generic-rv64");
  ASSERT_TRUE(TM->getTargetMIRInfo(*F));
  EXPECT_EQ(TM->getTargetMIRInfo(*F)->getModelName(),
            "riscv-generic-direct-v1");
  F->removeFnAttr("tune-cpu");
  F->addFnAttr(Attribute::getWithVScaleRangeArgs(C, 4, 4));
  ASSERT_TRUE(TM->getTargetMIRInfo(*F));
  EXPECT_EQ(TM->getTargetMIRInfo(*F)->getModelName(),
            "riscv-generic-direct-v1");
}

TEST_F(XiangShanV2TTITest, AggregateSpillUnitsAndScalarScopes) {
  auto Tuned = TM->getTargetTransformInfo(*F);
  F->addFnAttr("tune-cpu", "generic-rv64");
  auto Native = TM->getTargetTransformInfo(*F);
  auto K = TargetTransformInfo::TCK_RecipThroughput;
  unsigned V = Tuned.getRegisterClassForType(true);
  unsigned S = Tuned.getRegisterClassForType(false);
  auto Pair = [&](const TargetTransformInfo &TTI, uint64_t Q, uint64_t A) {
    return TTI.getRegisterClassSpillReloadCost(V, false, {Q, A}, K) +
           TTI.getRegisterClassSpillReloadCost(V, true, {Q, A}, K);
  };
  auto Baseline =
      Tuned.getArithmeticInstrCost(Instruction::SDiv, Type::getInt64Ty(C), K);
  {
    VPlanCostProfileScope Scope(true);
    EXPECT_EQ(Pair(Native, 4, 4), 8);
    EXPECT_EQ(Pair(Tuned, 4, 4), 16);
    EXPECT_EQ(Pair(Native, 4, 1), 8);
    EXPECT_EQ(Pair(Tuned, 4, 1), 10);
    EXPECT_EQ(Pair(Tuned, 0, 0), 0);
    for (const auto &TTI : {&Native, &Tuned}) {
      EXPECT_FALSE(Pair(*TTI, 1, 2).isValid());
      EXPECT_FALSE(Pair(*TTI, 1, 0).isValid());
      EXPECT_FALSE(Pair(*TTI, UINT64_MAX, 1).isValid());
    }
    EXPECT_EQ(Tuned.getRegisterClassSpillCost(S, K), 2);
    EXPECT_EQ(Tuned.getRegisterClassReloadCost(S, K), 1);
    unsigned FP = Tuned.getRegisterClassForType(false, Type::getDoubleTy(C));
    EXPECT_EQ(Tuned.getRegisterClassSpillCost(FP, K), 2);
    EXPECT_EQ(Tuned.getRegisterClassReloadCost(FP, K), 1);
    EXPECT_EQ(
        Tuned.getArithmeticInstrCost(Instruction::SDiv, Type::getInt64Ty(C), K),
        23);
    EXPECT_EQ(Tuned.getArithmeticInstrCost(Instruction::FDiv,
                                           Type::getDoubleTy(C), K),
              14);
    for (unsigned G : {1, 2, 4, 8}) {
      EXPECT_EQ(Pair(Tuned, G, 1), 2 * (G + 1));
      EXPECT_EQ(Pair(Native, G, 1), 2 * G);
    }
  }
  EXPECT_EQ(
      Tuned.getArithmeticInstrCost(Instruction::SDiv, Type::getInt64Ty(C), K),
      Baseline);
}

TEST_F(XiangShanV2TTITest, OpcodeAdapterMatchesDirectSheet) {
  ExposedTTI TTI(static_cast<RISCVTargetMachine *>(TM.get()), *F);
  auto K = TargetTransformInfo::TCK_RecipThroughput;
  VPlanCostProfileScope Scope(true);
  struct Operation {
    unsigned Opcode;
    const char *Name;
  };
  for (auto [VT, Group, SEW] :
       {std::tuple{MVT::nxv1i8, 1u, 8u}, std::tuple{MVT::nxv2i32, 8u, 32u},
        std::tuple{MVT::nxv8i32, 32u, 32u}}) {
    for (Operation Op : {Operation{RISCV::VADD_VV, "VADD_VV"},
                         Operation{RISCV::VDIVU_VV, "VDIVU_VV"},
                         Operation{RISCV::VRGATHEREI16_VV, "VRGATHEREI16_VV"},
                         Operation{RISCV::VSLIDEUP_VX, "VSLIDEUP_VX"},
                         Operation{RISCV::VREDSUM_VS, "VREDSUM_VS"}}) {
      VPlanMIRInstruction Q;
      Q.BaseOpcode = Op.Name;
      Q.Vector = true;
      Q.LMUL8 = Group;
      Q.SEW = SEW;
      auto C = XiangShanCostSheet().getInstructionCost(Q);
      ASSERT_TRUE(bool(C));
      EXPECT_EQ(TTI.getRISCVInstructionCost({Op.Opcode}, VT, K),
                InstructionCost(C->Numerator) / C->Denominator)
          << Op.Name;
    }
  }
  auto *Half = ScalableVectorType::get(Type::getHalfTy(C), 4);
  auto *Float = ScalableVectorType::get(Type::getFloatTy(C), 4);
  // The narrow source/destination is m1, e16. The wide operand occupies m2.
  EXPECT_EQ(TTI.getCastInstrCost(Instruction::FPExt, Float, Half,
                                 TargetTransformInfo::CastContextHint::None, K),
            2);
  EXPECT_EQ(TTI.getCastInstrCost(Instruction::FPTrunc, Half, Float,
                                 TargetTransformInfo::CastContextHint::None, K),
            2);
}
