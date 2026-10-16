//===- VPlanRACostModel.h - Research hook for RA-informed costs ----*- C++ -*-===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_LIB_TRANSFORMS_VECTORIZE_VPLANRACOSTMODEL_H
#define LLVM_LIB_TRANSFORMS_VECTORIZE_VPLANRACOSTMODEL_H

#include "llvm/Support/InstructionCost.h"
#include "llvm/Support/JSON.h"
#include "llvm/Support/TypeSize.h"

namespace llvm {
class VPlan;
/// Research hook: return the effective main-loop body cost in LLVM cost units.
/// Do not read measurement labels, identify kernels, or alter the candidate set.
InstructionCost costWithRAFeatures(const VPlan &Plan, ElementCount VF,
                                  InstructionCost OriginalCost,
                                  const json::Object &Features);
} // namespace llvm
#endif
