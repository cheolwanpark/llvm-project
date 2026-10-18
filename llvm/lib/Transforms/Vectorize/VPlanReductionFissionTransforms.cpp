//===- VPlanReductionFissionTransforms.cpp - Fission stages ---------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "LoopVectorizationPlanner.h"
#include "VPlan.h"
#include "VPlanCFG.h"
#include "VPlanHelpers.h"
#include "VPlanReductionFission.h"
#include "VPlanUtils.h"
#include "llvm/ADT/PostOrderIterator.h"
#include "llvm/Analysis/ScalarEvolutionExpressions.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/DataLayout.h"
#include "llvm/Support/Errc.h"
#include "llvm/Support/MathExtras.h"
#include <functional>
#include <limits>

using namespace llvm;

namespace {

SmallVector<VPRecipeBase *, 32> collectRecipes(VPlan &Plan) {
  SmallVector<VPRecipeBase *, 32> Result;
  ReversePostOrderTraversal<VPBlockDeepTraversalWrapper<VPBlockBase *>> RPOT(
      Plan.getEntry());
  for (VPBasicBlock *VPBB : VPBlockUtils::blocksOnly<VPBasicBlock>(RPOT))
    for (VPRecipeBase &Recipe : *VPBB)
      Result.push_back(&Recipe);
  return Result;
}

// Inspect loop control without calling getOrCreateCanonicalIVIncrement: a
// rejected candidate must leave even the baseline's recipe list unchanged.
const VPRecipeBase *getCanonicalIncrement(VPlan &Plan) {
  auto *Region = Plan.getVectorLoopRegion();
  for (VPUser *U : Region->getCanonicalIV()->users()) {
    auto *I = dyn_cast<VPInstruction>(U);
    if (I && I->getOpcode() == Instruction::Add && I->getNumOperands() == 2 &&
        I->getOperand(0) == Region->getCanonicalIV() &&
        I->getOperand(1) == &Plan.getVFxUF())
      return I;
  }
  return nullptr;
}

struct StagePlanBuildResult {
  std::unique_ptr<VPlan> Plan;
  DenseMap<VPValue *, VPValue *> Values;
  DenseMap<const VPRecipeBase *, VPRecipeBase *> Recipes;
  SmallVector<std::pair<VPValue *, VPValue *>, 8> PostLoopValues;
};

// Stages execute only full vector chunks. Tail predicates inherited from the
// baseline are always true here; data-dependent predicates must be preserved.
VPValue *removeStageTailPredication(StagePlanBuildResult &Stage) {
  VPlan &Plan = *Stage.Plan;
  VPBasicBlock *Body = Plan.getVectorLoopRegion()->getEntryBasicBlock();
  VPValue *Mask = Plan.getOrAddLiveIn(ConstantInt::getTrue(Plan.getContext()));
  for (VPRecipeBase &R : make_early_inc_range(*Body))
    if (auto *I = dyn_cast<VPInstruction>(&R);
        I && I->getOpcode() == VPInstruction::ActiveLaneMask) {
      I->replaceAllUsesWith(Mask);
      I->eraseFromParent();
    }
  for (VPRecipeBase &R : make_early_inc_range(*Body)) {
    auto *Select = dyn_cast<VPInstruction>(&R);
    if (!Select || Select->getOpcode() != Instruction::Select ||
        Select->getOperand(0) != Mask)
      continue;
    VPValue *ActiveValue = Select->getOperand(1);
    Select->replaceAllUsesWith(ActiveValue);
    for (auto &Entry : Stage.Values)
      if (Entry.second == Select)
        Entry.second = ActiveValue;
    for (auto &Entry : Stage.Recipes)
      if (Entry.second == Select)
        Entry.second = ActiveValue->getDefiningRecipe();
    Select->eraseFromParent();
  }

  for (VPRecipeBase &R : make_early_inc_range(*Body)) {
    if (auto *Group = dyn_cast<VPInterleaveRecipe>(&R);
        Group && Group->getMask() == Mask) {
      auto *Unmasked = new VPInterleaveRecipe(
          Group->getInterleaveGroup(), Group->getAddr(), {}, nullptr, false,
          *Group, Group->getDebugLoc());
      Unmasked->insertBefore(Group);
      for (auto [Old, New] :
           zip(Group->definedValues(), Unmasked->definedValues())) {
        Old->replaceAllUsesWith(New);
        for (auto &Entry : Stage.Values)
          if (Entry.second == Old)
            Entry.second = New;
      }
      for (auto &Entry : Stage.Recipes)
        if (Entry.second == Group)
          Entry.second = Unmasked;
      Group->eraseFromParent();
      continue;
    }
    if (auto *Reduction = dyn_cast<VPReductionRecipe>(&R);
        Reduction && Reduction->getCondOp() == Mask) {
      auto *Unmasked = new VPReductionRecipe(
          Reduction->getRecurrenceKind(), Reduction->getFastMathFlagsOrNone(),
          Reduction->getUnderlyingInstr(), Reduction->getChainOp(),
          Reduction->getVecOp(), nullptr,
          Reduction->isOrdered() ? ReductionStyle(RdxOrdered{})
                                 : ReductionStyle(RdxInLoop{}),
          Reduction->getDebugLoc());
      Unmasked->insertBefore(Reduction);
      Reduction->replaceAllUsesWith(Unmasked);
      for (auto &Entry : Stage.Values)
        if (Entry.second == Reduction)
          Entry.second = Unmasked;
      for (auto &Entry : Stage.Recipes)
        if (Entry.second == Reduction)
          Entry.second = Unmasked;
      Reduction->eraseFromParent();
      continue;
    }
    if (auto *Store = dyn_cast<VPWidenStoreRecipe>(&R);
        Store && Store->getMask() == Mask) {
      auto *Unmasked = new VPWidenStoreRecipe(
          cast<StoreInst>(Store->getIngredient()), Store->getAddr(),
          Store->getStoredValue(), nullptr, Store->isConsecutive(), *Store,
          Store->getDebugLoc());
      Unmasked->insertBefore(Store);
      for (auto &Entry : Stage.Recipes)
        if (Entry.second == Store)
          Entry.second = Unmasked;
      Store->eraseFromParent();
      continue;
    }
    auto *Load = dyn_cast<VPWidenLoadRecipe>(&R);
    if (!Load || Load->getMask() != Mask)
      continue;
    auto *Unmasked = new VPWidenLoadRecipe(
        cast<LoadInst>(Load->getIngredient()), Load->getAddr(), nullptr,
        Load->isConsecutive(), *Load, Load->getDebugLoc());
    Unmasked->insertBefore(Load);
    Load->replaceAllUsesWith(Unmasked);
    for (auto &Entry : Stage.Values)
      if (Entry.second == Load)
        Entry.second = Unmasked;
    for (auto &Entry : Stage.Recipes)
      if (Entry.second == Load)
        Entry.second = Unmasked;
    Load->eraseFromParent();
  }

  return Mask;
}

Expected<StagePlanBuildResult> buildStagePlan(
    VPlan &Baseline, const SmallPtrSetImpl<const VPRecipeBase *> &Selected,
    ArrayRef<VPValue *> AllowedCrossings, ArrayRef<ElementCount> CandidateVFs) {
  StagePlanBuildResult Result;
  Result.Plan = std::make_unique<VPlan>(
      Baseline.getScalarHeader()->getIRBasicBlock(), Baseline.getIndexType());
  VPlan &Stage = *Result.Plan;
  while (!Stage.getScalarHeader()->empty())
    Stage.getScalarHeader()->back().eraseFromParent();

  // Preserve the original preheader wrapper when available.  The scalar
  // header itself is an empty continuation: stage preview legality concerns
  // the independently vectorized region, not a duplicate scalar fallback.
  BasicBlock *ScalarHeaderIRBB = Baseline.getScalarHeader()->getIRBasicBlock();
  BasicBlock *IRPreheader = nullptr;
  for (BasicBlock *Pred : predecessors(ScalarHeaderIRBB))
    if (Pred != ScalarHeaderIRBB) {
      IRPreheader = Pred;
      break;
    }
  if (IRPreheader) {
    // Preheader computations remain in the original IR and are stage live-ins.
    // The second stage rebinds this wrapper to its incoming block; do not keep
    // recipes that wrap instructions belonging to the original preheader.
    Stage.setEntry(Stage.createEmptyVPIRBasicBlock(IRPreheader));
  }

  for (VPValue *LiveIn : Baseline.getLiveIns())
    Result.Values[LiveIn] = Stage.getOrAddLiveIn(LiveIn->getLiveInIRValue());
  Result.Values[&Baseline.getVF()] = &Stage.getVF();
  Result.Values[&Baseline.getUF()] = &Stage.getUF();
  if (auto *BTC = Baseline.getBackedgeTakenCount())
    Result.Values[BTC] = Stage.getOrCreateBackedgeTakenCount();
  Result.Values[&Baseline.getVFxUF()] = &Stage.getVFxUF();
  Result.Values[&Baseline.getVectorTripCount()] = &Stage.getVectorTripCount();

  VPBasicBlock *VectorPH = Stage.createVPBasicBlock("vector.ph");
  VPBasicBlock *Body = Stage.createVPBasicBlock("vector.body");
  VPRegionBlock *Region = Stage.createLoopRegion(Baseline.getIndexType(), {},
                                                 "vector loop", Body, Body);
  Result.Values[Baseline.getVectorLoopRegion()->getCanonicalIV()] =
      Region->getCanonicalIV();
  if (auto *Mask = Baseline.getVectorLoopRegion()->getHeaderMask())
    Result.Values[Mask] = Stage.getTrue();
  VPBasicBlock *Middle = Stage.createVPBasicBlock("middle.block");
  VPBasicBlock *ScalarPH = Stage.createVPBasicBlock("scalar.ph");
  VPBlockUtils::connectBlocks(Stage.getEntry(), VectorPH);
  VPBlockUtils::connectBlocks(VectorPH, Region);
  VPBlockUtils::connectBlocks(Region, Middle);
  VPBlockUtils::connectBlocks(Middle, ScalarPH);
  VPBlockUtils::connectBlocks(ScalarPH, Stage.getScalarHeader());

  SmallVector<std::pair<const VPRecipeBase *, VPRecipeBase *>, 32> Clones;
  const VPRecipeBase *CanonicalBackedge = getCanonicalIncrement(Baseline);
  VPBasicBlock *BaselineBody =
      Baseline.getVectorLoopRegion()->getEntryBasicBlock();
  SmallPtrSet<const VPRecipeBase *, 32> RecipesToClone(Selected.begin(),
                                                       Selected.end());
  for (VPRecipeBase &Recipe : *BaselineBody) {
    bool IsLoopControl = &Recipe == CanonicalBackedge ||
                         (isa<VPInstruction>(&Recipe) &&
                          (cast<VPInstruction>(&Recipe)->getOpcode() ==
                               VPInstruction::BranchOnCount ||
                           cast<VPInstruction>(&Recipe)->getOpcode() ==
                               VPInstruction::ActiveLaneMask));
    if (IsLoopControl)
      RecipesToClone.insert(&Recipe);
  }
  SmallVector<const VPRecipeBase *, 32> Worklist(RecipesToClone.begin(),
                                                 RecipesToClone.end());
  for (unsigned I = 0; I != Worklist.size(); ++I)
    for (VPValue *Operand : Worklist[I]->operands())
      if (VPRecipeBase *Def = Operand->getDefiningRecipe();
          Def && Def->getParent() == BaselineBody &&
          !is_contained(AllowedCrossings, Operand) &&
          RecipesToClone.insert(Def).second)
        Worklist.push_back(Def);

  for (VPRecipeBase &Recipe : *BaselineBody) {
    if (!RecipesToClone.contains(&Recipe))
      continue;
    VPRecipeBase *Clone = Recipe.clone();
    if (auto *IV = dyn_cast<VPWidenIntOrFpInductionRecipe>(Clone))
      IV->dropPoisonGeneratingFlags();
    Body->appendRecipe(Clone);
    Result.Recipes[&Recipe] = Clone;
    Clones.push_back({&Recipe, Clone});
    for (auto [OldValue, NewValue] :
         zip(Recipe.definedValues(), Clone->definedValues()))
      // A multi-result recipe may also be needed for a different, non-scratch
      // member. Its cloned results must not bypass a selected scratch crossing.
      if (!is_contained(AllowedCrossings, OldValue))
        Result.Values[OldValue] = NewValue;
  }

  // Materialize dependencies defined outside the vector body (for example,
  // reduction start vectors in vector.ph) before remapping body operands.
  // Never leave a stage operand referring into the baseline VPlan.
  SmallPtrSet<VPValue *, 8> CrossingValues(AllowedCrossings.begin(),
                                           AllowedCrossings.end());
  std::function<Error(VPValue *)> MapExternalValue =
      [&](VPValue *OldValue) -> Error {
    if (Result.Values.contains(OldValue))
      return Error::success();
    if (CrossingValues.contains(OldValue))
      return Error::success();
    VPRecipeBase *OldRecipe = OldValue->getDefiningRecipe();
    if (!OldRecipe)
      return createStringError(errc::invalid_argument,
                               "unmapped non-live-in stage operand");
    if (OldRecipe->getParent() ==
        Baseline.getVectorLoopRegion()->getEntryBasicBlock())
      return createStringError(errc::invalid_argument,
                               "stage body dependency is outside partition");
    for (VPValue *Operand : OldRecipe->operands())
      if (Error E = MapExternalValue(Operand))
        return E;
    if (!all_of(OldRecipe->operands(), [&](VPValue *Operand) {
          return Result.Values.contains(Operand);
        }))
      return createStringError(errc::invalid_argument,
                               "scratch crossing is used outside stage body");
    VPRecipeBase *Clone = OldRecipe->clone();
    if (isa<VPExpandSCEVRecipe>(Clone))
      Stage.getEntry()->appendRecipe(Clone);
    else
      VectorPH->appendRecipe(Clone);
    Result.Recipes[OldRecipe] = Clone;
    for (unsigned I = 0, E = OldRecipe->getNumOperands(); I != E; ++I)
      Clone->setOperand(I, Result.Values.lookup(OldRecipe->getOperand(I)));
    for (auto [OldDef, NewDef] :
         zip(OldRecipe->definedValues(), Clone->definedValues()))
      Result.Values[OldDef] = NewDef;
    return Error::success();
  };
  if (VPValue *TC = Baseline.getTripCount()) {
    if (Error E = MapExternalValue(TC))
      return E;
    Stage.setTripCount(Result.Values.lookup(TC));
  }
  for (auto [OldRecipe, NewRecipe] : Clones)
    for (VPValue *Operand : OldRecipe->operands())
      if (!Result.Values.contains(Operand))
        if (Error E = MapExternalValue(Operand))
          return E;

  for (auto [OldRecipe, NewRecipe] : Clones)
    for (unsigned I = 0, E = OldRecipe->getNumOperands(); I != E; ++I)
      if (VPValue *Mapped = Result.Values.lookup(OldRecipe->getOperand(I)))
        NewRecipe->setOperand(I, Mapped);

  if (CanonicalBackedge && !Baseline.getVectorLoopRegion()->hasCanonicalIVNUW())
    Region->clearCanonicalIVNUW(
        cast<VPInstruction>(Result.Recipes.lookup(CanonicalBackedge)));

  // Clone the mapped post-loop closure.  Reduction finalization is therefore
  // present only in the accumulator stage, whose reduction phis and exiting
  // values are mapped; the producer stage naturally retains an empty middle
  // continuation.
  for (VPRecipeBase &Recipe : *Baseline.getMiddleBlock()) {
    // A stage always continues to the next stage/exit. The baseline's
    // conditional branch to a scalar epilogue has no counterpart here.
    if (&Recipe == Baseline.getMiddleBlock()->getTerminator())
      continue;
    if (!all_of(Recipe.operands(), [&](VPValue *Operand) {
          return Result.Values.contains(Operand);
        }))
      continue;
    VPRecipeBase *Clone = Recipe.clone();
    Middle->appendRecipe(Clone);
    Result.Recipes[&Recipe] = Clone;
    for (unsigned I = 0, E = Recipe.getNumOperands(); I != E; ++I)
      Clone->setOperand(I, Result.Values.lookup(Recipe.getOperand(I)));
    for (auto [OldValue, NewValue] :
         zip(Recipe.definedValues(), Clone->definedValues())) {
      Result.Values[OldValue] = NewValue;
      Result.PostLoopValues.push_back({OldValue, NewValue});
    }
  }

  for (ElementCount VF : CandidateVFs)
    if (VF.isVector())
      Stage.addVF(VF);
  if (Stage.vectorFactors().empty())
    return createStringError(errc::invalid_argument, "stage has no vector VF");
  return Result;
}

// Combine only private scratch contributions to an unflagged integer-add
// recurrence. This operates on a fresh stage candidate, never on the baseline.
// Keeping shared scratch values and short/non-scratch inputs untouched avoids
// undoing a shared producer waist (e.g. sin/cos) or moving short chains out of
// the accumulator loop.
void combineAddContributions(VPReductionFissionCandidate &Candidate) {
  auto *Producer =
      Candidate.ProducerPlan->getVectorLoopRegion()->getEntryBasicBlock();
  auto *Accumulator =
      Candidate.AccumulatorPlan->getVectorLoopRegion()->getEntryBasicBlock();
  unsigned NumSlots = Candidate.Scratch.Slots.size();
  SmallVector<VPFissionScratchStoreRecipe *> Stores(NumSlots, nullptr);
  SmallVector<VPFissionScratchLoadRecipe *> Loads(NumSlots, nullptr);
  DenseMap<const VPRecipeBase *, unsigned> ProducerOrder;
  unsigned Order = 0;
  for (VPRecipeBase &R : *Producer) {
    ProducerOrder[&R] = Order++;
    if (auto *Store = dyn_cast<VPFissionScratchStoreRecipe>(&R))
      Stores[Store->getSlotID()] = Store;
  }
  for (VPRecipeBase &R : *Accumulator)
    if (auto *Load = dyn_cast<VPFissionScratchLoadRecipe>(&R))
      Loads[Load->getSlotID()] = Load;

  auto IsTrue = [](VPValue *V) {
    auto *C = isa<VPIRValue>(V) ? dyn_cast<ConstantInt>(V->getLiveInIRValue())
                                : nullptr;
    return C && C->isOne();
  };
  auto GetAdd = [](VPValue *V) -> VPRecipeWithIRFlags * {
    auto *R = V->getDefiningRecipe();
    if (auto *I = dyn_cast_or_null<VPInstruction>(R);
        I && I->getOpcode() == Instruction::Add && !I->hasNoUnsignedWrap() &&
        !I->hasNoSignedWrap())
      return I;
    if (auto *I = dyn_cast_or_null<VPWidenRecipe>(R);
        I && I->getOpcode() == Instruction::Add && !I->hasNoUnsignedWrap() &&
        !I->hasNoSignedWrap())
      return I;
    return nullptr;
  };

  // Gather PHIs first: rewriting a recurrence may erase later body recipes.
  SmallVector<VPReductionPHIRecipe *> Phis;
  for (VPRecipeBase &R : *Accumulator)
    if (auto *Phi = dyn_cast<VPReductionPHIRecipe>(&R);
        Phi && Phi->getRecurrenceKind() == RecurKind::Add && !Phi->isInLoop() &&
        (Phi)->getScalarType()->isIntegerTy())
      Phis.push_back(Phi);

  bool Changed = false;
  for (auto *Phi : Phis) {
    VPValue *Root = Phi->getBackedgeValue();
    VPValue *V = Root;
    SmallVector<VPRecipeWithIRFlags *> Updates;
    SmallVector<unsigned> Slots;
    SmallPtrSet<VPValue *, 8> Seen;
    while (V != Phi && Seen.insert(V).second) {
      auto *Add = GetAdd(V);
      if (!Add || Add->getParent() != Accumulator ||
          Add->getNumOperands() != 2 || (V != Root && V->getNumUsers() != 1))
        break;
      unsigned Input = 0;
      auto *Load = dyn_cast<VPFissionScratchLoadRecipe>(Add->getOperand(0));
      if (!Load) {
        Input = 1;
        Load = dyn_cast<VPFissionScratchLoadRecipe>(Add->getOperand(1));
      }
      if (!Load || Load->getNumUsers() != 1 ||
          Load->getElementType() != (Phi)->getScalarType() ||
          !IsTrue(Load->getMask()) || is_contained(Slots, Load->getSlotID()))
        break;
      auto *Store = Stores[Load->getSlotID()];
      if (!Store || !IsTrue(Store->getMask()))
        break;
      Updates.push_back(Add);
      Slots.push_back(Load->getSlotID());
      V = Add->getOperand(1 - Input);
    }
    if (V != Phi || Slots.size() < 2)
      continue;

    // Preserve the contribution order, excluding the single occurrence of
    // the accumulator. Integer modular addition is associative; do NOT carry
    // over no-wrap flags or apply this to floating-point/fused updates.
    std::reverse(Slots.begin(), Slots.end());
    auto *LastStore = Stores[Slots.front()];
    for (unsigned ID : Slots)
      if (ProducerOrder[Stores[ID]] > ProducerOrder[LastStore])
        LastStore = Stores[ID];
    VPValue *Sum = Stores[Slots.front()]->getStoredValue();
    for (unsigned ID : drop_begin(Slots)) {
      auto *Add = new VPInstruction(
          Instruction::Add, {Sum, Stores[ID]->getStoredValue()},
          VPIRFlags::getDefaultFlags(Instruction::Add), VPIRMetadata(),
          DebugLoc(), "fission.contribution");
      Add->insertBefore(LastStore);
      Sum = Add;
    }
    unsigned Keep = *llvm::min_element(Slots);
    auto &Slot = Candidate.Scratch.Slots[Keep];
    auto *Store = new VPFissionScratchStoreRecipe(
        Keep, Slot.ElementType, Slot.Alignment, Stores[Keep]->getOperand(0),
        LastStore->getOperand(1), Sum, LastStore->getMask());
    Store->insertBefore(LastStore);
    auto *Load = new VPFissionScratchLoadRecipe(
        Keep, Slot.ElementType, Slot.Alignment, Loads[Keep]->getOperand(0),
        Loads[Keep]->getOperand(1), Loads[Keep]->getMask());
    Load->insertBefore(Updates.front());
    Updates.front()->setOperand(0, Phi);
    Updates.front()->setOperand(1, Load);
    // Updates are ordered from the root toward the PHI, so users disappear
    // before their definitions are erased.
    for (auto *Update : drop_begin(Updates))
      Update->eraseFromParent();
    for (unsigned ID : Slots) {
      Loads[ID]->eraseFromParent();
      Stores[ID]->eraseFromParent();
      Loads[ID] = nullptr;
      Stores[ID] = nullptr;
    }
    Loads[Keep] = Load;
    Stores[Keep] = Store;
    Slot.Frontier = Sum;
    Changed = true;
  }
  if (!Changed)
    return;

  // Compact slot IDs and bases together; vector and scalar execution use the
  // same scratch layout. Scalar companion plans are built only afterwards.
  VPScratchPlan Scratch;
  Candidate.Partition.FrontierValues.clear();
  for (unsigned ID = 0; ID != NumSlots; ++ID) {
    if (!Stores[ID])
      continue;
    unsigned NewID = Scratch.Slots.size();
    VPScratchSlot Slot = Candidate.Scratch.Slots[ID];
    Slot.Offset = alignTo(Scratch.TotalBytes, Slot.Alignment);
    Scratch.TotalBytes = Slot.Offset + Slot.Bytes;
    Scratch.Slots.push_back(Slot);
    Candidate.Partition.FrontierValues.push_back(Slot.Frontier);
    auto *OldStore = Stores[ID];
    auto *OldLoad = Loads[ID];
    auto *Store = new VPFissionScratchStoreRecipe(
        NewID, Slot.ElementType, Slot.Alignment, OldStore->getOperand(0),
        OldStore->getOperand(1), OldStore->getStoredValue(),
        OldStore->getMask());
    Store->insertBefore(OldStore);
    auto *Load = new VPFissionScratchLoadRecipe(
        NewID, Slot.ElementType, Slot.Alignment, OldLoad->getOperand(0),
        OldLoad->getOperand(1), OldLoad->getMask());
    Load->insertBefore(OldLoad);
    OldLoad->replaceAllUsesWith(Load);
    OldLoad->eraseFromParent();
    OldStore->eraseFromParent();
  }
  Candidate.Scratch = std::move(Scratch);
}

Expected<VPFissionScalarRemainder> buildScalarRemainder(VPlan &VectorPlan) {
  VPFissionScalarRemainder Remainder;
  DenseMap<VPValue *, VPValue *> Values;
  Remainder.Plan.reset(VectorPlan.duplicate(&Values));
  VPlan &Plan = *Remainder.Plan;
  Plan.addVF(ElementCount::getFixed(1));
  Plan.setVF(ElementCount::getFixed(1));
  for (VPRecipeBase &R :
       *VectorPlan.getVectorLoopRegion()->getEntryBasicBlock()) {
    auto *Phi = dyn_cast<VPReductionPHIRecipe>(&R);
    if (!Phi)
      continue;
    auto *Result = vputils::findComputeReductionResult(Phi);
    VPValue *Start = Phi->getStartValue();
    if (auto *StartVector = dyn_cast<VPInstruction>(Start);
        StartVector &&
        StartVector->getOpcode() == VPInstruction::ReductionStartVector)
      Start = StartVector->getOperand(0);
    if (!Result || !isa<VPIRValue>(Start) || Result->getNumOperands() != 1 ||
        (Phi->isInLoop() && Phi->getRecurrenceKind() != RecurKind::FAdd) ||
        Phi->getVFScaleFactor() != 1 ||
        Result->getOperand(0)->getScalarType() != Phi->getScalarType())
      return createStringError(errc::invalid_argument,
                               "unsupported scalar remainder reduction");
    auto *VectorExport = new VPFissionLiveOutRecipe(Result);
    auto *ScalarExport = new VPFissionLiveOutRecipe(Values.lookup(Result));
    VectorPlan.getMiddleBlock()->appendRecipe(VectorExport);
    Plan.getMiddleBlock()->appendRecipe(ScalarExport);
    Remainder.Reductions.push_back(
        {Result, cast<VPReductionPHIRecipe>(Values.lookup(Phi)), Start,
         VectorExport, ScalarExport});
  }
  for (VPRecipeBase &R : make_early_inc_range(
           *Plan.getVectorLoopRegion()->getEntryBasicBlock())) {
    VPSingleDefRecipe *Scalar = nullptr;
    if (auto *Interleave = dyn_cast<VPInterleaveRecipe>(&R)) {
      const auto *Group = Interleave->getInterleaveGroup();
      if (!Group->isFull() || Group->isReverse() || Interleave->getMask() ||
          Interleave->needsMaskForGaps() ||
          Interleave->getNumStoreOperands() != 0)
        return createStringError(errc::invalid_argument,
                                 "unsupported scalar remainder interleave");
      // getAddr() denotes member zero at this stage's current canonical
      // iteration, even if group construction adjusted another member's
      // address to form it. Recreate the original scalar loads with their own
      // alignment/metadata; never execute a Factor*VF load in the remainder.
      VPBuilder Builder(Interleave);
      const DataLayout &DL = Group->getInsertPos()->getDataLayout();
      for (auto [Index, Def] : enumerate(Interleave->definedValues())) {
        auto *Member = cast<LoadInst>(Group->getMember(Index));
        VPValue *Addr = Interleave->getAddr();
        if (Index != 0) {
          uint64_t Offset =
              Index * DL.getTypeAllocSize(Member->getType()).getFixedValue();
          Addr = Builder.createPtrAdd(
              Addr, Plan.getConstantInt(64, Offset), Member->getDebugLoc());
        }
        auto *Load = new VPReplicateRecipe(
            Member, {Addr}, true, nullptr, {}, VPIRMetadata(*Member),
            Member->getDebugLoc());
        Load->insertBefore(Interleave);
        Def->replaceAllUsesWith(Load);
      }
      Interleave->eraseFromParent();
      continue;
    }
    if (auto *Store = dyn_cast<VPWidenStoreRecipe>(&R)) {
      if (Store->getMask())
        return createStringError(errc::invalid_argument,
                                 "predicated scalar remainder store");
      auto *ScalarStore = new VPReplicateRecipe(
          &Store->getIngredient(), {Store->getStoredValue(), Store->getAddr()},
          true, nullptr, {}, *Store, Store->getDebugLoc());
      ScalarStore->insertBefore(Store);
      Store->eraseFromParent();
      continue;
    }
    if (auto *IV = dyn_cast<VPWidenIntOrFpInductionRecipe>(&R)) {
      if (IV->getInductionDescriptor().getKind() !=
          InductionDescriptor::IK_IntInduction)
        return createStringError(errc::invalid_argument,
                                 "unsupported scalar remainder induction");
      // Derive this stage's value from its canonical resume index, not from
      // the original start. Modular arithmetic also handles truncated IVs.
      auto *Body = Plan.getVectorLoopRegion()->getEntryBasicBlock();
      VPBuilder Builder(Body, Body->getFirstNonPhi());
      Type *Ty = IV->getScalarType();
      auto Cast = [&](VPValue *V) {
        return Builder.createScalarZExtOrTrunc(V, Ty, V->getScalarType(),
                                               IV->getDebugLoc());
      };
      VPValue *Index = Cast(Plan.getVectorLoopRegion()->getCanonicalIV());
      VPValue *Start = Cast(IV->getStartValue());
      VPValue *Step = Cast(IV->getStepValue());
      VPValue *Value = Builder.createNaryOp(
          Instruction::Add,
          {Start,
           Builder.createNaryOp(Instruction::Mul, {Step, Index},
                                VPIRFlags::getDefaultFlags(Instruction::Mul))},
          VPIRFlags::getDefaultFlags(Instruction::Add));
      IV->replaceAllUsesWith(Value);
      IV->eraseFromParent();
      continue;
    } else if (auto *Reduction = dyn_cast<VPReductionRecipe>(&R)) {
      if (Reduction->getRecurrenceKind() != RecurKind::FAdd ||
          Reduction->isConditional() || !Reduction->isInLoop())
        return createStringError(errc::invalid_argument,
                                 "unsupported scalar remainder reduction");
      // Unordered in-loop lowering is vector-only. The companion performs
      // exactly one scalar add for this original iteration.
      Scalar = new VPInstruction(
          Instruction::FAdd, {Reduction->getChainOp(), Reduction->getVecOp()},
          *Reduction, {}, Reduction->getDebugLoc());
    } else if (auto *Widen = dyn_cast<VPWidenRecipe>(&R)) {
      if (auto *I = dyn_cast_or_null<Instruction>(Widen->getUnderlyingValue()))
        Scalar = new VPReplicateRecipe(I, Widen->operands(), true, nullptr,
                                       *Widen, *Widen, Widen->getDebugLoc());
      else
        Scalar = new VPInstruction(Widen->getOpcode(), Widen->operands(),
                                   *Widen, *Widen, Widen->getDebugLoc(), "",
                                   Widen->getScalarType());
    } else if (auto *Cast = dyn_cast<VPWidenCastRecipe>(&R)) {
      Scalar = new VPInstructionWithType(Cast->getOpcode(), Cast->operands(),
                                         Cast->getScalarType(), *Cast, *Cast,
                                         Cast->getDebugLoc());
    } else if (auto *Intrinsic = dyn_cast<VPWidenIntrinsicRecipe>(&R)) {
      Scalar = new VPFissionScalarIntrinsicRecipe(*Intrinsic);
    } else if (auto *GEP = dyn_cast<VPWidenGEPRecipe>(&R)) {
      Scalar = new VPReplicateRecipe(
          cast<GetElementPtrInst>(GEP->getUnderlyingValue()), GEP->operands(),
          true, nullptr, *GEP);
    } else if (auto *Load = dyn_cast<VPWidenLoadRecipe>(&R)) {
      if (Load->getMask())
        return createStringError(errc::invalid_argument,
                                 "predicated scalar remainder load");
      Scalar =
          new VPReplicateRecipe(&cast<LoadInst>(Load->getIngredient()),
                                {Load->getAddr()}, true, nullptr, {}, *Load);
    } else if (auto *Call = dyn_cast<VPWidenCallRecipe>(&R)) {
      auto *Replicate =
          new VPReplicateRecipe(cast<Instruction>(Call->getUnderlyingValue()),
                                Call->operands(), true, nullptr, *Call);
      Replicate->transferFlags(*Call);
      Scalar = Replicate;
    }
    if (!Scalar)
      continue;
    Scalar->insertBefore(&R);
    R.getVPSingleValue()->replaceAllUsesWith(Scalar);
    R.eraseFromParent();
  }
  return Remainder;
}

} // namespace

