// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVCostSheet.h"
#include <algorithm>
using namespace llvm;

// Direct MIR prices in native-relative units; rules: costsheet/saturn.md.
Expected<MIRInstructionCost>
SaturnCostSheet::getInstructionCost(const VPlanMIRInstruction &MI) const {
  auto Cost = RISCVCostSheet::getInstructionCost(MI);
  if (!Cost || Cost->Unknown)
    return Cost;
  StringRef Op = MI.BaseOpcode;
  // Native vector FMA opcode sequences cost one LMUL unit. Ordinary FP
  // arithmetic retains the generic two-unit price. IR legalization and
  // materialization remain the responsibility of the actual native TTI.
  bool Fused = Op.starts_with("VFMACC") || Op.starts_with("VFNMACC") ||
               Op.starts_with("VFMSAC") || Op.starts_with("VFNMSAC") ||
               Op.starts_with("VFMADD") || Op.starts_with("VFNMADD") ||
               Op.starts_with("VFMSUB") || Op.starts_with("VFNMSUB") ||
               Op.starts_with("VFWMACC") || Op.starts_with("VFWNMACC") ||
               Op.starts_with("VFWMSAC") || Op.starts_with("VFWNMSAC");
  if (MI.Vector && !MI.Configuration && Fused)
    return MIRInstructionCost{"saturn:native-relative-fma", false,
                              int64_t(std::max(1u, MI.LMUL8 / 8)), 1};
  Cost->Rule = "saturn:native-relative:" + Cost->Rule;
  return Cost;
}
