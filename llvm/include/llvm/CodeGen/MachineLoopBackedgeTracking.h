// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_CODEGEN_MACHINELOOPBACKEDGETRACKING_H
#define LLVM_CODEGEN_MACHINELOOPBACKEDGETRACKING_H
#include "llvm/IR/LoopBackedgeTracking.h"
namespace llvm {
class MachineBasicBlock;
class MachineFunction;
class LLVM_ABI MachineLoopBackedgeTracking
    : public LoopBackedgeTable<MachineBasicBlock> {
public:
  std::string Identity, Role;
  uint64_t MaterializedWidth = 0;
  bool CaptureFailures = false;
  explicit MachineLoopBackedgeTracking(const LoopBackedgeTracking &IR);
  /// A caller-proven duplication of a tail into one predecessor. This is not
  /// independent loop cloning and never creates a new iteration identity.
  void duplicateTail(const MachineBasicBlock &Tail,
                     const MachineBasicBlock &Pred);
  /// Bypass a single-successor block, preserving the boundary on actual edges.
  void bypass(const MachineBasicBlock &BB, const MachineBasicBlock &Successor);
};
} // namespace llvm
#endif
