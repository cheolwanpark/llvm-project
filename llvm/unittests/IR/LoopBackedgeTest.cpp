// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "llvm/Analysis/LoopBackedgeAnalysis.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/AsmParser/Parser.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Verifier.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Transforms/Utils/BasicBlockUtils.h"
#include "gtest/gtest.h"
using namespace llvm;

TEST(LoopBackedge, CurrentBodyIncludesHelperAndSurvivesSplitting) {
  LLVMContext C;
  SMDiagnostic Diagnostic;
  auto M = parseAssemblyString(R"(
    define void @f(i1 %a, i1 %b) {
    entry: br label %outer
    outer: br label %helper
    helper: br i1 %a, label %helper, label %latch
    latch: br i1 %b, label %outer, label %exit
    exit: ret void
    }
  )",
                               Diagnostic, C);
  ASSERT_TRUE(M);
  auto &F = *M->getFunction("f");
  DominatorTree DT(F);
  LoopInfo LI(DT);
  ScopedLoopBackedgeTracking Scope(F);
  auto &T = *LoopBackedgeTracking::get(&F);
  Loop *L = *LI.begin();
  auto *Header = L->getHeader();
  auto *Latch = L->getLoopLatch();
  registerTrackedLoop(T, *L, 8);
  auto Before = mapTrackedLoops(T, F, DT, LI);
  ASSERT_TRUE(bool(Before)) << toString(Before.takeError());
  ASSERT_EQ(Before->size(), 1u);
  EXPECT_EQ(Before->front().Width, 8u);
  EXPECT_EQ(Before->front().Blocks.size(), 3u);
  EXPECT_FALSE(is_contained(Before->front().Blocks, &F.getEntryBlock()));
  EXPECT_FALSE(is_contained(Before->front().Blocks, &F.back()));

  auto *SplitLatch =
      Latch->splitBasicBlock(Latch->getTerminator()->getIterator());
  Header->splitBasicBlockBefore(Header->getTerminator()->getIterator());
  ASSERT_FALSE(verifyFunction(F));
  DT.recalculate(F);
  LI.releaseMemory();
  LI.analyze(DT);
  auto After = mapTrackedLoops(T, F, DT, LI);
  ASSERT_TRUE(bool(After)) << toString(After.takeError());
  ASSERT_EQ(After->size(), 1u);
  EXPECT_EQ(After->front().Width, 8u);
  EXPECT_EQ(After->front().Blocks.size(), 5u);
  ASSERT_TRUE(MergeBlockIntoPredecessor(SplitLatch));
  ASSERT_FALSE(verifyFunction(F));
  DT.recalculate(F);
  LI.releaseMemory();
  LI.analyze(DT);
  auto Merged = mapTrackedLoops(T, F, DT, LI);
  ASSERT_TRUE(bool(Merged)) << toString(Merged.takeError());
  ASSERT_EQ(Merged->size(), 1u);
  EXPECT_EQ(Merged->front().Width, 8u);
  EXPECT_EQ(Merged->front().Blocks.size(), 4u);
}

TEST(LoopBackedge, MissingIterationIsFailureEvenWhenAnotherLoopRemains) {
  LLVMContext C;
  SMDiagnostic Diagnostic;
  auto M = parseAssemblyString(R"(
    define void @f(i1 %c) {
    entry: br label %first
    first: br i1 %c, label %first, label %second
    second: br i1 %c, label %second, label %exit
    exit: ret void
    }
  )",
                               Diagnostic, C);
  ASSERT_TRUE(M);
  auto &F = *M->getFunction("f");
  DominatorTree DT(F);
  LoopInfo LI(DT);
  ScopedLoopBackedgeTracking Scope(F);
  auto &T = *LoopBackedgeTracking::get(&F);
  for (auto *L : LI)
    registerTrackedLoop(T, *L, 4);
  auto Before = mapTrackedLoops(T, F, DT, LI);
  ASSERT_TRUE(bool(Before)) << toString(Before.takeError());
  ASSERT_EQ(Before->size(), 2u);
  auto *First = F.getEntryBlock().getTerminator()->getSuccessor(0);
  auto *Branch = First->getTerminator();
  Branch->setSuccessor(0, Branch->getSuccessor(1));
  DT.recalculate(F);
  LI.releaseMemory();
  LI.analyze(DT);
  auto After = mapTrackedLoops(T, F, DT, LI);
  ASSERT_FALSE(bool(After));
  EXPECT_EQ(toString(After.takeError()), "lost-backedge");
}

TEST(LoopBackedge, IrreducibleHelperIsNotAValidBody) {
  LLVMContext C;
  SMDiagnostic Diagnostic;
  auto M = parseAssemblyString(R"(
    define void @f(i1 %a, i1 %b) {
    entry: br label %outer
    outer: br i1 %a, label %left, label %right
    left: br label %right
    right: br i1 %b, label %left, label %latch
    latch: br i1 %a, label %outer, label %exit
    exit: ret void
    }
  )",
                               Diagnostic, C);
  ASSERT_TRUE(M);
  auto &F = *M->getFunction("f");
  DominatorTree DT(F);
  LoopInfo LI(DT);
  ScopedLoopBackedgeTracking Scope(F);
  auto &T = *LoopBackedgeTracking::get(&F);
  registerTrackedLoop(T, **LI.begin(), 4);
  auto Body = mapTrackedLoops(T, F, DT, LI);
  ASSERT_FALSE(bool(Body));
  EXPECT_EQ(toString(Body.takeError()), "ambiguous-loop");
}
