// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/PseudoProbe.h"
#include "llvm/Transforms/Vectorize/VPlanBackendFeedback.h"
using namespace llvm;

VPlanBackendMarkerDecision
VPlanBackendMarkerPolicy::assess(const VPlanBackendMarkerContext &C) const {
  if (!vplanBackendRegionProbesEnabled())
    return {false, "disabled"};
  const Function *F = C.Entry.getParent();
  if (!F || C.Exit.getParent() != F || C.Candidate.empty() ||
      F->getFnAttribute("vplan.backend.candidate").getValueAsString() !=
          C.Candidate)
    return {false, "invalid-identity"};
  if (C.Entry.getFirstInsertionPt() == C.Entry.end() ||
      !C.Exit.getTerminator() || C.Entry.isEHPad() || C.Exit.isEHPad())
    return {false, "illegal-position"};
  for (const auto &BB : *F)
    for (const auto &I : BB)
      if (isa<PseudoProbeInst>(I) ||
          (isa<CallInst>(I) && cast<CallInst>(I).isMustTailCall()))
        return {false, "instrumentation-conflict"};
  return {true, "enabled"};
}

// One pair denotes one materialized VF * IC iteration (one for a scalar probe).
// This uses the same
// nominal width as loop observations, including masked/EVL iterations; it does
// not claim that every lane is active. The caller establishes the body
// identity.
void llvm::markVPlanBackendRegion(BasicBlock &Entry, BasicBlock &Exit,
                                  StringRef ID) {
  Function &F = *Entry.getParent();
  uint64_t Width = 0;
  if (!VPlanBackendMarkerPolicy().assess({Entry, Exit, ID}).Insert)
    return;
  // Identity is always inserted. Unknown geometry makes marker recovery
  // ineligible, without suppressing markers or the ordinary loop proof.
  if ((F.getFnAttribute("vplan.backend.scalable").getValueAsString() != "0" &&
       !F.getVScaleValue()) ||
      (F.hasFnAttribute("vplan.backend.materialized-width")
           ? F.getFnAttribute("vplan.backend.materialized-width")
           : F.getFnAttribute("vplan.backend.width"))
          .getValueAsString()
          .getAsInteger(10, Width) ||
      !Width || Width > UINT32_MAX)
    Width = 0;
  uint64_t GUID = GlobalValue::getGUIDAssumingExternalLinkage(ID);
  F.addFnAttr("vplan.backend.region-guid", std::to_string(GUID));
  F.addFnAttr("vplan.backend.region-width", std::to_string(Width));
  auto *Probe =
      Intrinsic::getOrInsertDeclaration(F.getParent(), Intrinsic::pseudoprobe);
  auto Insert = [&](BasicBlock &BB, BasicBlock::iterator IP, uint64_t Index) {
    IRBuilder<> B(&BB, IP);
    B.CreateCall(Probe, {B.getInt64(GUID), B.getInt64(Index), B.getInt32(0),
                         B.getInt64(PseudoProbeFullDistributionFactor)});
  };
  Insert(Entry, Entry.getFirstInsertionPt(), 1);
  Insert(Exit, Exit.getTerminator()->getIterator(), 2);
}
