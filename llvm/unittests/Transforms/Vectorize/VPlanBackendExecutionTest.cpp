// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "../lib/Passes/VPlanBackendProbe.h"
#include "VPlanTestBase.h"
#include "../lib/Transforms/Vectorize/VPlan.h"
#include "../lib/Transforms/Vectorize/VPlanBackendCostModel.h"
#include "llvm/Analysis/TargetTransformInfoImpl.h"
#include "llvm/Analysis/AssumptionCache.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/ScalarEvolution.h"
#include "llvm/IR/RelatedBlock.h"
#include "llvm/IR/Verifier.h"
#include "llvm/Transforms/Utils/UnrollLoop.h"
#include "llvm/Transforms/Scalar/SimplifyCFG.h"
#include "llvm/Analysis/VPlanCostProfile.h"
#include "llvm/AsmParser/Parser.h"
#include "llvm/IR/Module.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/SaveAndRestore.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Transforms/Vectorize/LoopVectorize.h"
#include "gtest/gtest.h"
#include <condition_variable>
#include <mutex>
using namespace llvm;

namespace llvm {
class VPlanBackendCostModelTestAccess {
public:
  using Prepared = VPlanBackendCostModel::PreparedCandidate;
  static Prepared candidate(VPlan &P, unsigned VF, unsigned Cost, bool Query) {
    VPlanBackendCandidate C{std::to_string(VF), 0, ElementCount::getFixed(VF),
                            true, false, false};
    return {&P, C, Cost, Cost, 0, 0, VF, {}, Query, true};
  }
  static bool run(VPlanBackendCostModel &M, ArrayRef<Prepared> Cs) {
    return M.addBatch(Cs, VPBackendPruningContext{100, 0, true});
  }
};
}

TEST(VPlanBackendExecution, GateIsConservativeAtPressureAndOverflow) {
  EXPECT_EQ(boundVPlanLiveValues(3, {{1, 0}, {1, 1}, {1, 1}}), 5u);
  EXPECT_FALSE(boundVPlanLiveValues(UINT64_MAX, {{1, 0}}));
  for (auto [Usage, IC, Query] : {std::tuple{15u, 2u, false},
                                 std::tuple{16u, 2u, true}}) {
    VPRegisterUsageBound B;
    B.Known = true;
    B.Usage = Usage;
    B.applyInterleave(IC);
    EXPECT_EQ(B.shouldQuery(), Query);
  }
  VPRegisterUsageBound Unknown;
  EXPECT_TRUE(Unknown.shouldQuery());
  Unknown.Known = true;
  Unknown.Usage = UINT64_MAX;
  Unknown.applyInterleave(2);
  EXPECT_TRUE(Unknown.shouldQuery());
}

namespace {
class GateTTI : public TargetTransformInfoImplBase {
  inline static const DataLayout DL{""};
public:
  GateTTI() : TargetTransformInfoImplBase(DL) {}
  TypeSize getRegisterBitWidth(TargetTransformInfo::RegisterKind) const override {
    return TypeSize::getScalable(64);
  }
  bool isElementTypeLegalForScalableVector(Type *) const override { return true; }
  bool isTypeLegal(Type *) const override { return true; }
  unsigned getNumberOfParts(Type *) const override { return 1; }
  unsigned getRegUsageForType(Type *) const override { return 1; }
};
class BackendGate : public VPlanTestBase {};
}
TEST_F(BackendGate, UnsupportedRecipeCannotBecomeASafeSkip) {
  M->setTargetTriple(Triple("riscv64-unknown-elf"));
  auto &P = getPlan();
  auto *B = P.createVPBasicBlock("body");
  auto *Region = P.createLoopRegion(Type::getInt64Ty(C), DebugLoc(), "loop", B, B);
  VPBlockUtils::connectBlocks(P.getEntry(), Region);
  VPBlockUtils::connectBlocks(Region, P.getScalarHeader());
  auto *X = new VPInstructionWithType(VPInstruction::StepVector, {}, Type::getInt32Ty(C));
  B->appendRecipe(X);
  B->appendRecipe(new VPWidenRecipe(Instruction::Add, {X, X}));
  TargetTransformInfo TTI(std::make_unique<GateTTI>());
  auto Bound = computeVPlanRegisterUsageBound(P, ElementCount::getScalable(2), TTI);
  ASSERT_TRUE(Bound.Known);
  EXPECT_FALSE(Bound.shouldQuery());
  B->appendRecipe(new VPInstruction(VPInstruction::Reverse, {X}));
  Bound = computeVPlanRegisterUsageBound(P, ElementCount::getScalable(2), TTI);
  EXPECT_FALSE(Bound.Known);
  EXPECT_TRUE(Bound.shouldQuery());
}

