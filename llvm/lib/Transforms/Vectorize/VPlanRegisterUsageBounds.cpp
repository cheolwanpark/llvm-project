//===- VPlanRegisterUsageBounds.cpp - Cheap RVV pressure bounds
//-------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "VPlanRegisterUsageBounds.h"
#include "VPlan.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/Analysis/TargetTransformInfo.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/MathExtras.h"
#include <limits>

using namespace llvm;

static bool addChecked(uint64_t &A, uint64_t B) {
  if (B > std::numeric_limits<uint64_t>::max() - A)
    return false;
  A += B;
  return true;
}

std::optional<uint64_t>
llvm::boundVPlanLiveValues(uint64_t Persistent,
                           ArrayRef<VPRegisterLifetimeCounts> Recipes) {
  uint64_t Total = Persistent, Boundary = Persistent, MaxDefs = 0;
  for (auto [Defs, Kills] : Recipes) {
    if (!addChecked(Total, Defs) ||
        !addChecked(Boundary, Defs > Kills ? Defs - Kills : 0))
      return std::nullopt;
    MaxDefs = std::max(MaxDefs, Defs);
  }
  // Every prefix has live count <= Persistent + sum(max(0, Defs - Kills)).
  // Reserve all outputs before freeing inputs; no coalescing is assumed.
  if (!addChecked(Boundary, MaxDefs))
    return std::nullopt;
  return std::min(Total, Boundary);
}

