//===- RISCVVPlanPasses.cpp - Passive MIR observation pass -----------------===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCV.h"
#include "RISCVVPlanAnalytics.h"
#include "llvm/CodeGen/MachineFunction.h"
#include "llvm/IR/Function.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Transforms/Vectorize/VPlanRA.h"
using namespace llvm;

// The file observer can borrow StringRefs because it prints immediately. An
// in-memory result outlives the MachineFunction, clone and TargetMachine, so
// recursively take ownership of both keys and string values at the boundary.
static json::Value ownObservation(json::Value V) {
  if (auto S = V.getAsString())
    return S->str();
  if (auto *A = V.getAsArray())
    for (auto &E : *A)
      E = ownObservation(std::move(E));
  if (auto *O = V.getAsObject()) {
    json::Object Owned;
    for (auto &[K, E] : *O)
      Owned[K.str()] = ownObservation(std::move(E));
    return Owned;
  }
  return V;
}

static cl::opt<std::string>
    AnalyticsOutput("vplan-analytics-output", cl::Hidden,
                    cl::desc("Write cost-independent machine analytics"));
bool llvm::vplanAnalyticsEnabled() { return !AnalyticsOutput.empty(); }
char RISCVVPlanAnalytics::ID = 0;
INITIALIZE_PASS(RISCVVPlanAnalytics, "riscv-vplan-analytics",
                "RISC-V VPlan analytics", false, true)
RISCVVPlanAnalytics::RISCVVPlanAnalytics(std::optional<json::Object> *Sink)
    : MachineFunctionPass(ID), Sink(Sink) {
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
  if (Seen || (!Sink && Attr.getValueAsString() != getVPlanRAProbe()))
    reportFatalUsageError("ambiguous VPlan analytics probe function");
  Seen = true;
  auto Result = vplan::collectAnalytics(MF);
  if (Sink) {
    auto Owned = ownObservation(std::move(Result));
    *Sink = std::move(*Owned.getAsObject());
    return false;
  }
  if (!AnalyticsOutput.empty())
    writeVPlanRAJSON(AnalyticsOutput, json::Value(std::move(Result)));
  return false;
}
bool RISCVVPlanAnalytics::doFinalization(Module &) {
  if (!Seen && !Sink)
    reportFatalUsageError("VPlan analytics did not see the probe function");
  return false;
}
FunctionPass *llvm::createRISCVVPlanAnalyticsPass() {
  return new RISCVVPlanAnalytics();
}
