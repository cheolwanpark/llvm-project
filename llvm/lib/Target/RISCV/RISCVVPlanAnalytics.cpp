//===- RISCVVPlanAnalytics.cpp - Cost-independent post-RA facts
//-------------===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVVPlanAnalytics.h"
#include "RISCVInstrInfo.h"
#include "RISCVSubtarget.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/StringSwitch.h"
#include "llvm/CodeGen/LivePhysRegs.h"
#include "llvm/CodeGen/MachineDominators.h"
#include "llvm/CodeGen/MachineFrameInfo.h"
#include "llvm/CodeGen/MachineLoopInfo.h"
#include "llvm/CodeGen/MachineRegisterInfo.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Metadata.h"
#include "llvm/Transforms/Vectorize/VPlanRA.h"
using namespace llvm;
using namespace llvm::vplan;
json::Value llvm::vplan::toJSON(const Operand &V) {
  return json::Object{{"Reg", json::Value(V.Reg)},
                      {"Name", json::Value(V.Name)},
                      {"Units", json::Value(V.Units)},
                      {"Group8", json::Value(V.Group8)},
                      {"Vector", json::Value(V.Vector)},
                      {"Def", json::Value(V.Def)},
                      {"Use", json::Value(V.Use)},
                      {"Implicit", json::Value(V.Implicit)},
                      {"Dead", json::Value(V.Dead)},
                      {"Undef", json::Value(V.Undef)},
                      {"EarlyClobber", json::Value(V.EarlyClobber)},
                      {"Tied", json::Value(V.Tied)},
                      {"SubReg", json::Value(V.SubReg)}};
}
bool llvm::vplan::fromJSON(const json::Value &V, Operand &R, json::Path P) {
  json::ObjectMapper O(V, P);
  return O && O.map("Reg", R.Reg) && O.map("Name", R.Name) &&
         O.map("Units", R.Units) && O.map("Group8", R.Group8) &&
         O.map("Vector", R.Vector) && O.map("Def", R.Def) &&
         O.map("Use", R.Use) && O.map("Implicit", R.Implicit) &&
         O.map("Dead", R.Dead) && O.map("Undef", R.Undef) &&
         O.map("EarlyClobber", R.EarlyClobber) && O.map("Tied", R.Tied) &&
         O.map("SubReg", R.SubReg);
}
json::Value llvm::vplan::toJSON(const InstructionInfo &V) {
  return json::Object{{"ID", json::Value(V.ID)},
                      {"Block", json::Value(V.Block)},
                      {"Opcode", json::Value(V.Opcode)},
                      {"Base", json::Value(V.Base)},
                      {"Category", json::Value(V.Category)},
                      {"SEW", json::Value(V.SEW)},
                      {"Group8", json::Value(V.Group8)},
                      {"IndexSEW", json::Value(V.IndexSEW)},
                      {"IndexGroup8", json::Value(V.IndexGroup8)},
                      {"Predicate", json::Value(V.Predicate)},
                      {"StackSlot", json::Value(V.StackSlot)},
                      {"Bytes", json::Value(V.Bytes)},
                      {"ScalableBytes", json::Value(V.ScalableBytes)},
                      {"Stack", json::Value(V.Stack)},
                      {"Spill", json::Value(V.Spill)},
                      {"Load", json::Value(V.Load)},
                      {"Store", json::Value(V.Store)},
                      {"Masked", json::Value(V.Masked)},
                      {"Meta", json::Value(V.Meta)},
                      {"Barrier", json::Value(V.Barrier)},
                      {"ConfigUnused", json::Value(V.ConfigUnused)},
                      {"SameCopy", json::Value(V.SameCopy)},
                      {"Operands", json::Value(V.Operands)},
                      {"Immediates", json::Value(V.Immediates)}};
}
bool llvm::vplan::fromJSON(const json::Value &V, InstructionInfo &R,
                           json::Path P) {
  json::ObjectMapper O(V, P);
  return O && O.map("ID", R.ID) && O.map("Block", R.Block) &&
         O.map("Opcode", R.Opcode) && O.map("Base", R.Base) &&
         O.map("Category", R.Category) && O.map("SEW", R.SEW) &&
         O.map("Group8", R.Group8) && O.map("IndexSEW", R.IndexSEW) &&
         O.map("IndexGroup8", R.IndexGroup8) &&
         O.map("Predicate", R.Predicate) && O.map("StackSlot", R.StackSlot) &&
         O.map("Bytes", R.Bytes) && O.map("ScalableBytes", R.ScalableBytes) &&
         O.map("Stack", R.Stack) && O.map("Spill", R.Spill) &&
         O.map("Load", R.Load) && O.map("Store", R.Store) &&
         O.map("Masked", R.Masked) && O.map("Meta", R.Meta) &&
         O.map("Barrier", R.Barrier) && O.map("ConfigUnused", R.ConfigUnused) &&
         O.map("SameCopy", R.SameCopy) && O.map("Operands", R.Operands) &&
         O.map("Immediates", R.Immediates);
}
json::Value llvm::vplan::toJSON(const Edge &V) {
  return json::Object{{"Source", json::Value(V.Source)},
                      {"Destination", json::Value(V.Destination)},
                      {"OperandIndex", json::Value(V.OperandIndex)},
                      {"Distance", json::Value(V.Distance)},
                      {"WholeValue", json::Value(V.WholeValue)}};
}
bool llvm::vplan::fromJSON(const json::Value &V, Edge &R, json::Path P) {
  json::ObjectMapper O(V, P);
  return O && O.map("Source", R.Source) &&
         O.map("Destination", R.Destination) &&
         O.map("OperandIndex", R.OperandIndex) &&
         O.map("Distance", R.Distance) && O.map("WholeValue", R.WholeValue);
}
json::Value llvm::vplan::toJSON(const Block &V) {
  return json::Object{{"ID", json::Value(V.ID)},
                      {"Role", json::Value(V.Role)},
                      {"Successors", json::Value(V.Successors)}};
}
bool llvm::vplan::fromJSON(const json::Value &V, Block &R, json::Path P) {
  json::ObjectMapper O(V, P);
  return O && O.map("ID", R.ID) && O.map("Role", R.Role) &&
         O.map("Successors", R.Successors);
}
json::Value llvm::vplan::toJSON(const Analytics &V) {
  return json::Object{
      {"Version", json::Value(V.Version)},
      {"RunID", json::Value(V.RunID)},
      {"Candidate", json::Value(V.Candidate)},
      {"Function", json::Value(V.Function)},
      {"CPU", json::Value(V.CPU)},
      {"Stage", json::Value(V.Stage)},
      {"Error", json::Value(V.Error)},
      {"DependencyCoverage", json::Value(V.DependencyCoverage)},
      {"VLen", json::Value(V.VLen)},
      {"Width", json::Value(V.Width)},
      {"VF", json::Value(V.VF)},
      {"ScalableVF", json::Value(V.ScalableVF)},
      {"MaxTripCount", json::Value(V.MaxTripCount)},
      {"ExactTripCount", json::Value(V.ExactTripCount)},
      {"ScalarTail", json::Value(V.ScalarTail)},
      {"Header", json::Value(V.Header)},
      {"Latch", json::Value(V.Latch)},
      {"PeakLiveVectorRegisters", json::Value(V.PeakLiveVectorRegisters)},
      {"Blocks", json::Value(V.Blocks)},
      {"Instructions", json::Value(V.Instructions)},
      {"Edges", json::Value(V.Edges)}};
}
bool llvm::vplan::fromJSON(const json::Value &V, Analytics &R, json::Path P) {
  json::ObjectMapper O(V, P);
  return O && O.map("Version", R.Version) && O.map("RunID", R.RunID) &&
         O.map("Candidate", R.Candidate) && O.map("Function", R.Function) &&
         O.map("CPU", R.CPU) && O.map("Stage", R.Stage) &&
         O.map("Error", R.Error) &&
         O.map("DependencyCoverage", R.DependencyCoverage) &&
         O.map("VLen", R.VLen) && O.map("Width", R.Width) &&
         O.map("VF", R.VF) && O.map("ScalableVF", R.ScalableVF) &&
         O.map("MaxTripCount", R.MaxTripCount) &&
         O.map("ExactTripCount", R.ExactTripCount) &&
         O.map("ScalarTail", R.ScalarTail) && O.map("Header", R.Header) &&
         O.map("Latch", R.Latch) &&
         O.map("PeakLiveVectorRegisters", R.PeakLiveVectorRegisters) &&
         O.map("Blocks", R.Blocks) && O.map("Instructions", R.Instructions) &&
         O.map("Edges", R.Edges);
}
namespace {
// Fractional LMUL is kept exactly in eighths; encoding 4 is reserved.
static unsigned group8(unsigned Encoding) {
  switch (Encoding) {
  case 0:
    return 8;
  case 1:
    return 16;
  case 2:
    return 32;
  case 3:
    return 64;
  case 5:
    return 1;
  case 6:
    return 2;
  case 7:
    return 4;
  default:
    return 0;
  }
}

static bool isVectorRegister(Register Reg) {
  return Reg.isPhysical() && (RISCV::VRRegClass.contains(Reg) ||
                              RISCV::VRM2RegClass.contains(Reg) ||
                              RISCV::VRM4RegClass.contains(Reg) ||
                              RISCV::VRM8RegClass.contains(Reg));
}

static bool hasVectorOperand(const MachineInstr &MI) {
  for (const MachineOperand &MO : MI.operands()) {
    if (!MO.isReg() || !MO.getReg().isPhysical())
      continue;
    Register Reg = MO.getReg();
    if (isVectorRegister(Reg))
      return true;
  }
  return false;
}

// Whole-register COPY has no LMUL/SEW configuration. Its physical register
// class describes the amount transferred, including mask-register copies.
static unsigned physicalGroup8(const MachineOperand &MO) {
  if (!MO.isReg() || !MO.getReg().isPhysical() || MO.getSubReg())
    return 0;
  Register Reg = MO.getReg();
  if (RISCV::VRRegClass.contains(Reg))
    return 8;
  if (RISCV::VRM2RegClass.contains(Reg))
    return 16;
  if (RISCV::VRM4RegClass.contains(Reg))
    return 32;
  if (RISCV::VRM8RegClass.contains(Reg))
    return 64;
  return 0;
}

static bool isSupportedSlide(StringRef Base) {
  // Exact base opcodes from RISCVInstrInfoV.td, rather than a permutation
  // prefix. Gather, compress and other rearrangements remain unsupported.
  return StringSwitch<bool>(Base)
      .Cases({"VSLIDEUP_VI", "VSLIDEUP_VX", "VSLIDEDOWN_VI", "VSLIDEDOWN_VX",
              "VSLIDE1UP_VX", "VSLIDE1DOWN_VX", "VFSLIDE1UP_VF",
              "VFSLIDE1DOWN_VF"},
             true)
      .Default(false);
}

static bool isMaskLogical(unsigned Base) {
  // Clear/set pseudos map to VMXOR_MM/VMXNOR_MM too. Recognize exact
  // TableGen base opcodes, not pseudo names or the general VM prefix.
  switch (Base) {
  case RISCV::VMAND_MM:
  case RISCV::VMNAND_MM:
  case RISCV::VMANDN_MM:
  case RISCV::VMXOR_MM:
  case RISCV::VMOR_MM:
  case RISCV::VMNOR_MM:
  case RISCV::VMORN_MM:
  case RISCV::VMXNOR_MM:
    return true;
  default:
    return false;
  }
}

// Value identities are local to one observation, never register numbers or
// candidate identities. Only full single-register physical copies preserve
// identity; elementwise moves can depend on VL and leave some bits unchanged.
class PredicateProvenance {
  const TargetRegisterInfo &TRI;
  DenseMap<Register, int64_t> Values;
  int64_t Next = 1;