// A failure can arrive before the winning cost. Dominance, not completion
// order, determines whether that failure invalidates the attempt.
TEST(VPlanBackendExecution, RequiredFailureDiscardsButDominatedFailureDoesNot) {
  LLVMContext C;
  Module M("pruning", C);
  auto *F = Function::Create(FunctionType::get(Type::getVoidTy(C), false),
                             GlobalValue::ExternalLinkage, "f", M);
  auto *H = BasicBlock::Create(C, "loop", F);
  UncondBrInst::Create(H, H);
  VPlan P(H, Type::getInt32Ty(C));
  TargetTransformInfo TTI(M.getDataLayout());
  using Access = VPlanBackendCostModelTestAccess;
  for (bool Dominated : {false, true}) {
    VPlanBackendFeedback Feedback(
        [&](const Function &, const BasicBlock &, ArrayRef<VPlanBackendCandidate> Cs)
            -> Expected<VPlanBackendFeedback::Batch> {
          VPlanBackendFeedback::Batch Results;
          for (const auto &Candidate : Cs) {
            if (Candidate.Control)
              Candidate.Control->Started = true;
            if (Candidate.VF.getFixedValue() == 4)
              Results.emplace_back(createStringError("unavailable"));
            else {
              VPlanBackendResult R;
              R.Candidate = Candidate.ID;
              R.VF = Candidate.VF;
              R.IC = Candidate.IC;
              R.Spill.Status = VPlanBackendObservationStatus::Succeeded;
              R.Spill.IterationMapping = true;
              R.Spill.IterationWidth = Candidate.VF.getFixedValue();
              Results.emplace_back(std::move(R));
            }
          }
          for (unsigned I = Cs.size(); I; --I)
            if (Cs[I - 1].Control && Cs[I - 1].Control->Completed)
              Cs[I - 1].Control->Completed(Results[I - 1]);
          return Results;
        });
    VPlanBackendCostModel Costs(Feedback, TTI, *F, *H);
    auto Winner = Access::candidate(P, 8, Dominated ? 8 : 80, true);
    auto Failure = Access::candidate(P, 4, 8, true);
    EXPECT_EQ(Access::run(Costs, {Winner, Failure}), Dominated) << Costs.failure().str();
    EXPECT_EQ(Costs.failed(), !Dominated);
    EXPECT_EQ(Costs.isPruned(P, ElementCount::getFixed(4)), Dominated);
    EXPECT_EQ(Costs.lookup(P, ElementCount::getFixed(8)) != nullptr, Dominated);
  }
}

