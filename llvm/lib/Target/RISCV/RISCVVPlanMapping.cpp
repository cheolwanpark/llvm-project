// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVVPlanMapping.h"
#include "llvm/Analysis/LoopBackedgeAnalysis.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/CodeGen/MachineDominators.h"
#include "llvm/CodeGen/MachineFunction.h"
#include "llvm/CodeGen/MachineLoopInfo.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Function.h"
#include "llvm/Pass.h"
#include "llvm/PassInfo.h"
#include "llvm/PassRegistry.h"
#include "llvm/Support/Debug.h"
#define DEBUG_TYPE "vplan-backedge-loops"
using namespace llvm;
Expected<SmallVector<TrackedLoopBody<MachineBasicBlock>>>
llvm::vplan::mapProbeBody(MachineFunction &MF, VPlanBackendObservation &O) {
  auto *T = MF.getLoopBackedgeTracking();
  auto FailMapping = [&](StringRef Reason)
      -> Expected<SmallVector<TrackedLoopBody<MachineBasicBlock>>> {
    O.MappingFailure = Reason.str();
    return createStringError(Reason);
  };
  if (!T)
    return FailMapping("backedge-tracking-disabled");
  const auto &F = MF.getFunction();
  O.MaterializedWidth = T->MaterializedWidth;
  if (T->Identity.empty() ||
      F.getFnAttribute("vplan.backend.candidate").getValueAsString() !=
          T->Identity ||
      F.getFnAttribute("vplan.backend.role").getValueAsString() != T->Role)
    return FailMapping("materialized region identity mismatch");
  SmallVector<uint64_t> IDs;
  for (const auto &W : T->Widths)
    IDs.push_back(W.first);
  llvm::sort(IDs);
  for (uint64_t ID : IDs) {
    VPlanBackendLoopObservation Loop;
    Loop.ID = ID;
    Loop.IterationWidth = T->Widths.lookup(ID);
    O.Loops.push_back(std::move(Loop));
  }
  MachineDominatorTree DT(MF);
  MachineLoopInfo LI(DT);
  auto Bodies = mapTrackedLoops(*T, MF, DT, LI);
  if (!Bodies) {
    auto Reason = toString(Bodies.takeError());
    if (Reason == "width-overflow" ||
        Reason == "unsupported-iteration-transform" ||
        Reason == "unsupported-finite-body")
      O.NormalizationFailure = Reason;
    return FailMapping(Reason);
  }
  for (unsigned I = 0; I != Bodies->size(); ++I) {
    O.Loops[I].SelectedBlockCount = (*Bodies)[I].Blocks.size();
    O.SelectedBlockCount += O.Loops[I].SelectedBlockCount;
  }
  O.MappingSucceeded = true;
  O.NormalizationSucceeded = true;
  O.IterationMapping = true;
  return Bodies;
}

namespace {
class MappingVerifier : public FunctionPass {
public:
  static char ID;
  MappingVerifier() : FunctionPass(ID) {
    static const PassInfo PI("VPlan IR normalization validation",
                             "vplan-ir-normalization", &ID, nullptr, false,
                             false);
    static const bool Registered = [] {
      PassRegistry::getPassRegistry()->registerPass(PI);
      return true;
    }();
    (void)Registered;
  }
  void getAnalysisUsage(AnalysisUsage &AU) const override {
    AU.setPreservesAll();
  }
  bool runOnFunction(Function &F) override {
    validateLoopBackedges(F);
    return false;
  }
};
char MappingVerifier::ID = 0;
} // namespace
FunctionPass *llvm::createRISCVVPlanMappingVerifier() {
  return new MappingVerifier;
}
