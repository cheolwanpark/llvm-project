// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "llvm/Analysis/LoopBackedgeAnalysis.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Function.h"
using namespace llvm;
Error llvm::checkLoopBackedges(Function &F) {
  auto *T = LoopBackedgeTracking::get(&F);
  if (!T || T->Widths.empty())
    return Error::success();
  DominatorTree DT(F);
  LoopInfo LI(DT);
  auto Result = mapTrackedLoops(*T, F, DT, LI);
  return Result ? Error::success() : Result.takeError();
}
void llvm::validateLoopBackedges(Function &F) {
  if (auto *T = LoopBackedgeTracking::get(&F))
    if (auto E = checkLoopBackedges(F))
      T->fail(toString(std::move(E)));
}
void llvm::redirectTrackedEdge(BasicBlock &From, BasicBlock &Through,
                               BasicBlock &To) {
  auto *T = LoopBackedgeTracking::get(&From);
  if (!T)
    return;
  auto I = T->Backedges.find({&Through, &To});
  if (I != T->Backedges.end())
    T->bind({&From, &To}, I->second);
  I = T->Backedges.find({&From, &Through});
  if (I != T->Backedges.end()) {
    uint64_t Q = I->second;
    if (!is_contained(successors(&From), &Through))
      T->Backedges.erase(I);
    T->bind({&From, &To}, Q);
  }
}
void llvm::rebindTrackedLoop(LoopBackedgeTracking &T, uint64_t Q,
                             const Loop &L) {
  T.eraseLoopEdges(Q);
  for (auto *BB : L.blocks())
    for (auto *Succ : successors(BB))
      if (Succ == L.getHeader())
        T.bind({BB, Succ}, Q);
}
bool llvm::containsTrackedLoop(const LoopBackedgeTracking &T, const Loop &L) {
  return any_of(T.Backedges,
                [&](const auto &E) { return L.contains(E.first.second); });
}
void llvm::cloneTrackedLoops(LoopBackedgeTracking &T,
                             const LoopBackedgeTable<BasicBlock> &Before,
                             const ValueToValueMapTy &VMap, const Loop *Exclude,
                             LoopInfo *LI) {
  DenseMap<uint64_t, uint64_t> ClonedIDs;
  for (const auto &E : Before.Backedges) {
    if (Exclude && E.first.second == Exclude->getHeader())
      continue;
    auto H = VMap.find(E.first.second);
    if (H == VMap.end())
      continue;
    auto L = VMap.find(E.first.first);
    auto *NewH = dyn_cast_or_null<BasicBlock>(H->second);
    auto *NewL =
        L == VMap.end() ? nullptr : dyn_cast_or_null<BasicBlock>(L->second);
    auto [I, New] = ClonedIDs.try_emplace(E.second, 0);
    if (New)
      I->second = T.addLoop(Before.Widths.lookup(E.second));
    if (!NewH || (!LI && !NewL)) {
      T.fail("unsupported-finite-body");
      continue;
    }
    if (LI) {
      auto *NewLoop = LI->getLoopFor(NewH);
      if (!NewLoop || NewLoop->getHeader() != NewH)
        T.fail("unsupported-finite-body");
      else
        rebindTrackedLoop(T, I->second, *NewLoop);
    } else
      T.bind({NewL, NewH}, I->second);
  }
}
LoopBackedgeUnroll::LoopBackedgeUnroll(Loop &L)
    : F(*L.getHeader()->getParent()), Tracking(LoopBackedgeTracking::get(&F)),
      Rewrite(Tracking) {
  if (Tracking)
    for (const auto &E : Tracking->Backedges)
      if (E.first.second == L.getHeader()) {
        DirectID = E.second;
        break;
      }
}
LoopBackedgeUnroll::~LoopBackedgeUnroll() {
  Rewrite.commit([&] { return checkLoopBackedges(F); });
}
void LoopBackedgeUnroll::commit(Loop *Remaining, uint64_t Factor, bool Full) {
  if (!Tracking || !DirectID)
    return;
  if (Full) {
    Tracking->fail("unsupported-finite-body");
    return;
  }
  Tracking->expand(DirectID, Factor);
  rebindTrackedLoop(*Tracking, DirectID, *Remaining);
}
