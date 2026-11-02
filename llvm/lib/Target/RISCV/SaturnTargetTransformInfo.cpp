// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "SaturnTargetTransformInfo.h"
using namespace llvm;
SaturnTTIImpl::SaturnTTIImpl(const RISCVTargetMachine *TM, const Function &F)
    : RISCVTTIImpl(TM, F) {}
