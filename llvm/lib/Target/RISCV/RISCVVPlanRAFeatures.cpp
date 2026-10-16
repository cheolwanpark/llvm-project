//===- RISCVVPlanRAFeatures.cpp - Research feature hook --------------------===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVVPlanRAFeatures.h"
#include "llvm/CodeGen/MachineFunction.h"

llvm::json::Object
llvm::collectRISCVVPlanRAFeatures(const MachineFunction &MF) {
  // No chosen metric or heuristic yet. The driver also retains the complete MIR.
  return {};
}
