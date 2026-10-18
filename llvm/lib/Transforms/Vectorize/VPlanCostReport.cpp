//===- VPlanCostReport.cpp - Observations of VPlan costing
//------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "VPlanCostReport.h"
#include "LoopVectorizationPlanner.h"
#include "VPlan.h"
#include "VPlanCFG.h"
#include "VPlanHelpers.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/IR/Module.h"
#include "llvm/Transforms/Vectorize/LoopVectorizationLegality.h"

using namespace llvm;

VPlanCostReport::VPlanCostReport(const Loop &L,
                                 const VFSelectionContext &Config,
                                 unsigned Invocation, unsigned LoopIndex,
                                 bool Detailed)
    : TuningVScale(Config.getVScaleForTuning().value_or(1)),
      Detailed(Detailed) {
  const Function &F = *L.getHeader()->getParent();
  raw_string_ostream OS(Header);
  OS << "VPlan report_version=2 module=" << F.getParent()->getModuleIdentifier()
     << " invocation=" << Invocation << " function=" << F.getName()
     << " loop=" << LoopIndex << " header=" << L.getHeader()->getName()
     << " depth=" << (Detailed ? 2 : 1) << "\n";
  StringRef CPU = F.getFnAttribute("target-cpu").getValueAsString();
  OS << "  target=" << F.getParent()->getTargetTriple().str()
     << " cpu=" << (CPU.empty() ? "unspecified" : CPU) << "\n  cost_kind=";
  switch (Config.CostKind) {
  case TargetTransformInfo::TCK_RecipThroughput:
    OS << "reciprocal_throughput";
    break;
  case TargetTransformInfo::TCK_Latency:
    OS << "latency";
    break;
  case TargetTransformInfo::TCK_CodeSize:
    OS << "code_size";
    break;
  case TargetTransformInfo::TCK_SizeAndLatency:
    OS << "size_and_latency";
    break;
  }
  OS << " units=model-units opt_for_size=" << Config.OptForSize
     << " tuning_vscale=";
  if (auto VScale = Config.getVScaleForTuning())
    OS << *VScale;
  else
    OS << "unknown";
  OS << " user_vf=";
  printVF(OS, Config.getHints().getWidth());
  OS << " user_ic=" << Config.getHints().getInterleave() << " location=";
  L.getStartLoc().print(OS);
  OS << '\n';
}

VPlanCostReport::~VPlanCostReport() { print(errs()); }

static void printIDs(raw_ostream &OS, ArrayRef<bool> IDs) {
  ListSeparator Sep;
  for (unsigned I = 0; I < IDs.size(); ++I) {
    if (!IDs[I])
      continue;
    unsigned Start = I;
    while (I + 1 < IDs.size() && IDs[I + 1])
      ++I;
    OS << Sep << 'R' << Start;
    if (I != Start)
      OS << "-R" << I;
  }
}

