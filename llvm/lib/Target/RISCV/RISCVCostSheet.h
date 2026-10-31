// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_LIB_TARGET_RISCV_RISCVCOSTSHEET_H
#define LLVM_LIB_TARGET_RISCV_RISCVCOSTSHEET_H
#include "llvm/Analysis/TargetMIRInfo.h"
#include "llvm/Analysis/TargetTransformInfo.h"
namespace llvm {
/// Immutable direct pricing of owned instruction facts. The same query is used
/// by the MIR adapter and the TTI lowering adapter; no compiler state is
/// retained.
class RISCVCostSheet : public TargetMIRInfo {
protected:
  const unsigned NominalVLEN;
  const std::string CPU;

public:
  explicit RISCVCostSheet(unsigned VLEN, StringRef CPU = "generic")
      : NominalVLEN(VLEN), CPU(CPU.str()) {}
  StringRef getCPU() const override { return CPU; }
  unsigned getNominalVLEN() const override { return NominalVLEN; }
  StringRef getModelName() const override { return "riscv-generic-direct-v1"; }
  StringRef getRevision() const override { return "generic-v1"; }
  Expected<MIRInstructionCost>
  getInstructionCost(const VPlanMIRInstruction &Query) const override;
  virtual InstructionCost
  spillCost(bool Vector, bool IsLoad,
            TargetTransformInfo::SpillReloadUnits U) const;
};
class XiangShanCostSheet : public RISCVCostSheet {
public:
  XiangShanCostSheet() : RISCVCostSheet(128, "xiangshan-kunminghu") {}
  StringRef getModelName() const override { return "xiangshan-direct-v1"; }
  StringRef getRevision() const override {
    return "e7bab53e66dfb3c4a1d11cf9519b0396f8576cae";
  }
  Expected<MIRInstructionCost>
  getInstructionCost(const VPlanMIRInstruction &Query) const override;
  InstructionCost
  spillCost(bool Vector, bool IsLoad,
            TargetTransformInfo::SpillReloadUnits U) const override;
};
class XiangShanMIRInfo final : public TargetMIRInfo {
  XiangShanCostSheet Sheet;
public:
  StringRef getModelName() const override { return Sheet.getModelName(); }
  StringRef getRevision() const override { return Sheet.getRevision(); }
  StringRef getCPU() const override { return Sheet.getCPU(); }
  unsigned getNominalVLEN() const override { return Sheet.getNominalVLEN(); }
  Expected<MIRInstructionCost> getInstructionCost(
      const VPlanMIRInstruction &MI) const override {
    return Sheet.getInstructionCost(MI);
  }
};
class SaturnCostSheet : public RISCVCostSheet {
public:
  SaturnCostSheet() : RISCVCostSheet(256, "saturn-shuttle-v256d128") {}
  StringRef getModelName() const override { return "saturn-shuttle-direct-v1"; }
  StringRef getRevision() const override { return "dfe75de2a8868d51d42c20612821431a9fcf645e+vat-clear"; }
  Expected<MIRInstructionCost>
  getInstructionCost(const VPlanMIRInstruction &MI) const override;
  InstructionCost spillCost(bool Vector, bool IsLoad,
      TargetTransformInfo::SpillReloadUnits Units) const override;
};
class SaturnMIRInfo final : public TargetMIRInfo {
  SaturnCostSheet Sheet;
public:
  StringRef getModelName() const override { return Sheet.getModelName(); }
  StringRef getRevision() const override { return Sheet.getRevision(); }
  StringRef getCPU() const override { return Sheet.getCPU(); }
  unsigned getNominalVLEN() const override { return Sheet.getNominalVLEN(); }
  Expected<MIRInstructionCost> getInstructionCost(
      const VPlanMIRInstruction &MI) const override {
    return Sheet.getInstructionCost(MI);
  }
};
class SpacemitK1CostSheet : public RISCVCostSheet {
public:
  SpacemitK1CostSheet() : RISCVCostSheet(256, "spacemit-x60") {}
  StringRef getModelName() const override { return "spacemit-k1-direct-v1"; }
  StringRef getRevision() const override { return "llvm-x60-occupancy-v1"; }
  Expected<MIRInstructionCost>
  getInstructionCost(const VPlanMIRInstruction &MI) const override;
  InstructionCost spillCost(bool Vector, bool IsLoad,
      TargetTransformInfo::SpillReloadUnits Units) const override;
};
class SpacemitK1MIRInfo final : public TargetMIRInfo {
  SpacemitK1CostSheet Sheet;
public:
  StringRef getModelName() const override { return Sheet.getModelName(); }
  StringRef getRevision() const override { return Sheet.getRevision(); }
  StringRef getCPU() const override { return Sheet.getCPU(); }
  unsigned getNominalVLEN() const override { return Sheet.getNominalVLEN(); }
  Expected<MIRInstructionCost> getInstructionCost(
      const VPlanMIRInstruction &MI) const override {
    return Sheet.getInstructionCost(MI);
  }
};
} // namespace llvm
#endif
