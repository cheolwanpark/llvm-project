// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "../lib/Passes/VPlanBackendProbe.h"
#include "../lib/Transforms/Vectorize/VPlan.h"
#include "../lib/Transforms/Vectorize/VPlanBackendCostModel.h"
#include "VPlanTestBase.h"
#include "llvm/Analysis/AssumptionCache.h"
#include "llvm/Analysis/LoopBackedgeAnalysis.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/OptimizationRemarkEmitter.h"
#include "llvm/Analysis/ScalarEvolution.h"
#include "llvm/Analysis/TargetTransformInfoImpl.h"
#include "llvm/AsmParser/Parser.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Verifier.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Transforms/Scalar/SimplifyCFG.h"
#include "llvm/Transforms/Utils/LoopPeel.h"
#include "llvm/Transforms/Utils/UnrollLoop.h"
#include "gtest/gtest.h"
#include <condition_variable>
#include <mutex>
using namespace llvm;

namespace llvm {
class VPlanBackendCostModelTestAccess {
public:
  using Prepared = VPlanBackendCostModel::PreparedCandidate;
  static Prepared candidate(VPlan &P, unsigned VF, unsigned Cost, bool Query) {
    VPlanBackendCandidate C{
        std::to_string(VF), 0, ElementCount::getFixed(VF), true, false, false};
    return {&P, C, Cost, Cost, 0, 0, VF, {}, Query, true};
  }
  static bool run(VPlanBackendCostModel &M, ArrayRef<Prepared> Cs) {
    return M.addBatch(Cs, VPBackendPruningContext{100, 0, true});
  }
};
} // namespace llvm

