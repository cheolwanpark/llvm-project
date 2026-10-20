//===- ScalarFission.cpp - Scalar producer/consumer loop splitting
//----------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Analysis is transactional: discover closed state slices, choose their inputs,
// and prove the complete chunk schedule before creating any instructions.
// The producer retains its original CFG (including nested loops) and effects.
// The consumer replays the outer CFG, with private suffixes and ordered state
// updates. Nested producer loops are contracted to their dedicated exit.
// Counters describe a bounded chunk, never the total trip count.
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Scalar/ScalarFission.h"
#include "llvm/ADT/MapVector.h"
#include "llvm/ADT/ScopeExit.h"
#include "llvm/ADT/SetVector.h"
#include "llvm/Analysis/AliasAnalysis.h"
#include "llvm/Analysis/AssumptionCache.h"
#include "llvm/Analysis/IVDescriptors.h"
#include "llvm/Analysis/InstructionSimplify.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/OptimizationRemarkEmitter.h"
#include "llvm/Analysis/ScalarEvolution.h"
#include "llvm/Analysis/ScalarEvolutionExpressions.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/CFG.h"
#include "llvm/IR/DebugInfoMetadata.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/PatternMatch.h"
#include "llvm/Support/CheckedArithmetic.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/MathExtras.h"
#include "llvm/Transforms/Scalar/LoopPassManager.h"
#include "llvm/Transforms/Scalar/LoopRotation.h"
#include "llvm/Transforms/Utils/LCSSA.h"
#include "llvm/Transforms/Utils/Local.h"
#include "llvm/Transforms/Utils/LoopSimplify.h"
#include "llvm/Transforms/Utils/LoopUtils.h"
#include "llvm/Transforms/Utils/ValueMapper.h"

using namespace llvm;

#define DEBUG_TYPE "scalar-fission"

static cl::opt<bool> EnableFission("enable-scalar-fission", cl::init(false),
                                   cl::Hidden,
                                   cl::desc("Enable scalar loop fission"));
static cl::alias OldEnable("enable-vplan-reduction-fission", cl::Hidden,
                           cl::aliasopt(EnableFission));
static cl::opt<bool> OldScalarEnable("enable-scalar-reduction-fission",
                                     cl::init(true), cl::Hidden);
static cl::opt<bool>
    EarlyFission("scalar-fission-early", cl::init(false), cl::Hidden,
                 cl::desc("Run fission before full unrolling"));
static cl::opt<uint64_t> MaxScratch("scalar-fission-max-scratch-bytes",
                                    cl::init(65536), cl::Hidden);
static cl::alias OldScratch("vplan-reduction-fission-max-scratch-bytes",
                            cl::Hidden, cl::aliasopt(MaxScratch));
static cl::opt<unsigned> MaxCapacity("scalar-fission-chunk-capacity",
                                     cl::init(1024), cl::Hidden);
static cl::opt<bool> Reassociate("scalar-fission-allow-fp-reordering",
                                 cl::init(false), cl::Hidden);
static cl::alias OldReassociate("vplan-reduction-fission-allow-fp-reordering",
                                cl::Hidden, cl::aliasopt(Reassociate));
static cl::opt<unsigned> ProducerVF("scalar-fission-producer-vf", cl::init(0),
                                    cl::Hidden);
static cl::opt<unsigned> ConsumerVF("scalar-fission-consumer-vf", cl::init(0),
                                    cl::Hidden);
static cl::opt<bool> ProducerScalable("scalar-fission-producer-scalable",
                                      cl::init(false), cl::Hidden);
static cl::opt<bool> ConsumerScalable("scalar-fission-consumer-scalable",
                                      cl::init(false), cl::Hidden);
static cl::opt<unsigned> ProducerIC("scalar-fission-producer-interleave",
                                    cl::init(0), cl::Hidden);
static cl::opt<unsigned> ConsumerIC("scalar-fission-consumer-interleave",
                                    cl::init(0), cl::Hidden);
// The old VF flags denote scalable factors, including vscale x 1.
static cl::opt<unsigned>
    OldProducerVF("vplan-reduction-fission-force-producer-vf", cl::init(0),
                  cl::Hidden);
static cl::opt<unsigned>
    OldConsumerVF("vplan-reduction-fission-force-accumulator-vf", cl::init(0),
                  cl::Hidden);
// Parse obsolete options only to diagnose migration. They never gate legality.
static cl::opt<unsigned>
    OldRecipes("vplan-reduction-fission-max-duplicated-recipes", cl::Hidden);
static cl::opt<unsigned>
    OldSearch("vplan-reduction-fission-max-scalable-vf-multiplier", cl::Hidden);
static cl::opt<unsigned> OldDepth("vplan-reduction-fission-min-chain-depth",
                                  cl::Hidden);
static cl::opt<unsigned> OldReductions("vplan-reduction-fission-min-reductions",
                                       cl::Hidden);
static cl::opt<unsigned>
    OldPressure("vplan-reduction-fission-min-pressure-percent", cl::Hidden);
static cl::opt<bool>
    OldCombine("vplan-reduction-fission-combine-add-contributions", cl::Hidden);

static constexpr StringLiteral StageMD = "llvm.loop.scalar_fission.stage";
static constexpr StringLiteral ProducerMD = "llvm.loop.scalar_fission.producer";
static constexpr StringLiteral ConsumerMD = "llvm.loop.scalar_fission.consumer";
bool llvm::isScalarFissionEnabled() { return EnableFission; }
bool llvm::isScalarFissionEarly() { return EarlyFission; }
StringRef llvm::getScalarFissionStage(const Loop &L) {
  if (findOptionMDForLoop(&L, ProducerMD))
    return "producer";
  if (findOptionMDForLoop(&L, ConsumerMD))
    return "consumer";
  return {};
}
static void setFissionStartLoc(Loop &L, DebugLoc Loc) {
  if (!Loc)
    return;
  SmallVector<Metadata *, 8> MDs{nullptr, Loc.get()};
  bool SawStart = false;
  if (MDNode *ID = L.getLoopID())
    for (const MDOperand &Op : llvm::drop_begin(ID->operands())) {
      if (isa<DILocation>(Op) && !SawStart) {
        if (Op.get() == Loc.get())
          return;
        SawStart = true;
        continue;
      }
      MDs.push_back(Op.get());
    }
  MDNode *ID = MDNode::getDistinct(L.getHeader()->getContext(), MDs);
  ID->replaceOperandWith(0, ID);
  L.setLoopID(ID);
}

void llvm::preserveScalarFissionStageMetadata(MDNode *ID, Loop &L) {
  if (!ID || !findOptionMDForLoopID(ID, StageMD))
    return;
  for (StringRef Name : {StageMD, ProducerMD, ConsumerMD})
    if (findOptionMDForLoopID(ID, Name) && !findOptionMDForLoop(&L, Name))
      L.addStringLoopAttribute(Name);
  for (const MDOperand &Op : drop_begin(ID->operands()))
    if (auto *Loc = dyn_cast<DILocation>(Op)) {
      setFissionStartLoc(L, DebugLoc(Loc));
      break;
    }
}

namespace {
enum class Transfer { Recompute, Scratch, ExistingBuffer };
struct State {
  PHINode *Phi;
  Value *Seed;
  Value *Next;
};
struct Stream {
  Instruction *Source;
  uint64_t Bytes;
  Align Alignment;
  StoreInst *ExistingStore = nullptr;
};
struct Contribution {
  unsigned Group;
  Value *Root;
  SmallPtrSet<Instruction *, 32> Dependencies;
};
struct StateGroup {
  SmallPtrSet<Instruction *, 32> Updates;
};
struct FissionPlan {
  Loop &L;
  SmallVector<BasicBlock *> Blocks;
  DenseMap<BasicBlock *, BasicBlock *> Contracted;
  SmallVector<State> States;
  SmallPtrSet<Instruction *, 32> Moved;
  MapVector<Instruction *, Transfer> Inputs;
  SmallVector<PHINode *> Inductions;
  SmallVector<Stream> Streams;
  bool SingleChunk = false;
  uint64_t Capacity = 0;
  uint64_t ScratchBytes = 0;
  uint64_t ScratchTraffic = 0;
  uint64_t OriginalReadBytes = 0;
  uint64_t OriginalWriteBytes = 0;
  uint64_t ConsumerReadBytes = 0;
  uint64_t AdditionalReadBytes = 0;
  SmallVector<StateGroup, 2> Groups;
  SmallVector<Contribution, 4> Contributions;
  DenseMap<Instruction *, unsigned> Membership;
  MapVector<Instruction *, StringRef> Boundaries;
  SmallPtrSet<Instruction *, 32> Retained;
  bool FinalPartition = false;
  unsigned ProducerDepth = 0;
  unsigned Budget = 4096;
  bool charge() {
    if (!Budget)
      return reject("analysis-budget");
    --Budget;
    return true;
  }
  StringRef Reason;
  explicit FissionPlan(Loop &L) : L(L) {}
  bool reject(StringRef R) {
    Reason = R;
    return false;
  }
};
} // namespace

static std::string inputName(const Value *V) {
  if (V->hasName())
    return V->getName().str();
  std::string Name;
  raw_string_ostream OS(Name);
  V->printAsOperand(OS, false);
  return Name;
}

