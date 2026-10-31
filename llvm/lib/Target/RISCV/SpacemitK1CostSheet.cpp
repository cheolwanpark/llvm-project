// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVCostSheet.h"
#include "llvm/Support/MathExtras.h"
using namespace llvm;
namespace {
unsigned wholeGroup(const VPlanMIRInstruction &MI) {
  StringRef Op = MI.BaseOpcode;
  bool Move = Op.starts_with("VMV") && Op.size() > 3 &&
              Op[3] >= '1' && Op[3] <= '8';
  bool WholeLoad = Op.starts_with("VL") && Op.size() > 4 &&
                   Op[2] >= '1' && Op[2] <= '8' && Op.substr(3, 2) == "RE";
  bool WholeStore = Op.starts_with("VS") && Op.size() > 3 &&
                    Op[2] >= '1' && Op[2] <= '8' && Op[3] == 'R';
  if (Op == "COPY" || Move || WholeLoad || WholeStore)
    if (!MI.RegisterGroups8.empty())
      return MI.RegisterGroups8.front() / 8;
  return 0;
}
unsigned fields(StringRef Op) {
  auto P = Op.find("SEG");
  if (P == StringRef::npos || P + 3 >= Op.size())
    return 1;
  return unsigned(Op[P + 3] - '0');
}
} // namespace
// Static occupancy rules transcribed from RISCVSchedSpacemitX60.td.
// These are not vendor-guaranteed timings. See costsheet/k1.md.
Expected<MIRInstructionCost>
SpacemitK1CostSheet::getInstructionCost(const VPlanMIRInstruction &MI) const {
  auto Valid = RISCVCostSheet::getInstructionCost(MI);
  if (!Valid)
    return Valid.takeError();
  if (Valid->Unknown)
    return Valid;
  StringRef Op = MI.BaseOpcode;
  uint64_t Cost = 1;
  StringRef Rule = "assumed-scalar";
  if (MI.Vector && !MI.Configuration) {
    unsigned G = wholeGroup(MI);
    unsigned L = std::max(1u, MI.LMUL8 / 8);
    uint64_t Bits = uint64_t(256) * MI.LMUL8 / 8;
    uint64_t N = MI.SEW ? std::max(uint64_t(1), Bits / MI.SEW) : 1;
    Cost = L;
    Rule = "assumed-simd-groups";
    if (G) {
      if (MI.Load || MI.Store) {
        auto C = spillCost(true, MI.Load, {G, 1});
        if (!C.isValid())
          return createStringError("invalid whole-register memory cost");
        Cost = C.getValue();
      } else {
        Cost = G == 1 ? 4 : 2 * G;
      }
      Rule = "schedule-whole-register";
    } else if (MI.Load || MI.Store) {
      unsigned F = fields(Op), EEW = 0;
      bool Indexed = Op.contains("XEI");
      bool Strided = Op.starts_with("VLSE") || Op.starts_with("VSSE") ||
                     Op.starts_with("VLSSEG") || Op.starts_with("VSSSEG");
      StringRef Tail = Op.drop_until([](char C) { return C >= '0' && C <= '9'; });
      if (F > 1)
        Tail = Tail.drop_front().drop_until([](char C) { return C >= '0' && C <= '9'; });
      Tail = Tail.take_while([](char C) { return C >= '0' && C <= '9'; });
      (void)Tail.getAsInteger(10, EEW);
      if (!Indexed && EEW)
        N = std::max(uint64_t(1), Bits / EEW);
      Cost = F > 1 ? N * F : Indexed ? std::max(uint64_t(1), N / 2)
                    : Strided ? N : MI.Load ? std::max(3u, 2 * L)
                    : L == 8 ? 19 : std::max(3u, 2 * L);
      if (MI.LMUL8 < 8 && !MI.Load && !Strided && !Indexed && F == 1)
        Cost = 2;
      Rule = "schedule-memory-occupancy";
    } else if (Op.contains("DIV") || Op.contains("REM") || Op.contains("SQRT")) {
      Cost = Op.starts_with("VF")
                 ? uint64_t(Op.contains("_VF") ? (MI.SEW == 64 ? 40 : 12)
                                               : (MI.SEW == 16 ? 12 : 40)) * L
                 : 12 * std::max(1u, MI.LMUL8 / 4);
      Rule = "schedule-iterative-occupancy";
    } else if (Op.contains("RED")) {
      Cost = N * (Op.starts_with("VF") ? 4 : 1);
      Rule = "assumed-serial-reduction";
    } else if (Op.contains("GATHER") || Op.contains("COMPRESS") || Op.contains("SLIDE")) {
      Cost = 2 * N;
      Rule = "assumed-element-permute";
    } else if (Op.starts_with("VW") || Op.starts_with("VFW") || Op.starts_with("VFNC") ||
               Op.starts_with("VNS") || Op.starts_with("VNC")) {
      Cost = std::max(1u, MI.LMUL8 / 4);
      Rule = "assumed-wide-service";
    } else if (Op.starts_with("VADD") || Op.starts_with("VSUB") ||
               Op.starts_with("VRSUB") || Op.starts_with("VAND") ||
               Op.starts_with("VOR") || Op.starts_with("VXOR")) {
      Cost = std::max(1u, MI.LMUL8 / 4);
      Rule = "schedule-grouped-alu-occupancy";
    }
  } else if (Op.starts_with("DIV") || Op.starts_with("REM")) {
    Cost = Op.ends_with("W") ? 12 : 20;
    Rule = "schedule-scalar-divide";
  } else if (Op.starts_with("FDIV") || Op.starts_with("FSQRT")) {
    Cost = Op.ends_with("_H") ? 12 : Op.ends_with("_S") ? 15 : 22;
    Rule = "schedule-scalar-fp-iterative";
  }
  return MIRInstructionCost{("k1:" + Rule).str(), false, int64_t(Cost), 1};
}
InstructionCost SpacemitK1CostSheet::spillCost(
    bool Vector, bool IsLoad, TargetTransformInfo::SpillReloadUnits U) const {
  if (!U.isValid())
    return InstructionCost::getInvalid();
  if (!U.Accesses)
    return 0;
  if (!Vector) {
    if (U.Registers > uint64_t(INT64_MAX / 4))
      return InstructionCost::getInvalid();
    return int64_t(U.Registers);
  }
  if (U.Registers % U.Accesses)
    return InstructionCost::getInvalid();
  uint64_t G = U.Registers / U.Accesses;
  if (!isPowerOf2_64(G) || G > 8)
    return InstructionCost::getInvalid();
  uint64_t Unit = G == 1 ? 3 : 2 * G;
  if (U.Accesses > uint64_t(INT64_MAX / 4) / Unit)
    return InstructionCost::getInvalid();
  return int64_t(U.Accesses * Unit);
}