void llvm::simplifyReductionFissionTail(VPlan &Plan) {
  for (VPRecipeBase *R : collectRecipes(Plan)) {
    auto *Select = dyn_cast<VPInstruction>(R);
    if (!Select || Select->getOpcode() != Instruction::Select)
      continue;
    auto *Phi = dyn_cast<VPReductionPHIRecipe>(Select->getOperand(2));
    auto *Update = dyn_cast_or_null<VPRecipeWithIRFlags>(
        Select->getOperand(1)->getDefiningRecipe());
    if (!Phi || !Update || Update->getNumOperands() != 2 ||
        count(Update->operands(), Phi) != 1)
      continue;
    unsigned Opcode;
    if (auto *I = dyn_cast<VPInstruction>(Update))
      Opcode = I->getOpcode();
    else if (auto *W = dyn_cast<VPWidenRecipe>(Update))
      Opcode = W->getOpcode();
    else
      continue;
    if (Opcode != Instruction::Add &&
        !(Opcode == Instruction::FAdd && Update->hasFastMathFlags() &&
          Update->getFastMathFlagsOrNone().noSignedZeros()))
      continue;
    VPValue *Contribution = Update->getOperand(Update->getOperand(0) == Phi);
    auto *Load = dyn_cast_or_null<VPFissionScratchLoadRecipe>(
        Contribution->getDefiningRecipe());
    if (!Load || Load->getMask() != Select->getOperand(0))
      continue;
    Select->replaceAllUsesWith(Select->getOperand(1));
    Select->eraseFromParent();
  }
}

