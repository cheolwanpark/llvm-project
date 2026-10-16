//===- RISCVVPlanRAFeatures.cpp - Research feature hook --------------------===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVVPlanRAFeatures.h"
#include "MCTargetDesc/RISCVBaseInfo.h"
#include "RISCVInstrInfo.h"
#include "RISCVSubtarget.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringSwitch.h"
#include "llvm/CodeGen/MachineDominators.h"
#include "llvm/CodeGen/MachineFrameInfo.h"
#include "llvm/CodeGen/MachineFunction.h"
#include "llvm/CodeGen/MachineLoopInfo.h"
#include "llvm/CodeGen/TargetRegisterInfo.h"
#include "llvm/MC/MCRegisterInfo.h"
#include <algorithm>
#include <limits>
#include <optional>
#include <utility>

using namespace llvm;

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
  return Reg.isPhysical() &&
         (RISCV::VRRegClass.contains(Reg) || RISCV::VRM2RegClass.contains(Reg) ||
          RISCV::VRM4RegClass.contains(Reg) || RISCV::VRM8RegClass.contains(Reg));
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
      .Cases({"VSLIDEUP_VI", "VSLIDEUP_VX", "VSLIDEDOWN_VI",
              "VSLIDEDOWN_VX", "VSLIDE1UP_VX", "VSLIDE1DOWN_VX",
              "VFSLIDE1UP_VF", "VFSLIDE1DOWN_VF"}, true)
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
        MI.getNumOperands() >= 2 &&
        physicalGroup8(MI.getOperand(0)) == 8 &&
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

// A live register-AVL result identifies strip mining. Immediate-VL SLP work
// may coexist on a scalar path in the same function.
static bool hasLiveAVL(const MachineInstr &MI) {
  return MI.getOpcode() == RISCV::PseudoVSETVLI &&
         MI.getOperand(0).isReg() && !MI.getOperand(0).isDead() &&
         MI.getOperand(0).getReg() != RISCV::X0 &&
         MI.getOperand(1).isReg() && MI.getOperand(1).getReg() != RISCV::X0;
}

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

struct ResourceObservation {
  bool Supported = false;
  unsigned LoopBlocks = 0;
  int64_t Unit = 0, Spill = 0, Strided = 0, Indexed = 0, Masked = 0;
  int64_t Integer = 0, FP = 0, Fused = 0, Scalar = 0, Config = 0;
  int64_t ConfigUnused = 0, ConfigAdditive = 0;
  json::Array Operations;
  json::Array Recurrences;
  json::Array LoadUseNodes;

  void add(int64_t &Total, uint64_t Work) {
    uint64_t Max = std::numeric_limits<int64_t>::max();
    Total = Work > Max - uint64_t(Total) ? int64_t(Max) : Total + Work;
  }

  void operation(StringRef Kind, unsigned SEW, unsigned Group,
                 uint64_t Work, bool IsMasked = false,
                 unsigned IndexSEW = 0, unsigned IndexGroup = 0,
                 int64_t Predicate = 0, StringRef Form = {},
                 StringRef Direction = {}) {
    json::Object Op{
        {"kind", Kind}, {"sew", SEW}, {"group8", Group},
        {"work8", int64_t(Work)}, {"masked", IsMasked},
        {"index_sew", IndexSEW}, {"index_group8", IndexGroup}};
    if (IsMasked && (Kind == "unit" || Kind == "strided" || Kind == "indexed"))
      Op["predicate_id"] = Predicate;
    if (!Form.empty())
      Op["form"] = Form;
    if (!Direction.empty())
      Op["direction"] = Direction;
    Operations.push_back(std::move(Op));
  }

  json::Object finish() {
    return json::Object{{"version", 1}, {"supported", Supported},
                        {"loop_blocks", LoopBlocks}, {"unit8", Unit},
                        {"spill8", Spill}, {"strided8", Strided},
                        {"indexed8", Indexed}, {"masked8", Masked},
                        {"integer8", Integer}, {"fp8", FP},
                        {"fused8", Fused}, {"scalar8", Scalar},
                        {"config8", Config},
                        {"config_unused8", ConfigUnused},
                        {"config_additive8", ConfigAdditive},
                        {"operations", std::move(Operations)},
                        {"recurrences", std::move(Recurrences)},
                        {"load_use_nodes", std::move(LoadUseNodes)}};
  }
};

