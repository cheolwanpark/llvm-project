// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "llvm/IR/LoopBackedgeTracking.h"
#include "LLVMContextImpl.h"
#include "llvm/IR/BasicBlock.h"
#include "llvm/IR/Function.h"
using namespace llvm;
LoopBackedgeTracking *LoopBackedgeTracking::get(const Function *F) {
  if (!F || !F->getContext().pImpl->LoopBackedges)
    return nullptr;
  auto &R = *F->getContext().pImpl->LoopBackedges;
  auto I = R.find(F);
  return I == R.end() ? nullptr : I->second.get();
}
LoopBackedgeTracking *LoopBackedgeTracking::get(const BasicBlock *BB) {
  return BB ? get(BB->getParent()) : nullptr;
}
void LoopBackedgeTracking::deleted(BasicBlock &BB) {
  auto &R = BB.getContext().pImpl->LoopBackedges;
  if (R)
    for (auto &E : *R)
      E.second->forget(&BB);
}
void LoopBackedgeTracking::deleted(Function &F) {
  auto &R = F.getContext().pImpl->LoopBackedges;
  if (R) {
    R->erase(&F);
    if (R->empty())
      R.reset();
  }
}
ScopedLoopBackedgeTracking::ScopedLoopBackedgeTracking(Function &F)
    : Context(F.getContext()), Owner(&F) {
  auto &R = Context.pImpl->LoopBackedges;
  if (!R)
    R = std::make_unique<LLVMContextImpl::LoopBackedgeRegistry>();
  assert(!R->count(&F) && "function already tracked");
  R->try_emplace(&F, std::make_unique<LoopBackedgeTracking>());
}
ScopedLoopBackedgeTracking::~ScopedLoopBackedgeTracking() {
  auto &R = Context.pImpl->LoopBackedges;
  if (R) {
    R->erase(Owner);
    if (R->empty())
      R.reset();
  }
}