namespace {
enum class Shape { Scalar, Flexible, Vector, Unsupported };

StringRef recipeName(const VPRecipeBase &R) {
#define RECIPE(N)                                                              \
  case VPRecipeBase::N##SC:                                                    \
    return #N
  switch (R.getVPRecipeID()) {
    RECIPE(VPBranchOnMask);
    RECIPE(VPDerivedIV);
    RECIPE(VPExpandSCEV);
    RECIPE(VPExpression);
    RECIPE(VPIRInstruction);
    RECIPE(VPInstruction);
    RECIPE(VPInterleaveEVL);
    RECIPE(VPInterleave);
    RECIPE(VPReductionEVL);
    RECIPE(VPReduction);
    RECIPE(VPReplicate);
    RECIPE(VPScalarIVSteps);
    RECIPE(VPVectorPointer);
    RECIPE(VPVectorEndPointer);
    RECIPE(VPWidenCall);
    RECIPE(VPWidenCanonicalIV);
    RECIPE(VPWidenCast);
    RECIPE(VPWidenGEP);
    RECIPE(VPWidenIntrinsic);
    RECIPE(VPWidenMemIntrinsic);
    RECIPE(VPWidenLoadEVL);
    RECIPE(VPWidenLoad);
    RECIPE(VPWidenStoreEVL);
    RECIPE(VPWidenStore);
    RECIPE(VPWiden);
    RECIPE(VPBlend);
    RECIPE(VPHistogram);
    RECIPE(VPWidenPHI);
    RECIPE(VPPredInstPHI);
    RECIPE(VPCurrentIterationPHI);
    RECIPE(VPActiveLaneMaskPHI);
    RECIPE(VPFirstOrderRecurrencePHI);
    RECIPE(VPWidenIntOrFpInduction);
    RECIPE(VPWidenPointerInduction);
    RECIPE(VPReductionPHI);
  }
#undef RECIPE
  return "unknown-recipe";
}

bool simpleOpcode(unsigned Op) {
  switch (Op) {
  case Instruction::Add:
  case Instruction::Sub:
  case Instruction::Mul:
  case Instruction::SDiv:
  case Instruction::UDiv:
  case Instruction::SRem:
  case Instruction::URem:
  case Instruction::Shl:
  case Instruction::LShr:
  case Instruction::AShr:
  case Instruction::And:
  case Instruction::Or:
  case Instruction::Xor:
  case Instruction::FAdd:
  case Instruction::FSub:
  case Instruction::FMul:
  case Instruction::FDiv:
  case Instruction::FNeg:
  case Instruction::ICmp:
  case Instruction::FCmp:
  case Instruction::Select:
  case Instruction::Freeze:
  case VPInstruction::Not:
  case VPInstruction::LogicalAnd:
  case VPInstruction::LogicalOr:
    return true;
  default:
    return false;
  }
}

bool simplePredicate(const VPRecipeWithIRFlags &R) {
  switch (R.getPredicate()) {
  case CmpInst::FCMP_OEQ:
  case CmpInst::FCMP_OLT:
  case CmpInst::FCMP_OLE:
  case CmpInst::FCMP_OGT:
  case CmpInst::FCMP_OGE:
  case CmpInst::FCMP_UNE:
    return true;
  default:
    return false;
  }
}

bool hasExpandedDivision(unsigned Opcode, const VPRecipeBase &R) {
  switch (Opcode) {
  case Instruction::SDiv:
  case Instruction::UDiv:
  case Instruction::SRem:
  case Instruction::URem:
    // Constant division may become a multiply/shift sequence with temporaries.
    return isa<VPConstant>(R.getOperand(1));
  default:
    return false;
  }
}

Shape classify(const VPRecipeBase &R) {
  if (auto *L = dyn_cast<VPWidenLoadRecipe>(&R))
    return L->isConsecutive() ? Shape::Vector : Shape::Unsupported;
  if (auto *L = dyn_cast<VPWidenLoadEVLRecipe>(&R))
    return L->isConsecutive() ? Shape::Vector : Shape::Unsupported;
  if (auto *S = dyn_cast<VPWidenStoreRecipe>(&R))
    return S->isConsecutive() ? Shape::Vector : Shape::Unsupported;
  if (auto *S = dyn_cast<VPWidenStoreEVLRecipe>(&R))
    return S->isConsecutive() ? Shape::Vector : Shape::Unsupported;
  if (auto *W = dyn_cast<VPWidenRecipe>(&R))
    return simpleOpcode(W->getOpcode()) &&
                   !hasExpandedDivision(W->getOpcode(), R) &&
                   (W->getOpcode() != Instruction::FCmp || simplePredicate(*W))
               ? Shape::Vector
               : Shape::Unsupported;
  if (auto *C = dyn_cast<VPWidenCastRecipe>(&R)) {
    // Mask/data conversion and bitcasts can introduce additional temporaries.
    if (C->getScalarType()->isIntegerTy(1) ||
        C->getOperand(0)->getScalarType()->isIntegerTy(1))
      return Shape::Unsupported;
    unsigned SrcBits = C->getOperand(0)->getScalarType()->getScalarSizeInBits();
    unsigned DstBits = C->getScalarType()->getScalarSizeInBits();
    // Integer extensions have vf2/vf4/vf8 instructions. Other conversions
    // across more than one width step need unrepresented intermediate values.
    if (C->getOpcode() != Instruction::ZExt &&
        C->getOpcode() != Instruction::SExt &&
        (SrcBits > 2 * DstBits || DstBits > 2 * SrcBits))
      return Shape::Unsupported;
    switch (C->getOpcode()) {
    case Instruction::Trunc:
    case Instruction::ZExt:
    case Instruction::SExt:
    case Instruction::FPTrunc:
    case Instruction::FPExt:
    case Instruction::FPToSI:
    case Instruction::FPToUI:
    case Instruction::SIToFP:
    case Instruction::UIToFP:
      return Shape::Vector;
    default:
      return Shape::Unsupported;
    }
  }
  if (auto *B = dyn_cast<VPBlendRecipe>(&R))
    return B->isNormalized() && B->getNumIncomingValues() == 2
               ? Shape::Vector
               : Shape::Unsupported;
  if (auto *P = dyn_cast<VPReductionPHIRecipe>(&R))
    return P->isInLoop() ? Shape::Scalar : Shape::Vector;
  if (isa<VPWidenPHIRecipe, VPActiveLaneMaskPHIRecipe>(&R))
    return Shape::Vector;
  if (isa<VPCurrentIterationPHIRecipe, VPVectorPointerRecipe,
          VPVectorEndPointerRecipe, VPDerivedIVRecipe, VPExpandSCEVRecipe>(&R))
    return Shape::Scalar;
  if (auto *Rep = dyn_cast<VPReplicateRecipe>(&R))
    return Rep->isSingleScalar() && !Rep->isPredicated() &&
                   !isa<CallBase>(Rep->getUnderlyingInstr())
               ? Shape::Scalar
               : Shape::Unsupported;
  // These may be used only for scalar address/control computations. Vector
  // demand on their outputs is explicitly rejected below.
  if (isa<VPWidenGEPRecipe, VPWidenPointerInductionRecipe,
          VPScalarIVStepsRecipe>(&R))
    return Shape::Scalar;
  if (auto *I = dyn_cast<VPInstruction>(&R)) {
    unsigned Op = I->getOpcode();
    if (simpleOpcode(Op))
      return !hasExpandedDivision(Op, R) &&
                     (Op != Instruction::FCmp || simplePredicate(*I))
                 ? Shape::Flexible
                 : Shape::Unsupported;
    if (Instruction::isCast(Op))
      return Shape::Scalar; // VPInstruction casts generate one scalar.
    switch (Op) {
    case VPInstruction::Broadcast:
    case VPInstruction::StepVector:
      return Shape::Vector;
    case Instruction::Load:
    case Instruction::PHI:
    case VPInstruction::ExplicitVectorLength:
    case VPInstruction::CalculateTripCountMinusVF:
    case VPInstruction::CanonicalIVIncrementForPart:
    case VPInstruction::BranchOnCount:
    case VPInstruction::BranchOnCond:
    case VPInstruction::PtrAdd:
      return Shape::Scalar;
    default:
      return Shape::Unsupported;
    }
  }
  // Includes interleave, histogram, calls/intrinsics, reductions, vector IVs,
  // expression decomposition, predicated replication and recurrence recipes.
  return Shape::Unsupported;
}

bool scalarOperand(const VPRecipeBase &R, const VPValue *V) {
  if (auto *L = dyn_cast<VPWidenLoadRecipe>(&R))
    return V == L->getAddr();
  if (auto *L = dyn_cast<VPWidenLoadEVLRecipe>(&R))
    return V == L->getAddr() || V == L->getEVL();
  if (auto *S = dyn_cast<VPWidenStoreRecipe>(&R))
    return V == S->getAddr() && V != S->getStoredValue();
  if (auto *S = dyn_cast<VPWidenStoreEVLRecipe>(&R))
    return V == S->getEVL() || (V == S->getAddr() && V != S->getStoredValue());
  if (auto *I = dyn_cast<VPInstruction>(&R))
    return I->getOpcode() == VPInstruction::Broadcast;
  return false;
}
} // namespace

