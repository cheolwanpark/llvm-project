// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "llvm/Analysis/LoopBackedgeAnalysis.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Function.h"
using namespace llvm;
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
    auto Q = I->second;
    if (!is_contained(successors(&From), &Through))
      T->Backedges.erase(I);
    T->bind({&From, &To}, Q);
  }
}
static void rebindTrackedLoop(LoopBackedgeTracking &T, uint64_t Q,
                              const Loop &L) {
  T.eraseLoopEdges(Q);
  for (auto *BB : L.blocks())
    for (auto *Succ : successors(BB))
      if (Succ == L.getHeader())
        T.bind({BB, Succ}, Q);
}
void llvm::cloneTrackedLoops(LoopBackedgeTracking &T,
                             const LoopBackedgeTable<BasicBlock> &Before,
                             const ValueToValueMapTy &VMap,
                             const Loop *Exclude) {
  DenseMap<uint64_t, uint64_t> ClonedIDs;
  for (const auto &E : Before.Backedges) {
    if (Exclude && E.first.second == Exclude->getHeader())
      continue;
    auto H = VMap.find(E.first.second), L = VMap.find(E.first.first);
    if (H == VMap.end() || L == VMap.end())
      continue;
    auto *NewH = dyn_cast_or_null<BasicBlock>(H->second);
    auto *NewL = dyn_cast_or_null<BasicBlock>(L->second);
    if (!NewH || !NewL || !is_contained(successors(NewL), NewH))
      continue;
    for (auto Q : E.second) {
      auto [I, New] = ClonedIDs.try_emplace(Q, 0);
      if (New) {
        I->second = T.addLoop(Before.Widths.lookup(Q));
        if (Before.Undefined.contains(Q))
          T.Undefined.insert(I->second);
      }
      T.bind({NewL, NewH}, I->second);
    }
  }
}
LoopBackedgeUnroll::LoopBackedgeUnroll(Loop &L)
    : Tracking(LoopBackedgeTracking::get(L.getHeader())), Rewrite(Tracking) {
  if (Tracking)
    for (const auto &E : Tracking->Backedges)
      if (E.first.second == L.getHeader()) {
        for (auto Q : E.second)
          if (!is_contained(DirectIDs, Q))
            DirectIDs.push_back(Q);
      }
}
LoopBackedgeUnroll::~LoopBackedgeUnroll() { Rewrite.commit(); }
void LoopBackedgeUnroll::commit(Loop *Remaining, uint64_t Factor, bool Full) {
  if (!Tracking)
    return;
  for (auto Q : DirectIDs)
    Tracking->eraseLoopEdges(Q);
  if (Full)
    return;
  for (auto Q : DirectIDs)
    Tracking->expand(Q, Factor);
  for (auto Q : DirectIDs)
    rebindTrackedLoop(*Tracking, Q, *Remaining);
}
