// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVInstrInfo.h"
#include "RISCVSubtarget.h"
#include "RISCVTargetMachine.h"
#include "RISCVVPlanMIR.h"
#include "RISCVVPlanSpill.h"
#include "llvm/Analysis/LoopBackedgeAnalysis.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/CodeGen/MachineFrameInfo.h"
#include "llvm/CodeGen/MachineModuleInfo.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Module.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Target/TargetLoweringObjectFile.h"
#include "gtest/gtest.h"
using namespace llvm;

namespace {
class RISCVBackendObservation : public testing::Test {
protected:
  LLVMContext C;
  std::unique_ptr<RISCVTargetMachine> TM;
  std::unique_ptr<Module> M;
  std::unique_ptr<ScopedLoopBackedgeTracking> Tracking;
  uint64_t LoopID;
  BasicBlock *Entry, *Body;
  std::unique_ptr<MachineModuleInfo> MMI;
  std::unique_ptr<MachineFunction> MF;
  Function *F;
  const RISCVInstrInfo *TII;
  int SpillFI, OrdinaryFI;
  void SetUp() override {
    LLVMInitializeRISCVTargetInfo();
    LLVMInitializeRISCVTarget();
    LLVMInitializeRISCVTargetMC();
    Triple TT("riscv64-unknown-elf");
    std::string Error;
    auto *T = TargetRegistry::lookupTarget(TT, Error);
    ASSERT_TRUE(T);
    TM.reset(static_cast<RISCVTargetMachine *>(T->createTargetMachine(
        TT, "generic-rv64", "+v", TargetOptions(), std::nullopt)));
    M = std::make_unique<Module>("observation", C);
    M->setDataLayout(TM->createDataLayout());
    F = Function::Create(FunctionType::get(Type::getVoidTy(C), false),
                         GlobalValue::ExternalLinkage, "body", *M);
    F->addFnAttr("vplan.backend.candidate", "body");
    F->addFnAttr("vplan.backend.vf", "4");
    F->addFnAttr("vplan.backend.ic", "1");
    F->addFnAttr("vplan.backend.scalable", "0");
    F->addFnAttr("vplan.backend.role", "main");
    Entry = BasicBlock::Create(C, "entry", F);
    Body = BasicBlock::Create(C, "body", F);
    UncondBrInst::Create(Body, Entry);
    UncondBrInst::Create(Body, Body);
    Tracking = std::make_unique<ScopedLoopBackedgeTracking>(*F);
    auto &LoopTracking = *LoopBackedgeTracking::get(F);
    LoopTracking.Identity = "body";
    LoopTracking.Role = "main";
    LoopTracking.MaterializedWidth = 4;
    DominatorTree DT(*F);
    LoopInfo LI(DT);
    LoopID = registerTrackedLoop(LoopTracking, **LI.begin(), 4);
    MMI = std::make_unique<MachineModuleInfo>(TM.get());
    auto *ST = TM->getSubtargetImpl(*F);
    MF = std::make_unique<MachineFunction>(*F, *TM, *ST, MMI->getContext(), 0);
    TII = ST->getInstrInfo();
    SpillFI = MF->getFrameInfo().CreateSpillStackObject(4096, Align(16));
    OrdinaryFI = MF->getFrameInfo().CreateStackObject(8, Align(8), false);
  }
  MachineBasicBlock *block(const BasicBlock *IR = nullptr) {
    auto *B = MF->CreateMachineBasicBlock(IR);
    MF->push_back(B);
    return B;
  }
  void bindBackedge(MachineBasicBlock *Latch, MachineBasicBlock *Header) {
    MF->getLoopBackedgeTracking()->bind({Latch, Header}, LoopID);
  }
  MachineInstr *store(MachineBasicBlock *B, int FI, bool Vector = true) {
    auto MI = BuildMI(*B, B->end(), DebugLoc(),
                      TII->get(Vector ? RISCV::VS1R_V : RISCV::SW))
                  .addReg(Vector ? RISCV::V8 : RISCV::X10)
                  .addFrameIndex(FI);
    if (!Vector)
      MI.addImm(0);
    return MI.addMemOperand(MF->getMachineMemOperand(
        MachinePointerInfo::getFixedStack(*MF, FI), MachineMemOperand::MOStore,
        Vector ? TypeSize::getScalable(8) : TypeSize::getFixed(4), Align(8)));
  }
};
} // namespace

