// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "llvm/Support/VPlanBackendFailure.h"
using namespace llvm;
char VPlanBackendFailureError::ID = 0;
StringRef llvm::vplanBackendFailureGroupName(VPlanBackendFailureGroup G) {
  switch (G) {
  case VPlanBackendFailureGroup::Availability:
    return "availability";
  case VPlanBackendFailureGroup::Integrity:
    return "integrity";
  case VPlanBackendFailureGroup::Tracking:
    return "tracking";
  case VPlanBackendFailureGroup::Collection:
    return "collection";
  case VPlanBackendFailureGroup::Pricing:
    return "pricing";
  case VPlanBackendFailureGroup::Execution:
    return "execution";
  }
  llvm_unreachable("invalid backend failure group");
}
VPlanBackendFailure llvm::takeVPlanBackendFailure(Error E,
                                                  VPlanBackendFailureGroup G,
                                                  StringRef Candidate,
                                                  StringRef Stage) {
  std::optional<VPlanBackendFailure> F;
  auto Rest = handleErrors(
      std::move(E), [&](const VPlanBackendFailureError &E) { F = E.Failure; });
  if (Rest) {
    auto Detail = toString(std::move(Rest));
    if (!F)
      F = VPlanBackendFailure{G,           std::move(Detail), Candidate.str(),
                              Stage.str(), std::nullopt,      std::nullopt};
    else
      F->Detail += "; " + Detail;
  }
  assert(F && "expected a failure");
  if (F->Candidate.empty())
    F->Candidate = Candidate.str();
  if (F->Stage.empty())
    F->Stage = Stage.str();
  return std::move(*F);
}