Expected<VPReductionFissionCandidate> llvm::buildReductionFissionStagePlans(
    VPlan &Baseline, const VPReductionFissionAnalysis &Analysis,
    const VPScratchPlan &Scratch, ArrayRef<ElementCount> CandidateVFs,
    bool CombineAddContributions) {
  VPBasicBlock *Body = Baseline.getVectorLoopRegion()->getEntryBasicBlock();
  if (Scratch.Slots.empty())
    return createStringError(errc::invalid_argument, "empty scratch plan");
  for (const VPScratchSlot &Slot : Scratch.Slots) {
    if (Slot.Frontier->getScalarType() != Slot.ElementType)
      return createStringError(errc::invalid_argument,
                               "scratch frontier type mismatch");
    VPRecipeBase *Def = Slot.Frontier->getDefiningRecipe();
    if (!Def || Def->getParent() != Body)
      return createStringError(errc::invalid_argument,
                               "scratch frontier is outside vector body");
  }
  Expected<StagePlanBuildResult> Producer = buildStagePlan(
      Baseline, Analysis.Partition.ProducerRecipes, {}, CandidateVFs);
  if (!Producer)
    return Producer.takeError();
  Expected<StagePlanBuildResult> Accumulator =
      buildStagePlan(Baseline, Analysis.Partition.AccumulatorRecipes,
                     Analysis.Partition.FrontierValues, CandidateVFs);
  if (!Accumulator)
    return Accumulator.takeError();

  auto GetCanonicalIV = [](VPlan &Plan) -> VPValue * {
    return Plan.getVectorLoopRegion()->getCanonicalIV();
  };
  VPValue *ProducerIndex = GetCanonicalIV(*Producer->Plan);
  VPValue *AccumulatorIndex = GetCanonicalIV(*Accumulator->Plan);
  LLVMContext &Ctx = Scratch.Slots.front().ElementType->getContext();
  VPValue *ProducerMask = removeStageTailPredication(*Producer);
  VPValue *AccumulatorMask = removeStageTailPredication(*Accumulator);

  VPReductionFissionCandidate Candidate;
  Candidate.Partition = Analysis.Partition;
  Candidate.Partition.DuplicatedRecipeCount = 0;
  const VPRecipeBase *CanonicalBackedge = getCanonicalIncrement(Baseline);
  for (VPRecipeBase &R :
       *Baseline.getVectorLoopRegion()->getEntryBasicBlock()) {
    if (!Producer->Recipes.contains(&R) || !Accumulator->Recipes.contains(&R) ||
        isa<VPDerivedIVRecipe, VPScalarIVStepsRecipe>(R) ||
        &R == CanonicalBackedge)
      continue;
    if (auto *WideIV = dyn_cast<VPWidenCanonicalIVRecipe>(&R);
        WideIV && vputils::onlyFirstLaneUsed(WideIV))
      continue;
    if (auto *I = dyn_cast<VPInstruction>(&R))
      if (I->getOpcode() == VPInstruction::ActiveLaneMask ||
          I->getOpcode() == VPInstruction::BranchOnCount)
        continue;
    ++Candidate.Partition.DuplicatedRecipeCount;
  }
  Candidate.Scratch = Scratch;
  for (const auto &[SlotID, Slot] : enumerate(Scratch.Slots)) {
    VPRecipeBase *ProducerDef =
        Producer->Recipes.lookup(Slot.Frontier->getDefiningRecipe());
    VPValue *ProducerFrontier = Producer->Values.lookup(Slot.Frontier);
    if (!ProducerDef || !ProducerFrontier)
      return createStringError(errc::invalid_argument,
                               "producer frontier is not in stage body");
    Value *BasePlaceholder = PoisonValue::get(PointerType::getUnqual(Ctx));
    VPValue *ProducerBase = Producer->Plan->getOrAddLiveIn(BasePlaceholder);
    VPValue *AccumulatorBase =
        Accumulator->Plan->getOrAddLiveIn(BasePlaceholder);

    auto *Store = new VPFissionScratchStoreRecipe(
        SlotID, Slot.ElementType, Slot.Alignment, ProducerBase, ProducerIndex,
        ProducerFrontier, ProducerMask);
    Store->insertAfter(ProducerDef);

    auto *Load = new VPFissionScratchLoadRecipe(
        SlotID, Slot.ElementType, Slot.Alignment, AccumulatorBase,
        AccumulatorIndex, AccumulatorMask);
    VPRecipeBase *FirstUser = nullptr;
    // Use program order, not the baseline use-list order, to ensure the load
    // dominates every consumer. Do not mutate a use list while iterating it.
    for (VPRecipeBase &NewUser :
         *Accumulator->Plan->getVectorLoopRegion()->getEntryBasicBlock()) {
      if (!is_contained(NewUser.operands(), Slot.Frontier))
        continue;
      if (!FirstUser) {
        FirstUser = &NewUser;
        Load->insertBefore(&NewUser);
      }
      NewUser.replaceUsesOfWith(Slot.Frontier, Load);
    }
    if (!FirstUser) {
      delete Load;
      return createStringError(errc::invalid_argument,
                               "scratch frontier has no accumulator user");
    }
  }

  Candidate.ProducerPlan = std::move(Producer->Plan);
  Candidate.AccumulatorPlan = std::move(Accumulator->Plan);
  if (CombineAddContributions)
    combineAddContributions(Candidate);
  auto ProducerRemainder = buildScalarRemainder(*Candidate.ProducerPlan);
  if (!ProducerRemainder)
    return ProducerRemainder.takeError();
  auto AccumulatorRemainder = buildScalarRemainder(*Candidate.AccumulatorPlan);
  if (!AccumulatorRemainder)
    return AccumulatorRemainder.takeError();
  Candidate.ProducerRemainder = std::move(*ProducerRemainder);
  Candidate.AccumulatorRemainder = std::move(*AccumulatorRemainder);

  // Resolve every exit before committing IR. Only reduction results have a
  // vector/scalar merge; a last-iteration load or induction live-out needs its
  // own export and must currently leave the baseline untouched.
  SmallPtrSet<VPValue *, 8> Exported;
  for (const auto &R : Candidate.AccumulatorRemainder.Reductions)
    Exported.insert(R.VectorResult);
  SmallPtrSet<PHINode *, 8> ExitPhis;
  for (auto [Original, Result] : Accumulator->PostLoopValues)
    for (VPUser *U : Original->users()) {
      auto *Phi = dyn_cast<VPIRPhi>(U);
      if (!Phi)
        continue;
      if (!Exported.contains(Result))
        return createStringError(errc::invalid_argument,
                                 "unsupported-live-out");
      if (ExitPhis.insert(&Phi->getIRPhi()).second)
        Candidate.AccumulatorLiveOuts.push_back({&Phi->getIRPhi(), Result});
    }
  for (VPIRBasicBlock *Exit : Baseline.getExitBlocks())
    for (PHINode &Phi : Exit->getIRBasicBlock()->phis())
      if (Phi.getBasicBlockIndex(
              Baseline.getScalarHeader()->getIRBasicBlock()) >= 0 &&
          !ExitPhis.contains(&Phi))
        return createStringError(errc::invalid_argument,
                                 "unsupported-live-out");
  return Candidate;
}

