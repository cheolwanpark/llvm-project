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
    F->addFnAttr("vplan.backend.width", "4");
    F->addFnAttr("vplan.backend.iteration-mapping", "1");
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
  void marker(MachineBasicBlock *B, unsigned Index) {
    BuildMI(*B, B->end(), DebugLoc(), TII->get(TargetOpcode::PSEUDO_PROBE))
        .addImm(123).addImm(Index).addImm(0).addImm(0);
  }
  void region() {
    F->addFnAttr("vplan.backend.region-guid", "123");
    F->addFnAttr("vplan.backend.region-width", "4");
    F->addFnAttr("vplan.backend.region-count", "2");
    F->addFnAttr("vplan.backend.region-isolated", "1");
  }
};
}

TEST_F(RISCVBackendObservation, StructuralChainHasStageSpecificPayloads) {
  auto *Entry = BasicBlock::Create(C, "entry", F);
  auto *Body = BasicBlock::Create(C, "loop", F);
  UncondBrInst::Create(Body, Entry);
  auto *Backedge = UncondBrInst::Create(Body, Body);
  auto *Tag = MDNode::get(C, {MDString::get(C, "llvm.loop.vplan.backend.candidate"),
                             MDString::get(C, "body")});
  auto *ID = MDNode::getDistinct(C, {nullptr, Tag});
  ID->replaceOperandWith(0, ID);
  Backedge->setMetadata(LLVMContext::MD_loop, ID);
  auto *Setup = block(Entry), *Header = block(Body), *Latch = block(Body);
  Setup->addSuccessor(Header);
  Header->addSuccessor(Latch);
  Latch->addSuccessor(Header);
  store(Setup, SpillFI); // Setup is not part of the repeated body.
  store(Header, SpillFI);
  BuildMI(*Header, Header->end(), DebugLoc(), TII->get(RISCV::PseudoBR)).addMBB(Latch);
  store(Latch, SpillFI, false);
  store(Latch, OrdinaryFI, false);
  BuildMI(*Latch, Latch->end(), DebugLoc(), TII->get(RISCV::PseudoBR)).addMBB(Header);
  auto Spill = vplan::collectVectorSpills(*MF);
  auto MIR = vplan::collectMIRBody(*MF, false);
  ASSERT_TRUE(bool(Spill)) << toString(Spill.takeError());
  ASSERT_TRUE(bool(MIR)) << toString(MIR.takeError());
  ASSERT_EQ(Spill->Spill.Spills.size(), 1u);
  EXPECT_EQ(Spill->Spill.Spills[0].MinBytes, 8u);
  EXPECT_EQ(Spill->Spill.IterationWidth, MIR->MIR.IterationWidth);
  ASSERT_TRUE(MIR->MIR.MIRBody);
  EXPECT_EQ(llvm::count_if(*MIR->MIR.MIRBody, [](const auto &I) { return I.Spill; }), 2);
  // Each stage owns its slot even when geometry fails at the other stage.
  for (bool FailMIR : {false, true}) {
    VPlanBackendResult Slots;
    ASSERT_FALSE(bool(vplan::readCandidateIdentity(*F, Slots)));
    F->addFnAttr("vplan.backend.iteration-mapping", FailMIR ? "1" : "0");
    vplan::observeBody(*MF, Slots, false, false);
    F->addFnAttr("vplan.backend.iteration-mapping", FailMIR ? "0" : "1");
    vplan::observeBody(*MF, Slots, true, false);
    EXPECT_EQ(Slots.Spill.succeeded(), FailMIR);
    EXPECT_EQ(Slots.MIR.succeeded(), !FailMIR);
    EXPECT_EQ((FailMIR ? Slots.MIR : Slots.Spill).Status,
              VPlanBackendObservationStatus::Failed);
  }
  F->addFnAttr("vplan.backend.iteration-mapping", "1");
  // An exit before the latch cannot be represented by one repeated path.
  auto *Exit = block();
  Header->addSuccessor(Exit);
  auto EarlyExit = vplan::collectVectorSpills(*MF);
  EXPECT_FALSE(bool(EarlyExit));
  consumeError(EarlyExit.takeError());
  Header->removeSuccessor(Exit);
  Setup->addSuccessor(Latch);
  auto Bad = vplan::collectVectorSpills(*MF);
  EXPECT_FALSE(bool(Bad));
  consumeError(Bad.takeError());
  Setup->removeSuccessor(Latch);
  // Native cloning can leave two loops carrying the same candidate identity.
  // Neither observer may silently select the first copy.
  auto *Copy = block(Body);
  Setup->addSuccessor(Copy);
  Copy->addSuccessor(Copy);
  store(Copy, SpillFI);
  BuildMI(*Copy, Copy->end(), DebugLoc(), TII->get(RISCV::PseudoBR)).addMBB(Copy);
  auto Duplicated = vplan::collectMIRBody(*MF, false);
  EXPECT_FALSE(bool(Duplicated));
  consumeError(Duplicated.takeError());
  MF.reset();
  EXPECT_EQ(Spill->Candidate, "body"); // Owned facts outlive MachineFunction.
}

// These mutations cannot be reliably produced by native optimization. Exercise
// the real collectors on machine CFGs instead of mocking their scope proof.
TEST_F(RISCVBackendObservation, MarkerCompletenessAndNominalWidth) {
  region();
  auto *A = block(), *B = block();
  A->addSuccessor(B);
  marker(A, 1);
  marker(A, 1); // Scheduling need not interleave begin/end markers.
  store(A, SpillFI);
  marker(B, 2);
  marker(B, 2);
  store(B, SpillFI);
  auto Result = vplan::collectVectorSpills(*MF);
  ASSERT_TRUE(bool(Result)) << toString(Result.takeError());
  EXPECT_EQ(Result->Spill.IterationWidth, 8u);
  EXPECT_EQ(Result->Spill.Spills.size(), 2u);
  EXPECT_FALSE(Result->Spill.StructuralFailure.empty());
  auto rejects = [&] {
    auto Bad = vplan::collectVectorSpills(*MF);
    EXPECT_FALSE(bool(Bad));
    consumeError(Bad.takeError());
  };
  F->addFnAttr("vplan.backend.region-count", "1");
  rejects();
  F->addFnAttr("vplan.backend.region-count", "2");
  F->addFnAttr("vplan.backend.region-width", "4294967295");
  rejects();
  F->addFnAttr("vplan.backend.region-width", "4");
  B->addSuccessor(A);
  rejects();
  B->removeSuccessor(A);
  auto *Outside = block();
  B->addSuccessor(Outside);
  store(Outside, SpillFI);
  rejects();
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