VPRegisterUsageBound
llvm::computeVPlanRegisterUsageBound(const VPlan &Plan, ElementCount VF,
                                     const TargetTransformInfo &TTI) {
  VPRegisterUsageBound Result;
  auto Fail = [&](StringRef Reason, const VPRecipeBase *R = nullptr) {
    Result.Reason = Reason;
    if (R) {
      Result.Recipe = recipeName(*R);
      if (auto *I = dyn_cast<VPInstruction>(R))
        Result.Opcode = I->getOpcode();
      if (auto *W = dyn_cast<VPWidenRecipe>(R))
        Result.Opcode = W->getOpcode();
      if (auto *C = dyn_cast<VPWidenCastRecipe>(R))
        Result.Opcode = C->getOpcode();
    }
    return Result;
  };
  auto &F = *Plan.getScalarHeader()->getIRBasicBlock()->getParent();
  if (!F.getParent()->getTargetTriple().isRISCV() || VF.isScalar() ||
      TTI.getRegisterBitWidth(TargetTransformInfo::RGK_ScalableVector)
              .getKnownMinValue() == 0)
    return Fail("unsupported-target-or-vf");
  auto *Region = Plan.getVectorLoopRegion();
  auto *Body = Region ? dyn_cast<VPBasicBlock>(Region->getEntry()) : nullptr;
  if (!Body || Region->isReplicator() || Region->getExiting() != Body ||
      !Body->getSuccessors().empty())
    return Fail("unsupported-loop-structure");

  DenseMap<const VPRecipeBase *, Shape> Shapes;
  DenseMap<const VPRecipeBase *, unsigned> Indices;
  SmallVector<VPRegisterLifetimeCounts> Counts;
  for (const VPRecipeBase &R : *Body) {
    Shape S = classify(R);
    if (S == Shape::Unsupported)
      return Fail("unsupported-recipe", &R);
    Shapes[&R] = S;
    Indices[&R] = Counts.size();
    Counts.emplace_back();
  }

  // Demand propagation avoids recursive onlyFirstLaneUsed/isSingleScalar
  // queries, whose repeated traversal can be superlinear on shared DAGs.
  DenseMap<const VPValue *, bool> VectorValues;
  SmallVector<const VPValue *> Worklist;
  SmallVector<const VPValue *> OrderedValues;
  auto Mark = [&](const VPValue *V) {
    if (VectorValues.try_emplace(V, true).second) {
      Worklist.push_back(V);
      OrderedValues.push_back(V);
    }
  };
  auto MarkInputs = [&](const VPRecipeBase &R) {
    for (const VPValue *V : R.operands())
      if (!scalarOperand(R, V))
        Mark(V);
  };
  for (const VPRecipeBase &R : *Body) {
    if (Shapes.lookup(&R) == Shape::Vector) {
      for (auto *V : R.definedValues())
        Mark(V);
      MarkInputs(R);
    }
  }
  while (!Worklist.empty()) {
    const VPValue *V = Worklist.pop_back_val();
    const VPRecipeBase *R = V->getDefiningRecipe();
    auto It = Shapes.find(R);
    if (It != Shapes.end() && It->second == Shape::Flexible) {
      It->second = Shape::Vector;
      MarkInputs(*R);
    }
  }

  uint64_t Persistent = 0;
  DenseMap<VectorType *, unsigned> TypeUsage;
  for (const VPValue *V : OrderedValues) {
    const VPRecipeBase *Def = V->getDefiningRecipe();
    if (Def && isa<VPWidenGEPRecipe, VPWidenPointerInductionRecipe,
                   VPScalarIVStepsRecipe>(Def))
      return Fail("unmodelled-vector-address-or-replication", Def);
    Type *Ty = V->getScalarType();
    bool Mask = Ty->isIntegerTy(1);
    Result.HasMask |= Mask;
    if (!Mask &&
        !(Ty->isIntegerTy(8) || Ty->isIntegerTy(16) || Ty->isIntegerTy(32) ||
          Ty->isIntegerTy(64) || Ty->isFloatTy() || Ty->isDoubleTy()))
      return Fail("unsupported-element-type", Def);
    ElementCount ValueVF = VF;
    if (auto *Phi = dyn_cast_or_null<VPReductionPHIRecipe>(Def)) {
      unsigned Scale = Phi->getVFScaleFactor();
      if (Scale > VF.getKnownMinValue() || VF.getKnownMinValue() % Scale)
        return Fail("unsupported-vf-scale", Def);
      ValueVF = VF.divideCoefficientBy(Scale);
    }
    auto *VecTy = VectorType::get(Ty, ValueVF);
    auto [It, Inserted] = TypeUsage.try_emplace(VecTy, 0);
    if (Inserted) {
      // i1 is a predicate, not an RVV data element type. The target's data
      // element legality hook deliberately rejects it. A mask fitting in one
      // physical vector register needs no data-type promotion/legalization.
      if (Mask ? TTI.getRegUsageForType(VecTy) != 1
               : (!TTI.isElementTypeLegalForScalableVector(Ty) ||
                  TTI.getNumberOfParts(VecTy) != 1 ||
                  (VF.isScalable() && !TTI.isTypeLegal(VecTy))))
        return Fail("unsupported-type-legalization", Def);
      It->second = Mask ? 1 : TTI.getRegUsageForType(VecTy);
      if (!It->second || It->second > 8 || !isPowerOf2_32(It->second))
        return Fail("unsupported-register-group", Def);
    }
    Result.MaxRegisterGroup =
        std::max<uint64_t>(Result.MaxRegisterGroup, It->second);
    auto SI = Shapes.find(Def);
    bool Pinned =
        SI == Shapes.end() || SI->second != Shape::Vector || Def->isPhi();
    if (Pinned) {
      ++Persistent;
      continue;
    }
    ++Counts[Indices.lookup(Def)].Definitions;
    const VPUser *OnlyUser = nullptr;
    bool Unique = true;
    for (const VPUser *U : V->users()) {
      if (OnlyUser && OnlyUser != U) {
        Unique = false;
        break;
      }
      OnlyUser = U;
    }
    auto *Consumer = dyn_cast_or_null<VPRecipeBase>(OnlyUser);
    auto CI = Indices.find(Consumer);
    if (Unique && CI != Indices.end() && !Consumer->isPhi())
      ++Counts[CI->second].GuaranteedKills;
  }
  auto Peak = boundVPlanLiveValues(Persistent, Counts);
  if (!Peak)
    return Fail("arithmetic-overflow");
  Result.Peak = *Peak;
  uint64_t WithMask = *Peak;
  if (!addChecked(WithMask, Result.HasMask) ||
      WithMask > std::numeric_limits<uint64_t>::max() / Result.MaxRegisterGroup)
    return Fail("arithmetic-overflow");
  Result.Usage = WithMask * Result.MaxRegisterGroup;
  Result.Known = true;
  Result.Reason =
      Result.shouldQuery() ? "register-budget" : "below-register-budget";
  return Result;
}