// A dependency observation is separate from aggregate resource support. Only
// unmasked, non-widening e32/e64 FP add/subtract/multiply and accumulating FMA
// have a provisional latency prior. Unsupported writes still kill old values.
struct DependencyNode {
  const MachineInstr *MI;
  bool Supported = false;
  bool Fused = false;
  uint64_t Chunks = 0;
  SmallVector<MCRegUnit> DefUnits;
  SmallVector<MCRegUnit> WriteUnits;
  SmallVector<unsigned> Predecessors;

  explicit DependencyNode(const MachineInstr &MI) : MI(&MI) {}
};

static json::Array observeRecurrences(const MachineBasicBlock &BB,
                                     const RISCVSubtarget &ST) {
  const TargetRegisterInfo &TRI = *ST.getRegisterInfo();
  const RISCVInstrInfo &TII = *ST.getInstrInfo();
  SmallVector<DependencyNode> Nodes;
  for (const MachineInstr &MI : BB) {
    if (MI.isDebugInstr())
      continue;
    DependencyNode Node(MI);
    const MachineOperand *Def = nullptr;
    unsigned VectorDefs = 0;
    for (const MachineOperand &MO : MI.operands()) {
      if (!MO.isReg() || !MO.isDef() || !isVectorRegister(MO.getReg()))
        continue;
      ++VectorDefs;
      Def = &MO;
      // Include implicit and unsupported definitions, including IMPLICIT_DEF.
      for (MCRegUnit Unit : TRI.regunits(MO.getReg()))
        Node.WriteUnits.push_back(Unit);
    }
    const auto *Pseudo = RISCVVPseudosTable::getPseudoInfo(MI.getOpcode());
    uint64_t Flags = MI.getDesc().TSFlags;
    if (VectorDefs == 1 && !Def->isImplicit() && !Def->isDead() &&
        !Def->isEarlyClobber() && !Def->getSubReg() && Pseudo &&
        !RISCV::getMaskedPseudoInfo(MI.getOpcode()) &&
        RISCVII::hasSEWOp(Flags)) {
      const MachineOperand &SEW =
          MI.getOperand(RISCVII::getSEWOpNum(MI.getDesc()));
      StringRef Family = TII.getName(Pseudo->BaseInstr).split('_').first;
      bool FP = Family == "VFADD" || Family == "VFSUB" || Family == "VFMUL";
      Node.Fused = Family == "VFMACC" || Family == "VFNMACC" ||
                   Family == "VFMSAC" || Family == "VFNMSAC";
      unsigned Group = group8(unsigned(RISCVII::getLMul(Flags)));
      Node.Supported = (FP || Node.Fused) && SEW.isImm() &&
                       (SEW.getImm() == 5 || SEW.getImm() == 6) && Group;
      if (Node.Supported) {
        Node.DefUnits = SmallVector<MCRegUnit>(TRI.regunits(Def->getReg()));
        Node.Chunks = std::max<uint64_t>(
            1, uint64_t(Group) * ST.getRealMinVLen() / (8 * 128));
      }
    }
    Nodes.push_back(std::move(Node));
  }

  // regunits() yields MCRegUnit in ascending order. Keep the strong type in
  // both vectors and map keys; no numeric indexing of register units is needed.
  DenseMap<MCRegUnit, unsigned> Reaching;
  auto Write = [&](unsigned I) {
    for (const MachineOperand &MO : Nodes[I].MI->operands())
      if (MO.isRegMask())
        Reaching.clear();
    for (MCRegUnit Unit : Nodes[I].WriteUnits)
      Reaching[Unit] = I;
  };
  // The final writes seed the next iteration. Every overlapping write kills
  // its units, so partial aliases cannot masquerade as a whole reaching value.
  for (unsigned I = 0; I != Nodes.size(); ++I)
    Write(I);

  SmallVector<std::pair<unsigned, unsigned>> Backedges;
  for (unsigned I = 0; I != Nodes.size(); ++I) {
    DependencyNode &Node = Nodes[I];
    const MachineInstr &MI = *Node.MI;
    if (Node.Supported) {
      for (unsigned Op = 0; Op != MI.getNumOperands(); ++Op) {
        const MachineOperand &MO = MI.getOperand(Op);
        if (!MO.isReg() || !MO.isUse() || MO.isImplicit() || MO.isUndef() ||
            MO.getSubReg() || !isVectorRegister(MO.getReg()))
          continue;
        // The tied source of an ordinary operation is only tail passthrough.
        // An accumulating FMA's tied source is a true arithmetic input.
        if (!Node.Fused && MI.isRegTiedToDefOperand(Op))
          continue;
        SmallVector<MCRegUnit> UseUnits(TRI.regunits(MO.getReg()));
        std::optional<unsigned> Source;
        bool Complete = true;
        for (MCRegUnit Unit : UseUnits) {
          auto It = Reaching.find(Unit);
          if (It == Reaching.end() || (Source && *Source != It->second)) {
            Complete = false;
            break;
          }
          Source = It->second;
        }
        if (!Complete || !Source || !Nodes[*Source].Supported ||
            UseUnits != Nodes[*Source].DefUnits ||
            llvm::is_contained(Node.Predecessors, *Source))
          continue;
        Node.Predecessors.push_back(*Source);
        if (*Source >= I)
          Backedges.emplace_back(*Source, I);
      }
    }
    // Reads precede writes: neither register reuse nor a WAW/WAR hazard is a
    // value dependency. An undef read does not stop its definition killing.
    Write(I);
  }

  json::Array Result;
  for (auto [Source, Destination] : Backedges) {
    int64_t FP = 0, Fused = 0, Extra = 0;
    ResourceObservation Counts;
    unsigned Current = Source;
    while (true) {
      const DependencyNode &Node = Nodes[Current];
      Counts.add(Node.Fused ? Fused : FP, 1);
      Counts.add(Extra, Node.Chunks - 1);
      if (Current == Destination) {
        Result.push_back(json::Object{{"fp_steps", FP}, {"fused_steps", Fused},
                                      {"extra_chunks", Extra}});
        break;
      }
      std::optional<unsigned> Previous;
      bool Branching = false;
      for (unsigned Pred : Node.Predecessors) {
        if (Pred >= Current)
          continue;
        if (Previous) {
          Branching = true;
          break;
        }
        Previous = Pred;
      }
      // Accept one forward chain with one backedge. Branching chains and
      // cycles requiring another backedge supply no additional cost bound.
      if (Branching || !Previous || *Previous < Destination)
        break;
      Current = *Previous;
    }
  }
  return Result;
}

