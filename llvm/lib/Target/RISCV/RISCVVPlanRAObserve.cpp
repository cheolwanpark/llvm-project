//===- RISCVVPlanRAObserve.cpp - Fixed post-RA observation boundary --------===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCV.h"
#include "RISCVVPlanRAFeatures.h"
#include "llvm/CodeGen/MachineFunction.h"
#include "llvm/CodeGen/MachineFunctionPass.h"
#include "llvm/CodeGen/MachineRegisterInfo.h"
#include "llvm/IR/Function.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Transforms/Vectorize/VPlanRA.h"

using namespace llvm;
namespace {
class RISCVVPlanRAObserve : public MachineFunctionPass {
  json::Object Observation;
public:
  static char ID;
  RISCVVPlanRAObserve() : MachineFunctionPass(ID) {
    initializeRISCVVPlanRAObservePass(*PassRegistry::getPassRegistry());
  }
  StringRef getPassName() const override { return "RISC-V VPlan RA observation"; }
  void getAnalysisUsage(AnalysisUsage &AU) const override {
    AU.setPreservesAll();
    MachineFunctionPass::getAnalysisUsage(AU);
  }
  bool runOnMachineFunction(MachineFunction &MF) override {
    auto Attr = MF.getFunction().getFnAttribute("vplan.ra.candidate");
    if (!Attr.isValid())
      return false;
    if (!Observation.empty() || Attr.getValueAsString() != getVPlanRAProbe())
      reportFatalUsageError("ambiguous VPlan RA probe function");
    // Checking operands, rather than the vreg table, also accepts unused vregs
    // left in the table by the allocator. No live virtual operand may remain.
    for (const auto &MBB : MF)
      for (const auto &MI : MBB)
        if (!MI.isDebugInstr())
          for (const auto &MO : MI.operands())
            if (MO.isReg() && MO.getReg().isVirtual())
              reportFatalUsageError("VPlan observation precedes complete RA");
    Observation = json::Object{
        {"version", 1}, {"run_id", getVPlanRARunID().str()},
        {"id", getVPlanRAProbe().str()}, {"function", MF.getName().str()},
        {"stage", "post-ra"}, {"features", collectRISCVVPlanRAFeatures(MF)}};
    return false;
  }
  bool doFinalization(Module &) override {
    if (Observation.empty())
      reportFatalUsageError("VPlan RA observation did not see the probe function");
    writeVPlanRAJSON(getVPlanRAFeaturesOutput(), std::move(Observation));
    return false;
  }
};
}
char RISCVVPlanRAObserve::ID = 0;
INITIALIZE_PASS(RISCVVPlanRAObserve, "riscv-vplan-ra-observe",
                "RISC-V VPlan RA observation", false, true)
FunctionPass *llvm::createRISCVVPlanRAObservePass() {
  return new RISCVVPlanRAObserve();
}