void VPlanCostReport::print(raw_ostream &OS) const {
  OS << Header << "  scalar-baseline cost=";
  if (ScalarBaseline)
    OS << *ScalarBaseline;
  else
    OS << "not-evaluated";
  OS << "\n  candidates:\n"
        "    phase | plan | vf | estimated_width | body_cost | score | "
        "score_kind | vs_incumbent | vs_scalar | reason\n";
  auto PrintComparison = [&](const ComparisonRecord &C) {
    if (!C.Result) {
      OS << "not-evaluated";
      return;
    }
    OS << (*C.Result ? "yes" : "no") << " (" << C.Against << "; " << C.Reason
       << ')';
  };
  for (const auto &C : Candidates) {
    OS << "    " << (C.Epilogue ? "epilogue" : "main") << " | " << C.PlanID
       << " | ";
    printVF(OS, C.VF);
    OS << " | " << C.EstimatedWidth << " | ";
    if (C.BodyCost)
      OS << *C.BodyCost;
    else
      OS << "not-evaluated";
    OS << " | ";
    if (C.Score) {
      OS << *C.Score;
      if (C.ScoreKind == "cost-per-lane" && C.Score->isValid())
        OS << '/' << C.ScoreDivisor;
    } else
      OS << "not-evaluated";
    OS << " | " << C.ScoreKind << " | ";
    PrintComparison(C.Incumbent);
    OS << " | ";
    PrintComparison(C.Scalar);
    OS << " | " << (C.Reason.empty() ? "-" : C.Reason) << '\n';
  }
  if (Candidates.empty())
    OS << "    none\n";
  for (const auto &[Text, Count] : Diagnostics) {
    OS << StringRef(Text).rtrim();
    if (Count > 1)
      OS << " occurrences=" << Count;
    OS << '\n';
  }
  auto PrintSelection = [&](StringRef Name,
                            const std::optional<SelectionRecord> &S) {
    OS << "  selected-for-" << Name;
    if (!S) {
      OS << " plan=none vf=not-evaluated\n";
      return;
    }
    OS << " plan=" << S->PlanID << " vf=";
    printVF(OS, S->VF);
    if (S->SourcePlan)
      OS << " source_plan=" << *S->SourcePlan << " cost=reused";
    if (!S->Reason.empty())
      OS << " reason=" << S->Reason;
    OS << '\n';
  };
  PrintSelection("main", MainSelection);
  PrintSelection("epilogue", EpilogueSelection);
  OS << "  selected_interleave_count=";
  if (InterleaveCount)
    OS << *InterleaveCount;
  else
    OS << "not-evaluated";
  if (!InterleaveReason.empty())
    OS << " reason=" << InterleaveReason;
  OS << "\n  outcome="
     << (Plans.empty() ? "no-plan"
         : Emitted     ? "vectorization-emitted"
                       : "vectorization-rejected")
     << '\n';
  if (Detailed) {
    OS << "  details:\n";
    for (auto [ID, P] : enumerate(Plans)) {
      OS << "  plan=" << ID << '\n' << P->Snapshot;
      SmallVector<ElementCount> VFs;
      for (const auto &E : P->Evaluations)
        if (!is_contained(VFs, E->VF))
          VFs.push_back(E->VF);
      for (ElementCount VF : VFs) {
        OS << "    costs vf=";
        printVF(OS, VF);
        OS << '\n';
        for (const auto &E : P->Evaluations) {
          if (E->VF != VF)
            continue;
          OS << "    evaluation=" << E->ID << " plan=" << ID << " vf=";
          printVF(OS, VF);
          OS << " phase=" << E->Phase << '\n' << E->Events;
        }
      }
    }
    for (const auto &C : Candidates)
      if (C.MaxTripCount) {
        OS << "    ranking-context plan=" << C.PlanID << " vf=";
        printVF(OS, C.VF);
        OS << " phase=" << (C.Epilogue ? "epilogue" : "main")
           << " maximum_trip_count=" << *C.MaxTripCount
           << " has_tail=" << C.HasTail << '\n';
      }
    OS << Events;
  }
  OS << "End VPlan report\n";
}

void VPlanCostReport::addDiagnostic(std::string Text) {
  for (auto &D : Diagnostics)
    if (D.first == Text) {
      ++D.second;
      return;
    }
  Diagnostics.emplace_back(std::move(Text), 1);
}

VPlanCostReport::CandidateRecord &
VPlanCostReport::candidate(const VPlan &Plan, ElementCount VF, bool Epilogue) {
  unsigned ID = registerPlan(Plan);
  for (auto &C : Candidates)
    if (C.PlanID == ID && C.VF == VF && C.Epilogue == Epilogue)
      return C;
  Candidates.emplace_back(ID, VF, Epilogue,
                          VF.getKnownMinValue() *
                              (VF.isScalable() ? TuningVScale : 1));
  return Candidates.back();
}

void VPlanCostReport::bodyCost(const VPlan &Plan, ElementCount VF,
                               InstructionCost Cost) {
  // Outside-loop and interleave evaluations must not replace ranking costs.
  if (Phase == "main-selection" || Phase == "candidate-validation")
    candidate(Plan, VF).BodyCost = Cost;
}

void VPlanCostReport::skip(const VPlan &Plan, ElementCount VF, StringRef Reason,
                           bool Epilogue) {
  candidate(Plan, VF, Epilogue).Reason = Reason.str();
  Comparing.reset();
}

void VPlanCostReport::select(const VPlan &Plan, ElementCount VF,
                             StringRef Reason, const VPlan *Source) {
  SelectionRecord S{registerPlan(Plan), VF, std::nullopt, Reason.str()};
  if (Source) {
    S.SourcePlan = registerPlan(*Source);
    EpilogueSelection = std::move(S);
    if (!Reason.empty())
      candidate(*Source, VF, true).Reason = Reason.str();
  } else {
    MainSelection = std::move(S);
    if (!Reason.empty())
      candidate(Plan, VF).Reason = Reason.str();
  }
}

