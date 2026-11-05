// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_ANALYSIS_RELATEDBLOCKANALYSIS_H
#define LLVM_ANALYSIS_RELATEDBLOCKANALYSIS_H
#include "llvm/IR/RelatedBlock.h"
namespace llvm {
class Loop;
class LoopInfo;
class ScalarEvolution;
struct RelatedBlockTripCount {
  uint64_t Value = 0;
  bool UpperBound = false;
};
LLVM_ABI RelatedBlockTripCount getRelatedBlockTripCount(Loop &L,
                                                        ScalarEvolution &SE);
LLVM_ABI void validateRelatedBlockNormalization(Function &F, LoopInfo &LI);
/// Snapshot before mutation, commit only for a successful unroll. A clone is
/// not an unroll certificate; alternative clones do not change the width.
class LLVM_ABI RelatedBlockUnroll {
  RelatedBlockTracking *Tracking = nullptr;
  RelatedBlockTripCount Trip;
  bool MixedDomain = false;

public:
  RelatedBlockUnroll(Loop &L, ScalarEvolution &SE, LoopInfo &LI);
  void commit(uint64_t Factor, bool Full, bool MixedRemainder);
};
} // namespace llvm
#endif
