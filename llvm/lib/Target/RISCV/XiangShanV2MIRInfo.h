// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_LIB_TARGET_RISCV_XIANGSHANV2MIRINFO_H
#define LLVM_LIB_TARGET_RISCV_XIANGSHANV2MIRINFO_H
#include "llvm/Analysis/TargetMIRInfo.h"
namespace llvm {
class XiangShanV2MIRInfo final : public TargetMIRInfo {
public:
  StringRef getModelName() const override { return "rtl-service-sum-v1"; }
  StringRef getRevision() const override {
    return "e7bab53e66dfb3c4a1d11cf9519b0396f8576cae";
  }
  Expected<MIRInstructionCost>
  getInstructionCost(const VPlanMIRInstruction &MI) const override;
};
} // namespace llvm
#endif
