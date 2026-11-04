// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVVPlanSpill.h"
#include "RISCVInstrInfo.h"
#include "RISCVSubtarget.h"
#include "RISCVVPlanMIR.h"
#include "llvm/ADT/SmallPtrSet.h"
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

namespace {
// The range is local to one observation stage. A null Last includes the entire
// block; a loop range ends at its backedge, before any exit-only instructions.
struct ObservedRegion {
  SmallVector<const MachineBasicBlock *, 4> Blocks;
  const MachineInstr *Last;
  uint64_t Width;
  uint64_t ProbeCount = 0;
};

bool isBodyInstruction(const MachineInstr &MI) {
  return !MI.isMetaInstruction() && !MI.isPseudoProbe() && !MI.isReturn() &&
         !MI.getFlag(MachineInstr::FrameSetup) &&
         !MI.getFlag(MachineInstr::FrameDestroy);
}

Expected<ObservedRegion> findLoopRegion(MachineFunction &MF) {
  const Function &F = MF.getFunction();
  auto Width = attr(F, "vplan.backend.width");
  if (attr(F, "vplan.backend.iteration-mapping") != 1 || Width <= 0)
    return createStringError("original scalar iteration mapping is unproven");
  auto ID = F.getFnAttribute("vplan.backend.candidate").getValueAsString();
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
  if (!Loop->isInnermost() || !Loop->getLoopLatch())
    return createStringError(
        "candidate is not an innermost loop with one latch");
  SmallVector<const MachineBasicBlock *, 4> Blocks;
  SmallPtrSet<const MachineBasicBlock *, 8> Seen;
  const auto *Header = Loop->getHeader();
  const auto *Latch = Loop->getLoopLatch();
  const auto *BB = Header;
  while (true) {
    if (!Loop->contains(BB) || !Seen.insert(BB).second)
      return createStringError("candidate body is not a linear path");
    if (BB != Header &&
        (BB->pred_size() != 1 || *BB->pred_begin() != Blocks.back()))
      return createStringError("candidate body has a side entry");
    Blocks.push_back(BB);
    if (BB == Latch)
      break;
    if (BB->succ_size() != 1)
      return createStringError(
          "candidate body has divergence or an early exit");
    BB = *BB->succ_begin();
  }
  if (Blocks.size() != Loop->getNumBlocks())
    return createStringError("candidate path does not cover the loop");
  for (auto *Pred : Header->predecessors())
    if (Loop->contains(Pred) && Pred != Latch)
      return createStringError("candidate has an additional backedge");
  for (const auto &MI : *Latch)
    if (MI.isBranch())
      for (const auto &MO : MI.operands())
        if (MO.isMBB() && MO.getMBB() == Header)
          return ObservedRegion{std::move(Blocks), &MI, uint64_t(Width)};
  return createStringError("candidate backedge is unproven");
}

Expected<ObservedRegion> findMarkedRegion(MachineFunction &MF) {
  const Function &F = MF.getFunction();
  auto Width = attr(F, "vplan.backend.region-width");
  uint64_t GUID;
  if (Width <= 0 || Width > UINT32_MAX ||
      F.getFnAttribute("vplan.backend.region-guid")
          .getValueAsString()
          .getAsInteger(10, GUID))
    return createStringError("invalid region probe identity/width");

  SmallPtrSet<const MachineBasicBlock *, 8> Marked;
  uint64_t Begins = 0, Ends = 0;
  for (const auto &MBB : MF)
    for (const auto &MI : MBB) {
      if (!MI.isPseudoProbe() || MI.getNumOperands() < 2 ||
          !MI.getOperand(0).isImm() ||
          uint64_t(MI.getOperand(0).getImm()) != GUID)
        continue;
      Marked.insert(&MBB);
      if (!MI.getOperand(1).isImm())
        return createStringError("invalid region probe index");
      if (MI.getOperand(1).getImm() == 1)
        ++Begins;
      else if (MI.getOperand(1).getImm() == 2)
        ++Ends;
      else
        return createStringError("invalid region probe index");
    }
  if (!Begins || Begins != Ends)
    return createStringError("region probes missing or incomplete");
  if (attr(F, "vplan.backend.region-count") <= 0 ||
      Begins != uint64_t(attr(F, "vplan.backend.region-count")))
    return createStringError("region probe count changed during codegen");
  if (Begins > UINT32_MAX / uint64_t(Width))
    return createStringError("region probe iteration width overflow");
  if (attr(F, "vplan.backend.region-isolated") != 1)
    return createStringError("region probe has incomplete IR scope");

  // Establish execution order from CFG edges, never from block layout or
  // marker instruction order. Markers are identities, not scheduling fences.
  SmallVector<const MachineBasicBlock *, 4> Path;
  SmallPtrSet<const MachineBasicBlock *, 8> Seen;
  if (MF.empty())
    return createStringError("region probe has no executable path");
  const MachineBasicBlock *BB = &MF.front();
  while (true) {
    if (!Seen.insert(BB).second || BB->succ_size() > 1 ||
        BB->pred_size() > (Path.empty() ? 0u : 1u))
      return createStringError(
          "region probe path has a branch, merge or cycle");
    Path.push_back(BB);
    if (BB->succ_empty())
      break;
    BB = *BB->succ_begin();
  }
  unsigned First = Path.size(), End = 0;
  for (unsigned I = 0; I < Path.size(); ++I)
    if (Marked.erase(Path[I])) {
      First = std::min(First, I);
      End = I + 1;
    }
  if (!Marked.empty() || First == Path.size())
    return createStringError("region probes are not on one executable path");
  SmallVector<const MachineBasicBlock *, 4> Blocks(Path.begin() + First,
                                                   Path.begin() + End);
  for (const auto &MBB : MF) {
    if (is_contained(Blocks, &MBB))
      continue;
    for (const auto &MI : MBB)
      if (isBodyInstruction(MI) && !MI.isUnconditionalBranch())
        return createStringError(
            "region probe has executable machine code outside its path");
  }
  return ObservedRegion{std::move(Blocks), nullptr, uint64_t(Width) * Begins,
                        Begins};
}

Expected<ObservedRegion>
findObservedRegion(MachineFunction &MF, VPlanBackendObservation &Observation) {
  auto Region = findLoopRegion(MF);
  if (Region)
    return Region;
  // Recover only a missing structural proof. Instruction/geometry errors from
  // collection below do not trigger another selection or backend execution.
  Observation.StructuralFailure = toString(Region.takeError());
  if (!MF.getFunction().hasFnAttribute("vplan.backend.region-guid"))
    return createStringError(Observation.StructuralFailure);
  auto Marked = findMarkedRegion(MF);
  if (!Marked) {
    Observation.MarkerFailure = toString(Marked.takeError());
    return createStringError("structural: " + Observation.StructuralFailure +
                             "; marker: " + Observation.MarkerFailure);
  }
  return Marked;
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
    return createStringError("invalid backend candidate identity");
  if (Scalar && (VF != 1 || IC != 1 || attr(F, "vplan.backend.scalable") != 0))
    return createStringError("invalid scalar baseline observation identity");
  Result.Candidate = ID.str();
  Result.VF = ElementCount::get(VF, attr(F, "vplan.backend.scalable") != 0);
  Result.IC = IC;
  Result.IsEpilogue = Role == "epilogue";
  Result.Kind = Scalar ? VPlanBackendCandidateKind::ScalarBaseline
                       : VPlanBackendCandidateKind::Vector;
  return Error::success();
}

static Error collectBody(MachineFunction &MF, VPlanBackendResult &Result,
                         bool MIR, bool Text) {
  VPlanBackendResult Identity;
  if (auto E = vplan::readCandidateIdentity(MF.getFunction(), Identity))
    return E;
  if (Identity.Candidate != Result.Candidate || Identity.VF != Result.VF ||
      Identity.IC != Result.IC || Identity.Kind != Result.Kind ||
      Identity.IsEpilogue != Result.IsEpilogue)
    return createStringError("backend observation identity mismatch");
  auto &Observation = MIR ? Result.MIR : Result.Spill;
  auto Region = findObservedRegion(MF, Observation);
  if (!Region)
    return Region.takeError();
  Observation.IterationWidth = Region->Width;
  Observation.IterationMapping = true;
  Observation.RegionProbeCount = Region->ProbeCount;
  if (MIR) {
    Observation.Stage = "post-frame-lowering";
    Observation.MIRBody.emplace();
  }
  // Markers identify the block, not instruction fences: scheduling may cluster
  // them. Both payloads traverse the same region and omit frame/return
  // overhead.
  for (const auto *BB : Region->Blocks)
    for (const auto &MI : *BB) {
      if (isBodyInstruction(MI)) {
        if (MIR)
          Observation.MIRBody->push_back(
              vplan::collectMIRInstruction(MI, Text));
        else if (auto E =
                     vplan::collectVectorSpillAccess(MI, Observation.Spills))
          return E;
      }
      if (&MI == Region->Last)
        break;
    }
  Observation.Status = VPlanBackendObservationStatus::Succeeded;
  return Error::success();
}
Expected<VPlanBackendResult>
llvm::vplan::collectVectorSpills(MachineFunction &MF) {
  VPlanBackendResult Result;
  if (auto E = readCandidateIdentity(MF.getFunction(), Result))
    return std::move(E);
  if (auto E = collectBody(MF, Result, false, false))
    return std::move(E);
  return Result;
}
Expected<VPlanBackendResult> llvm::vplan::collectMIRBody(MachineFunction &MF,
                                                         bool Text) {
  VPlanBackendResult Result;
  if (auto E = readCandidateIdentity(MF.getFunction(), Result))
    return std::move(E);
  if (auto E = collectBody(MF, Result, true, Text))
    return std::move(E);
  return Result;
}
void llvm::vplan::observeBody(MachineFunction &MF, VPlanBackendResult &Result,
                              bool MIR, bool Text) {
  auto &Slot = MIR ? Result.MIR : Result.Spill;
  if (Slot.Status != VPlanBackendObservationStatus::NotCollected) {
    Slot = VPlanBackendObservation();
    Slot.Status = VPlanBackendObservationStatus::Failed;
    Slot.Failure = "ambiguous backend candidate function";
  } else if (auto E = collectBody(MF, Result, MIR, Text)) {
    auto Structural = std::move(Slot.StructuralFailure);
    auto Marker = std::move(Slot.MarkerFailure);
    Slot = VPlanBackendObservation();
    Slot.StructuralFailure = std::move(Structural);
    Slot.MarkerFailure = std::move(Marker);
    Slot.Status = VPlanBackendObservationStatus::Failed;
    Slot.Failure = toString(std::move(E));
  }
  Slot.Stage = MIR ? "post-frame-lowering" : "post-stack-slot-coloring";
}
char RISCVVPlanSpill::ID = 0;
RISCVVPlanSpill::RISCVVPlanSpill(VPlanBackendResult &Sink,
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
    vplan::observeBody(MF, Sink, false, false);
  }
  if (Timer)
    Timer->mark("spill_collection");
  return false;
}
