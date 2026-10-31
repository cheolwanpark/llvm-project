// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVCostSheet.h"
#include "llvm/ADT/StringSwitch.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/MathExtras.h"
#include <optional>
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
// These instruction-form classes are shared by observed MIR and the TTI's
// expected lowering sequences through the CostSheet query. Indexing uses LMUL8
// only after the common geometry validator has accepted the query.
enum class OccupancyFamily {
  None,
  SlideUpVX,
  SlideOther,
  GatherVXVI,
  GatherVV,
  GatherEI16,
  Compress,
  IntegerReduction,
  FPReduction,
  FPOrderedReduction,
  FPWideOrderedReduction,
  FPWideUnorderedReduction
};
struct Occupancy {
  unsigned Cost;
  StringRef Rule;
};
std::optional<Occupancy> tableOccupancy(StringRef Op, unsigned LMUL8,
                                      unsigned SEW) {
  auto Family = StringSwitch<OccupancyFamily>(Op)
      .Case("VSLIDEUP_VX", OccupancyFamily::SlideUpVX)
      .Cases({"VSLIDEDOWN_VX", "VSLIDEUP_VI", "VSLIDEDOWN_VI",
              "VSLIDE1UP_VX", "VSLIDE1DOWN_VX", "VFSLIDE1UP_VF",
              "VFSLIDE1DOWN_VF"}, OccupancyFamily::SlideOther)
      .Cases({"VRGATHER_VX", "VRGATHER_VI"}, OccupancyFamily::GatherVXVI)
      .Case("VRGATHER_VV", OccupancyFamily::GatherVV)
      .Case("VRGATHEREI16_VV", OccupancyFamily::GatherEI16)
      .Case("VCOMPRESS_VM", OccupancyFamily::Compress)
      .Cases({"VREDSUM_VS", "VREDAND_VS", "VREDOR_VS", "VREDXOR_VS",
              "VREDMIN_VS", "VREDMINU_VS", "VREDMAX_VS", "VREDMAXU_VS",
              "VWREDSUM_VS", "VWREDSUMU_VS"},
             OccupancyFamily::IntegerReduction)
      .Cases({"VFREDUSUM_VS", "VFREDMIN_VS", "VFREDMAX_VS"},
             OccupancyFamily::FPReduction)
      .Case("VFREDOSUM_VS", OccupancyFamily::FPOrderedReduction)
      .Case("VFWREDOSUM_VS", OccupancyFamily::FPWideOrderedReduction)
      .Case("VFWREDUSUM_VS", OccupancyFamily::FPWideUnorderedReduction)
      .Default(OccupancyFamily::None);
  // Explicit ReleaseAtCycles from scheduler blob
  // 3d97bb05692912dc73c2ebbf03f121446f3331c1. Columns: mf8..m8.
  static constexpr unsigned SlideUp[] = {1, 1, 1, 2, 4, 8, 16};
  static constexpr unsigned SlideOther[] = {1, 1, 1, 3, 5, 9, 17};
  static constexpr unsigned Gather[] = {1, 1, 1, 4, 16, 64, 256};
  static constexpr unsigned GatherEI16E8[] = {1, 1, 2, 8, 32, 128, 256};
  static constexpr unsigned Compress[] = {1, 1, 1, 3, 10, 36, 136};
  static constexpr unsigned IntegerRed[] = {1, 1, 2, 2, 4, 10, 35};
  static constexpr unsigned FPRed[] = {8, 8, 8, 8, 14, 20, 57};
  static constexpr unsigned FPOrdered16[] = {8, 8, 20, 24, 48, 96, 384};
  static constexpr unsigned FPOrdered32[] = {8, 8, 8, 12, 24, 48, 192};
  static constexpr unsigned FPOrdered64[] = {6, 6, 6, 6, 12, 24, 96};
  static constexpr unsigned FPWide16[] = {11, 11, 27, 32, 64, 128, 512};
  static constexpr unsigned FPWide32[] = {11, 11, 11, 16, 32, 64, 256};
  unsigned I = Log2_32(LMUL8);
  switch (Family) {
  case OccupancyFamily::SlideUpVX:
    return Occupancy{SlideUp[I], "schedule-slide-up-vx"};
  case OccupancyFamily::SlideOther:
    return Occupancy{SlideOther[I], "schedule-slide-vi-down-slide1"};
  case OccupancyFamily::GatherVXVI:
    return Occupancy{SlideUp[I], "schedule-gather-vx-vi"};
  case OccupancyFamily::GatherVV:
    return Occupancy{Gather[I], "schedule-gather-vv"};
  case OccupancyFamily::GatherEI16:
    return Occupancy{SEW == 8 ? GatherEI16E8[I] : Gather[I],
                     "schedule-gather-ei16"};
  case OccupancyFamily::Compress:
    return Occupancy{Compress[I], "schedule-compress"};
  case OccupancyFamily::IntegerReduction:
    return Occupancy{IntegerRed[I], "schedule-integer-reduction"};
  case OccupancyFamily::FPReduction:
    return Occupancy{FPRed[I], "schedule-fp-unordered-minmax-reduction"};
  case OccupancyFamily::FPOrderedReduction:
    return Occupancy{SEW == 16 ? FPOrdered16[I]
                    : SEW == 32 ? FPOrdered32[I] : FPOrdered64[I],
                     "schedule-fp-ordered-reduction"};
  case OccupancyFamily::FPWideOrderedReduction:
  case OccupancyFamily::FPWideUnorderedReduction:
    // RVV widening FP reductions have e16/e32 source elements. e64 has
    // no corresponding occupancy evidence or legal widening destination.
    if (SEW != 16 && SEW != 32)
      return std::nullopt;
    return Occupancy{SEW == 16 ? FPWide16[I] : FPWide32[I],
                     Family == OccupancyFamily::FPWideOrderedReduction
                         ? "schedule-fp-widening-ordered-reduction"
                         : "schedule-fp-widening-unordered-reduction"};
  case OccupancyFamily::None:
    return std::nullopt;
  }
  llvm_unreachable("unknown occupancy family");
}
enum class IterativeFamily {
  None, Integer, FPDivideVF, FPReverseDivideVF, FPDivideVV, FPSqrt
};
IterativeFamily iterativeFamily(StringRef Op) {
  return StringSwitch<IterativeFamily>(Op)
      .Cases({"VDIV_VV", "VDIV_VX", "VDIVU_VV", "VDIVU_VX", "VREM_VV",
              "VREM_VX", "VREMU_VV", "VREMU_VX"}, IterativeFamily::Integer)
      .Case("VFDIV_VF", IterativeFamily::FPDivideVF)
      .Case("VFRDIV_VF", IterativeFamily::FPReverseDivideVF)
      .Case("VFDIV_VV", IterativeFamily::FPDivideVV)
      .Case("VFSQRT_V", IterativeFamily::FPSqrt)
      .Default(IterativeFamily::None);
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
  if (MI.Vector && (Op == "VFWREDOSUM_VS" || Op == "VFWREDUSUM_VS") &&
      MI.SEW != 16 && MI.SEW != 32)
    return createStringError("missing K1 widening FP reduction price");
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
    } else if (auto Table = tableOccupancy(Op, MI.LMUL8, MI.SEW)) {
      Cost = Table->Cost;
      Rule = Table->Rule;
    } else if (auto Family = iterativeFamily(Op);
               Family != IterativeFamily::None) {
      switch (Family) {
      case IterativeFamily::Integer:
        Cost = 12 * std::max(1u, MI.LMUL8 / 4);
        Rule = "schedule-integer-divide-remainder";
        break;
      case IterativeFamily::FPDivideVF:
      case IterativeFamily::FPReverseDivideVF:
        // Normal and reverse divide share an explicit ReleaseAtCycles class.
        // The 18*LMUL normal e64 divide latency comment is not an occupancy.
        Cost = uint64_t(MI.SEW == 64 ? 40 : 12) * L;
        Rule = Family == IterativeFamily::FPDivideVF
                   ? "schedule-fp-divide-vf" : "schedule-fp-reverse-divide-vf";
        break;
      case IterativeFamily::FPDivideVV:
      case IterativeFamily::FPSqrt:
        Cost = uint64_t(MI.SEW == 16 ? 12 : 40) * L;
        Rule = Family == IterativeFamily::FPDivideVV
                   ? "schedule-fp-divide-vv" : "schedule-fp-sqrt";
        break;
      case IterativeFamily::None:
        llvm_unreachable("unclassified iterative operation");
      }
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
