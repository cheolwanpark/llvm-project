// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "llvm/CodeGen/MachineRelatedBlock.h"
#include "llvm/CodeGen/MachineBasicBlock.h"
#include "llvm/CodeGen/MachineFunction.h"
#include "llvm/IR/BasicBlock.h"
using namespace llvm;
RelatedBlockView MachineBasicBlock::getRelatedBlock() const {
  if (auto *T = getParent()->getRelatedBlockTracking())
    return T->lookup(*this);
  return {};
}
RelatedBlockView
MachineRelatedBlockTracking::lookup(const MachineBasicBlock &BB) const {
  auto I = Blocks.find(&BB);
  return I == Blocks.end() ? RelatedBlockView{{}, RelatedBlockState::Incomplete}
                           : I->second.view();
}
void MachineRelatedBlockTracking::create(const MachineBasicBlock &BB,
                                         const BasicBlock *IR) {
  if (IR)
    Blocks[&BB].assign(IR->getRelatedBlock());
}
void MachineRelatedBlockTracking::inherit(const MachineBasicBlock &To,
                                          const MachineBasicBlock &From) {
  RelatedBlockSet Copy;
  Copy.assign(lookup(From));
  Blocks[&To] = std::move(Copy);
}
void MachineRelatedBlockTracking::merge(const MachineBasicBlock &To,
                                        RelatedBlockView From) {
  RelatedBlockSet Snapshot;
  Snapshot.assign(From);
  From = Snapshot.view();
  auto [I, New] = Blocks.try_emplace(&To);
  if (New)
    I->second.assign(From);
  else
    I->second.merge(From);
}
void llvm::inheritRelatedBlocks(MachineBasicBlock &To,
                                const MachineBasicBlock &From) {
  assert(To.getParent() == From.getParent());
  if (auto *T = To.getParent()->getRelatedBlockTracking())
    T->inherit(To, From);
}
void llvm::mergeRelatedBlocks(MachineBasicBlock &To,
                              const MachineBasicBlock &From) {
  if (&To != &From)
    if (auto *T = To.getParent()->getRelatedBlockTracking()) {
      auto V = To.getParent() == From.getParent()
                   ? From.getRelatedBlock()
                   : RelatedBlockView{{}, RelatedBlockState::Incomplete};
      T->merge(To, V);
    }
}
void MachineRelatedBlockTracking::save(const MachineInstr &I,
                                       const MachineInstr &Source) {
  RelatedBlockSet Copy;
  if (Source.getParent())
    Copy.assign(lookup(*Source.getParent()));
  else if (auto It = Transfers.find(&Source); It != Transfers.end())
    Copy = It->second;
  else
    return;
  Transfers[&I] = std::move(Copy);
}
void MachineRelatedBlockTracking::insert(const MachineInstr &I) {
  auto It = Transfers.find(&I);
  if (It == Transfers.end())
    return;
  merge(*I.getParent(), It->second.view());
  Transfers.erase(It);
}
