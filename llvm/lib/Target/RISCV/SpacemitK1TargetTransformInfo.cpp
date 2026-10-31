// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "SpacemitK1TargetTransformInfo.h"
#include "llvm/Analysis/VPlanCostProfile.h"
using namespace llvm;
static bool active(TargetTransformInfo::TargetCostKind Kind) {
  return VPlanCostProfileScope::active() &&
         Kind == TargetTransformInfo::TCK_RecipThroughput;
}
SpacemitK1TTIImpl::SpacemitK1TTIImpl(const RISCVTargetMachine *TM,
                                       const Function &F)
    : RISCVTTIImpl(TM, F), Sheet(std::make_unique<SpacemitK1CostSheet>()) {}

VPlanMIRInstruction SpacemitK1TTIImpl::query(StringRef Op, MVT VT) const {
  VPlanMIRInstruction Q;
  Q.Opcode = Q.BaseOpcode = Op.str();
  Q.Vector = VT.isVector();
  Q.Configuration = Op.contains("VSET");
  Q.SEW = VT.getScalarSizeInBits();
  if (Q.Vector) {
    if (VT.isFixedLengthVector())
      VT = getTLI()->getContainerForFixedLengthVector(VT);
    // RVV scalable types encode their minimum size at vscale=1 (64 bits).
    Q.LMUL8 = Q.SEW == 1 ? 8 : VT.getSizeInBits().getKnownMinValue() / 8;
  }
  return Q;
}
std::optional<InstructionCost> SpacemitK1TTIImpl::price(StringRef Op,
                                                         MVT VT) const {
  auto C = Sheet->getInstructionCost(query(Op, VT));
  if (!C) {
    consumeError(C.takeError());
    return InstructionCost::getInvalid();
  }
  if (C->Unknown)
    return std::nullopt; // Explicit inherited fallback for unmodeled sequences.
  return InstructionCost(C->Numerator) / C->Denominator;
}
std::optional<InstructionCost>
SpacemitK1TTIImpl::profileOpcodeCost(unsigned Op, MVT VT,
                                      TTI::TargetCostKind Kind) const {
  if (!active(Kind))
    return std::nullopt;
  StringRef Name = getST()->getInstrInfo()->getName(Op);
  // Inherited conversion sequences pass the wide result type for VFWCVT.
  // Its vtype is instead the narrow source geometry.
  if (Name.starts_with("VFWCVT") && VT.getScalarSizeInBits() > 8)
    VT = VT.changeVectorElementType(
        MVT::getIntegerVT(VT.getScalarSizeInBits() / 2));
  return price(Name, VT);
}
std::optional<InstructionCost> SpacemitK1TTIImpl::profileArithmeticInstruction(
    unsigned Opcode, MVT VT, TTI::TargetCostKind Kind, TTI::OperandValueInfo O1,
    TTI::OperandValueInfo O2) const {
  if (!active(Kind))
    return std::nullopt;
  StringRef Base;
  bool Commutative = false;
  switch (Opcode) {
  case Instruction::Add:
    Base = "VADD";
    Commutative = true;
    break;
  case Instruction::Sub:
    Base = "VSUB";
    break;
  case Instruction::Mul:
    Base = "VMUL";
    Commutative = true;
    break;
  case Instruction::SDiv:
    Base = "VDIV";
    break;
  case Instruction::UDiv:
    Base = "VDIVU";
    break;
  case Instruction::SRem:
    Base = "VREM";
    break;
  case Instruction::URem:
    Base = "VREMU";
    break;
  case Instruction::Shl:
    Base = "VSLL";
    break;
  case Instruction::LShr:
    Base = "VSRL";
    break;
  case Instruction::AShr:
    Base = "VSRA";
    break;
  case Instruction::And:
    Base = "VAND";
    Commutative = true;
    break;
  case Instruction::Or:
    Base = "VOR";
    Commutative = true;
    break;
  case Instruction::Xor:
    Base = "VXOR";
    Commutative = true;
    break;
  case Instruction::FAdd:
    Base = "VFADD";
    Commutative = true;
    break;
  case Instruction::FSub:
    Base = "VFSUB";
    break;
  case Instruction::FMul:
    Base = "VFMUL";
    Commutative = true;
    break;
  case Instruction::FDiv:
    Base = "VFDIV";
    break;
  case Instruction::FNeg:
    return price("VFSGNJN_VV", VT);
  default:
    return std::nullopt;
  }
  if (VT.getScalarSizeInBits() == 1) {
    if (Opcode == Instruction::And)
      return price("VMAND_MM", VT);
    if (Opcode == Instruction::Or)
      return price("VMOR_MM", VT);
    if (Opcode == Instruction::Xor)
      return price("VMXOR_MM", VT);
    return std::nullopt;
  }
  bool Scalar = O2.isUniform();
  if (!Scalar && O1.isUniform()) {
    if (Commutative)
      Scalar = true;
    else if (Opcode == Instruction::Sub) {
      Base = "VRSUB";
      Scalar = true;
    } else if (Opcode == Instruction::FSub) {
      Base = "VFRSUB";
      Scalar = true;
    } else if (Opcode == Instruction::FDiv) {
      Base = "VFRDIV";
      Scalar = true;
    }
    // Other first-uniform forms need a broadcast and keep the native sequence.
    else
      return std::nullopt;
  }
  std::string Name =
      Base.str() + (Scalar ? (Base.starts_with("VF") ? "_VF" : "_VX") : "_VV");
  return price(Name, VT);
}
InstructionCost
SpacemitK1TTIImpl::profileMemoryCost(InstructionCost Cost, MemoryCostPath Path,
                                      unsigned Opcode, TTI::TargetCostKind Kind,
                                      Type *DataTy, unsigned Fields) const {
  if (!active(Kind))
    return Cost;
  auto LT = getTypeLegalizationCost(DataTy);
  bool Load = Opcode == Instruction::Load;
  std::string Name = Load ? "VL" : "VS";
  if (Path == MemoryCostPath::Strided)
    Name += "S";
  if (Path == MemoryCostPath::Segment)
    Name += "SEG" + std::to_string(Fields);
  Name += "E" + std::to_string(LT.second.getScalarSizeInBits()) + "_V";
  auto Q = query(Name, LT.second);
  Q.Load = Load;
  Q.Store = !Load;
  auto C = Sheet->getInstructionCost(Q);
  if (!C) {
    consumeError(C.takeError());
    return InstructionCost::getInvalid();
  }
  if (C->Unknown)
    return Cost;
  return LT.first * (InstructionCost(C->Numerator) / C->Denominator);
}