static bool scalarType(Type *T) {
  return T->isIntegerTy() || T->isFloatingPointTy() || T->isPointerTy();
}

// Only closed, effect-free state updates move. The forward closure also checks
// intermediate uses: a value feeding a producer address, predicate, call, or
// another retained recurrence disqualifies that state, not unrelated states.
static bool movable(const Instruction &I) {
  if (!scalarType(I.getType()) || isa<ConstrainedFPIntrinsic>(I))
    return false;
  if (auto *II = dyn_cast<IntrinsicInst>(&I)) {
    switch (II->getIntrinsicID()) {
    case Intrinsic::smin:
    case Intrinsic::smax:
    case Intrinsic::umin:
    case Intrinsic::umax:
    case Intrinsic::fma:
    case Intrinsic::fmuladd:
      return !II->hasOperandBundles();
    default:
      return false;
    }
  }
  return isa<BinaryOperator, UnaryOperator, CastInst, CmpInst, SelectInst,
             PHINode, FreezeInst, GetElementPtrInst, ExtractValueInst>(I);
}

static bool collectState(PHINode &Phi, FissionPlan &P, LoopInfo &LI,
                         SmallPtrSetImpl<Instruction *> &Slice,
                         bool AllowStateGroups) {
  SmallVector<Instruction *> Work{&Phi};
  auto *Latch = P.L.getLoopLatch();
  auto *Exit = P.L.getUniqueExitBlock();
  for (unsigned N = 0; N != Work.size(); ++N) {
    if (!P.charge())
      return P.reject("analysis-budget");
    Instruction *I = Work[N];
    if (!Slice.insert(I).second)
      continue;
    if (!movable(*I) || LI.getLoopFor(I->getParent()) != &P.L)
      return false;
    if (!AllowStateGroups)
      if (auto *PN = dyn_cast<PHINode>(I);
          PN && PN->getParent() == P.L.getHeader() && PN != &Phi)
        return false;
    // Other header PHIs in the forward closure form one closed state group.
    // Every member is discovered below; a producer use of any member rejects
    // the entire closure, while independent states can still be considered.
    for (Use &U : I->uses()) {
      auto *User = dyn_cast<Instruction>(U.getUser());
      if (!User)
        return false;
      if (P.L.contains(User)) {
        Work.push_back(User);
        continue;
      }
      auto *Export = dyn_cast<PHINode>(User);
      if (!Export || Export->getParent() != Exit ||
          Export->getIncomingBlock(U.getOperandNo()) != Latch)
        return false;
    }
  }
  return Slice.contains(
      dyn_cast<Instruction>(Phi.getIncomingValueForBlock(Latch)));
}

// Conservatively recognize input relays through casts, merges, selection,
// freeze and identities. A genuine arithmetic operation on any data path is
// required before storing a computed stream. Control choices alone do not
// turn input snapshots into computed results. Cycles are not a proof.
static bool computedImpl(Value *V, SmallPtrSetImpl<Value *> &Seen,
                         unsigned &Budget, unsigned Depth) {
  if (!Budget)
    return false;
  --Budget;
  auto *I = dyn_cast<Instruction>(V);
  if (!I || Depth > 64 || !Seen.insert(V).second || isa<LoadInst>(I))
    return false;
  if (Value *Simple = simplifyInstruction(I, SimplifyQuery(I->getDataLayout())))
    if (Simple != I)
      return computedImpl(Simple, Seen, Budget, Depth + 1);
  if (isa<CastInst, PHINode, SelectInst, FreezeInst, GetElementPtrInst,
          ExtractValueInst>(I)) {
    unsigned Start = isa<SelectInst>(I) ? 1 : 0;
    bool AnyComputed = false;
    for (unsigned N = Start; N < I->getNumOperands(); ++N) {
      Value *Op = I->getOperand(N);
      if (isa<BasicBlock, Constant, Argument>(Op))
        continue;
      // Each alternative must be computed. Sharing a visited set across arms
      // would confuse repeated values with cycles, so inspect arms separately.
      SmallPtrSet<Value *, 32> ArmSeen(Seen.begin(), Seen.end());
      if (!computedImpl(Op, ArmSeen, Budget, Depth + 1))
        return false;
      AnyComputed = true;
    }
    return AnyComputed;
  }

  if (auto *BO = dyn_cast<BinaryOperator>(I)) {
    // InstSimplify is not used as a policy oracle: cover neutral operations
    // explicitly, including ones that are only neutral under FP flags.
    Value *A = BO->getOperand(0), *B = BO->getOperand(1);
    auto Zero = [](Value *X) {
      auto *C = dyn_cast<Constant>(X);
      return C && C->isNullValue();
    };
    auto One = [](Value *X) {
      auto *C = dyn_cast<ConstantInt>(X);
      return C && C->isOne();
    };
    bool Identity = false;
    switch (BO->getOpcode()) {
    case Instruction::Add:
    case Instruction::Or:
    case Instruction::Xor:
      Identity = Zero(A) || Zero(B);
      break;
    case Instruction::Sub:
    case Instruction::Shl:
    case Instruction::LShr:
    case Instruction::AShr:
      Identity = Zero(B);
      break;
    case Instruction::Mul:
      Identity = One(A) || One(B);
      break;
    case Instruction::And:
      Identity = PatternMatch::match(A, PatternMatch::m_AllOnes()) ||
                 PatternMatch::match(B, PatternMatch::m_AllOnes());
      break;
    case Instruction::FAdd:
    case Instruction::FSub:
      Identity = Zero(A) || Zero(B);
      break;
    case Instruction::FMul:
    case Instruction::FDiv:
      Identity = PatternMatch::match(A, PatternMatch::m_FPOne()) ||
                 PatternMatch::match(B, PatternMatch::m_FPOne());
      break;
    default:
      break;
    }
    if (Identity) {
      return computedImpl(A, Seen, Budget, Depth + 1) ||
             computedImpl(B, Seen, Budget, Depth + 1);
    }
  }
  return isa<BinaryOperator, UnaryOperator, CmpInst, CallInst>(I);
}

static bool computed(Value *V, SmallPtrSetImpl<Value *> &Seen, FissionPlan &P) {
  bool Result = computedImpl(V, Seen, P.Budget, 0);
  if (!P.Budget)
    P.reject("analysis-budget");
  return Result;
}

// Score only data dependencies in the final retained producer. Loads do not
// inherit address depth; control and addresses are reached only if they also
// produce data. Recurrence PHIs cut backedges, including in nested producers.
static bool measureProducerDepth(FissionPlan &P, LoopInfo &LI,
                                 ScalarEvolution &SE) {
  SmallPtrSet<Instruction *, 32> Data;
  std::function<void(Value *)> MarkData = [&](Value *V) {
    auto *I = dyn_cast<Instruction>(V);
    if (!I || !P.L.contains(I) || !Data.insert(I).second || !P.charge())
      return;
    if (isa<LoadInst, GetElementPtrInst>(I) ||
        (isa<PHINode>(I) && LI.isLoopHeader(I->getParent())))
      return;
    unsigned Start = isa<SelectInst>(I) ? 1 : 0;
    for (unsigned N = Start; N < I->getNumOperands(); ++N)
      if (!I->getOperand(N)->getType()->isPointerTy())
        MarkData(I->getOperand(N));
  };
  // Trace state results through their update graphs, skipping select
  // conditions. Predicate roots still count as contribution slices, but a
  // control-only input cannot acquire data depth merely by needing a transfer.
  // Likewise, load addresses are never data dependencies of a loaded result.
  for (const State &S : P.States)
    MarkData(S.Next);
  for (BasicBlock *BB : P.L.blocks())
    for (Instruction &I : *BB) {
      if (!P.Retained.contains(&I))
        continue;
      if (auto *Store = dyn_cast<StoreInst>(&I))
        MarkData(Store->getValueOperand());
      else if (isa<CallBase>(I))
        MarkData(&I);
      else if (auto *Phi = dyn_cast<PHINode>(&I); Phi && LI.isLoopHeader(BB)) {
        Loop *Owner = LI.getLoopFor(BB);
        InductionDescriptor ID;
        if (!InductionDescriptor::isInductionPHI(Phi, Owner, &SE, ID))
          for (Value *V : Phi->incoming_values())
            MarkData(V);
      }
    }
  DenseMap<Instruction *, unsigned> Depths;
  std::function<unsigned(Value *)> Depth = [&](Value *V) -> unsigned {
    auto *I = dyn_cast<Instruction>(V);
    if (!I || !P.Retained.contains(I) || !Data.contains(I))
      return 0;
    if (auto It = Depths.find(I); It != Depths.end())
      return It->second;
    if (!P.charge())
      return 0;
    Depths[I] = 0;
    if (isa<LoadInst, GetElementPtrInst>(I) ||
        (isa<PHINode>(I) && LI.isLoopHeader(I->getParent())))
      return 0;
    if (Value *Simple =
            simplifyInstruction(I, SimplifyQuery(I->getDataLayout()));
        Simple && Simple != I)
      return Depths[I] = Depth(Simple);
    unsigned Result = 0;
    // Select conditions describe execution, not an extra data calculation.
    unsigned Start = isa<SelectInst>(I) ? 1 : 0;
    for (unsigned N = Start; N < I->getNumOperands(); ++N)
      Result = std::max(Result, Depth(I->getOperand(N)));
    bool Induction =
        SE.isSCEVable(I->getType()) && isa<SCEVAddRecExpr>(SE.getSCEV(I));
    bool Operation =
        !Induction && isa<BinaryOperator, UnaryOperator, CmpInst, CallBase>(I);
    return Depths[I] = Result + unsigned(Operation);
  };
  for (BasicBlock *BB : P.L.blocks())
    for (Instruction &I : *BB)
      if (P.Retained.contains(&I))
        P.ProducerDepth = std::max(P.ProducerDepth, Depth(&I));
  return P.Reason.empty();
}

