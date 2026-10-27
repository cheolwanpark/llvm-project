// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVVPlanSpill.h"
#include "RISCVInstrInfo.h"
#include "RISCVSubtarget.h"
#include "RISCVVPlanMIR.h"
#include "llvm/CodeGen/MachineDominators.h"
#include "llvm/CodeGen/MachineFrameInfo.h"
#include "llvm/CodeGen/MachineLoopInfo.h"
#include "llvm/CodeGen/MachineRegisterInfo.h"
#include "llvm/CodeGen/PseudoSourceValue.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Metadata.h"
#include "llvm/PassInfo.h"
#include "llvm/PassRegistry.h"
using namespace llvm;
namespace {
int64_t attr(const Function &F, StringRef Name) {
  auto A = F.getFnAttribute(Name);
  int64_t N;
  return A.isStringAttribute() && !A.getValueAsString().getAsInteger(10, N) ? N
                                                                            : 0;
}
StringRef candidate(const MachineLoop &L) {
  auto *ID = L.getLoopID();
  if (!ID)
    return {};
  for (const auto &Op : drop_begin(ID->operands()))
    if (auto *N = dyn_cast_or_null<MDNode>(Op))
      if (N->getNumOperands() == 2)
        if (auto *K = dyn_cast<MDString>(N->getOperand(0)))
          if (K->getString() == "llvm.loop.vplan.backend.candidate")
            if (auto *V = dyn_cast<MDString>(N->getOperand(1)))
              return V->getString();
  return {};
}
unsigned wholeGroup(unsigned Opcode) {
  switch (Opcode) {
#define GROUP(N)                                                               \
  case RISCV::VS##N##R_V:                                                      \
  case RISCV::VL##N##RE8_V:                                                    \
  case RISCV::VL##N##RE16_V:                                                   \
  case RISCV::VL##N##RE32_V:                                                   \
  case RISCV::VL##N##RE64_V:                                                   \
    return N;
    GROUP(1)
    GROUP(2)
    GROUP(4)
    GROUP(8)
#undef GROUP
  default:
    return 0;
  }
}
class TimingMarker : public MachineFunctionPass {
  VPlanFeedbackTimer &Timer;
  std::string Phase;

public:
  static char ID;
  TimingMarker(VPlanFeedbackTimer &Timer, StringRef Phase)
      : MachineFunctionPass(ID), Timer(Timer), Phase(Phase.str()) {}
  StringRef getPassName() const override {
    return "VPlan backend timing boundary";
  }
  void getAnalysisUsage(AnalysisUsage &AU) const override {
    AU.setPreservesAll();
    MachineFunctionPass::getAnalysisUsage(AU);
  }
  bool runOnMachineFunction(MachineFunction &) override {
    Timer.mark(Phase);
    return false;
  }
};
char TimingMarker::ID = 0;
} // namespace
FunctionPass *llvm::createRISCVVPlanTimingMarker(VPlanFeedbackTimer &Timer,
                                                 StringRef Phase) {
  return new TimingMarker(Timer, Phase);
}

