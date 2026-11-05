// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "llvm/CodeGen/MachineLoopBackedgeTracking.h"
#include "llvm/Analysis/LoopBackedgeAnalysis.h"
#include "llvm/CodeGen/MachineBasicBlock.h"
#include "llvm/CodeGen/MachineDominators.h"
#include "llvm/CodeGen/MachineFunction.h"
#include "llvm/CodeGen/MachineLoopInfo.h"
using namespace llvm;
MachineLoopBackedgeTracking::MachineLoopBackedgeTracking(
    const LoopBackedgeTracking &IR)
    : Identity(IR.Identity), Role(IR.Role),
      MaterializedWidth(IR.MaterializedWidth) {
  importWidths(IR.Widths);
  Failure = IR.Failure;
}
void MachineLoopBackedgeTracking::duplicateTail(const MachineBasicBlock &Tail,
                                                const MachineBasicBlock &Pred) {
  SmallVector<std::pair<Edge, ID>> Edges(Backedges.begin(), Backedges.end());
  for (const auto &E : Edges) {
    if (E.first.first == &Tail)
      bind({&Pred, E.first.second}, E.second);
    // Duplicating a header into its latch changes the iteration boundary. The
    // caller cannot infer that boundary from partial block duplication alone.
    if (E.first == Edge{&Pred, &Tail})
      fail("ambiguous-loop");
  }
}
void MachineLoopBackedgeTracking::bypass(const MachineBasicBlock &BB,
                                         const MachineBasicBlock &Successor) {
  SmallVector<std::pair<Edge, ID>> Edges(Backedges.begin(), Backedges.end());
  for (const auto &E : Edges) {
    if (E.first == Edge{&BB, &Successor}) {
      Backedges.erase(E.first);
      for (const auto *Pred : BB.predecessors())
        bind({Pred, &Successor}, E.second);
    }
  }
  transferIncoming(&BB, &Successor);
}
Error llvm::checkMachineLoopBackedges(MachineFunction &MF) {
  auto *T = MF.getLoopBackedgeTracking();
  if (!T)
    return Error::success();
  MachineDominatorTree DT(MF);
  MachineLoopInfo LI(DT);
  auto Result = mapTrackedLoops(*T, MF, DT, LI);
  if (!Result)
    return Result.takeError();
  return Error::success();
}
void llvm::validateMachineLoopBackedges(MachineFunction &MF) {
  if (auto *T = MF.getLoopBackedgeTracking())
    if (auto E = checkMachineLoopBackedges(MF))
      T->fail(toString(std::move(E)));
}
