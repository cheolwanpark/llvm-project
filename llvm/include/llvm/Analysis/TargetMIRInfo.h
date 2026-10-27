// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_ANALYSIS_TARGETMIRINFO_H
#define LLVM_ANALYSIS_TARGETMIRINFO_H
#include "llvm/ADT/StringRef.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/VPlanBackendResult.h"
namespace llvm {
/// An exact nominal service demand, in model units (not quarter-cost units).
struct MIRServiceDemand {
  std::string Service;
  int64_t Numerator = 0, Denominator = 1;
};
struct MIRInstructionCost {
  std::string Rule;
  bool Unknown = false;
  std::vector<MIRServiceDemand> Demands;
};
/// Target-owned, read-only pricing of owned MIR facts. No IR or machine pass
/// state, measured timings, or choice of VF enters this interface.
class TargetMIRInfo {
public:
  virtual ~TargetMIRInfo() = default;
  virtual StringRef getModelName() const = 0;
  virtual StringRef getRevision() const = 0;
  virtual Expected<MIRInstructionCost>
  getInstructionCost(const VPlanMIRInstruction &MI) const = 0;
};
} // namespace llvm
#endif
