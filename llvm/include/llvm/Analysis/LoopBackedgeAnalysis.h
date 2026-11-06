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
using ValueToValueMapTy = ValueMap<const Value *, WeakTrackingVH>;
/// Caller has replaced the path From->Through->To with From->To, preserving
/// the iteration it closes. Preserve labels on logical edges that still exist.
LLVM_ABI void redirectTrackedEdge(BasicBlock &From, BasicBlock &Through,
                                  BasicBlock &To);
LLVM_ABI void cloneTrackedLoops(LoopBackedgeTracking &T,
                                const LoopBackedgeTable<BasicBlock> &Before,
                                const ValueToValueMapTy &VMap,
                                const Loop *Exclude = nullptr);
/// A successful uniform serial expansion changes only the direct iteration.
/// Nested target clones are registered separately by the unroller's clone map.
class LLVM_ABI LoopBackedgeUnroll {
  LoopBackedgeTracking *Tracking;
  LoopBackedgeRewrite<BasicBlock> Rewrite;
  SmallVector<uint64_t> DirectIDs;

public:
  explicit LoopBackedgeUnroll(Loop &L);
  ~LoopBackedgeUnroll();
  bool suppressFullUnroll(const Loop &L, unsigned RequestedCount,
                          unsigned Count, unsigned MaxTripCount);
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
Expected<SmallVector<TrackedLoopBody<Block>>> mapTrackedLoops(
    const LoopBackedgeTable<Block> &T, FunctionT &F, DomTreeT &DT,
    LoopInfoT &LI, SmallVectorImpl<uint64_t> *Conflicts = nullptr,
    SmallVectorImpl<std::pair<uint64_t, std::string>> *Excluded = nullptr) {
  if (!T.Failure.empty())
    return createStringError(T.Failure);
  SmallPtrSet<const Block *, 32> Live;
  for (const auto &BB : F)
    Live.insert(&BB);
  DenseMap<const Block *, SmallVector<uint64_t>> Loops;
  for (const auto &E : T.Backedges) {
    auto [From, To] = E.first;
    if (!Live.contains(From) || !Live.contains(To))
      continue;
    if (!is_contained(children<const Block *>(From), To))
      continue;
    auto *L = LI.getLoopFor(To);
    if (!L || L->getHeader() != To || !L->contains(From) ||
        !DT.dominates(To, From))
      continue;
    auto &IDs = Loops[To];
    for (auto Q : E.second) {
      if (!T.Widths.count(Q))
        return createStringError("unregistered-loop-id");
      if (!is_contained(IDs, Q))
        IDs.push_back(Q);
    }
  }
  // Propagate contradictions across aliases, never across independent widths.
  DenseSet<uint64_t> Invalid = T.Undefined;
  bool Changed;
  do {
    Changed = false;
    for (const auto &Entry : Loops) {
      auto Width = T.Widths.lookup(Entry.second.front());
      if (any_of(Entry.second, [&](auto Q) {
            auto W = T.Widths.lookup(Q);
            return Invalid.contains(Q) || !W || W > UINT32_MAX || W != Width;
          }))
        for (auto Q : Entry.second)
          Changed |= Invalid.insert(Q).second;
    }
  } while (Changed);
  if (Conflicts)
    Conflicts->append(Invalid.begin(), Invalid.end());
  SmallVector<TrackedLoopBody<Block>> Result;
  // Function order makes observation instance identities deterministic.
  for (const auto &BB : F) {
    auto I = Loops.find(&BB);
    if (I == Loops.end() || Invalid.contains(I->second.front()))
      continue;
    uint64_t Q = *llvm::min_element(I->second);
    TrackedLoopBody<Block> Body{Q, T.Widths.lookup(Q), {}};
    for (auto *B : LI.getLoopFor(&BB)->blocks())
      Body.Blocks.push_back(B);
    Result.push_back(std::move(Body));
  }
  if (Excluded)
    for (const auto &W : T.Widths) {
      if (Invalid.contains(W.first) || !W.second || W.second > UINT32_MAX)
        Excluded->emplace_back(W.first, "undefined iteration width");
      else if (none_of(Loops, [&](const auto &L) {
                 return is_contained(L.second, W.first);
               }))
        Excluded->emplace_back(W.first, "no observable native loop");
    }
  return Result;
}
} // namespace llvm
#endif
