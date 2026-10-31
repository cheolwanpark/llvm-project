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
// Nominal service costs; derivations and assumptions: costsheet/saturn.md.
Expected<MIRInstructionCost>
SaturnCostSheet::getInstructionCost(const VPlanMIRInstruction &MI) const {
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
    uint64_t Bits = uint64_t(256) * MI.LMUL8 / 8;
    uint64_t N = MI.SEW ? std::max(uint64_t(1), Bits / MI.SEW) : 1;
    Cost = std::max(uint64_t(1), divideCeil(Bits, uint64_t(128)));
    Rule = "rtl-simd-groups";
    if (G) {
      if (MI.Load || MI.Store) {
        auto C = spillCost(true, MI.Load, {G, 1});
        if (!C.isValid())
          return createStringError("invalid whole-register memory cost");
        Cost = C.getValue();
      } else {
        Cost = 2 * G;
      }
      Rule = "derived-whole-register";
    } else if (MI.Load || MI.Store) {
      unsigned F = fields(Op);
      bool Indexed = Op.contains("XEI");
      bool Strided = Op.starts_with("VLSE") || Op.starts_with("VSSE") ||
                     Op.starts_with("VLSSEG") || Op.starts_with("VSSSEG");
      // Memory EEW comes from the opcode, not necessarily current SEW.
      unsigned EEW = 0;
      StringRef Tail = Op.drop_until([](char C) { return C >= '0' && C <= '9'; });
      if (F > 1)
        Tail = Tail.drop_front().drop_until([](char C) { return C >= '0' && C <= '9'; });
      Tail = Tail.take_while([](char C) { return C >= '0' && C <= '9'; });
      (void)Tail.getAsInteger(10, EEW);
      if (!Indexed && EEW)
        N = std::max(uint64_t(1), Bits / EEW);
      Cost = Indexed || Strided ? N * F
                               : std::max(uint64_t(1), divideCeil(Bits * F, uint64_t(128)));
      Rule = F > 1 ? "assumed-segment-service" : "derived-memory-service";
    } else if (Op.contains("DIV") || Op.contains("REM") || Op.contains("SQRT")) {
      Cost = 64 * N;
      Rule = "assumed-iterative-upper-bound";
    } else if (Op.contains("RED")) {
      Cost = N * (Op.starts_with("VF") ? 4 : 1);
      Rule = "assumed-serial-reduction";
    } else if (Op.contains("GATHER") || Op.contains("COMPRESS")) {
      Cost = 2 * N;
      Rule = "assumed-element-read-write";
    } else if (Op.starts_with("VW") || Op.starts_with("VFW") ||
               Op.starts_with("VNS") || Op.starts_with("VNC") || Op.starts_with("VFNC")) {
      Cost *= 2;
      Rule = "assumed-wide-service";
    }
  } else if (Op.starts_with("DIV") || Op.starts_with("REM") ||
             Op.starts_with("FDIV") || Op.starts_with("FSQRT")) {
    Cost = 64;
    Rule = "assumed-iterative-upper-bound";
  }
  return MIRInstructionCost{("saturn:" + Rule).str(), false, int64_t(Cost), 1};
}
InstructionCost SaturnCostSheet::spillCost(
    bool Vector, bool IsLoad, TargetTransformInfo::SpillReloadUnits U) const {
  if (!U.isValid() || U.Registers > uint64_t(INT64_MAX / 8))
    return InstructionCost::getInvalid();
  return int64_t(U.Registers * (Vector ? 2 : 1));
}
