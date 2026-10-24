//===- RISCVVPlanAnalytics.cpp - Passive post-RA MIR observations
//----------===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVVPlanAnalytics.h"
#include "RISCVInstrInfo.h"
#include "RISCVSubtarget.h"
#include "llvm/CodeGen/MachineDominators.h"
#include "llvm/CodeGen/MachineFrameInfo.h"
#include "llvm/CodeGen/MachineLoopInfo.h"
#include "llvm/CodeGen/PseudoSourceValue.h"
#include "llvm/CodeGen/ReachingDefAnalysis.h"
#include "llvm/Config/llvm-config.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/Transforms/Vectorize/VPlanRA.h"
using namespace llvm;
namespace {
unsigned group8(unsigned E) {
  switch (E) {
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
unsigned physicalGroup8(Register R) {
  if (!R.isPhysical())
    return 0;
  if (RISCV::VRRegClass.contains(R))
    return 8;
  if (RISCV::VRM2RegClass.contains(R))
    return 16;
  if (RISCV::VRM4RegClass.contains(R))
    return 32;
  if (RISCV::VRM8RegClass.contains(R))
    return 64;
  return 0;
}

// Query LLVM's physical reaching definitions, not a second dataflow engine.
// Empty cached results break cycles. Regmasks are not modeled by
// ReachingDefInfo; disable value proofs in opaque functions rather than
// crossing a clobber.
class ObservedValues {
  ReachingDefInfo RDI;
  const RISCVSubtarget &ST;
  const MachineDominatorTree &DT;
  bool Safe = true;
  DenseMap<std::pair<MachineInstr *, unsigned>, std::optional<uint64_t>> Cache;

  // Non-allocatable CSRs are absent from successor live-ins, so RDI cannot
  // follow them across blocks. Walk only backwards to the nearest VL writes;
  // all reaching writes must agree. This is not a general value dataflow pass.
  std::optional<uint64_t> vlValue(MachineInstr &At) {
    SmallVector<std::pair<MachineBasicBlock *, MachineBasicBlock::iterator>>
        Work;
    SmallPtrSet<MachineBasicBlock *, 8> Visited;
    SmallPtrSet<MachineInstr *, 8> Defs;
    Work.emplace_back(At.getParent(), At.getIterator());
    while (!Work.empty()) {
      auto [BB, End] = Work.pop_back_val();
      bool Found = false;
      while (End != BB->begin()) {
        auto &MI = *--End;
        // The legal x0,x0 form preserves VL and only changes VTYPE policies.
        if (MI.getOpcode() == RISCV::PseudoVSETVLIX0X0)
          continue;
        if (MI.modifiesRegister(RISCV::VL, ST.getRegisterInfo())) {
          Defs.insert(&MI);
          Found = true;
          break;
        }
      }
      if (Found)
        continue;
      if (BB->pred_empty())
        return std::nullopt;
      for (auto *Pred : BB->predecessors())
        if (Visited.insert(Pred).second)
          Work.emplace_back(Pred, Pred->end());
    }
    std::optional<uint64_t> Result;
    for (auto *Def : Defs) {
      auto V = evaluate(*Def, RISCV::VL);
      if (!V || (Result && Result != V))
        return std::nullopt;
      Result = V;
    }
    return Result;
  }

  std::optional<uint64_t> operandValue(MachineInstr &MI, unsigned I) {
    if (I >= MI.getNumOperands())
      return std::nullopt;
    const auto &MO = MI.getOperand(I);
    if (MO.isImm())
      return uint64_t(MO.getImm());
    if (MO.isReg() && !MO.isUndef() && !MO.getSubReg())
      return value(MI, MO.getReg());
    return std::nullopt;
  }

  std::optional<uint64_t> evaluate(MachineInstr &MI, Register R) {
    if (RISCVInstrInfo::isVectorConfigInstr(MI)) {
      unsigned Op = MI.getOpcode();
      if (Op != RISCV::PseudoVSETVLI && Op != RISCV::PseudoVSETIVLI &&
          Op != RISCV::PseudoVSETVLIX0 && Op != RISCV::PseudoVSETVLIX0X0)
        return std::nullopt;
      uint64_t VType = MI.getOperand(2).getImm();
      if (R == RISCV::VTYPE)
        return VType;
      auto VLen = ST.getRealVLen();
      unsigned Group = group8(unsigned(RISCVVType::getVLMUL(VType)));
      if (!VLen || !Group)
        return std::nullopt;
      uint64_t Max = uint64_t(*VLen) * Group / 8 / RISCVVType::getSEW(VType);
      if (!Max)
        return std::nullopt;
      if (Op == RISCV::PseudoVSETVLIX0)
        return Max;
      auto AVL = Op == RISCV::PseudoVSETVLIX0X0 ? value(MI, RISCV::VL)
                                                : operandValue(MI, 1);
      if (!AVL)
        return std::nullopt;
      if (Op == RISCV::PseudoVSETVLIX0X0)
        return *AVL <= Max ? AVL : std::nullopt;
      // The ISA permits implementation-dependent VL in the middle interval.
      if (*AVL <= Max)
        return AVL;
      return *AVL >= 2 * Max ? std::optional<uint64_t>(Max) : std::nullopt;
    }
    auto A = operandValue(MI, 1);
    if (!A)
      return std::nullopt;
    switch (MI.getOpcode()) {
    case RISCV::LUI:
      return uint64_t(SignExtend64<32>(*A << 12));
    case TargetOpcode::COPY:
      return A;
    default:
      break;
    }
    auto B = operandValue(MI, 2);
    if (!B)
      return std::nullopt;
    switch (MI.getOpcode()) {
    case RISCV::ADD:
    case RISCV::ADDI:
      return *A + *B;
    case RISCV::ADDW:
    case RISCV::ADDIW:
      return uint64_t(SignExtend64<32>(*A + *B));
    case RISCV::SUB:
      return *A - *B;
    case RISCV::MUL:
      return *A * *B;
    case RISCV::SLLI:
      return *A << (*B & 63);
    case RISCV::SRLI:
      return *A >> (*B & 63);
    case RISCV::ANDI:
      return *A & *B;
    case RISCV::ORI:
      return *A | *B;
    default:
      return std::nullopt;
    }
  }

public:
  ObservedValues(MachineFunction &MF, const MachineDominatorTree &DT)
      : ST(MF.getSubtarget<RISCVSubtarget>()), DT(DT) {
    Safe = MF.getProperties().hasTracksLiveness() && ST.is64Bit();
    for (const auto &BB : MF)
      for (const auto &MI : BB) {
        Safe &= !MI.isCall() && !MI.isInlineAsm();
        for (const auto &MO : MI.operands())
          Safe &=
              !MO.isRegMask() &&
              (!MO.isReg() || (!MO.getSubReg() && !MO.getReg().isVirtual()));
      }
    if (Safe)
      RDI.run(MF);
  }

  std::optional<uint64_t> value(MachineInstr &MI, Register R) {
    if (R == RISCV::X0)
      return 0;
    if (!Safe || !R.isPhysical() || !R)
      return std::nullopt;
    auto Key = std::make_pair(&MI, unsigned(R));
    auto [It, Inserted] = Cache.try_emplace(Key, std::nullopt);
    if (!Inserted)
      return It->second;
    auto *Def = R == RISCV::VL ? nullptr : RDI.getUniqueReachingMIDef(&MI, R);
    // A live-in path without a definition must not be mistaken for the only
    // constant-producing predecessor returned by RDI.
    if (Def && !DT.dominates(Def, &MI))
      Def = nullptr;
    auto Result = R == RISCV::VL ? vlValue(MI)
                  : Def          ? evaluate(*Def, R)
                                 : std::nullopt;
    Cache[Key] = Result;
    return Result;
  }

  json::Value jsonValue(MachineInstr &MI, Register R) {
    auto V = value(MI, R);
    return V ? json::Value(int64_t(*V)) : json::Value(nullptr);
  }
};
// Recover the index group from the generated pseudo table rather than from
// physical register allocation or a pseudo-name suffix.
const RISCV::VLX_VSXPseudo *indexedInfo(unsigned Opcode, unsigned DataLMUL) {
  for (unsigned LogEEW = 3; LogEEW <= 6; ++LogEEW)
    for (unsigned IndexLMUL = 0; IndexLMUL < 8; ++IndexLMUL) {
      if (!group8(IndexLMUL))
        continue;
      for (bool Masked : {false, true})
        for (bool Ordered : {false, true}) {
          auto *L =
              RISCV::getVLXPseudo(Masked, Ordered, LogEEW, DataLMUL, IndexLMUL);
          if (L && L->Pseudo == Opcode)
            return L;
          auto *S =
              RISCV::getVSXPseudo(Masked, Ordered, LogEEW, DataLMUL, IndexLMUL);
          if (S && S->Pseudo == Opcode)
            return S;
        }
    }
  return nullptr;
}
int64_t attr(const Function &F, StringRef Name, int64_t Default = 0) {
  auto A = F.getFnAttribute(Name);
  int64_t N;
  return A.isStringAttribute() && !A.getValueAsString().getAsInteger(10, N)
             ? N
             : Default;
}
StringRef candidate(const MachineLoop &L) {
  auto *ID = L.getLoopID();
  if (!ID)
    return {};
  for (const auto &Op : drop_begin(ID->operands()))
    if (auto *N = dyn_cast_or_null<MDNode>(Op))
      if (N->getNumOperands() == 2)
        if (auto *K = dyn_cast<MDString>(N->getOperand(0)))
          if (K->getString() == "llvm.loop.vplan.candidate")
            if (auto *V = dyn_cast<MDString>(N->getOperand(1)))
              return V->getString();
  return {};
}
std::string valueName(const Value *V) {
  if (!V)
    return {};
  std::string S;
  raw_string_ostream OS(S);
  V->printAsOperand(OS, false);
  return S;
}
json::Object operand(const MachineOperand &MO, unsigned Index,
                     const MachineInstr &MI, const TargetRegisterInfo &TRI) {
  std::string Text;
  raw_string_ostream OS(Text);
  MO.print(OS, &TRI);
  json::Object O{{"index", Index}, {"text", Text}};
  if (MO.isReg()) {
    Register R = MO.getReg();
    json::Array Units;
    // x0 is a constant, never a reaching definition or dependency.
    if (R.isPhysical() && R != RISCV::X0)
      for (auto U : TRI.regunits(R))
        Units.push_back(int64_t(U));
    O["kind"] = "register";
    O["register"] = R.id();
    O["name"] = R.isPhysical() ? TRI.getName(R) : "virtual-or-noreg";
    O["units"] = std::move(Units);
    O["physical"] = !R || R.isPhysical();
    O["group8"] = physicalGroup8(R);
    O["def"] = MO.isDef();
    O["use"] = MO.isUse();
    O["implicit"] = MO.isImplicit();
    O["undef"] = MO.isUndef();
    O["dead"] = MO.isDef() && MO.isDead();
    O["kill"] = MO.isUse() && MO.isKill();
    O["early_clobber"] = MO.isDef() && MO.isEarlyClobber();
    O["tied"] = MO.isUse() && MI.isRegTiedToDefOperand(Index);
    O["subregister"] = MO.getSubReg();
    O["internal_read"] = MO.isInternalRead();
  } else if (MO.isImm()) {
    O["kind"] = "immediate";
    O["value"] = MO.getImm();
  } else if (MO.isFI()) {
    O["kind"] = "frame-index";
    O["value"] = MO.getIndex();
  } else if (MO.isRegMask()) {
    O["kind"] = "register-mask";
  } else {
    O["kind"] = MO.isMBB() ? "block" : "other";
  }
  return O;
}
json::Object instruction(MachineInstr &MI, unsigned ID,
                         const RISCVSubtarget &ST, ObservedValues &Values) {
  const auto &TII = *ST.getInstrInfo();
  const auto &TRI = *ST.getRegisterInfo();
  std::string Text;
  raw_string_ostream OS(Text);
  MI.print(OS);
  json::Array Operands, Memory;
  bool Complete =
      !MI.isCall() && !MI.isInlineAsm() && !MI.hasUnmodeledSideEffects();
  bool Vector = false;
  for (auto [Idx, MO] : enumerate(MI.operands())) {
    Operands.push_back(operand(MO, Idx, MI, TRI));
    if (MO.isRegMask())
      Complete = false;
    if (MO.isReg()) {
      Vector |= physicalGroup8(MO.getReg()) != 0;
      if (MO.getSubReg() || (MO.getReg() && !MO.getReg().isPhysical()))
        Complete = false;
    }
  }
  for (const auto *MMO : MI.memoperands()) {
    auto Size = MMO->getSize();
    json::Object M{
        {"load", MMO->isLoad()},
        {"store", MMO->isStore()},
        {"volatile", MMO->isVolatile()},
        {"atomic", MMO->isAtomic()},
        {"offset", MMO->getOffset()},
        {"alignment", MMO->getAlign().value()},
        {"base", valueName(MMO->getValue())},
        {"stack_slot", nullptr},
        {"bytes", Size.hasValue()
                      ? json::Value(Size.getValue().getKnownMinValue())
                      : json::Value(nullptr)},
        {"scalable", Size.hasValue() && Size.getValue().isScalable()},
        {"alias_scope", MMO->getAAInfo().Scope != nullptr},
        {"noalias", MMO->getAAInfo().NoAlias != nullptr}};
    if (const auto *S = dyn_cast_or_null<FixedStackPseudoSourceValue>(
            MMO->getPseudoValue())) {
      M["stack_slot"] = S->getFrameIndex();
      M["spill_slot"] =
          MI.getMF()->getFrameInfo().isSpillSlotObjectIndex(S->getFrameIndex());
    }
    Memory.push_back(std::move(M));
  }
  uint64_t Flags = MI.getDesc().TSFlags;
  auto *P = RISCVVPseudosTable::getPseudoInfo(MI.getOpcode());
  unsigned Group = P ? group8(RISCVII::getLMul(Flags)) : 0;
  json::Value SEW = nullptr, VL = nullptr, Stride = nullptr;
  json::Value IndexGroup = nullptr, IndexEEW = nullptr;
  if (P && (MI.mayLoad() || MI.mayStore()))
    if (auto *Index = indexedInfo(MI.getOpcode(), P->VLMul)) {
      IndexGroup = group8(Index->IndexLMUL);
      IndexEEW = int64_t(1) << Index->Log2SEW;
    }
  if (P && RISCVII::hasSEWOp(Flags)) {
    const auto &O = MI.getOperand(RISCVII::getSEWOpNum(MI.getDesc()));
    if (O.isImm() && O.getImm() >= 0 && O.getImm() <= 6)
      SEW = O.getImm() == 0 ? 1 : int64_t(1) << O.getImm();
  }
  if (P && RISCVII::hasVLOp(Flags))
    VL = Values.jsonValue(MI, RISCV::VL);
  if (P && (MI.mayLoad() || MI.mayStore())) {
    int Idx = RISCV::getNamedOperandIdx(MI.getOpcode(), RISCV::OpName::rs2);
    if (Idx >= 0 && MI.getOperand(Idx).isReg())
      Stride = Values.jsonValue(MI, MI.getOperand(Idx).getReg());
  }
  return json::Object{
      {"id", ID},
      {"block", MI.getParent()->getNumber()},
      {"mir", Text},
      {"opcode", TII.getName(MI.getOpcode())},
      {"base_opcode",
       P ? TII.getName(P->BaseInstr) : TII.getName(MI.getOpcode())},
      {"pseudo", MI.getDesc().isPseudo()},
      {"vector", Vector || P},
      {"meta", MI.isMetaInstruction()},
      {"configuration", RISCVInstrInfo::isVectorConfigInstr(MI)},
      {"load", MI.mayLoad()},
      {"store", MI.mayStore()},
      {"registers_complete", Complete},
      {"lmul8", Group ? json::Value(Group) : json::Value(nullptr)},
      {"sew", std::move(SEW)},
      {"vl", std::move(VL)},
      {"stride", std::move(Stride)},
      {"index_emul8", std::move(IndexGroup)},
      {"index_eew", std::move(IndexEEW)},
      {"masked", RISCV::getMaskedPseudoInfo(MI.getOpcode()) != nullptr},
      {"operands", std::move(Operands)},
      {"memory", std::move(Memory)}};
}
// Unit-level reaching definitions preserve partial group dependencies. The
// operand index is its original MIR index, including non-register operands.
json::Array dependencies(const json::Array &Instructions) {
  DenseMap<int64_t, int64_t> Reaching;
  json::Array Edges;
  auto Write = [&](const json::Object &I) {
    if (!*I.getBoolean("registers_complete"))
      Reaching.clear();
    for (const auto &V : *I.getArray("operands")) {
      const auto &O = *V.getAsObject();
      if (O.getString("kind") != "register" || !*O.getBoolean("def"))
        continue;
      for (const auto &U : *O.getArray("units")) {
        if (*O.getInteger("subregister"))
          Reaching.erase(*U.getAsInteger());
        else
          Reaching[*U.getAsInteger()] = *I.getInteger("id");
      }
    }
  };
  for (const auto &V : Instructions)
    if (V.getAsObject()->getString("role") == "body")
      Write(*V.getAsObject());
  for (const auto &V : Instructions) {
    const auto &I = *V.getAsObject();
    if (I.getString("role") != "body")
      continue;
    for (const auto &OV : *I.getArray("operands")) {
      const auto &O = *OV.getAsObject();
      if (O.getString("kind") != "register" || !*O.getBoolean("use") ||
          *O.getBoolean("undef"))
        continue;
      for (const auto &U : *O.getArray("units")) {
        auto It = Reaching.find(*U.getAsInteger());
        if (It == Reaching.end())
          continue; // live-in, explicitly covered by complete register facts
        int64_t Dest = *I.getInteger("id"), Source = It->second;
        Edges.push_back(
            json::Object{{"source", Source},
                         {"destination", Dest},
                         {"operand_index", *O.getInteger("index")},
                         {"unit", *U.getAsInteger()},
                         {"iteration_distance", Source >= Dest ? 1 : 0},
                         {"kind", "register-raw"}});
      }
    }
    Write(I);
  }
  return Edges;
}
}
json::Object llvm::vplan::collectAnalytics(MachineFunction &MF) {
  const auto &F = MF.getFunction();
  const auto &ST = MF.getSubtarget<RISCVSubtarget>();
  StringRef ID = F.getFnAttribute("vplan.ra.candidate").getValueAsString();
  MachineDominatorTree DT(MF);
  MachineLoopInfo LI(DT);
  ObservedValues Values(MF, DT);
  MachineLoop *Loop = nullptr;
  std::string Error;
  for (auto *L : LI.getLoopsInPreorder())
    if (candidate(*L) == ID) {
      if (Loop)
        Error = "multiple loops carry candidate identity";
      Loop = L;
    }
  if (!Loop)
    Error = "candidate machine loop identity lost";
  else if (!Loop->isInnermost() || Loop->getNumBlocks() != 1 ||
           Loop->getLoopLatch() != Loop->getHeader())
    Error = "only innermost single-block loops have a proven circular "
            "execution order";
  if (attr(F, "vplan.ra.iteration-mapping") != 1)
    Error = "original scalar iteration mapping is unproven";
  int64_t Header = Loop ? Loop->getHeader()->getNumber() : -1;
  json::Array Blocks, Instructions, Order;
  for (auto &BB : MF) {
    StringRef Role = "outside";
    if (Loop && Loop->contains(&BB))
      Role = "body";
    else if (Loop && &BB == Loop->getLoopPreheader())
      Role = "setup";
    else if (Loop && LI.getLoopFor(&BB))
      Role = "tail-or-other-loop";
    else if (Loop && llvm::is_contained(BB.predecessors(), Loop->getHeader()))
      Role = "exit";
    json::Array Successors;
    for (auto *S : BB.successors())
      Successors.push_back(S->getNumber());
    Blocks.push_back(json::Object{{"id", BB.getNumber()},
                                  {"role", Role},
                                  {"successors", std::move(Successors)}});
    bool BackedgeSeen = false;
    for (auto &MI : BB) {
      if (MI.isDebugInstr())
        continue;
      auto I = instruction(MI, Instructions.size(), ST, Values);
      // Instructions following a taken backedge (typically the explicit exit
      // jump) are not executed on the repeated body path.
      StringRef InstructionRole = BackedgeSeen ? "exit" : Role;
      I["role"] = InstructionRole;
      if (InstructionRole == "body")
        Order.push_back(*I.getInteger("id"));
      Instructions.push_back(std::move(I));
      if (Role == "body" && MI.isBranch())
        for (const auto &MO : MI.operands())
          if (MO.isMBB() && MO.getMBB() == Loop->getHeader())
            BackedgeSeen = true;
    }
  }
  auto Edges = dependencies(Instructions);
  return json::Object{
      {"schema", "mir-local-observation-v2"},
      {"run_id", getVPlanRARunID()},
      {"candidate", ID},
      {"function", F.getName()},
      {"stage", "post-frame-lowering"},
      {"compiler", LLVM_VERSION_STRING},
      {"target_triple", F.getParent()->getTargetTriple().str()},
      {"cpu", ST.getTuneCPU()},
      {"features", ST.getFeatureString()},
      {"vlen", ST.getRealMinVLen()},
      {"vf", attr(F, "vplan.ra.vf", 1)},
      {"scalable", attr(F, "vplan.ra.scalable") != 0},
      {"iteration_width", attr(F, "vplan.ra.width", 1)},
      {"iteration_mapping", attr(F, "vplan.ra.iteration-mapping") == 1},
      {"max_trip_count", attr(F, "vplan.ra.max-trip-count")},
      {"exact_trip_count", attr(F, "vplan.ra.exact-trip-count")},
      {"scalar_tail", attr(F, "vplan.ra.scalar-tail") != 0},
      {"error", Error},
      {"header", Header},
      {"register_coverage", "physical-register-units-distance-0-1"},
      {"memory_coverage",
       "facts-only; alias and runtime addresses may be unknown"},
      {"blocks", std::move(Blocks)},
      {"body_order", std::move(Order)},
      {"instructions", std::move(Instructions)},
      {"dependencies", std::move(Edges)}};
}
