// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_SUPPORT_VPLANBACKENDRESULT_H
#define LLVM_SUPPORT_VPLANBACKENDRESULT_H
#include "llvm/Support/Timer.h"
#include "llvm/Support/TypeSize.h"
#include <string>
#include <vector>
namespace llvm {
/// Owned, cost-independent facts. No IR or CodeGen objects cross the boundary.
struct VPlanVectorSpillAccess {
  bool IsLoad = false;
  uint64_t MinBytes = 0;
  bool Scalable = true;
  uint64_t Alignment = 1;
  unsigned AddressSpace = 0;
  bool WholeRegister = true;
  unsigned RegisterGroup = 0;
  bool FromSegment = false;
};
struct VPlanFeedbackTiming {
  std::string Phase;
  double Wall = 0, CPU = 0;
};
/// Per-query timer, inert when disabled. Intervals are consecutive; totals are
/// reported separately and must not be added to their constituent intervals.
struct VPlanFeedbackTimer {
  bool Enabled;
  TimeRecord Last;
  std::vector<VPlanFeedbackTiming> Phases;
  explicit VPlanFeedbackTimer(bool Enabled) : Enabled(Enabled) {
    if (Enabled)
      Last = TimeRecord::getCurrentTime();
  }
  void mark(StringRef Phase) {
    if (!Enabled)
      return;
    auto Now = TimeRecord::getCurrentTime(false);
    auto Delta = Now - Last;
    Phases.push_back(
        {Phase.str(), Delta.getWallTime(), Delta.getProcessTime()});
    Last = Now;
  }
};
struct VPlanBackendResult {
  std::string Candidate;
  ElementCount VF = ElementCount::getFixed(0);
  unsigned IC = 0;
  bool IsEpilogue = false;
  uint64_t IterationWidth = 0;
  bool IterationMapping = false;
  std::string Stage = "post-rvv-ra-rewrite";
  std::vector<VPlanVectorSpillAccess> Spills;
  std::vector<VPlanFeedbackTiming> Timings;
};
} // namespace llvm
#endif
