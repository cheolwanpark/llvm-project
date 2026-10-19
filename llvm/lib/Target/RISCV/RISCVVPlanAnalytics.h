//===- RISCVVPlanAnalytics.h - Cost-independent post-RA facts -----*- C++
//-*-===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_LIB_TARGET_RISCV_VPLAN_ANALYTICS_H
#define LLVM_LIB_TARGET_RISCV_VPLAN_ANALYTICS_H
#include "llvm/CodeGen/MachineFunctionPass.h"
#include "llvm/Support/JSON.h"
#include <cstdint>
#include <string>
#include <vector>
namespace llvm {
namespace vplan {
struct Operand {
  int64_t Reg = 0;
  std::string Name;
  std::string Bank = "unknown";
  std::vector<int64_t> Units;
  int64_t Group8 = 0;
  bool Vector = false;
  bool Def = false;
  bool Use = false;
  bool Implicit = false;
  bool Dead = false;
  bool Undef = false;
  bool EarlyClobber = false;
  bool Tied = false;
  bool SubReg = false;
};
json::Value toJSON(const Operand &V);
struct InstructionInfo {
  int64_t ID = 0;
  int64_t Block = 0;
  std::string Opcode;
  std::string Base;
  std::string Category = "unknown";
  int64_t SEW = 0;
  int64_t Group8 = 0;
  int64_t IndexSEW = 0;
  int64_t IndexGroup8 = 0;
  int64_t Predicate = 0;
  int64_t StackSlot = 0;
  int64_t Bytes = 0;
  bool ScalableBytes = false;
  bool Stack = false;
  bool Spill = false;
  bool SpillSlotAccess = false;
  bool Load = false;
  bool Store = false;
  bool Masked = false;
  bool Meta = false;
  bool Barrier = false;
  bool ConfigUnused = false;
  bool SameCopy = false;
  std::vector<Operand> Operands;
  std::vector<int64_t> Immediates;
};
json::Value toJSON(const InstructionInfo &V);
struct Edge {
  int64_t Source = 0;
  int64_t Destination = 0;
  int64_t OperandIndex = 0;
  int64_t Distance = 0;
  bool WholeValue = false;
};
json::Value toJSON(const Edge &V);
struct Block {
  int64_t ID = 0;
  std::string Role = "outside";
  std::vector<int64_t> Successors;
};
json::Value toJSON(const Block &V);
struct Analytics {
  int64_t Version = 2;
  std::string RunID;
  std::string Candidate;
  std::string Function;
  std::string CPU;
  std::string Stage = "post-ra-cleanup";
  std::string Error;
  std::string DependencyCoverage = "block-local";
  int64_t VLen = 0;
  int64_t Width = 1;
  int64_t VF = 1;
  bool ScalableVF = false;
  int64_t MaxTripCount = 0;
  int64_t ExactTripCount = 0;
  bool ScalarTail = false;
  int64_t Header = -1;
  int64_t Latch = -1;
  int64_t PeakLiveVectorRegisters = -1;
  std::vector<Block> Blocks;
  std::vector<InstructionInfo> Instructions;
  std::vector<Edge> Edges;
};
json::Value toJSON(const Analytics &V);
Analytics collectAnalytics(const MachineFunction &MF);
} // namespace vplan
class RISCVVPlanAnalytics : public MachineFunctionPass {
  bool Seen = false;

public:
  static char ID;
  RISCVVPlanAnalytics();
  StringRef getPassName() const override { return "RISC-V VPlan analytics"; }
  void getAnalysisUsage(AnalysisUsage &AU) const override;
  bool runOnMachineFunction(MachineFunction &MF) override;
  bool doFinalization(Module &) override;
};
} // namespace llvm
#endif
