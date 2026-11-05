// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "llvm/IR/RelatedBlock.h"
#include "LLVMContextImpl.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/IR/BasicBlock.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Instruction.h"
using namespace llvm;
void RelatedBlockSet::assign(RelatedBlockView V) {
  Origins.assign(V.Origins.begin(), V.Origins.end());
  State = V.State == RelatedBlockState::Disabled ? RelatedBlockState::Incomplete
                                                 : V.State;
}
void RelatedBlockSet::merge(RelatedBlockView V) {
  Origins.append(V.Origins.begin(), V.Origins.end());
  llvm::sort(Origins);
  Origins.erase(std::unique(Origins.begin(), Origins.end()), Origins.end());
  if (V.State != RelatedBlockState::Known)
    State = RelatedBlockState::Incomplete;
}
bool RelatedBlockRegion::intersects(RelatedBlockView V) const {
  return any_of(V.Origins, [&](auto ID) { return is_contained(Origins, ID); });
}
RelatedBlockTracking *RelatedBlockTracking::get(const Function *F) {
  if (!F || !F->getContext().pImpl->RelatedBlocks)
    return nullptr;
  auto &R = *F->getContext().pImpl->RelatedBlocks;
  auto I = R.find(F);
  return I == R.end() ? nullptr : I->second.get();
}
RelatedBlockTracking *RelatedBlockTracking::get(const BasicBlock *BB) {
  if (!BB)
    return nullptr;
  if (BB->getParent())
    return get(BB->getParent());
  // CloneBasicBlock also supports detached clones. Their source owner retains
  // the relation until insertion or deletion, without a global current scope.
  auto &Registry = BB->getContext().pImpl->RelatedBlocks;
  if (Registry)
    for (auto &Entry : *Registry)
      if (Entry.second->Blocks.count(BB))
        return Entry.second.get();
  return nullptr;
}
RelatedBlockView RelatedBlockTracking::lookup(const BasicBlock *BB) const {
  auto I = Blocks.find(BB);
  return I == Blocks.end() ? RelatedBlockView{{}, RelatedBlockState::Incomplete}
                           : I->second.view();
}
RelatedBlockView BasicBlock::getRelatedBlock() const {
  if (auto *T = RelatedBlockTracking::get(this))
    return T->lookup(this);
  return {};
}
void RelatedBlockTracking::seed(ArrayRef<BasicBlock *> Body, StringRef Identity,
                                StringRef Role, uint64_t Width, bool Finite) {
  assert(!Seeded && "one materialized role per probe");
  Seeded = true;
  Region.Identity = Identity.str();
  Region.Role = Role.str();
  Region.Normalization.MaterializedWidth = Width;
  Region.Normalization.IterationWidth = Width;
  Region.Normalization.Finite = Finite;
  if (!Width || Width > UINT32_MAX)
    Region.Normalization.Failure = "invalid materialized geometry";
  for (auto &BB : *Owner) {
    auto &S = Blocks[&BB];
    S.Origins = {NextOrigin++};
    S.State = RelatedBlockState::Known;
  }
  for (auto *BB : Body) {
    auto I = Blocks.find(BB);
    if (I == Blocks.end()) {
      Region.Normalization.Failure =
          "materialized body contains a non-live block";
      continue;
    }
    Region.Origins.push_back(I->second.Origins.front());
  }
  if (Region.Origins.empty())
    Region.Normalization.Failure = "missing materialized body";
}
void RelatedBlockTracking::inherit(BasicBlock &To, const BasicBlock &From) {
  if (Seeded && (!To.getParent() || To.getParent() == Owner) &&
      &To.getContext() == &From.getContext() && get(&From) == this) {
    RelatedBlockSet Copy;
    Copy.assign(lookup(&From));
    Blocks[&To] = std::move(Copy);
  }
}
void RelatedBlockTracking::merge(BasicBlock &To, RelatedBlockView From) {
  if (!Seeded ||
      (To.getParent() != Owner && (To.getParent() || !Blocks.count(&To))))
    return;
  // An unclassified generated block acquires the cause of its first transfer.
  RelatedBlockSet Snapshot;
  Snapshot.assign(From);
  From = Snapshot.view();
  auto [I, New] = Blocks.try_emplace(&To);
  if (New)
    I->second.assign(From);
  else
    I->second.merge(From);
}
void llvm::inheritRelatedBlocks(BasicBlock &To, const BasicBlock &From) {
  auto *T = RelatedBlockTracking::get(&To);
  if (!T && !To.getParent())
    T = RelatedBlockTracking::get(&From);
  if (T)
    T->inherit(To, From);
}
void llvm::mergeRelatedBlocks(BasicBlock &To, const BasicBlock &From) {
  if (&To != &From)
    if (auto *T = RelatedBlockTracking::get(&To)) {
      // Origin integers are meaningful only within their owner's namespace.
      auto V = RelatedBlockTracking::get(&From) == T
                   ? From.getRelatedBlock()
                   : RelatedBlockView{{}, RelatedBlockState::Incomplete};
      T->merge(To, V);
    }
}
void RelatedBlockTracking::save(const Instruction &I,
                                const Instruction &Source) {
  if (!Seeded)
    return;
  RelatedBlockSet S;
  if (Source.getParent())
    S.assign(lookup(Source.getParent()));
  else if (auto It = Transfers.find(&Source); It != Transfers.end())
    S = It->second;
  else
    return;
  auto [It, New] = Transfers.try_emplace(&I);
  if (New)
    It->second = std::move(S);
  else
    It->second.merge(S.view());
}
void RelatedBlockTracking::insert(Instruction &I) {
  auto It = Transfers.find(&I);
  if (It == Transfers.end())
    return;
  merge(*I.getParent(), It->second.view());
  Transfers.erase(It);
}
void RelatedBlockTracking::removed(Instruction &I) {
  if (auto *T = get(I.getParent()))
    T->save(I, I);
}
void RelatedBlockTracking::inserted(Instruction &I) {
  if (auto *T = get(I.getParent()))
    T->insert(I);
}
void RelatedBlockTracking::cloned(Instruction &I, const Instruction &Source) {
  if (auto *T = get(Source.getParent())) {
    T->save(I, Source);
    return;
  }
  auto &Registry = Source.getContext().pImpl->RelatedBlocks;
  if (!Source.getParent() && Registry)
    for (auto &Entry : *Registry)
      if (Entry.second->Transfers.count(&Source)) {
        Entry.second->save(I, Source);
        return;
      }
}
void RelatedBlockTracking::deleted(Instruction &I) {
  auto &Registry = I.getContext().pImpl->RelatedBlocks;
  if (Registry)
    for (auto &Entry : *Registry)
      Entry.second->forget(&I);
}
void RelatedBlockTracking::deleted(BasicBlock &BB) {
  auto &Registry = BB.getContext().pImpl->RelatedBlocks;
  if (Registry)
    for (auto &Entry : *Registry)
      Entry.second->forget(&BB);
}
void RelatedBlockTracking::deleted(Function &F) {
  auto &Registry = F.getContext().pImpl->RelatedBlocks;
  if (Registry) {
    Registry->erase(&F);
    if (Registry->empty())
      Registry.reset();
  }
}
ScopedRelatedBlockTracking::ScopedRelatedBlockTracking(Function &F)
    : Context(F.getContext()), Owner(&F) {
  auto &Registry = Context.pImpl->RelatedBlocks;
  if (!Registry)
    Registry = std::make_unique<LLVMContextImpl::RelatedBlockRegistry>();
  assert(!Registry->count(&F) && "function already tracked");
  Registry->try_emplace(&F, std::make_unique<RelatedBlockTracking>(F));
}
ScopedRelatedBlockTracking::~ScopedRelatedBlockTracking() {
  auto &Registry = Context.pImpl->RelatedBlocks;
  if (Registry) {
    Registry->erase(Owner);
    if (Registry->empty())
      Registry.reset();
  }
}

void RelatedBlockTracking::replaced(const Value &From, Value &To) {
  if (!From.getContext().pImpl->RelatedBlocks)
    return;
  auto *A = dyn_cast<Instruction>(&From);
  auto *B = dyn_cast<Instruction>(&To);
  if (!A || !B || !A->getParent())
    return;
  if (B->getParent())
    mergeRelatedBlocks(*B->getParent(), *A->getParent());
  else if (auto *T = get(A->getParent()))
    T->save(*B, *A);
}

void RelatedBlockTracking::finishMaterialization() {
  if (!Seeded)
    return;
  for (auto &BB : *Owner)
    if (!Blocks.count(&BB)) {
      auto &S = Blocks[&BB];
      S.State = RelatedBlockState::Known;
      S.Origins = {NextOrigin++};
    }
}
