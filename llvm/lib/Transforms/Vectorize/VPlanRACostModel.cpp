//===- VPlanRACostModel.cpp - Research hook for RA-informed costs -----------===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "VPlanRACostModel.h"

llvm::InstructionCost llvm::costWithRAFeatures(
    const VPlan &Plan, ElementCount VF, InstructionCost OriginalCost,
    const json::Object &Features) {
  // Intentionally neutral. Feature choice and prediction belong to research.
  return OriginalCost;
}
