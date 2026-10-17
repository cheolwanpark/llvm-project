//===- VPlanReductionFissionFPReordering.h - FP reassociation --*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_VECTORIZE_VPLANREDUCTIONFISSIONFPREORDERING_H
#define LLVM_TRANSFORMS_VECTORIZE_VPLANREDUCTIONFISSIONFPREORDERING_H

#include "llvm/ADT/DenseMap.h"
#include <optional>

namespace llvm {

class ElementCount;
class Instruction;
class Loop;
class LoopVectorizationLegality;
class LoopVectorizeHints;
class PHINode;
class PredicatedScalarEvolution;
class RecurrenceDescriptor;
class TargetTransformInfo;
class VPlan;

/// Reassociation permission for one private reduction-fission planning attempt.
/// Selection is fixed before constructing its VFSelectionContext. The policy
/// must outlive that context and its plans; neither the policy nor its clients
/// may query the original IR after a successful fission erases the loop.
/// Destruction only discards pointer keys and does not access the original IR.
class FissionFPReorderingPolicy {
  SmallDenseMap<const PHINode *, const Instruction *, 4> Reductions;

  FissionFPReorderingPolicy() = default;
  static bool isEnabled();

public:
  /// Cheap gate before allocating any private planning state. Both fission
  /// and its FP reordering option must be enabled.
  static bool shouldAttempt(const Loop &L, const LoopVectorizeHints &Hints,
                            bool OptForSize);

  /// Check attempt-specific legality and select supported sums after the
  /// private Legal.canVectorize() succeeds. Return no policy if no sum can be
  /// reordered or another exact recurrence prevents the attempt. Never modify
  /// IR, hints or legality descriptors.
  static std::optional<FissionFPReorderingPolicy>
  create(const Loop &L, LoopVectorizationLegality &Legal,
         const PredicatedScalarEvolution &PSE, const LoopVectorizeHints &Hints,
         bool AllowOrderedReductions);

  bool allows(const PHINode *Phi) const { return Reductions.contains(Phi); }
  bool allows(const RecurrenceDescriptor &Rdx) const;

  /// Query TTI with a temporary reassociable descriptor for selected sums.
  /// The descriptor owned by legality is never modified.
  bool isLegalToVectorizeReduction(const RecurrenceDescriptor &Rdx,
                                   ElementCount VF,
                                   const TargetTransformInfo &TTI) const;

  /// Add only reassoc to selected sums in a private VPlan, before in-loop
  /// reduction recipes are created. Preserve other flags and producer math.
  void applyToPlan(VPlan &Plan) const;
};

} // namespace llvm

#endif // LLVM_TRANSFORMS_VECTORIZE_VPLANREDUCTIONFISSIONFPREORDERING_H