TEST_F(RISCVBackendObservation, BranchBodyAndIndependentStages) {
  auto *Setup = block(Entry), *Header = block(Body);
  auto *Left = block(Body), *Right = block(Body), *Join = block(Body);
  Setup->addSuccessor(Header);
  Header->addSuccessor(Left);
  Header->addSuccessor(Right);
  Left->addSuccessor(Join);
  Right->addSuccessor(Join);
  Join->addSuccessor(Header);
  bindBackedge(Join, Header);
  // Executable code outside the loop needs no origin or target identity.
  auto *Outside = block();
  store(Outside, SpillFI);
  store(Setup, SpillFI); // Non-target setup is excluded.
  store(Left, SpillFI);
  store(Right, SpillFI);
  store(Join, SpillFI, false);
  store(Join, OrdinaryFI, false);
  MF->getLoopBackedgeTracking()->CaptureFailures = true;
  VPlanBackendResult Result;
  Result.CaptureFailures = true;
  ASSERT_FALSE(bool(vplan::readCandidateIdentity(*F, Result)));
  vplan::observeBody(*MF, Result, false, false);
  ASSERT_TRUE(Result.Spill.succeeded());
  ASSERT_EQ(Result.Spill.Loops.size(), 1u);
  EXPECT_EQ(Result.Spill.Loops.front().Spills.size(), 2u);
  EXPECT_EQ(Result.Spill.Loops.front().IterationWidth, 4u);
  vplan::observeBody(*MF, Result, true, false);
  ASSERT_TRUE(Result.MIR.succeeded());
  ASSERT_EQ(Result.MIR.Loops.size(), 1u);
  ASSERT_TRUE(Result.MIR.Loops.front().MIRBody);
  EXPECT_EQ(llvm::count_if(*Result.MIR.Loops.front().MIRBody,
                           [](const auto &I) { return I.Spill; }),
            3);

  // Lose the target boundary only after the spill snapshot was collected.
  // The later MIR failure must preserve the independently owned spill facts.
  Join->removeSuccessor(Header);
  Result.MIR = VPlanBackendObservation();
  vplan::observeBody(*MF, Result, true, false);
  EXPECT_TRUE(Result.Spill.succeeded());
  EXPECT_EQ(Result.Spill.Loops.front().Spills.size(), 2u);
  EXPECT_FALSE(Result.MIR.succeeded());
  ASSERT_TRUE(Result.MIR.Failure);
  EXPECT_EQ(Result.MIR.Failure->Group, VPlanBackendFailureGroup::Tracking);
  ASSERT_EQ(Result.MIR.Exclusions.size(), 1u);
  EXPECT_EQ(Result.MIR.Exclusions.front().TrackingID, LoopID);
  EXPECT_FALSE(Result.MIR.Exclusions.front().ObservationID);
  EXPECT_EQ(Result.MIR.Exclusions.front().Detail, "no observable native loop");
  EXPECT_TRUE(llvm::all_of(Result.MIR.Loops, [](const auto &Loop) {
    return Loop.Spills.empty() && !Loop.MIRBody;
  }));
  MF.reset();
  EXPECT_EQ(Result.Candidate, "body");
  EXPECT_EQ(Result.Spill.Loops.front().Spills.size(), 2u);
}

TEST_F(RISCVBackendObservation, MovedAndClonedCodeUsesCurrentLocation) {
  auto *Outside = block(Entry), *Inside = block(Body);
  Outside->addSuccessor(Inside);
  Inside->addSuccessor(Inside);
  bindBackedge(Inside, Inside);
  auto *MI = store(Inside, SpillFI);
  Outside->push_back(MF->CloneMachineInstr(MI));
  MI->removeFromParent();
  Outside->push_back(MI);
  auto Hoisted = vplan::collectVectorSpills(*MF);
  ASSERT_TRUE(bool(Hoisted)) << toString(Hoisted.takeError());
  ASSERT_TRUE(Hoisted->Spill.succeeded());
  ASSERT_EQ(Hoisted->Spill.Loops.size(), 1u);
  EXPECT_TRUE(Hoisted->Spill.Loops.front().Spills.empty());
  EXPECT_EQ(Hoisted->Spill.Loops.front().IterationWidth, 4u);

  // Sinking one access into the loop changes the current body cost, regardless
  // of the instruction's creation or clone location.
  MI->removeFromParent();
  Inside->push_back(MI);
  auto Sunk = vplan::collectVectorSpills(*MF);
  ASSERT_TRUE(bool(Sunk)) << toString(Sunk.takeError());
  ASSERT_EQ(Sunk->Spill.Loops.size(), 1u);
  EXPECT_EQ(Sunk->Spill.Loops.front().Spills.size(), 1u);
}

