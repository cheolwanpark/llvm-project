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
#include <optional>
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
  struct EvaluationRecord {
    unsigned ID, PlanID;
    ElementCount VF;
    std::string Phase, Events;
    SmallVector<bool> Visited, SuccessfulChecks;
  };
  struct PlanRecord {
    std::string Snapshot;
    DenseMap<const VPRecipeBase *, unsigned> Recipes;
    SmallVector<std::unique_ptr<EvaluationRecord>> Evaluations;
  };
  struct ComparisonRecord {
    std::string Against, Reason;
    std::optional<bool> Result;
  };
  struct CandidateRecord {
    unsigned PlanID;
    ElementCount VF;
    bool Epilogue;
    std::optional<InstructionCost> BodyCost, Score;
    unsigned EstimatedWidth;
    CandidateRecord(unsigned PlanID, ElementCount VF, bool Epilogue,
                    unsigned EstimatedWidth)
        : PlanID(PlanID), VF(VF), Epilogue(Epilogue),
          EstimatedWidth(EstimatedWidth) {}
    unsigned ScoreDivisor = 1;
    std::string ScoreKind = "not-evaluated", Reason;
    ComparisonRecord Incumbent, Scalar;
    std::optional<unsigned> MaxTripCount;
    bool HasTail = false;
  };
  struct SelectionRecord {
    unsigned PlanID;
    ElementCount VF;
    std::optional<unsigned> SourcePlan;
    std::string Reason;
  };
  SmallVector<std::unique_ptr<PlanRecord>> Plans;
  DenseMap<const VPlan *, unsigned> PlanIDs;
  SmallVector<CandidateRecord, 0> Candidates;
  std::optional<InstructionCost> ScalarBaseline;
  std::optional<SelectionRecord> MainSelection, EpilogueSelection;
  std::optional<unsigned> InterleaveCount;
  std::string InterleaveReason;
  SmallVector<std::pair<std::string, unsigned>> Diagnostics;
  std::string Header, Events, RecipeEvents;
  EvaluationRecord *Active = nullptr;
  bool InRecipe = false;
  std::optional<unsigned> Comparing, ComparedIncumbent;
  bool ComparingScalar = false;
  unsigned NextEvaluation = 0;
  unsigned TuningVScale;
  bool Detailed;
  bool Emitted = false;
  unsigned DetailDepth = 0;

  CandidateRecord &candidate(const VPlan &Plan, ElementCount VF,
                             bool Epilogue = false);
  void addDiagnostic(std::string Text);
  void print(raw_ostream &OS) const;

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
  void forgetPlan(const VPlan &Plan) { PlanIDs.erase(&Plan); }
  void scalarBaseline(InstructionCost Cost) { ScalarBaseline = Cost; }
  void bodyCost(const VPlan &Plan, ElementCount VF, InstructionCost Cost);
  void skip(const VPlan &Plan, ElementCount VF, StringRef Reason,
            bool Epilogue = false);
  void select(const VPlan &Plan, ElementCount VF, StringRef Reason = {},
              const VPlan *Source = nullptr);
  void interleave(unsigned Count, StringRef Reason, bool Final = false);
  void beginComparison(const VPlan &Plan, ElementCount VF, InstructionCost Cost,
                       const VPlan *Incumbent, ElementCount IncumbentVF,
                       bool Scalar = false, bool Epilogue = false);
  void comparisonContext(unsigned MaxTripCount, bool HasTail);
  void comparisonScore(InstructionCost Score, InstructionCost IncumbentScore,
                       StringRef Kind, unsigned Divisor = 1,
                       unsigned IncumbentDivisor = 1);
  void comparisonResult(bool Result, StringRef Reason);

  void beginEvaluation(const VPlan &Plan, ElementCount VF);
  void endEvaluation();
  void beginRecipe(const VPRecipeBase &R);
  void recipeReference(const VPRecipeBase &R);
  void recipe(const VPRecipeBase &R, const Instruction *UI,
              InstructionCost Cost, StringRef Source);
  void legacy(const Instruction *I, StringRef Category, InstructionCost Cost);
  void invalid(StringRef Reason);
  void emitted() { Emitted = true; }
  bool isDetailed() const { return Detailed; }
  unsigned nextEvaluation() { return NextEvaluation++; }
  template <typename Fn> void summary(Fn &&Print) {
    std::string Text;
    raw_string_ostream OS(Text);
    Print(OS);
    addDiagnostic(std::move(Text));
  }
  template <typename Fn> void record(Fn &&Print) {
    if (!Detailed)
      return;
    raw_string_ostream OS(InRecipe ? RecipeEvents
                          : Active ? Active->Events
                                   : Events);
    Print(OS);
  }
  template <typename Fn> void detail(Fn &&Print) {
    if (!Detailed)
      return;
    std::string Text;
    raw_string_ostream OS(Text);
    Print(OS);
    record([&](raw_ostream &Out) {
      SmallVector<StringRef> Lines;
      StringRef(Text).rtrim('\n').split(Lines, '\n');
      for (StringRef Line : Lines)
        Out.indent(8 + 2 * DetailDepth) << Line.ltrim() << '\n';
    });
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
#define VP_COST_SUMMARY(Report, ...)                                           \
  do {                                                                         \
    if (auto *ReportPtr = (Report))                                            \
      ReportPtr->summary([&](llvm::raw_ostream &OS) { __VA_ARGS__; });         \
  } while (false)
#define VP_COST_DETAIL(Report, ...)                                            \
  do {                                                                         \
    if (auto *ReportPtr = (Report))                                            \
      ReportPtr->detail([&](llvm::raw_ostream &OS) { __VA_ARGS__; });          \
  } while (false)

} // namespace llvm
#endif
