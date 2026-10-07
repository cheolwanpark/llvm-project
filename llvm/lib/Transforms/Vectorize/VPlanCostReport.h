//===- VPlanCostReport.h - Observations of VPlan costing ---------*- C++
//-*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_VECTORIZE_VPLANCOSTREPORT_H
#define LLVM_TRANSFORMS_VECTORIZE_VPLANCOSTREPORT_H

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Support/InstructionCost.h"
#include "llvm/Support/TypeSize.h"
#include "llvm/Support/raw_ostream.h"
#include <memory>
#include <string>

namespace llvm {
class Instruction;
class Loop;
class VPlan;
class VPRecipeBase;
class VFSelectionContext;

/// A passive, per-loop observer. All values passed here must come from the
/// actual costing path. In particular, rendering must never query TTI or the
/// legacy cost model. Strings are captured while their IR/VPlan is still alive.
class VPlanCostReport {
  struct PlanRecord {
    std::string Snapshot, Events;
    DenseMap<const VPRecipeBase *, unsigned> Recipes;
    SmallVector<bool> Visited;
  };
  SmallVector<std::unique_ptr<PlanRecord>> Plans;
  DenseMap<const VPlan *, unsigned> PlanIDs;
  DenseMap<std::pair<const VPlan *, ElementCount>, unsigned> Evaluations;
  std::string Header, Events;
  PlanRecord *Active = nullptr;
  unsigned NextEvaluation = 0;
  bool Detailed;
  bool Emitted = false;
  unsigned DetailDepth = 0;

public:
  /// A detail scope is a node in the observed expression tree. It owns query
  /// leaves and expression results emitted while this cost routine executes.
  class CostScope {
    VPlanCostReport *Report;

  public:
    CostScope(VPlanCostReport *R, StringRef Name) : Report(R) {
      if (!Report || !Report->isDetailed())
        return;
      Report->record([&](raw_ostream &OS) {
        OS.indent(8 + 2 * Report->DetailDepth)
            << "calculation=" << Name << " {\n";
      });
      ++Report->DetailDepth;
    }
    ~CostScope() {
      if (!Report || !Report->isDetailed())
        return;
      --Report->DetailDepth;
      Report->record([&](raw_ostream &OS) {
        OS.indent(8 + 2 * Report->DetailDepth) << "}\n";
      });
    }
  };

  StringRef Phase = "candidate-validation";
  StringRef RecipeScope = "vector-region";
  bool Contributes = true;

  VPlanCostReport(const Loop &L, const VFSelectionContext &Config,
                  unsigned Invocation, unsigned LoopIndex, bool Detailed);
  ~VPlanCostReport();
  unsigned registerPlan(const VPlan &Plan);
  unsigned planID(const VPlan &Plan) { return registerPlan(Plan); }
  void forgetPlan(const VPlan &Plan) {
    PlanIDs.erase(&Plan);
    Evaluations.remove_if([&](const auto &Entry) {
      return Entry.first.first == &Plan;
    });
  }
  void beginEvaluation(const VPlan &Plan, ElementCount VF);
  void endEvaluation();
  void beginRecipe(const VPRecipeBase &R);
  void recipeReference(const VPRecipeBase &R);
  void recipe(const VPRecipeBase &R, const Instruction *UI,
              InstructionCost Cost, StringRef Source);
  void legacy(const Instruction *I, StringRef Category, InstructionCost Cost);
  void emitted() { Emitted = true; }
  bool isDetailed() const { return Detailed; }
  unsigned nextEvaluation() { return NextEvaluation++; }
  void evaluationReference(raw_ostream &OS, const VPlan &Plan,
                           ElementCount VF) const {
    auto It = Evaluations.find({&Plan, VF});
    if (It == Evaluations.end())
      OS << "not-evaluated";
    else
      OS << It->second;
  }

  template <typename Fn> void record(Fn &&Print) {
    raw_string_ostream OS(Active ? Active->Events : Events);
    Print(OS);
  }
  template <typename Fn> void detail(Fn &&Print) {
    if (Detailed)
      record(std::forward<Fn>(Print));
  }
  static void printVF(raw_ostream &OS, ElementCount VF) {
    OS << (VF.isScalable() ? 's' : 'f') << VF.getKnownMinValue();
  }
};

/// Observe an already evaluated query. Returning the unchanged value allows
/// observing leaves of expressions without introducing another TTI query.
inline InstructionCost observeVPlanCost(VPlanCostReport *Report, StringRef Name,
                                        InstructionCost Cost,
                                        StringRef Coverage = "tti-leaf") {
  if (Report)
    Report->detail([&](raw_ostream &OS) {
      OS << "          term=" << Name << " result=" << Cost
         << " coverage=" << Coverage << '\n';
    });
  return Cost;
}

/// Keep formatting and argument evaluation off the disabled path.
#define VP_COST_REPORT(Report, ...)                                            \
  do {                                                                         \
    if (auto *ReportPtr = (Report))                                            \
      ReportPtr->record([&](llvm::raw_ostream &OS) { __VA_ARGS__; });          \
  } while (false)
#define VP_COST_DETAIL(Report, ...)                                            \
  do {                                                                         \
    if (auto *ReportPtr = (Report))                                            \
      ReportPtr->detail([&](llvm::raw_ostream &OS) { __VA_ARGS__; });          \
  } while (false)

} // namespace llvm
#endif