static bool safeCall(const CallBase &C) {
  // Calls stay at the same producer program point and are never duplicated.
  // Do not infer contracts from names, vector mappings, or host libraries.
  return isa<CallInst>(C) && !C.isInlineAsm() && !C.hasOperandBundles() &&
         !cast<CallInst>(C).isTailCall() && !C.isConvergent() &&
         !C.cannotDuplicate() && !C.cannotMerge() && !C.isStrictFP() &&
         !C.hasFnAttr(Attribute::ReturnsTwice) && C.doesNotThrow() &&
         C.hasFnAttr(Attribute::WillReturn) &&
         (C.doesNotAccessMemory() ||
          (C.hasFnAttr(Attribute::NoSync) && C.hasFnAttr(Attribute::NoFree) &&
           C.hasFnAttr(Attribute::NoCallback) &&
           C.getMemoryEffects().getModRef(IRMemLocation::InaccessibleMem) ==
               ModRefInfo::NoModRef));
}

// This deliberately conservative proof covers all reversed pairs C(i), P(j),
// i < j, not just the original instruction order. AA's NoModRef/NoAlias here
// must hold for arbitrary iterations: loop-varying pointers are compared via
// their underlying objects, never by treating two same-iteration GEPs as a
// cross-iteration dependence proof.
static bool stableMemory(Value *Pointer, FissionPlan &P, AAResults &AA,
                         Instruction *Ignore = nullptr) {
  const Value *Object = getUnderlyingObject(Pointer);
  if (!P.L.isLoopInvariant(Object))
    return false;
  MemoryLocation Loc = MemoryLocation::getBeforeOrAfter(Object);
  for (BasicBlock *BB : P.L.blocks())
    for (Instruction &I : *BB) {
      if (&I == Ignore)
        continue;
      if (auto *Store = dyn_cast<StoreInst>(&I)) {
        const Value *Other = getUnderlyingObject(Store->getPointerOperand());
        if (!P.L.isLoopInvariant(Other) ||
            AA.alias(Loc, MemoryLocation::getBeforeOrAfter(Other)) !=
                AliasResult::NoAlias)
          return false;
      } else if (auto *Call = dyn_cast<CallBase>(&I)) {
        if (isModSet(AA.getModRefInfo(Call, Loc)))
          return false;
      } else if (I.mayWriteToMemory()) {
        return false;
      }
    }
  return true;
}

