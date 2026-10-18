//===- RISCVVPlanScoring.cpp - Iteration and tail normalization
//-------------===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVVPlanCost.h"
#include "llvm/Support/MathExtras.h"
using namespace llvm;
using namespace llvm::vplan;
Expected<VPlanBackendCost>
llvm::vplan::scoreCandidate(const Analytics &A, const Analytics &Scalar) {
  if (Scalar.VF != 1 || Scalar.ScalableVF || Scalar.RunID != A.RunID ||
      Scalar.Function != A.Function || Scalar.CPU != A.CPU ||
      Scalar.VLen != A.VLen || Scalar.MaxTripCount != A.MaxTripCount ||
      StringRef(Scalar.Candidate).rsplit(':').first.rsplit(':').first !=
          StringRef(A.Candidate).rsplit(':').first.rsplit(':').first)
    return createStringError(inconvertibleErrorCode(),
                             "scalar analytics context mismatch");
  auto Body = computeBodyCost(A);
  if (!Body)
    return Body.takeError();
  auto Reference = computeBodyCost(Scalar);
  if (!Reference)
    return Reference.takeError();
  VPlanBackendCost C;
  C.Body = Body->Total;
  C.ScalarBody = Reference->Total;
  C.Width = A.Width;
  C.ScalarWidth = Scalar.Width;
  C.Breakdown = costBreakdown(*Body);
  if (!A.MaxTripCount) {
    C.Score = C.Body;
    C.Divisor = A.Width;
    C.Kind = "cost-per-lane";
  } else {
    C.Kind = "whole-loop";
    if (A.ScalarTail || (!A.ScalableVF && A.VF == 1)) {
      // Keep the scalar probe's unrolled width as an exact denominator:
      // dividing its body first would lose sub-quarter scalar-tail costs.
      C.Score = C.Body * (A.MaxTripCount / A.Width) * Scalar.Width +
                C.ScalarBody * (A.MaxTripCount % A.Width);
      C.Divisor = Scalar.Width;
    } else
      C.Score = C.Body * divideCeil(A.MaxTripCount, A.Width);
  }
  return C;
}
