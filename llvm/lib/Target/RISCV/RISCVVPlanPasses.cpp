//===- RISCVVPlanPasses.cpp - Analytics and cost pass adapters
//--------------===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCV.h"
#include "RISCVVPlanAnalytics.h"
#include "RISCVVPlanCost.h"
#include "llvm/CodeGen/MachineFunction.h"
#include "llvm/IR/Function.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/MemoryBuffer.h"
using namespace llvm;
static cl::opt<std::string>
    AnalyticsOutput("vplan-analytics-output", cl::Hidden,
                    cl::desc("Write cost-independent machine analytics"));
static cl::opt<std::string>
    CostOutput("vplan-cost-output", cl::Hidden,
               cl::desc("Write backend candidate cost"));
static cl::opt<std::string>
    ScalarInput("vplan-scalar-analytics-input", cl::Hidden,
                cl::desc("Read the same loop's scalar analytics"));
bool llvm::vplanAnalyticsEnabled() {
  return !AnalyticsOutput.empty() || !CostOutput.empty();
}
bool llvm::vplanCostEnabled() { return !CostOutput.empty(); }
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
  Result = vplan::collectAnalytics(MF);
  if (!AnalyticsOutput.empty())
    writeVPlanRAJSON(AnalyticsOutput, vplan::toJSON(Result));
  return false;
}
bool RISCVVPlanAnalytics::doFinalization(Module &) {
  if (!Seen)
    reportFatalUsageError("VPlan analytics did not see the probe function");
  return false;
}
namespace {
class RISCVVPlanCost : public MachineFunctionPass {
public:
  static char ID;
  RISCVVPlanCost() : MachineFunctionPass(ID) {
    initializeRISCVVPlanCostPass(*PassRegistry::getPassRegistry());
  }
  StringRef getPassName() const override { return "RISC-V VPlan backend cost"; }
  void getAnalysisUsage(AnalysisUsage &AU) const override {
    AU.addRequired<RISCVVPlanAnalytics>();
    AU.setPreservesAll();
    MachineFunctionPass::getAnalysisUsage(AU);
  }
  bool runOnMachineFunction(MachineFunction &MF) override {
    if (!MF.getFunction().hasFnAttribute("vplan.ra.candidate"))
      return false;
    const auto &A = getAnalysis<RISCVVPlanAnalytics>().getResult();
    vplan::Analytics Scalar;
    const vplan::Analytics *Reference = &A;
    if (A.VF != 1 || A.ScalableVF) {
      if (ScalarInput.empty())
        reportFatalUsageError("vector cost requires scalar analytics");
      auto Parsed = readVPlanRAJSON(ScalarInput);
      if (!Parsed)
        reportFatalUsageError(Twine(toString(Parsed.takeError())));
      json::Path::Root Root;
      if (!vplan::fromJSON(*Parsed, Scalar, Root))
        reportFatalUsageError("malformed scalar analytics");
      Reference = &Scalar;
    }
    auto C = vplan::scoreCandidate(A, *Reference);
    if (!C) {
      std::string Reason = toString(C.takeError());
      if (!CostOutput.empty())
        writeVPlanRAJSON(CostOutput, json::Object{{"version", 2},
                                                  {"run_id", A.RunID},
                                                  {"id", A.Candidate},
                                                  {"supported", false},
                                                  {"reason", Reason}});
      reportFatalUsageError(Twine("backend cost unavailable: ") + Reason);
    }
    if (!CostOutput.empty())
      writeVPlanRAJSON(CostOutput,
                       json::Object{{"version", 2},
                                    {"run_id", A.RunID},
                                    {"id", A.Candidate},
                                    {"supported", true},
                                    {"cost", serializeBackendCost(*C)}});
    return false;
  }
};
} // namespace
char RISCVVPlanCost::ID = 0;
INITIALIZE_PASS_BEGIN(RISCVVPlanCost, "riscv-vplan-cost",
                      "RISC-V VPlan backend cost", false, true)
INITIALIZE_PASS_DEPENDENCY(RISCVVPlanAnalytics)
INITIALIZE_PASS_END(RISCVVPlanCost, "riscv-vplan-cost",
                    "RISC-V VPlan backend cost", false, true)
FunctionPass *llvm::createRISCVVPlanAnalyticsPass() {
  return new RISCVVPlanAnalytics();
}
FunctionPass *llvm::createRISCVVPlanCostPass() { return new RISCVVPlanCost(); }