static bool analyze(FissionPlan &P, LoopInfo &LI, DominatorTree &DT,
                    ScalarEvolution &SE, AAResults &AA,
                    bool AllowStateGroups = false) {
  Loop &L = P.L;
  BasicBlock *Header = L.getHeader(), *Latch = L.getLoopLatch();
  if (!Latch || !L.isLoopSimplifyForm() || !L.isLCSSAForm(DT) ||
      !L.hasDedicatedExits() || L.getExitingBlock() != Latch ||
      !L.getUniqueExitBlock())
    return P.reject("unsupported-iteration-boundary");
  auto *Branch = dyn_cast<BranchInst>(Latch->getTerminator());
  if (!Branch || !Branch->isConditional() ||
      (Branch->getSuccessor(0) != Header && Branch->getSuccessor(1) != Header))
    return P.reject("unsupported-exit");
  if (Header->getParent()->hasFnAttribute(Attribute::StrictFP))
    return P.reject("strict-fp");
  // Contract immediate child loops. Their execution and effects remain in the
  // producer, and the outer consumer sees only their LCSSA results.
  for (Loop *Sub : L.getSubLoops()) {
    if (!Sub->isLoopSimplifyForm() || !Sub->getUniqueExitBlock() ||
        !Sub->isRecursivelyLCSSAForm(DT, LI))
      return P.reject("unsupported-nested-exit");
    P.Contracted[Sub->getHeader()] = Sub->getUniqueExitBlock();
  }
  DenseMap<BasicBlock *, unsigned> Incoming;
  for (BasicBlock *BB : L.blocks()) {
    if (LI.getLoopFor(BB) != &L)
      continue;
    P.Blocks.push_back(BB);
    if (!isa<BranchInst>(BB->getTerminator()))
      return P.reject("unsupported-control");
    if (BB == Latch)
      continue;
    for (BasicBlock *Succ : successors(BB)) {
      if (auto *Contract = P.Contracted.lookup(Succ))
        Succ = Contract;
      if (Succ == Header || !L.contains(Succ) || LI.getLoopFor(Succ) != &L)
        return P.reject("unsupported-control");
      ++Incoming[Succ];
    }
  }
  SmallVector<BasicBlock *> Ready{Header};
  for (unsigned I = 0; I != Ready.size(); ++I) {
    if (Ready[I] == Latch)
      continue;
    for (BasicBlock *Succ : successors(Ready[I])) {
      if (auto *Contract = P.Contracted.lookup(Succ))
        Succ = Contract;
      if (--Incoming[Succ] == 0)
        Ready.push_back(Succ);
    }
  }
  if (Ready.size() != P.Blocks.size())
    return P.reject("irreducible-outer-control");
  for (PHINode &Phi : Header->phis()) {
    SmallPtrSet<Instruction *, 32> Slice;
    if (collectState(Phi, P, LI, Slice, AllowStateGroups)) {
      P.States.push_back({&Phi,
                          Phi.getIncomingValueForBlock(L.getLoopPreheader()),
                          Phi.getIncomingValueForBlock(Latch)});
      // Overlapping forward closures are one group, even if discovered from
      // several coupled header PHIs. Independent states keep their identities.
      for (auto It = P.Groups.begin(); It != P.Groups.end();) {
        if (any_of(It->Updates,
                   [&](Instruction *I) { return Slice.contains(I); })) {
          Slice.insert_range(It->Updates);
          It = P.Groups.erase(It);
        } else
          ++It;
      }
      P.Moved.insert_range(Slice);
      P.Groups.push_back({std::move(Slice)});
    }
    if (!P.Reason.empty())
      return false;
  }
  if (P.States.empty())
    return P.reject("no-closed-state");

  const DataLayout &DL = Header->getModule()->getDataLayout();
  for (BasicBlock *BB : L.blocks())
    for (Instruction &I : *BB) {
      if (!P.charge())
        return P.reject("analysis-budget");
      if (isa<ConstrainedFPIntrinsic>(I))
        return P.reject("strict-fp");
      if (auto *Load = dyn_cast<LoadInst>(&I)) {
        if (!Load->isSimple() || !scalarType(Load->getType()))
          return P.reject("non-simple-memory");
        P.OriginalReadBytes +=
            DL.getTypeStoreSize(Load->getType()).getFixedValue();
      } else if (auto *Store = dyn_cast<StoreInst>(&I)) {
        if (!Store->isSimple() ||
            !scalarType(Store->getValueOperand()->getType()))
          return P.reject("non-simple-memory");
        P.OriginalWriteBytes +=
            DL.getTypeStoreSize(Store->getValueOperand()->getType())
                .getFixedValue();
      } else if (auto *Call = dyn_cast<CallBase>(&I)) {
        if (!safeCall(*Call))
          return P.reject("unsafe-producer-call");
      } else if (!isa<BranchInst>(I) && !movable(I)) {
        return P.reject("unsupported-instruction");
      }
    }

  // Address reconstruction is independent of contribution sharing.
  // Recognize a bounded tree of original address operations. In particular a
  // load in this loop is never an invariant leaf. The emitter clones these
  // instructions at their original CFG positions, including widths and flags.
  std::function<bool(Value *, unsigned)> Address = [&](Value *V,
                                                       unsigned Depth) -> bool {
    if (L.isLoopInvariant(V))
      return true;
    if (!Depth || !P.charge())
      return false;
    auto *I = dyn_cast<Instruction>(V);
    if (!I || LI.getLoopFor(I->getParent()) != &L)
      return false;
    if (auto *Phi = dyn_cast<PHINode>(I)) {
      InductionDescriptor ID;
      return Phi->getParent() == Header &&
             InductionDescriptor::isInductionPHI(Phi, &L, &SE, ID) &&
             ID.getKind() == InductionDescriptor::IK_IntInduction &&
             ID.getConstIntStepValue() && ID.getInductionBinOp() &&
             L.isLoopInvariant(ID.getStartValue());
    }
    if (I->getOpcode() != Instruction::Add &&
        !isa<TruncInst, ZExtInst, SExtInst, GetElementPtrInst>(I))
      return false;
    return all_of(I->operands(),
                  [&](Value *Op) { return Address(Op, Depth - 1); });
  };
  auto AddressOrIV = [&](Instruction *I) {
    return Address(I, 8) ||
           (SE.isSCEVable(I->getType()) && isa<SCEVAddRecExpr>(SE.getSCEV(I)));
  };
  DenseMap<Instruction *, bool> VaryingInputs;
  std::function<bool(Value *)> Varying = [&](Value *V) {
    auto *I = dyn_cast<Instruction>(V);
    if (!I || !L.contains(I))
      return false;
    if (auto It = VaryingInputs.find(I); It != VaryingInputs.end())
      return It->second;
    if (!P.charge())
      return false;
    // Recurrences, reads and nondeterministic operations are varying leaves.
    // An invariant-only arithmetic tree is reconstructed in the consumer.
    VaryingInputs[I] = true;
    bool Result = isa<PHINode, LoadInst, CallBase, FreezeInst>(I) ||
                  any_of(I->operands(), Varying);
    return VaryingInputs[I] = Result;
  };
  auto InnerResult = [&](Instruction *I) {
    auto *Phi = dyn_cast<PHINode>(I);
    return Phi && Phi->getParent() != Header &&
           any_of(Phi->blocks(),
                  [&](BasicBlock *Pred) { return LI.getLoopFor(Pred) != &L; });
  };
  DenseMap<Instruction *, bool> Computations;
  auto Computed = [&](Instruction *I) {
    auto It = Computations.find(I);
    if (It != Computations.end())
      return It->second;
    SmallPtrSet<Value *, 32> Seen;
    bool Result = computed(I, Seen, P);
    Computations[I] = Result;
    return Result;
  };

  // An input is distinct within a closed group, rather than at each use or
  // header PHI. Collect in source order; hash-table order never chooses a cut.
  for (auto [G, Group] : enumerate(P.Groups)) {
    SmallPtrSet<Value *, 16> Roots;
    for (BasicBlock *BB : P.Blocks)
      for (Instruction &I : *BB)
        if (Group.Updates.contains(&I))
          for (Value *Op : I.operands()) {
            auto *Def = dyn_cast<Instruction>(Op);
            if (!Def || !L.contains(Def) || Group.Updates.contains(Def) ||
                !Roots.insert(Op).second)
              continue;
            P.Contributions.push_back({unsigned(G), Op, {}});
            Contribution &C = P.Contributions.back();
            SmallVector<Instruction *> Work{Def};
            while (!Work.empty()) {
              if (!P.charge())
                return false;
              Instruction *Node = Work.pop_back_val();
              if (!C.Dependencies.insert(Node).second)
                continue;
              // Count once per complete slice, including short slices and
              // reconvergent paths. Recurrences and nested LCSSA are leaves.
              if (!P.charge())
                return false;
              ++P.Membership[Node];
              if ((isa<PHINode>(Node) && Node->getParent() == Header) ||
                  InnerResult(Node))
                continue;
              for (Value *Operand : Node->operands())
                if (auto *Dep = dyn_cast<Instruction>(Operand);
                    Dep && L.contains(Dep) && !P.Moved.contains(Dep))
                  Work.push_back(Dep);
            }
          }
  }

  // Last shared-to-private edges, including 4 -> 2 -> 1 sharing levels.
  // Mandatory producer values supplement this frontier; they are not sharing.
  for (BasicBlock *BB : P.Blocks)
    for (Instruction &I : *BB) {
      if (!P.Membership.count(&I))
        continue;
      StringRef Why;
      if (InnerResult(&I))
        Why = "inner-result";
      else if (isa<ExtractValueInst>(I))
        Why = "aggregate-result";
      else if (isa<CallBase, FreezeInst>(I))
        Why = isa<CallBase>(I) ? "call" : "freeze";
      else if (P.Membership.lookup(&I) > 1 &&
               any_of(I.users(),
                      [&](User *U) {
                        auto *Use = dyn_cast<Instruction>(U);
                        return Use && P.Membership.lookup(Use) == 1;
                      }) &&
               !(isa<PHINode>(I) && I.getParent() == Header) &&
               !AddressOrIV(&I) && Varying(&I) && Computed(&I))
        Why = "last-shared";
      if (!Why.empty())
        P.Boundaries[&I] = Why;
    }
  // An independent computed input, or a shared root used directly by updates,
  // still needs a computed-result crossing when it has no selected ancestor.
  for (const Contribution &C : P.Contributions) {
    if (any_of(C.Dependencies,
               [&](Instruction *I) { return P.Boundaries.count(I); }))
      continue;
    auto *Root = cast<Instruction>(C.Root);
    if (!(isa<PHINode>(Root) && Root->getParent() == Header) &&
        !AddressOrIV(Root) && Varying(Root) && Computed(Root))
      P.Boundaries[Root] = "uncovered-root";
  }
  if (!P.Reason.empty())
    return false;

  // Resolve availability before committing the consumer closure. Each node has
  // one decision. Failed reconstruction promotes a genuine computed result to
  // a fallback boundary; no tentative stream/IV lists need rolling back.
  struct Availability {
    Transfer Mode = Transfer::Recompute;
    StringRef Failure;
  };
  DenseMap<Instruction *, Availability> Available;
  SmallPtrSet<Instruction *, 32> Visiting;
  std::function<StringRef(Value *)> Resolve = [&](Value *V) -> StringRef {
    auto *I = dyn_cast<Instruction>(V);
    if (!I || !L.contains(I) || P.Moved.contains(I))
      return {};
    if (auto It = Available.find(I); It != Available.end())
      return It->second.Failure;
    if (!P.charge())
      return P.Reason;
    if (!Visiting.insert(I).second)
      return "unsupported-input-cycle";
    auto Pop = make_scope_exit([&] { Visiting.erase(I); });
    Availability A;
    if (LI.getLoopFor(I->getParent()) != &L)
      A.Failure = "non-lcssa-inner-input";
    else if (auto *Phi = dyn_cast<PHINode>(I);
             Phi && Phi->getParent() == Header) {
      if (!Address(Phi, 8))
        A.Failure = "producer-state-input";
      // The induction's next value is included in the final closure below.
    } else if (P.Boundaries.count(I) || InnerResult(I) ||
               isa<CallBase, FreezeInst, ExtractValueInst>(I)) {
      if (!Computed(I))
        A.Failure = "forbidden-load-relay";
      else if (!scalarType(I->getType()))
        A.Failure = "unsupported-stream-type";
      else {
        A.Mode = Transfer::Scratch;
        if (!P.Boundaries.count(I))
          P.Boundaries[I] = InnerResult(I)     ? "inner-result"
                            : isa<CallBase>(I) ? "call"
                                               : "freeze";
      }
    } else {
      if (auto *Load = dyn_cast<LoadInst>(I)) {
        if (!stableMemory(Load->getPointerOperand(), P, AA))
          A.Failure = "load-snapshot-required";
      } else if (!movable(*I))
        A.Failure = "unsupported-consumer-input";
      if (A.Failure.empty())
        for (Value *Op : I->operands()) {
          A.Failure = Resolve(Op);
          if (!A.Failure.empty())
            break;
        }
      if ((A.Failure == "load-snapshot-required" ||
           A.Failure == "producer-state-input" ||
           A.Failure == "non-lcssa-inner-input") &&
          Computed(I)) {
        A.Failure = {};
        A.Mode = Transfer::Scratch;
        P.Boundaries[I] = "unavailable-dependency";
      }
    }
    Available[I] = A;
    return A.Failure;
  };
  auto Require = [&](Value *V) {
    StringRef Failure = Resolve(V);
    return P.Reason.empty() && (Failure.empty() || P.reject(Failure));
  };
  for (const Contribution &C : P.Contributions)
    if (!Require(C.Root))
      return false;
  // Control is a consumer dependency, never an extra contribution slice.
  for (BasicBlock *BB : P.Blocks)
    if (BB != Latch)
      if (auto *Br = cast<BranchInst>(BB->getTerminator()); Br->isConditional())
        if (!Require(Br->getCondition()))
          return false;

  std::function<bool(Value *)> Commit = [&](Value *V) {
    auto *I = dyn_cast<Instruction>(V);
    if (!I || !L.contains(I) || P.Moved.contains(I) || P.Inputs.count(I))
      return true;
    if (!P.charge() || !Require(I))
      return false;
    Transfer T = Available.lookup(I).Mode;
    P.Inputs[I] = T;
    if (T == Transfer::Scratch) {
      P.Streams.push_back({I, DL.getTypeAllocSize(I->getType()).getFixedValue(),
                           DL.getABITypeAlign(I->getType())});
      return true;
    }
    if (auto *Phi = dyn_cast<PHINode>(I); Phi && Phi->getParent() == Header)
      P.Inductions.push_back(Phi);
    for (Value *Op : I->operands())
      if (!Commit(Op))
        return false;
    return true;
  };
  for (const Contribution &C : P.Contributions)
    if (!Commit(C.Root))
      return false;
  for (BasicBlock *BB : P.Blocks)
    if (BB != Latch)
      if (auto *Br = cast<BranchInst>(BB->getTerminator()); Br->isConditional())
        if (!Commit(Br->getCondition()))
          return false;
  if (P.Streams.empty())
    return P.reject("no-computed-boundary");
  // Reuse an existing result array only with an injective, nonwrapping
  // original IV and a same-path store. Every other possible writer must be
  // disjoint for the whole schedule. No new noalias assumption is introduced.
  unsigned NumStreams = P.Streams.size();
  for (unsigned N = 0; N < NumStreams; ++N) {
    Instruction *Source = P.Streams[N].Source;
    for (User *U : Source->users()) {
      auto *Store = dyn_cast<StoreInst>(U);
      if (!Store || Store->getValueOperand() != Source ||
          Store->getParent() != Source->getParent() || !Store->isSimple())
        continue;
      auto *GEP = dyn_cast<GetElementPtrInst>(Store->getPointerOperand());
      if (!GEP || !GEP->isInBounds() || GEP->getNumIndices() != 1 ||
          GEP->getSourceElementType() != Source->getType() ||
          !L.isLoopInvariant(GEP->getPointerOperand()) ||
          !DT.dominates(GEP, Source))
        continue;
      auto *IV = dyn_cast<PHINode>(GEP->getOperand(1));
      if (!IV || IV != L.getCanonicalInductionVariable())
        continue;
      auto *Next =
          dyn_cast<BinaryOperator>(IV->getIncomingValueForBlock(Latch));
      if (!Next || !Next->hasNoUnsignedWrap() ||
          !stableMemory(GEP, P, AA, Store))
        continue;
      if (!Commit(GEP))
        return false;
      P.Inputs[Source] = Transfer::ExistingBuffer;
      P.Streams[N].ExistingStore = Store;
      P.Streams[N].Alignment = Store->getAlign();
      break;
    }
  }
  // Discard reconstruction below a selected scratch boundary. Keeping these
  // nodes would introduce unused reads and references into producer-only CFG.
  SmallPtrSet<Instruction *, 32> Needed;
  std::function<void(Value *)> Mark = [&](Value *V) {
    auto *I = dyn_cast<Instruction>(V);
    if (!I || !L.contains(I) || !Needed.insert(I).second)
      return;
    if (!P.charge())
      return;
    if (P.Inputs.count(I) && P.Inputs.lookup(I) != Transfer::Recompute) {
      if (P.Inputs.lookup(I) == Transfer::ExistingBuffer)
        for (const Stream &S : P.Streams)
          if (S.Source == I)
            Mark(S.ExistingStore->getPointerOperand());
      return;
    }
    for (Value *Op : I->operands())
      Mark(Op);
  };
  auto ConsumerNeeds = [&] {
    Needed.clear();
    for (Instruction *I : P.Moved)
      Mark(I);
    for (BasicBlock *BB : P.Blocks)
      if (BB != Latch)
        if (auto *Br = cast<BranchInst>(BB->getTerminator());
            Br->isConditional())
          Mark(Br->getCondition());
    P.Inputs.remove_if(
        [&](const auto &Entry) { return !Needed.contains(Entry.first); });
    llvm::erase_if(P.Streams,
                   [&](const Stream &S) { return !Needed.contains(S.Source); });
    llvm::erase_if(P.Inductions,
                   [&](PHINode *I) { return !Needed.contains(I); });
  };
  auto &Retained = P.Retained;
  auto ProducerNeeds = [&](Instruction *Omit) {
    Retained.clear();
    SmallVector<Instruction *> Work;
    auto Add = [&](Value *V) {
      auto *I = dyn_cast<Instruction>(V);
      if (I && L.contains(I) && !P.Moved.contains(I) &&
          Retained.insert(I).second)
        Work.push_back(I);
    };
    for (BasicBlock *BB : L.blocks())
      for (Instruction &I : *BB) {
        if (I.isTerminator() || I.mayHaveSideEffects() ||
            isa<CallBase, FreezeInst>(&I) ||
            (isa<PHINode>(&I) && BB == Header) ||
            any_of(I.users(), [&](User *U) {
              auto *UI = dyn_cast<Instruction>(U);
              return !UI || !L.contains(UI);
            }))
          Add(&I);
      }
    for (const Stream &S : P.Streams)
      if (S.Source != Omit)
        Add(S.Source);
    while (!Work.empty()) {
      if (!P.Budget) {
        P.reject("analysis-budget");
        return;
      }
      --P.Budget;
      for (Value *Op : Work.pop_back_val()->operands())
        Add(Op);
    }
  };
  // Removing a synthetic store can make its private source dead. Only move a
  // multiply whose operands already have dominating consumer definitions; this
  // never opens a new input walk, adds a read, or duplicates producer work.
  bool Changed;
  do {
    ConsumerNeeds();
    Changed = false;
    for (const Stream &S : P.Streams) {
      Instruction *I = S.Source;
      if (S.ExistingStore || I->getOpcode() != Instruction::FMul ||
          LI.getLoopFor(I->getParent()) != &L || P.Streams.size() == 1)
        continue;
      bool Available = all_of(I->operands(), [&](Value *Op) {
        if (L.isLoopInvariant(Op))
          return DT.dominates(Op, I);
        auto *Def = dyn_cast<Instruction>(Op);
        return Def && Needed.contains(Def) && P.Inputs.count(Def) &&
               DT.dominates(Def, I);
      });
      if (!Available)
        continue;
      ProducerNeeds(I);
      if (!P.Reason.empty())
        return false;
      if (Retained.contains(I))
        continue;
      P.Inputs[I] = Transfer::Recompute;
      llvm::erase_if(P.Streams,
                     [&](const Stream &Stream) { return Stream.Source == I; });
      Changed = true;
      break;
    }
  } while (Changed);
  ProducerNeeds(nullptr);
  if (!P.Reason.empty())
    return false;
  // Validate the authoritative consumer closure before emission can remap it.
  // Original SSA dominance and CFG positions are preserved, including PHI
  // edges.
  for (Instruction *I : Needed) {
    if (P.Moved.contains(I) || P.Inputs.count(I))
      continue;
    return P.reject("unavailable-consumer-definition");
  }
  P.FinalPartition = true;
  if (!measureProducerDepth(P, LI, SE))
    return false;
  if (P.ProducerDepth < 3)
    return P.reject("producer-too-shallow");
  P.ConsumerReadBytes = 0;
  P.AdditionalReadBytes = 0;
  for (auto [I, T] : P.Inputs)
    if (auto *Load = dyn_cast<LoadInst>(I)) {
      uint64_t Bytes = DL.getTypeStoreSize(Load->getType()).getFixedValue();
      P.ConsumerReadBytes += Bytes;
      if (Retained.contains(Load))
        P.AdditionalReadBytes += Bytes;
    }
  P.ScratchTraffic = 0;
  for (const Stream &S : P.Streams)
    if (!S.ExistingStore)
      P.ScratchTraffic +=
          DL.getTypeStoreSize(S.Source->getType()).getFixedValue();
  if (!P.Reason.empty())
    return false;
  auto Size = [&](uint64_t Count) -> std::optional<uint64_t> {
    uint64_t Bytes = 0;
    for (const Stream &S : P.Streams) {
      if (S.ExistingStore)
        continue;
      auto Pad = checkedAddUnsigned(Bytes, S.Alignment.value() - 1);
      auto Total = Pad ? checkedMulAddUnsigned(
                             Count, S.Bytes, *Pad & ~(S.Alignment.value() - 1))
                       : std::nullopt;
      if (!Total || *Total > MaxScratch ||
          !isUIntN(DL.getIndexSizeInBits(DL.getAllocaAddrSpace()) - 1, *Total))
        return std::nullopt;
      Bytes = *Total;
    }
    return Bytes;
  };
  if (!MaxCapacity || !Size(1))
    return P.reject("scratch-limit");
  unsigned Bound = SE.getSmallConstantMaxTripCount(&L);
  uint64_t Low = 1, High = Bound ? std::min(unsigned(MaxCapacity), Bound)
                                 : unsigned(MaxCapacity);
  while (Low < High) {
    uint64_t Mid = Low + (High - Low) / 2 + 1;
    if (Size(Mid))
      Low = Mid;
    else
      High = Mid - 1;
  }
  P.SingleChunk = Bound && Bound <= Low;
  P.Capacity = Low;
  P.ScratchBytes = *Size(Low);
  return true;
}

