// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVVPlanMIR.h"
#include "RISCVInstrInfo.h"
#include "RISCVSubtarget.h"
#include "RISCVVPlanSpill.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/CodeGen/MachineFrameInfo.h"
#include "llvm/CodeGen/PseudoSourceValue.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Function.h"
#include "llvm/PassInfo.h"
#include "llvm/PassRegistry.h"
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
std::optional<std::pair<unsigned, unsigned>> indexedInfo(unsigned Opcode,
                                                         unsigned DataLMUL) {
  for (unsigned LogEEW = 3; LogEEW <= 6; ++LogEEW)
    for (unsigned IndexLMUL = 0; IndexLMUL < 8; ++IndexLMUL) {
      if (!group8(IndexLMUL))
        continue;
      for (bool Masked : {false, true})
        for (bool Ordered : {false, true}) {
          auto *L =
              RISCV::getVLXPseudo(Masked, Ordered, LogEEW, DataLMUL, IndexLMUL);
          auto *S =
              RISCV::getVSXPseudo(Masked, Ordered, LogEEW, DataLMUL, IndexLMUL);
          if ((L && L->Pseudo == Opcode) || (S && S->Pseudo == Opcode))
            return std::pair{group8(IndexLMUL), 1u << LogEEW};
          for (unsigned Fields = 2; Fields <= 8; ++Fields) {
            auto *L = RISCV::getVLXSEGPseudo(Fields, Masked, Ordered, LogEEW,
                                             DataLMUL, IndexLMUL);
            auto *S = RISCV::getVSXSEGPseudo(Fields, Masked, Ordered, LogEEW,
                                             DataLMUL, IndexLMUL);
            if ((L && L->Pseudo == Opcode) || (S && S->Pseudo == Opcode))
              return std::pair{group8(IndexLMUL), 1u << LogEEW};
          }
        }
    }
  return std::nullopt;
}
// Raw matrix MC instructions do not have RVV pseudo SEW/LMUL operands.
// Join reaching immediate VTYPE definitions; conflicting or dynamic state is
// unavailable, never guessed from the physical base register.
std::optional<unsigned> matrixVType(const MachineInstr &MI) {
  using Position =
      std::pair<const MachineBasicBlock *, MachineBasicBlock::const_iterator>;
  SmallVector<Position> Work{{MI.getParent(), MI.getIterator()}};
  SmallPtrSet<const MachineBasicBlock *, 16> Seen;
  std::optional<unsigned> Type;
  const auto *TRI = MI.getMF()->getSubtarget().getRegisterInfo();
  while (!Work.empty()) {
    auto [BB, It] = Work.pop_back_val();
    bool Found = false;
    while (It != BB->begin()) {
      const auto &Prev = *--It;
      switch (Prev.getOpcode()) {
      case RISCV::VSETVLI:
      case RISCV::VSETIVLI:
      case RISCV::PseudoVSETVLI:
      case RISCV::PseudoVSETVLIX0:
      case RISCV::PseudoVSETVLIX0X0:
      case RISCV::PseudoVSETIVLI: {
        if (Prev.getNumOperands() < 3 || !Prev.getOperand(2).isImm())
          return std::nullopt;
        unsigned Current = Prev.getOperand(2).getImm() & 0x3f;
        if (Type && *Type != Current)
          return std::nullopt;
        Type = Current;
        Found = true;
        break;
      }
      default:
        break;
      }
      if (Found)
        break;
      if (Prev.isCall() || Prev.isInlineAsm() ||
          Prev.modifiesRegister(RISCV::VTYPE, TRI))
        return std::nullopt;
    }
    if (Found)
      continue;
    if (BB->pred_empty())
      return std::nullopt;
    for (const auto *Pred : BB->predecessors())
      if (Seen.insert(Pred).second)
        Work.emplace_back(Pred, Pred->end());
  }
  return Type;
}
bool isMatrix(unsigned Opcode) {
  switch (Opcode) {
  case RISCV::VMMACC_VV:
  case RISCV::VFMMACC_VV:
  case RISCV::VWMMACC_VV:
  case RISCV::VFWMMACC_VV:
  case RISCV::VFWMMACC_VV_SCALE:
  case RISCV::VFWIMMACC_VV:
  case RISCV::VQMMACC_VV:
  case RISCV::VFQMMACC_VV:
  case RISCV::VFQMMACC_VV_SCALE:
  case RISCV::VFQIMMACC_VV:
  case RISCV::V8WMMACC_VV:
  case RISCV::VF8WMMACC_VV:
  case RISCV::VF8WMMACC_VV_SCALE:
  case RISCV::VF8WIMMACC_VV:
  case RISCV::VMTL_V:
  case RISCV::VMTS_V:
  case RISCV::VMTTL_V:
  case RISCV::VMTTS_V:
    return true;
  default:
    return false;
  }
}
} // namespace
VPlanMIRInstruction llvm::vplan::collectMIRInstruction(const MachineInstr &MI,
                                                       bool Text) {
  const auto &MF = *MI.getMF();
  const auto &ST = MF.getSubtarget<RISCVSubtarget>();
  const auto &TII = *ST.getInstrInfo();
  auto *P = RISCVVPseudosTable::getPseudoInfo(MI.getOpcode());
  VPlanMIRInstruction O;
  O.Opcode = TII.getName(MI.getOpcode()).str();
  O.BaseOpcode = P ? TII.getName(P->BaseInstr).str() : O.Opcode;
  O.BaseOpcodeID = P ? P->BaseInstr : MI.getOpcode();
  O.Call = MI.isCall();
  if (MI.isInlineAsm())
    for (const auto &MO : MI.operands())
      if (MO.isMetadata()) {
        const MDNode *MD = MO.getMetadata();
        if (MD->getNumOperands() == 2 &&
            isa_and_nonnull<MDString>(MD->getOperand(0)) &&
            cast<MDString>(MD->getOperand(0))->getString() ==
                "vplan.asm.arguments")
          if (auto *N = mdconst::dyn_extract<ConstantInt>(MD->getOperand(1)))
            O.InlineAsmArguments = N->getZExtValue();
      }
  for (const auto *MMO : MI.memoperands()) {
    O.MemoryAlignment =
        O.MemoryAlignment ? std::min(O.MemoryAlignment, MMO->getAlign().value())
                          : MMO->getAlign().value();
    O.AddressSpace = MMO->getAddrSpace();
  }
  O.Pseudo = MI.getDesc().isPseudo();
  O.Configuration = RISCVInstrInfo::isVectorConfigInstr(MI);
  O.Load = MI.mayLoad();
  O.Store = MI.mayStore();
  for (const auto &MO : MI.operands())
    if (MO.isReg())
      if (unsigned G = physicalGroup8(MO.getReg()))
        O.RegisterGroups8.push_back(G);
  O.Vector = P || !O.RegisterGroups8.empty();
  O.Spill = (O.Load || O.Store) &&
            llvm::any_of(MI.memoperands(), [&](const auto *MMO) {
              auto *S = dyn_cast_or_null<FixedStackPseudoSourceValue>(
                  MMO->getPseudoValue());
              return S && MF.getFrameInfo().isSpillSlotObjectIndex(
                              S->getFrameIndex());
            });
  if (P) {
    uint64_t Flags = MI.getDesc().TSFlags;
    O.LMUL8 = group8(RISCVII::getLMul(Flags));
    if (RISCVII::hasSEWOp(Flags)) {
      const auto &S = MI.getOperand(RISCVII::getSEWOpNum(MI.getDesc()));
      if (S.isImm() && S.getImm() >= 0 && S.getImm() <= 6)
        O.SEW = S.getImm() == 0 ? 1 : 1u << S.getImm();
    }
    if (O.Load || O.Store)
      if (auto Index = indexedInfo(MI.getOpcode(), P->VLMul)) {
        O.IndexEMUL8 = Index->first;
        O.IndexEEW = Index->second;
      }
  }
  if (isMatrix(O.BaseOpcodeID)) {
    if (auto Type = matrixVType(MI)) {
      O.SEW = RISCVVType::getSEW(*Type);
      O.LMUL8 = group8(unsigned(RISCVVType::getVLMUL(*Type)));
    }
    if (O.Load || O.Store) {
      if (MI.getNumOperands() > 3 && MI.getOperand(3).isImm()) {
        int64_t Encoded = MI.getOperand(3).getImm();
        O.MatrixLambda = Encoded == 0                  ? 0
                         : Encoded > 0 && Encoded <= 7 ? 1u << (Encoded - 1)
                                                       : 128;
      }
    }
  }
  if (Text) {
    raw_string_ostream OS(O.Text);
    MI.print(OS);
  }
  return O;
}
char RISCVVPlanMIR::ID = 0;
RISCVVPlanMIR::RISCVVPlanMIR(VPlanBackendResult &Sink,
                             VPlanFeedbackTimer *Timer, bool Text,
                             bool CollectMIR)
    : MachineFunctionPass(ID), Sink(Sink), Timer(Timer), Text(Text),
      CollectMIR(CollectMIR) {
  static const PassInfo PI("RISC-V VPlan MIR body observer", "riscv-vplan-mir",
                           &ID, nullptr, false, false);
  static const bool Registered = [] {
    PassRegistry::getPassRegistry()->registerPass(PI);
    return true;
  }();
  (void)Registered;
}
void RISCVVPlanMIR::getAnalysisUsage(AnalysisUsage &AU) const {
  AU.setPreservesAll();
  MachineFunctionPass::getAnalysisUsage(AU);
}
bool RISCVVPlanMIR::runOnMachineFunction(MachineFunction &MF) {
  if (Timer)
    Timer->mark("post_rvv_to_frame_lowering");
  if (MF.getFunction().hasFnAttribute("vplan.backend.candidate")) {
    vplan::observeCommonBody(MF, Sink, CollectMIR, Text);
  }
  if (Timer)
    Timer->mark("mir_collection");
  return false;
}
