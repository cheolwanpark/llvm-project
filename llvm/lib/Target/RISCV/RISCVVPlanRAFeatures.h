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
/// Optional resource_demand.load_use_nodes is a block-local DAG: each node
/// records kind, 128-bit chunks (at least one), and preceding node indices.
/// Only whole, same-shaped physical reaching values connect ordinary unit
/// loads to supported arithmetic; observations never seed the loop backedge.
json::Object collectRISCVVPlanRAFeatures(const MachineFunction &MF);
} // namespace llvm
#endif
