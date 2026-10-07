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
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/IR/Module.h"
#include "llvm/Transforms/Vectorize/LoopVectorizationLegality.h"

using namespace llvm;

VPlanCostReport::VPlanCostReport(const Loop &L,
                                 const VFSelectionContext &Config,
                                 unsigned Invocation, unsigned LoopIndex,
                                 bool Detailed)
    : Detailed(Detailed) {
  const Function &F = *L.getHeader()->getParent();
  raw_string_ostream OS(Header);
  OS << "VPlan report_version=1 module=" << F.getParent()->getModuleIdentifier()
     << " invocation=" << Invocation << " function=" << F.getName()
     << " loop=" << LoopIndex << " header=" << L.getHeader()->getName()
     << " depth=" << (Detailed ? 2 : 1) << "\n";
  OS << "  target=" << F.getParent()->getTargetTriple().str()
     << " cpu=" << F.getFnAttribute("target-cpu").getValueAsString()
     << " features=" << F.getFnAttribute("target-features").getValueAsString()
     << "\n  cost_kind=";
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

VPlanCostReport::~VPlanCostReport() {
  errs() << Header;
  for (auto [ID, P] : enumerate(Plans))
    errs() << "  plan=" << ID << '\n' << P->Snapshot << P->Events;
  errs() << Events;
  if (Plans.empty())
    errs() << "  outcome=no-plan\n";
  errs() << "  outcome="
         << (Emitted ? "vectorization-emitted" : "vectorization-rejected")
         << "\nEnd VPlan report\n";
}

unsigned VPlanCostReport::registerPlan(const VPlan &Plan) {
  auto It = PlanIDs.find(&Plan);
  if (It != PlanIDs.end())
    return It->second;
  unsigned ID = Plans.size();
  PlanIDs[&Plan] = ID;
  auto P = std::make_unique<PlanRecord>();
#if !defined(NDEBUG) || defined(LLVM_ENABLE_DUMP)
  raw_string_ostream OS(P->Snapshot);
  OS << "    tail_folded=" << Plan.hasTailFolded()
     << " scalar_tail=" << Plan.hasScalarTail() << '\n';
  Plan.print(OS);
  VPSlotTracker Slots(&Plan);
  OS << "    recipe_inventory:\n";
  for (const VPBasicBlock *BB : VPBlockUtils::blocksOnly<const VPBasicBlock>(
           vp_depth_first_deep(Plan.getEntry()))) {
    for (const VPRecipeBase &R : *BB) {
      unsigned RID = P->Recipes.size();
      P->Recipes[&R] = RID;
      OS << "      R" << RID << " block=" << BB->getName() << " ";
      R.print(OS, "", Slots);
      OS << '\n';
    }
  }
#endif
  Plans.push_back(std::move(P));
  return ID;
}

void VPlanCostReport::beginEvaluation(const VPlan &Plan, ElementCount VF) {
  assert(!Active && "nested cost evaluation");
  unsigned ID = registerPlan(Plan);
  Active = Plans[ID].get();
  Active->Visited.assign(Active->Recipes.size(), false);
  Contributes =
      Phase != "outside-loop-profitability" && Phase != "invalid-cost-remarks";
  RecipeScope = Contributes ? "vector-region" : Phase;
  unsigned EvaluationID = nextEvaluation();
  Evaluations[{&Plan, VF}] = EvaluationID;
  record([&](raw_ostream &OS) {
    OS << "    evaluation=" << EvaluationID << " plan=" << ID << " vf=";
    printVF(OS, VF);
    OS << " phase=" << Phase << '\n';
  });
}

void VPlanCostReport::endEvaluation() {
  if (!Active)
    return;
  record([&](raw_ostream &OS) {
    for (auto [ID, Visited] : enumerate(Active->Visited))
      if (!Visited)
        OS << "      R" << ID << " status=not-evaluated\n";
  });
  Active = nullptr;
  Contributes = true;
}

void VPlanCostReport::beginRecipe(const VPRecipeBase &R) {
  if (!Active)
    return;
  auto It = Active->Recipes.find(&R);
  if (It == Active->Recipes.end())
    return;
  Active->Visited[It->second] = true;
  record([&](raw_ostream &OS) {
    OS << "      R" << It->second << " scope=" << RecipeScope << '\n';
  });
}

void VPlanCostReport::recipeReference(const VPRecipeBase &R) {
  if (!Active)
    return;
  auto It = Active->Recipes.find(&R);
  if (It != Active->Recipes.end())
    record([&](raw_ostream &OS) {
      OS << "        owner=R" << It->second << '\n';
    });
}

void VPlanCostReport::recipe(const VPRecipeBase &R, const Instruction *UI,
                             InstructionCost Cost, StringRef Source) {
  record([&](raw_ostream &OS) {
    OS << "        cost=" << Cost
       << " contribution=" << (Contributes ? Cost : InstructionCost(0))
       << " source=";
    if (Source == "induction" || Source == "non-backedge-branches" ||
        Source == "forced-scalar" || Source == "scalarization")
      OS << "precomputed owner=" << Source;
    else
      OS << Source;
    OS << " status=" << (Cost.isValid() ? "evaluated" : "invalid");
    if (Detailed)
      OS << " coverage=" << (Source == "recipe" ? "expanded" : "opaque-legacy");
    if (UI)
      OS << " ir=" << *UI;
    OS << '\n';
  });
}

void VPlanCostReport::legacy(const Instruction *I, StringRef Category,
                             InstructionCost Cost) {
  record([&](raw_ostream &OS) {
    OS << "      legacy category=" << Category << " contribution=" << Cost
       << " ir=" << *I << '\n';
  });
}
