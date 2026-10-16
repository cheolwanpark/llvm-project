//===- VPlanRACostModel.h - Research hook for RA-informed costs ----*- C++ -*-===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_LIB_TRANSFORMS_VECTORIZE_VPLANRACOSTMODEL_H
#define LLVM_LIB_TRANSFORMS_VECTORIZE_VPLANRACOSTMODEL_H

#include "llvm/ADT/DenseMap.h"
#include "llvm/Support/InstructionCost.h"
#include "llvm/Support/JSON.h"
#include "llvm/Support/TypeSize.h"

namespace llvm {
class VPlan;
namespace detail {
/// Split a masked-access delay into a reusable predicate component and a
/// recurring service residual. Delay must be valid and nonnegative, in the
/// caller's accumulation units.
/// A divisor of one is full sharing; zero disables sharing. Unknown predicates
/// always retain the full independent delay. The production model uses four.
class LLVM_ABI VPlanRAPredicateCost {
  unsigned SharedDivisor;
  InstructionCost Residual = 0;
  DenseMap<int64_t, InstructionCost> Shared;

public:
  explicit VPlanRAPredicateCost(unsigned SharedDivisor)
      : SharedDivisor(SharedDivisor) {}
  void add(InstructionCost Delay, int64_t Predicate);
  InstructionCost getCost() const;
};
} // namespace detail
/// Research hook: return the effective main-loop body cost in LLVM cost units.
/// Do not read measurement labels, identify kernels, or alter the candidate set.
LLVM_ABI InstructionCost costWithRAFeatures(const VPlan &Plan, ElementCount VF,
                                          InstructionCost OriginalCost,
                                          const json::Object &Features);
} // namespace llvm
#endif
