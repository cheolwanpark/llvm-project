//===- VPlanRATest.cpp - Backend feedback selection integration tests ------===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "llvm/Analysis/TargetTransformInfoImpl.h"
#include "llvm/AsmParser/Parser.h"
#include "llvm/IR/Module.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/SaveAndRestore.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Transforms/Vectorize/LoopVectorize.h"
#include "llvm/Transforms/Vectorize/VPlanRA.h"
#include "gtest/gtest.h"

using namespace llvm;

namespace {
class TestTTI : public TargetTransformInfoImplCRTPBase<TestTTI> {
public:
  explicit TestTTI(const DataLayout &DL) : TargetTransformInfoImplCRTPBase(DL) {}
  TypeSize getRegisterBitWidth(TTI::RegisterKind K) const override {
    return TypeSize::getFixed(K == TTI::RGK_ScalableVector ? 0 : 128);
  }
};
const char *IR = R"(
  target datalayout = "e-p:64:64-i64:64-n8:16:32:64-S128"
  define void @kernel(ptr noalias %a, ptr noalias %b, i64 %n) {
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
)";

json::Value runLV(StringRef Manifest) {
  LLVMContext Context;
  SMDiagnostic Err;
  auto M = parseAssemblyString(IR, Err, Context);
  EXPECT_TRUE(M);
  PassBuilder PB;
  LoopAnalysisManager LAM;
  FunctionAnalysisManager FAM;
  CGSCCAnalysisManager CGAM;
  ModuleAnalysisManager MAM;
  FAM.registerPass([&] {
    return TargetIRAnalysis([](const Function &F) {
      return TargetTransformInfo(std::make_unique<TestTTI>(F.getDataLayout()));
    });
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
  MPM.run(*M, MAM);
  finishVPlanRA(*M);
  auto Buffer = MemoryBuffer::getFile(Manifest);
  EXPECT_TRUE(bool(Buffer));
  return cantFail(json::parse((*Buffer)->getBuffer()));
}

TEST(VPlanRA, BackendScoresChangeTheActualMainVFSelection) {
  SmallString<128> Dir;
  ASSERT_FALSE(sys::fs::createUniqueDirectory("vplan-ra-unit", Dir));
  SmallString<128> Manifest(Dir), Feedback(Dir);
  sys::path::append(Manifest, "manifest.json");
  sys::path::append(Feedback, "feedback.json");
  auto &Opts = cl::getRegisteredOptions();
  auto &Out = *static_cast<cl::opt<std::string> *>(Opts["vplan-candidates-output"]);
  auto &In = *static_cast<cl::opt<std::string> *>(Opts["vplan-ra-feedback"]);
  auto &ID = *static_cast<cl::opt<std::string> *>(Opts["vplan-ra-run-id"]);
  auto &IC = *static_cast<cl::opt<unsigned> *>(Opts["force-vector-interleave"]);
  auto &Epi = *static_cast<cl::opt<bool> *>(Opts["enable-epilogue-vectorization"]);
  SaveAndRestore<std::string> SaveOut(Out.getValue(), Manifest.str().str());
  SaveAndRestore<std::string> SaveIn(In.getValue());
  SaveAndRestore<std::string> SaveID(ID.getValue(), "unit-test");
  SaveAndRestore<unsigned> SaveIC(IC.getValue(), 1);
  SaveAndRestore<bool> SaveEpi(Epi.getValue(), false);
  auto Baseline = runLV(Manifest);
  auto *Rows = Baseline.getAsObject()->getArray("candidates");
  ASSERT_GE(Rows->size(), 3u);
  // Feed computed scores directly into the real vectorizer, including a scalar
  // win.
  for (StringRef Wanted : {"f1", "f2", "f4"}) {
    json::Array FeedbackRows;
    for (auto &Row : *Rows) {
      const auto &O = *Row.getAsObject();
      if (O.getBoolean("probeable") != true)
        continue;
      FeedbackRows.push_back(json::Object{
          {"id", O.getString("id")->str()},
          {"cost", json::Object{{"body_quarters", 4},
                                {"scalar_quarters", 4},
                                {"score_quarters",
                                 O.getString("vf") == Wanted ? 4 : 40000},
                                {"divisor", 1},
                                {"width", 1},
                                {"scalar_width", 1},
                                {"kind", "cost-per-lane"}}},
          {"selection", json::Object{{"id", O.getString("id")->str()},
                                     {"ic", 1},
                                     {"epilogue_vf", "f0"},
                                     {"emitted", true}}}});
    }
    writeVPlanRAJSON(Feedback,
                     json::Object{{"version", 2},
                                  {"run_id", "unit-test"},
                                  {"candidates", std::move(FeedbackRows)}});
    In = Feedback.str().str();
    auto Final = runLV(Manifest);
    auto *Selected = Final.getAsObject()->getArray("selections");
    ASSERT_EQ(Selected->size(), 1u);
    EXPECT_TRUE((*Selected)[0].getAsObject()->getString("id")->ends_with(Wanted));
    EXPECT_EQ((*Selected)[0].getAsObject()->getBoolean("emitted"),
              Wanted != "f1");
  }
  EXPECT_FALSE(sys::fs::remove_directories(Dir));
}
} // namespace
