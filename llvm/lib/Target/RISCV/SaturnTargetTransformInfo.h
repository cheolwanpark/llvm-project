// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_LIB_TARGET_RISCV_SATURNTARGETTRANSFORMINFO_H
#define LLVM_LIB_TARGET_RISCV_SATURNTARGETTRANSFORMINFO_H
#include "RISCVTargetTransformInfo.h"
namespace llvm {
// Saturn uses native RISC-V prices and lowering sequences. Keep its profile
// identity so CPU/VLEN selection and whole-loop retry policy remain explicit.
class SaturnTTIImpl : public RISCVTTIImpl {
public:
  using RISCVTTIImpl::RISCVTTIImpl;
  StringRef getVPlanCostProfileName() const override {
    return "saturn-shuttle-v256d128";
  }
};
} // namespace llvm
#endif