Expected<VPScratchPlan>
llvm::buildScratchPlan(ArrayRef<VPValue *> FrontierValues,
                       const SCEV *MaxTripCount, const DataLayout &DL,
                       uint64_t MaximumBytes) {
  const auto *ConstantTripCount = dyn_cast_or_null<SCEVConstant>(MaxTripCount);
  if (!ConstantTripCount || ConstantTripCount->getAPInt().getActiveBits() > 64)
    return buildScratchPlan(FrontierValues, std::nullopt, DL, MaximumBytes);
  return buildScratchPlan(FrontierValues,
                          ConstantTripCount->getAPInt().getZExtValue(), DL,
                          MaximumBytes);
}

Expected<VPScratchPlan>
llvm::buildScratchPlan(ArrayRef<VPValue *> FrontierValues,
                       std::optional<uint64_t> MaxTripCount,
                       const DataLayout &DL, uint64_t MaximumBytes) {
  if (!MaxTripCount)
    return createStringError(errc::invalid_argument,
                             "trip count has no constant upper bound");
  if (*MaxTripCount == 0)
    return createStringError(errc::invalid_argument,
                             "zero trip count has no scratch layout");

  VPScratchPlan Result;
  SmallPtrSet<VPValue *, 8> Seen;
  for (VPValue *Frontier : FrontierValues) {
    if (!Seen.insert(Frontier).second)
      continue;
    Type *ElementType = (Frontier)->getScalarType();
    TypeSize ElementSize = DL.getTypeAllocSize(ElementType);
    if (ElementSize.isScalable())
      return createStringError(errc::result_out_of_range,
                               "scalable scratch element size");
    uint64_t ElementBytes = ElementSize.getFixedValue();
    if (ElementBytes != 0 &&
        *MaxTripCount > std::numeric_limits<uint64_t>::max() / ElementBytes)
      return createStringError(errc::result_out_of_range,
                               "scratch slot size overflow");
    uint64_t Bytes = *MaxTripCount * ElementBytes;
    Align Alignment = DL.getABITypeAlign(ElementType);
    uint64_t AlignValue = Alignment.value();
    uint64_t Padding =
        (AlignValue - Result.TotalBytes % AlignValue) % AlignValue;
    if (Result.TotalBytes > std::numeric_limits<uint64_t>::max() - Padding)
      return createStringError(errc::result_out_of_range,
                               "scratch alignment overflow");
    uint64_t Offset = Result.TotalBytes + Padding;
    if (Offset > std::numeric_limits<uint64_t>::max() - Bytes)
      return createStringError(errc::result_out_of_range,
                               "scratch layout overflow");
    uint64_t End = Offset + Bytes;
    if (End > MaximumBytes)
      return createStringError(errc::result_out_of_range,
                               "scratch byte limit exceeded");
    Result.Slots.push_back(
        {Frontier, ElementType, *MaxTripCount, Alignment, Offset, Bytes});
    Result.TotalBytes = End;
  }
  return Result;
}

