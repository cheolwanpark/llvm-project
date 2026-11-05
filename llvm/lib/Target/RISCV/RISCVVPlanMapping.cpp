// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVVPlanMapping.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/RelatedBlockAnalysis.h"
#include "llvm/CodeGen/MachineFunction.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Function.h"
#include "llvm/Pass.h"
#include "llvm/PassInfo.h"
#include "llvm/PassRegistry.h"
#include "llvm/Support/Debug.h"
#define DEBUG_TYPE "vplan-related-blocks"
using namespace llvm;
Expected<SmallVector<const MachineBasicBlock *>>
llvm::vplan::mapProbeBody(MachineFunction &MF, VPlanBackendObservation &O) {
  auto *T = MF.getRelatedBlockTracking();
  auto FailMapping = [&](StringRef Reason)
      -> Expected<SmallVector<const MachineBasicBlock *>> {
    O.MappingFailure = Reason.str();
    return createStringError(Reason);
  };
  if (!T)
    return FailMapping("related-block tracking disabled");
  const auto &R = T->Region;
  const auto &F = MF.getFunction();
  if (R.Identity.empty() || R.Origins.empty() ||
      F.getFnAttribute("vplan.backend.candidate").getValueAsString() !=
          R.Identity ||
      F.getFnAttribute("vplan.backend.role").getValueAsString() != R.Role)
    return FailMapping("materialized region identity mismatch");
  const auto &N = R.Normalization;
  O.MaterializedWidth = N.MaterializedWidth;
  O.IterationWidth = N.IterationWidth;
  O.TripCount = N.TripCount;
  O.TripCountKind = N.TripCountKind;
  O.NormalizationBasis = N.Basis;
  O.NormalizationFailure = N.Failure;
  O.NormalizationSucceeded =
      N.Failure.empty() && N.IterationWidth && N.IterationWidth <= UINT32_MAX;
  if (!O.NormalizationSucceeded && O.NormalizationFailure.empty())
    O.NormalizationFailure = "invalid iteration width";
  SmallVector<const MachineBasicBlock *> Blocks;
  for (const auto &BB : MF) {
    auto V = BB.getRelatedBlock();
    if (V.State != RelatedBlockState::Known &&
        any_of(BB,
               [](const MachineInstr &I) { return !I.isMetaInstruction(); })) {
      ++O.UnresolvedBlockCount;
      LLVM_DEBUG(dbgs() << "Unresolved machine ancestry at " << O.Stage << "\n";
                 BB.print(dbgs());
                 if (const auto *IR = BB.getBasicBlock()) dbgs()
                 << "IR ancestry state: "
                 << unsigned(IR->getRelatedBlock().State) << "\n");
    }
    if (!R.intersects(V))
      continue;
    Blocks.push_back(&BB);
    if (any_of(V.Origins,
               [&](auto ID) { return !is_contained(R.Origins, ID); }))
      ++O.MixedOriginBlockCount;
  }
  O.SelectedBlockCount = Blocks.size();
  if (O.UnresolvedBlockCount)
    return FailMapping("unresolved executable block ancestry");
  if (Blocks.empty())
    return FailMapping("materialized body absent without removal certificate");
  O.MappingSucceeded = true;
  if (!O.NormalizationSucceeded)
    return createStringError(O.NormalizationFailure);
  O.IterationMapping = true;
  return Blocks;
}

namespace {
class MappingVerifier : public FunctionPass {
public:
  static char ID;
  MappingVerifier() : FunctionPass(ID) {
    static const PassInfo PI("VPlan IR normalization validation",
                             "vplan-ir-normalization", &ID, nullptr, false,
                             false);
    static const bool Registered = [] {
      PassRegistry::getPassRegistry()->registerPass(PI);
      return true;
    }();
    (void)Registered;
  }
  void getAnalysisUsage(AnalysisUsage &AU) const override {
    AU.setPreservesAll();
  }
  bool runOnFunction(Function &F) override {
    if (RelatedBlockTracking::get(&F)) {
      DominatorTree DT(F);
      LoopInfo LI(DT);
      validateRelatedBlockNormalization(F, LI);
      LLVM_DEBUG(for (const auto &BB : F) if (BB.getRelatedBlock().State !=
                                              RelatedBlockState::Known) dbgs()
                     << "Unresolved IR before ISel: " << BB;);
    }
    return false;
  }
};
char MappingVerifier::ID = 0;
} // namespace
FunctionPass *llvm::createRISCVVPlanMappingVerifier() {
  return new MappingVerifier;
}
