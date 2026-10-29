// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#ifndef LLVM_SUPPORT_SCOPEDPASSCANCELLATION_H
#define LLVM_SUPPORT_SCOPEDPASSCANCELLATION_H

#include "llvm/Support/Compiler.h"
#include <atomic>

namespace llvm {
/// Cancellation of a disposable pipeline only: never resume the abandoned IR.
/// The requester owns this object until the worker has returned.
struct PassCancellation {
  std::atomic<bool> Requested{false};
  // Worker-owned; read only after completion publication.
  bool Observed = false;
};

class ScopedPassCancellation {
  LLVM_ABI static thread_local PassCancellation *Current;
  PassCancellation *Previous;

public:
  explicit ScopedPassCancellation(PassCancellation *C) : Previous(Current) {
    Current = C;
  }
  ScopedPassCancellation(const ScopedPassCancellation &) = delete;
  ScopedPassCancellation &operator=(const ScopedPassCancellation &) = delete;
  ~ScopedPassCancellation() { Current = Previous; }
  static bool check() {
    if (!Current || !Current->Requested.load(std::memory_order_relaxed))
      return false;
    Current->Observed = true;
    return true;
  }
};
} // namespace llvm
#endif
