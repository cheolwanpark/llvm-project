// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "llvm/Analysis/VPlanCostProfile.h"
using namespace llvm;
static thread_local bool Active = false;
VPlanCostProfileScope::VPlanCostProfileScope(bool Enabled) : Previous(Active) {
  Active = Enabled;
}
VPlanCostProfileScope::~VPlanCostProfileScope() { Active = Previous; }
bool VPlanCostProfileScope::active() { return Active; }
