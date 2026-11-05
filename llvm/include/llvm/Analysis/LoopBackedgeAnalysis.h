// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_ANALYSIS_LOOPBACKEDGEANALYSIS_H
#define LLVM_ANALYSIS_LOOPBACKEDGEANALYSIS_H
#include "llvm/ADT/GraphTraits.h"
#include "llvm/ADT/PostOrderIterator.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/Analysis/CFG.h"
#include "llvm/IR/LoopBackedgeTracking.h"
#include "llvm/IR/ValueHandle.h"
#include "llvm/IR/ValueMap.h"
#include "llvm/Support/Error.h"
namespace llvm {
class Loop;
class LoopInfo;
using ValueToValueMapTy = ValueMap<const Value *, WeakTrackingVH>;
LLVM_ABI Error checkLoopBackedges(Function &F);
LLVM_ABI void validateLoopBackedges(Function &F);
/// Caller has replaced the path From->Through->To with From->To, preserving
/// the iteration it closes. Preserve labels on logical edges that still exist.
LLVM_ABI void redirectTrackedEdge(BasicBlock &From, BasicBlock &Through,
                                  BasicBlock &To);
LLVM_ABI void rebindTrackedLoop(LoopBackedgeTracking &T, uint64_t Q,
                                const Loop &L);
LLVM_ABI void cloneTrackedLoops(LoopBackedgeTracking &T,
                                const LoopBackedgeTable<BasicBlock> &Before,
                                const ValueToValueMapTy &VMap,
                                const Loop *Exclude = nullptr,
                                LoopInfo *LI = nullptr);
LLVM_ABI bool containsTrackedLoop(const LoopBackedgeTracking &T, const Loop &L);
/// A successful uniform serial expansion changes only the direct iteration.
/// Nested target clones are registered separately by the unroller's clone map.
class LLVM_ABI LoopBackedgeUnroll {
  Function &F;
  LoopBackedgeTracking *Tracking;
  LoopBackedgeRewrite<BasicBlock> Rewrite;
  uint64_t DirectID = 0;

public:
  explicit LoopBackedgeUnroll(Loop &L);
  ~LoopBackedgeUnroll();
  const LoopBackedgeTable<BasicBlock> *snapshot() const {
    return Rewrite.snapshot();
  }
  void commit(Loop *Remaining, uint64_t Factor, bool Full);
};
/// Register one independent, materialized or cloned iteration. Callers, not
/// block cloning utilities, decide whether a transformation creates a loop.
template <class Block, class LoopT>
uint64_t registerTrackedLoop(LoopBackedgeTable<Block> &T, const LoopT &L,
                             uint64_t Width) {
  uint64_t Q = T.addLoop(Width);
  for (const auto *BB : L.blocks())
    for (auto *Succ : children<const Block *>(BB))
      if (Succ == L.getHeader())
        T.bind({BB, Succ}, Q);
  return Q;
}
/// Local observation view. No pointer in this result may outlive the CFG.
template <class Block> struct TrackedLoopBody {
  uint64_t ID, Width;
  SmallVector<const Block *> Blocks;
};
/// The caller supplies analyses of the current, completed CFG, independently
/// at each observation boundary. This deliberately does not recover lost IDs.
template <class Block, class FunctionT, class DomTreeT, class LoopInfoT>
Expected<SmallVector<TrackedLoopBody<Block>>>
mapTrackedLoops(const LoopBackedgeTable<Block> &T, FunctionT &F, DomTreeT &DT,
                LoopInfoT &LI) {
  if (!T.Failure.empty())
    return createStringError(T.Failure);
  if (T.Widths.empty())
    return createStringError("missing-target-loop");
  SmallPtrSet<const Block *, 32> Live, Selected;
  for (const auto &BB : F)
    Live.insert(&BB);
  for (const auto &E : T.Backedges) {
    if (!T.Widths.count(E.second))
      return createStringError("unregistered-loop-id");
    if (!Live.contains(E.first.first) || !Live.contains(E.first.second))
      return createStringError("lost-backedge");
  }
  SmallVector<uint64_t> IDs;
  for (const auto &W : T.Widths)
    IDs.push_back(W.first);
  llvm::sort(IDs);
  SmallVector<TrackedLoopBody<Block>> Result;
  for (uint64_t Q : IDs) {
    const Block *Header = nullptr;
    unsigned EdgeCount = 0;
    for (const auto &E : T.Backedges) {
      if (E.second != Q)
        continue;
      const Block *From = E.first.first, *To = E.first.second;
      bool Exists = false;
      for (auto *Succ : children<const Block *>(From))
        Exists |= Succ == To;
      if (!Exists)
        return createStringError("lost-backedge");
      if (!DT.dominates(To, From))
        return createStringError("ambiguous-loop");
      if (Header && Header != To)
        return createStringError("ambiguous-loop");
      Header = To;
      ++EdgeCount;
    }
    if (!Header)
      return createStringError("lost-backedge");
    auto *L = LI.getLoopFor(Header);
    if (!L || L->getHeader() != Header)
      return createStringError("ambiguous-loop");
    ReversePostOrderTraversal<const Block *> RPO(Header);
    SmallVector<const Block *> BodyRPO;
    for (auto *BB : RPO)
      if (L->contains(BB))
        BodyRPO.push_back(BB);
    if (containsIrreducibleCFG<const Block *>(BodyRPO, LI))
      return createStringError("ambiguous-loop");
    unsigned ActualEdges = 0;
    for (auto *BB : L->blocks())
      for (auto *Succ : children<const Block *>(BB)) {
        if (Succ != Header)
          continue;
        auto I = T.Backedges.find({BB, Header});
        if (I == T.Backedges.end())
          return createStringError("lost-backedge");
        if (I->second != Q)
          return createStringError("conflicting-loop-ids");
        // IR switches can contain the same successor more than once.
        ++ActualEdges;
        break;
      }
    if (ActualEdges != EdgeCount)
      return createStringError("ambiguous-loop");
    uint64_t Width = T.Widths.lookup(Q);
    if (!Width || Width > UINT32_MAX)
      return createStringError("width-overflow");
    TrackedLoopBody<Block> Body{Q, Width, {}};
    for (const auto *BB : L->blocks()) {
      if (!Selected.insert(BB).second)
        return createStringError("overlapping-loop-bodies");
      Body.Blocks.push_back(BB);
    }
    Result.push_back(std::move(Body));
  }
  return Result;
}
} // namespace llvm
#endif