void VPFissionScratchLoadRecipe::execute(VPTransformState &State) {
  IRBuilderBase &Builder = State.Builder;
  Value *Base = State.get(getOperand(0), /*IsScalar=*/true);
  Value *Index = State.get(getOperand(1), /*IsScalar=*/true);
  Value *Address =
      Builder.CreateGEP(ElementType, Base, Index, "fission.scratch.address");
  Type *VectorTy = toVectorizedTy(ElementType, State.VF);
  Value *Loaded;
  if (isa<VPIRValue>(getMask()) &&
      getMask()->getLiveInIRValue() == Builder.getTrue())
    Loaded = Builder.CreateAlignedLoad(VectorTy, Address, Alignment,
                                       "fission.scratch.load");
  else {
    assert(State.VF.isVector() && "scalar scratch access must be unmasked");
    Loaded = Builder.CreateMaskedLoad(
        VectorTy, Address, Alignment, State.get(getMask()),
        Constant::getNullValue(VectorTy), "fission.scratch.load");
  }
  State.set(this, Loaded);
}

InstructionCost
VPFissionScratchLoadRecipe::computeCost(ElementCount VF,
                                        VPCostContext &Ctx) const {
  return Ctx.TTI.getMemoryOpCost(Instruction::Load,
                                 toVectorizedTy(ElementType, VF), Alignment, 0,
                                 Ctx.CostKind);
}

