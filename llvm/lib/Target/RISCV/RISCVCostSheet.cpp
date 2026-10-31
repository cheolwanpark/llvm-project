// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVCostSheet.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/StringSwitch.h"
#include "llvm/Support/MathExtras.h"
#include "llvm/Support/Regex.h"
using namespace llvm;
namespace {
enum class OperationKind {
  FPDivide,
  FPDivideSqrt,
  FPSqrt,
  IndexedLoad,
  IndexedStore,
  Integer,
  IntegerDivide,
  Multiply,
  OpcodeBku,
  OpcodeBrh,
  OpcodeCsr,
  OpcodeF2v,
  OpcodeFalu,
  OpcodeFcvt,
  OpcodeFence,
  OpcodeFmac,
  OpcodeI2f,
  OpcodeI2v,
  OpcodeJmp,
  OpcodeMou,
  OrderedIndexedLoad,
  ScalarLoad,
  ScalarStore,
  SegmentLoad,
  SegmentStore,
  Unknown,
  VectorConvert,
  VectorFMA,
  VectorFP,
  VectorFPDivide,
  VectorFPSqrt,
  VectorInteger,
  VectorIntegerDivide,
  VectorLoad,
  VectorMask,
  VectorMultiply,
  VectorPermute,
  VectorStore
};
struct OpcodeRule {
  StringLiteral Opcode;
  OperationKind Category;
  StringLiteral Form;
};
unsigned instructionPrice(OperationKind Kind, unsigned Precision) {
  if (Precision && Kind != OperationKind::IntegerDivide &&
      Kind != OperationKind::FPDivide && Kind != OperationKind::FPSqrt &&
      Kind != OperationKind::VectorIntegerDivide &&
      Kind != OperationKind::VectorFPDivide &&
      Kind != OperationKind::VectorFPSqrt)
    return 0;
  switch (Kind) {
  case OperationKind::Integer:
    return 1;
  case OperationKind::OpcodeBku:
    return 1;
  case OperationKind::OpcodeBrh:
    return 1;
  case OperationKind::OpcodeCsr:
    return 1;
  case OperationKind::IntegerDivide:
    switch (Precision) {
    case 32:
      return 15;
    case 64:
      return 23;
    default:
      return 0;
    }
  case OperationKind::OpcodeF2v:
    return 1;
  case OperationKind::OpcodeFalu:
    return 1;
  case OperationKind::OpcodeFcvt:
    return 1;
  case OperationKind::FPDivide:
    switch (Precision) {
    case 16:
      return 7;
    case 32:
      return 9;
    case 64:
      return 14;
    default:
      return 0;
    }
  case OperationKind::OpcodeFence:
    return 1;
  case OperationKind::OpcodeFmac:
    return 1;
  case OperationKind::FPSqrt:
    switch (Precision) {
    case 16:
      return 6;
    case 32:
      return 9;
    case 64:
      return 16;
    default:
      return 0;
    }
  case OperationKind::OpcodeI2f:
    return 1;
  case OperationKind::OpcodeI2v:
    return 1;
  case OperationKind::OpcodeJmp:
    return 1;
  case OperationKind::ScalarLoad:
    return 1;
  case OperationKind::Multiply:
    return 1;
  case OperationKind::Unknown:
    return 1;
  case OperationKind::VectorFP:
    return 1;
  case OperationKind::VectorConvert:
    return 1;
  case OperationKind::VectorFPDivide:
    switch (Precision) {
    case 16:
      return 8;
    case 32:
      return 10;
    case 64:
      return 15;
    default:
      return 0;
    }
  case OperationKind::VectorFMA:
    return 1;
  case OperationKind::VectorFPSqrt:
    switch (Precision) {
    case 16:
      return 7;
    case 32:
      return 10;
    case 64:
      return 17;
    default:
      return 0;
    }
  case OperationKind::VectorInteger:
    return 1;
  case OperationKind::VectorIntegerDivide:
    switch (Precision) {
    case 8:
      return 11;
    case 16:
      return 13;
    case 32:
      return 17;
    case 64:
      return 25;
    default:
      return 0;
    }
  case OperationKind::VectorMultiply:
    return 1;
  case OperationKind::VectorMask:
    return 1;
  case OperationKind::VectorLoad:
    return 1;
  case OperationKind::IndexedLoad:
    return 1;
  case OperationKind::OrderedIndexedLoad:
    return 4;
  case OperationKind::VectorPermute:
    return 1;
  case OperationKind::SegmentLoad:
    return 8;
  case OperationKind::SegmentStore:
    return 4;
  case OperationKind::VectorStore:
    return 1;
  case OperationKind::IndexedStore:
    return 1;
  default:
    return 0;
  }
}

#include "RISCVCostSheetTables.inc"
const OpcodeRule *lookup(ArrayRef<OpcodeRule> Table, StringRef Op) {
  auto I = llvm::lower_bound(
      Table, Op, [](const OpcodeRule &R, StringRef S) { return R.Opcode < S; });
  return I != Table.end() && I->Opcode == Op ? &*I : nullptr;
}
MIRInstructionCost unknown(StringRef Base) {
  return {(Base + ":unknown").str(), true, 1, 1};
}
bool legalGroup(unsigned G) { return isPowerOf2_32(G) && G <= 64; }
bool legalSEW(unsigned S) { return S == 8 || S == 16 || S == 32 || S == 64; }
unsigned number(StringRef S) {
  unsigned N = 0;
  if (!S.empty())
    (void)S.getAsInteger(10, N);
  return N;
}
Expected<MIRInstructionCost> price(StringRef Base, StringRef Form,
                                   OperationKind Category, unsigned Work,
                                   unsigned Moves = 0, unsigned Precision = 0) {
  unsigned Unit = instructionPrice(Category, Precision);
  if (!Unit)
    return createStringError("missing MIR operation price/precision");
  MIRInstructionCost R{Form.empty() ? Base.str() : (Base + ":" + Form).str(),
                       Category == OperationKind::Unknown,
                       int64_t(Work) * Unit + Moves, 1};
  return R;
}
InstructionCost priceSpillUnits(bool Tuned, bool Vector, bool IsLoad,
                                TargetTransformInfo::SpillReloadUnits U) {
  if (!U.isValid())
    return InstructionCost::getInvalid();
  uint64_t Cost = !Tuned   ? U.Registers
                  : Vector ? U.Registers + U.Accesses
                           : U.Registers * (IsLoad ? 1 : 2);
  if (Cost > INT64_MAX / 4)
    return InstructionCost::getInvalid();
  return int64_t(Cost);
}
} // namespace

