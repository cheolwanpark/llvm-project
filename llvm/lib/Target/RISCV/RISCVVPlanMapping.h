// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_LIB_TARGET_RISCV_VPLAN_MAPPING_H
#define LLVM_LIB_TARGET_RISCV_VPLAN_MAPPING_H
#include "llvm/ADT/SmallVector.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/VPlanBackendResult.h"
namespace llvm {
class FunctionPass;
FunctionPass *createRISCVVPlanMappingVerifier();
class MachineBasicBlock;
class MachineFunction;
namespace vplan {
/// Pointers are local to one invocation at one observer stage.
Expected<SmallVector<const MachineBasicBlock *>>
mapProbeBody(MachineFunction &MF, VPlanBackendObservation &Evidence);
} // namespace vplan
} // namespace llvm
#endif
