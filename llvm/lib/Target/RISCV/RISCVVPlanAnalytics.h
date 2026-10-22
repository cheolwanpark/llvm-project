//===- RISCVVPlanAnalytics.h - Passive MIR observations -----------*- C++
//-*-===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_LIB_TARGET_RISCV_VPLAN_ANALYTICS_H
#define LLVM_LIB_TARGET_RISCV_VPLAN_ANALYTICS_H
#include "llvm/CodeGen/MachineFunctionPass.h"
#include "llvm/Support/JSON.h"
namespace llvm {
namespace vplan {
json::Object collectAnalytics(const MachineFunction &MF);
}
class RISCVVPlanAnalytics : public MachineFunctionPass {
  bool Seen = false;
public:
  static char ID;
  RISCVVPlanAnalytics();
  StringRef getPassName() const override {
    return "RISC-V local cost observations";
  }
  void getAnalysisUsage(AnalysisUsage &AU) const override;
  bool runOnMachineFunction(MachineFunction &MF) override;
  bool doFinalization(Module &) override;
};
} // namespace llvm
#endif
