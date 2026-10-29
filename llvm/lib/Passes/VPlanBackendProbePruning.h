// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_LIB_PASSES_VPLANBACKENDPROBEPRUNING_H
#define LLVM_LIB_PASSES_VPLANBACKENDPROBEPRUNING_H
#include "llvm/IR/PassManager.h"
#include "llvm/Support/CommandLine.h"
namespace llvm {
extern cl::opt<bool> PruneLoopRegions, PruningTrace, PruningDumpIR;
struct PruningResult {
  unsigned Removed;
  StringRef Reason;
};

struct ProbeIRSize {
  unsigned Instructions = 0, Blocks = 0;
  unsigned LoopInstructions = 0, LoopBlocks = 0;
};

ProbeIRSize getProbeIRSize(Function &F, FunctionAnalysisManager &FAM);
PruningResult pruneLoopRegions(Function &F, FunctionAnalysisManager &FAM);
} // namespace llvm
#endif