enum class OperationKind { Unsupported, Integer, FP, Fused };

// A deliberately narrow latency vocabulary, independent of resource support.
// Exact non-widening families exclude masks, conversions and permutations.
static StringRef loadUseKind(StringRef Family) {
  return StringSwitch<StringRef>(Family)
      .Cases({"VLE8", "VLE16", "VLE32", "VLE64"}, "load")
      .Cases({"VFADD", "VFSUB", "VFRSUB", "VFMUL"}, "fp")
      .Cases({"VFMACC", "VFNMACC", "VFMSAC", "VFNMSAC", "VFMADD",
              "VFNMADD", "VFMSUB", "VFNMSUB"}, "fused")
      .Cases({"VADD", "VSUB", "VRSUB", "VAND", "VOR", "VXOR", "VSLL",
              "VSRL", "VSRA", "VMIN", "VMINU", "VMAX", "VMAXU"},
             "integer")
      .Cases({"VMUL", "VMULH", "VMULHU", "VMULHSU"}, "multiply")
      .Default("");
}

static json::Array observeLoadUses(const MachineBasicBlock &BB,
                                  const RISCVSubtarget &ST) {
  const TargetRegisterInfo &TRI = *ST.getRegisterInfo();
  const RISCVInstrInfo &TII = *ST.getInstrInfo();
  struct Value {
    SmallVector<MCRegUnit> Units;
    unsigned SEW, Group;
  };
  SmallVector<Value> Values;
  DenseMap<MCRegUnit, unsigned> Reaching;
  json::Array Result;
  // Empty at entry: neither live-ins nor final writes seed the next iteration.
  // Register reuse supplies no memory alias edge or loop-carried dependency.
  for (const MachineInstr &MI : BB) {
    if (MI.isDebugInstr())
      continue;
    const MachineOperand *Def = nullptr;
    unsigned VectorDefs = 0;
    for (const MachineOperand &MO : MI.operands())
      if (MO.isReg() && MO.isDef() && isVectorRegister(MO.getReg())) {
        Def = &MO;
        ++VectorDefs;
      }
    StringRef Kind;
    unsigned SEW = 0, Group = 0;
    const auto *Pseudo = RISCVVPseudosTable::getPseudoInfo(MI.getOpcode());
    uint64_t Flags = MI.getDesc().TSFlags;
    bool HasRegMask = llvm::any_of(
        MI.operands(), [](const MachineOperand &MO) { return MO.isRegMask(); });
    if (VectorDefs == 1 && !Def->isImplicit() && !Def->isDead() &&
        !Def->isEarlyClobber() && !Def->getSubReg() && Pseudo &&
        !RISCV::getMaskedPseudoInfo(MI.getOpcode()) &&
        RISCVII::hasSEWOp(Flags) && !MI.isCall() && !MI.isInlineAsm() &&
        !HasRegMask) {
      const MachineOperand &SEWOp =
          MI.getOperand(RISCVII::getSEWOpNum(MI.getDesc()));
      Kind = loadUseKind(TII.getName(Pseudo->BaseInstr).split('_').first);
      Group = group8(unsigned(RISCVII::getLMul(Flags)));
      if (SEWOp.isImm() && SEWOp.getImm() >= 3 && SEWOp.getImm() <= 6)
        SEW = 1u << SEWOp.getImm();
      if (!Group || !SEW ||
          ((Kind == "fp" || Kind == "fused") && SEW < 32))
        Kind = {};
      if (Kind == "load") {
        // Ordinary unit loads only. Stack reloads and read/write operations
        // are not roots, even if their physical output matches a consumer.
        bool Frame = llvm::any_of(
            MI.operands(), [](const MachineOperand &MO) { return MO.isFI(); });
        if (!MI.mayLoad() || MI.mayStore() || Frame)
          Kind = {};
      }
    }

    json::Array Predecessors;
    SmallVector<unsigned> Sources;
    if (!Kind.empty() && Kind != "load") {
      for (unsigned Op = 0; Op != MI.getNumOperands(); ++Op) {
        const MachineOperand &MO = MI.getOperand(Op);
        if (!MO.isReg() || !MO.isUse() || MO.isImplicit() || MO.isUndef() ||
            MO.getSubReg() || !isVectorRegister(MO.getReg()))
          continue;
        // FMA's tied operand is an arithmetic input (including VFMADD's
        // multiplicand). Other tied operands preserve only inactive tails.
        if (Kind != "fused" && MI.isRegTiedToDefOperand(Op))
          continue;
        SmallVector<MCRegUnit> Units(TRI.regunits(MO.getReg()));
        std::optional<unsigned> Source;
        bool Complete = true;
        for (MCRegUnit Unit : Units) {
          auto It = Reaching.find(Unit);
          if (It == Reaching.end() || (Source && *Source != It->second)) {
            Complete = false;
            break;
          }
          Source = It->second;
        }
        // Require a whole, same-shaped reaching value. Partial aliases and
        // intervening type/group changes cannot prove chunk forwarding.
        if (Complete && Source && Values[*Source].Units == Units &&
            Values[*Source].SEW == SEW && Values[*Source].Group == Group &&
            !llvm::is_contained(Sources, *Source))
          Sources.push_back(*Source);
      }
      for (unsigned Source : Sources)
        Predecessors.push_back(int64_t(Source));
    }

    // Snapshot true reads before killing every write, including unsupported
    // operations, implicit defs and partial aliases. Calls and regmasks are
    // conservative barriers. No unsupported instruction propagates a path.
    if (MI.isCall() || MI.isInlineAsm())
      Reaching.clear();
    for (const MachineOperand &MO : MI.operands()) {
      if (MO.isRegMask())
        Reaching.clear();
      if (MO.isReg() && MO.isDef() && MO.getReg().isPhysical())
        for (MCRegUnit Unit : TRI.regunits(MO.getReg()))
          Reaching.erase(Unit);
    }
    if (Kind.empty() || (Kind != "load" && Sources.empty()))
      continue;
    unsigned Index = Values.size();
    Values.push_back(
        {SmallVector<MCRegUnit>(TRI.regunits(Def->getReg())), SEW, Group});
    uint64_t Chunks = std::max<uint64_t>(
        1, uint64_t(Group) * ST.getRealMinVLen() / (8 * 128));
    Result.push_back(json::Object{{"kind", Kind}, {"chunks", int64_t(Chunks)},
                                  {"predecessors", std::move(Predecessors)}});
    for (MCRegUnit Unit : Values.back().Units)
      Reaching[Unit] = Index;
  }
  return Result;
}

