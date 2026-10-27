// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "XiangShanV2MIRInfo.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/StringSwitch.h"
#include "llvm/Support/MathExtras.h"
#include "llvm/Support/Regex.h"
using namespace llvm;
namespace {
struct OpcodeRule {
  StringLiteral Opcode, Service, Split;
};
struct ServiceRate {
  StringLiteral Service;
  unsigned Precision, Rate;
};
#include "XiangShanV2MIRInfoTables.inc"
const OpcodeRule *lookup(ArrayRef<OpcodeRule> Table, StringRef Op) {
  auto I = llvm::lower_bound(
      Table, Op, [](const OpcodeRule &R, StringRef S) { return R.Opcode < S; });
  return I != Table.end() && I->Opcode == Op ? &*I : nullptr;
}
MIRInstructionCost unknown(StringRef Base) {
  return {(Base + ":unknown").str(), true, {{"unknown", 1, 1}}};
}
bool legalGroup(unsigned G) { return isPowerOf2_32(G) && G <= 64; }
bool legalSEW(unsigned S) { return S == 8 || S == 16 || S == 32 || S == 64; }
unsigned number(StringRef S) {
  unsigned N = 0;
  if (!S.empty())
    (void)S.getAsInteger(10, N);
  return N;
}
Expected<MIRInstructionCost> price(StringRef Base, StringRef Split,
                                   StringRef Service, unsigned Work,
                                   unsigned Moves = 0, bool FPMoves = false,
                                   unsigned Precision = 0) {
  auto Rate = llvm::find_if(ServiceRates, [&](const auto &R) {
    return R.Service == Service && R.Precision == Precision;
  });
  if (Rate == std::end(ServiceRates))
    return createStringError("missing MIR service rate/precision: " + Service);
  MIRInstructionCost R{Split.empty() ? Base.str() : (Base + ":" + Split).str(),
                       Service == "unknown",
                       {}};
  R.Demands.push_back({Service.str(), int64_t(Work) * Rate->Rate, 1});
  if (Moves)
    R.Demands.push_back({FPMoves ? "f2v" : "i2v", Moves, 1});
  return R;
}
} // namespace