static MDNode *stageID(LLVMContext &C, MDNode *Original, StringRef Stage,
                       unsigned VF = 0, bool Scalable = false,
                       unsigned IC = 0) {
  SmallVector<Metadata *> MDs{nullptr};
  if (Original)
    for (const MDOperand &Op : drop_begin(Original->operands())) {
      auto *Node = dyn_cast<MDNode>(Op);
      auto *Name = Node && Node->getNumOperands()
                       ? dyn_cast<MDString>(Node->getOperand(0))
                       : nullptr;
      // mustprogress on the source loop does not describe a stage, which can
      // have a different observable-effect profile. Do not copy follow-up IDs
      // that would silently restore source VF hints after vectorization.
      if (Name &&
          (Name->getString() == "llvm.loop.mustprogress" ||
           Name->getString().contains("followup") ||
           Name->getString().starts_with("llvm.loop.scalar_fission.") ||
           (VF && Name->getString().starts_with("llvm.loop.vectorize.")) ||
           (IC && Name->getString() == "llvm.loop.interleave.count")))
        continue;
      MDs.push_back(Op);
    }
  MDs.push_back(MDNode::get(C, MDString::get(C, StageMD)));
  if (Stage != StageMD)
    MDs.push_back(MDNode::get(C, MDString::get(C, Stage)));
  auto IntMD = [&](StringRef Name, unsigned Value, unsigned Bits) {
    MDs.push_back(MDNode::get(
        C, {MDString::get(C, Name), ConstantAsMetadata::get(ConstantInt::get(
                                        IntegerType::get(C, Bits), Value))}));
  };
  if (VF) {
    IntMD("llvm.loop.vectorize.width", VF, 32);
    IntMD("llvm.loop.vectorize.scalable.enable", Scalable, 1);
    IntMD("llvm.loop.vectorize.enable", VF != 1 || Scalable, 1);
  }
  if (IC)
    IntMD("llvm.loop.interleave.count", IC, 32);
  // Keep requested settings separate from actual LV observations.
  IntMD("llvm.loop.scalar_fission.requested_vf", VF, 32);
  IntMD("llvm.loop.scalar_fission.requested_scalable", Scalable, 1);
  IntMD("llvm.loop.scalar_fission.requested_ic", IC, 32);
  MDNode *ID = MDNode::getDistinct(C, MDs);
  ID->replaceOperandWith(0, ID);
  return ID;
}

