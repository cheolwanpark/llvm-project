// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVInstrInfo.h"
#include "RISCVSubtarget.h"
#include "RISCVTargetMachine.h"
#include "RISCVVPlanMIR.h"
#include "RISCVVPlanSpill.h"
#include "llvm/CodeGen/MachineFrameInfo.h"
#include "llvm/CodeGen/MachineModuleInfo.h"
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
  std::unique_ptr<ScopedRelatedBlockTracking> Tracking;
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
    Tracking = std::make_unique<ScopedRelatedBlockTracking>(*F);
    RelatedBlockTracking::get(F)->seed({Body}, "body", "main", 4, false);
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
  MachineInstr *store(MachineBasicBlock *B, int FI, bool Vector = true) {
    auto MI = BuildMI(*B, B->end(), DebugLoc(), TII->get(Vector ? RISCV::VS1R_V : RISCV::SW))
                  .addReg(Vector ? RISCV::V8 : RISCV::X10).addFrameIndex(FI);
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
  store(Setup, SpillFI); // Non-target setup is excluded.
  store(Left, SpillFI);
  store(Right, SpillFI);
  store(Join, SpillFI, false);
  store(Join, OrdinaryFI, false);
  VPlanBackendResult Result;
  ASSERT_FALSE(bool(vplan::readCandidateIdentity(*F, Result)));
  vplan::observeBody(*MF, Result, false, false);
  ASSERT_TRUE(Result.Spill.succeeded()) << Result.Spill.Failure;
  EXPECT_EQ(Result.Spill.Spills.size(), 2u); // Both alternatives, once each.
  EXPECT_EQ(Result.Spill.IterationWidth, 4u);
  vplan::observeBody(*MF, Result, true, false);
  ASSERT_TRUE(Result.MIR.succeeded()) << Result.MIR.Failure;
  EXPECT_EQ(llvm::count_if(*Result.MIR.MIRBody,
                           [](const auto &I) { return I.Spill; }),
            3);

  // A later lowering introduces unresolved executable ancestry. Re-observe
  // only the later stage: the already owned spill facts must survive failure.
  auto *Unknown = block();
  store(Unknown, SpillFI);
  Result.MIR = VPlanBackendObservation();
  vplan::observeBody(*MF, Result, true, false);
  EXPECT_TRUE(Result.Spill.succeeded());
  EXPECT_EQ(Result.Spill.Spills.size(), 2u);
  EXPECT_FALSE(Result.MIR.succeeded());
  EXPECT_FALSE(Result.MIR.MappingFailure.empty());
  EXPECT_FALSE(Result.MIR.MIRBody);
  MF.reset();
  EXPECT_EQ(Result.Candidate, "body");
}

TEST_F(RISCVBackendObservation, MovedAndClonedCodeRetainsBodyMembership) {
  auto *Source = block(Body), *Destination = block(Entry);
  auto *MI = store(Source, SpillFI);
  // Native tail duplication uses clone + insert, while sinking can use a
  // remove + insert. Both must carry source ancestry through detached code.
  Destination->push_back(MF->CloneMachineInstr(MI));
  MI->removeFromParent();
  Destination->push_back(MI);
  auto Result = vplan::collectVectorSpills(*MF);
  ASSERT_TRUE(bool(Result)) << toString(Result.takeError());
  EXPECT_EQ(Result->Spill.Spills.size(), 2u);
  EXPECT_EQ(Result->Spill.IterationWidth, 4u);
  EXPECT_EQ(Result->Spill.MixedOriginBlockCount, 1u);
}

TEST_F(RISCVBackendObservation, ResetEndsMachineTrackingLifetime) {
  auto *B = block(Body);
  Tracking.reset();
  EXPECT_EQ(B->getRelatedBlock().State, RelatedBlockState::Known);

  MF->reset();
  EXPECT_EQ(block(Body)->getRelatedBlock().State, RelatedBlockState::Disabled);
}

TEST_F(RISCVBackendObservation, SegmentAccessesFollowPhysicalEncoding) {
  auto *B = block();
  auto *TRI = MF->getSubtarget<RISCVSubtarget>().getRegisterInfo();
  // One even and one odd encoding suffice to exercise the 2+1 / 1+2 split.
  for (unsigned Parity : {0u, 1u}) {
    MCPhysReg Reg = *llvm::find_if(RISCV::VRN3M1RegClass, [&](MCPhysReg R) {
      return TRI->getEncodingValue(R) % 2 == Parity;
    });
    auto *MI = BuildMI(*B, B->end(), DebugLoc(), TII->get(RISCV::PseudoVRELOAD3_M1))
                   .addReg(Reg, RegState::Define).addFrameIndex(SpillFI)
                   .addMemOperand(MF->getMachineMemOperand(
                       MachinePointerInfo::getFixedStack(*MF, SpillFI),
                       MachineMemOperand::MOLoad, TypeSize::getScalable(24), Align(16)))
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
