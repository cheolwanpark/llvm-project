//===- ScalarFission.h - Scalar producer/consumer loop splitting --*- C++
//-*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
#ifndef LLVM_TRANSFORMS_SCALAR_SCALARFISSION_H
#define LLVM_TRANSFORMS_SCALAR_SCALARFISSION_H

#include "llvm/IR/PassManager.h"

namespace llvm {
class Loop;
class MDNode;

/// Split closed scalar state updates from their producer. This pass does not
/// require, construct, or select vector plans. Rejected plans create no IR.
class ScalarFissionPass : public PassInfoMixin<ScalarFissionPass> {
public:
  PreservedAnalyses run(Function &F, FunctionAnalysisManager &AM);
};

bool isScalarFissionEnabled();
bool isScalarFissionEarly();
StringRef getScalarFissionStage(const Loop &L);
void preserveScalarFissionStageMetadata(MDNode *OriginalID, Loop &L);
} // namespace llvm
#endif