static void emit(FissionPlan &P, DominatorTree &DT, LoopInfo &LI,
                 ScalarEvolution &SE) {
  Loop &L = P.L;
  auto *Header = L.getHeader(), *Latch = L.getLoopLatch();
  auto *Preheader = L.getLoopPreheader(), *Exit = L.getUniqueExitBlock();
  auto *Branch = cast<BranchInst>(Latch->getTerminator());
  Function &F = *Header->getParent();
  LLVMContext &C = F.getContext();
  const DataLayout &DL = F.getDataLayout();
  MDNode *OriginalID = L.getLoopID();
  DebugLoc Loc = L.getStartLoc();
  SE.forgetAllLoops();

  auto NewBlock = [&](const Twine &Name) {
    return BasicBlock::Create(C, Name, &F, Exit);
  };
  BasicBlock *Chunk = NewBlock("scalar.fission.chunk");
  BasicBlock *ProducerPH = NewBlock("scalar.fission.producer.ph");
  BasicBlock *ProducerExit = NewBlock("scalar.fission.producer.exit");
  BasicBlock *ConsumerPH = NewBlock("scalar.fission.consumer.ph");
  BasicBlock *ConsumerExit = NewBlock("scalar.fission.consumer.exit");
  BasicBlock *ChunkLatch = NewBlock("scalar.fission.chunk.latch");
  // Snapshot every original recurrence and exit edge before editing any use.
  SmallVector<State> OriginalState;
  for (PHINode &Phi : Header->phis())
    OriginalState.push_back({&Phi, Phi.getIncomingValueForBlock(Preheader),
                             Phi.getIncomingValueForBlock(Latch)});
  SmallVector<std::pair<PHINode *, Value *>> Exports;
  for (PHINode &Phi : Exit->phis())
    if (int Idx = Phi.getBasicBlockIndex(Latch); Idx >= 0)
      Exports.emplace_back(&Phi, Phi.getIncomingValue(Idx));

  IRBuilder<> B(Chunk);
  B.SetCurrentDebugLocation(Loc);
  DenseMap<Value *, PHINode *> Carries;
  for (const State &S : OriginalState) {
    Value *Seed = S.Seed;
    if (!P.SingleChunk) {
      auto *Carry =
          B.CreatePHI(S.Phi->getType(), 2, S.Phi->getName() + ".chunk");
      Carry->addIncoming(Seed, Preheader);
      Carries[S.Phi] = Carry;
      Seed = Carry;
    }
    S.Phi->replaceIncomingBlockWith(Preheader, ProducerPH);
    S.Phi->setIncomingValueForBlock(ProducerPH, Seed);
  }
  B.CreateBr(ProducerPH);
  BranchInst::Create(Header, ProducerPH)->setDebugLoc(Loc);
  Preheader->getTerminator()->replaceSuccessorWith(Header, Chunk);

  // Consumer control clones only the outer iteration graph. There is one
  // consumer iteration per completed producer iteration, even when no state
  // participates. Branches preserve lazy execution; selects remain selects.
  ValueToValueMapTy Map;
  for (BasicBlock *BB : P.Blocks)
    Map[BB] = NewBlock(BB->getName() + ".consume");
  for (auto [Inner, After] : P.Contracted)
    Map[Inner] = Map[After];
  Map[Preheader] = ConsumerPH;
  Map[ProducerPH] = ConsumerPH;
  Map[Exit] = ConsumerExit;
  BranchInst::Create(cast<BasicBlock>(Map[Header]), ConsumerPH);
  for (BasicBlock *BB : P.Blocks) {
    auto *Dest = cast<BasicBlock>(Map[BB]);
    for (Instruction &I : *BB) {
      bool Copy =
          P.Moved.contains(&I) ||
          (P.Inputs.count(&I) && P.Inputs.lookup(&I) == Transfer::Recompute);
      if (isa<BranchInst>(I))
        Copy = true;
      if (!Copy)
        continue;
      Instruction *Clone = I.clone();
      Clone->insertInto(Dest, Dest->end());
      if (!I.getType()->isVoidTy())
        Clone->setName(I.getName() + ".consume");
      Map[&I] = Clone;
    }
  }

  // A fixed-width local ordinal is bounded by the checked capacity, independent
  // of the source IV width, wrap, total count, or data-dependent termination.
  auto *CountTy = Type::getInt64Ty(C);
  auto *Ordinal =
      PHINode::Create(CountTy, 2, "fission.producer.ordinal", Header->begin());
  Ordinal->addIncoming(ConstantInt::get(CountTy, 0), ProducerPH);
  B.SetInsertPoint(Branch);
  Value *NextOrdinal =
      B.CreateAdd(Ordinal, B.getInt64(1), "fission.completed", true);
  Ordinal->addIncoming(NextOrdinal, Latch);
  Value *Continue =
      Branch->getSuccessor(0) == Header
          ? Branch->getCondition()
          : B.CreateNot(Branch->getCondition(), "fission.continue");
  Value *More = Continue;
  if (!P.SingleChunk) {
    More = B.CreateICmpULT(NextOrdinal, B.getInt64(P.Capacity));
    // Preserve the original conditional poison semantics.
    More = B.CreateSelect(Continue, More, B.getFalse(), "fission.more");
  }
  Branch->setCondition(More);
  Branch->setSuccessor(0, Header);
  Branch->setSuccessor(1, ProducerExit);
  Branch->setMetadata(LLVMContext::MD_prof, nullptr);

  DenseMap<Value *, Value *> ProducerExports;
  auto ExportProducer = [&](Value *V) -> Value * {
    if (Value *Existing = ProducerExports.lookup(V))
      return Existing;
    if (L.isLoopInvariant(V))
      return V;
    auto *Phi = PHINode::Create(V->getType(), 1, V->getName() + ".produced",
                                ProducerExit);
    Phi->addIncoming(V, Latch);
    ProducerExports[V] = Phi;
    return Phi;
  };
  Value *Completed = ExportProducer(NextOrdinal);
  Value *MoreChunks = P.SingleChunk ? nullptr : ExportProducer(Continue);
  for (const State &S : OriginalState)
    if (!P.SingleChunk && !P.Moved.contains(S.Phi))
      Carries[S.Phi]->addIncoming(ExportProducer(S.Next), ChunkLatch);
  for (auto [Phi, V] : Exports)
    if (!P.Moved.contains(dyn_cast<Instruction>(V)))
      Phi->setIncomingValueForBlock(Latch, ExportProducer(V));
  B.SetInsertPoint(ProducerExit);
  // Freeze a known nonpoison count to discourage SCEV from reconstructing the
  // original (possibly uncountable) termination in the consumer.
  Value *Count = B.CreateFreeze(Completed, "fission.consumer.count");
  B.CreateBr(ConsumerPH);

  auto *ConsumerHeader = cast<BasicBlock>(Map[Header]);
  auto *ConsumerLatch = cast<BasicBlock>(Map[Latch]);
  auto *ConsumerOrdinal = PHINode::Create(
      CountTy, 2, "fission.consumer.ordinal", ConsumerHeader->begin());
  ConsumerOrdinal->addIncoming(ConstantInt::get(CountTy, 0), ConsumerPH);
  IRBuilder<> Entry(&*F.getEntryBlock().getFirstInsertionPt());
  SmallVector<AllocaInst *> Scratch;
  for (const Stream &S : P.Streams) {
    auto *Array = ArrayType::get(S.Source->getType(), P.Capacity);
    AllocaInst *Slot = nullptr;
    auto *Source = S.Source;
    if (!S.ExistingStore) {
      Slot = Entry.CreateAlloca(Array, DL.getAllocaAddrSpace(), nullptr,
                                "scalar.fission.scratch");
      Slot->setAlignment(S.Alignment);
      Scratch.push_back(Slot);
      // The preheader executes once per complete schedule, even when this
      // schedule is nested in another loop. Never end between chunks.
      IRBuilder<> Start(Preheader->getTerminator());
      Start.CreateLifetimeStart(Slot);
      // Provenance is diagnostic only, never an alias or legality claim.
      Slot->setMetadata(
          "scalar.fission.source",
          MDNode::get(C, MDString::get(C, Source->getOpcodeName())));
      IRBuilder<> StoreBuilder(Source->getParent(),
                               isa<PHINode>(Source)
                                   ? Source->getParent()->getFirstInsertionPt()
                                   : std::next(Source->getIterator()));
      Value *Address = StoreBuilder.CreateInBoundsGEP(
          Array, Slot, {StoreBuilder.getInt32(0), Ordinal});
      StoreBuilder.CreateAlignedStore(Source, Address, S.Alignment);
    }
    auto *Dest = cast<BasicBlock>(Map[Source->getParent()]);
    // Insert at the source's position in the copied block. For a removed PHI
    // (an inner-loop LCSSA export), insert after the remaining PHIs.
    BasicBlock::iterator At = Dest->getFirstInsertionPt();
    if (!isa<PHINode>(Source)) {
      At = Dest->end();
      for (auto It = std::next(Source->getIterator());
           It != Source->getParent()->end(); ++It)
        if (Value *Next = Map.lookup(&*It)) {
          At = cast<Instruction>(Next)->getIterator();
          break;
        }
    }
    IRBuilder<> LoadBuilder(Dest, At);
    Value *ReadAddress = nullptr;
    if (S.ExistingStore) {
      ReadAddress = Map.lookup(S.ExistingStore->getPointerOperand());
      if (!ReadAddress)
        ReadAddress = S.ExistingStore->getPointerOperand();
    } else {
      ReadAddress = LoadBuilder.CreateInBoundsGEP(
          Array, Slot, {LoadBuilder.getInt32(0), ConsumerOrdinal});
    }
    Map[Source] = LoadBuilder.CreateAlignedLoad(Source->getType(), ReadAddress,
                                                S.Alignment,
                                                Source->getName() + ".scratch");
  }
  // Remap only actual clones; generated scratch GEPs refer to the new ordinal.
  for (BasicBlock *BB : P.Blocks)
    for (Instruction &I : *BB) {
      if (P.Inputs.count(&I) && P.Inputs.lookup(&I) != Transfer::Recompute)
        continue;
      auto *Clone = dyn_cast_or_null<Instruction>(Map.lookup(&I));
      if (!Clone)
        continue;
      // Latch control is replaced below; it may name producer-only values.
      if (&I == Branch)
        continue;
      RemapInstruction(Clone, Map,
                       RF_IgnoreMissingLocals | RF_NoModuleLevelChanges);
    }
  for (const State &S : OriginalState)
    if (auto *Phi = dyn_cast_or_null<PHINode>(Map.lookup(S.Phi)))
      Phi->setIncomingValueForBlock(ConsumerPH,
                                    P.SingleChunk ? S.Seed : Carries[S.Phi]);

  auto *ConsumerBranch = cast<BranchInst>(Map[Branch]);
  B.SetInsertPoint(ConsumerBranch);
  auto *ConsumerNext = B.CreateAdd(ConsumerOrdinal, B.getInt64(1),
                                   "fission.consumer.next", true);
  ConsumerOrdinal->addIncoming(ConsumerNext, ConsumerLatch);
  auto *ConsumerMore = B.CreateICmpULT(ConsumerNext, Count);
  ConsumerBranch->setCondition(ConsumerMore);
  ConsumerBranch->setSuccessor(0, ConsumerHeader);
  ConsumerBranch->setSuccessor(1, ConsumerExit);
  ConsumerBranch->setMetadata(LLVMContext::MD_prof, nullptr);

  DenseMap<Value *, Value *> ConsumerExports;
  auto ExportConsumer = [&](Value *V) -> Value * {
    if (Value *Existing = ConsumerExports.lookup(V))
      return Existing;
    Value *Mapped = Map.lookup(V);
    if (!Mapped)
      Mapped = V;
    auto *Phi = PHINode::Create(V->getType(), 1, V->getName() + ".consumed",
                                ConsumerExit);
    Phi->addIncoming(Mapped, ConsumerLatch);
    ConsumerExports[V] = Phi;
    return Phi;
  };
  if (!P.SingleChunk)
    for (const State &S : P.States)
      Carries[S.Phi]->addIncoming(ExportConsumer(S.Next), ChunkLatch);
  for (auto [Phi, V] : Exports) {
    if (P.Moved.contains(dyn_cast<Instruction>(V)))
      Phi->setIncomingValueForBlock(Latch, ExportConsumer(V));
    Phi->replaceIncomingBlockWith(Latch, ChunkLatch);
  }
  BranchInst::Create(ChunkLatch, ConsumerExit);
  B.SetInsertPoint(ChunkLatch);
  // All original exits go through the consumer and then the dedicated exit.
  // Its entry is therefore after every scratch read on the completed path.
  IRBuilder<> End(&*Exit->getFirstInsertionPt());
  for (AllocaInst *Slot : Scratch)
    End.CreateLifetimeEnd(Slot);
  if (P.SingleChunk)
    B.CreateBr(Exit);
  else
    B.CreateCondBr(MoreChunks, Chunk, Exit);

  // Only direct FP sums get the explicit opt-in permission. Compound updates,
  // subtraction, compensation, and accumulator-dependent FMA remain ordered.
  if (Reassociate)
    for (const State &S : P.States) {
      BinaryOperator *Update = nullptr;
      for (User *U : S.Phi->users())
        if (auto *BO = dyn_cast<BinaryOperator>(U);
            BO && BO->getOpcode() == Instruction::FAdd && !Update)
          Update = BO;
      if (!Update ||
          (Update->getOperand(0) == S.Phi) == (Update->getOperand(1) == S.Phi))
        continue;
      bool SumOnly = true;
      for (User *U : S.Phi->users())
        SumOnly &= U == Update || U == S.Next;
      if (S.Next != Update) {
        auto *Merge = dyn_cast<PHINode>(S.Next);
        auto *Select = dyn_cast<SelectInst>(S.Next);
        if (!Merge && !Select)
          continue;
        if (Merge)
          for (Value *V : Merge->incoming_values())
            SumOnly &= V == S.Phi || V == Update;
        if (Select)
          SumOnly &= (Select->getTrueValue() == Update &&
                      Select->getFalseValue() == S.Phi) ||
                     (Select->getFalseValue() == Update &&
                      Select->getTrueValue() == S.Phi);
      }
      if (SumOnly)
        cast<Instruction>(Map[Update])->setHasAllowReassoc(true);
    }
  for (Instruction *I : P.Moved)
    I->dropAllReferences();
  for (Instruction *I : P.Moved)
    I->eraseFromParent();
  // Remove inputs whose sole consumers moved. This also distinguishes moved
  // loads from actual rereads. Calls and stores retain their program points.
  SmallVector<WeakTrackingVH> Dead;
  // Include dead users outside the consumer closure: they must not keep a
  // pruned suffix (or a moved load) alive in the producer. Preserve the calls
  // and freezes used as retention roots during analysis.
  for (BasicBlock *BB : P.Blocks)
    for (Instruction &I : *BB)
      Dead.push_back(&I);
  while (!Dead.empty()) {
    auto *I = dyn_cast_or_null<Instruction>(Dead.pop_back_val());
    if (!I || isa<CallBase, FreezeInst>(I) || !isInstructionTriviallyDead(I))
      continue;
    for (Value *Op : I->operands())
      if (auto *Def = dyn_cast<Instruction>(Op); Def && L.contains(Def))
        Dead.push_back(Def);
    I->eraseFromParent();
  }

  unsigned PVF = ProducerVF ? unsigned(ProducerVF) : unsigned(OldProducerVF);
  unsigned CVF = ConsumerVF ? unsigned(ConsumerVF) : unsigned(OldConsumerVF);
  Branch->setMetadata(
      LLVMContext::MD_loop,
      stageID(C, OriginalID, ProducerMD, PVF,
              ProducerScalable || (!ProducerVF && OldProducerVF), ProducerIC));
  ConsumerBranch->setMetadata(
      LLVMContext::MD_loop,
      stageID(C, OriginalID, ConsumerMD, CVF,
              ConsumerScalable || (!ConsumerVF && OldConsumerVF), ConsumerIC));
  if (!P.SingleChunk)
    ChunkLatch->getTerminator()->setMetadata(
        LLVMContext::MD_loop, stageID(C, nullptr, StageMD, 1, false, 1));
  // Rebuild after emission; never reuse a Loop pointer or plan across this
  // boundary. No MemorySSA preservation is claimed.
  DT.recalculate(F);
  LI.releaseMemory();
  LI.analyze(DT);
  setFissionStartLoc(*LI.getLoopFor(Header), Loc);
  setFissionStartLoc(*LI.getLoopFor(ConsumerHeader), Loc);
  for (Loop *Top : LI)
    formLCSSARecursively(*Top, DT, &LI, nullptr);
}