static OperationKind arithmeticKind(StringRef Family) {
  // Only elementwise families: reductions, permutations, integer divide,
  // remainder and square root deliberately retain the original model.
  // FP divide is observed separately using exact base opcodes below.
  return StringSwitch<OperationKind>(Family)
      .Cases({"VFMACC", "VFNMACC", "VFMSAC", "VFNMSAC", "VFMADD",
              "VFNMADD", "VFMSUB", "VFNMSUB", "VFWMACC", "VFWNMACC",
              "VFWMSAC", "VFWNMSAC"}, OperationKind::Fused)
      .Cases({"VFADD", "VFSUB", "VFRSUB", "VFMUL", "VFMIN", "VFMAX",
              "VFSGNJ", "VFSGNJN", "VFSGNJX", "VMFEQ", "VMFNE",
              "VMFLT", "VMFLE", "VMFGT", "VMFGE", "VFCVT", "VFWCVT",
              "VFNCVT", "VFWADD", "VFWSUB", "VFWMUL", "VFCLASS",
              "VFMV"}, OperationKind::FP)
      .Cases({"VADD", "VSUB", "VRSUB", "VAND", "VOR", "VXOR", "VSLL",
              "VSRL", "VSRA", "VMUL", "VMULH", "VMULHU", "VMULHSU",
              "VMACC", "VNMSAC", "VMADD", "VNMSUB", "VMIN", "VMINU",
              "VMAX", "VMAXU", "VMSEQ", "VMSNE", "VMSLT", "VMSLTU",
              "VMSLE", "VMSLEU", "VMSGT", "VMSGTU", "VMERGE", "VMV",
              "VID", "VWADD", "VWADDU", "VWSUB",
              "VWSUBU", "VWMUL", "VWMULU", "VWMULSU", "VWMACC",
              "VWMACCU", "VWMACCSU", "VWMACCUS", "VNSRL", "VNSRA",
              "VNCLIP", "VNCLIPU"},
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
          const auto *Load = RISCV::getVLXPseudo(Masked, Ordered, LogSEW,
                                                DataLMUL, IndexLMUL);
          if (Load && Load->Pseudo == Opcode)
            return Load;
          const auto *Store = RISCV::getVSXPseudo(Masked, Ordered, LogSEW,
                                                 DataLMUL, IndexLMUL);
          if (Store && Store->Pseudo == Opcode)
            return Store;
        }
    }
  return nullptr;
}