#if !defined(NDEBUG) || defined(LLVM_ENABLE_DUMP)
void VPFissionScratchLoadRecipe::printRecipe(raw_ostream &O,
                                             const Twine &Indent,
                                             VPSlotTracker &SlotTracker) const {
  O << Indent;
  printAsOperand(O, SlotTracker);
  O << " = FISSION-SCRATCH-LOAD slot(" << SlotID << ") ";
  printOperands(O, SlotTracker);
}
#endif

void VPFissionScratchStoreRecipe::execute(VPTransformState &State) {
  IRBuilderBase &Builder = State.Builder;
  Value *Base = State.get(getOperand(0), /*IsScalar=*/true);
  Value *Index = State.get(getOperand(1), /*IsScalar=*/true);
  Value *Address =
      Builder.CreateGEP(ElementType, Base, Index, "fission.scratch.address");
  if (isa<VPIRValue>(getMask()) &&
      getMask()->getLiveInIRValue() == Builder.getTrue())
    Builder.CreateAlignedStore(State.get(getStoredValue()), Address, Alignment);
  else {
    assert(State.VF.isVector() && "scalar scratch access must be unmasked");
    Builder.CreateMaskedStore(State.get(getStoredValue()), Address, Alignment,
                              State.get(getMask()));
  }
}

