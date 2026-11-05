// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_IR_LOOPBACKEDGETRACKING_H
#define LLVM_IR_LOOPBACKEDGETRACKING_H
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Support/Compiler.h"
#include <cstdint>
#include <optional>
#include <string>
namespace llvm {
class BasicBlock;
class Function;
class LLVMContext;
/// Only iteration identities, widths and actual CFG edges persist between
/// transformations. Membership is reconstructed from current loop analysis.
template <class Block> struct LoopBackedgeTable {
  using ID = uint64_t;
  using Edge = std::pair<const Block *, const Block *>;
  DenseMap<ID, uint64_t> Widths;
  using Labels = SmallVector<ID, 1>;
  DenseMap<Edge, Labels> Backedges;
  DenseSet<ID> Undefined;
  std::string Failure;
  void fail(StringRef Reason) {
    if (Failure.empty())
      Failure = Reason.str();
  }
  void importWidths(const DenseMap<ID, uint64_t> &Source) {
    Widths = Source;
    NextID = 1;
    for (const auto &W : Widths) {
      if (!W.first || W.first == UINT64_MAX) {
        fail("width-overflow");
        continue;
      }
      NextID = std::max(NextID, W.first + 1);
    }
  }
  void eraseLoopEdges(ID Q) {
    SmallVector<Edge> Edges;
    for (const auto &E : Backedges)
      if (is_contained(E.second, Q))
        Edges.push_back(E.first);
    for (auto E : Edges) {
      llvm::erase(Backedges[E], Q);
      if (Backedges[E].empty())
        Backedges.erase(E);
    }
  }
  ID addLoop(uint64_t Width) {
    ID Q = NextID++;
    Widths[Q] = Width;
    if (!Width || Width > UINT32_MAX)
      Undefined.insert(Q);
    return Q;
  }
  void bind(Edge E, ID Q) {
    if (!Widths.count(Q)) {
      fail("unregistered-loop-id");
      return;
    }
    auto &IDs = Backedges[E];
    if (!is_contained(IDs, Q))
      IDs.push_back(Q);
    if (any_of(IDs, [&](ID Other) {
          return Undefined.contains(Other) ||
                 Widths.lookup(Other) != Widths.lookup(Q);
        }))
      Undefined.insert(IDs.begin(), IDs.end());
  }
  void bind(Edge E, Labels IDs) {
    for (ID Q : IDs)
      bind(E, Q);
  }
  void move(Edge Old, Edge New) {
    auto I = Backedges.find(Old);
    if (I == Backedges.end())
      return;
    auto IDs = I->second;
    Backedges.erase(I);
    bind(New, IDs);
  }
  void transferIncoming(const Block *From, const Block *To) {
    SmallVector<Edge> Edges;
    for (const auto &E : Backedges)
      if (E.first.second == From)
        Edges.push_back(E.first);
    for (auto E : Edges)
      move(E, {E.first, To});
  }
  void transferOutgoing(const Block *From, const Block *To) {
    SmallVector<Edge> Edges;
    for (const auto &E : Backedges)
      if (E.first.first == From)
        Edges.push_back(E.first);
    for (auto E : Edges)
      move(E, {To, E.second});
  }
  void forget(const Block *BB) {
    SmallVector<Edge> Edges;
    for (const auto &E : Backedges)
      if (E.first.first == BB || E.first.second == BB)
        Edges.push_back(E.first);
    for (auto E : Edges)
      Backedges.erase(E);
  }
  void expand(ID Q, uint64_t Factor) {
    auto I = Widths.find(Q);
    if (I == Widths.end()) {
      fail("unregistered-loop-id");
      return;
    }
    if (!Factor || I->second > UINT32_MAX / Factor) {
      Undefined.insert(Q);
      return;
    }
    I->second *= Factor;
  }

private:
  ID NextID = 1;
};
/// A snapshot exists only while a semantic CFG rewrite is in progress. The
/// caller must restore its CFG before rollback. Completion does not validate
/// tracking completeness or inspect a temporarily disconnected graph.
template <class Block> class LoopBackedgeRewrite {
  LoopBackedgeTable<Block> *Table;
  std::optional<LoopBackedgeTable<Block>> Saved;
  bool Finished = false;

public:
  explicit LoopBackedgeRewrite(LoopBackedgeTable<Block> *T) : Table(T) {
    if (Table)
      Saved = *Table;
  }
  LoopBackedgeRewrite(const LoopBackedgeRewrite &) = delete;
  LoopBackedgeRewrite &operator=(const LoopBackedgeRewrite &) = delete;
  ~LoopBackedgeRewrite() = default;
  const LoopBackedgeTable<Block> *snapshot() const {
    return Saved ? &*Saved : nullptr;
  }
  void commit() {
    assert(!Finished);
    Finished = true;
  }
  void rollback() {
    assert(!Finished);
    Finished = true;
    if (Table)
      *Table = std::move(*Saved);
  }
};
class LLVM_ABI LoopBackedgeTracking : public LoopBackedgeTable<BasicBlock> {
public:
  std::string Identity, Role;
  uint64_t MaterializedWidth = 0;
  bool CaptureFailures = false;
  static LoopBackedgeTracking *get(const Function *F);
  static LoopBackedgeTracking *get(const BasicBlock *BB);
  static void deleted(BasicBlock &BB);
  static void deleted(Function &F);
};
class LLVM_ABI ScopedLoopBackedgeTracking {
  LLVMContext &Context;
  Function *Owner;

public:
  explicit ScopedLoopBackedgeTracking(Function &F);
  ~ScopedLoopBackedgeTracking();
  ScopedLoopBackedgeTracking(const ScopedLoopBackedgeTracking &) = delete;
  ScopedLoopBackedgeTracking &
  operator=(const ScopedLoopBackedgeTracking &) = delete;
};
} // namespace llvm
#endif