static bool observe(const MachineInstr &MI, const RISCVSubtarget &ST,
                    ResourceObservation &R, int64_t Predicate) {
  if (MI.isMetaInstruction())
    return true;
  if (RISCVInstrInfo::isVectorConfigInstr(MI)) {
    R.add(R.Config, 8);
    R.add(hasUnusedConfigResult(MI) ? R.ConfigUnused : R.ConfigAdditive, 8);
    return true;
  }

  const RISCVInstrInfo &TII = *ST.getInstrInfo();
  int FI = 0;
  TypeSize Bytes = TypeSize::getZero();
  Register StackReg = TII.isLoadFromStackSlot(MI, FI, Bytes);
  if (!StackReg)
    StackReg = TII.isStoreToStackSlot(MI, FI, Bytes);
  if (StackReg && MI.getMF()->getFrameInfo().isSpillSlotObjectIndex(FI)) {
    uint64_t Work = Bytes.getKnownMinValue();
    // Scalable stack sizes use 64-bit RVV blocks; full chunks are 128 bits.
    Work = Bytes.isScalable() ? Work * ST.getRealMinVLen() / 128 : Work / 2;
    Work = std::max<uint64_t>(8, Work);
    R.add(R.Spill, Work);
    R.operation("spill", 0, 0, Work);
    return true;
  }

  if (MI.getOpcode() == TargetOpcode::COPY) {
    unsigned Group = physicalGroup8(MI.getOperand(0));
    if (Group) {
      if (physicalGroup8(MI.getOperand(1)) != Group)
        return false;
      // A same-register copy has no transfer. Do not infer fractional LMUL
      // from a preceding vset: COPY transfers the whole physical group.
      uint64_t Work = MI.getOperand(0).getReg() == MI.getOperand(1).getReg()
                          ? 0
                          : uint64_t(Group) * ST.getRealMinVLen() / 128;
      R.operation("copy", 0, Group, Work);
      return true;
    }
    if (hasVectorOperand(MI))
      return false;
    // Ordinary scalar COPY keeps its existing treatment below.
  }

  const auto *Pseudo = RISCVVPseudosTable::getPseudoInfo(MI.getOpcode());
  if (!Pseudo) {
    if (hasVectorOperand(MI))
      return false;
    R.add(R.Scalar, 8);
    return !MI.isCall() && !MI.isInlineAsm();
  }
  uint64_t Flags = MI.getDesc().TSFlags;
  if (!RISCVII::hasSEWOp(Flags))
    return false;
  if (isMaskLogical(Pseudo->BaseInstr)) {
    // VPseudoVALU_MM has rd, rs2, rs1, AVL, sew_mask; clear/set aliases
    // have rd, AVL, sew_mask. There is no passthrough or policy operand.
    // All vector operands are single VRs even for the B1 (logical M8)
    // mask. LMUL describes the bit count, not a physical register group.
    unsigned NumOps = MI.getDesc().getNumOperands();
    if ((NumOps != 3 && NumOps != 5) ||
        MI.getNumOperands() < NumOps ||
        MI.getNumExplicitDefs() != 1)
      return false;
    for (unsigned I = 0; I != NumOps - 2; ++I)
      if (physicalGroup8(MI.getOperand(I)) != 8)
        return false;
    const MachineOperand &AVL = MI.getOperand(NumOps - 2);
    const MachineOperand &SEW = MI.getOperand(NumOps - 1);
    unsigned Group = group8(unsigned(RISCVII::getLMul(Flags)));
    if ((!AVL.isReg() && !AVL.isImm()) || !SEW.isImm() ||
        SEW.getImm() != 0 || !Group)
      return false;
    // AllMasks uses canonical e8 LMUL: B = 64 / group8 and the full mask
    // has VLEN/B bits. One integer service unit per 128 packed bits, with
    // an issue floor of one; work8 is eight times that service demand.
    // Do not cost eight-bit data lanes, infer mask density, or remove an
    // alias with a known Boolean result. Only observe the instruction.
    uint64_t Work = std::max<uint64_t>(
        8, uint64_t(Group) * ST.getRealMinVLen() / (8 * 128));
    R.add(R.Integer, Work);
    R.operation("mask_logical", 1, Group, Work);
    return true;
  }
  const MachineOperand &SEWOp = MI.getOperand(RISCVII::getSEWOpNum(MI.getDesc()));
  if (!SEWOp.isImm() || SEWOp.getImm() < 3 || SEWOp.getImm() > 6)
    return false;
  unsigned SEW = 1u << SEWOp.getImm();
  unsigned Group = group8(unsigned(RISCVII::getLMul(Flags)));
  if (!Group)
    return false;
  unsigned VLen = ST.getRealMinVLen();
  bool Masked = RISCV::getMaskedPseudoInfo(MI.getOpcode()) != nullptr;
  StringRef Base = TII.getName(Pseudo->BaseInstr);
  StringRef Family = Base.split('_').first;

  // Pseudo metadata maps masked, SEW-specialized and scalar-FPR forms back
  // to these exact ISA opcodes. TSFlags describe the non-widening data LMUL,
  // and the SEW operand describes the operation rather than a preceding vset.
  // Do not recognize division by a pseudo-name prefix or count it as ordinary
  // FP arithmetic. Retain mask presence without assuming active-lane density.
  StringRef DivideForm = StringSwitch<StringRef>(Base)
                             .Case("VFDIV_VV", "vv")
                             .Case("VFDIV_VF", "vf")
                             .Case("VFRDIV_VF", "reverse_vf")
                             .Default("");
  if (!DivideForm.empty()) {
    if (SEW != 16 && SEW != 32 && SEW != 64)
      return false;
    uint64_t Work = std::max<uint64_t>(8, uint64_t(Group) * VLen / 128);
    R.operation("fp_div", SEW, Group, Work, Masked, 0, 0, 0, DivideForm);
    return true;
  }

  if (isSupportedSlide(Base)) {
    // Slide pseudos use the same m.vrclass for destination and vector source.
    // TSFlags retain fractional LMUL; slides are not widening arithmetic.
    uint64_t Work = std::max<uint64_t>(8, uint64_t(Group) * VLen / 128);
    R.operation("slide", SEW, Group, Work, Masked);
    return true;
  }

  if (MI.mayLoad() || MI.mayStore()) {
    // Observe direction from instruction metadata, independently of access
    // class and pseudo naming. Supported ordinary accesses have one direction;
    // ambiguous read/write instructions retain unsupported-resource behavior.
    // Spill slots were handled above and never enter ordinary memory demand.
    if (MI.mayLoad() == MI.mayStore())
      return false;
    StringRef Direction = MI.mayLoad() ? "load" : "store";
    unsigned IndexSEW = 0, IndexGroup = 0;
    StringRef Kind;
    int64_t *Total;
    uint64_t Work;
    if (const auto *Index = indexedInfo(MI.getOpcode(), Pseudo->VLMul)) {
      Kind = "indexed";
      Total = &R.Indexed;
      IndexSEW = 1u << Index->Log2SEW;
      IndexGroup = group8(Index->IndexLMUL);
      Group = group8(Index->LMUL);
      Masked = Index->Masked;
      Work = uint64_t(Group) * VLen / SEW;
    } else if (Family == "VLSE8" || Family == "VLSE16" ||
               Family == "VLSE32" || Family == "VLSE64" ||
               Family == "VSSE8" || Family == "VSSE16" ||
               Family == "VSSE32" || Family == "VSSE64") {
      Kind = "strided";
      Total = &R.Strided;
      Work = uint64_t(Group) * VLen / SEW;
    } else if (Family == "VLE8" || Family == "VLE16" || Family == "VLE32" ||
               Family == "VLE64" || Family == "VSE8" || Family == "VSE16" ||
               Family == "VSE32" || Family == "VSE64") {
      Kind = "unit";
      Total = &R.Unit;
      Work = uint64_t(Group) * VLen / 128;
    } else {
      return false;
    }
    Work = std::max<uint64_t>(8, Work);
    R.add(*Total, Work);
    if (Masked)
      R.add(R.Masked, Work);
    R.operation(Kind, SEW, Group, Work, Masked, IndexSEW, IndexGroup, Predicate,
                /*Form=*/{}, Direction);
    return true;
  }

  OperationKind Kind = arithmeticKind(Family);
  if (Kind == OperationKind::Unsupported)
    return false;
  // Account for the largest operand of widening/narrowing operations.
  if (Family.starts_with("VW") || Family.starts_with("VFW") ||
      Family.starts_with("VNSR") || Family.starts_with("VNCLIP") ||
      Family.starts_with("VFNC"))
    Group *= 2;
  uint64_t Work = std::max<uint64_t>(8, uint64_t(Group) * VLen / 128);
  switch (Kind) {
  case OperationKind::Integer:
    R.add(R.Integer, Work);
    R.operation("integer", SEW, Group, Work, Masked);
    break;
  case OperationKind::FP:
    R.add(R.FP, Work);
    R.operation("fp", SEW, Group, Work, Masked);
    break;
  case OperationKind::Fused:
    R.add(R.Fused, Work);
    R.operation("fused", SEW, Group, Work, Masked);
    break;
  case OperationKind::Unsupported:
    llvm_unreachable("handled above");
  }
  return true;
}
} // namespace