  int64_t value(const MachineOperand &MO) {
    if (physicalGroup8(MO) != 8 || MO.isUndef())
      return 0;
    auto [It, Inserted] = Values.try_emplace(MO.getReg(), 0);
    if (Inserted)
      It->second = Next++;
    return It->second;
  }

public:
  explicit PredicateProvenance(const TargetRegisterInfo &TRI) : TRI(TRI) {}

  void clear() { Values.clear(); }

  // Snapshot uses before invalidating definitions, including aliases of a
  // grouped vector destination. Clobbering a source does not change copies
  // already made from it. Repeated copies of an unchanged source retain ID.
  int64_t observe(const MachineInstr &MI) {
    if (MI.isDebugInstr())
      return 0;
    int64_t Predicate = 0;
    if (const auto *Masked = RISCV::getMaskedPseudoInfo(MI.getOpcode())) {
      // The table index counts inputs; MachineInstr also has explicit defs.
      unsigned MaskIdx = Masked->MaskOpIdx + MI.getNumExplicitDefs();
      if (MaskIdx < MI.getNumOperands())
        Predicate = value(MI.getOperand(MaskIdx));
    }

    Register CopyDest;
    int64_t CopyValue = 0;
    if ((MI.getOpcode() == TargetOpcode::COPY ||
         MI.getOpcode() == RISCV::VMV1R_V) &&
        MI.getNumOperands() >= 2 && physicalGroup8(MI.getOperand(0)) == 8 &&
        physicalGroup8(MI.getOperand(1)) == 8) {
      CopyDest = MI.getOperand(0).getReg();
      CopyValue = value(MI.getOperand(1));
    }

    SmallVector<Register> Clobbered;
    for (const auto &Entry : Values) {
      Register Reg = Entry.first;
      for (const MachineOperand &MO : MI.operands())
        if ((MO.isReg() && MO.isDef() && MO.getReg().isPhysical() &&
             TRI.regsOverlap(Reg, MO.getReg())) ||
            (MO.isRegMask() && MO.clobbersPhysReg(Reg))) {
          Clobbered.push_back(Reg);
          break;
        }
    }
    for (Register Reg : Clobbered)
      Values.erase(Reg);
    // IMPLICIT_DEF has no executable output but still breaks provenance.
    // Undef copies likewise cannot prove a value identity for consumers.
    if (MI.isImplicitDef())
      for (const MachineOperand &MO : MI.operands())
        if (MO.isReg() && MO.isDef() && MO.getReg().isPhysical())
          for (MCRegAliasIterator Alias(MO.getReg(), &TRI, true);
               Alias.isValid(); ++Alias)
            if (RISCV::VRRegClass.contains(*Alias))
              Values[Register(*Alias)] = 0;
    if (MI.isCall() || MI.isInlineAsm())
      clear();
    else if (CopyDest)
      Values[CopyDest] = CopyValue;
    return Predicate;
  }
};

// Only the scalar result is classified here. An unused rd still leaves VL
// and VTYPE dependencies on vector consumers and subsequent configurations.
static bool hasUnusedConfigResult(const MachineInstr &MI) {
  switch (MI.getOpcode()) {
  case RISCV::PseudoVSETVLI:
  case RISCV::PseudoVSETVLIX0:
  case RISCV::PseudoVSETVLIX0X0:
  case RISCV::PseudoVSETIVLI:
    break;
  default:
    // Other configuration forms have no established scalar-result contract.
    return false;
  }
  if (!MI.getNumOperands())
    return false;
  const MachineOperand &RD = MI.getOperand(0);
  if (!RD.isReg() || !RD.isDef() || RD.isImplicit() || RD.getSubReg() ||
      !RD.getReg().isPhysical() || !RISCV::GPRRegClass.contains(RD.getReg()))
    return false;
  // X0 discards the scalar result regardless of liveness availability. For
  // other GPRs trust a dead def only when the function tracks liveness.
  return RD.getReg() == RISCV::X0 ||
         (MI.getMF()->getProperties().hasTracksLiveness() && RD.isDead());
}

enum class OperationKind { Unsupported, Integer, FP, Fused };
static OperationKind arithmeticKind(StringRef Family) {
  // Only elementwise families: reductions, permutations, integer divide,
  // remainder and square root deliberately retain the original model.
  // FP divide is observed separately using exact base opcodes below.
  return StringSwitch<OperationKind>(Family)
      .Cases({"VFMACC", "VFNMACC", "VFMSAC", "VFNMSAC", "VFMADD", "VFNMADD",
              "VFMSUB", "VFNMSUB", "VFWMACC", "VFWNMACC", "VFWMSAC",
              "VFWNMSAC"},
             OperationKind::Fused)
      .Cases({"VFADD",  "VFSUB",   "VFRSUB",  "VFMUL",   "VFMIN",  "VFMAX",
              "VFSGNJ", "VFSGNJN", "VFSGNJX", "VMFEQ",   "VMFNE",  "VMFLT",
              "VMFLE",  "VMFGT",   "VMFGE",   "VFCVT",   "VFWCVT", "VFNCVT",
              "VFWADD", "VFWSUB",  "VFWMUL",  "VFCLASS", "VFMV"},
             OperationKind::FP)
      .Cases({"VADD",     "VSUB",   "VRSUB",   "VAND",   "VOR",     "VXOR",
              "VSLL",     "VSRL",   "VSRA",    "VMUL",   "VMULH",   "VMULHU",
              "VMULHSU",  "VMACC",  "VNMSAC",  "VMADD",  "VNMSUB",  "VMIN",
              "VMINU",    "VMAX",   "VMAXU",   "VMSEQ",  "VMSNE",   "VMSLT",
              "VMSLTU",   "VMSLE",  "VMSLEU",  "VMSGT",  "VMSGTU",  "VMERGE",
              "VMV",      "VID",    "VWADD",   "VWADDU", "VWSUB",   "VWSUBU",
              "VWMUL",    "VWMULU", "VWMULSU", "VWMACC", "VWMACCU", "VWMACCSU",
              "VWMACCUS", "VNSRL",  "VNSRA",   "VNCLIP", "VNCLIPU"},
             OperationKind::Integer)
      .Default(OperationKind::Unsupported);
}

// Indexed table keys are configuration fields, not opcodes. Recover the
// record from the small finite domain without parsing pseudo name suffixes.
static const RISCV::VLX_VSXPseudo *indexedInfo(unsigned Opcode,
                                               unsigned DataLMUL) {
  for (unsigned LogSEW = 3; LogSEW <= 6; ++LogSEW)
    for (unsigned IndexLMUL = 0; IndexLMUL != 8; ++IndexLMUL) {
      if (!group8(IndexLMUL))
        continue;
      for (bool Masked : {false, true})
        for (bool Ordered : {false, true}) {
          const auto *Load =
              RISCV::getVLXPseudo(Masked, Ordered, LogSEW, DataLMUL, IndexLMUL);
          if (Load && Load->Pseudo == Opcode)
            return Load;
          const auto *Store =
              RISCV::getVSXPseudo(Masked, Ordered, LogSEW, DataLMUL, IndexLMUL);
          if (Store && Store->Pseudo == Opcode)
            return Store;
        }
    }
  return nullptr;
}

InstructionInfo observeInstruction(const MachineInstr &MI, int64_t ID,
                                   const RISCVSubtarget &ST,
                                   int64_t Predicate) {
  InstructionInfo I;
  const auto &TII = *ST.getInstrInfo();
  const auto &TRI = *ST.getRegisterInfo();
  I.ID = ID;
  I.Block = MI.getParent()->getNumber();
  I.Opcode = TII.getName(MI.getOpcode()).str();
  I.Base = I.Opcode;
  I.Meta = MI.isMetaInstruction();
  I.Barrier = MI.isCall() || MI.isInlineAsm();
  I.Load = MI.mayLoad();
  I.Store = MI.mayStore();
  I.Predicate = Predicate;
  for (auto [Index, MO] : enumerate(MI.operands())) {
    if (MO.isRegMask())
      I.Barrier = true;
    if (MO.isImm())
      I.Immediates.push_back(MO.getImm());
    if (MO.isFI()) {
      I.Stack = true;
      I.StackSlot = MO.getIndex();
    }
    if (!MO.isReg() || !MO.getReg())
      continue;
    Operand O;
    O.Reg = MO.getReg().id();
    if (!MO.getReg().isPhysical()) {
      I.Barrier = true;
      continue;
    }
    O.Name = std::string(TRI.getName(MO.getReg()));
    for (auto U : TRI.regunits(MO.getReg()))
      O.Units.push_back(static_cast<int64_t>(U));
    O.Vector = isVectorRegister(MO.getReg());
    O.Group8 = physicalGroup8(MO);
    O.Def = MO.isDef();
    O.Use = MO.isUse();
    O.Implicit = MO.isImplicit();
    O.Dead = MO.isDef() && MO.isDead();
    O.Undef = MO.isUndef();
    O.EarlyClobber = MO.isDef() && MO.isEarlyClobber();
    O.Tied = MO.isUse() && MI.isRegTiedToDefOperand(Index);
    O.SubReg = MO.getSubReg() != 0;
    I.Operands.push_back(std::move(O));
  }
  int FI = 0;
  TypeSize Bytes = TypeSize::getZero();
  Register StackReg = TII.isLoadFromStackSlot(MI, FI, Bytes);
  if (!StackReg)
    StackReg = TII.isStoreToStackSlot(MI, FI, Bytes);
  if (StackReg) {
    I.Stack = true;
    I.StackSlot = FI;
    I.Bytes = Bytes.getKnownMinValue();
    I.ScalableBytes = Bytes.isScalable();
    I.Spill = MI.getMF()->getFrameInfo().isSpillSlotObjectIndex(FI);
  }
  if (I.Meta) {
    I.Category = "meta";
    return I;
  }
  if (RISCVInstrInfo::isVectorConfigInstr(MI)) {
    I.Category = "config";
    I.ConfigUnused = hasUnusedConfigResult(MI);
    return I;
  }
  if (I.Spill) {
    I.Category = "spill";
    return I;
  }
  if (MI.getOpcode() == TargetOpcode::COPY && MI.getNumOperands() >= 2) {
    I.Group8 = physicalGroup8(MI.getOperand(0));
    if (I.Group8 && I.Group8 == physicalGroup8(MI.getOperand(1))) {
      I.Category = "copy";
      I.SameCopy = MI.getOperand(0).getReg() == MI.getOperand(1).getReg();
      return I;
    }
  }
  // Whole-register transfers are selected when VL covers the whole group.
  // They have no SEW/LMUL operands: record encoded EEW and physical grouping.
  unsigned WholeEEW =
      StringSwitch<unsigned>(I.Opcode)
          .Cases({"VL1RE8_V", "VL2RE8_V", "VL4RE8_V", "VL8RE8_V"}, 8)
          .Cases({"VL1RE16_V", "VL2RE16_V", "VL4RE16_V", "VL8RE16_V"}, 16)
          .Cases({"VL1RE32_V", "VL2RE32_V", "VL4RE32_V", "VL8RE32_V"}, 32)
          .Cases({"VL1RE64_V", "VL2RE64_V", "VL4RE64_V", "VL8RE64_V"}, 64)
          .Cases({"VS1R_V", "VS2R_V", "VS4R_V", "VS8R_V"}, 8)
          .Default(0);
  if (WholeEEW) {
    I.Category = "unit";
    I.SEW = WholeEEW;
    I.Group8 = physicalGroup8(MI.getOperand(0));
    return I;
  }
  const auto *Pseudo = RISCVVPseudosTable::getPseudoInfo(MI.getOpcode());
  if (!Pseudo) {
    if (!hasVectorOperand(MI) && !I.Barrier)
      I.Category = "scalar";
    return I;
  }
  I.Base = TII.getName(Pseudo->BaseInstr).str();
  uint64_t Flags = MI.getDesc().TSFlags;
  I.Group8 = group8(RISCVII::getLMul(Flags));
  I.Masked = RISCV::getMaskedPseudoInfo(MI.getOpcode()) != nullptr;
  if (!RISCVII::hasSEWOp(Flags))
    return I;
  const auto &SEW = MI.getOperand(RISCVII::getSEWOpNum(MI.getDesc()));
  if (!SEW.isImm())
    return I;
  if (isMaskLogical(Pseudo->BaseInstr) && SEW.getImm() == 0) {
    I.SEW = 1;
    I.Category = "mask_logical";
    return I;
  }
  if (SEW.getImm() < 3 || SEW.getImm() > 6)
    return I;
  I.SEW = 1u << SEW.getImm();
  StringRef Base(I.Base), Family = Base.split('_').first;
  if (Base == "VFDIV_VV" || Base == "VFDIV_VF" || Base == "VFRDIV_VF")
    I.Category = "fp_div";
  else if (isSupportedSlide(Base))
    I.Category = "slide";
  else if (I.Load != I.Store) {
    if (const auto *Index = indexedInfo(MI.getOpcode(), Pseudo->VLMul)) {
      I.Category = "indexed";
      I.IndexSEW = 1u << Index->Log2SEW;
      I.IndexGroup8 = group8(Index->IndexLMUL);
      I.Group8 = group8(Index->LMUL);
    } else if (Family == "VLSE8" || Family == "VLSE16" || Family == "VLSE32" ||
               Family == "VLSE64" || Family == "VSSE8" || Family == "VSSE16" ||
               Family == "VSSE32" || Family == "VSSE64")
      I.Category = "strided";
    else if (Family == "VLE8" || Family == "VLE16" || Family == "VLE32" ||
             Family == "VLE64" || Family == "VSE8" || Family == "VSE16" ||
             Family == "VSE32" || Family == "VSE64")
      I.Category = "unit";
  } else {
    switch (arithmeticKind(Family)) {
    case OperationKind::Integer:
      I.Category = "integer";
      break;
    case OperationKind::FP:
      I.Category = "fp";
      break;
    case OperationKind::Fused:
      I.Category = "fused";
      break;
    default:
      break;
    }
  }
  return I;
}
// RAW edges describe physical reaching values, including implicit uses. A
// partial write never establishes a whole-register value. Register masks and
// calls stop provenance; WAR/WAW are deliberately not value edges.
void dependencies(Analytics &A, int64_t BlockID, bool Backedge) {
  DenseMap<int64_t, int64_t> Reaching;
  auto Write = [&](const InstructionInfo &I) {
    if (I.Barrier)
      Reaching.clear();
    for (const auto &O : I.Operands)
      if (O.Def)
        for (int64_t U : O.Units)
          Reaching[U] = I.ID;
  };
  if (Backedge)
    for (const auto &I : A.Instructions)
      if (I.Block == BlockID)
        Write(I);
  for (const auto &I : A.Instructions) {
    if (I.Block != BlockID)
      continue;
    for (auto [Index, O] : enumerate(I.Operands)) {
      if (!O.Use || O.Undef || O.SubReg || O.Units.empty())
        continue;
      std::optional<int64_t> Source;
      bool Complete = true;
      for (int64_t U : O.Units) {
        auto It = Reaching.find(U);
        if (It == Reaching.end() || (Source && *Source != It->second)) {
          Complete = false;
          break;
        }
        Source = It->second;
      }
      if (!Complete || !Source)
        continue;
      const auto &Def = A.Instructions[*Source];
      const auto &UseUnits = O.Units;
      bool Whole = any_of(Def.Operands, [&](const Operand &D) {
        return D.Def && !D.SubReg && D.Units == UseUnits;
      });
      A.Edges.push_back(
          {*Source, I.ID, int64_t(Index), *Source >= I.ID ? 1 : 0, Whole});
    }
    Write(I);
  }
}
int64_t attrNumber(const Function &F, StringRef Name, int64_t Default = 0) {
  auto A = F.getFnAttribute(Name);
  int64_t N;
  return A.isStringAttribute() && !A.getValueAsString().getAsInteger(10, N)
             ? N
             : Default;
}
StringRef loopCandidate(const MachineLoop &L) {
  auto *ID = L.getLoopID();
  if (!ID)
    return {};
  for (const auto &Op : drop_begin(ID->operands()))
    if (auto *Node = dyn_cast_or_null<MDNode>(Op))
      if (Node->getNumOperands() == 2)
        if (auto *Key = dyn_cast<MDString>(Node->getOperand(0)))
          if (Key->getString() == "llvm.loop.vplan.candidate")
            if (auto *Value = dyn_cast<MDString>(Node->getOperand(1)))
              return Value->getString();
  return {};
}
} // namespace

