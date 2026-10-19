//===- RISCVVPlanPasses.cpp - Analytics and cost pass adapters
//--------------===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCV.h"
#include "RISCVVPlanAnalytics.h"
#include "llvm/CodeGen/MachineFunction.h"
#include "llvm/IR/Function.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Transforms/Vectorize/VPlanRA.h"
using namespace llvm;
static cl::opt<std::string>
    AnalyticsOutput("vplan-analytics-output", cl::Hidden,
                    cl::desc("Write cost-independent machine analytics"));
bool llvm::vplanAnalyticsEnabled() { return !AnalyticsOutput.empty(); }
char RISCVVPlanAnalytics::ID = 0;
INITIALIZE_PASS(RISCVVPlanAnalytics, "riscv-vplan-analytics",
                "RISC-V VPlan analytics", false, true)
RISCVVPlanAnalytics::RISCVVPlanAnalytics() : MachineFunctionPass(ID) {
  initializeRISCVVPlanAnalyticsPass(*PassRegistry::getPassRegistry());
}
void RISCVVPlanAnalytics::getAnalysisUsage(AnalysisUsage &AU) const {
  AU.setPreservesAll();
  MachineFunctionPass::getAnalysisUsage(AU);
}
bool RISCVVPlanAnalytics::runOnMachineFunction(MachineFunction &MF) {
  auto Attr = MF.getFunction().getFnAttribute("vplan.ra.candidate");
  if (!Attr.isValid())
    return false;
  if (Seen || Attr.getValueAsString() != getVPlanRAProbe())
    reportFatalUsageError("ambiguous VPlan analytics probe function");
  Seen = true;
  auto Result = vplan::collectAnalytics(MF);
  if (!AnalyticsOutput.empty())
    writeVPlanRAJSON(AnalyticsOutput, vplan::toJSON(Result));
  return false;
}
bool RISCVVPlanAnalytics::doFinalization(Module &) {
  if (!Seen)
    reportFatalUsageError("VPlan analytics did not see the probe function");
  return false;
}
FunctionPass *llvm::createRISCVVPlanAnalyticsPass() {
  return new RISCVVPlanAnalytics();
}
