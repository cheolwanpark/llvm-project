//===- VPlanCostProfile.h - Scoped candidate throughput costs -----*- C++
//-*-===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_ANALYSIS_VPLANCOSTPROFILE_H
#define LLVM_ANALYSIS_VPLANCOSTPROFILE_H
#include "llvm/Support/Compiler.h"
namespace llvm {
/// Scope only explicit candidate cost queries. Never span planning or codegen.
class LLVM_ABI VPlanCostProfileScope {
  bool Previous;

public:
  explicit VPlanCostProfileScope(bool Enabled);
  ~VPlanCostProfileScope();
  VPlanCostProfileScope(const VPlanCostProfileScope &) = delete;
  VPlanCostProfileScope &operator=(const VPlanCostProfileScope &) = delete;
  static bool active();
};
} // namespace llvm
#endif