Analytics llvm::vplan::collectAnalytics(const MachineFunction &MF) {
  Analytics A;
  const auto &F = MF.getFunction();
  const auto &ST = MF.getSubtarget<RISCVSubtarget>();
  A.RunID = getVPlanRARunID().str();
  A.Candidate = F.getFnAttribute("vplan.ra.candidate").getValueAsString().str();
  A.Function = F.getName().str();
  A.CPU = ST.getTuneCPU().str();
  A.VLen = ST.getRealMinVLen();
  A.VF = attrNumber(F, "vplan.ra.vf", 1);
  A.Width = attrNumber(F, "vplan.ra.width", 1);
  A.ScalableVF = attrNumber(F, "vplan.ra.scalable") != 0;
  A.MaxTripCount = attrNumber(F, "vplan.ra.max-trip-count");
  A.ExactTripCount = attrNumber(F, "vplan.ra.exact-trip-count");
  A.ScalarTail = attrNumber(F, "vplan.ra.scalar-tail") != 0;
  MachineDominatorTree DT(const_cast<MachineFunction &>(MF));
  MachineLoopInfo LI(DT);
  MachineLoop *Loop = nullptr;
  for (auto *L : LI.getLoopsInPreorder())
    if (loopCandidate(*L) == A.Candidate) {
      if (Loop) {
        A.Error = "multiple machine loops carry the candidate identity";
        break;
      }
      Loop = L;
    }
  if (!Loop)
    A.Error = "candidate loop identity lost (possibly fully unrolled)";
  if (Loop && (!Loop->isInnermost() || !Loop->getLoopLatch() ||
               Loop->getExitingBlock() != Loop->getLoopLatch()))
    A.Error = "candidate is not an innermost single-latch-exit loop";
  if (attrNumber(F, "vplan.ra.iteration-mapping") != 1)
    A.Error = "cannot prove original-iteration mapping after IR optimization";
  if (Loop) {
    A.Header = Loop->getHeader()->getNumber();
    if (Loop->getLoopLatch())
      A.Latch = Loop->getLoopLatch()->getNumber();
    if (Loop->getNumBlocks() == 1)
      A.DependencyCoverage = "single-block-distance-0-1";
  }
  PredicateProvenance Predicates(*ST.getRegisterInfo());
  const MachineBasicBlock *Previous = nullptr;
  for (const auto &BB : MF) {
    Block B;
    B.ID = BB.getNumber();
    if (Loop && Loop->contains(&BB)) {
      B.Role = "body";
      if (Loop->getLoopLatch() && !DT.dominates(&BB, Loop->getLoopLatch()))
        A.Error = "conditional body blocks are unsupported";
    } else if (Loop && &BB == Loop->getLoopPreheader())
      B.Role = "entry";
    else if (Loop && LI.getLoopFor(&BB))
      B.Role = "other-loop-or-tail";
    else
      B.Role = "outside";
    for (auto *Succ : BB.successors())
      B.Successors.push_back(Succ->getNumber());
    A.Blocks.push_back(std::move(B));
    if (!Previous || Previous->succ_size() != 1 ||
        *Previous->succ_begin() != &BB || BB.pred_size() != 1)
      Predicates.clear();
    for (const auto &MI : BB) {
      if (MI.isDebugInstr())
        continue;
      for (const auto &MO : MI.operands())
        if (MO.isReg() && MO.getReg().isVirtual())
          A.Error = "observation precedes complete RA";
      A.Instructions.push_back(observeInstruction(MI, A.Instructions.size(), ST,
                                                  Predicates.observe(MI)));
    }
    Previous = &BB;
  }
  for (const auto &B : A.Blocks)
    dependencies(A, B.ID,
                 B.Role == "body" &&
                     A.DependencyCoverage == "single-block-distance-0-1");
  if (MF.getProperties().hasTracksLiveness()) {
    A.PeakLiveVectorRegisters = 0;
    LivePhysRegs Live(*ST.getRegisterInfo());
    for (const auto &BB : MF) {
      if (!Loop || !Loop->contains(&BB))
        continue;
      Live.clear();
      Live.addLiveOuts(BB);
      for (const auto &MI : reverse(BB)) {
        Live.stepBackward(MI);
        int64_t Count = 0;
        for (auto R : Live)
          if (RISCV::VRRegClass.contains(R))
            ++Count;
        A.PeakLiveVectorRegisters = std::max(A.PeakLiveVectorRegisters, Count);
      }
    }
  }
  return A;
}