void VPlanCostReport::interleave(unsigned Count, StringRef Reason, bool Final) {
  if (Final)
    InterleaveCount = Count;
  if (!Reason.empty())
    InterleaveReason = Reason.str();
}

void VPlanCostReport::beginComparison(const VPlan &Plan, ElementCount VF,
                                      InstructionCost Cost,
                                      const VPlan *Incumbent,
                                      ElementCount IncumbentVF, bool Scalar,
                                      bool Epilogue) {
  auto &C = candidate(Plan, VF, Epilogue);
  C.BodyCost = Cost;
  Comparing = &C - Candidates.data();
  ComparingScalar = Scalar;
  ComparedIncumbent.reset();
  if (Incumbent && !IncumbentVF.isScalar())
    for (auto [I, Other] : enumerate(Candidates))
      if (Other.PlanID == registerPlan(*Incumbent) && Other.VF == IncumbentVF &&
          Other.Epilogue == Epilogue) {
        ComparedIncumbent = I;
        break;
      }
  auto &Comparison = Scalar ? C.Scalar : C.Incumbent;
  raw_string_ostream OS(Comparison.Against);
  if (Scalar)
    OS << "scalar";
  else if (Incumbent) {
    OS << "plan=" << registerPlan(*Incumbent) << " vf=";
    printVF(OS, IncumbentVF);
  } else
    OS << "none";
}

void VPlanCostReport::comparisonContext(unsigned MaxTripCount, bool HasTail) {
  if (!Comparing)
    return;
  auto &C = Candidates[*Comparing];
  C.MaxTripCount = MaxTripCount;
  C.HasTail = HasTail;
}

void VPlanCostReport::comparisonScore(InstructionCost Score,
                                      InstructionCost IncumbentScore,
                                      StringRef Kind, unsigned Divisor,
                                      unsigned IncumbentDivisor) {
  if (!Comparing)
    return;
  auto &C = Candidates[*Comparing];
  C.Score = Score;
  C.ScoreKind = Kind.str();
  C.ScoreDivisor = Divisor;
  // The first epilogue candidate bypasses comparison, but its score may be
  // observed later when it is the incumbent. Do not evaluate it just to print.
  if (ComparedIncumbent) {
    auto &B = Candidates[*ComparedIncumbent];
    if (!B.Score) {
      B.Score = IncumbentScore;
      B.ScoreKind = Kind.str();
      B.ScoreDivisor = IncumbentDivisor;
      B.MaxTripCount = C.MaxTripCount;
      B.HasTail = C.HasTail;
    }
  }
}

void VPlanCostReport::comparisonResult(bool Result, StringRef Reason) {
  if (!Comparing)
    return;
  auto &C = Candidates[*Comparing];
  auto &Comparison = ComparingScalar ? C.Scalar : C.Incumbent;
  Comparison.Result = Result;
  Comparison.Reason = Reason.str();
  Comparing.reset();
}

unsigned VPlanCostReport::registerPlan(const VPlan &Plan) {
  auto It = PlanIDs.find(&Plan);
  if (It != PlanIDs.end())
    return It->second;
  unsigned ID = Plans.size();
  PlanIDs[&Plan] = ID;
  auto P = std::make_unique<PlanRecord>();
  for (const VPBasicBlock *BB : VPBlockUtils::blocksOnly<const VPBasicBlock>(
           vp_depth_first_deep(Plan.getEntry())))
    for (const VPRecipeBase &R : *BB) {
      unsigned RID = P->Recipes.size();
      P->Recipes[&R] = RID;
    }
#if !defined(NDEBUG) || defined(LLVM_ENABLE_DUMP)
  if (Detailed) {
    raw_string_ostream OS(P->Snapshot);
    OS << "    tail_folded=" << Plan.hasTailFolded()
       << " scalar_tail=" << Plan.hasScalarTail() << '\n';
    Plan.print(OS, &P->Recipes);
  }
#endif
  Plans.push_back(std::move(P));
  return ID;
}

void VPlanCostReport::beginEvaluation(const VPlan &Plan, ElementCount VF) {
  assert(!Active && "nested cost evaluation");
  unsigned ID = registerPlan(Plan);
  auto E = std::make_unique<EvaluationRecord>();
  E->ID = nextEvaluation();
  E->PlanID = ID;
  E->VF = VF;
  E->Phase = Phase.str();
  E->Visited.assign(Plans[ID]->Recipes.size(), false);
  E->SuccessfulChecks.assign(E->Visited.size(), false);
  Active = E.get();
  Plans[ID]->Evaluations.push_back(std::move(E));
  Contributes =
      Phase != "outside-loop-profitability" && Phase != "invalid-cost-remarks";
  RecipeScope = Contributes ? "vector-region" : Phase;
}

