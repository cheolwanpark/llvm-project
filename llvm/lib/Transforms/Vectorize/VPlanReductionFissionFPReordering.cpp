//===- VPlanReductionFissionFPReordering.cpp - FP reassociation ----------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "VPlanReductionFissionFPReordering.h"
#include "VPlan.h"
#include "VPlanCFG.h"
#include "VPlanReductionFission.h"
#include "llvm/ADT/PostOrderIterator.h"
#include "llvm/Analysis/LoopAccessAnalysis.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/ScalarEvolution.h"
#include "llvm/Analysis/TargetTransformInfo.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Transforms/Vectorize/LoopVectorizationLegality.h"

using namespace llvm;

static cl::opt<bool> VPlanReductionFissionAllowFPReordering(
    "vplan-reduction-fission-allow-fp-reordering", cl::init(false), cl::Hidden,
    cl::desc("Allow reassociation of FP sums in reduction-fission candidates "
             "only (does not imply nnan, ninf, nsz or contract)"));

bool FissionFPReorderingPolicy::isEnabled() {
  return isReductionFissionEnabled() && VPlanReductionFissionAllowFPReordering;
}

bool FissionFPReorderingPolicy::shouldAttempt(const Loop &L,
                                              const LoopVectorizeHints &Hints,
                                              bool OptForSize) {
  return isEnabled() && L.isInnermost() && !Hints.getWidth() &&
         Hints.getInterleave() <= 1 && !OptForSize && L.getNumBlocks() == 1 &&
         !L.getHeader()->getParent()->hasFnAttribute(Attribute::StrictFP);
}

std::optional<FissionFPReorderingPolicy> FissionFPReorderingPolicy::create(
    const Loop &L, LoopVectorizationLegality &Legal,
    const PredicatedScalarEvolution &PSE, const LoopVectorizeHints &Hints,
    bool AllowOrderedReductions) {
  if (!isEnabled() ||
      L.getHeader()->getParent()->hasFnAttribute(Attribute::StrictFP) ||
      !Legal.canVectorizeFPMath(true) || !PSE.getPredicate().isAlwaysTrue() ||
      !Legal.getLAI()->getRuntimePointerChecking()->getChecks().empty() ||
      !Legal.getLAI()->getSymbolicStrides().empty())
    return std::nullopt;
  FissionFPReorderingPolicy Policy;
  for (const auto &[Phi, Rdx] : Legal.getReductionVars())
    if (isSupportedFissionFAdd(*Phi, Rdx, L))
      Policy.Reductions.insert({Phi, Rdx.getLoopExitInstr()});
  if (Policy.Reductions.empty())
    return std::nullopt;
  for (const auto &[Phi, Rdx] : Legal.getReductionVars())
    if (Rdx.hasExactFPMath() && !Hints.allowReordering() &&
        !Policy.allows(Phi) && !(AllowOrderedReductions && Rdx.isOrdered()))
      return std::nullopt;
  return Policy;
}

bool FissionFPReorderingPolicy::allows(const RecurrenceDescriptor &Rdx) const {
  return any_of(Reductions, [&](const auto &Reduction) {
    return Reduction.second == Rdx.getLoopExitInstr();
  });
}

bool FissionFPReorderingPolicy::isLegalToVectorizeReduction(
    const RecurrenceDescriptor &Rdx, ElementCount VF,
    const TargetTransformInfo &TTI) const {
  if (!allows(Rdx))
    return TTI.isLegalToVectorizeReduction(Rdx, VF);

  FastMathFlags FMF = Rdx.getFastMathFlags();
  FMF.setAllowReassoc();
  RecurrenceDescriptor Relaxed(Rdx.getRecurrenceStartValue(),
                               Rdx.getLoopExitInstr(), nullptr, RecurKind::FAdd,
                               FMF, nullptr, Rdx.getRecurrenceType());
  return TTI.isLegalToVectorizeReduction(Relaxed, VF);
}

void FissionFPReorderingPolicy::applyToPlan(VPlan &Plan) const {
  ReversePostOrderTraversal<VPBlockDeepTraversalWrapper<VPBlockBase *>> RPOT(
      Plan.getEntry());
  for (VPBasicBlock *VPBB : VPBlockUtils::blocksOnly<VPBasicBlock>(RPOT)) {
    for (VPRecipeBase &R : make_early_inc_range(*VPBB)) {
      auto *Phi = dyn_cast<VPReductionPHIRecipe>(&R);
      if (!Phi || !allows(dyn_cast_or_null<PHINode>(Phi->getUnderlyingValue())))
        continue;
      auto *Add = cast<VPInstruction>(Phi->getBackedgeValue());
      assert(Add->getOpcode() == Instruction::FAdd &&
             "only independently classified single fadd recurrences");
      FastMathFlags FMF = Phi->getFastMathFlagsOrNone();
      FMF.setAllowReassoc();
      auto *Relaxed = new VPReductionPHIRecipe(
          cast<PHINode>(Phi->getUnderlyingValue()), RecurKind::FAdd,
          *Phi->getStartValue(), *Add, RdxUnordered{1}, FMF);
      Relaxed->insertBefore(Phi);
      Phi->replaceAllUsesWith(Relaxed);
      Phi->eraseFromParent();
      FMF = Add->getFastMathFlagsOrNone();
      FMF.setAllowReassoc();
      VPIRFlags Flags(FMF);
      Add->transferFlags(Flags);
    }
  }
}
