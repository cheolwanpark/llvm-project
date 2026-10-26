//===- VPlanRegisterUsageBounds.h - Cheap RVV pressure bounds -----*- C++
//-*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_VECTORIZE_VPLANREGISTERUSAGEBOUNDS_H
#define LLVM_TRANSFORMS_VECTORIZE_VPLANREGISTERUSAGEBOUNDS_H

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Support/Compiler.h"
#include "llvm/Support/TypeSize.h"
#include <cstdint>
#include <optional>

namespace llvm {
class VPlan;
class TargetTransformInfo;

/// Counts for one atomic recipe. Kills includes only distinct, non-persistent
/// values whose sole consumer is this recipe, never a guessed last user.
struct VPRegisterLifetimeCounts {
  uint64_t Definitions = 0;
  uint64_t GuaranteedKills = 0;
};

/// Upper bound over every schedule, including input/output overlap. Persistent
/// values are live throughout. nullopt indicates arithmetic overflow.
LLVM_ABI_FOR_TEST std::optional<uint64_t>
boundVPlanLiveValues(uint64_t Persistent,
                     ArrayRef<VPRegisterLifetimeCounts> Recipes);

struct VPRegisterUsageBound {
  bool Known = false;
  uint64_t Peak = 0;
  uint64_t MaxRegisterGroup = 1;
  bool HasMask = false;
  uint64_t Usage = 0;
  StringRef Reason = "unsupported";
  StringRef Recipe;
  std::optional<unsigned> Opcode;

  bool shouldQuery() const { return !Known || Usage >= 32; }
};

/// Read-only, O(recipes + values + operands) expected time. This is an upper
/// bound for explicitly supported RVV lowering, not exact register saturation
/// and not a replacement for the vectorizer's register-pressure cost model.
/// Unmodelled recipes, types and geometry require a backend query.
LLVM_ABI_FOR_TEST VPRegisterUsageBound computeVPlanRegisterUsageBound(
    const VPlan &Plan, ElementCount VF, const TargetTransformInfo &TTI);
} // namespace llvm

#endif
