// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_LIB_TARGET_RISCV_XIANGSHANV2TARGETTRANSFORMINFO_H
#define LLVM_LIB_TARGET_RISCV_XIANGSHANV2TARGETTRANSFORMINFO_H
#include "RISCVTargetTransformInfo.h"
namespace llvm {
class XiangShanV2TTIImpl : public RISCVTTIImpl {
  using TTI = TargetTransformInfo;
  std::optional<InstructionCost>
  profileOpcodeCost(unsigned Opcode, MVT VT,
                    TTI::TargetCostKind Kind) const override;
  InstructionCost
  profileArithmeticCost(InstructionCost Cost, bool FP, bool Uniform,
                        TTI::TargetCostKind Kind) const override;
  InstructionCost profileMemoryCost(InstructionCost Cost, MemoryCostPath Path,
                                    unsigned Opcode, InstructionCost Count,
                                    TTI::TargetCostKind Kind) const override;

public:
  using RISCVTTIImpl::RISCVTTIImpl;
  StringRef getVPlanCostProfileName() const override {
    return "xiangshan-v2-128";
  }
  InstructionCost getSpillReloadCost(const TTI::SpillReloadAccess &Access,
                                     TTI::TargetCostKind Kind) const override;
};
} // namespace llvm
#endif