static Expected<MIRInstructionCost>
priceInstruction(const VPlanMIRInstruction &MI, unsigned VLEN, bool Generic) {
  StringRef Base = MI.BaseOpcode;
  if (MI.Configuration)
    return price(Base, "", OperationKind::Integer, 1);
  if (!MI.Vector) {
    if (Base == "PseudoBR" || Base == "PseudoRET")
      return price(Base, "", OperationKind::OpcodeJmp, 1);
    if (MI.Pseudo || Base == "COPY")
      return unknown(Base);
    auto *R = lookup(ScalarOpcodes, Base);
    if (!R)
      return unknown(Base);
    OperationKind Category = R->Category;
    if (Category == OperationKind::ScalarStore)
      return MIRInstructionCost{Base.str(), false, Generic ? 1 : 2, 1};
    if (Category == OperationKind::FPDivideSqrt)
      Category = Base.contains("SQRT") ? OperationKind::FPSqrt
                                       : OperationKind::FPDivide;
    unsigned Precision = 0;
    if (Category == OperationKind::IntegerDivide)
      Precision = Base.ends_with("W") ? 32 : 64;
    if (Category == OperationKind::FPDivide ||
        Category == OperationKind::FPSqrt)
      Precision = Base.ends_with("_H")   ? 16
                  : Base.ends_with("_S") ? 32
                  : Base.ends_with("_D") ? 64
                                         : 0;
    if (!instructionPrice(Category, Precision))
      return unknown(Base);
    if (Generic) {
      unsigned Cost = Category == OperationKind::IntegerDivide         ? 4
                      : Base.starts_with("F") && !MI.Load && !MI.Store ? 2
                                                                       : 1;
      return MIRInstructionCost{Base.str(), false, Cost, 1};
    }
    return price(Base, "", Category, 1, 0, Precision);
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
    if (IsWhole) {
      auto Cost = priceSpillUnits(!Generic, true, MI.Load, {Count, 1});
      if (!Cost.isValid())
        return createStringError("invalid whole-register memory cost");
      return MIRInstructionCost{(Base + ":WHOLE_MEMORY").str(), false,
                                Cost.getValue(), 1};
    }
    return price(Base, "VEC_MVNR", OperationKind::VectorPermute, Count);
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
    StringRef Form;
    if (IsIndexed) {
      if (!legalSEW(SEW) || !legalGroup(MI.IndexEMUL8) ||
          MI.IndexEEW != number(Match[1]) ||
          MI.IndexEMUL8 * SEW != G * MI.IndexEEW)
        return createStringError("missing/invalid indexed geometry");
      EEW = SEW;
      Form = "VEC_I_LDST";
    } else if (Segment.match(Base, &Match)) {
      Strided = !Match[1].empty();
      Fields = number(Match[2]);
      EEW = number(Match[3]);
      Form = Strided ? "VEC_S_LDST" : "VEC_US_LDST";
    } else if (Unit.match(Base, &Match)) {
      Strided = Match[1] == "SE";
      EEW = number(Match[2]);
      Form = Strided ? "VEC_S_LDST" : "VEC_US_LDST";
    } else
      return unknown(Base);
    if ((VLEN / 8) * G < EEW || G * Fields > 64)
      return createStringError("illegal memory register geometry");
    unsigned Work;
    OperationKind Category;
    if (Fields > 1) {
      Category =
          MI.Load ? OperationKind::SegmentLoad : OperationKind::SegmentStore;
      Work = (VLEN / 8) * G / EEW * Fields;
    } else if (Form == "VEC_US_LDST") {
      Category =
          MI.Load ? OperationKind::VectorLoad : OperationKind::VectorStore;
      Work = std::max(1u, G / 8);
    } else {
      Category = MI.Load ? (Base.starts_with("VLOXEI")
                                ? OperationKind::OrderedIndexedLoad
                                : OperationKind::IndexedLoad)
                         : OperationKind::IndexedStore;
      Work = (VLEN / 8) * G / EEW;
    }
    if (Generic) {
      unsigned Cost = Fields > 1             ? (VLEN / 8) * G / EEW * Fields
                      : Strided || IsIndexed ? (VLEN / 8) * G / EEW
                                             : std::max(1u, G / 8);
      return MIRInstructionCost{Base.str(), false, Cost, 1};
    }
    return price(Base, Form, Category, Work, Strided ? 2 : 1);
  }
  if (!R)
    return unknown(Base);
  StringRef Form = R->Form;
  OperationKind Category = R->Category;
  bool Mask = SEW == 1 && (Form == "dummy" || Form == "VEC_M0X");
  if ((!Mask && !legalSEW(SEW)) || (VLEN / 8) * G < SEW)
    return createStringError("illegal LMUL/SEW");
  bool Wide =
      StringSwitch<bool>(Form)
          .Cases({"VEC_VWW", "VEC_VVW", "VEC_WVW", "VEC_WVV"}, true)
          .Cases({"VEC_VXW", "VEC_WXW", "VEC_WXV", "VEC_VFW", "VEC_WFW"}, true)
          .Default(false);
  if (Wide && G > 32)
    return createStringError("wide operand EMUL exceeds 8");
  if ((Form == "VEC_VFRED" || Form == "VEC_VFREDOSUM") && SEW != 16 &&
      SEW != 32 && SEW != 64)
    return createStringError("invalid FP reduction SEW");
  unsigned L = std::max(1u, G / 8), W = std::max(1u, G / 4);
  using Shape = std::pair<unsigned, unsigned>;
  Shape ShapeValue =
      StringSwitch<Shape>(Form)
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
  if (Form == "VEC_SLIDEUP" || Form == "VEC_SLIDEDOWN") {
    static constexpr unsigned Counts[] = {1, 3, 10, 36};
    ShapeValue = {Counts[Log2_32(L)], 1};
  } else if (Form == "VEC_COMPRESS") {
    static constexpr unsigned Counts[] = {1, 4, 13, 43};
    ShapeValue = {Counts[Log2_32(L)], 0};
  } else if (Form == "VEC_VFRED") {
    // Python modulo is nonnegative even for fractional LMUL fold counts.
    int Fold = (std::min(int(Log2_32(G)) - 3, 0) +
                (SEW == 16   ? 3
                 : SEW == 32 ? 2
                             : 1) +
                8) %
               8;
    ShapeValue = {L + unsigned(Fold), 0};
  } else if (Form == "VEC_VFREDOSUM") {
    ShapeValue = {std::max(1u, (VLEN / 8) * G / SEW), 0};
  }
  if (!ShapeValue.first)
    return unknown(Base);
  if (Category == OperationKind::VectorFPDivide && Base.contains("SQRT"))
    Category = OperationKind::VectorFPSqrt;
  unsigned Precision = Category == OperationKind::VectorFPDivide ||
                               Category == OperationKind::VectorFPSqrt ||
                               Category == OperationKind::VectorIntegerDivide
                           ? SEW
                           : 0;
  if (!instructionPrice(Category, Precision)) {
    if (Precision)
      return createStringError("unsupported vector arithmetic precision");
    Category = OperationKind::Unknown;
  }
  if (Generic) {
    if (Category == OperationKind::Unknown)
      return unknown(Base);
    unsigned N = std::max(1u, (VLEN / 8) * G / SEW);
    unsigned Cost = L;
    if (Form == "dummy" || Form == "VEC_M0X" || Form == "VEC_0XV")
      Cost = 1;
    else if (Form == "VEC_VFREDOSUM")
      Cost = N;
    else if (Form == "VEC_VRED" || Form == "VEC_VFRED")
      Cost = std::max(1u, Log2_32_Ceil(N));
    else if (Form == "VEC_RGATHER" || Form == "VEC_RGATHEREI16")
      Cost = L * L;
    else if (Category == OperationKind::VectorIntegerDivide)
      Cost = 4 * L;
    else if (Base.starts_with("VF") && Category != OperationKind::VectorConvert)
      Cost = 2 * L;
    return MIRInstructionCost{Base.str(), false, Cost, 1};
  }
  return price(Base, Form, Category, ShapeValue.first, ShapeValue.second,
               Precision);
}

Expected<MIRInstructionCost>
XiangShanCostSheet::getInstructionCost(const VPlanMIRInstruction &MI) const {
  return priceInstruction(MI, NominalVLEN, false);
}
Expected<MIRInstructionCost>
RISCVCostSheet::getInstructionCost(const VPlanMIRInstruction &MI) const {
  return priceInstruction(MI, NominalVLEN, true);
}
InstructionCost
RISCVCostSheet::spillCost(bool Vector, bool IsLoad,
                          TargetTransformInfo::SpillReloadUnits U) const {
  return priceSpillUnits(false, Vector, IsLoad, U);
}
InstructionCost
XiangShanCostSheet::spillCost(bool Vector, bool IsLoad,
                              TargetTransformInfo::SpillReloadUnits U) const {
  return priceSpillUnits(true, Vector, IsLoad, U);
}