Error llvm::vplan::collectVectorSpillAccess(
    const MachineInstr &MI, std::vector<VPlanVectorSpillAccess> &Accesses) {
  if (MI.isMetaInstruction())
    return Error::success();
  const auto &MF = *MI.getMF();
  bool Spill = any_of(MI.memoperands(), [&](const MachineMemOperand *MMO) {
    auto *S =
        dyn_cast_or_null<FixedStackPseudoSourceValue>(MMO->getPseudoValue());
    return S && MF.getFrameInfo().isSpillSlotObjectIndex(S->getFrameIndex());
  });
  if (!Spill)
    return Error::success();
  const auto &TRI = *MF.getSubtarget<RISCVSubtarget>().getRegisterInfo();
  const auto &MRI = MF.getRegInfo();
  bool Vector = false;
  for (auto &MO : MI.operands()) {
    if (!MO.isReg() || !MO.getReg())
      continue;
    auto R = MO.getReg();
    const auto *RC =
        R.isVirtual() ? MRI.getRegClass(R) : TRI.getMinimalPhysRegClass(R);
    bool RVV = RC && RISCVRegisterInfo::isRVVRegClass(RC);
    if (!RVV)
      continue; // Scalar address registers need not have been allocated.
    Vector = true;
    if (!R.isPhysical() || MO.getSubReg())
      return createStringError(
          "vector spill data register is not fully allocated");
  }
  if (!Vector)
    return Error::success();
  auto Segment = RISCV::isRVVSpillForZvlsseg(MI.getOpcode());
  unsigned Group = wholeGroup(MI.getOpcode());
  if ((!Segment && !Group) || MI.memoperands().size() != 1 ||
      MI.mayLoad() == MI.mayStore() || MI.isCall() || MI.isInlineAsm() ||
      MI.hasUnmodeledSideEffects() || !MI.getOperand(0).isReg() ||
      !MI.getOperand(0).getReg().isPhysical() || MI.getOperand(0).getSubReg())
    return createStringError("unsupported vector spill access");
  const auto &MMO = **MI.memoperands_begin();
  if (MMO.isVolatile() || MMO.isAtomic() || MMO.isLoad() != MI.mayLoad() ||
      MMO.isStore() != MI.mayStore())
    return createStringError("unsupported vector spill memory operand");
  auto Reg = MI.getOperand(0).getReg();
  const auto *DataRC = TRI.getMinimalPhysRegClass(Reg);
  if (!DataRC || !RISCVRegisterInfo::isRVVRegClass(DataRC))
    return createStringError(
        "vector spill data operand is not a vector register");
  auto Add = [&](unsigned G, TypeSize Size, bool Segment) {
    Accesses.push_back({MI.mayLoad(), Size.getKnownMinValue(),
                        Size.isScalable(), MMO.getAlign().value(),
                        MMO.getAddrSpace(), true, G, Segment});
  };
  if (!Segment) {
    unsigned Actual = RISCV::VRM8RegClass.contains(Reg)   ? 8
                      : RISCV::VRM4RegClass.contains(Reg) ? 4
                      : RISCV::VRM2RegClass.contains(Reg) ? 2
                      : RISCV::VRRegClass.contains(Reg)   ? 1
                                                          : 0;
    if (Actual != Group)
      return createStringError("vector spill opcode/register group mismatch");
    // Whole-register opcode determines the access, not the stack slot size.
    Add(Group, TypeSize::getScalable(Group * 8), false);
    return Error::success();
  }
  if (RISCVRI::getNF(DataRC->TSFlags) != Segment->first ||
      (1u << unsigned(RISCVRI::getLMul(DataRC->TSFlags))) != Segment->second)
    return createStringError("segment spill opcode/register geometry mismatch");
  unsigned NumRegs = Segment->first * Segment->second;
  auto Size = MMO.getSize();
  if (!NumRegs || NumRegs > 8 || !Size.isPrecise() ||
      !Size.getValue().isKnownMultipleOf(NumRegs))
    return createStringError("unsupported segment spill size");
  auto VRegSize = Size.getValue().divideCoefficientBy(NumRegs);
  if (!VRegSize.getKnownMinValue())
    return createStringError("empty segment spill size");
  unsigned Encoding = TRI.getEncodingValue(Reg);
  while (NumRegs) {
    unsigned G = RISCVRegisterInfo::getSegmentSpillGroup(NumRegs, Encoding);
    Add(G, VRegSize * G, true);
    Encoding += G;
    NumRegs -= G;
  }
  return Error::success();
}