InstructionCost SpacemitK1TTIImpl::getRegisterClassSpillReloadCost(
    unsigned C, bool Load, TTI::SpillReloadUnits U,
    TTI::TargetCostKind Kind) const {
  if (!active(Kind))
    return RISCVTTIImpl::getRegisterClassSpillReloadCost(C, Load, U, Kind);
  return Sheet->spillCost(C == RISCVRegisterClass::VRRC, Load, U);
}
InstructionCost
SpacemitK1TTIImpl::getRegisterClassSpillCost(unsigned C,
                                              TTI::TargetCostKind Kind) const {
  return active(Kind)
             ? Sheet->spillCost(C == RISCVRegisterClass::VRRC, false, {1, 1})
             : RISCVTTIImpl::getRegisterClassSpillCost(C, Kind);
}
InstructionCost
SpacemitK1TTIImpl::getRegisterClassReloadCost(unsigned C,
                                               TTI::TargetCostKind Kind) const {
  return active(Kind)
             ? Sheet->spillCost(C == RISCVRegisterClass::VRRC, true, {1, 1})
             : RISCVTTIImpl::getRegisterClassReloadCost(C, Kind);
}
InstructionCost SpacemitK1TTIImpl::getArithmeticInstrCost(
    unsigned Opcode, Type *Ty, TTI::TargetCostKind Kind,
    TTI::OperandValueInfo O1, TTI::OperandValueInfo O2,
    ArrayRef<const Value *> Args, const Instruction *I) const {
  if (active(Kind) && !Ty->isVectorTy()) {
    auto LT = getTypeLegalizationCost(Ty);
    StringRef Op;
    bool FP = Ty->isFloatingPointTy();
    switch (Opcode) {
    case Instruction::Add:
      Op = "ADD";
      break;
    case Instruction::Sub:
      Op = "SUB";
      break;
    case Instruction::Mul:
      Op = "MUL";
      break;
    case Instruction::SDiv:
      Op = "DIV";
      break;
    case Instruction::UDiv:
      Op = "DIVU";
      break;
    case Instruction::SRem:
      Op = "REM";
      break;
    case Instruction::URem:
      Op = "REMU";
      break;
    case Instruction::Shl:
      Op = "SLL";
      break;
    case Instruction::LShr:
      Op = "SRL";
      break;
    case Instruction::AShr:
      Op = "SRA";
      break;
    case Instruction::And:
      Op = "AND";
      break;
    case Instruction::Or:
      Op = "OR";
      break;
    case Instruction::Xor:
      Op = "XOR";
      break;
    case Instruction::FAdd:
      Op = "FADD";
      break;
    case Instruction::FSub:
      Op = "FSUB";
      break;
    case Instruction::FMul:
      Op = "FMUL";
      break;
    case Instruction::FNeg:
      Op = "FSGNJN";
      break;
    case Instruction::FDiv:
      Op = "FDIV";
      break;
    default:
      break;
    }
    if (!Op.empty()) {
      std::string Name = Op.str();
      if (FP)
        Name += Ty->isHalfTy() ? "_H" : Ty->isFloatTy() ? "_S" : "_D";
      else if (Ty->getScalarSizeInBits() <= 32 &&
               (Opcode == Instruction::SDiv || Opcode == Instruction::UDiv ||
                Opcode == Instruction::SRem || Opcode == Instruction::URem))
        Name += "W";
      if (auto C = price(Name, LT.second))
        return LT.first * *C;
    }
  }
  return RISCVTTIImpl::getArithmeticInstrCost(Opcode, Ty, Kind, O1, O2, Args,
                                              I);
}
InstructionCost
SpacemitK1TTIImpl::getMemoryOpCost(unsigned Opcode, Type *Ty, Align Alignment,
                                    unsigned AS, TTI::TargetCostKind Kind,
                                    TTI::OperandValueInfo O,
                                    const Instruction *I) const {
  if (active(Kind)) {
    auto LT = getTypeLegalizationCost(Ty);
    unsigned Bits = LT.second.getScalarSizeInBits();
    bool Load = Opcode == Instruction::Load;
    std::string Name;
    if (LT.second.isVector())
      Name = std::string(Load ? "VLE" : "VSE") + std::to_string(Bits) + "_V";
    else if (Ty->isFloatingPointTy())
      Name = std::string(Load ? "FL" : "FS") + (Bits == 64   ? "D"
                                                : Bits == 32 ? "W"
                                                             : "H");
    else
      Name = std::string(Load ? "L" : "S") + (Bits == 64   ? "D"
                                              : Bits == 32 ? "W"
                                              : Bits == 16 ? "H"
                                                           : "B");
    auto Q = query(Name, LT.second);
    Q.Load = Load;
    Q.Store = !Load;
    auto C = Sheet->getInstructionCost(Q);
    if (!C) {
      consumeError(C.takeError());
      return InstructionCost::getInvalid();
    }
    if (!C->Unknown) {
      InstructionCost Materialize = 0;
      if (!Load && O.isConstant() && Ty->isVectorTy())
        Materialize = getStoreImmCost(Ty, O, Kind);
      return Materialize +
             LT.first * (InstructionCost(C->Numerator) / C->Denominator);
    }
  }
  return RISCVTTIImpl::getMemoryOpCost(Opcode, Ty, Alignment, AS, Kind, O, I);
}

