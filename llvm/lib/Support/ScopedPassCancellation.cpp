// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "llvm/Support/ScopedPassCancellation.h"

// One scope per thread across LLVM component/shared-library boundaries.
thread_local llvm::PassCancellation *llvm::ScopedPassCancellation::Current =
    nullptr;