TEST(VPlanBackendExecution, CancellationJoinsAndLeavesWorkersReusable) {
  if (!LLVM_ENABLE_THREADS)
    GTEST_SKIP();
  VPlanBackendProbePool Pool(2);
  PassCancellation Cancel;
  std::mutex Mutex;
  std::condition_variable CV;
  bool Requested = false;
  VPlanCostProfileScope CallerScope(true);
  auto Result = Pool.run(2, [&](unsigned I) -> VPlanBackendProbeResult {
    EXPECT_FALSE(VPlanCostProfileScope::active());
    if (I == 1) {
      std::unique_lock<std::mutex> Lock(Mutex);
      CV.wait(Lock, [&] { return Requested; });
      ScopedPassCancellation Scope(&Cancel);
      EXPECT_TRUE(ScopedPassCancellation::check());
      VPlanBackendProbeResult R(createStringError("cancelled"));
      R.Cancelled = true;
      return R;
    }
    return {VPlanBackendResult{}};
  }, [&](unsigned I, const VPlanBackendProbeResult &) {
    if (I == 0) {
      std::lock_guard<std::mutex> Lock(Mutex);
      Cancel.Requested = true;
      Requested = true;
      CV.notify_all();
    }
  });
  ASSERT_EQ(Result.size(), 2u);
  EXPECT_TRUE(Result[0].Observation);
  EXPECT_TRUE(Result[1].Cancelled);
  auto Reused = Pool.run(3, [](unsigned I) -> VPlanBackendProbeResult {
    EXPECT_FALSE(ScopedPassCancellation::check());
    VPlanBackendResult R;
    R.Candidate = std::to_string(I);
    return {std::move(R)};
  });
  ASSERT_EQ(Reused.size(), 3u);
  for (unsigned I = 0; I < Reused.size(); ++I)
    EXPECT_EQ(Reused[I].Observation->Candidate, std::to_string(I));
  EXPECT_TRUE(VPlanCostProfileScope::active());
}

#if !defined(NDEBUG) || defined(LLVM_ENABLE_DUMP)
namespace {
class ReportingTTI : public TargetTransformInfoImplCRTPBase<ReportingTTI> {
  using Base = TargetTransformInfoImplCRTPBase<ReportingTTI>;
  unsigned &Queries;
  bool RejectTuned;
public:
  ReportingTTI(const DataLayout &DL, unsigned &Queries, bool RejectTuned)
      : Base(DL), Queries(Queries), RejectTuned(RejectTuned) {}
  TypeSize getRegisterBitWidth(TTI::RegisterKind K) const override {
    return TypeSize::get(128, K == TTI::RGK_ScalableVector);
  }
  unsigned getEpilogueVectorizationMinVF() const override { return 2; }
  bool preferEpilogueVectorization(ElementCount) const override { return true; }
  InstructionCost getArithmeticInstrCost(
      unsigned Op, Type *Ty, TTI::TargetCostKind Kind, TTI::OperandValueInfo A,
      TTI::OperandValueInfo B, ArrayRef<const Value *> Args,
      const Instruction *I = nullptr) const override {
    ++Queries;
    if (RejectTuned && VPlanCostProfileScope::active() && isa<VectorType>(Ty))
      return InstructionCost::getInvalid();
    return Base::getArithmeticInstrCost(Op, Ty, Kind, A, B, Args, I);
  }
};
}