TEST(VPlanBackendExecution, GateIsConservativeAtPressureAndOverflow) {
  EXPECT_EQ(boundVPlanLiveValues(3, {{1, 0}, {1, 1}, {1, 1}}), 5u);
  EXPECT_FALSE(boundVPlanLiveValues(UINT64_MAX, {{1, 0}}));
  for (auto [Usage, IC, Query] :
       {std::tuple{15u, 2u, false}, std::tuple{16u, 2u, true}}) {
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
  TypeSize
  getRegisterBitWidth(TargetTransformInfo::RegisterKind) const override {
    return TypeSize::getScalable(64);
  }
  bool isElementTypeLegalForScalableVector(Type *) const override {
    return true;
  }
  bool isTypeLegal(Type *) const override { return true; }
  unsigned getNumberOfParts(Type *) const override { return 1; }
  unsigned getRegUsageForType(Type *) const override { return 1; }
};
class BackendGate : public VPlanTestBase {};
} // namespace
TEST_F(BackendGate, UnsupportedRecipeCannotBecomeASafeSkip) {
  M->setTargetTriple(Triple("riscv64-unknown-elf"));
  auto &P = getPlan();
  auto *B = P.createVPBasicBlock("body");
  auto *Region =
      P.createLoopRegion(Type::getInt64Ty(C), DebugLoc(), "loop", B, B);
  VPBlockUtils::connectBlocks(P.getEntry(), Region);
  VPBlockUtils::connectBlocks(Region, P.getScalarHeader());
  auto *X = new VPInstructionWithType(VPInstruction::StepVector, {},
                                      Type::getInt32Ty(C));
  B->appendRecipe(X);
  B->appendRecipe(new VPWidenRecipe(Instruction::Add, {X, X}));
  TargetTransformInfo TTI(std::make_unique<GateTTI>());
  auto Bound =
      computeVPlanRegisterUsageBound(P, ElementCount::getScalable(2), TTI);
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
    VPlanBackendFeedback Feedback([&](const Function &, const BasicBlock &,
                                      ArrayRef<VPlanBackendCandidate> Cs)
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
          R.Spill.Loops.push_back({1, Candidate.VF.getFixedValue(), 1, {}, {}});
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
    EXPECT_EQ(Access::run(Costs, {Winner, Failure}), Dominated);
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
  auto Result = Pool.run(
      2,
      [&](unsigned I) -> VPlanBackendProbeResult {
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
      },
      [&](unsigned I, const VPlanBackendProbeResult &) {
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
}

// Exercise real IR transformations and their observable normalization, not the
// ledger API or the number/order of propagation hooks.
TEST(VPlanBackendExecution, UnrollUsesUniformExpansionAndDropsFiniteBodies) {
  for (unsigned Case = 0; Case != 5; ++Case) {
    SCOPED_TRACE(Case);
    LLVMContext C;
    SMDiagnostic Error;
    std::string Limit = Case == 0 ? "4" : Case == 2 ? "10" : "%trip";
    std::string Setup =
        Case == 1 ? "%bound = and i64 %n, 3\n%trip = add nuw i64 %bound, 1\n"
                  : "%trip = add i64 %n, 0\n";
    auto M = parseAssemblyString(
        "define void @f(ptr %p, i64 %n) {\nentry:\n" + Setup +
            "br label %loop\nloop:\n"
            "%i = phi i64 [0, %entry], [%next, %loop]\n"
            "%q = getelementptr i32, ptr %p, i64 %i\n"
            "store i32 7, ptr %q\n"
            "%next = add nuw i64 %i, 1\n"
            "%done = icmp eq i64 %next, " +
            Limit +
            "\nbr i1 %done, label %exit, label %loop\nexit: ret void\n}",
        Error, C);
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
    ScopedLoopBackedgeTracking Scope(F);
    auto *T = LoopBackedgeTracking::get(&F);
    registerTrackedLoop(*T, *L, 16);
    UnrollLoopOptions Options{};
    Options.Count = Case < 2 || Case == 4 ? 4 : 2;
    Options.Runtime = Case == 4;
    Options.AllowExpensiveTripCount = Case == 4;
    Options.Force = true;
    auto Result =
        UnrollLoop(L, Options, &LI, &SE, &DT, &AC, &TTI, nullptr, false);
    ASSERT_NE(Result, LoopUnrollResult::Unmodified);
    EXPECT_FALSE(verifyFunction(F, &errs()));
    auto Body = mapTrackedLoops(*T, F, DT, LI);
    if (Case < 2) {
      ASSERT_TRUE(bool(Body)) << toString(Body.takeError());
      EXPECT_TRUE(Body->empty());
    } else {
      ASSERT_TRUE(bool(Body)) << toString(Body.takeError());
      if (Case == 4) {
        ASSERT_EQ(Body->size(), 2u);
        SmallVector<uint64_t> Widths;
        for (const auto &LoopBody : *Body)
          Widths.push_back(LoopBody.Width);
        llvm::sort(Widths);
        EXPECT_EQ(Widths, (SmallVector<uint64_t>{16, 64}));
      } else {
        ASSERT_EQ(Body->size(), 1u);
        EXPECT_EQ(Body->front().Width, 32u);
      }
      EXPECT_FALSE(Body->front().Blocks.empty());
    }
  }
}

TEST(VPlanBackendExecution, ObservationFollowsCurrentInstructionPlacement) {
  LLVMContext C;
  SMDiagnostic Diagnostic;
  auto M = parseAssemblyString(R"(
    define void @f(ptr %p, i1 %cond) {
    entry: br label %loop
    loop:
      store i32 7, ptr %p
      br i1 %cond, label %loop, label %exit
    exit: ret void
    })",
                               Diagnostic, C);
  ASSERT_TRUE(M);
  auto &F = *M->getFunction("f");
  DominatorTree DT(F);
  LoopInfo LI(DT);
  Loop *L = *LI.begin();
  ScopedLoopBackedgeTracking Scope(F);
  auto *T = LoopBackedgeTracking::get(&F);
  registerTrackedLoop(*T, *L, 1);
  auto CountStores = [&]() {
    auto Body = mapTrackedLoops(*T, F, DT, LI);
    if (!Body) {
      ADD_FAILURE() << toString(Body.takeError());
      return 0u;
    }
    unsigned Stores = 0;
    for (const auto &LoopBody : *Body)
      for (auto *BB : LoopBody.Blocks)
        Stores +=
            count_if(*BB, [](const auto &I) { return isa<StoreInst>(I); });
    return Stores;
  };
  auto &Store = L->getHeader()->front();
  EXPECT_EQ(CountStores(), 1u);
  Store.moveBefore(F.getEntryBlock().getTerminator()->getIterator());
  EXPECT_EQ(CountStores(), 0u);
  Store.moveBefore(L->getHeader()->getTerminator()->getIterator());
  EXPECT_EQ(CountStores(), 1u);
  EXPECT_FALSE(verifyFunction(F));
}

TEST(VPlanBackendExecution, EnclosingTransformsPreserveOrJamInnerWidths) {
  for (unsigned Mode = 0; Mode != 3; ++Mode) {
    SCOPED_TRACE(Mode);
    LLVMContext C;
    SMDiagnostic Diagnostic;
    auto M = parseAssemblyString(R"(
    define void @f(ptr %p, i64 %n) {
    entry: br label %outer
    outer:
      %i = phi i64 [0, %entry], [%inext, %outer.latch]
      br label %inner.preheader
    inner.preheader: br label %inner
    inner:
      %j = phi i64 [0, %inner.preheader], [%jnext, %inner]
      %address = getelementptr i32, ptr %p, i64 %j
      store i32 7, ptr %address
      %jnext = add nuw i64 %j, 1
      %inner.done = icmp eq i64 %jnext, %n
      br i1 %inner.done, label %outer.latch, label %inner
    outer.latch:
      %inext = add nuw i64 %i, 1
      %outer.done = icmp eq i64 %inext, 2
      br i1 %outer.done, label %exit, label %outer
    exit: ret void
    })",
                                 Diagnostic, C);
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
    Loop *Outer = *LI.begin();
    ASSERT_EQ(Outer->getSubLoops().size(), 1u);
    ScopedLoopBackedgeTracking Scope(F);
    auto &T = *LoopBackedgeTracking::get(&F);
    registerTrackedLoop(T, *Outer->getSubLoops().front(), 8);
    UnrollLoopOptions Options{};
    Options.Count = 2;
    Options.Force = true;
    if (Mode == 0) {
      EXPECT_EQ(
          UnrollLoop(Outer, Options, &LI, &SE, &DT, &AC, &TTI, nullptr, false),
          LoopUnrollResult::FullyUnrolled);
    } else if (Mode == 1) {
      ValueToValueMapTy VMap;
      peelLoop(Outer, 1, false, &LI, &SE, DT, &AC, false, VMap);
    } else {
      OptimizationRemarkEmitter ORE(&F);
      EXPECT_EQ(UnrollAndJamLoop(Outer, 2, 2, 2, false, &LI, &SE, &DT, &AC,
                                 &TTI, &ORE),
                LoopUnrollResult::FullyUnrolled);
    }
    ASSERT_FALSE(verifyFunction(F));
    auto Bodies = mapTrackedLoops(T, F, DT, LI);
    ASSERT_TRUE(bool(Bodies)) << toString(Bodies.takeError());
    ASSERT_EQ(Bodies->size(), Mode == 2 ? 1u : 2u);
    for (const auto &Body : *Bodies)
      EXPECT_EQ(Body.Width, Mode == 2 ? 16u : 8u);
  }
}