TEST_F(RISCVBackendObservation, MachineObservationOutlivesIRTracking) {
  auto *Setup = block(Entry), *Loop = block(Body);
  Setup->addSuccessor(Loop);
  Loop->addSuccessor(Loop);
  bindBackedge(Loop, Loop);
  store(Loop, SpillFI);
  Tracking.reset();
  auto Result = vplan::collectVectorSpills(*MF);
  ASSERT_TRUE(bool(Result)) << toString(Result.takeError());
  ASSERT_TRUE(Result->Spill.succeeded());
  MF.reset();
  ASSERT_EQ(Result->Spill.Loops.size(), 1u);
  EXPECT_EQ(Result->Spill.Loops.front().IterationWidth, 4u);
  EXPECT_EQ(Result->Spill.Loops.front().Spills.size(), 1u);
}

TEST_F(RISCVBackendObservation, SegmentAccessesFollowPhysicalEncoding) {
  auto *B = block();
  auto *TRI = MF->getSubtarget<RISCVSubtarget>().getRegisterInfo();
  // One even and one odd encoding suffice to exercise the 2+1 / 1+2 split.
  for (unsigned Parity : {0u, 1u}) {
    MCPhysReg Reg = *llvm::find_if(RISCV::VRN3M1RegClass, [&](MCPhysReg R) {
      return TRI->getEncodingValue(R) % 2 == Parity;
    });
    auto *MI =
        BuildMI(*B, B->end(), DebugLoc(), TII->get(RISCV::PseudoVRELOAD3_M1))
            .addReg(Reg, RegState::Define)
            .addFrameIndex(SpillFI)
            .addMemOperand(MF->getMachineMemOperand(
                MachinePointerInfo::getFixedStack(*MF, SpillFI),
                MachineMemOperand::MOLoad, TypeSize::getScalable(24),
                Align(16)))
            .getInstr();
    std::vector<VPlanVectorSpillAccess> Accesses;
    auto E = vplan::collectVectorSpillAccess(*MI, Accesses);
    ASSERT_FALSE(bool(E)) << toString(std::move(E));
    ASSERT_EQ(Accesses.size(), 2u);
    EXPECT_EQ(Accesses[0].RegisterGroup, Parity ? 1u : 2u);
    EXPECT_EQ(Accesses[1].RegisterGroup, Parity ? 2u : 1u);
    EXPECT_EQ(Accesses[0].MinBytes + Accesses[1].MinBytes, 24u);
    EXPECT_TRUE(Accesses[0].IsLoad && Accesses[0].FromSegment);
  }
}

TEST_F(RISCVBackendObservation, FailedLoopLeavesIndependentZeroObservation) {
  auto *Setup = block(Entry), *Bad = block(Body), *Good = block(Body);
  Setup->addSuccessor(Bad);
  Bad->addSuccessor(Bad);
  Bad->addSuccessor(Good);
  Good->addSuccessor(Good);
  bindBackedge(Bad, Bad);
  bindBackedge(Good, Good);
  // A mismatched vector data group makes the complete first loop unusable.
  auto *MI = store(Bad, SpillFI);
  MI->getOperand(0).setReg(RISCV::V8M2);
  VPlanBackendResult Owned;
  Owned.CaptureFailures = true;
  ASSERT_FALSE(bool(vplan::readCandidateIdentity(*F, Owned)));
  vplan::observeBody(*MF, Owned, false, false);
  std::optional<VPlanBackendResult> Result(std::move(Owned));
  ASSERT_TRUE(bool(Result));
  ASSERT_TRUE(Result->Spill.succeeded());
  ASSERT_EQ(Result->Spill.Exclusions.size(), 1u);
  const auto &Failure = Result->Spill.Exclusions.front();
  EXPECT_EQ(Failure.Group, VPlanBackendFailureGroup::Collection);
  EXPECT_EQ(Failure.Candidate, "body");
  EXPECT_EQ(Failure.Stage, "post-stack-slot-coloring");
  EXPECT_EQ(Failure.TrackingID, LoopID);
  EXPECT_EQ(Failure.ObservationID, 1u);
  EXPECT_EQ(Failure.Detail, "vector spill opcode/register group mismatch");
  ASSERT_EQ(Result->Spill.Loops.size(), 1u);
  EXPECT_EQ(Result->Spill.Loops.front().SelectedBlockCount, 1u);
  EXPECT_TRUE(Result->Spill.Loops.front().Spills.empty());
  EXPECT_EQ(Result->Spill.Loops.front().TrackingID, LoopID);
}
