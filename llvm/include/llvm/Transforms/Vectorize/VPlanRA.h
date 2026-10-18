//===- VPlanRA.h - Transport for backend-informed VPlan research -*- C++ -*-===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

#ifndef LLVM_TRANSFORMS_VECTORIZE_VPLANRA_H
#define LLVM_TRANSFORMS_VECTORIZE_VPLANRA_H

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/IR/PassManager.h"
#include "llvm/Support/Compiler.h"
#include "llvm/Support/InstructionCost.h"
#include "llvm/Support/JSON.h"
#include "llvm/Support/TypeSize.h"
#include <string>

namespace llvm {
class Function;
class Module;
class VPlan;
class Loop;
class ScalarEvolution;
namespace vfs {
class FileSystem;
}

enum class VPlanPipelineStage { Full, Prepare, Resume };
LLVM_ABI VPlanPipelineStage getVPlanPipelineStage();
LLVM_ABI bool vplanRAEnabled();
LLVM_ABI StringRef getVPlanRAProbe();
LLVM_ABI StringRef getVPlanRARunID();
LLVM_ABI bool vplanRAHasFeedback();
LLVM_ABI void markVPlanRALoop(Loop &L, StringRef ID, ScalarEvolution &SE);
LLVM_ABI void finalizeVPlanRAIterationMapping(Function &F,
                                              FunctionAnalysisManager &AM);
struct VPlanBackendCost {
  InstructionCost Body = 0, ScalarBody = 0, Score = 0;
  unsigned Divisor = 1, Width = 1, ScalarWidth = 1;
  std::string Kind = "cost-per-lane";
  json::Object Breakdown;
};
LLVM_ABI int64_t costQuarters(InstructionCost C);
LLVM_ABI json::Object serializeBackendCost(const VPlanBackendCost &C);
LLVM_ABI VPlanBackendCost parseBackendCost(const json::Object &O);
LLVM_ABI bool backendCostLess(const VPlanBackendCost &A,
                              const VPlanBackendCost &B);
LLVM_ABI void writeVPlanRAJSON(StringRef Path, json::Value Value);
LLVM_ABI void finishVPlanRA(Module &M);
LLVM_ABI void initializeVPlanRA(vfs::FileSystem &FS);
LLVM_ABI Expected<json::Value> readVPlanRAJSON(StringRef Path);

/// Per original loop, never keyed by a transient report snapshot or address.
/// The orchestration/transport is fixed; the cost hook is a research surface.
class VPlanRAContext {
  std::string FunctionName;
  unsigned LoopIndex;
  SmallVector<const VPlan *> Plans;
  StringMap<json::Object> Feedback;
  std::string Prefix;

public:
  VPlanRAContext(const Function &F, unsigned LoopIndex);
  void registerPlan(const VPlan &Plan);
  std::string candidateID(const VPlan &Plan, ElementCount VF) const;
  bool isProbe(const VPlan &Plan, ElementCount VF) const;
  bool probesThisLoop() const;
  VPlanBackendCost cost(const VPlan &Plan, ElementCount VF) const;
  void recordCandidate(const VPlan &Plan, ElementCount VF);
  void selection(const VPlan &Plan, ElementCount VF, unsigned IC,
                 ElementCount EpilogueVF, bool Emitted);
};
} // namespace llvm
#endif
