// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_LIB_TARGET_RISCV_RISCVGENERICMIRINFO_H
#define LLVM_LIB_TARGET_RISCV_RISCVGENERICMIRINFO_H
#include "llvm/Analysis/TargetMIRInfo.h"
#include "llvm/TargetParser/SubtargetFeature.h"
namespace llvm {
class RISCVSubtarget;
class RISCVGenericMIRInfo final : public TargetMIRInfo {
  unsigned VLEN, DLen, XLen;
  FeatureBitset Features;
  std::string CPU;
  int64_t GroupCosts[7], GatherCosts[7];
  bool OptimizedSegment[9];

public:
  explicit RISCVGenericMIRInfo(const RISCVSubtarget &ST);
  StringRef getModelName() const override { return "riscv-generic-mirinfo-v1"; }
  StringRef getRevision() const override { return "generic-mirinfo-native-v1"; }
  StringRef getCPU() const override { return CPU; }
  unsigned getNominalVLEN() const override { return VLEN; }
  Expected<MIRInstructionCost>
  getInstructionCost(const VPlanMIRInstruction &MI) const override;
};
} // namespace llvm
#endif
