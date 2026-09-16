//===- ReductionFission.h - Experimental LV distribution ---------*- C++
//-*-===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_LIB_TRANSFORMS_VECTORIZE_REDUCTIONFISSION_H
#define LLVM_LIB_TRANSFORMS_VECTORIZE_REDUCTIONFISSION_H

#include "llvm/ADT/SetVector.h"
#include "llvm/Analysis/IVDescriptors.h"
#include "llvm/Support/TypeSize.h"

namespace llvm {
class Loop;
class LoopInfo;
class ScalarEvolution;
class DominatorTree;
class TargetTransformInfo;
class LoopVectorizationLegality;

/// A logical choice sits above VPlan: a fission choice owns several loop plans,
/// not a second meaning for the original loop's ElementCount.
struct LoopVectorizationCandidate {
  enum class Kind { Normal, Fission } Transform;
  ElementCount MapVF;
  /// Infinity is a policy, deliberately not an InstructionCost sentinel.
  bool isAutomaticallySelectable() const { return Transform == Kind::Normal; }
};

class ReductionFission {
  struct Reduction {
    PHINode *Phi;
    RecurrenceDescriptor Descriptor;
    SetVector<Instruction *> Slice;
    SetVector<Value *> Inputs;
    ElementCount VF = ElementCount::getFixed(1);
    SmallVector<ElementCount, 8> LegalVFs{};
  };
  Loop *L;
  SmallVector<Reduction, 2> Reductions;
  const SCEV *BackedgeCount = nullptr;
  std::string Failure;

public:
  explicit ReductionFission(Loop *L) : L(L) {}
  /// Read-only analysis of scalar IR. Does not allocate buffers or alter CFG.
  bool analyze(LoopVectorizationLegality &Legal, ScalarEvolution &SE,
               DominatorTree &DT, const TargetTransformInfo &TTI);
  StringRef getFailure() const { return Failure; }
  SmallVector<ElementCount> getReductionVFs() const;
  SmallVector<SmallVector<ElementCount, 8>> getReductionVFChoices() const;
  static void setReductionVF(Loop *L, ElementCount VF);
  /// Only called for an explicitly selected fission candidate.
  SmallVector<Loop *> execute(const LoopVectorizationCandidate &Candidate,
                              LoopInfo &LI, ScalarEvolution &SE,
                              DominatorTree &DT);
};
} // namespace llvm
#endif
