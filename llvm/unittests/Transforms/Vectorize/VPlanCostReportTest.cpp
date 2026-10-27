//===- VPlanCostReportTest.cpp - Passive VPlan reporting tests
//--------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Analysis/TargetTransformInfoImpl.h"
#include "llvm/Analysis/VPlanCostProfile.h"
#include "llvm/AsmParser/Parser.h"
#include "llvm/IR/Module.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/SaveAndRestore.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Transforms/Vectorize/LoopVectorize.h"
#include "llvm/Transforms/Vectorize/VPlanBackendFeedback.h"
#include "gtest/gtest.h"

using namespace llvm;

#if !defined(NDEBUG) || defined(LLVM_ENABLE_DUMP)
namespace {

// Record both query order and results, independently of the report observer.
class RecordingTTI : public TargetTransformInfoImplCRTPBase<RecordingTTI> {
  using Base = TargetTransformInfoImplCRTPBase<RecordingTTI>;
  std::vector<std::string> &Queries;
  bool FailLaterProfile;

  InstructionCost record(StringRef Name, unsigned Opcode, Type *Ty,
                         InstructionCost Cost) const {
    if (FailLaterProfile && VPlanCostProfileScope::active() && Ty &&
        isa<VectorType>(Ty) &&
        cast<VectorType>(Ty)->getElementCount().getKnownMinValue() >= 4 &&
        Name == "arithmetic")
      Cost = InstructionCost::getInvalid();
    std::string Text;
    raw_string_ostream OS(Text);
    OS << Name << ' ' << Opcode << ' ';
    if (Ty)
      OS << *Ty;
    OS << " = " << Cost;
    Queries.push_back(std::move(Text));
    return Cost;
  }

public:
  RecordingTTI(const DataLayout &DL, std::vector<std::string> &Queries,
               bool FailLaterProfile = false)
      : Base(DL), Queries(Queries), FailLaterProfile(FailLaterProfile) {}

  TypeSize getRegisterBitWidth(TTI::RegisterKind K) const override {
    return TypeSize::get(128, K == TTI::RGK_ScalableVector);
  }

  unsigned getEpilogueVectorizationMinVF() const override { return 2; }
  bool preferEpilogueVectorization(ElementCount) const override { return true; }
  InstructionCost getSpillReloadCost(const TTI::SpillReloadAccess &A,
                                     TTI::TargetCostKind) const override {
    return record("spill", 0, A.AccessType, InstructionCost(1));
  }

  InstructionCost
  getArithmeticInstrCost(unsigned Opcode, Type *Ty, TTI::TargetCostKind Kind,
                         TTI::OperandValueInfo Op1, TTI::OperandValueInfo Op2,
                         ArrayRef<const Value *> Args,
                         const Instruction *I = nullptr) const override {
    return record(
        "arithmetic", Opcode, Ty,
        Base::getArithmeticInstrCost(Opcode, Ty, Kind, Op1, Op2, Args, I));
  }

  InstructionCost getMemoryOpCost(unsigned Opcode, Type *Ty, Align Alignment,
                                  unsigned AS, TTI::TargetCostKind Kind,
                                  TTI::OperandValueInfo Info,
                                  const Instruction *I) const override {
    return record(
        "memory", Opcode, Ty,
        Base::getMemoryOpCost(Opcode, Ty, Alignment, AS, Kind, Info, I));
  }

  InstructionCost
  getCFInstrCost(unsigned Opcode, TTI::TargetCostKind Kind,
                 const Instruction *I = nullptr) const override {
    return record("control", Opcode, nullptr,
                  Base::getCFInstrCost(Opcode, Kind, I));
  }

  InstructionCost getCmpSelInstrCost(unsigned Opcode, Type *Ty, Type *CondTy,
                                     CmpInst::Predicate Pred,
                                     TTI::TargetCostKind Kind,
                                     TTI::OperandValueInfo Op1,
                                     TTI::OperandValueInfo Op2,
                                     const Instruction *I) const override {
    return record(
        "compare", Opcode, Ty,
        Base::getCmpSelInstrCost(Opcode, Ty, CondTy, Pred, Kind, Op1, Op2, I));
  }