InstructionCost
VPFissionScratchStoreRecipe::computeCost(ElementCount VF,
                                         VPCostContext &Ctx) const {
  return Ctx.TTI.getMemoryOpCost(Instruction::Store,
                                 toVectorizedTy(ElementType, VF), Alignment, 0,
                                 Ctx.CostKind);
}

#if !defined(NDEBUG) || defined(LLVM_ENABLE_DUMP)
void VPFissionScratchStoreRecipe::printRecipe(
    raw_ostream &O, const Twine &Indent, VPSlotTracker &SlotTracker) const {
  O << Indent << "FISSION-SCRATCH-STORE slot(" << SlotID << ") ";
  printOperands(O, SlotTracker);
}
#endif

void VPFissionLiveOutRecipe::execute(VPTransformState &State) {
  Result = State.get(getOperand(0), /*IsScalar=*/true);
}

void VPFissionScalarIntrinsicRecipe::execute(VPTransformState &State) {
  assert(State.VF.isScalar() && "intrinsic belongs to a scalar companion");
  SmallVector<Value *, 4> Args;
  for (VPValue *Op : operands())
    Args.push_back(State.get(Op, /*IsScalar=*/true));
  Value *Result = State.Builder.CreateIntrinsic(getScalarType(), ID, Args);
  if (auto *I = dyn_cast<Instruction>(Result)) {
    applyFlags(*I);
    applyMetadata(*I);
  }
  State.set(this, Result);
}