// Automatic epilogue failures and native preparation failures cannot be
// reliably forced by target flags. Inject only those two failures here.
TEST(VPlanBackendExecution, ReportingAndWholeLoopAttemptAreTransactional) {
  auto &Options = cl::getRegisteredOptions();
  auto flag = [&](StringRef Name) -> bool & {
    return static_cast<cl::opt<bool> *>(Options[Name])->getValue();
  };
  SaveAndRestore Force(flag("vplan-backend-force-all"), true);
  SaveAndRestore Epilogue(flag("enable-epilogue-vectorization"), true);
  std::string NativeIR, NativeReport;
  for (unsigned Scenario : {0u, 1u, 2u}) {
    SaveAndRestore Master(flag("vplan-backend"), Scenario != 0);
    std::string ReferenceIR;
    unsigned ReferenceQueries = 0;
    std::vector<bool> ReferenceProbes;
    for (bool Print : {false, true}) {
      SaveAndRestore Detailed(flag("print-detailed-vplans"), Print);
      LLVMContext C;
      SMDiagnostic E;
      auto M = parseAssemblyString(R"(
        target datalayout = "e-p:64:64-i64:64-n8:16:32:64-S128"
        target triple = "riscv64"
        define void @map(ptr noalias %a, ptr noalias %b, i64 %n) {
        entry: br label %loop
        loop:
          %i = phi i64 [0, %entry], [%next, %loop]
          %src = getelementptr i32, ptr %a, i64 %i
          %dst = getelementptr i32, ptr %b, i64 %i
          %x = load i32, ptr %src
          %y = add i32 %x, 7
          store i32 %y, ptr %dst
          %next = add nuw i64 %i, 1
          %end = icmp eq i64 %next, %n
          br i1 %end, label %exit, label %loop
        exit: ret void
        })", E, C);
      ASSERT_TRUE(M);
      unsigned Queries = 0;
      std::vector<bool> Probes;
      PassBuilder PB;
      LoopAnalysisManager LAM;
      FunctionAnalysisManager FAM;
      CGSCCAnalysisManager CGAM;
      ModuleAnalysisManager MAM;
      FAM.registerPass([&] { return TargetIRAnalysis([&](const Function &F) {
        return TargetTransformInfo(std::make_unique<ReportingTTI>(
            F.getDataLayout(), Queries, Scenario == 2));
      }); });
      FAM.registerPass([&] { return VPlanBackendFeedbackAnalysis(
          [&](const Function &, const BasicBlock &, ArrayRef<VPlanBackendCandidate> Cs)
              -> Expected<VPlanBackendFeedback::Batch> {
            VPlanBackendFeedback::Batch Results;
            for (const auto &Candidate : Cs) {
              Probes.push_back(Candidate.IsEpilogue);
              if (Candidate.IsEpilogue)
                Results.emplace_back(createStringError("epilogue unavailable"));
              else {
                VPlanBackendResult R;
                R.Candidate = Candidate.ID;
                R.VF = Candidate.VF;
                R.IC = Candidate.IC;
                R.Spill.Status = VPlanBackendObservationStatus::Succeeded;
                R.Spill.IterationMapping = true;
                R.Spill.IterationWidth = Candidate.VF.getKnownMinValue() * Candidate.IC;
                Results.emplace_back(std::move(R));
              }
            }
            return Results;
          }); });
      PB.registerModuleAnalyses(MAM);
      PB.registerCGSCCAnalyses(CGAM);
      PB.registerFunctionAnalyses(FAM);
      PB.registerLoopAnalyses(LAM);
      PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);
      FunctionPassManager FPM;
      FPM.addPass(LoopVectorizePass());
      testing::internal::CaptureStderr();
      FPM.run(*M->getFunction("map"), FAM);
      auto Report = testing::internal::GetCapturedStderr();
      std::string IR;
      raw_string_ostream OS(IR);
      M->print(OS, nullptr);
      if (!Print) {
        ReferenceIR = IR;
        ReferenceQueries = Queries;
        ReferenceProbes = Probes;
        EXPECT_TRUE(Report.empty());
      } else {
        EXPECT_EQ(IR, ReferenceIR);
        EXPECT_EQ(Queries, ReferenceQueries);
        EXPECT_EQ(Probes, ReferenceProbes);
        if (Scenario == 0) {
          NativeIR = IR;
          NativeReport = Report;
        }
        if (Scenario == 1) {
          EXPECT_TRUE(llvm::is_contained(Probes, true));
          EXPECT_NE(Report.find("model=tti-v1"), std::string::npos);
          EXPECT_EQ(Report.find(" model=tti-real-vector-spill-v1"), std::string::npos);
        }
        if (Scenario == 2) {
          EXPECT_EQ(IR, NativeIR);
          EXPECT_EQ(Report, NativeReport);
          EXPECT_EQ(Report.find("backend-cost"), std::string::npos);
          EXPECT_EQ(Report.find("backend-scalar"), std::string::npos);
        }
      }
    }
  }
}
#endif

