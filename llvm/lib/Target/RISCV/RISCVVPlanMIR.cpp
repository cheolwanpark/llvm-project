// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVVPlanMIR.h"
#include "RISCVInstrInfo.h"
#include "RISCVSubtarget.h"
#include "llvm/CodeGen/MachineFrameInfo.h"
#include "llvm/CodeGen/PseudoSourceValue.h"
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
      if (auto *Index = indexedInfo(MI.getOpcode(), P->VLMul)) {
        O.IndexEMUL8 = group8(Index->IndexLMUL);
        O.IndexEEW = 1u << Index->Log2SEW;
      }
  }
  if (Text) {
    raw_string_ostream OS(O.Text);
    MI.print(OS);
  }
  return O;
}
char RISCVVPlanMIR::ID = 0;
RISCVVPlanMIR::RISCVVPlanMIR(std::optional<Expected<VPlanBackendResult>> &Sink,
                             VPlanFeedbackTimer *Timer, bool Text)
    : MachineFunctionPass(ID), Sink(Sink), Timer(Timer), Text(Text) {
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
    if (Sink) {
      if (!*Sink)
        consumeError(Sink->takeError());
      Sink.emplace(createStringError("ambiguous backend candidate function"));
    } else
      Sink.emplace(vplan::collectMIRBody(MF, Text));
  }
  if (Timer)
    Timer->mark("mir_collection");
  return false;
}
