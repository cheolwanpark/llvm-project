// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVVPlanSpill.h"
#include "RISCVInstrInfo.h"
#include "RISCVSubtarget.h"
#include "RISCVVPlanMIR.h"
#include "RISCVVPlanMapping.h"
#include "llvm/CodeGen/MachineFrameInfo.h"
#include "llvm/CodeGen/MachineRegisterInfo.h"
#include "llvm/CodeGen/PseudoSourceValue.h"
#include "llvm/IR/Function.h"
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

Error llvm::vplan::collectSpillAccess(const MachineInstr &MI,
                                      std::vector<VPlanSpillAccess> &Accesses) {
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
      continue; // Address registers do not determine the vector access group.
    Vector = true;
    if (!R.isPhysical() || MO.getSubReg())
      return vplanBackendError(
          VPlanBackendFailureGroup::Collection,
          "vector spill data register is not fully allocated", "",
          "post-frame-lowering");
  }
  if (!Vector) {
    if (MI.memoperands().size() != 1 || MI.mayLoad() == MI.mayStore() ||
        MI.isCall() || MI.isInlineAsm() || MI.hasUnmodeledSideEffects() ||
        !MI.getOperand(0).isReg() || !MI.getOperand(0).getReg().isPhysical() ||
        MI.getOperand(0).getSubReg())
      return vplanBackendError(VPlanBackendFailureGroup::Collection,
                               "unsupported scalar spill access", "",
                               "post-frame-lowering");
    const auto &MMO = **MI.memoperands_begin();
    if (!MMO.getSize().isPrecise() || MMO.isVolatile() || MMO.isAtomic() ||
        MMO.getSize().getValue().isScalable() || MMO.isLoad() != MI.mayLoad() ||
        MMO.isStore() != MI.mayStore())
      return vplanBackendError(VPlanBackendFailureGroup::Collection,
                               "unsupported scalar spill memory operand", "",
                               "post-frame-lowering");
    auto R = MI.getOperand(0).getReg();
    bool FP = RISCV::FPR16RegClass.contains(R) ||
              RISCV::FPR32RegClass.contains(R) ||
              RISCV::FPR64RegClass.contains(R);
    if (!FP && !RISCV::GPRRegClass.contains(R))
      return vplanBackendError(VPlanBackendFailureGroup::Collection,
                               "unsupported scalar spill register", "",
                               "post-frame-lowering");
    Accesses.push_back(
        {MI.mayLoad(), MMO.getSize().getValue().getKnownMinValue(), false,
         MMO.getAlign().value(), MMO.getAddrSpace(), true, 1, false,
         FP ? VPlanSpillAccess::RegisterKind::FloatingPoint
            : VPlanSpillAccess::RegisterKind::Integer});
    return Error::success();
  }
  auto Segment = RISCV::isRVVSpillForZvlsseg(MI.getOpcode());
  unsigned Group = wholeGroup(MI.getOpcode());
  if ((!Segment && !Group) || MI.memoperands().size() != 1 ||
      MI.mayLoad() == MI.mayStore() || MI.isCall() || MI.isInlineAsm() ||
      MI.hasUnmodeledSideEffects() || !MI.getOperand(0).isReg() ||
      !MI.getOperand(0).getReg().isPhysical() || MI.getOperand(0).getSubReg())
    return vplanBackendError(VPlanBackendFailureGroup::Collection,
                             "unsupported vector spill access", "",
                             "post-frame-lowering");
  const auto &MMO = **MI.memoperands_begin();
  if (MMO.isVolatile() || MMO.isAtomic() || MMO.isLoad() != MI.mayLoad() ||
      MMO.isStore() != MI.mayStore())
    return vplanBackendError(VPlanBackendFailureGroup::Collection,
                             "unsupported vector spill memory operand", "",
                             "post-frame-lowering");
  auto Reg = MI.getOperand(0).getReg();
  const auto *DataRC = TRI.getMinimalPhysRegClass(Reg);
  if (!DataRC || !RISCVRegisterInfo::isRVVRegClass(DataRC))
    return vplanBackendError(
        VPlanBackendFailureGroup::Collection,
        "vector spill data operand is not a vector register", "",
        "post-frame-lowering");
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
      return vplanBackendError(VPlanBackendFailureGroup::Collection,
                               "vector spill opcode/register group mismatch",
                               "", "post-frame-lowering");
    // Whole-register opcode determines the access, not the stack slot size.
    Add(Group, TypeSize::getScalable(Group * 8), false);
    return Error::success();
  }
  if (RISCVRI::getNF(DataRC->TSFlags) != Segment->first ||
      (1u << unsigned(RISCVRI::getLMul(DataRC->TSFlags))) != Segment->second)
    return vplanBackendError(VPlanBackendFailureGroup::Collection,
                             "segment spill opcode/register geometry mismatch",
                             "", "post-frame-lowering");
  unsigned NumRegs = Segment->first * Segment->second;
  auto Size = MMO.getSize();
  if (!NumRegs || NumRegs > 8 || !Size.isPrecise() ||
      !Size.getValue().isKnownMultipleOf(NumRegs))
    return vplanBackendError(VPlanBackendFailureGroup::Collection,
                             "unsupported segment spill size", "",
                             "post-frame-lowering");
  auto VRegSize = Size.getValue().divideCoefficientBy(NumRegs);
  if (!VRegSize.getKnownMinValue())
    return vplanBackendError(VPlanBackendFailureGroup::Collection,
                             "empty segment spill size", "",
                             "post-frame-lowering");
  unsigned Encoding = TRI.getEncodingValue(Reg);
  while (NumRegs) {
    unsigned G = RISCVRegisterInfo::getSegmentSpillGroup(NumRegs, Encoding);
    Add(G, VRegSize * G, true);
    Encoding += G;
    NumRegs -= G;
  }
  return Error::success();
}

