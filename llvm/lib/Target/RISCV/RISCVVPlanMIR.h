// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_LIB_TARGET_RISCV_RISCVVPLANMIR_H
#define LLVM_LIB_TARGET_RISCV_RISCVVPLANMIR_H
#include "llvm/CodeGen/MachineFunctionPass.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/VPlanBackendResult.h"
namespace llvm {
namespace vplan {
VPlanMIRInstruction collectMIRInstruction(const MachineInstr &MI, bool Text);
Expected<VPlanBackendResult> collectMIRBody(MachineFunction &MF, bool Text);
} // namespace vplan
class RISCVVPlanMIR : public MachineFunctionPass {
  std::optional<Expected<VPlanBackendResult>> &Sink;
  VPlanFeedbackTimer *Timer;
  bool Text;

public:
  static char ID;
  RISCVVPlanMIR(std::optional<Expected<VPlanBackendResult>> &Sink,
                VPlanFeedbackTimer *Timer, bool Text);
  StringRef getPassName() const override {
    return "RISC-V VPlan MIR body observer";
  }
  void getAnalysisUsage(AnalysisUsage &AU) const override;
  bool runOnMachineFunction(MachineFunction &MF) override;
};
} // namespace llvm
#endif