PreservedAnalyses ScalarFissionPass::run(Function &F,
                                         FunctionAnalysisManager &AM) {
  if (OldScalarEnable.getNumOccurrences() && !OldScalarEnable) {
    F.getContext().emitError(
        "VPlan-only fission was removed; use -passes=scalar-fission or disable "
        "-enable-scalar-fission");
    return PreservedAnalyses::all();
  }
  if (F.hasOptNone())
    return PreservedAnalyses::all();
  for (unsigned VF :
       {unsigned(ProducerVF), unsigned(ConsumerVF), unsigned(OldProducerVF),
        unsigned(OldConsumerVF), unsigned(ProducerIC), unsigned(ConsumerIC)})
    if (VF && !isPowerOf2_32(VF)) {
      F.getContext().emitError(
          "scalar-fission VF and interleave must be powers of two");
      return PreservedAnalyses::all();
    }
  if (OldRecipes.getNumOccurrences() || OldSearch.getNumOccurrences() ||
      OldDepth.getNumOccurrences() || OldReductions.getNumOccurrences() ||
      OldPressure.getNumOccurrences() || OldCombine.getNumOccurrences())
    errs() << "scalar-fission: obsolete VPlan search/profitability option "
              "ignored; "
              "use scalar-fission stage metadata and VF sweep instead\n";

  // These standard canonicalizations may change rejected loops. The fission
  // transaction itself starts only after normalization and never mutates on
  // rejection. Rotation makes a pretested loop's zero-trip guard explicit.
  FunctionPassManager Normalize;
  Normalize.addPass(LoopSimplifyPass());
  Normalize.addPass(LCSSAPass());
  Normalize.addPass(createFunctionToLoopPassAdaptor(LoopRotatePass()));
  Normalize.run(F, AM);
  SmallPtrSet<BasicBlock *, 32> Attempted;
  while (true) {
    auto &LI = AM.getResult<LoopAnalysis>(F);
    auto &DT = AM.getResult<DominatorTreeAnalysis>(F);
    auto &SE = AM.getResult<ScalarEvolutionAnalysis>(F);
    auto &AA = AM.getResult<AAManager>(F);
    auto &ORE = AM.getResult<OptimizationRemarkEmitterAnalysis>(F);
    Loop *Candidate = nullptr;
    // Preorder intentionally considers outer producer nests first.
    for (Loop *L : LI.getLoopsInPreorder()) {
      bool Stage = false;
      for (Loop *A = L; A; A = A->getParentLoop())
        Stage |= findOptionMDForLoop(A, StageMD) != nullptr;
      if (!Stage &&
          !findOptionMDForLoop(L, "llvm.loop.scalar_fission.disable") &&
          Attempted.insert(L->getHeader()).second) {
        Candidate = L;
        break;
      }
    }
    if (!Candidate)
      break;
    FissionPlan Primary(*Candidate), Grouped(*Candidate);
    FissionPlan *Chosen = &Primary;
    bool Valid = analyze(Primary, LI, DT, SE, AA);
    // Prefer terminal states, retaining producer recurrences. If none close
    // individually, try a coupled state group. Growing an already legal cut
    // can turn a computed boundary into an unsafe raw-input snapshot.
    if (!Valid && Primary.Reason == "no-closed-state") {
      Valid = analyze(Grouped, LI, DT, SE, AA, /*AllowStateGroups=*/true);
      Chosen = &Grouped;
    }
    FissionPlan &P = *Chosen;
    // Bounded analysis records distinguish graph membership, the initial cut,
    // and the final transfers after availability resolution and cleanup.
    unsigned Records = 0;
    for (const Contribution &C : P.Contributions) {
      if (Records++ == 128)
        break;
      ORE.emit([&] {
        return OptimizationRemarkAnalysis("scalar-fission", "Contribution",
                                          Candidate->getStartLoc(),
                                          Candidate->getHeader())
               << "contribution group " << ore::NV("StateGroup", C.Group)
               << ", root " << ore::NV("Root", inputName(C.Root))
               << ", slice size "
               << ore::NV("SliceSize", C.Dependencies.size());
      });
    }
    Records = 0;
    for (BasicBlock *BB : Candidate->blocks())
      for (Instruction &I : *BB) {
        if ((!P.Membership.count(&I) && !P.Boundaries.count(&I)) ||
            Records++ >= 256)
          continue;
        ORE.emit([&] {
          StringRef Mode = !P.FinalPartition ? "unresolved"
                           : !P.Inputs.count(&I)
                               ? (P.Retained.contains(&I) ? "producer" : "dead")
                           : P.Inputs.lookup(&I) == Transfer::Scratch
                               ? "scratch"
                           : P.Inputs.lookup(&I) == Transfer::ExistingBuffer
                               ? "existing-buffer"
                               : "recompute";
          return OptimizationRemarkAnalysis("scalar-fission", "Frontier",
                                            Candidate->getStartLoc(),
                                            Candidate->getHeader())
                 << "value " << ore::NV("Value", inputName(&I))
                 << ", membership "
                 << ore::NV("Membership", P.Membership.lookup(&I))
                 << ", boundary "
                 << ore::NV("Boundary", P.Boundaries.lookup(&I))
                 << ", final mode " << ore::NV("Transfer", Mode);
        });
      }
    LLVM_DEBUG(dbgs() << "scalar fission: " << P.Contributions.size()
                      << " contributions, producer depth " << P.ProducerDepth
                      << ", budget remaining " << P.Budget << '\n');
    if (!Valid) {
      ORE.emit([&] {
        return OptimizationRemarkMissed("scalar-fission", "Rejected",
                                        Candidate->getStartLoc(),
                                        Candidate->getHeader())
               << "scalar fission rejected: " << ore::NV("Reason", P.Reason)
               << ", producer depth "
               << ore::NV("ProducerDepth", P.ProducerDepth)
               << ", analysis budget remaining "
               << ore::NV("AnalysisBudgetRemaining", P.Budget);
      });
      continue;
    }
    // Capture the remark before emission destroys the source Loop. Emit it
    // only after successful emission, while the source header remains valid.
    OptimizationRemark Selected("scalar-fission", "Selected",
                                Candidate->getStartLoc(),
                                Candidate->getHeader());
    Selected
        << "split " << ore::NV("Path", "scalar-IR") << " loop; chunk capacity "
        << ore::NV("ChunkCapacity", P.Capacity) << ", scratch bytes "
        << ore::NV("ScratchBytes", P.ScratchBytes) << ", streams "
        << ore::NV("Streams", P.Streams.size()) << ", original read bytes "
        << ore::NV("OriginalLoadInstructionBytes", P.OriginalReadBytes)
        << ", original write bytes "
        << ore::NV("OriginalStoreInstructionBytes", P.OriginalWriteBytes)
        << ", additional read bytes "
        << ore::NV("AdditionalLoadInstructionBytesUpperBound",
                   P.AdditionalReadBytes)
        << ", duplicated original read bytes "
        << ore::NV("DuplicatedOriginalLoadInstructionBytes",
                   P.AdditionalReadBytes)
        << ", moved original read bytes "
        << ore::NV("MovedOriginalLoadInstructionBytes",
                   P.ConsumerReadBytes - P.AdditionalReadBytes)
        << ", single chunk " << ore::NV("SingleChunk", P.SingleChunk)
        << ", traffic scope "
        << ore::NV(
               "TrafficScope",
               "static access widths; conditional/nested multiplicities vary")
        << ", consumer original read bytes "
        << ore::NV("ConsumerOriginalLoadInstructionBytes", P.ConsumerReadBytes)
        << ", reused result buffers "
        << ore::NV("ReusedBuffers", count_if(P.Streams,
                                             [](const Stream &S) {
                                               return S.ExistingStore !=
                                                      nullptr;
                                             }))
        << ", scratch store bytes "
        << ore::NV("ScratchStoreBytesPerIteration", P.ScratchTraffic)
        << ", scratch load bytes "
        << ore::NV("ScratchLoadBytesPerIteration", P.ScratchTraffic)
        << ", producer depth " << ore::NV("ProducerDepth", P.ProducerDepth)
        << ", analysis budget remaining "
        << ore::NV("AnalysisBudgetRemaining", P.Budget);
    emit(P, DT, LI, SE);
    ORE.emit(Selected);
    AM.invalidate(F, PreservedAnalyses::none());
  }
  uint64_t Allocation = 0;
  for (Instruction &I : F.getEntryBlock())
    if (auto *AI = dyn_cast<AllocaInst>(&I);
        AI && AI->getMetadata("scalar.fission.source"))
      Allocation += *AI->getAllocationSize(F.getDataLayout());
  if (Allocation) {
    auto &ORE = AM.getResult<OptimizationRemarkEmitterAnalysis>(F);
    ORE.emit([&] {
      return OptimizationRemarkAnalysis("scalar-fission", "FunctionScratch", &F)
             << "function scratch IR allocation bytes "
             << ore::NV("FunctionScratchAllocaBytes", Allocation)
             << "; sum of allocas, not peak live scratch or machine frame";
    });
  }
  return PreservedAnalyses::none();
}
