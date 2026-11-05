// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVVPlanMapping.h"
#include "llvm/Analysis/LoopBackedgeAnalysis.h"
#include "llvm/CodeGen/MachineDominators.h"
#include "llvm/CodeGen/MachineFunction.h"
#include "llvm/CodeGen/MachineLoopInfo.h"
#include "llvm/IR/Function.h"
using namespace llvm;
Expected<SmallVector<TrackedLoopBody<MachineBasicBlock>>>
llvm::vplan::mapProbeBody(MachineFunction &MF, VPlanBackendObservation &O) {
  auto *T = MF.getLoopBackedgeTracking();
  auto FailMapping = [&](StringRef Reason,
                         VPlanBackendFailureGroup Group =
                             VPlanBackendFailureGroup::Tracking)
      -> Expected<SmallVector<TrackedLoopBody<MachineBasicBlock>>> {
    return vplanBackendError(Group, Reason, T ? T->Identity : "", O.Stage);
  };
  if (!T)
    return FailMapping("backedge-tracking-disabled",
                       VPlanBackendFailureGroup::Availability);
  const auto &F = MF.getFunction();
  O.MaterializedWidth = T->MaterializedWidth;
  if (T->Identity.empty() ||
      F.getFnAttribute("vplan.backend.candidate").getValueAsString() !=
          T->Identity ||
      F.getFnAttribute("vplan.backend.role").getValueAsString() != T->Role)
    return FailMapping("materialized region identity mismatch",
                       VPlanBackendFailureGroup::Integrity);
  MachineDominatorTree DT(MF);
  MachineLoopInfo LI(DT);
  SmallVector<uint64_t> Conflicts;
  SmallVector<std::pair<uint64_t, std::string>> Excluded;
  auto Bodies = mapTrackedLoops(*T, MF, DT, LI, &Conflicts,
                                T->CaptureFailures ? &Excluded : nullptr);
  for (auto &[Q, Detail] : Excluded)
    O.Exclusions.push_back({VPlanBackendFailureGroup::Tracking,
                            std::move(Detail), T->Identity, O.Stage, Q,
                            std::nullopt});
  T->Undefined.insert(Conflicts.begin(), Conflicts.end());
  if (!Bodies) {
    auto Reason = toString(Bodies.takeError());
    return FailMapping(Reason);
  }
  if (Bodies->empty())
    return FailMapping("no-usable-target-loop");
  for (unsigned I = 0; I != Bodies->size(); ++I) {
    VPlanBackendLoopObservation Loop;
    Loop.ID = I + 1;
    Loop.TrackingID = (*Bodies)[I].ID;
    Loop.IterationWidth = (*Bodies)[I].Width;
    Loop.SelectedBlockCount = (*Bodies)[I].Blocks.size();
    O.SelectedBlockCount += Loop.SelectedBlockCount;
    O.Loops.push_back(std::move(Loop));
  }
  O.IterationMapping = true;
  return Bodies;
}
