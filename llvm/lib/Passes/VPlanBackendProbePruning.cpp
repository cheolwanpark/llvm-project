// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "VPlanBackendProbePruning.h"
#include "llvm/Analysis/LoopBackedgeAnalysis.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/Dominators.h"
using namespace llvm;
// Private probe CFG reduction. See BACKEND_FEEDBACK.md.
cl::opt<bool> llvm::PruneLoopRegions(
    "vplan-backend-prune-cfg", cl::Hidden, cl::init(true),
    cl::desc(
        "Compatibility option; common post-frame probes retain the full CFG"));
cl::opt<bool>
    llvm::PruningTrace("vplan-backend-pruning-trace", cl::Hidden,
                       cl::init(false),
                       cl::desc("Report experimental probe pruning sizes"));
cl::opt<bool> llvm::PruningDumpIR(
    "vplan-backend-pruning-dump-ir", cl::Hidden, cl::init(false),
    cl::desc("Dump experimental probe IR before/after pruning and suffix"));

// Passive diagnostics use current natural-loop membership.
ProbeIRSize llvm::getProbeIRSize(Function &F) {
  ProbeIRSize Size{F.getInstructionCount(), unsigned(F.size()), 0, 0};
  if (auto *T = LoopBackedgeTracking::get(&F)) {
    DominatorTree DT(F);
    LoopInfo LI(DT);
    auto Bodies = mapTrackedLoops(*T, F, DT, LI);
    if (!Bodies) {
      consumeError(Bodies.takeError());
      return Size;
    }
    for (const auto &Body : *Bodies)
      for (auto *BB : Body.Blocks) {
        Size.LoopInstructions += BB->size();
        ++Size.LoopBlocks;
      }
  }
  return Size;
}