#if !defined(NDEBUG) || defined(LLVM_ENABLE_DUMP)
void VPFissionScalarIntrinsicRecipe::printRecipe(
    raw_ostream &O, const Twine &Indent, VPSlotTracker &SlotTracker) const {
  O << Indent;
  printAsOperand(O, SlotTracker);
  O << " = FISSION-SCALAR-INTRINSIC " << Intrinsic::getBaseName(ID);
  printFlags(O);
  printOperands(O, SlotTracker);
}
#endif

#if !defined(NDEBUG) || defined(LLVM_ENABLE_DUMP)
void VPFissionLiveOutRecipe::printRecipe(raw_ostream &O, const Twine &Indent,
                                         VPSlotTracker &SlotTracker) const {
  O << Indent << "FISSION-LIVE-OUT ";
  printOperands(O, SlotTracker);
}
#endif

bool llvm::verifyReductionFissionRecipe(const VPRecipeBase &R) {
  if (auto *S = dyn_cast<VPFissionScratchStoreRecipe>(&R)) {
    if (S->getSlotID() == std::numeric_limits<unsigned>::max() ||
        !VectorType::isValidElementType(S->getElementType()) ||
        S->getStoredValue()->getScalarType() != S->getElementType()) {
      errs() << "Invalid reduction-fission scratch store\n";
      return false;
    }
  }
  if (auto *L = dyn_cast<VPFissionScratchLoadRecipe>(&R)) {
    if (L->getSlotID() == std::numeric_limits<unsigned>::max() ||
        !VectorType::isValidElementType(L->getElementType())) {
      errs() << "Invalid reduction-fission scratch load\n";
      return false;
    }
  }
  return true;
}