Expected<MIRInstructionCost>
XiangShanV2MIRInfo::getInstructionCost(const VPlanMIRInstruction &MI) const {
  StringRef Base = MI.BaseOpcode;
  if (MI.Configuration)
    return price(Base, "", "alu", 1);
  if (!MI.Vector) {
    if (Base == "PseudoBR" || Base == "PseudoRET")
      return price(Base, "", "jmp", 1);
    if (MI.Pseudo || Base == "COPY")
      return unknown(Base);
    auto *R = lookup(ScalarOpcodes, Base);
    if (!R)
      return unknown(Base);
    StringRef Service = R->Service;
    if (Service == "stu")
      return MIRInstructionCost{
          Base.str(), false, {{"sta", 1, 1}, {"std", 1, 1}}};
    if (Service == "fDivSqrt")
      Service = Base.contains("SQRT") ? "fsqrt" : "fdiv";
    unsigned Precision = 0;
    if (Service == "div")
      Precision = Base.ends_with("W") ? 32 : 64;
    if (Service == "fdiv" || Service == "fsqrt")
      Precision = Base.ends_with("_H")   ? 16
                  : Base.ends_with("_S") ? 32
                  : Base.ends_with("_D") ? 64
                                         : 0;
    if (!llvm::any_of(ServiceRates,
                      [&](const auto &R) { return R.Service == Service; }))
      return unknown(Base);
    return price(Base, "", Service, 1, 0, false, Precision);
  }

  // Match ISA forms, not the pseudo-name suffix (which can encode index EMUL).
  static const Regex Whole("^(VL([1248])RE(8|16|32|64)|VS([1248])R)_V$");
  static const Regex Copy("^VMV([1248])R_V$");
  SmallVector<StringRef, 8> Match;
  bool IsWhole = Whole.match(Base, &Match);
  unsigned Count = IsWhole ? number(Match[2].empty() ? Match[4] : Match[2]) : 0;
  bool IsCopy = Copy.match(Base, &Match);
  if (IsCopy)
    Count = number(Match[1]);
  if (Base == "COPY" || IsWhole || IsCopy) {
    if (Base == "COPY" && !MI.RegisterGroups8.empty())
      Count = MI.RegisterGroups8.front() / 8;
    if (!isPowerOf2_32(Count) || Count > 8 || MI.RegisterGroups8.empty() ||
        llvm::any_of(MI.RegisterGroups8,
                     [&](unsigned G) { return G != Count * 8; }))
      return createStringError("whole-register grouping unknown/invalid");
    return price(Base, IsWhole ? "WHOLE_MEMORY" : "VEC_MVNR",
                 IsWhole ? (MI.Load ? "vload128" : "vstore128") : "vppu", Count,
                 IsWhole ? 1 : 0);
  }
  auto *R = lookup(VectorOpcodes, Base);
  unsigned G = MI.LMUL8, SEW = MI.SEW;
  if (!G) {
    if (!R && !MI.Load && !MI.Store)
      return unknown(Base);
    return createStringError("missing vector LMUL/EMUL");
  }
  if (!legalGroup(G))
    return createStringError("illegal LMUL/EMUL");
  if (MI.Load || MI.Store) {
    static const Regex Indexed("^V[LS][UO]XEI(8|16|32|64)_V$");
    static const Regex Segment("^V[LS](S?)SEG([2-8])E(8|16|32|64)_V$");
    static const Regex Unit("^V[LS](E|SE)(8|16|32|64)_V$");
    bool IsIndexed = Indexed.match(Base, &Match);
    unsigned Fields = 1, EEW = 0;
    bool Strided = false;
    StringRef Split;
    if (IsIndexed) {
      if (!legalSEW(SEW) || !legalGroup(MI.IndexEMUL8) ||
          MI.IndexEEW != number(Match[1]) ||
          MI.IndexEMUL8 * SEW != G * MI.IndexEEW)
        return createStringError("missing/invalid indexed geometry");
      EEW = SEW;
      Split = "VEC_I_LDST";
    } else if (Segment.match(Base, &Match)) {
      Strided = !Match[1].empty();
      Fields = number(Match[2]);
      EEW = number(Match[3]);
      Split = Strided ? "VEC_S_LDST" : "VEC_US_LDST";
    } else if (Unit.match(Base, &Match)) {
      Strided = Match[1] == "SE";
      EEW = number(Match[2]);
      Split = Strided ? "VEC_S_LDST" : "VEC_US_LDST";
    } else
      return unknown(Base);
    if (16 * G < EEW || G * Fields > 64)
      return createStringError("illegal memory register geometry");
    unsigned Work;
    StringRef Service;
    if (Fields > 1) {
      Service = MI.Load ? "vsegload" : "vsegstore";
      Work = 16 * G / EEW * Fields;
    } else if (Split == "VEC_US_LDST") {
      Service = MI.Load ? "vload128" : "vstore128";
      Work = std::max(1u, G / 8);
    } else {
      Service = MI.Load ? (Base.starts_with("VLOXEI") ? "vload_ordered"
                                                      : "vload_element")
                        : "vstore_element";
      Work = 16 * G / EEW;
    }
    return price(Base, Split, Service, Work, Strided ? 2 : 1);
  }
  if (!R)
    return unknown(Base);
  StringRef Split = R->Split, Service = R->Service;
  bool Mask = SEW == 1 && (Split == "dummy" || Split == "VEC_M0X");
  if ((!Mask && !legalSEW(SEW)) || 16 * G < SEW)
    return createStringError("illegal LMUL/SEW");
  bool Wide =
      StringSwitch<bool>(Split)
          .Cases({"VEC_VWW", "VEC_VVW", "VEC_WVW", "VEC_WVV"}, true)
          .Cases({"VEC_VXW", "VEC_WXW", "VEC_WXV", "VEC_VFW", "VEC_WFW"}, true)
          .Default(false);
  if (Wide && G > 32)
    return createStringError("wide operand EMUL exceeds 8");
  if ((Split == "VEC_VFRED" || Split == "VEC_VFREDOSUM") && SEW != 16 &&
      SEW != 32 && SEW != 64)
    return createStringError("invalid FP reduction SEW");
  unsigned L = std::max(1u, G / 8), W = std::max(1u, G / 4);
  using Shape = std::pair<unsigned, unsigned>;
  Shape ShapeValue =
      StringSwitch<Shape>(Split)
          .Cases({"dummy", "SCA_SIM"}, {1, 0})
          .Cases({"VEC_VVV", "VEC_VVM", "VEC_EXT2", "VEC_EXT4"}, {L, 0})
          .Cases({"VEC_EXT8", "VEC_VRED", "VEC_M0X"}, {L, 0})
          .Cases({"VEC_VXV", "VEC_VFV", "VEC_VXM", "VEC_VFM"}, {L, 1})
          .Cases({"VEC_SLIDE1UP", "VEC_FSLIDE1UP"}, {L, 1})
          .Case("VEC_0XV", {1, 1})
          .Case("VEC_VWW", {2 * L, 0})
          .Cases({"VEC_VVW", "VEC_WVW", "VEC_WVV"}, {W, 0})
          .Cases({"VEC_VXW", "VEC_WXW", "VEC_WXV", "VEC_VFW", "VEC_WFW"},
                 {W, 1})
          .Cases({"VEC_SLIDE1DOWN", "VEC_FSLIDE1DOWN"}, {2 * L - 1, 1})
          .Case("VEC_RGATHER", {L * L, 0})
          .Case("VEC_RGATHER_VX", {L * L, 1})
          .Case("VEC_RGATHEREI16", {L * L * (SEW == 8 && G != 64 ? 2 : 1), 0})
          .Case("VEC_MVV", {2 * L - 1, 0})
          .Default({0, 0});
  if (Split == "VEC_SLIDEUP" || Split == "VEC_SLIDEDOWN") {
    static constexpr unsigned Counts[] = {1, 3, 10, 36};
    ShapeValue = {Counts[Log2_32(L)], 1};
  } else if (Split == "VEC_COMPRESS") {
    static constexpr unsigned Counts[] = {1, 4, 13, 43};
    ShapeValue = {Counts[Log2_32(L)], 0};
  } else if (Split == "VEC_VFRED") {
    // Python modulo is nonnegative even for fractional LMUL fold counts.
    int Fold = (std::min(int(Log2_32(G)) - 3, 0) +
                (SEW == 16   ? 3
                 : SEW == 32 ? 2
                             : 1) +
                8) %
               8;
    ShapeValue = {L + unsigned(Fold), 0};
  } else if (Split == "VEC_VFREDOSUM") {
    ShapeValue = {std::max(1u, 16 * G / SEW), 0};
  }
  if (!ShapeValue.first)
    return unknown(Base);
  if (Service == "vfdiv" && Base.contains("SQRT"))
    Service = "vfsqrt";
  unsigned Precision =
      Service == "vfdiv" || Service == "vfsqrt" || Service == "vidiv" ? SEW : 0;
  if (!llvm::any_of(ServiceRates,
                    [&](const auto &R) { return R.Service == Service; }))
    Service = "unknown";
  bool FPMoves = StringSwitch<bool>(Split)
                     .Cases({"VEC_VFV", "VEC_VFM", "VEC_VFW", "VEC_WFW"}, true)
                     .Cases({"VEC_FSLIDE1UP", "VEC_FSLIDE1DOWN"}, true)
                     .Default(false);
  return price(Base, Split, Service, ShapeValue.first, ShapeValue.second,
               FPMoves || Base == "VFMV_S_F", Precision);
}
