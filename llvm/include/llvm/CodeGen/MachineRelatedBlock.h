// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_CODEGEN_MACHINERELATEDBLOCK_H
#define LLVM_CODEGEN_MACHINERELATEDBLOCK_H
#include "llvm/IR/RelatedBlock.h"
namespace llvm {
class MachineBasicBlock;
class MachineInstr;
/// Machine lifetime owner. IR pointers are used only at the creation bridge.
class LLVM_ABI MachineRelatedBlockTracking {
  DenseMap<const MachineBasicBlock *, RelatedBlockSet> Blocks;
  DenseMap<const MachineInstr *, RelatedBlockSet> Transfers;

public:
  RelatedBlockRegion Region;
  explicit MachineRelatedBlockTracking(const RelatedBlockRegion &R)
      : Region(R) {}
  RelatedBlockView lookup(const MachineBasicBlock &BB) const;
  void create(const MachineBasicBlock &BB, const BasicBlock *IR);
  void inherit(const MachineBasicBlock &To, const MachineBasicBlock &From);
  void merge(const MachineBasicBlock &To, RelatedBlockView From);
  void save(const MachineInstr &I, const MachineInstr &Source);
  void insert(const MachineInstr &I);
  void forget(const MachineBasicBlock *BB) { Blocks.erase(BB); }
  void forget(const MachineInstr *I) { Transfers.erase(I); }
};
LLVM_ABI void inheritRelatedBlocks(MachineBasicBlock &To,
                                   const MachineBasicBlock &From);
LLVM_ABI void mergeRelatedBlocks(MachineBasicBlock &To,
                                 const MachineBasicBlock &From);
} // namespace llvm
#endif
