//===- RISCVVPlanCost.h - Costs derived exclusively from analytics -*- C++
//-*-===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_LIB_TARGET_RISCV_VPLAN_COST_H
#define LLVM_LIB_TARGET_RISCV_VPLAN_COST_H
#include "RISCVVPlanAnalytics.h"
#include "llvm/Support/Error.h"
#include "llvm/Transforms/Vectorize/VPlanRA.h"
namespace llvm::vplan {
struct BodyCost {
  InstructionCost Memory = 0, Arithmetic = 0, Movement = 0, Scalar = 0;
  InstructionCost Divider = 0, Recurrence = 0, LoadUse = 0;
  InstructionCost Spill = 0, Configuration = 0, Total = 0;
};
Expected<BodyCost> computeBodyCost(const Analytics &A);
Expected<VPlanBackendCost> scoreCandidate(const Analytics &A,
                                          const Analytics &Scalar);
json::Object costBreakdown(const BodyCost &C);
} // namespace llvm::vplan
#endif
