//===- RISCVVPlanRAFeatures.h - Research feature hook --------------*- C++ -*-===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_LIB_TARGET_RISCV_RISCVVPLANRAFEATURES_H
#define LLVM_LIB_TARGET_RISCV_RISCVVPLANRAFEATURES_H

#include "llvm/Support/JSON.h"

namespace llvm {
class MachineFunction;
/// Observe the selected function after vector AND scalar register allocation.
/// This hook must not modify instructions or access benchmark measurements.
/// Feature definitions, units, and aggregation are research decisions.
json::Object collectRISCVVPlanRAFeatures(const MachineFunction &MF);
} // namespace llvm
#endif