static Expected<VPlanBackendResult> collectBody(MachineFunction &MF, bool MIR,
                                                bool Text) {
  const Function &F = MF.getFunction();
  auto ID = F.getFnAttribute("vplan.backend.candidate").getValueAsString();
  auto Role = F.getFnAttribute("vplan.backend.role").getValueAsString();
  auto VF = attr(F, "vplan.backend.vf"), IC = attr(F, "vplan.backend.ic");
  auto Width = attr(F, "vplan.backend.width");
  if (ID.empty() || VF <= 0 || VF > UINT32_MAX || IC <= 0 || IC > UINT32_MAX ||
      (Role != "main" && Role != "epilogue"))
    return createStringError("invalid backend candidate identity");
  if (attr(F, "vplan.backend.iteration-mapping") != 1 || Width <= 0)
    return createStringError("original scalar iteration mapping is unproven");
  MachineDominatorTree DT(MF);
  MachineLoopInfo LI(DT);
  MachineLoop *Loop = nullptr;
  for (auto *L : LI.getLoopsInPreorder())
    if (candidate(*L) == ID) {
      if (Loop)
        return createStringError("multiple loops carry candidate identity");
      Loop = L;
    }
  if (!Loop)
    return createStringError("candidate machine loop identity lost");
  if (!Loop->isInnermost() || Loop->getNumBlocks() != 1 ||
      Loop->getLoopLatch() != Loop->getHeader())
    return createStringError("only innermost single-block loops have a proven "
                             "circular execution order");
  VPlanBackendResult Result;
  Result.Candidate = ID.str();
  Result.VF = ElementCount::get(VF, attr(F, "vplan.backend.scalable") != 0);
  Result.IC = IC;
  Result.IsEpilogue = Role == "epilogue";
  Result.IterationWidth = Width;
  Result.IterationMapping = true;
  if (MIR) {
    Result.Stage = "post-frame-lowering";
    Result.MIRBody.emplace();
  }
  bool BackedgeSeen = false;
  for (auto &MI : *Loop->getHeader()) {
    if (MIR) {
      if (!MI.isMetaInstruction())
        Result.MIRBody->push_back(vplan::collectMIRInstruction(MI, Text));
    } else if (auto E = vplan::collectVectorSpillAccess(MI, Result.Spills))
      return std::move(E);
    if (MI.isBranch())
      for (const auto &MO : MI.operands())
        if (MO.isMBB() && MO.getMBB() == Loop->getHeader())
          BackedgeSeen = true;
    if (BackedgeSeen)
      break;
  }
  if (!BackedgeSeen)
    return createStringError("candidate backedge is unproven");
  return Result;
}
Expected<VPlanBackendResult>
llvm::vplan::collectVectorSpills(MachineFunction &MF) {
  return collectBody(MF, false, false);
}
Expected<VPlanBackendResult> llvm::vplan::collectMIRBody(MachineFunction &MF,
                                                         bool Text) {
  return collectBody(MF, true, Text);
}
char RISCVVPlanSpill::ID = 0;
RISCVVPlanSpill::RISCVVPlanSpill(
    std::optional<Expected<VPlanBackendResult>> &Sink,
    VPlanFeedbackTimer *Timer)
    : MachineFunctionPass(ID), Sink(Sink), Timer(Timer) {
  // This internal pass requires a per-query sink and has no command-line
  // constructor. Register its identity for standard pass instrumentation.
  static const PassInfo PI("RISC-V VPlan vector spill observer",
                           "riscv-vplan-spill", &ID, nullptr, false, false);
  static const bool Registered = [] {
    PassRegistry::getPassRegistry()->registerPass(PI);
    return true;
  }();
  (void)Registered;
}
void RISCVVPlanSpill::getAnalysisUsage(AnalysisUsage &AU) const {
  AU.setPreservesAll();
  MachineFunctionPass::getAnalysisUsage(AU);
}
bool RISCVVPlanSpill::runOnMachineFunction(MachineFunction &MF) {
  if (Timer)
    Timer->mark("post_rvv_to_stack_slot_coloring");
  if (MF.getFunction().hasFnAttribute("vplan.backend.candidate")) {
    if (Sink) {
      if (!*Sink)
        consumeError(Sink->takeError());
      Sink.emplace(createStringError("ambiguous backend candidate function"));
    } else
      Sink.emplace(vplan::collectVectorSpills(MF));
  }
  if (Timer)
    Timer->mark("spill_collection");
  return false;
}