namespace {
bool isBodyInstruction(const MachineInstr &MI) {
  return !MI.isMetaInstruction() && !MI.isPseudoProbe() && !MI.isReturn() &&
         !MI.getFlag(MachineInstr::FrameSetup) &&
         !MI.getFlag(MachineInstr::FrameDestroy);
}

} // namespace

Error llvm::vplan::readCandidateIdentity(const Function &F,
                                         VPlanBackendResult &Result) {
  auto ID = F.getFnAttribute("vplan.backend.candidate").getValueAsString();
  auto Role = F.getFnAttribute("vplan.backend.role").getValueAsString();
  auto VF = attr(F, "vplan.backend.vf"), IC = attr(F, "vplan.backend.ic");
  bool Scalar = Role == "scalar-baseline";
  if (ID.empty() || VF <= 0 || VF > UINT32_MAX || IC <= 0 || IC > UINT32_MAX ||
      (Role != "main" && Role != "epilogue" && !Scalar))
    return vplanBackendError(VPlanBackendFailureGroup::Integrity,
                             "invalid backend candidate identity", ID, "input");
  if (Scalar && (VF != 1 || IC != 1 || attr(F, "vplan.backend.scalable") != 0))
    return vplanBackendError(VPlanBackendFailureGroup::Integrity,
                             "invalid scalar baseline observation identity", ID,
                             "input");
  Result.Candidate = ID.str();
  Result.VF = ElementCount::get(VF, attr(F, "vplan.backend.scalable") != 0);
  Result.IC = IC;
  Result.IsEpilogue = Role == "epilogue";
  Result.Kind = Scalar ? VPlanBackendCandidateKind::ScalarBaseline
                       : VPlanBackendCandidateKind::Vector;
  return Error::success();
}

