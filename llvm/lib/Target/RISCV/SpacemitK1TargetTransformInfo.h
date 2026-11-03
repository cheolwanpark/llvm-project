// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_LIB_TARGET_RISCV_SPACEMITK1TARGETTRANSFORMINFO_H
#define LLVM_LIB_TARGET_RISCV_SPACEMITK1TARGETTRANSFORMINFO_H
#include "RISCVTargetTransformInfo.h"
namespace llvm {
// Keep K1's profile identity while using native RISC-V prices and lowering.
class SpacemitK1TTIImpl : public RISCVTTIImpl {
public:
  using RISCVTTIImpl::RISCVTTIImpl;
  StringRef getVPlanCostProfileName() const override {
    return "spacemit-k1-256";
  }
};
} // namespace llvm
#endif
