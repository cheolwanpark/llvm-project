// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_LIB_TARGET_RISCV_SATURNTARGETTRANSFORMINFO_H
#define LLVM_LIB_TARGET_RISCV_SATURNTARGETTRANSFORMINFO_H
#include "RISCVCostSheet.h"
#include "RISCVTargetTransformInfo.h"
namespace llvm {
class SaturnTTIImpl : public RISCVTTIImpl {
  using TTI = TargetTransformInfo;
  std::unique_ptr<RISCVCostSheet> Sheet;
  VPlanMIRInstruction query(StringRef Opcode, MVT VT) const;
  std::optional<InstructionCost> price(StringRef Opcode, MVT VT) const;
  std::optional<InstructionCost>
  profileOpcodeCost(unsigned Opcode, MVT VT,
                    TTI::TargetCostKind Kind) const override;
  std::optional<InstructionCost> profileArithmeticInstruction(
      unsigned Opcode, MVT VT, TTI::TargetCostKind Kind,
      TTI::OperandValueInfo O1, TTI::OperandValueInfo O2) const override;
  InstructionCost profileMemoryCost(InstructionCost Cost, MemoryCostPath Path,
                                    unsigned Opcode, TTI::TargetCostKind Kind,
                                    Type *DataTy,
                                    unsigned Fields) const override;

public:
  SaturnTTIImpl(const RISCVTargetMachine *TM, const Function &F);
  InstructionCost
  getRegisterClassSpillReloadCost(unsigned ClassID, bool IsLoad,
                                  TTI::SpillReloadUnits Units,
                                  TTI::TargetCostKind Kind) const override;
  InstructionCost
  getRegisterClassSpillCost(unsigned ClassID,
                            TTI::TargetCostKind Kind) const override;
  InstructionCost
  getRegisterClassReloadCost(unsigned ClassID,
                             TTI::TargetCostKind Kind) const override;
  InstructionCost getArithmeticInstrCost(
      unsigned Opcode, Type *Ty, TTI::TargetCostKind Kind,
      TTI::OperandValueInfo Op1Info = {TTI::OK_AnyValue, TTI::OP_None},
      TTI::OperandValueInfo Op2Info = {TTI::OK_AnyValue, TTI::OP_None},
      ArrayRef<const Value *> Args = {},
      const Instruction *I = nullptr) const override;
  InstructionCost
  getCastInstrCost(unsigned Opcode, Type *Dst, Type *Src,
                   TTI::CastContextHint CCH, TTI::TargetCostKind Kind,
                   const Instruction *I = nullptr) const override;
  InstructionCost
  getIntrinsicInstrCost(const IntrinsicCostAttributes &ICA,
                        TTI::TargetCostKind Kind) const override;
  InstructionCost getMemoryOpCost(
      unsigned Opcode, Type *Ty, Align Alignment, unsigned AddressSpace,
      TTI::TargetCostKind Kind,
      TTI::OperandValueInfo OpInfo = {TTI::OK_AnyValue, TTI::OP_None},
      const Instruction *I = nullptr) const override;
  StringRef getVPlanCostProfileName() const override {
    return "saturn-shuttle-v256d128";
  }
};
} // namespace llvm
#endif
