//===- ReductionFission.h - Experimental LV distribution ---------*- C++
//-*-===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_LIB_TRANSFORMS_VECTORIZE_REDUCTIONFISSION_H
#define LLVM_LIB_TRANSFORMS_VECTORIZE_REDUCTIONFISSION_H

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SetVector.h"
#include "llvm/Analysis/IVDescriptors.h"
#include "llvm/IR/Intrinsics.h"
#include "llvm/Support/Alignment.h"
#include "llvm/Support/TypeSize.h"
#include <optional>

namespace llvm {
class AAResults;
class DataLayout;
class Loop;
class LoopInfo;
class ScalarEvolution;
class DominatorTree;
class TargetTransformInfo;
class TargetLibraryInfo;
class LoopVectorizationLegality;
class OptimizationRemarkEmitter;

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
    // A homogeneous associative chain with exactly one accumulator operand.
    // Terms are in recurrence order; an fmuladd contributes its independent
    // product. No IR is created until this candidate is selected.
    unsigned CombineOpcode = 0;
    Intrinsic::ID CombineIntrinsic = Intrinsic::not_intrinsic;
    SmallVector<Instruction *, 4> ContributionChain{};
    FastMathFlags ContributionFMF{};
    Instruction *ContributionGuard = nullptr;
    bool ContributionInvariant = false;
    bool PreserveInitialNaN = false;
    bool PreserveInitialInf = false;
    bool PreserveInitialZero = false;
    Value *Contribution = nullptr;
    std::optional<unsigned> SharedContributionWith = std::nullopt;
    StringRef ContributionReason = "original dependent slice";
  };
  void planContribution(Reduction &R);
  bool isCheapProduct(const Reduction &R, LoopVectorizationLegality &Legal,
                      ScalarEvolution &SE) const;
  static bool sameContribution(const Reduction &A, const Reduction &B);
  SmallVector<ElementCount, 8>
  getLegalVFs(const Reduction &R, const TargetTransformInfo &TTI) const;
  Loop *L;
  SmallVector<Reduction, 2> Reductions;
  // A buffer is identified by the SSA value and its definition's iteration
  // coverage, not by the decoding chosen by a consumer. A null Start denotes
  // owned scratch; otherwise this is a proven stable, borrowed Map stream.
  struct Storage {
    Value *StoredValue;
    Type *StoredType;
    // Allocation alignment for owned scratch; access alignment for streams.
    Align Alignment;
    const SCEV *Start = nullptr;
    Align getAccessAlignment(const DataLayout &DL) const;
  };
  struct Encoding {
    unsigned Buffer;
    // In load-to-consumer order. Preserve mixed sext/zext chains exactly.
    SmallVector<CastInst *, 2> Decode;
  };
  SmallVector<Storage, 4> StoragePlans;
  DenseMap<Value *, Encoding> Encodings;
  void recordEncoding(Value *Logical, Storage S,
                      ArrayRef<CastInst *> Decode = {});
  bool hasStream(Value *V) const;
  const SCEV *BackedgeCount = nullptr;
  // Static full-loop capacity proven and budgeted after physical storage
  // sharing. Execution always uses BackedgeCount + 1, including for dynamic
  // trip counts.
  std::optional<uint64_t> StackCapacity;
  std::string Failure;

public:
  explicit ReductionFission(Loop *L) : L(L) {}
  /// Read-only analysis of scalar IR. Does not allocate buffers or alter CFG.
  bool analyze(LoopVectorizationLegality &Legal, ScalarEvolution &SE,
               DominatorTree &DT, const TargetTransformInfo &TTI,
               AAResults &AA, const TargetLibraryInfo &TLI);
  StringRef getFailure() const { return Failure; }
  SmallVector<ElementCount> getReductionVFs() const;
  SmallVector<SmallVector<ElementCount, 8>> getReductionVFChoices() const;
  void emitPlanRemarks(OptimizationRemarkEmitter &ORE) const;
  static void setReductionVF(Loop *L, ElementCount VF);
  struct GeneratedLoops {
    // Null when stream/invariant reuse leaves no computation or observable
    // effect in Map. Every original accumulator still has its own reducer.
    Loop *Map;
    SmallVector<Loop *> Reductions;
  };
  /// Only called for an explicitly selected fission candidate.
  GeneratedLoops execute(const LoopVectorizationCandidate &Candidate,
                         LoopInfo &LI, ScalarEvolution &SE, DominatorTree &DT);
};
} // namespace llvm
#endif
