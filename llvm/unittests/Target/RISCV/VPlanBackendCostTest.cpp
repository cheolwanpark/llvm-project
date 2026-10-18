//===- VPlanBackendCostTest.cpp - Typed analytics and cost tests
//-----------===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVVPlanCost.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/StringSwitch.h"
#include "gtest/gtest.h"
#include <array>
using namespace llvm;
using namespace llvm::vplan;
namespace {
#include "VPlanCostReference.inc"
Analytics analytics() {
  Analytics A;
  A.CPU = "xiangshan-kunminghu";
  A.VLen = 128;
  A.Function = "f";
  A.RunID = "test";
  A.Candidate = "f:0:0:f1";
  A.Blocks.push_back({0, "body", {0}});
  return A;
}
InstructionInfo instruction(StringRef K, unsigned G = 8, unsigned SEW = 32) {
  InstructionInfo I;
  I.Category = K.str();
  I.Group8 = G;
  I.SEW = SEW;
  I.Load = K == "unit" || K == "strided" || K == "indexed";
  return I;
}
void append(Analytics &A, InstructionInfo I) {
  I.ID = A.Instructions.size();
  A.Instructions.push_back(std::move(I));
}
TEST(VPlanBackendCost, FrozenVectorFormula) {
  for (unsigned VL : {128u, 256u, 512u})
    for (unsigned G : {1u, 2u, 4u, 8u, 16u, 32u, 64u})
      for (StringRef K : {"unit", "strided", "indexed", "integer", "fp",
                          "fused", "copy", "slide", "mask_logical", "fp_div"})
        for (bool Mask : {false, true}) {
          auto A = analytics();
          A.VLen = VL;
          auto I = instruction(K, G);
          I.Masked = Mask;
          I.Predicate = 1;
          append(A, I);
          append(A, I);
          append(A, instruction("scalar", 0, 0));
          json::Object R{{"version", 1}, {"supported", true}, {"unit8", 0},
                         {"spill8", 0},  {"strided8", 0},     {"indexed8", 0},
                         {"masked8", 0}, {"integer8", 0},     {"fp8", 0},
                         {"fused8", 0},  {"scalar8", 8},      {"config8", 0}};
          int64_t W = uint64_t(G) * VL /
                      (K == "strided" || K == "indexed" ? 32
                       : K == "mask_logical"            ? 1024
                                                        : 128);
          if (K != "copy")
            W = std::max<int64_t>(8, W);
          std::string Key = (K == "mask_logical" ? "integer" : K).str() + "8";
          if (R.get(Key))
            R[Key] = W * 2;
          if (I.Load && Mask)
            R["masked8"] = W * 2;
          json::Array Ops;
          for (unsigned N = 0; N < 2; ++N) {
            json::Object Op{{"kind", K}, {"work8", W},     {"group8", G},
                            {"sew", 32}, {"masked", Mask}, {"predicate_id", 1}};
            if (I.Load)
              Op["direction"] = "load";
            if (K == "fp_div")
              Op["form"] = "vv";
            Ops.push_back(std::move(Op));
          }
          R["operations"] = std::move(Ops);
          auto C = computeBodyCost(A);
          ASSERT_TRUE(bool(C)) << toString(C.takeError());
          EXPECT_EQ(C->Total, referenceCost(json::Object{
                                  {"resource_demand", std::move(R)}}))
              << K.str() << " VL=" << VL << " G=" << G << " masked=" << Mask;
        }
}
TEST(VPlanBackendCost, ScalarSpillsConfigurationAndScoring) {
  auto S = analytics();
  append(S, instruction("scalar", 0, 0));
  auto A = S;
  A.Candidate = "f:0:1:s4";
  A.VF = 4;
  A.ScalableVF = true;
  A.Width = 8;
  auto Spill = instruction("spill", 0, 0);
  Spill.Bytes = 8;
  append(A, Spill);
  auto Config = instruction("config", 0, 0);
  append(A, Config);
  auto C = scoreCandidate(A, S);
  ASSERT_TRUE(bool(C));
  EXPECT_EQ(C->Body, InstructionCost(2));
  EXPECT_EQ(C->Divisor, 8u);
  S.MaxTripCount = A.MaxTripCount = 10;
  A.ScalarTail = true;
  C = scoreCandidate(A, S);
  ASSERT_TRUE(bool(C));
  EXPECT_EQ(C->Score, 3);
  EXPECT_EQ(C->Divisor, 1u);
  A.ScalarTail = false;
  C = scoreCandidate(A, S);
  ASSERT_TRUE(bool(C));
  EXPECT_EQ(C->Score, 4);
}
TEST(VPlanBackendCost, UnrolledScalarTailRetainsFraction) {
  auto S = analytics();
  S.Width = 8;
  S.MaxTripCount = 10;
  for (unsigned I = 0; I < 3; ++I)
    append(S, instruction("scalar", 0, 0));
  auto A = analytics();
  A.VF = 4;
  A.Width = 4;
  A.MaxTripCount = 10;
  A.ScalarTail = true;
  A.Candidate = "f:0:1:f4";
  append(A, instruction("integer"));
  auto C = scoreCandidate(A, S);
  ASSERT_TRUE(bool(C));
  // 2 vector iterations * 1 + 2 scalar iterations * (1.5 / 8) = 2.375.
  EXPECT_EQ(costQuarters(C->Score), 76);
  EXPECT_EQ(C->Divisor, 8u);
}
TEST(VPlanBackendCost, ExactTransportAndOverflowSafeOrdering) {
  VPlanBackendCost A, B;
  A.Body = InstructionCost(3) / 4;
  A.Score = InstructionCost::getMax();
  A.Divisor = UINT32_MAX;
  B = A;
  B.Divisor -= 1;
  EXPECT_TRUE(backendCostLess(A, B));
  auto Copy = parseBackendCost(serializeBackendCost(A));
  EXPECT_EQ(Copy.Body, A.Body);
  EXPECT_EQ(Copy.Score, A.Score);
}
Operand vectorOperand(bool Def, int64_t Unit, bool Tied = false) {
  Operand O;
  O.Vector = true;
  O.Def = Def;
  O.Use = !Def;
  O.Units = {Unit};
  O.Group8 = 8;
  O.Tied = Tied;
  return O;
}
TEST(VPlanBackendCost, RecurrenceAndLoadUseUseOnlyProvenEdges) {
  auto A = analytics();
  A.DependencyCoverage = "single-block-distance-0-1";
  auto I = instruction("fused");
  I.Base = "VFMACC_VV";
  I.Operands = {vectorOperand(true, 1), vectorOperand(false, 1, true)};
  append(A, I);
  A.Edges.push_back({0, 0, 1, 1, true});
  auto C = computeBodyCost(A);
  ASSERT_TRUE(bool(C));
  EXPECT_EQ(C->Total, 5);
  A.Edges[0].WholeValue = false;
  C = computeBodyCost(A);
  ASSERT_TRUE(bool(C));
  EXPECT_EQ(C->Total, 2);
  A = analytics();
  A.DependencyCoverage = "single-block-distance-0-1";
  I = instruction("unit");
  I.Base = "VLE32_V";
  I.Operands = {vectorOperand(true, 1)};
  append(A, I);
  I = instruction("fp");
  I.Base = "VFADD_VV";
  I.Operands = {vectorOperand(true, 2), vectorOperand(false, 1)};
  append(A, I);
  A.Edges.push_back({0, 1, 1, 0, true});
  C = computeBodyCost(A);
  ASSERT_TRUE(bool(C));
  EXPECT_EQ(C->Total, 7);
  A.Instructions[1].Operands[1].Tied = true;
  C = computeBodyCost(A);
  ASSERT_TRUE(bool(C));
  EXPECT_EQ(C->Total, 2);
}
TEST(VPlanBackendCost, RejectsMalformedFeedbackAndMixedScoreKinds) {
  VPlanBackendCost C;
  auto O = serializeBackendCost(C);
  O["divisor"] = 0;
  EXPECT_DEATH((void)parseBackendCost(O), "denominator/kind");
  O = serializeBackendCost(C);
  O["score_quarters"] = -1;
  EXPECT_DEATH((void)parseBackendCost(O), "numerator");
  VPlanBackendCost D;
  D.Kind = "whole-loop";
  EXPECT_DEATH((void)backendCostLess(C, D), "score kinds");
}
TEST(VPlanBackendCost, AnalyticsRoundTripAndUnsupported) {
  auto A = analytics();
  append(A, instruction("scalar", 0, 0));
  json::Path::Root Root;
  Analytics B;
  EXPECT_TRUE(fromJSON(toJSON(A), B, Root));
  EXPECT_EQ(B.Instructions[0].Category, "scalar");
  B.Instructions[0].Category = "unknown";
  auto C = computeBodyCost(B);
  EXPECT_FALSE(bool(C));
  consumeError(C.takeError());
  B = A;
  B.Edges.push_back({100, 0, 0, 0, true});
  C = computeBodyCost(B);
  EXPECT_FALSE(bool(C));
  consumeError(C.takeError());
}
} // namespace