  InstructionCost getCastInstrCost(unsigned Opcode, Type *Dst, Type *Src,
                                   TTI::CastContextHint Hint,
                                   TTI::TargetCostKind Kind,
                                   const Instruction *I) const override {
    return record("cast", Opcode, Dst,
                  Base::getCastInstrCost(Opcode, Dst, Src, Hint, Kind, I));
  }

  InstructionCost
  getAddressComputationCost(Type *Ty, ScalarEvolution *SE, const SCEV *Expr,
                            TTI::TargetCostKind Kind) const override {
    return record("address", 0, Ty,
                  Base::getAddressComputationCost(Ty, SE, Expr, Kind));
  }

  InstructionCost
  getScalarizationOverhead(VectorType *Ty, const APInt &Elts, bool Insert,
                           bool Extract, TTI::TargetCostKind Kind,
                           bool Poison = true, ArrayRef<Value *> VL = {},
                           TTI::VectorInstrContext VIC =
                               TTI::VectorInstrContext::None) const override {
    return record("scalarization", 0, Ty,
                  Base::getScalarizationOverhead(Ty, Elts, Insert, Extract,
                                                 Kind, Poison, VL, VIC));
  }
};

// A provider can fail before any observation, after partial success, or during
// epilogue preparation. None of those attempts may leak into the native report.
TEST(VPlanCostReportTest, ReportingDoesNotQueryCostsOrChangeIR) {
  // The flags are private to LoopVectorize.cpp. Restore their values after each
  // run so this test does not change the configuration of other vectorizer
  // tests.
  auto &Options = cl::getRegisteredOptions();
  ASSERT_TRUE(Options.contains("print-vplans"));
  ASSERT_TRUE(Options.contains("print-detailed-vplans"));
  auto &Summary = *static_cast<cl::opt<bool> *>(Options["print-vplans"]);
  auto &Detailed =
      *static_cast<cl::opt<bool> *>(Options["print-detailed-vplans"]);
  auto &Master = *static_cast<cl::opt<bool> *>(Options["vplan-backend"]);
  auto &ForceAll =
      *static_cast<cl::opt<bool> *>(Options["vplan-backend-force-all"]);
  auto &Epilogues =
      *static_cast<cl::opt<bool> *>(Options["enable-epilogue-vectorization"]);
  SaveAndRestore<bool> SaveForce(ForceAll.getValue(), true);
  SaveAndRestore<bool> SaveEpilogues(Epilogues.getValue(), true);
  for (bool Batch : {false, true}) {
    std::string NativeReports[4], NativeIR;
    // 0=native, 1=success, 2=first query fails, 3=second query fails,
    // 4=epilogue fails after successful main selection,
    // 5=first query fails before a later profile preparation error.
    for (unsigned Scenario = 0; Scenario != 6; ++Scenario) {
      SaveAndRestore<bool> SaveMaster(Master.getValue(), Scenario != 0);
      std::vector<std::string> ReferenceQueries, ReferenceProbes;
      std::string ReferenceIR;
      for (unsigned Mode = 0; Mode != 4; ++Mode) {
        SaveAndRestore<bool> SaveSummary(Summary.getValue(), Mode & 1);
        SaveAndRestore<bool> SaveDetailed(Detailed.getValue(), Mode & 2);
        LLVMContext Context;
        SMDiagnostic Error;
        auto M = parseAssemblyString(R"(
      target datalayout = "e-p:64:64-i64:64-n8:16:32:64-S128"
      target triple = "riscv64"
      define void @add(ptr noalias %a, ptr noalias %b, i64 %n) {
      entry:
        br label %loop
      loop:
        %iv = phi i64 [ 0, %entry ], [ %next, %loop ]
        %pa = getelementptr i32, ptr %a, i64 %iv
        %pb = getelementptr i32, ptr %b, i64 %iv
        %x = load i32, ptr %pa, align 4
        %y = add i32 %x, 3
        store i32 %y, ptr %pb, align 4
        %next = add nuw i64 %iv, 1
        %done = icmp eq i64 %next, %n
        br i1 %done, label %exit, label %loop
      exit:
        ret void
      }
    )",
                                     Error, Context);
        ASSERT_TRUE(M);
        std::vector<std::string> Queries, Probes;
        bool SawEpilogue = false;
        PassBuilder PB;
        LoopAnalysisManager LAM;
        FunctionAnalysisManager FAM;
        CGSCCAnalysisManager CGAM;
        ModuleAnalysisManager MAM;
        FAM.registerPass([&] {
          return TargetIRAnalysis([&](const Function &F) {
            return TargetTransformInfo(std::make_unique<RecordingTTI>(
                F.getDataLayout(), Queries, Scenario == 5));
          });
        });
        FAM.registerPass([&] {
          return VPlanBackendFeedbackAnalysis(
              [&](const Function &, const BasicBlock &,
                  ArrayRef<VPlanBackendCandidate> Candidates)
                  -> Expected<VPlanBackendFeedback::Batch> {
                VPlanBackendFeedback::Batch Results;
                for (const auto &C : Candidates) {
                  auto Query = [&]() -> Expected<VPlanBackendResult> {
                    Probes.push_back(C.ID);
                    SawEpilogue |= C.IsEpilogue;
                    if (Scenario == 2 || Scenario == 5 ||
                        (Scenario == 3 && Probes.size() == 2) ||
                        (Scenario == 4 && C.IsEpilogue))
                      return createStringError("test provider failure");
                    VPlanBackendResult R;
                    R.Candidate = C.ID;
                    R.VF = C.VF;
                    R.IC = C.IC;
                    R.IsEpilogue = C.IsEpilogue;
                    R.IterationMapping = true;
                    // A cleanup width of three bodies exercises exact rational
                    // output.
                    R.IterationWidth = C.VF.getKnownMinValue() * C.IC * 3;
                    R.Spills.push_back({false, 8, true, 8, 0, true, 1, false});
                    return R;
                  };
                  Results.emplace_back(Query());
                }
                return Results;
              },
              [&](const Function &) { return Batch; });
        });
        PB.registerModuleAnalyses(MAM);
        PB.registerCGSCCAnalyses(CGAM);
        PB.registerFunctionAnalyses(FAM);
        PB.registerLoopAnalyses(LAM);
        PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);
        FunctionPassManager FPM;
        FPM.addPass(LoopVectorizePass());
        ModulePassManager MPM;
        MPM.addPass(createModuleToFunctionPassAdaptor(std::move(FPM)));
        testing::internal::CaptureStderr();
        MPM.run(*M, MAM);
        std::string Report = testing::internal::GetCapturedStderr();
        std::string IR;
        raw_string_ostream OS(IR);
        M->print(OS, nullptr);
        EXPECT_NE(IR.find("vector.body"), std::string::npos);
        ASSERT_FALSE(Queries.empty());
        if (Mode == 0) {
          ReferenceProbes = Probes;
          ReferenceQueries = Queries;
          ReferenceIR = IR;
          EXPECT_TRUE(Report.empty());
        } else {
          EXPECT_EQ(ReferenceProbes, Probes) << "reporting mode " << Mode;
          EXPECT_EQ(ReferenceQueries, Queries) << "reporting mode " << Mode;
          EXPECT_EQ(ReferenceIR, IR) << "reporting mode " << Mode;
          EXPECT_NE(Report.find("cost-per-lane"), std::string::npos);
          EXPECT_NE(Report.find("outcome=vectorization-emitted"),
                    std::string::npos);
        }
        if (Scenario == 0) {
          NativeReports[Mode] = Report;
          NativeIR = IR;
          EXPECT_TRUE(Probes.empty());
        } else {
          EXPECT_FALSE(Probes.empty());
          if (Scenario == 3 || Scenario == 4)
            EXPECT_GE(Probes.size(), 2u);
          if (Scenario == 4)
            EXPECT_TRUE(SawEpilogue);
          if (Scenario == 5)
            EXPECT_EQ(Probes.size(), 1u);
          if (Scenario >= 2) {
            EXPECT_EQ(NativeIR, IR);
            EXPECT_EQ(NativeReports[Mode], Report);
          } else if (Mode) {
            EXPECT_NE(Report.find("model=tti-real-vector-spill-v1"),
                      std::string::npos);
            EXPECT_NE(Report.find("phase=epilogue"), std::string::npos);
            if (Mode & 2)
              EXPECT_NE(Report.find("B=L-Ev+Sv="), std::string::npos);
          }
        }
      }
    }
  }
}
} // namespace
#endif
