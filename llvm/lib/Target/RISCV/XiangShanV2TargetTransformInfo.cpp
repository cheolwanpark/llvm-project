// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "XiangShanV2TargetTransformInfo.h"
#include "llvm/Analysis/VPlanCostProfile.h"
using namespace llvm;
static bool active(TargetTransformInfo::TargetCostKind Kind) {
  return VPlanCostProfileScope::active() &&
         Kind == TargetTransformInfo::TCK_RecipThroughput;
}
std::optional<InstructionCost>
XiangShanV2TTIImpl::profileOpcodeCost(unsigned Op, MVT VT,
                                      TTI::TargetCostKind Kind) const {
  if (!active(Kind))
    return std::nullopt;
  unsigned L = getTLI()->getLMULCost(VT).getValue();
  unsigned Bits = VT.getScalarSizeInBits();
  switch (Op) {
  case RISCV::VSLIDEUP_VI:
  case RISCV::VSLIDEUP_VX:
  case RISCV::VSLIDEDOWN_VI:
  case RISCV::VSLIDEDOWN_VX:
    return L * (L + 1) / 2 + 1;
  case RISCV::VRGATHER_VI:
    return L * L + 1;
  case RISCV::VFDIV_VV:
  case RISCV::VFDIV_VF:
  case RISCV::VFRDIV_VF:
    return L * (Bits == 16   ? 8
                : Bits == 32 ? 10
                             : 15) +
           (Op != RISCV::VFDIV_VV);
  case RISCV::VFSQRT_V:
    return L * (Bits == 16 ? 7 : Bits == 32 ? 10 : 17);
  case RISCV::VDIV_VV:
  case RISCV::VREM_VV:
    return L * (Bits == 8 ? 11 : Bits == 16 ? 13 : Bits == 32 ? 17 : 25);
  case RISCV::VNSRL_WI:
    return std::max(
               1u,
               unsigned(divideCeil(
                   2 * VT.getSizeInBits().getKnownMinValue(),
                   VT.isScalableVector() ? 64 : getST()->getRealMinVLen()))) +
           1;
  default:
    return std::nullopt;
  }
}
InstructionCost
XiangShanV2TTIImpl::profileArithmeticCost(InstructionCost Cost, bool FP,
                                          bool Uniform,
                                          TTI::TargetCostKind Kind) const {
  if (!active(Kind))
    return FP ? Cost * 2 : Cost;
  return Cost + unsigned(Uniform);
}
InstructionCost
XiangShanV2TTIImpl::profileMemoryCost(InstructionCost Cost, MemoryCostPath Path,
                                      unsigned Opcode, InstructionCost Count,
                                      TTI::TargetCostKind Kind) const {
  if (!active(Kind))
    return Cost;
  switch (Path) {
  case MemoryCostPath::Contiguous:
    return Cost + Count;
  case MemoryCostPath::Strided:
    return Cost + 2;
  case MemoryCostPath::GatherScatter:
    return Cost + 1;
  case MemoryCostPath::Segment:
    return Count * (Opcode == Instruction::Load ? 8 : 4) + 1;
  }
  llvm_unreachable("unknown memory cost path");
}
InstructionCost
XiangShanV2TTIImpl::getSpillReloadCost(const TTI::SpillReloadAccess &Access,
                                       TTI::TargetCostKind Kind) const {
  if (active(Kind) && Access.WholeRegister) {
    if (!isPowerOf2_32(Access.RegisterGroup) || Access.RegisterGroup > 8)
      return InstructionCost::getInvalid();
    return Access.RegisterGroup + 1;
  }
  return RISCVTTIImpl::getSpillReloadCost(Access, Kind);
}