InstructionCost
SpacemitK1TTIImpl::getIntrinsicInstrCost(const IntrinsicCostAttributes &ICA,
                                          TTI::TargetCostKind Kind) const {
  Type *Ty = ICA.getReturnType();
  if (active(Kind) && Ty->isFloatingPointTy() &&
      (ICA.getID() == Intrinsic::sqrt || ICA.getID() == Intrinsic::fma)) {
    auto LT = getTypeLegalizationCost(Ty);
    std::string Name = ICA.getID() == Intrinsic::sqrt ? "FSQRT" : "FMADD";
    Name += Ty->isHalfTy() ? "_H" : Ty->isFloatTy() ? "_S" : "_D";
    if (auto C = price(Name, LT.second))
      return LT.first * *C;
  }
  return RISCVTTIImpl::getIntrinsicInstrCost(ICA, Kind);
}
InstructionCost SpacemitK1TTIImpl::getCastInstrCost(
    unsigned Opcode, Type *Dst, Type *Src, TTI::CastContextHint CCH,
    TTI::TargetCostKind Kind, const Instruction *I) const {
  if (!active(Kind))
    return RISCVTTIImpl::getCastInstrCost(Opcode, Dst, Src, CCH, Kind, I);
  if (Src->isVectorTy() && Dst->isVectorTy() &&
      cast<VectorType>(Src)->getElementCount() ==
          cast<VectorType>(Dst)->getElementCount()) {
    unsigned SB = Src->getScalarSizeInBits(), DB = Dst->getScalarSizeInBits();
    bool Widen = DB == 2 * SB, Narrow = SB == 2 * DB;
    bool Same = SB == DB;
    std::string Name;
    switch (Opcode) {
    case Instruction::FPExt:
      if (Widen)
        Name = "VFWCVT_F_F_V";
      break;
    case Instruction::FPTrunc:
      if (Narrow)
        Name = "VFNCVT_F_F_W";
      break;
    case Instruction::FPToSI:
    case Instruction::FPToUI:
      if (Same || Widen || Narrow)
        Name = std::string(Widen    ? "VFWCVT_RTZ_"
                           : Narrow ? "VFNCVT_RTZ_"
                                    : "VFCVT_RTZ_") +
               (Opcode == Instruction::FPToUI ? "XU_F_" : "X_F_") +
               (Narrow ? "W" : "V");
      break;
    case Instruction::SIToFP:
    case Instruction::UIToFP:
      if (Same || Widen || Narrow)
        Name = std::string(Widen    ? "VFWCVT_F_"
                           : Narrow ? "VFNCVT_F_"
                                    : "VFCVT_F_") +
               (Opcode == Instruction::UIToFP ? "XU_" : "X_") +
               (Narrow ? "W" : "V");
      break;
    default:
      break;
    }
    if (!Name.empty()) {
      auto SrcLT = getTypeLegalizationCost(Src);
      auto DstLT = getTypeLegalizationCost(Dst);
      // Only replace a single legal lowering; promotions and multi-instruction
      // conversions retain the inherited sequence construction.
      if (SrcLT.first == DstLT.first && SrcLT.second.isVector() &&
          DstLT.second.isVector() && SrcLT.second.getScalarSizeInBits() == SB &&
          DstLT.second.getScalarSizeInBits() == DB) {
        auto LT = Widen ? SrcLT : DstLT;
        if (auto C = price(Name, LT.second))
          return LT.first * *C;
      }
    }
  }
  if (!Src->isVectorTy() && !Dst->isVectorTy()) {
    auto Format = [](Type *Ty, bool Unsigned) -> std::string {
      if (Ty->isFloatingPointTy())
        return Ty->isHalfTy() ? "H" : Ty->isFloatTy() ? "S" : "D";
      return std::string(Ty->getScalarSizeInBits() <= 32 ? "W" : "L") +
             (Unsigned ? "U" : "");
    };
    switch (Opcode) {
    case Instruction::FPExt:
    case Instruction::FPTrunc:
    case Instruction::FPToSI:
    case Instruction::FPToUI:
    case Instruction::SIToFP:
    case Instruction::UIToFP: {
      auto LT = getTypeLegalizationCost(Dst);
      std::string Name = "FCVT_" + Format(Dst, Opcode == Instruction::FPToUI) +
                         "_" + Format(Src, Opcode == Instruction::UIToFP);
      if (auto C = price(Name, LT.second))
        return LT.first * *C;
      break;
    }
    default:
      break;
    }
  }
  // Inherited legalization builds opcode sequences; their individual prices
  // return through profileOpcodeCost. Unsupported sequences stay native.
  return RISCVTTIImpl::getCastInstrCost(Opcode, Dst, Src, CCH, Kind, I);
}
