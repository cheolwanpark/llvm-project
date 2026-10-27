// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_LIB_PASSES_VPLANBACKENDPROBE_H
#define LLVM_LIB_PASSES_VPLANBACKENDPROBE_H

#include "llvm/ADT/STLFunctionalExtras.h"
#include "llvm/Support/ThreadPool.h"
#include "llvm/Transforms/Vectorize/VPlanBackendFeedback.h"

namespace llvm {
/// Provider-local scheduling only. The callback and all its inputs remain alive
/// until run() joins the batch; each task owns one result slot. No IR is
/// cached.
class LLVM_ABI_FOR_TEST VPlanBackendProbePool {
  unsigned Threads;
  std::unique_ptr<DefaultThreadPool> Pool;

public:
  explicit VPlanBackendProbePool(unsigned Threads) : Threads(Threads) {
    assert(Threads);
  }
  VPlanBackendFeedback::Batch
  run(unsigned Count, function_ref<VPlanBackendProbeResult(unsigned)> Probe);
};
} // namespace llvm
#endif
