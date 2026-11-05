// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_IR_LOOPBACKEDGETRACKING_H
#define LLVM_IR_LOOPBACKEDGETRACKING_H
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Support/Compiler.h"
#include "llvm/Support/Error.h"
#include <cstdint>
#include <optional>
#include <string>
namespace llvm {
class BasicBlock;
class Function;
class LLVMContext;
/// Only iteration identities, widths and actual CFG edges persist between
/// transformations. Membership is reconstructed from current loop analysis.
template <class Block> class LoopBackedgeRewrite;
template <class Block> struct LoopBackedgeTable {
  friend class LoopBackedgeRewrite<Block>;
  using ID = uint64_t;
  using Edge = std::pair<const Block *, const Block *>;
  DenseMap<ID, uint64_t> Widths;
  DenseMap<Edge, ID> Backedges;
  std::string Failure;
  void fail(StringRef Reason) {
    if (Failure.empty())
      Failure = Reason.str();
  }
  void importWidths(const DenseMap<ID, uint64_t> &Source) {
    Widths = Source;
    NextID = 1;
    for (const auto &W : Widths) {
      if (!W.first || W.first == UINT64_MAX || !W.second ||
          W.second > UINT32_MAX) {
        fail("width-overflow");
        continue;
      }
      NextID = std::max(NextID, W.first + 1);
    }
  }
  void eraseLoopEdges(ID Q) {
    SmallVector<Edge> Edges;
    for (const auto &E : Backedges)
      if (E.second == Q)
        Edges.push_back(E.first);
    for (auto E : Edges)
      Backedges.erase(E);
  }
  ID addLoop(uint64_t Width) {
    ID Q = NextID++;
    Widths[Q] = Width;
    if (!Width || Width > UINT32_MAX)
      fail("width-overflow");
    return Q;
  }
  void bind(Edge E, ID Q) {
    if (!Widths.count(Q)) {
      fail("unregistered-loop-id");
      return;
    }
    auto [I, New] = Backedges.try_emplace(E, Q);
    if (!New && I->second != Q)
      fail("conflicting-loop-ids");
  }
  void move(Edge Old, Edge New) {
    auto I = Backedges.find(Old);
    if (I == Backedges.end())
      return;
    ID Q = I->second;
    Backedges.erase(I);
    bind(New, Q);
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
    if (!Edges.empty() && !RewriteDepth)
      fail("lost-backedge");
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
      fail("width-overflow");
      return;
    }
    I->second *= Factor;
  }

private:
  ID NextID = 1;
  unsigned RewriteDepth = 0;
};
/// A snapshot exists only while a semantic CFG rewrite is in progress. The
/// caller must restore its CFG before rollback; commit validates the completed
/// outer rewrite, never a temporarily disconnected intermediate graph.
template <class Block> class LoopBackedgeRewrite {
  LoopBackedgeTable<Block> *Table;
  std::optional<LoopBackedgeTable<Block>> Saved;
  bool Finished = false;

public:
  explicit LoopBackedgeRewrite(LoopBackedgeTable<Block> *T) : Table(T) {
    if (Table) {
      Saved = *Table;
      ++Table->RewriteDepth;
    }
  }
  LoopBackedgeRewrite(const LoopBackedgeRewrite &) = delete;
  LoopBackedgeRewrite &operator=(const LoopBackedgeRewrite &) = delete;
  ~LoopBackedgeRewrite() {
    if (Table && !Finished) {
      --Table->RewriteDepth;
      Table->fail("unsupported-iteration-transform");
    }
  }
  const LoopBackedgeTable<Block> *snapshot() const {
    return Saved ? &*Saved : nullptr;
  }
  template <class Validator> void commit(Validator &&Validate) {
    assert(!Finished);
    Finished = true;
    if (!Table)
      return;
    assert(Table->RewriteDepth == Saved->RewriteDepth + 1);
    if (!--Table->RewriteDepth && Table->Failure.empty())
      if (Error E = Validate())
        Table->fail(toString(std::move(E)));
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
