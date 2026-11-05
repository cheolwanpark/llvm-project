// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "llvm/CodeGen/MachineLoopBackedgeTracking.h"
#include "llvm/CodeGen/MachineBasicBlock.h"
using namespace llvm;
MachineLoopBackedgeTracking::MachineLoopBackedgeTracking(
    const LoopBackedgeTracking &IR)
    : Identity(IR.Identity), Role(IR.Role),
      MaterializedWidth(IR.MaterializedWidth),
      CaptureFailures(IR.CaptureFailures) {
  importWidths(IR.Widths);
  Failure = IR.Failure;
  Undefined = IR.Undefined;
}
void MachineLoopBackedgeTracking::duplicateTail(const MachineBasicBlock &Tail,
                                                const MachineBasicBlock &Pred) {
  SmallVector<std::pair<Edge, Labels>> Edges(Backedges.begin(),
                                             Backedges.end());
  for (const auto &E : Edges) {
    if (E.first.first == &Tail)
      bind({&Pred, E.first.second}, E.second);
    // Duplicating a header into its latch changes the iteration boundary. The
    // caller cannot infer that boundary from partial block duplication alone.
    if (E.first == Edge{&Pred, &Tail})
      Backedges.erase(E.first);
  }
}
void MachineLoopBackedgeTracking::bypass(const MachineBasicBlock &BB,
                                         const MachineBasicBlock &Successor) {
  SmallVector<std::pair<Edge, Labels>> Edges(Backedges.begin(),
                                             Backedges.end());
  for (const auto &E : Edges) {
    if (E.first == Edge{&BB, &Successor}) {
      Backedges.erase(E.first);
      for (const auto *Pred : BB.predecessors())
        bind({Pred, &Successor}, E.second);
    }
  }
  transferIncoming(&BB, &Successor);
}