// Exercise real IR transformations and their observable normalization, not the
// ledger API or the number/order of propagation hooks.
TEST(VPlanBackendExecution, UnrollNormalizationUsesBodyTripEvidence) {
  for (unsigned Case = 0; Case != 4; ++Case) {
    SCOPED_TRACE(Case);
    LLVMContext C;
    SMDiagnostic Error;
    std::string Limit = Case == 0 ? "4" : Case == 2 ? "10" : "%trip";
    std::string Setup = Case == 1
                            ? "%bound = and i64 %n, 3\n%trip = add nuw i64 %bound, 1\n"
                            : "%trip = add i64 %n, 0\n";
    auto M = parseAssemblyString(
        "define void @f(ptr %p, i64 %n) {\nentry:\n" + Setup +
        "br label %loop\nloop:\n"
        "%i = phi i64 [0, %entry], [%next, %loop]\n"
        "%q = getelementptr i32, ptr %p, i64 %i\n"
        "store i32 7, ptr %q\n"
        "%next = add nuw i64 %i, 1\n"
        "%done = icmp eq i64 %next, " + Limit +
        "\nbr i1 %done, label %exit, label %loop\nexit: ret void\n}", Error, C);
    ASSERT_TRUE(M);
    auto &F = *M->getFunction("f");
    PassBuilder PB;
    FunctionAnalysisManager FAM;
    PB.registerFunctionAnalyses(FAM);
    auto &LI = FAM.getResult<LoopAnalysis>(F);
    auto &SE = FAM.getResult<ScalarEvolutionAnalysis>(F);
    auto &DT = FAM.getResult<DominatorTreeAnalysis>(F);
    auto &AC = FAM.getResult<AssumptionAnalysis>(F);
    auto &TTI = FAM.getResult<TargetIRAnalysis>(F);
    Loop *L = *LI.begin();
    ScopedRelatedBlockTracking Scope(F);
    auto *T = RelatedBlockTracking::get(&F);
    T->seed(L->getBlocks(), "body", "main", 16, false);
    UnrollLoopOptions Options{};
    Options.Count = Case < 2 ? 4 : 2;
    Options.Force = true;
    auto Result = UnrollLoop(L, Options, &LI, &SE, &DT, &AC, &TTI, nullptr, false);
    ASSERT_NE(Result, LoopUnrollResult::Unmodified);
    EXPECT_FALSE(verifyFunction(F, &errs()));
    const auto &N = T->Region.Normalization;
    EXPECT_EQ(N.Failure.empty(), Case != 3);
    if (Case != 3) {
      EXPECT_EQ(N.IterationWidth, Case < 2 ? 64u : 32u);
      EXPECT_EQ(N.TripCountKind, Case == 1 ? "upper-bound" : "exact");
      EXPECT_EQ(LI.empty(), Case < 2);
    } else {
      EXPECT_EQ(N.TripCountKind, "unknown");
    }
    EXPECT_TRUE(any_of(F, [&](const auto &BB) {
      return T->Region.intersects(BB.getRelatedBlock());
    }));
  }
}

TEST(VPlanBackendExecution, SharedStoreRetainsEverySource) {
  LLVMContext C;
  SMDiagnostic Error;
  auto M = parseAssemblyString(R"(
    define void @f(ptr %p, i1 %cond) {
    entry: br i1 %cond, label %left, label %right
    left:
      store i32 7, ptr %p
      br label %exit
    right:
      store i32 7, ptr %p
      br label %exit
    exit: ret void
    })", Error, C);
  ASSERT_TRUE(M);
  auto &F = *M->getFunction("f");
  auto *Right = F.getEntryBlock().getTerminator()->getSuccessor(1);
  ScopedRelatedBlockTracking Scope(F);
  auto *T = RelatedBlockTracking::get(&F);
  T->seed({Right}, "body", "main", 1, true);
  PassBuilder PB;
  FunctionAnalysisManager FAM;
  PB.registerFunctionAnalyses(FAM);
  FunctionPassManager PM;
  PM.addPass(SimplifyCFGPass(SimplifyCFGOptions().hoistCommonInsts(true)));
  PM.run(F, FAM);
  EXPECT_FALSE(verifyFunction(F, &errs()));
  unsigned Stores = 0;
  for (auto &BB : F)
    for (auto &I : BB)
      if (isa<StoreInst>(I)) {
        ++Stores;
        EXPECT_TRUE(T->Region.intersects(BB.getRelatedBlock()));
        EXPECT_EQ(BB.getRelatedBlock().State, RelatedBlockState::Known);
      }
  EXPECT_EQ(Stores, 1u);
}
