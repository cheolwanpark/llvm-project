//===- RelatedBlock.h - Scoped block ancestry ---------------------*- C++ -*-===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_IR_RELATEDBLOCK_H
#define LLVM_IR_RELATEDBLOCK_H
#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Support/Compiler.h"
#include <cstdint>
#include <string>

namespace llvm {
class BasicBlock;
class Function;
class Instruction;
class LLVMContext;
class Value;
using BlockOriginID = uint64_t;
enum class RelatedBlockState { Disabled, Known, Incomplete };
struct RelatedBlockView {
  ArrayRef<BlockOriginID> Origins;
  RelatedBlockState State = RelatedBlockState::Disabled;
};
struct RelatedBlockSet {
  SmallVector<BlockOriginID, 2> Origins;
  RelatedBlockState State = RelatedBlockState::Incomplete;
  RelatedBlockView view() const { return {Origins, State}; }
  LLVM_ABI void assign(RelatedBlockView V);
  LLVM_ABI void merge(RelatedBlockView V);
};
/// Owned evidence; neither pointers nor origin cardinality encode iterations.
struct RelatedBlockNormalization {
  uint64_t MaterializedWidth = 0, IterationWidth = 0, TripCount = 0;
  std::string TripCountKind = "unknown";
  std::string Basis = "materialized-iteration";
  std::string Failure;
  bool Finite = false;
};
struct RelatedBlockRegion {
  std::string Identity, Role;
  SmallVector<BlockOriginID, 8> Origins;
  RelatedBlockNormalization Normalization;
  LLVM_ABI bool intersects(RelatedBlockView V) const;
};
/// Active tables are allocated only for explicitly registered functions.
/// Views expire at the next table mutation. No BB object layout is changed.
class LLVM_ABI RelatedBlockTracking {
  friend class ScopedRelatedBlockTracking;
  Function *Owner;
  DenseMap<const BasicBlock *, RelatedBlockSet> Blocks;
  DenseMap<const Instruction *, RelatedBlockSet> Transfers;
  BlockOriginID NextOrigin = 1;
  bool Seeded = false;

public:
  RelatedBlockRegion Region;
  explicit RelatedBlockTracking(Function &F) : Owner(&F) {}
  static RelatedBlockTracking *get(const Function *F);
  static RelatedBlockTracking *get(const BasicBlock *BB);
  RelatedBlockView lookup(const BasicBlock *BB) const;
  void seed(ArrayRef<BasicBlock *> Body, StringRef Identity, StringRef Role,
            uint64_t Width, bool Finite);
  void finishMaterialization();
  void inherit(BasicBlock &To, const BasicBlock &From);
  void merge(BasicBlock &To, RelatedBlockView From);
  void forget(const BasicBlock *BB) { Blocks.erase(BB); }
  void save(const Instruction &I, const Instruction &Source);
  void insert(Instruction &I);
  void forget(const Instruction *I) { Transfers.erase(I); }
  static void replaced(const Value &From, Value &To);
  static void removed(Instruction &I);
  static void inserted(Instruction &I);
  static void cloned(Instruction &I, const Instruction &Source);
  static void deleted(Instruction &I);
  static void deleted(BasicBlock &BB);
  static void deleted(Function &F);
};
class LLVM_ABI ScopedRelatedBlockTracking {
  LLVMContext &Context;
  Function *Owner;

public:
  explicit ScopedRelatedBlockTracking(Function &F);
  ~ScopedRelatedBlockTracking();
  ScopedRelatedBlockTracking(const ScopedRelatedBlockTracking &) = delete;
  ScopedRelatedBlockTracking &
  operator=(const ScopedRelatedBlockTracking &) = delete;
};
LLVM_ABI void inheritRelatedBlocks(BasicBlock &To, const BasicBlock &From);
LLVM_ABI void mergeRelatedBlocks(BasicBlock &To, const BasicBlock &From);
} // namespace llvm
#endif
