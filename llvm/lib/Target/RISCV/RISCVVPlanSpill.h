// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_LIB_TARGET_RISCV_VPLAN_SPILL_H
#define LLVM_LIB_TARGET_RISCV_VPLAN_SPILL_H
#include "llvm/CodeGen/MachineFunctionPass.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/VPlanBackendResult.h"
namespace llvm {
namespace vplan {
Error readCandidateIdentity(const Function &F, VPlanBackendResult &Result);
void observeBody(MachineFunction &MF, VPlanBackendResult &Result, bool MIR,
                 bool Text);
void observeCommonBody(MachineFunction &MF, VPlanBackendResult &Result,
                       bool MIR, bool Text);
Error collectSpillAccess(const MachineInstr &MI,
                         std::vector<VPlanSpillAccess> &Accesses);
} // namespace vplan
FunctionPass *createRISCVVPlanTimingMarker(VPlanFeedbackTimer &Timer,
                                           StringRef Phase);
} // namespace llvm
#endif
