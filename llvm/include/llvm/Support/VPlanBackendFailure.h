// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_SUPPORT_VPLANBACKENDFAILURE_H
#define LLVM_SUPPORT_VPLANBACKENDFAILURE_H
#include "llvm/Support/Error.h"
#include <optional>
#include <string>
#include <tuple>
namespace llvm {
enum class VPlanBackendFailureGroup {
  Availability,
  Integrity,
  Tracking,
  Collection,
  Pricing,
  Execution
};
/// Owned evidence; absent identities stay absent across worker boundaries.
struct VPlanBackendFailure {
  VPlanBackendFailureGroup Group;
  std::string Detail, Candidate, Stage;
  std::optional<uint64_t> TrackingID, ObservationID;
  auto key() const {
    return std::tie(Group, Candidate, Stage, TrackingID, ObservationID, Detail);
  }
  bool operator<(const VPlanBackendFailure &B) const { return key() < B.key(); }
  bool operator==(const VPlanBackendFailure &B) const {
    return key() == B.key();
  }
};
LLVM_ABI StringRef vplanBackendFailureGroupName(VPlanBackendFailureGroup Group);
class LLVM_ABI VPlanBackendFailureError
    : public ErrorInfo<VPlanBackendFailureError> {
public:
  static char ID;
  VPlanBackendFailure Failure;
  explicit VPlanBackendFailureError(VPlanBackendFailure F)
      : Failure(std::move(F)) {}
  void log(raw_ostream &OS) const override { OS << Failure.Detail; }
  std::error_code convertToErrorCode() const override {
    return inconvertibleErrorCode();
  }
};
inline Error vplanBackendError(VPlanBackendFailure F) {
  return make_error<VPlanBackendFailureError>(std::move(F));
}
inline Error vplanBackendError(VPlanBackendFailureGroup Group, StringRef Detail,
                               StringRef Candidate, StringRef Stage) {
  return vplanBackendError({Group, Detail.str(), Candidate.str(), Stage.str(),
                            std::nullopt, std::nullopt});
}
/// Classify external errors at their owning boundary, preserve typed evidence.
LLVM_ABI VPlanBackendFailure
takeVPlanBackendFailure(Error E, VPlanBackendFailureGroup Group,
                        StringRef Candidate, StringRef Stage);
} // namespace llvm
#endif
