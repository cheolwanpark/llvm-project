// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "llvm/Analysis/RelatedBlockAnalysis.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/ScalarEvolution.h"
#include "llvm/Analysis/ScalarEvolutionExpressions.h"
using namespace llvm;
RelatedBlockTripCount llvm::getRelatedBlockTripCount(Loop &L,
                                                     ScalarEvolution &SE) {
  auto Count = [](const SCEV *S) -> uint64_t {
    auto *C = dyn_cast<SCEVConstant>(S);
    if (!C || C->getAPInt().getActiveBits() > 64)
      return 0;
    uint64_t Backedges = C->getAPInt().getZExtValue();
    return Backedges == UINT64_MAX ? 0 : Backedges + 1;
  };
  // Whole-loop counts, conditional on entry, not one exiting block's count.
  if (uint64_t N = Count(SE.getBackedgeTakenCount(&L)))
    return {N, false};
  return {Count(SE.getConstantMaxBackedgeTakenCount(&L)), true};
}
RelatedBlockUnroll::RelatedBlockUnroll(Loop &L, ScalarEvolution &SE,
                                       LoopInfo &LI) {
  auto *T = RelatedBlockTracking::get(L.getHeader());
  if (!T || !any_of(L.blocks(), [&](auto *BB) {
        return T->Region.intersects(BB->getRelatedBlock());
      }))
    return;
  Tracking = T;
  // A single width cannot describe serial expansion of only one alternative,
  // or expansion of an enclosing/synthetic loop. In particular do not multiply
  // the region width once for each unswitched clone.
  MixedDomain =
      T->Region.Normalization.Finite || !L.isInnermost() ||
      any_of(LI.getLoopsInPreorder(), [&](Loop *Other) {
        return Other != &L && !Other->contains(&L) &&
               T->Region.intersects(Other->getHeader()->getRelatedBlock());
      });
  Trip = getRelatedBlockTripCount(L, SE);
}
void RelatedBlockUnroll::commit(uint64_t Factor, bool Full,
                                bool MixedRemainder) {
  if (!Tracking)
    return;
  auto &N = Tracking->Region.Normalization;
  if (!N.Failure.empty())
    return;
  N.TripCount = Trip.Value;
  N.TripCountKind = !Trip.Value       ? "unknown"
                    : Trip.UpperBound ? "upper-bound"
                                      : "exact";
  if (!Trip.Value) {
    N.Failure = "unroll without a constant trip count or bound";
    return;
  }
  if (MixedRemainder || MixedDomain) {
    N.Failure = "mixed alternative, nested or remainder iteration domains";
    return;
  }
  if (!Factor || N.IterationWidth > UINT32_MAX / Factor) {
    N.Failure = "unrolled iteration width overflow";
    return;
  }
  N.IterationWidth *= Factor;
  N.Finite = Full;
  N.Basis = Full ? (Trip.UpperBound ? "full-unroll-bound" : "full-unroll-exact")
                 : "partial-unroll";
}

void llvm::validateRelatedBlockNormalization(Function &F, LoopInfo &LI) {
  auto *T = RelatedBlockTracking::get(&F);
  if (!T || !T->Region.Normalization.Failure.empty())
    return;
  auto &N = T->Region.Normalization;
  if (N.Finite)
    return;
  bool Repeated = any_of(LI.getLoopsInPreorder(), [&](Loop *L) {
    return T->Region.intersects(L->getHeader()->getRelatedBlock());
  });
  if (!Repeated)
    N.Failure = "body removed without a finite expansion certificate";
}
