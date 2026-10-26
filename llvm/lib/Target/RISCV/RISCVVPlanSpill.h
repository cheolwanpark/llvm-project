// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_LIB_TARGET_RISCV_VPLAN_SPILL_H
#define LLVM_LIB_TARGET_RISCV_VPLAN_SPILL_H
#include "llvm/CodeGen/MachineFunctionPass.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/VPlanBackendResult.h"
namespace llvm {
namespace vplan {
Expected<VPlanBackendResult> collectVectorSpills(MachineFunction &MF);
Error collectVectorSpillAccess(const MachineInstr &MI,
                               std::vector<VPlanVectorSpillAccess> &Accesses);
} // namespace vplan
class RISCVVPlanSpill : public MachineFunctionPass {
  std::optional<Expected<VPlanBackendResult>> &Sink;
  VPlanFeedbackTimer *Timer;

public:
  static char ID;
  RISCVVPlanSpill(std::optional<Expected<VPlanBackendResult>> &Sink,
                  VPlanFeedbackTimer *Timer);
  StringRef getPassName() const override {
    return "RISC-V VPlan vector spill observer";
  }
  void getAnalysisUsage(AnalysisUsage &AU) const override;
  bool runOnMachineFunction(MachineFunction &MF) override;
};
FunctionPass *createRISCVVPlanTimingMarker(VPlanFeedbackTimer &Timer,
                                           StringRef Phase);
} // namespace llvm
#endif