using BodyRegion = SmallVector<TrackedLoopBody<MachineBasicBlock>>;
static Error collectBody(MachineFunction &MF, VPlanBackendResult &Result,
                         bool MIR, bool Text, const BodyRegion *Mapped,
                         const VPlanBackendObservation *Evidence) {
  auto &Observation = MIR ? Result.MIR : Result.Spill;
  Observation.Stage = "post-frame-lowering";
  VPlanBackendResult Identity;
  if (auto E = vplan::readCandidateIdentity(MF.getFunction(), Identity)) {
    auto Failure = takeVPlanBackendFailure(std::move(E),
                                           VPlanBackendFailureGroup::Integrity,
                                           Result.Candidate, Observation.Stage);
    Failure.Stage = Observation.Stage;
    return vplanBackendError(std::move(Failure));
  }
  if (Identity.Candidate != Result.Candidate || Identity.VF != Result.VF ||
      Identity.IC != Result.IC || Identity.Kind != Result.Kind ||
      Identity.IsEpilogue != Result.IsEpilogue)
    return vplanBackendError(VPlanBackendFailureGroup::Integrity,
                             "backend observation identity mismatch",
                             Result.Candidate, Observation.Stage);
  if (Evidence)
    Observation = *Evidence;
  Expected<BodyRegion> Region = Mapped ? Expected<BodyRegion>(*Mapped)
                                       : vplan::mapProbeBody(MF, Observation);
  if (!Region)
    return Region.takeError();
  // Commit only complete loop payloads. A bad loop does not erase survivors.
  std::vector<VPlanBackendLoopObservation> Included;
  uint64_t Blocks = 0;
  for (unsigned I = 0; I != Region->size(); ++I) {
    auto Loop = std::move(Observation.Loops[I]);
    auto Collect = [&]() -> Error {
      if (MIR)
        Loop.MIRBody.emplace();
      for (const auto *BB : (*Region)[I].Blocks)
        for (const auto &MI : *BB) {
          if (!isBodyInstruction(MI))
            continue;
          if (MIR)
            Loop.MIRBody->push_back(vplan::collectMIRInstruction(MI, Text));
          else if (auto E = vplan::collectSpillAccess(MI, Loop.Spills))
            return E;
        }
      return Error::success();
    };
    if (auto E = Collect()) {
      auto Failure = takeVPlanBackendFailure(
          std::move(E), VPlanBackendFailureGroup::Collection, Result.Candidate,
          Observation.Stage);
      Failure.Stage = Observation.Stage;
      Failure.TrackingID = Loop.TrackingID;
      Failure.ObservationID = Loop.ID;
      if (Result.CaptureFailures)
        Observation.Exclusions.push_back(std::move(Failure));
      continue;
    }
    Blocks += Loop.SelectedBlockCount;
    Included.push_back(std::move(Loop));
  }
  Observation.Loops = std::move(Included);
  Observation.SelectedBlockCount = Blocks;
  if (Observation.Loops.empty())
    return vplanBackendError(VPlanBackendFailureGroup::Collection,
                             "no-usable-target-loop", Result.Candidate,
                             Observation.Stage);
  Observation.Status = VPlanBackendObservationStatus::Succeeded;
  return Error::success();
}
static void
observeMappedBody(MachineFunction &MF, VPlanBackendResult &Result, bool MIR,
                  bool Text, const BodyRegion *Mapped = nullptr,
                  const VPlanBackendObservation *Evidence = nullptr) {
  auto &Slot = MIR ? Result.MIR : Result.Spill;
  if (Slot.Status != VPlanBackendObservationStatus::NotCollected) {
    Slot = VPlanBackendObservation();
    Slot.Status = VPlanBackendObservationStatus::Failed;
    Slot.Failure = VPlanBackendFailure{VPlanBackendFailureGroup::Integrity,
                                       "ambiguous backend candidate function",
                                       Result.Candidate,
                                       "post-frame-lowering",
                                       {},
                                       {}};
  } else if (auto E = collectBody(MF, Result, MIR, Text, Mapped, Evidence)) {
    // Discard only this slot's provisional payload. Preserve scope evidence
    // and the other slot's independently owned result.
    for (auto &Loop : Slot.Loops) {
      Loop.Spills.clear();
      Loop.MIRBody.reset();
    }
    Slot.Status = VPlanBackendObservationStatus::Failed;
    Slot.Failure = takeVPlanBackendFailure(
        std::move(E), VPlanBackendFailureGroup::Collection, Result.Candidate,
        "post-frame-lowering");
  }
  Slot.Stage = "post-frame-lowering";
}
void llvm::vplan::observeBody(MachineFunction &MF, VPlanBackendResult &Result,
                              bool MIR, bool Text) {
  observeMappedBody(MF, Result, MIR, Text);
}
void llvm::vplan::observeCommonBody(MachineFunction &MF,
                                    VPlanBackendResult &Result, bool MIR,
                                    bool Text) {
  VPlanBackendObservation Evidence;
  auto Region = mapProbeBody(MF, Evidence);
  if (!Region) {
    auto Failure = takeVPlanBackendFailure(Region.takeError(),
                                           VPlanBackendFailureGroup::Tracking,
                                           Result.Candidate, Evidence.Stage);
    for (auto *Slot : {&Result.Spill, &Result.MIR}) {
      if (Slot == &Result.MIR && !MIR)
        continue;
      *Slot = Evidence;
      Slot->Status = VPlanBackendObservationStatus::Failed;
      Slot->Failure = Failure;
    }
    return;
  }
  observeMappedBody(MF, Result, false, false, &*Region, &Evidence);
  if (MIR)
    observeMappedBody(MF, Result, true, Text, &*Region, &Evidence);
}