void VPlanCostReport::endEvaluation() {
  if (!Active)
    return;
  record([&](raw_ostream &OS) {
    unsigned Checks = count(Active->SuccessfulChecks, true);
    if (Checks) {
      OS << "      validity-checks passed=" << Checks << " recipes=";
      printIDs(OS, Active->SuccessfulChecks);
      OS << '\n';
    }
    SmallVector<bool> Unvisited;
    for (bool Visited : Active->Visited)
      Unvisited.push_back(!Visited);
    unsigned Missing = count(Unvisited, true);
    if (Missing) {
      OS << "      not-evaluated count=" << Missing << " recipes=";
      printIDs(OS, Unvisited);
      OS << '\n';
    }
  });
  Active = nullptr;
  Contributes = true;
}

void VPlanCostReport::beginRecipe(const VPRecipeBase &R) {
  if (!Active)
    return;
  auto It = Plans[Active->PlanID]->Recipes.find(&R);
  if (It == Plans[Active->PlanID]->Recipes.end())
    return;
  assert(!InRecipe && "nested recipe cost");
  Active->Visited[It->second] = true;
  InRecipe = true;
  RecipeEvents.clear();
  record([&](raw_ostream &OS) {
    OS << "      R" << It->second << " scope=" << RecipeScope << '\n';
  });
}

void VPlanCostReport::recipeReference(const VPRecipeBase &R) {
  if (!Active)
    return;
  auto It = Plans[Active->PlanID]->Recipes.find(&R);
  if (It != Plans[Active->PlanID]->Recipes.end())
    record([&](raw_ostream &OS) {
      OS << "        owner=R" << It->second << '\n';
    });
}

void VPlanCostReport::recipe(const VPRecipeBase &R, const Instruction *UI,
                             InstructionCost Cost, StringRef Source) {
  if (Active && !Cost.isValid())
    summary([&](raw_ostream &OS) {
      OS << "  invalid-cost plan=" << Active->PlanID << " vf=";
      printVF(OS, Active->VF);
      OS << " recipe=R" << Plans[Active->PlanID]->Recipes.lookup(&R)
         << " scope=" << RecipeScope << " source=" << Source;
      if (UI)
        OS << " ir=" << *UI;
      OS << '\n';
    });
  record([&](raw_ostream &OS) {
    OS << "        cost=" << Cost
       << " contribution=" << (Contributes ? Cost : InstructionCost(0))
       << " source=";
    if (Source == "induction" || Source == "non-backedge-branches" ||
        Source == "forced-scalar" || Source == "scalarization")
      OS << "precomputed owner=" << Source;
    else
      OS << Source;
    OS << " status=" << (Cost.isValid() ? "evaluated" : "invalid")
       << " coverage=" << (Source == "recipe" ? "expanded" : "opaque-legacy");
    if (UI)
      OS << " ir=" << *UI;
    OS << '\n';
  });
  if (InRecipe) {
    if (RecipeScope == "validity-only" && Cost.isValid())
      Active->SuccessfulChecks[Plans[Active->PlanID]->Recipes.lookup(&R)] =
          true;
    else
      Active->Events += RecipeEvents;
    InRecipe = false;
    RecipeEvents.clear();
  }
}

void VPlanCostReport::invalid(StringRef Reason) {
  summary([&](raw_ostream &OS) {
    OS << "  invalid-cost";
    if (Active) {
      OS << " plan=" << Active->PlanID << " vf=";
      printVF(OS, Active->VF);
    }
    OS << " reason=" << Reason << '\n';
  });
}

void VPlanCostReport::legacy(const Instruction *I, StringRef Category,
                             InstructionCost Cost) {
  if (!Cost.isValid())
    summary([&](raw_ostream &OS) {
      OS << "  invalid-cost";
      if (Active) {
        OS << " plan=" << Active->PlanID << " vf=";
        printVF(OS, Active->VF);
      }
      OS << " source=legacy category=" << Category << " ir=" << *I << '\n';
    });
  record([&](raw_ostream &OS) {
    OS << "      legacy category=" << Category << " contribution=" << Cost
       << " ir=" << *I << '\n';
  });
}

void VPlanCostReport::backendWidth(const VPlan &Plan, ElementCount VF,
                                   unsigned Width) {
  candidate(Plan, VF, false).EstimatedWidth = Width;
}