json::Object llvm::collectRISCVVPlanRAFeatures(const MachineFunction &MF) {
  ResourceObservation R;
  const auto &ST = MF.getSubtarget<RISCVSubtarget>();
  if (ST.getTuneCPU() != "xiangshan-kunminghu" || !ST.hasVInstructions())
    return json::Object{{"resource_demand", R.finish()}};

  // Analysis APIs require a mutable function reference; these local analyses
  // only read its CFG. No machine instruction or RA state is changed.
  MachineDominatorTree DT(const_cast<MachineFunction &>(MF));
  MachineLoopInfo LI(DT);
  SmallVector<MachineLoop *> VectorLoops, AVLLoops;
  for (MachineLoop *L : LI.getLoopsInPreorder()) {
    if (!L->isInnermost())
      continue;
    bool Vector = false, AVL = false;
    for (const MachineBasicBlock *BB : L->blocks())
      for (const MachineInstr &MI : *BB) {
        Vector |= !MI.isMetaInstruction() && hasVectorOperand(MI);
        AVL |= hasLiveAVL(MI);
      }
    if (Vector) {
      VectorLoops.push_back(L);
      if (AVL)
        AVLLoops.push_back(L);
    }
  }
  MachineLoop *Loop = nullptr;
  if (AVLLoops.size() == 1)
    Loop = AVLLoops.front();
  else if (AVLLoops.empty() && VectorLoops.size() == 1)
    Loop = VectorLoops.front();
  if (!Loop)
    return json::Object{{"resource_demand", R.finish()}};

  MachineBasicBlock *Latch = Loop->getLoopLatch();
  if (!Latch || Loop->getExitingBlock() != Latch)
    return json::Object{{"resource_demand", R.finish()}};
  R.LoopBlocks = Loop->getNumBlocks();
  // Analyze provenance in execution order along a unique forward chain.
  // Never carry identities across the backedge, a join, a branch, or an
  // external predecessor. Other region blocks receive block-local identities.
  // This does not change the existing region or its resource aggregation.
  PredicateProvenance Provenance(*ST.getRegisterInfo());
  DenseMap<const MachineInstr *, int64_t> Predicates;
  SmallPtrSet<const MachineBasicBlock *, 8> Visited;
  auto TrackChain = [&](const MachineBasicBlock *BB) {
    Provenance.clear();
    while (BB && Visited.insert(BB).second) {
      for (const MachineInstr &MI : *BB)
        Predicates[&MI] = Provenance.observe(MI);
      const MachineBasicBlock *Next =
          BB->succ_size() == 1 ? *BB->succ_begin() : nullptr;
      BB = Next && Next != Loop->getHeader() && Loop->contains(Next) &&
                   Next->pred_size() == 1
               ? Next
               : nullptr;
    }
  };
  TrackChain(Loop->getHeader());
  for (const MachineBasicBlock *BB : Loop->blocks())
    if (!Visited.contains(BB))
      TrackChain(BB);
  for (const MachineBasicBlock *BB : Loop->blocks()) {
    if (!DT.dominates(BB, Latch))
      return json::Object{{"resource_demand", R.finish()}};
    for (const MachineInstr &MI : *BB)
      if (!observe(MI, ST, R, Predicates.lookup(&MI)))
        return json::Object{{"resource_demand", R.finish()}};
  }
  R.Supported = true;
  if (R.LoopBlocks == 1) {
    R.Recurrences = observeRecurrences(*Loop->getHeader(), ST);
    R.LoadUseNodes = observeLoadUses(*Loop->getHeader(), ST);
  }
  return json::Object{{"resource_demand", R.finish()}};
}
