//===- llvm/unittests/Transforms/Vectorize/VPlanTest.cpp - VPlan tests ----===//
//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "../lib/Transforms/Vectorize/VPlan.h"
#include "../lib/Transforms/Vectorize/LoopVectorizationPlanner.h"
#include "../lib/Transforms/Vectorize/VPlanCFG.h"
#include "../lib/Transforms/Vectorize/VPlanHelpers.h"
#include "../lib/Transforms/Vectorize/VPlanRACostModel.h"
#include "../lib/Transforms/Vectorize/VPlanUtils.h"
#include "VPlanTestBase.h"
#include "llvm/ADT/DepthFirstIterator.h"
#include "llvm/ADT/PostOrderIterator.h"
#include "llvm/Analysis/VectorUtils.h"
#include "llvm/IR/Instruction.h"
#include "llvm/IR/Instructions.h"
#include "gtest/gtest.h"
#include <algorithm>
#include <initializer_list>
#include <limits>
#include <string>
#include <utility>

namespace llvm {

namespace {

#define CHECK_ITERATOR(Range1, ...)                                            \
  do {                                                                         \
    std::vector<VPInstruction *> Tmp = {__VA_ARGS__};                          \
    EXPECT_EQ((size_t)std::distance(Range1.begin(), Range1.end()),             \
              Tmp.size());                                                     \
    for (auto Pair : zip(Range1, make_range(Tmp.begin(), Tmp.end())))          \
      EXPECT_EQ(&std::get<0>(Pair), std::get<1>(Pair));                        \
  } while (0)

using VPInstructionTest = VPlanTestBase;
using VPlanSCEVTest = VPlanTestIRBase;

class VPlanRAResourceCost : public VPlanTestBase {
protected:
  VPlanRAResourceCost() {
    BasicBlock *Entry = BasicBlock::Create(C, "entry", F, ScalarHeader);
    UncondBrInst::Create(ScalarHeader, Entry);
  }

  static json::Object features() {
    return json::Object{
        {"resource_demand",
         json::Object{{"version", 1}, {"supported", true},
                      {"unit8", 0}, {"spill8", 0}, {"strided8", 0},
                      {"indexed8", 0}, {"masked8", 0}, {"integer8", 0},
                      {"fp8", 0}, {"fused8", 0}, {"scalar8", 0},
                      {"config8", 0}}}};
  }

  static json::Object &resources(json::Object &Features) {
    return *Features.getObject("resource_demand");
  }

  static json::Object operation(StringRef Kind, bool Masked, int64_t Group,
                                int64_t Work, int64_t SEW = 32) {
    return json::Object{{"kind", Kind}, {"masked", Masked}, {"group8", Group},
                        {"work8", Work}, {"sew", SEW}};
  }

  static json::Object recurrence(int64_t FP, int64_t Fused, int64_t Extra) {
    return json::Object{{"fp_steps", FP}, {"fused_steps", Fused},
                        {"extra_chunks", Extra}};
  }

  static json::Object loadUse(StringRef Kind, int64_t Chunks,
                              std::initializer_list<int64_t> Preds = {}) {
    json::Array Predecessors;
    for (int64_t Pred : Preds)
      Predecessors.push_back(Pred);
    return json::Object{{"kind", Kind}, {"chunks", Chunks},
                        {"predecessors", std::move(Predecessors)}};
  }

  static json::Object memoryOperation(StringRef Kind, StringRef Direction,
                                      bool Masked, int64_t Group, int64_t Work,
                                      int64_t Predicate = 0, int64_t SEW = 32) {
    auto Op = operation(Kind, Masked, Group, Work, SEW);
    Op["direction"] = Direction;
    if (Masked)
      Op["predicate_id"] = Predicate;
    return Op;
  }

  static json::Object division(StringRef Form, bool Masked, int64_t Group,
                               int64_t Work, int64_t SEW) {
    auto Op = operation("fp_div", Masked, Group, Work, SEW);
    Op["form"] = Form;
    return Op;
  }

  static InstructionCost cost(VPlan &Plan, const json::Object &Features,
                              ElementCount VF = ElementCount::getScalable(4),
                              InstructionCost Original = 100) {
    return costWithRAFeatures(Plan, VF, Original, Features);
  }

  static json::Object predicateOperation(StringRef Kind, int64_t Group,
                                         int64_t Work, int64_t Predicate,
                                         int64_t SEW = 32) {
    auto Op = operation(Kind, true, Group, Work, SEW);
    Op["predicate_id"] = Predicate;
    return Op;
  }
};

TEST_F(VPlanRAResourceCost, LoadUseFirstChunkLatencyAndStreaming) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  for (int64_t Chunks : {1, 2, 4, 8}) {
    // One chunk also represents every fractional group after the issue floor.
    R["load_use_nodes"] = json::Array{loadUse("load", Chunks),
                                     loadUse("fp", Chunks, {0}),
                                     loadUse("fused", Chunks, {1})};
    // 4+3+5 first-chunk latency; one trailing stream, not three.
    EXPECT_EQ(cost(Plan, Features), 12 + Chunks - 1);
    EXPECT_EQ(cost(Plan, Features, ElementCount::getScalable(16)),
              12 + Chunks - 1);
  }
  R["load_use_nodes"] = json::Array{loadUse("load", 1),
                                   loadUse("integer", 1, {0}),
                                   loadUse("multiply", 1, {1})};
  EXPECT_EQ(cost(Plan, Features), 8);
}

TEST_F(VPlanRAResourceCost, LoadUseIndependentLoadsFanoutAndJoins) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["load_use_nodes"] = json::Array{loadUse("load", 8), loadUse("load", 8)};
  EXPECT_EQ(cost(Plan, Features), 0); // No arithmetic endpoint.
  R["load_use_nodes"] = json::Array{
      loadUse("load", 2), loadUse("load", 2),
      loadUse("fp", 2, {0}), loadUse("fp", 2, {0}),
      loadUse("fused", 2, {1}), loadUse("fp", 2, {2, 3, 4})};
  EXPECT_EQ(cost(Plan, Features), 13); // max(4+3+3, 4+5+3) + 1.
  // Different chunk counts also keep first/last bounds separate at joins.
  R["load_use_nodes"] = json::Array{
      loadUse("load", 8), loadUse("load", 1),
      loadUse("fused", 1, {1}), loadUse("fp", 1, {0, 2})};
  EXPECT_EQ(cost(Plan, Features), 14); // max(4+7+3, 4+5+3).
}

TEST_F(VPlanRAResourceCost, LoadUsePreservesResourcesRecurrencesAndAdditions) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["load_use_nodes"] = json::Array{loadUse("load", 1),
                                   loadUse("fp", 1, {0})}; // Bound=7.
  R["spill8"] = 8;
  R["config8"] = 16;
  R["config_unused8"] = 8;
  R["config_additive8"] = 8;
  EXPECT_EQ(cost(Plan, Features), InstructionCost(17) / 2);
  R["recurrences"] = json::Array{recurrence(3, 0, 0)};
  EXPECT_EQ(cost(Plan, Features), InstructionCost(21) / 2);
  R["fp8"] = 80; // Arithmetic=20 competes with both paths.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(43) / 2);
  R["fp8"] = 0;
  R["scalar8"] = 160; // Scalar=10 + unused configuration=1.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(25) / 2);
  R["scalar8"] = 0;
  R["unit8"] = 240; // Legacy memory=15.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(33) / 2);
  R["unit8"] = 0;
  R["recurrences"] = json::Array{};
  R["operations"] = json::Array{operation("copy", false, 64, 128)};
  EXPECT_EQ(cost(Plan, Features), InstructionCost(19) / 2); // Movement=8.
  R["operations"] = json::Array{division("vv", false, 8, 8, 32)};
  EXPECT_EQ(cost(Plan, Features), InstructionCost(53) / 2); // Divider=25.
}

TEST_F(VPlanRAResourceCost, LoadUseAbsentMalformedAndScalar) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["integer8"] = 16;
  EXPECT_EQ(cost(Plan, Features), 2);
  R["load_use_nodes"] = json::Array{};
  EXPECT_EQ(cost(Plan, Features), 2);
  for (json::Value Bad : {
           json::Value(7), json::Value(json::Array{7}),
           json::Value(json::Array{loadUse("unknown", 1)}),
           json::Value(json::Array{loadUse("load", 0)}),
           json::Value(json::Array{loadUse("load", -1)}),
           json::Value(json::Array{loadUse("fp", 1)}),
           json::Value(json::Array{loadUse("load", 1, {0})}),
           json::Value(json::Array{loadUse("load", 1),
                                   loadUse("fp", 1, {-1})}),
           json::Value(json::Array{loadUse("load", 1),
                                   loadUse("fp", 1, {1})}),
           json::Value(json::Array{loadUse("load", 1),
                                   loadUse("fp", 1, {2})})}) {
    R["load_use_nodes"] = std::move(Bad);
    EXPECT_EQ(cost(Plan, Features), 100);
  }
  for (StringRef Key : {"kind", "chunks", "predecessors"}) {
    auto Node = loadUse("load", 1);
    Node.erase(Key);
    R["load_use_nodes"] = json::Array{std::move(Node)};
    EXPECT_EQ(cost(Plan, Features), 100);
  }
  for (json::Value Pred :
       {json::Value("0"), json::Value(true), json::Value(nullptr)}) {
    auto Node = loadUse("fp", 1);
    Node["predecessors"] = json::Array{std::move(Pred)};
    R["load_use_nodes"] = json::Array{loadUse("load", 1), std::move(Node)};
    EXPECT_EQ(cost(Plan, Features), 100);
  }
  R["load_use_nodes"] = json::Array{loadUse("load", 1),
                                   loadUse("fp", 1, {0})};
  EXPECT_EQ(cost(Plan, Features, ElementCount::getFixed(1)), 100);
  R["supported"] = false;
  EXPECT_EQ(cost(Plan, Features), 100);
}

TEST_F(VPlanRAResourceCost, LoadUseSaturationDerivedFromRawQuarterUnits) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  constexpr int64_t Max = std::numeric_limits<int64_t>::max();
  R["load_use_nodes"] = json::Array{loadUse("load", Max),
                                   loadUse("fp", Max, {0})};
  // The internal signed quarter-unit accumulator saturates at Max. The
  // final /16 leaves floor(Max/16) raw quarters: Max/64 whole units + 3/4.
  // Derive this from the integer representation, without getMax() or using
  // the model's multiplication as an expectation oracle.
  InstructionCost Expected = InstructionCost(Max / 64) + InstructionCost(3) / 4;
  InstructionCost Actual = cost(Plan, Features);
  EXPECT_TRUE(Actual.isValid());
  EXPECT_GE(Actual, 0);
  EXPECT_EQ(Actual, Expected);
  // Multiplication forms raw quarters * 64 before rescaling by four.
  // ExtraChunks <= Max/256 fits this intermediate product; the following
  // extra chunk saturates. Below the threshold, latency is exactly C+6.
  constexpr int64_t Threshold = Max / 256;
  for (int64_t Chunks : {Threshold, Threshold + 1}) {
    R["load_use_nodes"] = json::Array{loadUse("load", Chunks),
                                     loadUse("fp", Chunks, {0})};
    EXPECT_EQ(cost(Plan, Features), Chunks + 6);
  }
  R["load_use_nodes"] = json::Array{loadUse("load", Threshold + 2),
                                   loadUse("fp", Threshold + 2, {0})};
  EXPECT_EQ(cost(Plan, Features), Expected);
  R["spill8"] = Max;
  R["config8"] = Max;
  EXPECT_EQ(cost(Plan, Features), Expected);
}

TEST_F(VPlanRAResourceCost, SeparateMemoryLoadStoreAndSharedLimits) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  // Each direction serves two chunks/unit. Shared service permits at most
  // 1/8 overlap; singleton direction demand retains its entire old cost.
  R["unit8"] = 64;
  for (StringRef Direction : {"load", "store"}) {
    R["operations"] = json::Array{
        memoryOperation("unit", Direction, false, 64, 64)};
    EXPECT_EQ(cost(Plan, Features), 4);
  }
  R["unit8"] = 128;
  R["operations"] = json::Array{
      memoryOperation("unit", "load", false, 64, 64),
      memoryOperation("unit", "store", false, 64, 64)};
  EXPECT_EQ(cost(Plan, Features), 7); // max(4, 4, 7).
  // Unequal directions: shared constraint still dominates at 3:1.
  R["unit8"] = 64;
  R["operations"] = json::Array{
      memoryOperation("unit", "load", false, 32, 48),
      memoryOperation("unit", "store", false, 16, 16)};
  EXPECT_EQ(cost(Plan, Features), InstructionCost(7) / 2);
  // A nearly single-direction workload reaches its independent limit.
  R["operations"] = json::Array{
      memoryOperation("unit", "load", false, 64, 60),
      memoryOperation("unit", "store", false, 1, 4)};
  EXPECT_EQ(cost(Plan, Features), InstructionCost(15) / 4);
}

TEST_F(VPlanRAResourceCost, SeparateMemoryGroupingAndFractionalAccumulation) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  const int64_t Groups[] = {1, 2, 4, 8, 16, 32, 64};
  const int64_t Work[] = {8, 8, 8, 8, 16, 32, 64};
  const InstructionCost Expected[] = {InstructionCost(3) / 4,
      InstructionCost(3) / 4, InstructionCost(3) / 4,
      InstructionCost(3) / 4, InstructionCost(7) / 4,
      InstructionCost(7) / 2, 7};
  for (unsigned I = 0; I != 7; ++I) {
    R["unit8"] = Work[I] * 2;
    R["operations"] = json::Array{
        memoryOperation("unit", "load", false, Groups[I], Work[I]),
        memoryOperation("unit", "store", false, Groups[I], Work[I])};
    EXPECT_EQ(cost(Plan, Features), Expected[I]);
  }
  // Two 7/16-unit service demands must accumulate before truncation.
  R["unit8"] = 16;
  R["operations"] = json::Array{
      memoryOperation("unit", "load", false, 1, 8),
      memoryOperation("unit", "store", false, 1, 8)};
  EXPECT_EQ(cost(Plan, Features), InstructionCost(3) / 4);
  // Upward shared rounding avoids loss on small integer observations.
  R["unit8"] = 9;
  R["operations"] = json::Array{
      memoryOperation("unit", "load", false, 1, 5),
      memoryOperation("unit", "store", false, 1, 4)};
  EXPECT_EQ(cost(Plan, Features), InstructionCost(1) / 2);
}

TEST_F(VPlanRAResourceCost, SeparateMemoryMaskedStridedAndPredicateSharing) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 32;
  R["strided8"] = 128;
  R["indexed8"] = 128;
  R["masked8"] = 288;
  R["operations"] = json::Array{
      memoryOperation("unit", "load", true, 16, 16, 1),
      memoryOperation("unit", "store", true, 16, 16, 1),
      memoryOperation("strided", "store", true, 32, 128, 1),
      memoryOperation("indexed", "load", true, 32, 128, 1)};
  // Old ordinary demand 52 becomes 45.5. Unchanged strided service=6;
  // predicate service=.75*(.125+.125+3+3)+.25*3=5.4375.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(227) / 4);
  auto &Ops = *R["operations"].getAsArray();
  for (unsigned I = 0; I != Ops.size(); ++I)
    (*Ops[I].getAsObject())["predicate_id"] = I + 1;
  EXPECT_EQ(cost(Plan, Features), InstructionCost(231) / 4);
  // Unmasked strided service is unaffected by direction overlap too.
  R["unit8"] = 0;
  R["indexed8"] = 0;
  R["strided8"] = 256;
  R["masked8"] = 0;
  R["operations"] = json::Array{
      memoryOperation("strided", "load", false, 32, 128),
      memoryOperation("strided", "store", false, 32, 128)};
  EXPECT_EQ(cost(Plan, Features), 40); // 28 shared + 12 strided service.
}

TEST_F(VPlanRAResourceCost, SeparateMemoryKeepsSpillsAndOtherResources) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 128;
  R["spill8"] = 32;
  R["config8"] = 8;
  R["operations"] = json::Array{
      memoryOperation("unit", "load", false, 64, 64),
      memoryOperation("unit", "store", false, 64, 64),
      operation("spill", false, 0, 32, 0)};
  EXPECT_EQ(cost(Plan, Features), 10); // Memory 7 + spill 2 + config 1.
  R["fp8"] = 32;
  EXPECT_EQ(cost(Plan, Features), 11); // Arithmetic 8 + additive 3.
  R["fp8"] = 0;
  R["scalar8"] = 160;
  EXPECT_EQ(cost(Plan, Features), 13);
  R["scalar8"] = 0;
  R["recurrences"] = json::Array{recurrence(0, 1, 3)};
  EXPECT_EQ(cost(Plan, Features), 14);
  R.erase("recurrences");
  R["operations"].getAsArray()->push_back(operation("slide", false, 64, 64));
  EXPECT_EQ(cost(Plan, Features), 18); // Movement 8+7, then 3.
  R["operations"].getAsArray()->push_back(division("vv", false, 8, 8, 32));
  EXPECT_EQ(cost(Plan, Features), 28); // Divider 25, then 3.
  EXPECT_EQ(cost(Plan, Features, ElementCount::getFixed(1), 19), 19);
}

TEST_F(VPlanRAResourceCost, SeparateMemoryLegacyAndPartialObservations) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 128;
  R["operations"] = json::Array{
      memoryOperation("unit", "load", false, 64, 64),
      operation("unit", false, 64, 64)};
  EXPECT_EQ(cost(Plan, Features), 8); // No partial discount.
  R["operations"] = json::Array{operation("unit", false, 64, 64),
                                 operation("unit", false, 64, 64)};
  EXPECT_EQ(cost(Plan, Features), 8);
  R["operations"] = json::Array{};
  EXPECT_EQ(cost(Plan, Features), 8);
  R.erase("operations");
  EXPECT_EQ(cost(Plan, Features), 8);
}

TEST_F(VPlanRAResourceCost, SeparateMemoryMalformedObservations) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 64;
  for (json::Value Direction : {json::Value("unknown"), json::Value("load_store"),
                                json::Value(1), json::Value(true)}) {
    auto Op = memoryOperation("unit", "load", false, 64, 64);
    Op["direction"] = std::move(Direction);
    R["operations"] = json::Array{std::move(Op)};
    EXPECT_EQ(cost(Plan, Features), 100);
  }
  for (StringRef Kind : {"unit", "strided", "indexed"}) {
    for (StringRef Key : {"sew", "group8", "work8", "masked"}) {
      auto Op = memoryOperation(Kind, "load", false, 64, 64);
      Op.erase(Key);
      R["operations"] = json::Array{std::move(Op)};
      EXPECT_EQ(cost(Plan, Features), 100);
    }
  }
  R["operations"] = json::Array{
      memoryOperation("unit", "load", false, 64, 32)};
  EXPECT_EQ(cost(Plan, Features), 100); // Inconsistent complete totals.
  R["unit8"] = 32;
  R["masked8"] = 1;
  EXPECT_EQ(cost(Plan, Features), 100);
}

TEST_F(VPlanRAResourceCost, SeparateMemoryZeroAndSaturation) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["operations"] = json::Array{
      memoryOperation("unit", "load", true, 64, 0, 1),
      memoryOperation("strided", "store", false, 64, 0)};
  EXPECT_EQ(cost(Plan, Features), 0);
  const int64_t Max = std::numeric_limits<int64_t>::max();
  R["unit8"] = Max;
  R["operations"] = json::Array{
      memoryOperation("unit", "load", false, 64, Max),
      memoryOperation("unit", "store", false, 64, Max)};
  InstructionCost Result = cost(Plan, Features);
  ASSERT_TRUE(Result.isValid());
  EXPECT_GE(Result, 0);
  // Each direction saturates independently; the resource maximum still has
  // the saturated magnitude. Shared service subtraction cannot wrap negative.
  constexpr int64_t Quarters = std::numeric_limits<int64_t>::max() / 16;
  InstructionCost Expected = InstructionCost(Quarters / 4) +
                             InstructionCost(Quarters % 4) / 4;
  EXPECT_EQ(Result, Expected);
  R["spill8"] = Max;
  R["config8"] = Max;
  EXPECT_EQ(cost(Plan, Features), Expected);
  R["unit8"] = 0;
  R["spill8"] = 0;
  R["config8"] = 0;
  R["strided8"] = Max;
  R["masked8"] = Max;
  R["operations"] = json::Array{
      memoryOperation("strided", "load", true, 64, Max, 1),
      memoryOperation("strided", "store", true, 64, Max, 1)};
  EXPECT_EQ(cost(Plan, Features), Expected);
}

TEST_F(VPlanRAResourceCost, SeparateMemoryBoundedAcrossSaturationThresholds) {
  VPlan &Plan = getPlan();
  const int64_t Max = std::numeric_limits<int64_t>::max();
  for (StringRef Kind : {"unit", "strided", "indexed"})
    for (bool Masked : {false, true})
      for (int64_t Work : {Max / 128, Max / 32, Max / 16, Max / 4, Max}) {
        auto Features = features();
        auto &R = resources(Features);
        int64_t Total = Work > Max - Work ? Max : Work + Work;
        R[Kind.str() + "8"] = Total;
        if (Masked)
          R["masked8"] = Total;
        R["operations"] = json::Array{
            memoryOperation(Kind, "load", Masked, 64, Work, 1),
            memoryOperation(Kind, "store", Masked, 64, Work, 1)};
        InstructionCost Separate = cost(Plan, Features);
        for (json::Value &Op : *R["operations"].getAsArray())
          Op.getAsObject()->erase("direction");
        InstructionCost Legacy = cost(Plan, Features);
        ASSERT_TRUE(Separate.isValid());
        EXPECT_GE(Separate, 0);
        EXPECT_LE(Separate, Legacy);
      }
}

TEST_F(VPlanRAResourceCost, PackedMaskLogicalUsesExistingIntegerResource) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["config8"] = 8;
  R["scalar8"] = 24;
  // Ten Boolean/alias families over B=1..64. Independently counted service:
  // VLEN=128: 10*7; 256: 10*(2+6); 1024: 10*(8+4+2+4);
  // 2048: 10*(16+8+4+2+3). No change to the integer coefficient.
  for (auto [Work, Expected] :
       {std::pair<int64_t, int64_t>{560, 71}, {640, 81},
        {1440, 181}, {2640, 331}}) {
    R["integer8"] = Work;
    EXPECT_EQ(cost(Plan, Features), Expected);
    EXPECT_EQ(cost(Plan, Features, ElementCount::getScalable(16)), Expected);
  }
  EXPECT_EQ(cost(Plan, Features, ElementCount::getFixed(1), 37), 37);
}

TEST_F(VPlanRAResourceCost, PackedMaskDemandOverlapsAndKeepsAdditiveCosts) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  // One B1 mask at VLEN=2048 processes 2048 packed bits: 16 integer units.
  R["integer8"] = 128;
  R["operations"] = json::Array{operation("mask_logical", false, 64, 128, 1)};
  R["spill8"] = 24; // 1.5 remains additive.
  R["config8"] = 8; // 1 remains additive.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(37) / 2);
  R["fp8"] = 80; // 20 FP units add on the same arithmetic resource.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(77) / 2); // 16+20+2.5.
  R["unit8"] = 640; // 40 memory units dominate the arithmetic sum of 36.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(85) / 2);
  R["supported"] = false;
  EXPECT_EQ(cost(Plan, Features, ElementCount::getScalable(4), 37), 37);
}

TEST_F(VPlanRAResourceCost, DividerFormsGroupingAndSEW) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  for (StringRef Form : {"vv", "vf", "reverse_vf"}) {
    for (bool Masked : {false, true}) {
      for (int64_t SEW : {16, 32, 64}) {
        int64_t Service = SEW == 16 ? 29 : (SEW == 32 ? 25 : 37);
        // Fractional groups retain their identity but issue one chunk.
        for (int64_t Group : {1, 2, 4, 8, 16, 32, 64}) {
          int64_t Work = std::max<int64_t>(8, Group);
          R["operations"] = json::Array{division(Form, Masked, Group, Work, SEW)};
          EXPECT_EQ(cost(Plan, Features), InstructionCost(Work / 8 * Service));
        }
      }
    }
  }
  // Service scales with observed chunks, including a larger target VLEN.
  R["operations"] = json::Array{division("vv", false, 16, 32, 32)};
  EXPECT_EQ(cost(Plan, Features, ElementCount::getScalable(4), 7), 100);
  R["operations"] = json::Array{division("vv", false, 8, 8, 32),
                                division("reverse_vf", true, 8, 8, 64)};
  EXPECT_EQ(cost(Plan, Features), 62); // Division service accumulates.
  R["operations"] = json::Array{division("vf", false, 2, 1, 32),
                                division("vf", true, 2, 1, 32)};
  EXPECT_EQ(cost(Plan, Features), InstructionCost(25) / 4);
}

TEST_F(VPlanRAResourceCost, DividerCompetesWithExistingResources) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 32;    // Memory=2.
  R["fp8"] = 32;      // FP arithmetic=8.
  R["fused8"] = 8;    // Fused arithmetic=2, total arithmetic=10.
  R["scalar8"] = 64;  // Scalar=4.
  R["spill8"] = 24;   // Additive spill=1.5.
  R["config8"] = 16;  // Additive configuration=2.
  R["recurrences"] = json::Array{recurrence(1, 1, 0)}; // Recurrence=8.
  R["operations"] = json::Array{operation("slide", true, 64, 64),
                                operation("copy", false, 32, 32),
                                division("vf", true, 8, 8, 32)};
  // Movement=17; divider=25 wins. No predicate or movement dependency floor.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(57) / 2);
  R["integer8"] = 120; // Arithmetic=25 ties divider; charge it once.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(57) / 2);
  R["integer8"] = 240; // Arithmetic=40 wins.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(87) / 2);
  R["integer8"] = 0;
  R["unit8"] = 640; // Memory=40 wins.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(87) / 2);
  R["unit8"] = 32;
  R["scalar8"] = 640; // Scalar=40 wins.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(87) / 2);
  R["scalar8"] = 64;
  R["recurrences"] = json::Array{recurrence(10, 1, 2)}; // Recurrence=39.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(85) / 2);
  R["recurrences"] = json::Array{recurrence(1, 1, 0)};
  R["operations"] = json::Array{operation("slide", true, 64, 256),
                                operation("copy", false, 32, 32),
                                division("vv", false, 8, 8, 32)};
  EXPECT_EQ(cost(Plan, Features), InstructionCost(89) / 2); // Movement=41.
}

TEST_F(VPlanRAResourceCost, DividerZeroAndPredicateService) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  EXPECT_EQ(cost(Plan, Features), 0); // Legacy aggregate-only observations.
  R["operations"] = json::Array{division("reverse_vf", true, 64, 0, 64)};
  EXPECT_EQ(cost(Plan, Features), 0);
  R["strided8"] = 256;
  R["masked8"] = 256;
  R["spill8"] = 16;
  R["config8"] = 8;
  // Shared predicate service and strided service retain their existing demand:
  // memory=48+12, predicate=21/4, spill/config=2 => 269/4.
  R["operations"] = json::Array{predicateOperation("strided", 32, 128, 1),
                                predicateOperation("strided", 32, 128, 1),
                                division("vf", true, 64, 0, 64)};
  EXPECT_EQ(cost(Plan, Features), InstructionCost(269) / 4);
  R["operations"] = json::Array{predicateOperation("strided", 32, 128, 1),
                                predicateOperation("strided", 32, 128, 1),
                                division("vf", true, 8, 8, 32)};
  EXPECT_EQ(cost(Plan, Features), InstructionCost(269) / 4); // Memory wins.
  R["operations"] = json::Array{predicateOperation("strided", 32, 128, 1),
                                predicateOperation("strided", 32, 128, 1),
                                division("reverse_vf", true, 32, 32, 64)};
  EXPECT_EQ(cost(Plan, Features), 150); // Divider=148 hides memory, plus 2.
}

TEST_F(VPlanRAResourceCost, DividerFallback) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  for (StringRef Key : {"form", "masked", "group8", "work8", "sew"}) {
    auto Missing = division("vv", false, 8, 8, 32);
    Missing.erase(Key);
    R["operations"] = json::Array{std::move(Missing)};
    EXPECT_EQ(cost(Plan, Features), 100);
    auto WrongType = division("vv", false, 8, 8, 32);
    WrongType[Key] = json::Array{};
    R["operations"] = json::Array{std::move(WrongType)};
    EXPECT_EQ(cost(Plan, Features), 100);
  }
  for (int64_t Group : {-1, 0, 3, 128}) {
    R["operations"] = json::Array{division("vv", false, Group, 8, 32)};
    EXPECT_EQ(cost(Plan, Features), 100);
  }
  for (int64_t SEW : {-1, 0, 8, 128}) {
    R["operations"] = json::Array{division("vf", true, 8, 8, SEW)};
    EXPECT_EQ(cost(Plan, Features), 100);
  }
  R["operations"] = json::Array{division("vv", false, 8, -1, 32)};
  EXPECT_EQ(cost(Plan, Features), 100);
  for (StringRef Form : {"", "vx", "reverse_vv"}) {
    R["operations"] = json::Array{division(Form, false, 8, 8, 32)};
    EXPECT_EQ(cost(Plan, Features), 100);
  }
  R["operations"] = json::Array{division("vv", false, 8, 8, 32)};
  EXPECT_EQ(cost(Plan, Features, ElementCount::getFixed(1), 7), 7);
  R["supported"] = false; // Other unsupported operations retain fallback.
  EXPECT_EQ(cost(Plan, Features), 100);
}

TEST_F(VPlanRAResourceCost, DividerSaturatesValidAndNonnegative) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  constexpr int64_t Max = std::numeric_limits<int64_t>::max();
  for (int64_t SEW : {16, 32, 64}) {
    R["operations"] = json::Array{division("vv", false, 64, Max, SEW),
                                  division("reverse_vf", true, 64, Max, SEW)};
    for (int64_t Additive : {int64_t(0), Max}) {
      R["spill8"] = Additive;
      R["config8"] = Additive;
      InstructionCost Result = cost(Plan, Features);
      ASSERT_TRUE(Result.isValid());
      EXPECT_GE(Result, 0);
      constexpr int64_t Quarters = Max / 16;
      InstructionCost Expected = InstructionCost(Quarters / 4) +
                                 InstructionCost(Quarters % 4) / 4;
      EXPECT_EQ(Result, Expected);
    }
  }
}

TEST_F(VPlanRAResourceCost, RecurrenceLatencyAndIndependentAccumulators) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["fused8"] = 16;
  EXPECT_EQ(cost(Plan, Features), 4);
  R["recurrences"] = json::Array{recurrence(0, 1, 0), recurrence(0, 1, 0)};
  EXPECT_EQ(cost(Plan, Features), 5);
  R["recurrences"] = json::Array{recurrence(0, 2, 0)};
  EXPECT_EQ(cost(Plan, Features), 10);
  R["fused8"] = 0;
  R["fp8"] = 16;
  R["recurrences"] = json::Array{recurrence(2, 0, 0)};
  EXPECT_EQ(cost(Plan, Features), 6);
  R["recurrences"] = json::Array{recurrence(1, 0, 0), recurrence(1, 0, 0)};
  EXPECT_EQ(cost(Plan, Features), 4);
}

TEST_F(VPlanRAResourceCost, RecurrenceDominatesAfterScalarOverlap) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["fp8"] = 8;
  R["fused8"] = 8;
  R["scalar8"] = 64;
  R["unit8"] = 16;
  R["spill8"] = 32;
  R["config8"] = 8;
  EXPECT_EQ(cost(Plan, Features), 7); // max(1, 4, 4) + 2 + 1.
  R["recurrences"] = json::Array{recurrence(1, 1, 2)};
  EXPECT_EQ(cost(Plan, Features), 15); // max(1, 4, 4, 12) + 2 + 1.
  R["scalar8"] = 192; // Equal recurrence/scalar demand is counted once.
  EXPECT_EQ(cost(Plan, Features), 15);
}

TEST_F(VPlanRAResourceCost, RecurrenceHiddenByCompetingResources) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["recurrences"] = json::Array{recurrence(0, 1, 0)};
  R["spill8"] = 8;
  R["config8"] = 8;
  for (const char *Key : {"unit8", "integer8", "scalar8", "copy"}) {
    SCOPED_TRACE(Key);
    R["unit8"] = 0;
    R["integer8"] = 0;
    R["scalar8"] = 0;
    R["operations"] = json::Array{};
    if (StringRef(Key) == "copy")
      R["operations"] = json::Array{operation("copy", false, 64, 128, 0)};
    else
      R[Key] = StringRef(Key) == "integer8" ? 64 : 128;
    EXPECT_EQ(cost(Plan, Features), InstructionCost(19) / 2);
    R["recurrences"] = json::Array{};
    EXPECT_EQ(cost(Plan, Features), InstructionCost(19) / 2);
    R["recurrences"] = json::Array{recurrence(0, 1, 0)};
  }
}

TEST_F(VPlanRAResourceCost, RecurrenceKeepsPartialPredicateSharingOnMemory) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 256;
  R["masked8"] = 256;
  R["scalar8"] = 64;
  R["recurrences"] = json::Array{recurrence(13, 1, 0)}; // 44.
  R["operations"] = json::Array{
      predicateOperation("unit", 64, 64, 1),
      predicateOperation("unit", 64, 64, 1),
      predicateOperation("unit", 64, 64, 1),
      predicateOperation("unit", 64, 64, 1)};
  // Memory=32 + 4*(3/4*3.5) + 1/4*3.5 = 43.375, hidden by 44.
  EXPECT_EQ(cost(Plan, Features), 44);
  R["recurrences"] = json::Array{recurrence(13, 0, 2)}; // 43.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(173) / 4);
  for (auto &Op : *R["operations"].getAsArray())
    (*Op.getAsObject())["predicate_id"] = 0;
  EXPECT_EQ(cost(Plan, Features), 46); // All four waits remain independent.
  R["recurrences"] = json::Array{recurrence(13, 1, 0)};
  EXPECT_EQ(cost(Plan, Features), 46);
}

TEST_F(VPlanRAResourceCost, RecurrencePreservesStridedServiceAndAdditiveCosts) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["strided8"] = 96;
  R["scalar8"] = 24;
  R["spill8"] = 32;
  R["config8"] = 8;
  R["operations"] = json::Array{predicateOperation("strided", 16, 96, 1)};
  R["recurrences"] = json::Array{recurrence(1, 1, 2)};
  // Memory=12 + 1.5 strided service + .75 predicate wait, recurrence=12.
  // Spill=2 and configuration=1 remain additive; scalar=1.5 overlaps.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(69) / 4);
  R["recurrences"] = json::Array{recurrence(0, 3, 0)};
  EXPECT_EQ(cost(Plan, Features), 18);
  R["integer8"] = 160;
  EXPECT_EQ(cost(Plan, Features), 23);
}

TEST_F(VPlanRAResourceCost, NoRecurrencePreservesParentScalarOverlap) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 64;
  R["scalar8"] = 160;
  R["fp8"] = 16;
  R["spill8"] = 8;
  R["config8"] = 8;
  R["operations"] = json::Array{operation("copy", false, 64, 128, 0)};
  EXPECT_EQ(cost(Plan, Features), InstructionCost(23) / 2);
  R["recurrences"] = json::Array{};
  EXPECT_EQ(cost(Plan, Features), InstructionCost(23) / 2);
  R["recurrences"] = json::Array{recurrence(0, 0, 0)};
  EXPECT_EQ(cost(Plan, Features), InstructionCost(23) / 2);
}

TEST_F(VPlanRAResourceCost, RecurrenceUsesObservedChunksNotVF) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  for (int64_t Extra : {0, 1, 3, 7}) {
    R["recurrences"] = json::Array{recurrence(0, 1, Extra)};
    InstructionCost Expected = 5 + Extra * 2;
    EXPECT_EQ(cost(Plan, Features), Expected);
    EXPECT_EQ(cost(Plan, Features, ElementCount::getScalable(16)), Expected);
    EXPECT_EQ(cost(Plan, Features, ElementCount::getFixed(4)), Expected);
  }
  EXPECT_EQ(cost(Plan, Features, ElementCount::getFixed(1), 7), 7);
}

TEST_F(VPlanRAResourceCost, AbsentEmptyAndUnsupportedRecurrences) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["fp8"] = 16;
  EXPECT_EQ(cost(Plan, Features), 4);
  R["recurrences"] = json::Array{};
  EXPECT_EQ(cost(Plan, Features), 4);
  R["recurrences"] = json::Array{recurrence(0, 0, 0)};
  EXPECT_EQ(cost(Plan, Features), 4);
  R["recurrences"] = json::Array{recurrence(10, 10, 10)};
  R["supported"] = false;
  EXPECT_EQ(cost(Plan, Features), 100);
  R["supported"] = true;
  R["version"] = 2;
  EXPECT_EQ(cost(Plan, Features), 100);
}

TEST_F(VPlanRAResourceCost, MalformedRecurrences) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["recurrences"] = "not an array";
  EXPECT_EQ(cost(Plan, Features), 100);
  R["recurrences"] = json::Array{0};
  EXPECT_EQ(cost(Plan, Features), 100);
  for (const char *Key : {"fp_steps", "fused_steps", "extra_chunks"}) {
    auto Missing = recurrence(1, 1, 1);
    Missing.erase(Key);
    R["recurrences"] = json::Array{std::move(Missing)};
    EXPECT_EQ(cost(Plan, Features), 100);
    for (json::Value Bad : {json::Value(-1), json::Value("1"),
                           json::Value(true)}) {
      auto Wrong = recurrence(1, 1, 1);
      Wrong[Key] = std::move(Bad);
      R["recurrences"] = json::Array{recurrence(1, 1, 1), std::move(Wrong)};
      EXPECT_EQ(cost(Plan, Features), 100);
    }
  }
}

TEST_F(VPlanRAResourceCost, ExtremeRecurrenceDemand) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  const int64_t Max = std::numeric_limits<int64_t>::max();
  InstructionCost Expected = InstructionCost::getMax();
  Expected /= 16;
  for (auto Chain : {recurrence(Max, 0, 0), recurrence(0, Max, 0),
                     recurrence(0, 0, Max), recurrence(Max, Max, Max)}) {
    R["recurrences"] = json::Array{std::move(Chain)};
    InstructionCost Result = cost(Plan, Features);
    ASSERT_TRUE(Result.isValid());
    EXPECT_GT(Result, 100);
    EXPECT_EQ(Result, Expected);
  }
  R["spill8"] = Max;
  R["scalar8"] = Max;
  R["config8"] = Max;
  EXPECT_EQ(cost(Plan, Features), Expected);
}

TEST_F(VPlanRAResourceCost, RecurrenceResourceOverlapSaturation) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  const int64_t Max = std::numeric_limits<int64_t>::max();
  R["recurrences"] = json::Array{recurrence(Max, Max, Max)};
  R["unit8"] = Max;
  R["masked8"] = Max;
  R["scalar8"] = Max;
  R["fp8"] = Max;
  R["operations"] = json::Array{predicateOperation("unit", 64, Max, 1),
                                operation("copy", false, 64, Max, 0)};
  // Independently: positive saturation produces INT64_MAX internal quarters
  // before the final /16. floor((2^63-1)/16) = 2^59-1 quarters, hence
  // 144115188075855871.75 model units. Additive spill/configuration either
  // leave this maximum unchanged or saturate to it again.
  // Integer compound division divides internal quarters directly. Binary
  // division converts 16 to an InstructionCost and first multiplies the
  // saturated numerator by four, producing a different overflow result.
  InstructionCost Expected = InstructionCost::getMax();
  Expected /= 16;
  constexpr int64_t Quarters = std::numeric_limits<int64_t>::max() / 16;
  InstructionCost Fraction = Quarters % 4;
  Fraction /= 4;
  EXPECT_EQ(Expected, InstructionCost(Quarters / 4) + Fraction);
  for (bool Additive : {false, true}) {
    SCOPED_TRACE(Additive);
    R["spill8"] = Additive ? Max : 0;
    R["config8"] = Additive ? Max : 0;
    InstructionCost Result = cost(Plan, Features);
    ASSERT_TRUE(Result.isValid());
    EXPECT_GE(Result, 0);
    EXPECT_EQ(Result, Expected);
  }
}

TEST_F(VPlanRAResourceCost, OverlapAndSerial) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 64;
  R["integer8"] = 48;
  R["scalar8"] = 24;
  R["config8"] = 8;
  // max(memory=4, arithmetic=6, scalar=1.5) + config=1.
  EXPECT_EQ(cost(Plan, Features), 7);
  R["unit8"] = 160;
  EXPECT_EQ(cost(Plan, Features), 11);
}

TEST_F(VPlanRAResourceCost, ScalarResourceDominance) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["scalar8"] = 160; // Twenty scalar instructions, ten cost units.
  R["unit8"] = 16;    // Memory=1.
  R["integer8"] = 16; // Arithmetic=2.
  R["operations"] = json::Array{operation("copy", false, 64, 64, 0)};
  // Scalar=10 > copy=4 > arithmetic=2 > memory=1.
  EXPECT_EQ(cost(Plan, Features), 10);
  EXPECT_EQ(cost(Plan, Features, ElementCount::getFixed(4)), 10);
  EXPECT_EQ(cost(Plan, Features, ElementCount::getScalable(16)), 10);
  R["scalar8"] = 176;
  EXPECT_EQ(cost(Plan, Features), 11);
}

TEST_F(VPlanRAResourceCost, VectorResourcesHideScalarThroughput) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["scalar8"] = 64; // Scalar=4.
  R["unit8"] = 64;
  R["masked8"] = 64;
  R["operations"] = json::Array{predicateOperation("unit", 64, 64, 1)};
  // Memory=8 + predicate service=3.5 hides scalar=4.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(23) / 2);
  R["fp8"] = 64; // Arithmetic=16 hides memory+service and scalar.
  EXPECT_EQ(cost(Plan, Features), 16);
  R["operations"].getAsArray()->push_back(operation("copy", false, 64, 320, 0));
  EXPECT_EQ(cost(Plan, Features), 20); // Copy=20 dominates.
  R["scalar8"] = 320;
  EXPECT_EQ(cost(Plan, Features), 20); // Equal demand is counted once.
}

TEST_F(VPlanRAResourceCost, ZeroScalarDemandPreservesVectorCosts) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  EXPECT_EQ(cost(Plan, Features), 0);
  R["unit8"] = 64;
  EXPECT_EQ(cost(Plan, Features), 4);
  R["integer8"] = 64;
  EXPECT_EQ(cost(Plan, Features), 8);
  R["operations"] = json::Array{operation("copy", false, 64, 192, 0)};
  EXPECT_EQ(cost(Plan, Features), 12);
}

TEST_F(VPlanRAResourceCost, ScalarOverlapKeepsConfigurationAndSpillsAdditive) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["scalar8"] = 160; // Scalar=10, vector arithmetic=4.
  R["integer8"] = 32;
  R["config8"] = 24; // Three configuration instructions.
  R["spill8"] = 32;  // Spill=2.
  EXPECT_EQ(cost(Plan, Features), 15); // 10 + 3 + 2.
  R["config8"] = 40;
  EXPECT_EQ(cost(Plan, Features), 17); // 10 + 5 + 2.
  R["spill8"] = 64;
  EXPECT_EQ(cost(Plan, Features), 19); // 10 + 5 + 4.
  R["fp8"] = 80;
  EXPECT_EQ(cost(Plan, Features), 33); // Arithmetic=24 + 5 + 4.
}

TEST_F(VPlanRAResourceCost, ScalarOverlapFractionalCosts) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 3;
  R["scalar8"] = 5;
  // max(3/16, 5/16) truncates once to a quarter.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(1) / 4);
  R["spill8"] = 3;
  EXPECT_EQ(cost(Plan, Features), InstructionCost(1) / 2); // (5+3)/16.
  R["config8"] = 1;
  EXPECT_EQ(cost(Plan, Features), InstructionCost(1) / 2); // 10/16.
  R["unit8"] = 9;
  EXPECT_EQ(cost(Plan, Features), InstructionCost(3) / 4); // (9+3+2)/16.
  R["scalar8"] = 11;
  EXPECT_EQ(cost(Plan, Features), 1); // (11+3+2)/16.
  R["scalar8"] = 0;
  EXPECT_EQ(cost(Plan, Features), InstructionCost(3) / 4);
}

TEST_F(VPlanRAResourceCost, ScalarOverlapSaturation) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  const int64_t Max = std::numeric_limits<int64_t>::max();
  // Constructor saturates internal quarters; final integer division is /16.
  constexpr int64_t Quarters = std::numeric_limits<int64_t>::max() / 16;
  const InstructionCost Expected = InstructionCost(Quarters / 4) +
                                   InstructionCost(Quarters % 4) / 4;
  R["scalar8"] = Max;
  for (bool VectorDominates : {false, true}) {
    R["fp8"] = VectorDominates ? Max : 0;
    for (bool Additive : {false, true}) {
      R["spill8"] = Additive ? Max : 0;
      R["config8"] = Additive ? Max : 0;
      InstructionCost Result = cost(Plan, Features);
      ASSERT_TRUE(Result.isValid());
      EXPECT_GE(Result, 0);
      EXPECT_EQ(Result, Expected);
    }
  }
  // Near the internal limit, overlapping equal resources must not add them.
  R["scalar8"] = Max / 16;
  R["unit8"] = Max / 16;
  R["fp8"] = 0;
  R["spill8"] = 0;
  R["config8"] = 0;
  constexpr int64_t NearQuarters = (Max / 16 * 4) / 16;
  EXPECT_EQ(cost(Plan, Features), InstructionCost(NearQuarters / 4) +
                                    InstructionCost(NearQuarters % 4) / 4);
}

TEST_F(VPlanRAResourceCost, AccessClassesAndMasking) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 32;
  R["strided8"] = 16;
  R["indexed8"] = 24;
  R["masked8"] = 52;
  EXPECT_EQ(cost(Plan, Features), InstructionCost(41) / 4);
  // Fractional eighth-unit inputs are rounded only after accumulation.
  R["unit8"] = 1;
  R["strided8"] = 0;
  R["indexed8"] = 0;
  R["masked8"] = 3;
  EXPECT_EQ(cost(Plan, Features), InstructionCost(1) / 4);
}

TEST_F(VPlanRAResourceCost, FusedVersusSplit) {
  VPlan &Plan = getPlan();
  auto Fused = features();
  resources(Fused)["fused8"] = 32;
  auto Split = features();
  resources(Split)["fp8"] = 64;
  EXPECT_EQ(cost(Plan, Fused), 8);
  EXPECT_EQ(cost(Plan, Split), 16);
  EXPECT_LT(cost(Plan, Fused), cost(Plan, Split));
}

TEST_F(VPlanRAResourceCost, UnmaskedMemoryGrouping) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 128;
  R["integer8"] = 80;
  R["spill8"] = 32;
  R["scalar8"] = 24;
  R["config8"] = 8;
  InstructionCost Original = cost(Plan, Features);
  EXPECT_EQ(Original, 13);
  for (int64_t Group : {1, 2, 4, 8, 16, 32, 64}) {
    R["operations"] = json::Array{
        operation("unit", false, Group, 128),
        operation("indexed", false, Group, 128),
        operation("fp", true, Group, 128),
        operation("spill", false, 0, 32)};
    EXPECT_EQ(cost(Plan, Features), Original);
    // The term depends on the observed instruction, never on the chosen VF.
    EXPECT_EQ(cost(Plan, Features, ElementCount::getScalable(16)), Original);
  }
  const int64_t Groups[] = {1, 2, 4, 8, 16, 32, 64};
  // Memory numerator: 128 + 128 * max(group8 - 8, 0) / 32.
  // Arithmetic numerator: 160; scalar numerator: 24.
  // Additive numerator: 32 + 16 = 48.
  // At M4/M8: (max(224/352, 160, 24) + 48) / 16 = 17/25.
  const InstructionCost Expected[] = {13, 13, 13, 13, 13, 17, 25};
  for (unsigned I = 0; I != 7; ++I) {
    R["operations"] = json::Array{
        operation("unit", false, Groups[I], 128),
        operation("strided", false, Groups[I], 128),
        operation("indexed", false, Groups[I], 128),
        operation("fp", true, Groups[I], 128),
        operation("spill", false, 0, 32)};
    EXPECT_EQ(cost(Plan, Features), Expected[I]);
    EXPECT_EQ(cost(Plan, Features, ElementCount::getScalable(16)), Expected[I]);
  }
}

TEST_F(VPlanRAResourceCost, StridedFractionalAndIntegralGroups) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  const int64_t Groups[] = {1, 2, 4, 8, 16, 32, 64};
  const int64_t Work[] = {8, 8, 16, 32, 64, 128, 256};
  const int64_t Expected[] = {1, 1, 2, 4, 9, 22, 60};
  for (unsigned I = 0; I != 7; ++I) {
    R["strided8"] = Work[I];
    R["operations"] =
        json::Array{operation("strided", false, Groups[I], Work[I])};
    EXPECT_EQ(cost(Plan, Features), Expected[I]);
    EXPECT_EQ(cost(Plan, Features, ElementCount::getFixed(4)), Expected[I]);
    EXPECT_EQ(cost(Plan, Features, ElementCount::getScalable(16)), Expected[I]);
  }
  R.erase("operations");
  // Aggregate-only feedback retains the original linear strided demand.
  EXPECT_EQ(cost(Plan, Features), 32);
}

TEST_F(VPlanRAResourceCost, StridedSEWWork) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  const int64_t SEWs[] = {8, 16, 32, 64};
  const int64_t Work[] = {512, 256, 128, 64};
  const int64_t Expected[] = {88, 44, 22, 11};
  for (unsigned I = 0; I != 4; ++I) {
    // M4 at VLEN=128: work8 = group8 * VLEN / SEW.
    R["strided8"] = Work[I];
    R["operations"] =
        json::Array{operation("strided", false, 32, Work[I], SEWs[I])};
    EXPECT_EQ(cost(Plan, Features), Expected[I]);
  }
}

TEST_F(VPlanRAResourceCost, StridedPerOperationAccumulation) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["strided8"] = 8;
  R["operations"] = json::Array{operation("strided", false, 16, 8)};
  EXPECT_EQ(cost(Plan, Features), 1); // 1 + 1/8 rounds down to a quarter.
  R["scalar8"] = 2;
  EXPECT_EQ(cost(Plan, Features), 1); // Scalar=1/8 is hidden.
  R["scalar8"] = 0;
  R["strided8"] = 16;
  // Two eighth-unit increments combine into a quarter before rounding.
  R["operations"] = json::Array{operation("strided", false, 16, 8),
                                 operation("strided", false, 16, 8)};
  EXPECT_EQ(cost(Plan, Features), InstructionCost(9) / 4);
  R["operations"] = json::Array{operation("strided", false, 8, 8),
                                 operation("strided", false, 8, 8)};
  EXPECT_EQ(cost(Plan, Features), 2);
  // Equal aggregate work does not imply equal grouped service demand.
  R["operations"] = json::Array{operation("strided", false, 32, 16)};
  EXPECT_EQ(cost(Plan, Features), InstructionCost(11) / 4);
}

TEST_F(VPlanRAResourceCost, StridedResourceOverlapAndAdditiveCosts) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["strided8"] = 128;
  R["spill8"] = 32;
  R["scalar8"] = 24;
  R["config8"] = 8;
  R["operations"] = json::Array{operation("strided", false, 32, 128)};
  EXPECT_EQ(cost(Plan, Features), 25); // 22 + 3.
  R["fp8"] = 128;
  EXPECT_EQ(cost(Plan, Features), 35); // 32 + 3.
  R["fp8"] = 80;
  EXPECT_EQ(cost(Plan, Features), 25); // max(22, 20).
  R["spill8"] = 64;
  EXPECT_EQ(cost(Plan, Features), 27);
}

TEST_F(VPlanRAResourceCost, MaskedStridedServiceAndSerialization) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["strided8"] = 128;
  R["masked8"] = 128;
  R["operations"] = json::Array{operation("strided", true, 32, 128)};
  EXPECT_EQ(cost(Plan, Features), 33); // 16 + 8 + 6 service + 3 serial.
  R["fp8"] = 128;
  EXPECT_EQ(cost(Plan, Features), 33); // max(30 + 3, 32).
  R["spill8"] = 32;
  EXPECT_EQ(cost(Plan, Features), 35);
  R["masked8"] = 0;
  R["operations"] = json::Array{operation("strided", false, 32, 128)};
  EXPECT_EQ(cost(Plan, Features), 34);
}

TEST_F(VPlanRAResourceCost, MalformedStridedOperations) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["strided8"] = 16;
  for (bool Masked : {false, true}) {
    for (int64_t Group : {-1, 0, 3, 128}) {
      R["operations"] = json::Array{operation("strided", Masked, Group, 16)};
      EXPECT_EQ(cost(Plan, Features), 100);
    }
    for (int64_t SEW : {-1, 0, 7, 128}) {
      R["operations"] =
          json::Array{operation("strided", Masked, 16, 16, SEW)};
      EXPECT_EQ(cost(Plan, Features), 100);
    }
    R["operations"] = json::Array{operation("strided", Masked, 16, -1)};
    EXPECT_EQ(cost(Plan, Features), 100);
    for (StringRef Key : {"group8", "work8", "sew", "masked"}) {
      auto Missing = operation("strided", Masked, 16, 16);
      Missing.erase(Key);
      R["operations"] = json::Array{std::move(Missing)};
      EXPECT_EQ(cost(Plan, Features), 100);
      auto WrongType = operation("strided", Masked, 16, 16);
      WrongType[Key] = "16";
      R["operations"] = json::Array{std::move(WrongType)};
      EXPECT_EQ(cost(Plan, Features), 100);
    }
  }
  EXPECT_EQ(cost(Plan, Features, ElementCount::getFixed(1), 7), 7);
}

TEST_F(VPlanRAResourceCost, ExtremeStridedDemand) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  const int64_t Max = std::numeric_limits<int64_t>::max();
  R["operations"] = json::Array{operation("strided", false, 64, 0)};
  EXPECT_EQ(cost(Plan, Features), 0);
  R["operations"] = json::Array{operation("strided", false, 8, Max)};
  EXPECT_EQ(cost(Plan, Features), 0);
  R["operations"] = json::Array{operation("strided", false, 64, Max),
                                 operation("strided", false, 64, Max)};
  // The product and its sum saturate before integer divisions by 32 and 16.
  constexpr int64_t ExpectedQuarters =
      std::numeric_limits<int64_t>::max() / 32 / 16;
  const InstructionCost Expected = InstructionCost(ExpectedQuarters / 4) +
                                   InstructionCost(ExpectedQuarters % 4) / 4;
  InstructionCost ServiceOnly = cost(Plan, Features);
  ASSERT_TRUE(ServiceOnly.isValid());
  EXPECT_GE(ServiceOnly, 0);
  EXPECT_EQ(ServiceOnly, Expected);
  R["strided8"] = Max;
  R["fp8"] = Max;
  R["spill8"] = Max;
  InstructionCost All = cost(Plan, Features);
  ASSERT_TRUE(All.isValid());
  EXPECT_GE(All, ServiceOnly);
  InstructionCost Saturated = InstructionCost::getMax();
  Saturated /= 16;
  EXPECT_EQ(All, Saturated);
}

TEST_F(VPlanRAResourceCost, SlideAndCopyGroups) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  const int64_t Groups[] = {1, 2, 4, 8, 16, 32, 64};
  const int64_t Work[] = {8, 8, 8, 8, 16, 32, 64};
  // Independent chunk/boundary counts at VLEN=128: slides = 1,1,1,1,
  // (2+1),(4+3),(8+7). Copies = half the number of transferred chunks.
  const int64_t Slides[] = {1, 1, 1, 1, 3, 7, 15};
  const InstructionCost Copies[] = {
      InstructionCost(1) / 2, InstructionCost(1) / 2,
      InstructionCost(1) / 2, InstructionCost(1) / 2, 1, 2, 4};
  for (unsigned I = 0; I != 7; ++I) {
    for (bool Masked : {false, true}) {
      R["operations"] =
          json::Array{operation("slide", Masked, Groups[I], Work[I])};
      EXPECT_EQ(cost(Plan, Features), Slides[I]);
      EXPECT_EQ(cost(Plan, Features, ElementCount::getScalable(16)), Slides[I]);
      EXPECT_EQ(cost(Plan, Features, ElementCount::getFixed(4)), Slides[I]);
    }
    R["operations"] =
        json::Array{operation("copy", false, Groups[I], Work[I])};
    EXPECT_EQ(cost(Plan, Features), Copies[I]);
  }
}

TEST_F(VPlanRAResourceCost, MovementAccumulationAndZeroWork) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  EXPECT_EQ(cost(Plan, Features), 0);
  R["operations"] = json::Array{operation("slide", false, 64, 0),
                                 operation("copy", false, 64, 0)};
  EXPECT_EQ(cost(Plan, Features), 0);
  R["operations"] = json::Array{operation("copy", false, 4, 1),
                                 operation("copy", false, 4, 1),
                                 operation("slide", false, 4, 1)};
  // Four sixteenth units accumulate to a quarter before final rounding.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(1) / 4);
  R["operations"] = json::Array{operation("slide", false, 32, 32),
                                 operation("copy", false, 16, 16)};
  EXPECT_EQ(cost(Plan, Features), 8); // 4 slide chunks + 3 boundaries + 1 copy.
}

TEST_F(VPlanRAResourceCost, MovementOverlapPreservesMemoryAndSpills) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["strided8"] = 128;
  R["masked8"] = 128;
  R["spill8"] = 32;
  R["scalar8"] = 24;
  R["config8"] = 8;
  R["operations"] = json::Array{operation("strided", true, 32, 128),
                                 operation("slide", true, 64, 64),
                                 operation("copy", false, 64, 64)};
  // Memory+waits=30+3, movement=15+4, scalar=1.5, spill/config=2+1.
  EXPECT_EQ(cost(Plan, Features), 36);
  R["fp8"] = 144; // Arithmetic=36 hides memory+waits=33 and movement=19.
  EXPECT_EQ(cost(Plan, Features), 39);
  R["operations"] = json::Array{operation("strided", true, 32, 128),
                                 operation("slide", false, 64, 256)};
  // Movement=32+7 dominates, hiding predicate service and scalar work.
  EXPECT_EQ(cost(Plan, Features), 42); // 39 + spill=2 + config=1.
}

TEST_F(VPlanRAResourceCost, MovementFallback) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  for (StringRef Kind : {"slide", "copy"}) {
    for (int64_t Group : {-1, 0, 3, 128}) {
      R["operations"] = json::Array{operation(Kind, false, Group, 8)};
      EXPECT_EQ(cost(Plan, Features), 100);
    }
    R["operations"] = json::Array{operation(Kind, false, 8, -1)};
    EXPECT_EQ(cost(Plan, Features), 100);
    for (StringRef Key : {"group8", "work8"}) {
      auto Missing = operation(Kind, false, 8, 8);
      Missing.erase(Key);
      R["operations"] = json::Array{std::move(Missing)};
      EXPECT_EQ(cost(Plan, Features), 100);
      auto WrongType = operation(Kind, false, 8, 8);
      WrongType[Key] = "8";
      R["operations"] = json::Array{std::move(WrongType)};
      EXPECT_EQ(cost(Plan, Features), 100);
    }
  }
  R["operations"] = json::Array{operation("slide", false, 64, 64)};
  EXPECT_EQ(cost(Plan, Features, ElementCount::getFixed(1), 7), 7);
  R["supported"] = false; // Collector rejected another operation in the loop.
  EXPECT_EQ(cost(Plan, Features), 100);
}

TEST_F(VPlanRAResourceCost, SaturatedMovement) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  for (StringRef Kind : {"slide", "copy"}) {
    R["operations"] = json::Array{
        operation(Kind, false, 64, std::numeric_limits<int64_t>::max()),
        operation(Kind, false, 64, std::numeric_limits<int64_t>::max())};
    // The internal signed quarter-unit accumulator saturates at INT64_MAX.
    constexpr int64_t Quarters = std::numeric_limits<int64_t>::max() / 16;
    InstructionCost Expected = InstructionCost(Quarters / 4) +
                               InstructionCost(Quarters % 4) / 4;
    InstructionCost Result = cost(Plan, Features);
    ASSERT_TRUE(Result.isValid());
    EXPECT_GE(Result, 0);
    EXPECT_EQ(Result, Expected);
  }
}

TEST_F(VPlanRAResourceCost, MovementSharesCopyAndSlideService) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 32;   // Memory=2.
  R["integer8"] = 32; // Arithmetic=4.
  R["scalar8"] = 64; // Scalar=4.
  R["recurrences"] = json::Array{recurrence(0, 1, 0)}; // Recurrence=5.
  R["spill8"] = 24;  // Spill=1.5.
  R["config8"] = 16; // Configuration=2.
  R["operations"] = json::Array{operation("slide", false, 32, 32),
                                operation("copy", false, 32, 32, 0)};
  // Four slide chunks + three boundaries + four half-unit copy chunks = 9.
  // The shared movement resource exceeds each other resource, including the
  // recurrence. max(slide, copy) would incorrectly predict 7 + 3.5 instead.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(25) / 2); // 9 + 1.5 + 2.
  R["scalar8"] = 160;
  EXPECT_EQ(cost(Plan, Features), InstructionCost(27) / 2); // 10 + 3.5.
  R["scalar8"] = 144;
  EXPECT_EQ(cost(Plan, Features), InstructionCost(25) / 2); // Equal demand once.
  R["recurrences"] = json::Array{recurrence(1, 1, 2)}; // 3 + 5 + 4 = 12.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(31) / 2); // 12 + 3.5.
  R["scalar8"] = 192;
  EXPECT_EQ(cost(Plan, Features), InstructionCost(31) / 2); // Recurrence tie.
}

TEST_F(VPlanRAResourceCost, MovementKeepsPartialPredicateSharing) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 128;
  R["masked8"] = 128;
  R["scalar8"] = 128; // Scalar=8.
  R["recurrences"] = json::Array{recurrence(3, 0, 1)}; // 11.
  R["spill8"] = 8;
  R["config8"] = 8;
  auto Operations = []() {
    return json::Array{predicateOperation("unit", 64, 64, 1),
                       predicateOperation("unit", 64, 64, 1)};
  };
  R["operations"] = Operations();
  // Base memory=16. Two equal 3.5-unit predicate delays share one quarter:
  // 2*(3/4*3.5) + 1/4*3.5 = 6.125. Total=22.125 + 1.5 -> 23.5.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(47) / 2);
  auto Ops = Operations();
  Ops.push_back(operation("slide", false, 64, 64)); // Slide=15.
  Ops.push_back(operation("copy", false, 64, 64, 0)); // Copy=4.
  R["operations"] = std::move(Ops);
  EXPECT_EQ(cost(Plan, Features), InstructionCost(47) / 2); // Memory dominates.
  R["operations"].getAsArray()->push_back(operation("slide", true, 32, 32));
  // Movement=15+4+7=26 hides memory+service, scalar and recurrence.
  // Masked slides add no masked-memory predicate delay.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(55) / 2);
  R["fp8"] = 112; // Arithmetic=28 hides movement.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(59) / 2);
}

TEST_F(VPlanRAResourceCost, ZeroSlidesPreserveAllParentResources) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["spill8"] = 8;
  R["config8"] = 8;
  for (const char *Dominant : {"unit8", "fp8", "copy", "scalar8",
                                "recurrence"}) {
    SCOPED_TRACE(Dominant);
    R["unit8"] = StringRef(Dominant) == "unit8" ? 160 : 16;
    R["fp8"] = StringRef(Dominant) == "fp8" ? 40 : 8;
    R["scalar8"] = StringRef(Dominant) == "scalar8" ? 160 : 16;
    R["recurrences"] = json::Array{
        recurrence(0, StringRef(Dominant) == "recurrence" ? 2 : 0, 0)};
    R["operations"] = json::Array{operation(
        "copy", false, 64, StringRef(Dominant) == "copy" ? 160 : 16, 0)};
    EXPECT_EQ(cost(Plan, Features), InstructionCost(23) / 2); // 10 + .5 + 1.
    for (int64_t Group : {1, 2, 4, 8, 16, 32, 64})
      R["operations"].getAsArray()->push_back(operation("slide", true, Group, 0));
    EXPECT_EQ(cost(Plan, Features), InstructionCost(23) / 2);
  }
}

TEST_F(VPlanRAResourceCost, FractionalSlidesOverlapAndAccumulateBeforeRounding) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["scalar8"] = 20; // 1.25.
  R["spill8"] = 3;
  R["config8"] = 1;
  for (int64_t Group : {1, 2, 4, 8}) {
    SCOPED_TRACE(Group);
    R["operations"] = json::Array{operation("slide", true, Group, 8),
                                  operation("copy", false, 8, 8, 0)};
    // One issued slide chunk plus half a copy chunk = 1.5, with no boundary.
    // Add 3/16 spill and 1/8 config: 29/16 rounds once to 1.75.
    EXPECT_EQ(cost(Plan, Features), InstructionCost(7) / 4);
  }
  R["operations"] = json::Array{operation("slide", false, 4, 1),
                                operation("slide", false, 4, 1),
                                operation("copy", false, 8, 1, 0)};
  R["scalar8"] = 0;
  // Synthetic sub-quarter inputs sum to 5/16 before 5/16 additive demand.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(1) / 2); // 10/16 -> .5.
  R["recurrences"] = json::Array{recurrence(1, 0, 0)};
  EXPECT_EQ(cost(Plan, Features), InstructionCost(13) / 4); // 3+5/16 -> 3.25.
}

TEST_F(VPlanRAResourceCost, MovementInteractionFallback) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["scalar8"] = 160;
  R["recurrences"] = json::Array{recurrence(1, 1, 2)};
  R["operations"] = json::Array{operation("slide", false, 64, 64),
                                operation("copy", false, 64, 64, 0)};
  EXPECT_EQ(cost(Plan, Features), 19);
  R["supported"] = false; // Gather after the observed slide/copy rejects loop.
  R["operations"].getAsArray()->push_back(operation("gather", false, 64, 64));
  EXPECT_EQ(cost(Plan, Features), 100);
  R["supported"] = true;
  R["recurrences"] = json::Array{recurrence(1, 1, -1)};
  EXPECT_EQ(cost(Plan, Features), 100);
  R["recurrences"] = json::Array{recurrence(1, 1, 2)};
  R["operations"] = json::Array{operation("slide", false, 3, 64)};
  EXPECT_EQ(cost(Plan, Features), 100);
}

TEST_F(VPlanRAResourceCost, MovementScalarRecurrenceSaturation) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  constexpr int64_t Max = std::numeric_limits<int64_t>::max();
  // Independently, INT64_MAX internal quarters saturates before /16:
  // floor((2^63-1)/16)/4 = 144115188075855871.75 model units.
  constexpr int64_t Quarters = Max / 16;
  const InstructionCost Expected = InstructionCost(Quarters / 4) +
                                   InstructionCost(Quarters % 4) / 4;
  for (const char *Dominant : {"slide", "copy", "scalar", "recurrence"}) {
    SCOPED_TRACE(Dominant);
    R["scalar8"] = StringRef(Dominant) == "scalar" ? Max : 16;
    R["recurrences"] = json::Array{
        recurrence(StringRef(Dominant) == "recurrence" ? Max : 1, 0, 0)};
    R["operations"] = json::Array{
        operation("slide", false, 64, StringRef(Dominant) == "slide" ? Max : 64),
        operation("copy", false, 64, StringRef(Dominant) == "copy" ? Max : 64, 0)};
    for (bool Additive : {false, true}) {
      R["spill8"] = Additive ? Max : 0;
      R["config8"] = Additive ? Max : 0;
      InstructionCost Result = cost(Plan, Features);
      ASSERT_TRUE(Result.isValid());
      EXPECT_GE(Result, 0);
      EXPECT_EQ(Result, Expected);
    }
  }
  // Below saturation the resources must overlap, while copy and slide sum.
  // Two MF2 slides each carry Max/32 work; there are no group boundaries.
  // Movement and scalar both equal Max/8 (rounded down); adding them would
  // double the common demand and produce a different result.
  constexpr int64_t SmallWork = Max / 32;
  R["operations"] = json::Array{operation("slide", false, 4, SmallWork),
                                operation("slide", false, 4, SmallWork)};
  R["scalar8"] = SmallWork * 4;
  R["recurrences"] = json::Array{recurrence(1, 0, 0)};
  R["spill8"] = 0;
  R["config8"] = 0;
  constexpr int64_t NearQuarters = SmallWork * 16 / 16;
  InstructionCost Fraction = NearQuarters % 4;
  Fraction /= 4;
  EXPECT_EQ(cost(Plan, Features), InstructionCost(NearQuarters / 4) + Fraction);
}

TEST_F(VPlanRAResourceCost, PhysicalCopyGroupsAndSelfCopies) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  const int64_t Groups[] = {8, 16, 32, 64};
  const InstructionCost Expected[] = {InstructionCost(1) / 2, 1, 2, 4};
  for (unsigned I = 0; I != 4; ++I) {
    // VLEN=128: transfer 1/2/4/8 physical registers at half a unit each.
    R["operations"] =
        json::Array{operation("copy", false, Groups[I], Groups[I], 0)};
    EXPECT_EQ(cost(Plan, Features), Expected[I]);
    EXPECT_EQ(cost(Plan, Features, ElementCount::getScalable(16)), Expected[I]);
    EXPECT_EQ(cost(Plan, Features, ElementCount::getFixed(4)), Expected[I]);
    R["operations"] =
        json::Array{operation("copy", false, Groups[I], 0, 0)};
    EXPECT_EQ(cost(Plan, Features), 0);
  }
  // Work scales with physical VLEN, without charging for SEW again.
  R["operations"] = json::Array{operation("copy", false, 16, 32, 0)};
  EXPECT_EQ(cost(Plan, Features), 2);
}

TEST_F(VPlanRAResourceCost, CopyAccumulationAndZeroWork) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["operations"] = json::Array{operation("copy", false, 8, 8, 0),
                                 operation("copy", false, 16, 16, 0),
                                 operation("copy", false, 32, 32, 0),
                                 operation("copy", false, 64, 64, 0),
                                 operation("copy", false, 64, 0, 0)};
  EXPECT_EQ(cost(Plan, Features), InstructionCost(15) / 2);
  // Accumulate sub-quarter synthetic work before the final body division.
  R["operations"] = json::Array{operation("copy", false, 8, 1, 0),
                                 operation("copy", false, 8, 1, 0),
                                 operation("copy", false, 8, 1, 0),
                                 operation("copy", false, 8, 1, 0)};
  EXPECT_EQ(cost(Plan, Features), InstructionCost(1) / 4);
}

TEST_F(VPlanRAResourceCost, CopyOverlapPreservesMemoryAndSpills) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["strided8"] = 128;
  R["masked8"] = 128;
  R["spill8"] = 32;
  R["scalar8"] = 24;
  R["config8"] = 8;
  R["operations"] = json::Array{operation("strided", true, 32, 128),
                                 operation("copy", false, 64, 64, 0)};
  // Memory+waits=30+3 > copy=4; scalar=1.5 is hidden; spill/config=2+1.
  EXPECT_EQ(cost(Plan, Features), 36);
  R["fp8"] = 128; // Memory+waits=33 > arithmetic=32 and copy=4.
  EXPECT_EQ(cost(Plan, Features), 36);
  R["integer8"] = 8;
  R["fused8"] = 8;
  json::Array Operations{operation("strided", true, 32, 128),
                         operation("integer", false, 8, 8),
                         operation("fp", false, 64, 64),
                         operation("fp", false, 64, 64),
                         operation("fused", false, 8, 8)};
  for (unsigned I = 0; I != 10; ++I)
    Operations.push_back(operation("copy", false, 64, 64, 0));
  R["operations"] = std::move(Operations);
  // Copy=40 > arithmetic=35 and memory+waits=33; additive costs persist.
  EXPECT_EQ(cost(Plan, Features), 43);
}

TEST_F(VPlanRAResourceCost, CopyFallbackPreservesUnsupportedLoop) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 16;
  R["operations"] = json::Array{operation("unit", false, 16, 16),
                                 operation("copy", false, 64, 64, 0)};
  EXPECT_EQ(cost(Plan, Features), 4);
  EXPECT_EQ(cost(Plan, Features, ElementCount::getFixed(1), 7), 7);
  // A gather rejects the loop even when supported copy/slide work preceded it.
  // Partial observations must not authorize costing an unsupported loop.
  R["supported"] = false;
  EXPECT_EQ(cost(Plan, Features), 100);
  for (StringRef Kind : {"slide", "gather"}) {
    R["operations"] = json::Array{operation("copy", false, 64, 64, 0),
                                   operation(Kind, false, 64, 64)};
    EXPECT_EQ(cost(Plan, Features), 100);
  }
}

TEST_F(VPlanRAResourceCost, MalformedCopyOperations) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  for (int64_t Group : {-1, 0, 3, 128}) {
    R["operations"] = json::Array{operation("copy", false, Group, 8, 0)};
    EXPECT_EQ(cost(Plan, Features), 100);
  }
  R["operations"] = json::Array{operation("copy", false, 8, -1, 0)};
  EXPECT_EQ(cost(Plan, Features), 100);
  for (StringRef Key : {"group8", "work8"}) {
    auto Missing = operation("copy", false, 8, 8, 0);
    Missing.erase(Key);
    R["operations"] = json::Array{std::move(Missing)};
    EXPECT_EQ(cost(Plan, Features), 100);
    auto WrongType = operation("copy", false, 8, 8, 0);
    WrongType[Key] = "8";
    R["operations"] = json::Array{std::move(WrongType)};
    EXPECT_EQ(cost(Plan, Features), 100);
  }
}

TEST_F(VPlanRAResourceCost, SaturatedCopyDemand) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["operations"] = json::Array{
      operation("copy", false, 64, std::numeric_limits<int64_t>::max(), 0),
      operation("copy", false, 64, std::numeric_limits<int64_t>::max(), 0)};
  constexpr int64_t Quarters = std::numeric_limits<int64_t>::max() / 16;
  InstructionCost Expected = InstructionCost(Quarters / 4) +
                             InstructionCost(Quarters % 4) / 4;
  InstructionCost Result = cost(Plan, Features);
  ASSERT_TRUE(Result.isValid());
  EXPECT_GE(Result, 0);
  EXPECT_EQ(Result, Expected);
}

TEST_F(VPlanRAResourceCost, MaskedMemoryGrouping) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  // One unit-stride transfer: baseline G plus triangular predicate wait.
  const int64_t Groups[] = {8, 16, 32, 64};
  const InstructionCost Expected[] = {
      1, 2, InstructionCost(19) / 4, InstructionCost(23) / 2};
  for (unsigned I = 0; I != 4; ++I) {
    R["unit8"] = Groups[I];
    R["masked8"] = Groups[I];
    R["operations"] =
        json::Array{operation("unit", true, Groups[I], Groups[I])};
    EXPECT_EQ(cost(Plan, Features), Expected[I]);
    EXPECT_EQ(cost(Plan, Features, ElementCount::getFixed(4)), Expected[I]);
    EXPECT_EQ(cost(Plan, Features, ElementCount::getScalable(16)), Expected[I]);
  }
}

TEST_F(VPlanRAResourceCost, MaskedAccessWorkAndSEW) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["integer8"] = 512;
  // Equal grouping, but the existing per-lane observation reflects SEW.
  // The same predicate term applies to strided and indexed memory.
  for (StringRef Kind : {"strided", "indexed"}) {
    R["strided8"] = Kind == "strided" ? 128 : 0;
    R["indexed8"] = Kind == "indexed" ? 128 : 0;
    R["masked8"] = 128;
    R["operations"] = json::Array{operation(Kind, true, 32, 128, 32)};
    EXPECT_EQ(cost(Plan, Features), 64); // Arithmetic hides memory service.
    R["integer8"] = 0;
    EXPECT_EQ(cost(Plan, Features), Kind == "strided" ? 33 : 27);
    R["integer8"] = 512;
    R["strided8"] = Kind == "strided" ? 64 : 0;
    R["indexed8"] = Kind == "indexed" ? 64 : 0;
    R["masked8"] = 64;
    R["operations"] = json::Array{operation(Kind, true, 32, 64, 64)};
    EXPECT_EQ(cost(Plan, Features), 64);
    R["integer8"] = 0;
    EXPECT_EQ(cost(Plan, Features),
              InstructionCost(Kind == "strided" ? 33 : 27) / 2);
    R["integer8"] = 512;
  }
}

TEST_F(VPlanRAResourceCost, ArithmeticDominatedMaskedMemoryAndSpills) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 64;
  R["masked8"] = 64;
  R["fp8"] = 128;
  R["spill8"] = 32;
  R["scalar8"] = 24;
  R["config8"] = 8;
  EXPECT_EQ(cost(Plan, Features), 35);
  R["operations"] = json::Array{operation("unit", true, 64, 64)};
  // Arithmetic hides the 3.5-unit predicate service; spills stay additive.
  EXPECT_EQ(cost(Plan, Features), 35);
  R["spill8"] = 64;
  EXPECT_EQ(cost(Plan, Features), 37);
}

TEST_F(VPlanRAResourceCost, MaskedServiceHiddenByArithmetic) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 64;
  R["masked8"] = 64;
  R["fp8"] = 128;
  R["spill8"] = 32;
  R["scalar8"] = 24;
  R["config8"] = 8;
  R["operations"] = json::Array{operation("unit", true, 64, 64),
                                 operation("copy", false, 64, 64, 0)};
  // max(memory 8 + service 3.5, arithmetic 32, copy 4, scalar 1.5)
  // + spill 2 + config 1 = 35.
  // Charging service after the maximum would give 38.5.
  EXPECT_EQ(cost(Plan, Features), 35);
  EXPECT_EQ(cost(Plan, Features, ElementCount::getFixed(4)), 35);
  EXPECT_EQ(cost(Plan, Features, ElementCount::getScalable(16)), 35);
}

TEST_F(VPlanRAResourceCost, MaskedServiceMemoryDominanceUnchanged) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 64;
  R["masked8"] = 64;
  R["fp8"] = 16;
  R["spill8"] = 32;
  R["scalar8"] = 24;
  R["config8"] = 8;
  R["operations"] = json::Array{operation("unit", true, 64, 64),
                                 operation("copy", false, 64, 64, 0)};
  // Memory=8 already dominates arithmetic=4 and copy=4. Scalar=1.5 is hidden;
  // 8 + 3.5 + spill 2 + config 1 = 14.5.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(29) / 2);
  R["spill8"] = 64;
  EXPECT_EQ(cost(Plan, Features), InstructionCost(33) / 2);
}

TEST_F(VPlanRAResourceCost, MaskedServicePartialOverlap) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 64;
  R["masked8"] = 64;
  R["integer8"] = 80;
  R["operations"] = json::Array{operation("unit", true, 64, 64)};
  // Arithmetic=10 hides 2 of the 3.5 service units on memory=8.
  // Result is 11.5, rather than the previous 13.5 or full hiding at 10.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(23) / 2);
  R["operations"] = json::Array{operation("unit", true, 64, 64),
                                 operation("copy", false, 64, 64, 0),
                                 operation("copy", false, 64, 64, 0),
                                 operation("copy", false, 32, 32, 0)};
  // Copy=10 can also hide 2 service units, with arithmetic absent.
  R["integer8"] = 0;
  EXPECT_EQ(cost(Plan, Features), InstructionCost(23) / 2);
  R["operations"] = json::Array{operation("unit", true, 64, 64),
                                 operation("copy", false, 64, 64, 0),
                                 operation("copy", false, 64, 64, 0),
                                 operation("copy", false, 64, 64, 0),
                                 operation("copy", false, 64, 64, 0)};
  EXPECT_EQ(cost(Plan, Features), 16); // Copy hides the complete service.
}

TEST_F(VPlanRAResourceCost, ZeroMaskedServicePreservesResourceMaximum) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 64;
  R["masked8"] = 64;
  R["integer8"] = 80;
  EXPECT_EQ(cost(Plan, Features), 10); // Aggregate-only observations.
  R["operations"] = json::Array{};
  EXPECT_EQ(cost(Plan, Features), 10);
  for (int64_t Group : {1, 2, 4, 8}) {
    R["operations"] = json::Array{operation("unit", true, Group, 64)};
    EXPECT_EQ(cost(Plan, Features), 10); // No inter-chunk service.
  }
  R["operations"] = json::Array{operation("unit", false, 64, 64),
                                 operation("unit", true, 64, 0),
                                 operation("fp", true, 64, 64)};
  EXPECT_EQ(cost(Plan, Features), 10); // Unmasked/zero work/arithmetic.
  R["operations"] = json::Array{operation("unit", false, 64, 64),
                                 operation("copy", false, 64, 256, 0)};
  EXPECT_EQ(cost(Plan, Features), 16);
}

TEST_F(VPlanRAResourceCost, MaskedServiceFractionalAccumulation) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 48;
  R["masked8"] = 48;
  // Each M2 operation contributes 1/8 service unit. Accumulate before
  // the maximum and final quarter-unit rounding, with scalar work hidden.
  const InstructionCost Expected[] = {6, InstructionCost(25) / 4,
                                     InstructionCost(25) / 4};
  const InstructionCost WithScalar[] = {6, InstructionCost(25) / 4,
                                      InstructionCost(25) / 4};
  json::Array Operations;
  for (unsigned I = 0; I != 3; ++I) {
    Operations.push_back(operation("unit", true, 16, 16));
    R["operations"] = json::Array(Operations);
    R["scalar8"] = 0;
    EXPECT_EQ(cost(Plan, Features), Expected[I]);
    R["scalar8"] = 2;
    EXPECT_EQ(cost(Plan, Features), WithScalar[I]);
  }
  R["integer8"] = 50; // Arithmetic=6.25, memory+service=6.375.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(25) / 4);
  R["integer8"] = 52; // Arithmetic=6.5 now hides all service.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(13) / 2);
}

TEST_F(VPlanRAResourceCost, MaskedServiceOverlapSaturation) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  const int64_t Max = std::numeric_limits<int64_t>::max();
  R["operations"] = json::Array{operation("unit", true, 64, Max),
                                 operation("unit", true, 64, Max)};
  // Masked accumulation saturates independently before dividing by 64.
  constexpr int64_t Quarters = std::numeric_limits<int64_t>::max() / 64 / 16;
  InstructionCost Expected = InstructionCost(Quarters / 4) +
                             InstructionCost(Quarters % 4) / 4;
  InstructionCost Result = cost(Plan, Features);
  ASSERT_TRUE(Result.isValid());
  EXPECT_GE(Result, 0);
  EXPECT_EQ(Result, Expected);
  // Adding that service to already saturated memory must remain valid.
  R["unit8"] = Max;
  Expected = InstructionCost::getMax();
  Expected /= 16;
  Result = cost(Plan, Features);
  ASSERT_TRUE(Result.isValid());
  EXPECT_EQ(Result, Expected);
  R["unit8"] = 0;
  R["fp8"] = Max; // Saturated arithmetic hides the service.
  Result = cost(Plan, Features);
  ASSERT_TRUE(Result.isValid());
  EXPECT_EQ(Result, Expected);
  R["spill8"] = Max;
  R["scalar8"] = Max;
  R["config8"] = Max;
  Result = cost(Plan, Features);
  ASSERT_TRUE(Result.isValid());
  EXPECT_EQ(Result, Expected);
}

TEST_F(VPlanRAResourceCost, FractionalMaskedGroups) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 8;
  R["masked8"] = 8;
  // MF8/MF4/MF2 use one issue slot, with no inter-register wait.
  for (int64_t Group : {1, 2, 4, 8}) {
    R["operations"] = json::Array{operation("unit", true, Group, 8)};
    EXPECT_EQ(cost(Plan, Features), 1);
  }
  R["unit8"] = 48;
  R["masked8"] = 48;
  R["operations"] = json::Array{operation("unit", true, 16, 16),
                                 operation("unit", true, 16, 16),
                                 operation("unit", true, 16, 16)};
  // Three sub-quarter waits accumulate before final quarter-unit rounding.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(25) / 4);
}

TEST_F(VPlanRAResourceCost, ExtremeMaskedMemoryDemand) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  const int64_t Max = std::numeric_limits<int64_t>::max();
  R["operations"] = json::Array{operation("unit", true, 64, Max),
                                 operation("strided", true, 64, Max),
                                 operation("indexed", true, 64, Max)};
  InstructionCost ServiceAndSerial = cost(Plan, Features);
  ASSERT_TRUE(ServiceAndSerial.isValid());
  EXPECT_GT(ServiceAndSerial, 0);
  // Each accumulator independently saturates. The strided service divides
  // by 32, predicate serialization by 64, then their sum divides by 16.
  constexpr int64_t MaxQuarters = std::numeric_limits<int64_t>::max();
  constexpr int64_t ExpectedQuarters =
      (MaxQuarters / 32 + MaxQuarters / 64) / 16;
  InstructionCost Expected = InstructionCost(ExpectedQuarters / 4) +
                             InstructionCost(ExpectedQuarters % 4) / 4;
  EXPECT_EQ(ServiceAndSerial, Expected);
  R["fp8"] = Max;
  R["spill8"] = Max;
  InstructionCost All = cost(Plan, Features);
  ASSERT_TRUE(All.isValid());
  EXPECT_GE(All, ServiceAndSerial);
  Expected = InstructionCost::getMax();
  Expected /= 16;
  EXPECT_EQ(All, Expected);
}

TEST_F(VPlanRAResourceCost, PartialSharingRepeatedDistinctAndUnknown) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 192;
  R["masked8"] = 192;
  R["operations"] = json::Array{predicateOperation("unit", 64, 64, 1),
                                 predicateOperation("unit", 64, 64, 1),
                                 predicateOperation("unit", 64, 64, 1)};
  // Ordinary memory=24. Each M8 delay=3.5: three residuals of 2.625
  // plus shared max=0.875 gives 8.75, hence memory demand=32.75.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(131) / 4);
  R["operations"] = json::Array{predicateOperation("unit", 64, 64, 1),
                                 predicateOperation("unit", 64, 64, 2),
                                 predicateOperation("unit", 64, 64, 3)};
  EXPECT_EQ(cost(Plan, Features), InstructionCost(69) / 2);
  R["operations"] = json::Array{predicateOperation("unit", 64, 64, 1),
                                 predicateOperation("unit", 64, 64, 2),
                                 predicateOperation("unit", 64, 64, 1)};
  EXPECT_EQ(cost(Plan, Features), InstructionCost(67) / 2);
  // Zero and absent IDs do not prove equality, even on identical accesses.
  R["operations"] = json::Array{predicateOperation("unit", 64, 64, 0),
                                 predicateOperation("unit", 64, 64, 0),
                                 operation("unit", true, 64, 64)};
  EXPECT_EQ(cost(Plan, Features), InstructionCost(69) / 2);
}

TEST_F(VPlanRAResourceCost, PartialSharingUnequalGroupingAndAccessKinds) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 112;
  R["masked8"] = 112;
  const int64_t Groups[] = {16, 32, 64};
  for (bool Reverse : {false, true}) {
    json::Array Ops;
    for (unsigned I = 0; I != 3; ++I) {
      int64_t G = Groups[Reverse ? 2 - I : I];
      Ops.push_back(predicateOperation("unit", G, G, 9));
    }
    R["operations"] = std::move(Ops);
    // 14 + 3/4*(1/8 + 3/4 + 7/2) + 1/4*(7/2) = 18.15625.
    // Final quarter-unit truncation gives 18, independent of access order.
    EXPECT_EQ(cost(Plan, Features), 18);
    EXPECT_EQ(cost(Plan, Features, ElementCount::getScalable(16)), 18);
  }
  R["unit8"] = 16;
  R["strided8"] = 128;
  R["indexed8"] = 128;
  R["masked8"] = 272;
  R["operations"] = json::Array{predicateOperation("unit", 16, 16, 9),
                                 predicateOperation("strided", 32, 128, 9),
                                 predicateOperation("indexed", 32, 128, 9)};
  // Ordinary memory=50, strided service=6, masked service=5.34375.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(245) / 4);
  R["fp8"] = 256; // Arithmetic=64 hides all memory service.
  R["spill8"] = 32;
  EXPECT_EQ(cost(Plan, Features), 66); // Spills add 2 regardless of overlap.
}

TEST_F(VPlanRAResourceCost, PartialSharingMixedKnownAndUnknown) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 160;
  R["masked8"] = 160;
  const int64_t Groups[] = {16, 64, 64, 16};
  const int64_t Predicates[] = {1, 1, 0, 2};
  for (bool Reverse : {false, true}) {
    json::Array Ops;
    for (unsigned I = 0; I != 4; ++I) {
      unsigned J = Reverse ? 3 - I : I;
      Ops.push_back(predicateOperation("unit", Groups[J], Groups[J],
                                       Predicates[J]));
    }
    R["operations"] = std::move(Ops);
    // 20 ordinary memory + 3/4*(.125+3.5) + .875 + 3.5 + .125
    // = 27.21875, including the full unknown access, truncates to 27.
    EXPECT_EQ(cost(Plan, Features), 27);
  }
}

TEST_F(VPlanRAResourceCost, PartialSharingArithmeticOverlapAndMemoryDominance) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 192;
  R["masked8"] = 192;
  R["spill8"] = 32;
  R["scalar8"] = 24;
  R["config8"] = 8;
  R["operations"] = json::Array{predicateOperation("unit", 64, 64, 1),
                                 predicateOperation("unit", 64, 64, 1),
                                 predicateOperation("unit", 64, 64, 1),
                                 operation("copy", false, 64, 64, 0)};
  // max(memory 24+8.75, arithmetic 40, copy 4, scalar 1.5) + 3 = 43.
  // Keeping masked service additive would give 51.75.
  R["integer8"] = 320;
  EXPECT_EQ(cost(Plan, Features), 43);
  // Partial arithmetic overlap: memory service overtakes arithmetic=32.
  R["integer8"] = 256;
  EXPECT_EQ(cost(Plan, Features), InstructionCost(143) / 4);
  // Memory dominance preserves ordinary demand and the entire shared split.
  R["integer8"] = 32;
  EXPECT_EQ(cost(Plan, Features), InstructionCost(143) / 4);
  R["spill8"] = 64;
  EXPECT_EQ(cost(Plan, Features), InstructionCost(151) / 4);
  // Copy demand can also hide service, with arithmetic absent.
  R["integer8"] = 0;
  R["operations"].getAsArray()->push_back(operation("copy", false, 64, 640, 0));
  EXPECT_EQ(cost(Plan, Features), 49); // 44 + 5.
}

TEST_F(VPlanRAResourceCost, PartialSharingZeroDemandAndFractionalAccumulation) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 48;
  R["masked8"] = 48;
  R["operations"] = json::Array{predicateOperation("unit", 16, 16, 1),
                                 predicateOperation("unit", 16, 16, 1),
                                 predicateOperation("unit", 16, 16, 1)};
  // 6 + 3*.09375 + .03125 = 6.3125, truncates once to 6.25.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(25) / 4);
  R["scalar8"] = 2;
  EXPECT_EQ(cost(Plan, Features), InstructionCost(25) / 4);
  R["scalar8"] = 0;
  for (int64_t Group : {1, 2, 4, 8}) {
    R["operations"] = json::Array{predicateOperation("unit", Group, 16, 1),
                                   predicateOperation("unit", Group, 16, 1)};
    EXPECT_EQ(cost(Plan, Features), 6);
  }
  R["operations"] = json::Array{predicateOperation("unit", 64, 0, 1),
                                 operation("unit", false, 64, 64),
                                 predicateOperation("fp", 64, 64, 1)};
  EXPECT_EQ(cost(Plan, Features), 6); // Zero work/unmasked/arithmetic.
  R["operations"] = json::Array{};
  EXPECT_EQ(cost(Plan, Features), 6);
  R.erase("operations");
  EXPECT_EQ(cost(Plan, Features), 6); // Aggregate-only fallback unchanged.
}

TEST_F(VPlanRAResourceCost, PartialSharingSingletonEquivalence) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  for (StringRef Kind : {"unit", "strided", "indexed"})
    for (int64_t Group : {1, 2, 4, 8, 16, 32, 64})
      for (int64_t Work : {int64_t(0), int64_t(1), int64_t(8), int64_t(16),
                           int64_t(128), std::numeric_limits<int64_t>::max()}) {
        R["operations"] = json::Array{operation(Kind, true, Group, Work)};
        InstructionCost Independent = cost(Plan, Features);
        R["operations"] =
            json::Array{predicateOperation(Kind, Group, Work, 7)};
        EXPECT_EQ(cost(Plan, Features), Independent);
      }
}

TEST_F(VPlanRAResourceCost, PartialSharingAccumulatorLimitsAndSaturation) {
  // Independently known limiting values in accumulation units. This helper
  // test does not provide a feedback-controlled coefficient; production is 4.
  for (unsigned Divisor : {0, 1, 4}) {
    detail::VPlanRAPredicateCost Delay(Divisor);
    Delay.add(64, 1);
    EXPECT_EQ(Delay.getCost(), 64);
    Delay.add(64, 1);
    Delay.add(64, 1);
    EXPECT_EQ(Delay.getCost(), Divisor == 0 ? 192 : Divisor == 1 ? 64 : 160);
    detail::VPlanRAPredicateCost Unknown(Divisor), Distinct(Divisor);
    for (int64_t I = 1; I <= 3; ++I) {
      Unknown.add(64, 0);
      Distinct.add(64, I);
    }
    EXPECT_EQ(Unknown.getCost(), 192);
    EXPECT_EQ(Distinct.getCost(), 192);
    detail::VPlanRAPredicateCost Saturated(Divisor);
    InstructionCost Max = InstructionCost::getMax();
    Saturated.add(Max, 1);
    EXPECT_EQ(Saturated.getCost(), Max);
    Saturated.add(Max, 1);
    Saturated.add(Max, 2);
    Saturated.add(Max, 0);
    ASSERT_TRUE(Saturated.getCost().isValid());
    EXPECT_GE(Saturated.getCost(), 0);
    EXPECT_EQ(Saturated.getCost(), Max);
  }
  detail::VPlanRAPredicateCost Rounded(4);
  Rounded.add(InstructionCost(1) / 4, 1);
  Rounded.add(0, 1);
  EXPECT_EQ(Rounded.getCost(), InstructionCost(1) / 4);
}

TEST_F(VPlanRAResourceCost, PartialSharingSaturatedNonnegativeBody) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  int64_t Max = std::numeric_limits<int64_t>::max();
  R["operations"] = json::Array{predicateOperation("unit", 64, Max, 1),
                                 predicateOperation("unit", 64, Max, 1),
                                 predicateOperation("unit", 32, Max, 1)};
  // Internal quarter counts saturate at INT64_MAX before /64 and /16.
  constexpr int64_t Quarters = std::numeric_limits<int64_t>::max() / 64 / 16;
  InstructionCost Expected = InstructionCost(Quarters / 4) +
                             InstructionCost(Quarters % 4) / 4;
  InstructionCost Result = cost(Plan, Features);
  ASSERT_TRUE(Result.isValid());
  EXPECT_GE(Result, 0);
  EXPECT_EQ(Result, Expected);
  R["operations"] = json::Array{predicateOperation("unit", 64, Max, 1),
                                 predicateOperation("unit", 64, Max, Max)};
  EXPECT_EQ(cost(Plan, Features), Expected);
  R["unit8"] = Max;
  R["masked8"] = Max;
  R["spill8"] = Max;
  R["scalar8"] = Max;
  R["config8"] = Max;
  constexpr int64_t BodyQuarters = std::numeric_limits<int64_t>::max() / 16;
  Expected = InstructionCost(BodyQuarters / 4) +
             InstructionCost(BodyQuarters % 4) / 4;
  Result = cost(Plan, Features);
  ASSERT_TRUE(Result.isValid());
  EXPECT_GE(Result, 0);
  EXPECT_EQ(Result, Expected);
}

TEST_F(VPlanRAResourceCost, PartialSharingMalformedPredicateFallback) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  for (int64_t Group : {4, 16, 64})
    for (json::Value ID : {json::Value(-1), json::Value("1"),
                          json::Value(true), json::Value(1.5)}) {
      auto Op = operation("unit", true, Group, 16);
      Op["predicate_id"] = std::move(ID);
      R["operations"] = json::Array{std::move(Op)};
      EXPECT_EQ(cost(Plan, Features), 100);
      EXPECT_EQ(cost(Plan, Features, ElementCount::getFixed(1), 7), 7);
      R["supported"] = false;
      EXPECT_EQ(cost(Plan, Features), 100);
      R["supported"] = true;
    }
}

TEST_F(VPlanRAResourceCost, MalformedMaskedOperations) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 16;
  R["masked8"] = 16;
  R["operations"] = "not an array";
  EXPECT_EQ(cost(Plan, Features), 100);
  R["operations"] = json::Array{0};
  EXPECT_EQ(cost(Plan, Features), 100);
  for (int64_t Group : {-1, 0, 3, 128}) {
    R["operations"] = json::Array{operation("unit", true, Group, 16)};
    EXPECT_EQ(cost(Plan, Features), 100);
  }
  R["operations"] = json::Array{operation("unit", true, 16, -1)};
  EXPECT_EQ(cost(Plan, Features), 100);
  auto MissingWork = operation("unit", true, 16, 16);
  MissingWork.erase("work8");
  R["operations"] = json::Array{std::move(MissingWork)};
  EXPECT_EQ(cost(Plan, Features), 100);
  auto WrongMask = operation("unit", true, 16, 16);
  WrongMask["masked"] = "true";
  R["operations"] = json::Array{std::move(WrongMask)};
  EXPECT_EQ(cost(Plan, Features), 100);
  // A scalar reference still bypasses resource modeling entirely.
  EXPECT_EQ(cost(Plan, Features, ElementCount::getFixed(1), 7), 7);
}

TEST_F(VPlanRAResourceCost, UnusedConfigurationScalarResource) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["integer8"] = 80; // Arithmetic=10.
  R["scalar8"] = 32;  // Scalar=2.
  R["config8"] = 24;
  R["config_unused8"] = 24; // Unused configuration=3, same coefficient.
  R["config_additive8"] = 0;
  EXPECT_EQ(cost(Plan, Features), 10);
  R["scalar8"] = 144; // Scalar plus configuration=9+3=12.
  EXPECT_EQ(cost(Plan, Features), 12);
  R["unit8"] = 320; // Memory=20 overlaps the same scalar service.
  EXPECT_EQ(cost(Plan, Features), 20);
  R["spill8"] = 32; // Spills still add two.
  EXPECT_EQ(cost(Plan, Features), 22);
}

TEST_F(VPlanRAResourceCost, MixedConfigurationResults) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["integer8"] = 80;
  R["scalar8"] = 144;
  R["config8"] = 32;
  R["config_unused8"] = 16;
  R["config_additive8"] = 16; // Live/uncertain results still add two.
  EXPECT_EQ(cost(Plan, Features), 13); // max(10,9+2)+2.
  R["config_unused8"] = 0;
  R["config_additive8"] = 32;
  EXPECT_EQ(cost(Plan, Features), 14); // Unchanged live AVL service.
  R["config_unused8"] = 32;
  R["config_additive8"] = 0;
  EXPECT_EQ(cost(Plan, Features), 13); // All configurations share scalar.
}

TEST_F(VPlanRAResourceCost, ConfigurationOverlapRetainsResourceBounds) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["scalar8"] = 32;
  R["config8"] = 24;
  R["config_unused8"] = 16;
  R["config_additive8"] = 8;
  R["recurrences"] = json::Array{recurrence(4, 0, 0)};
  EXPECT_EQ(cost(Plan, Features), 13); // Recurrence=12, live config adds 1.
  R["operations"] = json::Array{operation("copy", false, 32, 256)};
  EXPECT_EQ(cost(Plan, Features), 17); // Movement=16 still overlaps.
  R["operations"] = json::Array{division("vf", false, 8, 8, 32)};
  EXPECT_EQ(cost(Plan, Features), 26); // Divider=25 still overlaps.
  R["spill8"] = 32;
  EXPECT_EQ(cost(Plan, Features), 28); // Spills retain additive service.
}

TEST_F(VPlanRAResourceCost, ConfigurationClassificationFallback) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["integer8"] = 80;
  R["config8"] = 16;
  EXPECT_EQ(cost(Plan, Features), 12); // Old observations stay additive.
  R["config_unused8"] = 16;
  EXPECT_EQ(cost(Plan, Features), 12); // Partial extension stays additive.
  R.erase("config_unused8");
  R["config_additive8"] = 0;
  EXPECT_EQ(cost(Plan, Features), 12);
  for (json::Value Bad : {json::Value(-1), json::Value(17),
                          json::Value("16"), json::Value(true),
                          json::Value(1.5), json::Value(nullptr),
                          json::Value(std::numeric_limits<int64_t>::max())}) {
    R["config_unused8"] = std::move(Bad);
    EXPECT_EQ(cost(Plan, Features), 12);
  }
  R["config_unused8"] = 16;
  for (json::Value Bad : {json::Value(-1), json::Value(8),
                          json::Value("0"), json::Value(true),
                          json::Value(0.5), json::Value(nullptr),
                          json::Value(std::numeric_limits<int64_t>::max())}) {
    R["config_additive8"] = std::move(Bad);
    EXPECT_EQ(cost(Plan, Features), 12);
  }
  R["config_additive8"] = 0;
  EXPECT_EQ(cost(Plan, Features), 10);
  EXPECT_EQ(cost(Plan, Features, ElementCount::getFixed(4)), 10);
  EXPECT_EQ(cost(Plan, Features, ElementCount::getFixed(1), 7), 7);
  R["supported"] = false;
  EXPECT_EQ(cost(Plan, Features), 100);
  R["supported"] = true;
  R["version"] = 2;
  EXPECT_EQ(cost(Plan, Features), 100);
}

TEST_F(VPlanRAResourceCost, FractionalConfigurationOverlap) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["integer8"] = 1;
  R["scalar8"] = 1;
  R["spill8"] = 1;
  R["config8"] = 2;
  R["config_unused8"] = 1;
  R["config_additive8"] = 1;
  // max(2,1+2)+1+2 = 6 sixteenth units; retain fractions until division.
  EXPECT_EQ(cost(Plan, Features), InstructionCost(1) / 4);
  R["config_unused8"] = 2;
  R["config_additive8"] = 0;
  EXPECT_EQ(cost(Plan, Features), InstructionCost(1) / 4);
  R["scalar8"] = 5;
  EXPECT_EQ(cost(Plan, Features), InstructionCost(1) / 2);
}

TEST_F(VPlanRAResourceCost, SaturatingConfigurationOverlap) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  constexpr int64_t Max = std::numeric_limits<int64_t>::max();
  constexpr int64_t ExpectedQuarters = Max / 16;
  const InstructionCost Expected = InstructionCost(ExpectedQuarters / 4) +
                                   InstructionCost(ExpectedQuarters % 4) / 4;
  R["config8"] = Max;
  for (int64_t Unused : {int64_t(0), Max / 2, Max}) {
    R["config_unused8"] = Unused;
    R["config_additive8"] = Max - Unused;
    InstructionCost Body = cost(Plan, Features);
    EXPECT_TRUE(Body.isValid());
    EXPECT_GE(Body, 0);
    EXPECT_EQ(Body, Expected);
  }
  // Validate the raw partition before InstructionCost saturation can hide
  // inconsistent totals. A saturated all-unused value must not hide this.
  R["config_unused8"] = Max;
  R["config_additive8"] = Max;
  EXPECT_EQ(cost(Plan, Features), Expected);
  R["config_additive8"] = 0;
  R["scalar8"] = Max;
  R["fused8"] = Max;
  R["spill8"] = Max;
  EXPECT_EQ(cost(Plan, Features), Expected);
  // Equal resources below saturation must overlap; scalar and unused service
  // still sum, and live configuration retains its original coefficient.
  R["integer8"] = 800;
  R["fused8"] = 0;
  R["scalar8"] = 800;
  R["spill8"] = 0;
  R["config8"] = 408;
  R["config_unused8"] = 400;
  R["config_additive8"] = 8;
  EXPECT_EQ(cost(Plan, Features), 101);
}

TEST_F(VPlanRAResourceCost, ArithmeticDominatedSpills) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 192;
  R["spill8"] = 256;
  R["fused8"] = 128;
  R["scalar8"] = 64;
  R["config8"] = 16;
  // Memory plus spills fits below arithmetic, but spills still add 16.
  EXPECT_EQ(cost(Plan, Features), 50);
  R["spill8"] = 512;
  EXPECT_EQ(cost(Plan, Features), 66);
}

TEST_F(VPlanRAResourceCost, MemoryDominatedSpills) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 160;
  R["integer8"] = 16;
  R["scalar8"] = 24;
  R["config8"] = 8;
  R["spill8"] = 32;
  // Memory dominates; spills keep their existing weight and are added once.
  EXPECT_EQ(cost(Plan, Features), 13);
  R["spill8"] = 64;
  EXPECT_EQ(cost(Plan, Features), 15);
}

TEST_F(VPlanRAResourceCost, ZeroSpillDemand) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 64;
  R["integer8"] = 48;
  R["scalar8"] = 24;
  R["config8"] = 8;
  EXPECT_EQ(cost(Plan, Features), 7);
  R["unit8"] = 160;
  EXPECT_EQ(cost(Plan, Features), 11);
}

TEST_F(VPlanRAResourceCost, FractionalSpillAccumulation) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["unit8"] = 1;
  R["integer8"] = 1;
  R["spill8"] = 1;
  R["scalar8"] = 1;
  // Arithmetic=1/8 hides scalar=1/16; add spills before rounding.
  EXPECT_EQ(cost(Plan, Features), 0); // 3/16.
  R["spill8"] = 3;
  EXPECT_EQ(cost(Plan, Features), InstructionCost(1) / 4);
  R["spill8"] = 5;
  EXPECT_EQ(cost(Plan, Features), InstructionCost(1) / 4);
  // Memory dominance also retains fractional spill demand until the final sum.
  R["integer8"] = 0;
  R["masked8"] = 1;
  R["spill8"] = 1;
  EXPECT_EQ(cost(Plan, Features), 0); // 3/16.
}

TEST_F(VPlanRAResourceCost, ExtremeSpillDemand) {
  VPlan &Plan = getPlan();
  auto Features = features();
  auto &R = resources(Features);
  R["spill8"] = std::numeric_limits<int64_t>::max();

  // Construction saturates the internal quarter-unit count at INT64_MAX.
  // Body /= 16 divides that integer directly. Binary InstructionCost division
  // would first multiply the numerator by four and saturate again, so derive
  // the oracle in integers and construct its whole and fractional parts.
  constexpr int64_t ExpectedQuarters = std::numeric_limits<int64_t>::max() / 16;
  const InstructionCost Expected = InstructionCost(ExpectedQuarters / 4) +
                                   InstructionCost(ExpectedQuarters % 4) / 4;
  InstructionCost SpillOnly = cost(Plan, Features);
  ASSERT_TRUE(SpillOnly.isValid());
  EXPECT_GE(SpillOnly, 0);
  EXPECT_EQ(SpillOnly, Expected);

  R["fused8"] = std::numeric_limits<int64_t>::max();
  InstructionCost SpillAndArithmetic = cost(Plan, Features);
  ASSERT_TRUE(SpillAndArithmetic.isValid());
  EXPECT_GE(SpillAndArithmetic, 0);
  EXPECT_EQ(SpillAndArithmetic, Expected);
}

TEST_F(VPlanRAResourceCost, GatherSplitOrdering) {
  VPlan &Plan = getPlan();
  auto Small = features();
  auto &S = resources(Small);
  S["unit8"] = 32;
  S["indexed8"] = 128;
  S["integer8"] = 176;
  S["scalar8"] = 48;
  S["config8"] = 8;
  auto Large = features();
  auto &L = resources(Large);
  L["unit8"] = 64;
  L["indexed8"] = 256;
  L["integer8"] = 352;
  L["scalar8"] = 72;
  L["config8"] = 32;
  EXPECT_EQ(cost(Plan, Small), 23);
  EXPECT_EQ(cost(Plan, Large), 48);
  // The extra configurations overcome width normalization.
  EXPECT_GT(cost(Plan, Large) * 128, cost(Plan, Small) * 256);
}

TEST_F(VPlanRAResourceCost, LinearWidthPreference) {
  VPlan &Plan = getPlan();
  auto Small = features();
  resources(Small)["unit8"] = 64;
  resources(Small)["integer8"] = 32;
  resources(Small)["scalar8"] = 48;
  resources(Small)["config8"] = 8;
  auto Large = features();
  resources(Large)["unit8"] = 128;
  resources(Large)["integer8"] = 64;
  resources(Large)["scalar8"] = 48;
  resources(Large)["config8"] = 8;
  EXPECT_EQ(cost(Plan, Small), 5);
  EXPECT_EQ(cost(Plan, Large), 9);
  EXPECT_LT(cost(Plan, Large), cost(Plan, Small) * 2);
}

TEST_F(VPlanRAResourceCost, FallbackScalarAndNonnegative) {
  ASSERT_NE(ScalarHeader->getTerminator(), nullptr);
  ASSERT_EQ(ScalarHeader->getParent(), F);
  ASSERT_EQ(F->getParent(), M.get());
  ASSERT_NE(&F->getEntryBlock(), ScalarHeader);
  ASSERT_FALSE(verifyFunction(*F));
  VPlan &Plan = getPlan();
  auto Features = features();
  resources(Features)["integer8"] = 80;
  EXPECT_EQ(cost(Plan, Features, ElementCount::getFixed(1), 7), 7);
  EXPECT_EQ(cost(Plan, Features, ElementCount::getFixed(4), 999), 10);
  EXPECT_EQ(cost(Plan, Features, ElementCount::getScalable(4), 999), 10);
  EXPECT_EQ(cost(Plan, json::Object{}), 100);
  resources(Features)["supported"] = false;
  EXPECT_EQ(cost(Plan, Features), 100);
  resources(Features)["supported"] = true;
  resources(Features)["integer8"] = 0;
  EXPECT_EQ(cost(Plan, Features), 0);
  for (StringRef Key : {"unit8", "spill8", "strided8", "indexed8", "masked8",
                        "integer8", "fp8", "fused8", "scalar8", "config8"})
    resources(Features)[Key] = std::numeric_limits<int64_t>::max();
  InstructionCost Saturated = cost(Plan, Features);
  EXPECT_TRUE(Saturated.isValid());
  EXPECT_GT(Saturated, 0);
  InstructionCost Expected = InstructionCost::getMax();
  Expected /= 16;
  EXPECT_EQ(Saturated, Expected);
}

TEST_F(VPlanRAResourceCost, MalformedObservations) {
  VPlan &Plan = getPlan();
  auto Missing = features();
  resources(Missing).erase("indexed8");
  EXPECT_EQ(cost(Plan, Missing), 100);
  auto Negative = features();
  resources(Negative)["fp8"] = -1;
  EXPECT_EQ(cost(Plan, Negative), 100);
  auto WrongType = features();
  resources(WrongType)["unit8"] = "8";
  EXPECT_EQ(cost(Plan, WrongType), 100);
  auto WrongVersion = features();
  resources(WrongVersion)["version"] = 2;
  EXPECT_EQ(cost(Plan, WrongVersion), 100);
}

TEST_F(VPlanSCEVTest, GetSCEVExprForVPValueAbs) {
  const char *ModuleString = R"(
define void @f(i32 %x) {
entry:
  br label %loop
loop:
  br label %loop
}
)";

  Module &M = parseModule(ModuleString);
  Function *F = M.getFunction("f");
  BasicBlock *LoopHeader = F->getEntryBlock().getSingleSuccessor();
  doAnalysis(*F);

  Loop *L = LI->getLoopFor(LoopHeader);
  PredicatedScalarEvolution PSE(*SE, *L);
  VPlan Plan(LoopHeader, IntegerType::get(*Ctx, 32));
  Argument *X = F->getArg(0);
  VPValue *Op = Plan.getOrAddLiveIn(X);

  // is_int_min_poison is local to the call, not a global no-wrap fact.
  // Exercise both getAbsExpr flag paths; SCEV drops IsNSW for this input.
  const SCEV *XSCEV = SE->getSCEV(X);

  VPWidenIntrinsicRecipe Abs(Intrinsic::abs, {Op, Plan.getTrue()},
                             X->getType());
  EXPECT_EQ(SE->getAbsExpr(XSCEV, /*IsNSW=*/true),
            vputils::getSCEVExprForVPValue(&Abs, PSE, L));

  VPWidenIntrinsicRecipe WrappingAbs(Intrinsic::abs, {Op, Plan.getFalse()},
                                     X->getType());
  EXPECT_EQ(SE->getAbsExpr(XSCEV, /*IsNSW=*/false),
            vputils::getSCEVExprForVPValue(&WrappingAbs, PSE, L));
}

TEST_F(VPInstructionTest, insertBefore) {
  IntegerType *Int32 = IntegerType::get(C, 32);
  VPInstruction *I1 =
      new VPInstructionWithType(VPInstruction::StepVector, {}, Int32);
  VPInstruction *I2 =
      new VPInstructionWithType(VPInstruction::StepVector, {}, Int32);
  VPInstruction *I3 =
      new VPInstructionWithType(VPInstruction::StepVector, {}, Int32);

  VPBasicBlock &VPBB1 = *getPlan().createVPBasicBlock("");
  VPBB1.appendRecipe(I1);

  I2->insertBefore(I1);
  CHECK_ITERATOR(VPBB1, I2, I1);

  I3->insertBefore(I2);
  CHECK_ITERATOR(VPBB1, I3, I2, I1);
}

TEST_F(VPInstructionTest, eraseFromParent) {
  IntegerType *Int32 = IntegerType::get(C, 32);
  VPInstruction *I1 =
      new VPInstructionWithType(VPInstruction::StepVector, {}, Int32);
  VPInstruction *I2 =
      new VPInstructionWithType(VPInstruction::StepVector, {}, Int32);
  VPInstruction *I3 =
      new VPInstructionWithType(VPInstruction::StepVector, {}, Int32);

  VPBasicBlock &VPBB1 = *getPlan().createVPBasicBlock("");
  VPBB1.appendRecipe(I1);
  VPBB1.appendRecipe(I2);
  VPBB1.appendRecipe(I3);

  I2->eraseFromParent();
  CHECK_ITERATOR(VPBB1, I1, I3);

  I1->eraseFromParent();
  CHECK_ITERATOR(VPBB1, I3);

  I3->eraseFromParent();
  EXPECT_TRUE(VPBB1.empty());
}

TEST_F(VPInstructionTest, moveAfter) {
  IntegerType *Int32 = IntegerType::get(C, 32);
  VPInstruction *I1 =
      new VPInstructionWithType(VPInstruction::StepVector, {}, Int32);
  VPInstruction *I2 =
      new VPInstructionWithType(VPInstruction::StepVector, {}, Int32);
  VPInstruction *I3 =
      new VPInstructionWithType(VPInstruction::StepVector, {}, Int32);

  VPBasicBlock &VPBB1 = *getPlan().createVPBasicBlock("");
  VPBB1.appendRecipe(I1);
  VPBB1.appendRecipe(I2);
  VPBB1.appendRecipe(I3);

  I1->moveAfter(I2);

  CHECK_ITERATOR(VPBB1, I2, I1, I3);

  VPInstruction *I4 =
      new VPInstructionWithType(VPInstruction::StepVector, {}, Int32);
  VPInstruction *I5 =
      new VPInstructionWithType(VPInstruction::StepVector, {}, Int32);
  VPBasicBlock &VPBB2 = *getPlan().createVPBasicBlock("");
  VPBB2.appendRecipe(I4);
  VPBB2.appendRecipe(I5);

  I3->moveAfter(I4);

  CHECK_ITERATOR(VPBB1, I2, I1);
  CHECK_ITERATOR(VPBB2, I4, I3, I5);
  EXPECT_EQ(I3->getParent(), I4->getParent());
}

TEST_F(VPInstructionTest, moveBefore) {
  IntegerType *Int32 = IntegerType::get(C, 32);
  VPInstruction *I1 =
      new VPInstructionWithType(VPInstruction::StepVector, {}, Int32);
  VPInstruction *I2 =
      new VPInstructionWithType(VPInstruction::StepVector, {}, Int32);
  VPInstruction *I3 =
      new VPInstructionWithType(VPInstruction::StepVector, {}, Int32);

  VPBasicBlock &VPBB1 = *getPlan().createVPBasicBlock("");
  VPBB1.appendRecipe(I1);
  VPBB1.appendRecipe(I2);
  VPBB1.appendRecipe(I3);

  I1->moveBefore(VPBB1, I3->getIterator());

  CHECK_ITERATOR(VPBB1, I2, I1, I3);

  VPInstruction *I4 =
      new VPInstructionWithType(VPInstruction::StepVector, {}, Int32);
  VPInstruction *I5 =
      new VPInstructionWithType(VPInstruction::StepVector, {}, Int32);
  VPBasicBlock &VPBB2 = *getPlan().createVPBasicBlock("");
  VPBB2.appendRecipe(I4);
  VPBB2.appendRecipe(I5);

  I3->moveBefore(VPBB2, I4->getIterator());

  CHECK_ITERATOR(VPBB1, I2, I1);
  CHECK_ITERATOR(VPBB2, I3, I4, I5);
  EXPECT_EQ(I3->getParent(), I4->getParent());

  VPBasicBlock &VPBB3 = *getPlan().createVPBasicBlock("");

  I4->moveBefore(VPBB3, VPBB3.end());

  CHECK_ITERATOR(VPBB1, I2, I1);
  CHECK_ITERATOR(VPBB2, I3, I5);
  CHECK_ITERATOR(VPBB3, I4);
  EXPECT_EQ(&VPBB3, I4->getParent());
}

TEST_F(VPInstructionTest, setOperand) {
  IntegerType *Int32 = IntegerType::get(C, 32);
  VPValue *VPV1 = getPlan().getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPValue *VPV2 = getPlan().getOrAddLiveIn(ConstantInt::get(Int32, 2));
  VPInstruction *I1 =
      new VPInstruction(Instruction::Add, {VPV1, VPV2},
                        VPIRFlags::getDefaultFlags(Instruction::Add));
  EXPECT_TRUE(VPV1->hasOneUse());
  EXPECT_EQ(I1, *VPV1->user_begin());
  EXPECT_TRUE(VPV2->hasOneUse());
  EXPECT_EQ(I1, *VPV2->user_begin());

  // Replace operand 0 (VPV1) with VPV3.
  VPValue *VPV3 = getPlan().getOrAddLiveIn(ConstantInt::get(Int32, 3));
  I1->setOperand(0, VPV3);
  EXPECT_TRUE(VPV1->user_empty());
  EXPECT_TRUE(VPV2->hasOneUse());
  EXPECT_EQ(I1, *VPV2->user_begin());
  EXPECT_TRUE(VPV3->hasOneUse());
  EXPECT_EQ(I1, *VPV3->user_begin());

  // Replace operand 1 (VPV2) with VPV3.
  I1->setOperand(1, VPV3);
  EXPECT_TRUE(VPV1->user_empty());
  EXPECT_TRUE(VPV2->user_empty());
  EXPECT_EQ(2u, VPV3->getNumUsers());
  EXPECT_EQ(I1, *VPV3->user_begin());
  EXPECT_EQ(I1, *std::next(VPV3->user_begin()));

  // Replace operand 0 (VPV3) with VPV4.
  VPValue *VPV4 = getPlan().getOrAddLiveIn(ConstantInt::get(Int32, 4));
  I1->setOperand(0, VPV4);
  EXPECT_TRUE(VPV3->hasOneUse());
  EXPECT_EQ(I1, *VPV3->user_begin());
  EXPECT_EQ(I1, *VPV4->user_begin());

  // Replace operand 1 (VPV3) with VPV4.
  I1->setOperand(1, VPV4);
  EXPECT_TRUE(VPV3->user_empty());
  EXPECT_EQ(I1, *VPV4->user_begin());
  EXPECT_EQ(I1, *std::next(VPV4->user_begin()));

  delete I1;
}

TEST_F(VPInstructionTest, replaceAllUsesWith) {
  IntegerType *Int32 = IntegerType::get(C, 32);
  VPValue *VPV1 = getPlan().getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPValue *VPV2 = getPlan().getOrAddLiveIn(ConstantInt::get(Int32, 2));
  VPInstruction *I1 =
      new VPInstruction(Instruction::Add, {VPV1, VPV2},
                        VPIRFlags::getDefaultFlags(Instruction::Add));

  // Replace all uses of VPV1 with VPV3.
  VPValue *VPV3 = getPlan().getOrAddLiveIn(ConstantInt::get(Int32, 3));
  VPV1->replaceAllUsesWith(VPV3);
  EXPECT_EQ(VPV3, I1->getOperand(0));
  EXPECT_EQ(VPV2, I1->getOperand(1));
  EXPECT_TRUE(VPV1->user_empty());
  EXPECT_TRUE(VPV2->hasOneUse());
  EXPECT_EQ(I1, *VPV2->user_begin());
  EXPECT_TRUE(VPV3->hasOneUse());
  EXPECT_EQ(I1, *VPV3->user_begin());

  // Replace all uses of VPV2 with VPV3.
  VPV2->replaceAllUsesWith(VPV3);
  EXPECT_EQ(VPV3, I1->getOperand(0));
  EXPECT_EQ(VPV3, I1->getOperand(1));
  EXPECT_TRUE(VPV1->user_empty());
  EXPECT_TRUE(VPV2->user_empty());
  EXPECT_EQ(2u, VPV3->getNumUsers());
  EXPECT_EQ(I1, *VPV3->user_begin());

  // Replace all uses of VPV3 with VPV1.
  VPV3->replaceAllUsesWith(VPV1);
  EXPECT_EQ(VPV1, I1->getOperand(0));
  EXPECT_EQ(VPV1, I1->getOperand(1));
  EXPECT_EQ(2u, VPV1->getNumUsers());
  EXPECT_EQ(I1, *VPV1->user_begin());
  EXPECT_TRUE(VPV2->user_empty());
  EXPECT_TRUE(VPV3->user_empty());

  VPInstruction *I2 =
      new VPInstruction(Instruction::Add, {VPV1, VPV2},
                        VPIRFlags::getDefaultFlags(Instruction::Add));
  EXPECT_EQ(3u, VPV1->getNumUsers());
  VPV1->replaceAllUsesWith(VPV3);
  EXPECT_EQ(3u, VPV3->getNumUsers());

  delete I1;
  delete I2;
}

TEST_F(VPInstructionTest, releaseOperandsAtDeletion) {
  IntegerType *Int32 = IntegerType::get(C, 32);
  VPValue *VPV1 = getPlan().getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPValue *VPV2 = getPlan().getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPInstruction *I1 =
      new VPInstruction(Instruction::Add, {VPV1, VPV2},
                        VPIRFlags::getDefaultFlags(Instruction::Add));

  EXPECT_TRUE(VPV1->hasOneUse());
  EXPECT_EQ(I1, *VPV1->user_begin());
  EXPECT_TRUE(VPV2->hasOneUse());
  EXPECT_EQ(I1, *VPV2->user_begin());

  delete I1;

  EXPECT_TRUE(VPV1->user_empty());
  EXPECT_TRUE(VPV2->user_empty());
}

using VPBasicBlockTest = VPlanTestBase;

TEST_F(VPBasicBlockTest, getPlan) {
  {
    VPlan &Plan = getPlan();
    VPBasicBlock *VPBB1 = Plan.getEntry();
    VPBasicBlock *VPBB2 = Plan.createVPBasicBlock("");
    VPBasicBlock *VPBB3 = Plan.createVPBasicBlock("");
    VPBasicBlock *VPBB4 = Plan.createVPBasicBlock("");

    //     VPBB1
    //     /   \
    // VPBB2  VPBB3
    //    \    /
    //    VPBB4
    VPBlockUtils::connectBlocks(VPBB1, VPBB2);
    VPBlockUtils::connectBlocks(VPBB1, VPBB3);
    VPBlockUtils::connectBlocks(VPBB2, VPBB4);
    VPBlockUtils::connectBlocks(VPBB3, VPBB4);
    VPBlockUtils::connectBlocks(VPBB4, Plan.getScalarHeader());

    EXPECT_EQ(&Plan, VPBB1->getPlan());
    EXPECT_EQ(&Plan, VPBB2->getPlan());
    EXPECT_EQ(&Plan, VPBB3->getPlan());
    EXPECT_EQ(&Plan, VPBB4->getPlan());
  }

  {
    VPlan &Plan = getPlan();
    VPBasicBlock *VPBB1 = Plan.getEntry();
    // VPBasicBlock is the entry into the VPlan, followed by a region.
    VPBasicBlock *R1BB1 = Plan.createVPBasicBlock("");
    VPBasicBlock *R1BB2 = Plan.createVPBasicBlock("");
    VPRegionBlock *R1 = Plan.createLoopRegion(Type::getInt32Ty(C), DebugLoc(),
                                              "R1", R1BB1, R1BB2);
    VPBlockUtils::connectBlocks(R1BB1, R1BB2);

    VPBlockUtils::connectBlocks(VPBB1, R1);

    VPBlockUtils::connectBlocks(R1, Plan.getScalarHeader());

    EXPECT_EQ(&Plan, VPBB1->getPlan());
    EXPECT_EQ(&Plan, R1->getPlan());
    EXPECT_EQ(&Plan, R1BB1->getPlan());
    EXPECT_EQ(&Plan, R1BB2->getPlan());
  }

  {
    VPlan &Plan = getPlan();
    VPBasicBlock *R1BB1 = Plan.createVPBasicBlock("");
    VPBasicBlock *R1BB2 = Plan.createVPBasicBlock("");
    VPRegionBlock *R1 = Plan.createLoopRegion(Type::getInt32Ty(C), DebugLoc(),
                                              "R1", R1BB1, R1BB2);
    VPBlockUtils::connectBlocks(R1BB1, R1BB2);

    VPBasicBlock *R2BB1 = Plan.createVPBasicBlock("");
    VPBasicBlock *R2BB2 = Plan.createVPBasicBlock("");
    VPRegionBlock *R2 = Plan.createLoopRegion(Type::getInt32Ty(C), DebugLoc(),
                                              "R2", R2BB1, R2BB2);
    VPBlockUtils::connectBlocks(R2BB1, R2BB2);

    VPBasicBlock *VPBB1 = Plan.getEntry();
    VPBlockUtils::connectBlocks(VPBB1, R1);
    VPBlockUtils::connectBlocks(VPBB1, R2);

    VPBasicBlock *VPBB2 = Plan.createVPBasicBlock("");
    VPBlockUtils::connectBlocks(R1, VPBB2);
    VPBlockUtils::connectBlocks(R2, VPBB2);

    VPBlockUtils::connectBlocks(R2, Plan.getScalarHeader());

    EXPECT_EQ(&Plan, VPBB1->getPlan());
    EXPECT_EQ(&Plan, R1->getPlan());
    EXPECT_EQ(&Plan, R1BB1->getPlan());
    EXPECT_EQ(&Plan, R1BB2->getPlan());
    EXPECT_EQ(&Plan, R2->getPlan());
    EXPECT_EQ(&Plan, R2BB1->getPlan());
    EXPECT_EQ(&Plan, R2BB2->getPlan());
    EXPECT_EQ(&Plan, VPBB2->getPlan());
  }
}

TEST_F(VPBasicBlockTest, TraversingIteratorTest) {
  {
    // VPBasicBlocks only
    //     VPBB1
    //     /   \
    // VPBB2  VPBB3
    //    \    /
    //    VPBB4
    //
    VPlan &Plan = getPlan();
    VPBasicBlock *VPBB1 = Plan.getEntry();
    VPBasicBlock *VPBB2 = Plan.createVPBasicBlock("");
    VPBasicBlock *VPBB3 = Plan.createVPBasicBlock("");
    VPBasicBlock *VPBB4 = Plan.createVPBasicBlock("");

    VPBlockUtils::connectBlocks(VPBB1, VPBB2);
    VPBlockUtils::connectBlocks(VPBB1, VPBB3);
    VPBlockUtils::connectBlocks(VPBB2, VPBB4);
    VPBlockUtils::connectBlocks(VPBB3, VPBB4);

    VPBlockDeepTraversalWrapper<const VPBlockBase *> Start(VPBB1);
    SmallVector<const VPBlockBase *> FromIterator(depth_first(Start));
    EXPECT_EQ(4u, FromIterator.size());
    EXPECT_EQ(VPBB1, FromIterator[0]);
    EXPECT_EQ(VPBB2, FromIterator[1]);

    VPBlockUtils::connectBlocks(VPBB4, Plan.getScalarHeader());
  }

  {
    // 2 consecutive regions.
    // VPBB0
    //  |
    // R1 {
    //     \
    //     R1BB1
    //    /     \   |--|
    //  R1BB2   R1BB3 -|
    //    \      /
    //     R1BB4
    //  }
    //   |
    // R2 {
    //   \
    //    R2BB1
    //      |
    //    R2BB2
    //
    VPlan &Plan = getPlan();
    VPBasicBlock *VPBB0 = Plan.getEntry();
    VPBasicBlock *R1BB1 = Plan.createVPBasicBlock("");
    VPBasicBlock *R1BB2 = Plan.createVPBasicBlock("");
    VPBasicBlock *R1BB3 = Plan.createVPBasicBlock("");
    VPBasicBlock *R1BB4 = Plan.createVPBasicBlock("");
    VPRegionBlock *R1 = Plan.createLoopRegion(Type::getInt32Ty(C), DebugLoc(),
                                              "R1", R1BB1, R1BB4);
    R1BB2->setParent(R1);
    R1BB3->setParent(R1);
    VPBlockUtils::connectBlocks(VPBB0, R1);
    VPBlockUtils::connectBlocks(R1BB1, R1BB2);
    VPBlockUtils::connectBlocks(R1BB1, R1BB3);
    VPBlockUtils::connectBlocks(R1BB2, R1BB4);
    VPBlockUtils::connectBlocks(R1BB3, R1BB4);
    // Cycle.
    VPBlockUtils::connectBlocks(R1BB3, R1BB3);

    VPBasicBlock *R2BB1 = Plan.createVPBasicBlock("");
    VPBasicBlock *R2BB2 = Plan.createVPBasicBlock("");
    VPRegionBlock *R2 = Plan.createLoopRegion(Type::getInt32Ty(C), DebugLoc(),
                                              "R2", R2BB1, R2BB2);
    VPBlockUtils::connectBlocks(R2BB1, R2BB2);
    VPBlockUtils::connectBlocks(R1, R2);

    // Successors of R1.
    SmallVector<const VPBlockBase *> FromIterator(
        VPHierarchicalChildrenIterator<VPBlockBase *>(R1),
        VPHierarchicalChildrenIterator<VPBlockBase *>::end(R1));
    EXPECT_EQ(1u, FromIterator.size());
    EXPECT_EQ(R1BB1, FromIterator[0]);

    // Predecessors of R1.
    FromIterator.clear();
    copy(VPHierarchicalChildrenIterator<VPBlockBase *, false>(R1),
         VPHierarchicalChildrenIterator<VPBlockBase *, false>::end(R1),
         std::back_inserter(FromIterator));
    EXPECT_EQ(1u, FromIterator.size());
    EXPECT_EQ(R1BB4, FromIterator[0]);

    // Predecessors of R1BB1.
    FromIterator.clear();
    copy(VPHierarchicalChildrenIterator<VPBlockBase *, false>(R1BB1),
         VPHierarchicalChildrenIterator<VPBlockBase *, false>::end(R1BB1),
         std::back_inserter(FromIterator));
    EXPECT_EQ(1u, FromIterator.size());
    EXPECT_EQ(VPBB0, FromIterator[0]);

    // Depth-first.
    VPBlockDeepTraversalWrapper<VPBlockBase *> Start(R1);
    FromIterator.clear();
    copy(df_begin(Start), df_end(Start), std::back_inserter(FromIterator));
    EXPECT_EQ(8u, FromIterator.size());
    EXPECT_EQ(R1, FromIterator[0]);
    EXPECT_EQ(R1BB1, FromIterator[1]);
    EXPECT_EQ(R1BB2, FromIterator[2]);
    EXPECT_EQ(R1BB4, FromIterator[3]);
    EXPECT_EQ(R2, FromIterator[4]);
    EXPECT_EQ(R2BB1, FromIterator[5]);
    EXPECT_EQ(R2BB2, FromIterator[6]);
    EXPECT_EQ(R1BB3, FromIterator[7]);

    // Depth-first on the inverse graph (traverse predecessors).
    FromIterator.clear();
    copy(depth_first<Inverse<VPBlockBase *>>(R2),
         std::back_inserter(FromIterator));
    EXPECT_EQ(9u, FromIterator.size());
    EXPECT_EQ(R2, FromIterator[0]);
    EXPECT_EQ(R2BB2, FromIterator[1]);
    EXPECT_EQ(R2BB1, FromIterator[2]);
    EXPECT_EQ(R1, FromIterator[3]);
    EXPECT_EQ(R1BB4, FromIterator[4]);
    EXPECT_EQ(R1BB2, FromIterator[5]);
    EXPECT_EQ(R1BB1, FromIterator[6]);
    EXPECT_EQ(VPBB0, FromIterator[7]);
    EXPECT_EQ(R1BB3, FromIterator[8]);

    // const VPBasicBlocks only.
    FromIterator.clear();
    copy(VPBlockUtils::blocksOnly<const VPBasicBlock>(depth_first(Start)),
         std::back_inserter(FromIterator));
    EXPECT_EQ(6u, FromIterator.size());
    EXPECT_EQ(R1BB1, FromIterator[0]);
    EXPECT_EQ(R1BB2, FromIterator[1]);
    EXPECT_EQ(R1BB4, FromIterator[2]);
    EXPECT_EQ(R2BB1, FromIterator[3]);
    EXPECT_EQ(R2BB2, FromIterator[4]);
    EXPECT_EQ(R1BB3, FromIterator[5]);

    // VPRegionBlocks only.
    SmallVector<VPRegionBlock *> FromIteratorVPRegion(
        VPBlockUtils::blocksOnly<VPRegionBlock>(depth_first(Start)));
    EXPECT_EQ(2u, FromIteratorVPRegion.size());
    EXPECT_EQ(R1, FromIteratorVPRegion[0]);
    EXPECT_EQ(R2, FromIteratorVPRegion[1]);

    // Post-order.
    FromIterator.clear();
    copy(post_order(Start), std::back_inserter(FromIterator));
    EXPECT_EQ(8u, FromIterator.size());
    EXPECT_EQ(R2BB2, FromIterator[0]);
    EXPECT_EQ(R2BB1, FromIterator[1]);
    EXPECT_EQ(R2, FromIterator[2]);
    EXPECT_EQ(R1BB4, FromIterator[3]);
    EXPECT_EQ(R1BB2, FromIterator[4]);
    EXPECT_EQ(R1BB3, FromIterator[5]);
    EXPECT_EQ(R1BB1, FromIterator[6]);
    EXPECT_EQ(R1, FromIterator[7]);

    VPBlockUtils::connectBlocks(R2, Plan.getScalarHeader());
  }

  {
    // 2 nested regions.
    //  VPBB1
    //    |
    //  R1 {
    //         R1BB1
    //       /        \
    //   R2 {          |
    //     \           |
    //     R2BB1       |
    //       |   \    R1BB2
    //     R2BB2-|     |
    //        \        |
    //         R2BB3   |
    //   }            /
    //      \        /
    //        R1BB3
    //  }
    //   |
    //  VPBB2
    //
    VPlan &Plan = getPlan();
    VPBasicBlock *R1BB1 = Plan.createVPBasicBlock("R1BB1");
    VPBasicBlock *R1BB2 = Plan.createVPBasicBlock("R1BB2");
    VPBasicBlock *R1BB3 = Plan.createVPBasicBlock("R1BB3");
    VPRegionBlock *R1 = Plan.createLoopRegion(Type::getInt32Ty(C), DebugLoc(),
                                              "R1", R1BB1, R1BB3);

    VPBasicBlock *R2BB1 = Plan.createVPBasicBlock("R2BB1");
    VPBasicBlock *R2BB2 = Plan.createVPBasicBlock("R2BB2");
    VPBasicBlock *R2BB3 = Plan.createVPBasicBlock("R2BB3");
    VPRegionBlock *R2 = Plan.createLoopRegion(Type::getInt32Ty(C), DebugLoc(),
                                              "R2", R2BB1, R2BB3);
    R2BB2->setParent(R2);
    VPBlockUtils::connectBlocks(R2BB1, R2BB2);
    VPBlockUtils::connectBlocks(R2BB2, R2BB1);
    VPBlockUtils::connectBlocks(R2BB2, R2BB3);

    R2->setParent(R1);
    VPBlockUtils::connectBlocks(R1BB1, R2);
    R1BB2->setParent(R1);
    VPBlockUtils::connectBlocks(R1BB1, R1BB2);
    VPBlockUtils::connectBlocks(R1BB2, R1BB3);
    VPBlockUtils::connectBlocks(R2, R1BB3);

    VPBasicBlock *VPBB1 = Plan.getEntry();
    VPBlockUtils::connectBlocks(VPBB1, R1);
    VPBasicBlock *VPBB2 = Plan.createVPBasicBlock("VPBB2");
    VPBlockUtils::connectBlocks(R1, VPBB2);

    // Depth-first.
    VPBlockDeepTraversalWrapper<VPBlockBase *> Start(VPBB1);
    SmallVector<VPBlockBase *> FromIterator(depth_first(Start));
    EXPECT_EQ(10u, FromIterator.size());
    EXPECT_EQ(VPBB1, FromIterator[0]);
    EXPECT_EQ(R1, FromIterator[1]);
    EXPECT_EQ(R1BB1, FromIterator[2]);
    EXPECT_EQ(R2, FromIterator[3]);
    EXPECT_EQ(R2BB1, FromIterator[4]);
    EXPECT_EQ(R2BB2, FromIterator[5]);
    EXPECT_EQ(R2BB3, FromIterator[6]);
    EXPECT_EQ(R1BB3, FromIterator[7]);
    EXPECT_EQ(VPBB2, FromIterator[8]);
    EXPECT_EQ(R1BB2, FromIterator[9]);

    // Post-order.
    FromIterator.clear();
    copy(post_order(Start), std::back_inserter(FromIterator));
    EXPECT_EQ(10u, FromIterator.size());
    EXPECT_EQ(VPBB2, FromIterator[0]);
    EXPECT_EQ(R1BB3, FromIterator[1]);
    EXPECT_EQ(R2BB3, FromIterator[2]);
    EXPECT_EQ(R2BB2, FromIterator[3]);
    EXPECT_EQ(R2BB1, FromIterator[4]);
    EXPECT_EQ(R2, FromIterator[5]);
    EXPECT_EQ(R1BB2, FromIterator[6]);
    EXPECT_EQ(R1BB1, FromIterator[7]);
    EXPECT_EQ(R1, FromIterator[8]);
    EXPECT_EQ(VPBB1, FromIterator[9]);

    VPBlockUtils::connectBlocks(VPBB2, Plan.getScalarHeader());
  }

  {
    //  VPBB1
    //    |
    //  R1 {
    //    \
    //     R2 {
    //      R2BB1
    //        |
    //      R2BB2
    //   }
    //
    VPlan &Plan = getPlan();
    VPBasicBlock *R2BB1 = Plan.createVPBasicBlock("R2BB1");
    VPBasicBlock *R2BB2 = Plan.createVPBasicBlock("R2BB2");
    VPRegionBlock *R2 = Plan.createLoopRegion(Type::getInt32Ty(C), DebugLoc(),
                                              "R2", R2BB1, R2BB2);
    VPBlockUtils::connectBlocks(R2BB1, R2BB2);

    VPRegionBlock *R1 =
        Plan.createLoopRegion(Type::getInt32Ty(C), DebugLoc(), "R1", R2, R2);
    R2->setParent(R1);

    VPBasicBlock *VPBB1 = Plan.getEntry();
    VPBlockUtils::connectBlocks(VPBB1, R1);

    // Depth-first.
    VPBlockDeepTraversalWrapper<VPBlockBase *> Start(VPBB1);
    SmallVector<VPBlockBase *> FromIterator(depth_first(Start));
    EXPECT_EQ(5u, FromIterator.size());
    EXPECT_EQ(VPBB1, FromIterator[0]);
    EXPECT_EQ(R1, FromIterator[1]);
    EXPECT_EQ(R2, FromIterator[2]);
    EXPECT_EQ(R2BB1, FromIterator[3]);
    EXPECT_EQ(R2BB2, FromIterator[4]);

    // Post-order.
    FromIterator.clear();
    copy(post_order(Start), std::back_inserter(FromIterator));
    EXPECT_EQ(5u, FromIterator.size());
    EXPECT_EQ(R2BB2, FromIterator[0]);
    EXPECT_EQ(R2BB1, FromIterator[1]);
    EXPECT_EQ(R2, FromIterator[2]);
    EXPECT_EQ(R1, FromIterator[3]);
    EXPECT_EQ(VPBB1, FromIterator[4]);

    VPBlockUtils::connectBlocks(R1, Plan.getScalarHeader());
  }

  {
    //  Nested regions with both R3 and R2 being exit nodes without successors.
    //  The successors of R1 should be used.
    //
    //  VPBB1
    //    |
    //  R1 {
    //    \
    //     R2 {
    //      \
    //      R2BB1
    //        |
    //       R3 {
    //          R3BB1
    //      }
    //   }
    //   |
    //  VPBB2
    //
    VPlan &Plan = getPlan();
    VPBasicBlock *R3BB1 = Plan.createVPBasicBlock("R3BB1");
    VPRegionBlock *R3 = Plan.createLoopRegion(Type::getInt32Ty(C), DebugLoc(),
                                              "R3", R3BB1, R3BB1);

    VPBasicBlock *R2BB1 = Plan.createVPBasicBlock("R2BB1");
    VPRegionBlock *R2 =
        Plan.createLoopRegion(Type::getInt32Ty(C), DebugLoc(), "R2", R2BB1, R3);
    R3->setParent(R2);
    VPBlockUtils::connectBlocks(R2BB1, R3);

    VPRegionBlock *R1 =
        Plan.createLoopRegion(Type::getInt32Ty(C), DebugLoc(), "R1", R2, R2);
    R2->setParent(R1);

    VPBasicBlock *VPBB1 = Plan.getEntry();
    VPBasicBlock *VPBB2 = Plan.createVPBasicBlock("VPBB2");
    VPBlockUtils::connectBlocks(VPBB1, R1);
    VPBlockUtils::connectBlocks(R1, VPBB2);

    // Depth-first.
    VPBlockDeepTraversalWrapper<VPBlockBase *> Start(VPBB1);
    SmallVector<VPBlockBase *> FromIterator(depth_first(Start));
    EXPECT_EQ(7u, FromIterator.size());
    EXPECT_EQ(VPBB1, FromIterator[0]);
    EXPECT_EQ(R1, FromIterator[1]);
    EXPECT_EQ(R2, FromIterator[2]);
    EXPECT_EQ(R2BB1, FromIterator[3]);
    EXPECT_EQ(R3, FromIterator[4]);
    EXPECT_EQ(R3BB1, FromIterator[5]);
    EXPECT_EQ(VPBB2, FromIterator[6]);

    SmallVector<VPBlockBase *> FromIteratorVPBB;
    copy(VPBlockUtils::blocksOnly<VPBasicBlock>(depth_first(Start)),
         std::back_inserter(FromIteratorVPBB));
    EXPECT_EQ(VPBB1, FromIteratorVPBB[0]);
    EXPECT_EQ(R2BB1, FromIteratorVPBB[1]);
    EXPECT_EQ(R3BB1, FromIteratorVPBB[2]);
    EXPECT_EQ(VPBB2, FromIteratorVPBB[3]);

    // Post-order.
    FromIterator.clear();
    copy(post_order(Start), std::back_inserter(FromIterator));
    EXPECT_EQ(7u, FromIterator.size());
    EXPECT_EQ(VPBB2, FromIterator[0]);
    EXPECT_EQ(R3BB1, FromIterator[1]);
    EXPECT_EQ(R3, FromIterator[2]);
    EXPECT_EQ(R2BB1, FromIterator[3]);
    EXPECT_EQ(R2, FromIterator[4]);
    EXPECT_EQ(R1, FromIterator[5]);
    EXPECT_EQ(VPBB1, FromIterator[6]);

    // Post-order, const VPRegionBlocks only.
    VPBlockDeepTraversalWrapper<const VPBlockBase *> StartConst(VPBB1);
    SmallVector<const VPRegionBlock *> FromIteratorVPRegion;
    copy(VPBlockUtils::blocksOnly<const VPRegionBlock>(post_order(StartConst)),
         std::back_inserter(FromIteratorVPRegion));
    EXPECT_EQ(3u, FromIteratorVPRegion.size());
    EXPECT_EQ(R3, FromIteratorVPRegion[0]);
    EXPECT_EQ(R2, FromIteratorVPRegion[1]);
    EXPECT_EQ(R1, FromIteratorVPRegion[2]);

    // Post-order, VPBasicBlocks only.
    FromIterator.clear();
    copy(VPBlockUtils::blocksOnly<VPBasicBlock>(post_order(Start)),
         std::back_inserter(FromIterator));
    EXPECT_EQ(FromIterator.size(), 4u);
    EXPECT_EQ(VPBB2, FromIterator[0]);
    EXPECT_EQ(R3BB1, FromIterator[1]);
    EXPECT_EQ(R2BB1, FromIterator[2]);
    EXPECT_EQ(VPBB1, FromIterator[3]);

    VPBlockUtils::connectBlocks(VPBB2, Plan.getScalarHeader());
  }
}

TEST_F(VPBasicBlockTest, reassociateBlocks) {
  {
    // Ensure that when we reassociate a basic block, we make sure to update any
    // references to it in VPWidenPHIRecipes' incoming blocks.
    VPlan &Plan = getPlan();
    VPBasicBlock *VPBB1 = Plan.createVPBasicBlock("VPBB1");
    VPBasicBlock *VPBB2 = Plan.createVPBasicBlock("VPBB2");
    VPBlockUtils::connectBlocks(VPBB1, VPBB2);

    IntegerType *Int32 = IntegerType::get(C, 32);
    VPValue *Val = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
    auto *WidenPhi = new VPWidenPHIRecipe(ArrayRef<VPValue *>{Val});
    VPBB2->appendRecipe(WidenPhi);

    VPBasicBlock *VPBBNew = Plan.createVPBasicBlock("VPBBNew");
    VPBlockUtils::reassociateBlocks(VPBB1, VPBBNew);
    EXPECT_EQ(VPBB2->getSinglePredecessor(), VPBBNew);
    EXPECT_EQ(WidenPhi->getIncomingBlock(0), VPBBNew);
  }

  {
    // Ensure that we update VPWidenPHIRecipes that are nested inside a
    // VPRegionBlock.
    VPlan &Plan = getPlan();
    VPBasicBlock *VPBB1 = Plan.createVPBasicBlock("VPBB1");
    VPBasicBlock *VPBB2 = Plan.createVPBasicBlock("VPBB2");
    VPRegionBlock *R1 = Plan.createLoopRegion(Type::getInt32Ty(C), DebugLoc(),
                                              "R1", VPBB2, VPBB2);
    VPBlockUtils::connectBlocks(VPBB1, R1);

    IntegerType *Int32 = IntegerType::get(C, 32);
    VPValue *Val = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
    auto *WidenPhi = new VPWidenPHIRecipe({Val, Val});
    VPBB2->appendRecipe(WidenPhi);

    VPBasicBlock *VPBBNew = Plan.createVPBasicBlock("VPBBNew");
    VPBlockUtils::reassociateBlocks(VPBB1, VPBBNew);
    EXPECT_EQ(R1->getSinglePredecessor(), VPBBNew);
    EXPECT_EQ(WidenPhi->getIncomingBlock(0), VPBBNew);
  }
}

TEST_F(VPBasicBlockTest, splitAtEnd) {
  VPlan &Plan = getPlan();
  VPInstruction *VPI = new VPInstructionWithType(VPInstruction::StepVector, {},
                                                 IntegerType::get(C, 32));
  VPBasicBlock *VPBB = Plan.createVPBasicBlock("VPBB1", VPI);
  VPBlockUtils::connectBlocks(Plan.getEntry(), VPBB);
  VPBlockUtils::connectBlocks(VPBB, Plan.getScalarHeader());
  VPBB->splitAt(VPBB->end());
  EXPECT_EQ(VPBB->size(), 1u);
  EXPECT_EQ(&VPBB->front(), VPI);
  auto *Split = cast<VPBasicBlock>(VPBB->getSingleSuccessor());
  EXPECT_TRUE(Split->empty());
  EXPECT_EQ(Split->getSingleSuccessor(), Plan.getScalarHeader());
}

#if !defined(NDEBUG) || defined(LLVM_ENABLE_DUMP)
TEST_F(VPBasicBlockTest, print) {
  VPlan &Plan = getPlan();
  IntegerType *Int32 = IntegerType::get(C, 32);
  VPValue *Val = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPBasicBlock *VPBB0 = Plan.getEntry();

  VPInstruction *I1 =
      new VPInstruction(Instruction::Add, {Val, Val},
                        VPIRFlags::getDefaultFlags(Instruction::Add));
  VPInstruction *I2 =
      new VPInstruction(Instruction::Sub, {I1, Val},
                        VPIRFlags::getDefaultFlags(Instruction::Sub));
  VPInstruction *I3 = new VPInstruction(Instruction::Store, {I1, I2});

  VPBasicBlock *VPBB1 = Plan.createVPBasicBlock("");
  VPBB1->appendRecipe(I1);
  VPBB1->appendRecipe(I2);
  VPBB1->appendRecipe(I3);
  VPBB1->setName("bb1");

  VPInstruction *I4 = new VPInstruction(
      Instruction::Mul, {I2, I1}, VPIRFlags::getDefaultFlags(Instruction::Mul));
  VPInstruction *I5 = new VPInstruction(Instruction::Freeze, {I4});
  VPBasicBlock *VPBB2 = Plan.createVPBasicBlock("");
  VPBB2->appendRecipe(I4);
  VPBB2->appendRecipe(I5);
  VPBB2->setName("bb2");

  VPBlockUtils::connectBlocks(VPBB1, VPBB2);

  // Check printing an instruction without associated VPlan.
  {
    std::string I3Dump;
    raw_string_ostream OS(I3Dump);
    VPSlotTracker SlotTracker;
    cast<VPRecipeBase>(I3)->print(OS, "", SlotTracker);
    EXPECT_EQ("EMIT store <badref>, <badref>", I3Dump);
  }

  VPBlockUtils::connectBlocks(VPBB2, Plan.getScalarHeader());
  VPBlockUtils::connectBlocks(VPBB0, VPBB1);
  std::string FullDump;
  raw_string_ostream OS(FullDump);
  Plan.printDOT(OS);

  const char *ExpectedStr = R"(digraph VPlan {
graph [labelloc=t, fontsize=30; label="Vectorization Plan\n for UF\>=1\n"]
node [shape=rect, fontname=Courier, fontsize=30]
edge [fontname=Courier, fontsize=30]
compound=true
  N0 [label =
    "preheader:\l" +
    "Successor(s): bb1\l"
  ]
  N0 -> N1 [ label=""]
  N1 [label =
    "bb1:\l" +
    "  EMIT vp\<%1\> = add ir\<1\>, ir\<1\>\l" +
    "  EMIT vp\<%2\> = sub vp\<%1\>, ir\<1\>\l" +
    "  EMIT store vp\<%1\>, vp\<%2\>\l" +
    "Successor(s): bb2\l"
  ]
  N1 -> N2 [ label=""]
  N2 [label =
    "bb2:\l" +
    "  EMIT vp\<%4\> = mul vp\<%2\>, vp\<%1\>\l" +
    "  EMIT vp\<%5\> = freeze vp\<%4\>\l" +
    "Successor(s): ir-bb\<scalar.header\>\l"
  ]
  N2 -> N3 [ label=""]
  N3 [label =
    "ir-bb\<scalar.header\>:\l" +
    "No successors\l"
  ]
}
)";
  EXPECT_EQ(ExpectedStr, FullDump);

  const char *ExpectedBlock1Str = R"(bb1:
  EMIT vp<%1> = add ir<1>, ir<1>
  EMIT vp<%2> = sub vp<%1>, ir<1>
  EMIT store vp<%1>, vp<%2>
Successor(s): bb2
)";
  std::string Block1Dump;
  raw_string_ostream OS1(Block1Dump);
  VPBB1->print(OS1);
  EXPECT_EQ(ExpectedBlock1Str, Block1Dump);

  // Ensure that numbering is good when dumping the second block in isolation.
  const char *ExpectedBlock2Str = R"(bb2:
  EMIT vp<%4> = mul vp<%2>, vp<%1>
  EMIT vp<%5> = freeze vp<%4>
Successor(s): ir-bb<scalar.header>
)";
  std::string Block2Dump;
  raw_string_ostream OS2(Block2Dump);
  VPBB2->print(OS2);
  EXPECT_EQ(ExpectedBlock2Str, Block2Dump);

  {
    std::string I3Dump;
    raw_string_ostream OS(I3Dump);
    VPSlotTracker SlotTracker(&Plan);
    cast<VPRecipeBase>(I3)->print(OS, "", SlotTracker);
    EXPECT_EQ("EMIT store vp<%1>, vp<%2>", I3Dump);
  }

  {
    std::string I4Dump;
    raw_string_ostream OS(I4Dump);
    OS << *I4;
    EXPECT_EQ("EMIT vp<%4> = mul vp<%2>, vp<%1>", I4Dump);
  }
}

TEST_F(VPBasicBlockTest, printPlanWithVFsAndUFs) {
  VPlan &Plan = getPlan();
  IntegerType *Int32 = IntegerType::get(C, 32);
  VPValue *Val = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPBasicBlock *VPBB0 = Plan.getEntry();

  VPInstruction *I1 =
      new VPInstruction(Instruction::Add, {Val, Val},
                        VPIRFlags::getDefaultFlags(Instruction::Add));
  VPBasicBlock *VPBB1 = Plan.createVPBasicBlock("");
  VPBB1->appendRecipe(I1);
  VPBB1->setName("bb1");

  VPBlockUtils::connectBlocks(VPBB1, Plan.getScalarHeader());
  VPBlockUtils::connectBlocks(VPBB0, VPBB1);
  Plan.setName("TestPlan");
  Plan.addVF(ElementCount::getFixed(4));

  {
    std::string FullDump;
    raw_string_ostream OS(FullDump);
    Plan.print(OS);

    const char *ExpectedStr = R"(VPlan 'TestPlan for VF={4},UF>=1' {

preheader:
Successor(s): bb1

bb1:
  EMIT vp<%1> = add ir<1>, ir<1>
Successor(s): ir-bb<scalar.header>

ir-bb<scalar.header>:
No successors
}
)";
    EXPECT_EQ(ExpectedStr, FullDump);
  }

  {
    Plan.addVF(ElementCount::getScalable(8));
    std::string FullDump;
    raw_string_ostream OS(FullDump);
    Plan.print(OS);

    const char *ExpectedStr = R"(VPlan 'TestPlan for VF={4,vscale x 8},UF>=1' {

preheader:
Successor(s): bb1

bb1:
  EMIT vp<%1> = add ir<1>, ir<1>
Successor(s): ir-bb<scalar.header>

ir-bb<scalar.header>:
No successors
}
)";
    EXPECT_EQ(ExpectedStr, FullDump);
  }

  {
    Plan.setUF(4);
    std::string FullDump;
    raw_string_ostream OS(FullDump);
    Plan.print(OS);

    const char *ExpectedStr = R"(VPlan 'TestPlan for VF={4,vscale x 8},UF={4}' {

preheader:
Successor(s): bb1

bb1:
  EMIT vp<%1> = add ir<1>, ir<1>
Successor(s): ir-bb<scalar.header>

ir-bb<scalar.header>:
No successors
}
)";
    EXPECT_EQ(ExpectedStr, FullDump);
  }
}

TEST_F(VPBasicBlockTest, cloneAndPrint) {
  VPlan &Plan = getPlan();
  VPBasicBlock *VPBB0 = Plan.getEntry();

  IntegerType *Int32 = IntegerType::get(C, 32);
  VPValue *Val = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));

  VPInstruction *I1 =
      new VPInstruction(Instruction::Add, {Val, Val},
                        VPIRFlags::getDefaultFlags(Instruction::Add));
  VPInstruction *I2 =
      new VPInstruction(Instruction::Sub, {I1, Val},
                        VPIRFlags::getDefaultFlags(Instruction::Sub));
  VPInstruction *I3 = new VPInstruction(Instruction::Store, {I1, I2});

  VPBasicBlock *VPBB1 = Plan.createVPBasicBlock("");
  VPBB1->appendRecipe(I1);
  VPBB1->appendRecipe(I2);
  VPBB1->appendRecipe(I3);
  VPBB1->setName("bb1");
  VPBlockUtils::connectBlocks(VPBB0, VPBB1);

  const char *ExpectedStr = R"(digraph VPlan {
graph [labelloc=t, fontsize=30; label="Vectorization Plan\n for UF\>=1\n"]
node [shape=rect, fontname=Courier, fontsize=30]
edge [fontname=Courier, fontsize=30]
compound=true
  N0 [label =
    "preheader:\l" +
    "Successor(s): bb1\l"
  ]
  N0 -> N1 [ label=""]
  N1 [label =
    "bb1:\l" +
    "  EMIT vp\<%1\> = add ir\<1\>, ir\<1\>\l" +
    "  EMIT vp\<%2\> = sub vp\<%1\>, ir\<1\>\l" +
    "  EMIT store vp\<%1\>, vp\<%2\>\l" +
    "No successors\l"
  ]
}
)";
  // Check that printing a cloned plan produces the same output.
  std::string FullDump;
  raw_string_ostream OS(FullDump);
  VPlan *Clone = Plan.duplicate();
  Clone->printDOT(OS);
  EXPECT_EQ(ExpectedStr, FullDump);
  delete Clone;
}
#endif

using VPRecipeTest = VPlanTestBase;

namespace {
template <typename RecipeT, typename T, typename... Rest>
void checkVPRecipeCastImpl(RecipeT *R) {
  // Direct checks on recipe pointer
  EXPECT_TRUE(isa<T>(R));
  EXPECT_EQ(R, dyn_cast<T>(R));
  (void)cast<T>(R); // Verify cast succeeds (asserts on failure)

  // Check through base pointer
  VPRecipeBase *BaseR = R;
  EXPECT_TRUE(isa<T>(BaseR));
  EXPECT_EQ(R, dyn_cast<T>(BaseR));
  (void)cast<T>(BaseR);

  // Check through const base pointer
  const VPRecipeBase *ConstBaseR = R;
  EXPECT_TRUE(isa<T>(ConstBaseR));
  EXPECT_EQ(R, dyn_cast<T>(ConstBaseR));
  (void)cast<T>(ConstBaseR);

  if constexpr (sizeof...(Rest) > 0)
    checkVPRecipeCastImpl<RecipeT, Rest...>(R);
}
} // namespace

TEST_F(VPRecipeTest, CastVPInstructionToVPUser) {
  IntegerType *Int32 = IntegerType::get(C, 32);
  VPlan &Plan = getPlan();
  VPValue *Op1 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPValue *Op2 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 2));
  VPInstruction Recipe(Instruction::Add, {Op1, Op2},
                       VPIRFlags::getDefaultFlags(Instruction::Add));

  checkVPRecipeCastImpl<VPInstruction, VPUser, VPIRMetadata>(&Recipe);
}

TEST_F(VPRecipeTest, CastVPWidenRecipeToVPUser) {
  VPlan &Plan = getPlan();
  IntegerType *Int32 = IntegerType::get(C, 32);
  auto *AI = BinaryOperator::CreateAdd(PoisonValue::get(Int32),
                                       PoisonValue::get(Int32));
  VPValue *Op1 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPValue *Op2 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 2));
  SmallVector<VPValue *, 2> Args;
  Args.push_back(Op1);
  Args.push_back(Op2);
  VPWidenRecipe WidenR(*AI, Args);

  checkVPRecipeCastImpl<VPWidenRecipe, VPUser, VPIRMetadata>(&WidenR);
  delete AI;
}

TEST_F(VPRecipeTest, CastVPWidenCallRecipeToVPUserAndVPRecipeBase) {
  VPlan &Plan = getPlan();
  IntegerType *Int32 = IntegerType::get(C, 32);
  FunctionType *FTy = FunctionType::get(Int32, false);
  Function *Fn = Function::Create(FTy, GlobalValue::ExternalLinkage, 0);
  auto *Call = CallInst::Create(FTy, Fn);
  VPValue *Op1 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPValue *Op2 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 2));
  VPValue *CalledFn = Plan.getOrAddLiveIn(Call->getCalledFunction());
  SmallVector<VPValue *, 2> Args;
  Args.push_back(Op1);
  Args.push_back(Op2);
  Args.push_back(CalledFn);
  VPWidenCallRecipe Recipe(Call, Fn, Args);

  checkVPRecipeCastImpl<VPWidenCallRecipe, VPUser, VPIRMetadata>(&Recipe);

  VPValue *VPV = &Recipe;
  EXPECT_TRUE(VPV->getDefiningRecipe());
  EXPECT_EQ(&Recipe, VPV->getDefiningRecipe());

  delete Call;
  delete Fn;
}

TEST_F(VPRecipeTest, CastVPWidenGEPRecipeToVPUserAndVPDef) {
  VPlan &Plan = getPlan();
  IntegerType *Int32 = IntegerType::get(C, 32);
  PointerType *Int32Ptr = PointerType::get(C, 0);
  auto *GEP = GetElementPtrInst::Create(Int32, PoisonValue::get(Int32Ptr),
                                        PoisonValue::get(Int32));
  VPValue *Op1 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPValue *Op2 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 2));
  SmallVector<VPValue *, 4> Args;
  Args.push_back(Op1);
  Args.push_back(Op2);
  VPWidenGEPRecipe Recipe(GEP->getSourceElementType(), Args, {}, {}, GEP);

  checkVPRecipeCastImpl<VPWidenGEPRecipe, VPUser>(&Recipe);

  VPValue *VPV = &Recipe;
  EXPECT_EQ(&Recipe, VPV->getDefiningRecipe());

  delete GEP;
}

TEST_F(VPRecipeTest, CastVPWidenCastRecipeToVPUser) {
  VPlan &Plan = getPlan();
  IntegerType *Int32 = IntegerType::get(C, 32);
  IntegerType *Int64 = IntegerType::get(C, 64);
  auto *Cast = CastInst::CreateZExtOrBitCast(PoisonValue::get(Int32), Int64);
  VPValue *Op1 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPWidenCastRecipe Recipe(Instruction::ZExt, Op1, Int64, Cast,
                           VPIRFlags::getDefaultFlags(Instruction::ZExt));

  checkVPRecipeCastImpl<VPWidenCastRecipe, VPUser, VPIRMetadata>(&Recipe);
  delete Cast;
}

TEST_F(VPRecipeTest, CastVPWidenIntrinsicRecipeToVPUser) {
  VPlan &Plan = getPlan();
  IntegerType *Int32 = IntegerType::get(C, 32);
  VPValue *Op1 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPValue *Op2 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 2));
  VPWidenIntrinsicRecipe Recipe(Intrinsic::smax, {Op1, Op2}, Int32);

  checkVPRecipeCastImpl<VPWidenIntrinsicRecipe, VPUser, VPIRMetadata>(&Recipe);
}

TEST_F(VPRecipeTest, CastVPBlendRecipeToVPUser) {
  VPlan &Plan = getPlan();
  IntegerType *Int32 = IntegerType::get(C, 32);
  auto *Phi = PHINode::Create(Int32, 1);

  VPValue *I1 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPValue *I2 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 2));
  VPValue *M2 = Plan.getOrAddLiveIn(ConstantInt::getTrue(C));
  SmallVector<VPValue *, 4> Args;
  Args.push_back(I1);
  Args.push_back(I2);
  Args.push_back(M2);
  VPBlendRecipe Recipe(Phi, Args, {}, {});

  checkVPRecipeCastImpl<VPBlendRecipe, VPUser>(&Recipe);

  delete Phi;
}

TEST_F(VPRecipeTest, CastVPInterleaveRecipeToVPUser) {
  VPlan &Plan = getPlan();
  IntegerType *Int32 = IntegerType::get(C, 32);
  VPValue *Addr = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPValue *Mask = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 2));
  InterleaveGroup<Instruction> IG(4, false, Align(4));
  VPInterleaveRecipe Recipe(&IG, Addr, {}, Mask, false, {}, DebugLoc());

  checkVPRecipeCastImpl<VPInterleaveRecipe, VPUser, VPIRMetadata>(&Recipe);
}

TEST_F(VPRecipeTest, CastVPReplicateRecipeToVPUser) {
  VPlan &Plan = getPlan();
  IntegerType *Int32 = IntegerType::get(C, 32);
  FunctionType *FTy = FunctionType::get(Int32, false);
  Function *Fn = Function::Create(FTy, GlobalValue::ExternalLinkage, 0);
  auto *Call = CallInst::Create(FTy, Fn);
  VPValue *Op1 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPValue *Op2 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 2));
  VPValue *CalledFn = Plan.getOrAddLiveIn(Call->getCalledFunction());
  SmallVector<VPValue *, 4> Args;
  Args.push_back(Op1);
  Args.push_back(Op2);
  Args.push_back(CalledFn);
  VPReplicateRecipe Recipe(Call, make_range(Args.begin(), Args.end()), true);

  checkVPRecipeCastImpl<VPReplicateRecipe, VPUser, VPIRMetadata>(&Recipe);

  delete Call;
  delete Fn;
}

TEST_F(VPRecipeTest, CastVPBranchOnMaskRecipeToVPUser) {
  VPlan &Plan = getPlan();
  IntegerType *Int32 = IntegerType::get(C, 32);
  VPValue *Mask = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPBranchOnMaskRecipe Recipe(Mask, {});

  checkVPRecipeCastImpl<VPBranchOnMaskRecipe, VPUser>(&Recipe);
}

TEST_F(VPRecipeTest, CastVPWidenMemoryRecipeToVPUserAndVPRecipeBase) {
  VPlan &Plan = getPlan();
  IntegerType *Int32 = IntegerType::get(C, 32);
  PointerType *Int32Ptr = PointerType::get(C, 0);
  auto *Load =
      new LoadInst(Int32, PoisonValue::get(Int32Ptr), "", false, Align(1));
  VPValue *Addr = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPValue *Mask = Plan.getOrAddLiveIn(ConstantInt::getTrue(C));
  VPWidenLoadRecipe Recipe(*Load, Addr, Mask, true, {}, {});

  checkVPRecipeCastImpl<VPWidenLoadRecipe, VPUser, VPIRMetadata>(&Recipe);

  VPValue *VPV = Recipe.getVPSingleValue();
  EXPECT_EQ(&Recipe, VPV->getDefiningRecipe());

  delete Load;
}

TEST_F(VPRecipeTest, CastVPInterleaveEVLRecipeToVPUser) {
  VPlan &Plan = getPlan();
  IntegerType *Int32 = IntegerType::get(C, 32);
  VPValue *Addr = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPValue *Mask = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 2));
  VPValue *EVL = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 8));
  InterleaveGroup<Instruction> IG(4, false, Align(4));
  VPInterleaveRecipe BaseRecipe(&IG, Addr, {}, Mask, false, {}, DebugLoc());
  VPInterleaveEVLRecipe Recipe(BaseRecipe, *EVL, Mask);

  checkVPRecipeCastImpl<VPInterleaveEVLRecipe, VPUser, VPIRMetadata>(&Recipe);
}

TEST_F(VPRecipeTest, CastVPWidenLoadEVLRecipeToVPUser) {
  VPlan &Plan = getPlan();
  IntegerType *Int32 = IntegerType::get(C, 32);
  PointerType *Int32Ptr = PointerType::get(C, 0);
  auto *Load =
      new LoadInst(Int32, PoisonValue::get(Int32Ptr), "", false, Align(1));
  VPValue *Addr = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPValue *Mask = Plan.getOrAddLiveIn(ConstantInt::getTrue(C));
  VPValue *EVL = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 8));
  VPWidenLoadRecipe BaseLoad(*Load, Addr, Mask, true, {}, {});
  VPWidenLoadEVLRecipe Recipe(BaseLoad, Addr, *EVL, Mask);

  checkVPRecipeCastImpl<VPWidenLoadEVLRecipe, VPUser, VPIRMetadata>(&Recipe);

  delete Load;
}

TEST_F(VPRecipeTest, CastVPWidenStoreRecipeToVPUser) {
  VPlan &Plan = getPlan();
  IntegerType *Int32 = IntegerType::get(C, 32);
  PointerType *Int32Ptr = PointerType::get(C, 0);
  auto *Store = new StoreInst(PoisonValue::get(Int32),
                              PoisonValue::get(Int32Ptr), false, Align(1));
  VPValue *Addr = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPValue *StoredVal = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 42));
  VPValue *Mask = Plan.getOrAddLiveIn(ConstantInt::getTrue(C));
  VPWidenStoreRecipe Recipe(*Store, Addr, StoredVal, Mask, true, {}, {});

  checkVPRecipeCastImpl<VPWidenStoreRecipe, VPUser, VPIRMetadata>(&Recipe);

  delete Store;
}

TEST_F(VPRecipeTest, CastVPWidenStoreEVLRecipeToVPUser) {
  VPlan &Plan = getPlan();
  IntegerType *Int32 = IntegerType::get(C, 32);
  PointerType *Int32Ptr = PointerType::get(C, 0);
  auto *Store = new StoreInst(PoisonValue::get(Int32),
                              PoisonValue::get(Int32Ptr), false, Align(1));
  VPValue *Addr = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPValue *StoredVal = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 42));
  VPValue *EVL = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 8));
  VPValue *Mask = Plan.getOrAddLiveIn(ConstantInt::getTrue(C));
  VPWidenStoreRecipe BaseStore(*Store, Addr, StoredVal, Mask, true, {}, {});
  VPWidenStoreEVLRecipe Recipe(BaseStore, Addr, StoredVal, *EVL, Mask);

  checkVPRecipeCastImpl<VPWidenStoreEVLRecipe, VPUser, VPIRMetadata>(&Recipe);

  delete Store;
}

TEST_F(VPRecipeTest, MayHaveSideEffectsAndMayReadWriteMemory) {
  IntegerType *Int32 = IntegerType::get(C, 32);
  PointerType *Int32Ptr = PointerType::get(C, 0);
  VPlan &Plan = getPlan();

  {
    auto *AI = BinaryOperator::CreateAdd(PoisonValue::get(Int32),
                                         PoisonValue::get(Int32));
    VPValue *Op1 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
    VPValue *Op2 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 2));
    SmallVector<VPValue *, 2> Args;
    Args.push_back(Op1);
    Args.push_back(Op2);
    VPWidenRecipe Recipe(*AI, Args);
    EXPECT_FALSE(Recipe.mayHaveSideEffects());
    EXPECT_FALSE(Recipe.mayReadFromMemory());
    EXPECT_FALSE(Recipe.mayWriteToMemory());
    EXPECT_FALSE(Recipe.mayReadOrWriteMemory());
    delete AI;
  }

  {
    auto *GEP = GetElementPtrInst::Create(Int32, PoisonValue::get(Int32Ptr),
                                          PoisonValue::get(Int32));
    VPValue *Op1 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
    VPValue *Op2 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 2));
    SmallVector<VPValue *, 4> Args;
    Args.push_back(Op1);
    Args.push_back(Op2);
    VPWidenGEPRecipe Recipe(GEP->getSourceElementType(), Args, {}, {}, GEP);
    EXPECT_FALSE(Recipe.mayHaveSideEffects());
    EXPECT_FALSE(Recipe.mayReadFromMemory());
    EXPECT_FALSE(Recipe.mayWriteToMemory());
    EXPECT_FALSE(Recipe.mayReadOrWriteMemory());
    delete GEP;
  }

  {
    VPValue *Mask = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));

    VPBranchOnMaskRecipe Recipe(Mask, {});
    EXPECT_TRUE(Recipe.mayHaveSideEffects());
    EXPECT_FALSE(Recipe.mayReadFromMemory());
    EXPECT_FALSE(Recipe.mayWriteToMemory());
    EXPECT_FALSE(Recipe.mayReadOrWriteMemory());
  }

  {
    VPValue *ChainOp = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
    VPValue *VecOp = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 2));
    VPValue *CondOp = Plan.getOrAddLiveIn(ConstantInt::getTrue(C));
    VPReductionRecipe Recipe(RecurKind::Add, FastMathFlags(), ChainOp, VecOp,
                             CondOp, RdxUnordered{});
    EXPECT_FALSE(Recipe.mayHaveSideEffects());
    EXPECT_FALSE(Recipe.mayReadFromMemory());
    EXPECT_FALSE(Recipe.mayWriteToMemory());
    EXPECT_FALSE(Recipe.mayReadOrWriteMemory());
  }

  {
    VPValue *ChainOp = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
    VPValue *VecOp = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 2));
    VPValue *CondOp = Plan.getOrAddLiveIn(ConstantInt::getTrue(C));
    VPReductionRecipe Recipe(RecurKind::Add, FastMathFlags(), ChainOp, VecOp,
                             CondOp, RdxUnordered{});
    VPValue *EVL = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 4));
    VPReductionEVLRecipe EVLRecipe(Recipe, *EVL, CondOp);
    EXPECT_FALSE(EVLRecipe.mayHaveSideEffects());
    EXPECT_FALSE(EVLRecipe.mayReadFromMemory());
    EXPECT_FALSE(EVLRecipe.mayWriteToMemory());
    EXPECT_FALSE(EVLRecipe.mayReadOrWriteMemory());
  }

  {
    auto *Load =
        new LoadInst(Int32, PoisonValue::get(Int32Ptr), "", false, Align(1));
    VPValue *Mask = Plan.getOrAddLiveIn(ConstantInt::getTrue(C));
    VPValue *Addr = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 2));
    VPWidenLoadRecipe Recipe(*Load, Addr, Mask, true, {}, {});
    EXPECT_FALSE(Recipe.mayHaveSideEffects());
    EXPECT_TRUE(Recipe.mayReadFromMemory());
    EXPECT_FALSE(Recipe.mayWriteToMemory());
    EXPECT_TRUE(Recipe.mayReadOrWriteMemory());
    delete Load;
  }

  {
    auto *Store = new StoreInst(PoisonValue::get(Int32),
                                PoisonValue::get(Int32Ptr), false, Align(1));
    VPValue *Mask = Plan.getOrAddLiveIn(ConstantInt::getTrue(C));
    VPValue *Addr = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 2));
    VPValue *StoredV = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 3));
    VPWidenStoreRecipe Recipe(*Store, Addr, StoredV, Mask, false, {}, {});
    EXPECT_TRUE(Recipe.mayHaveSideEffects());
    EXPECT_FALSE(Recipe.mayReadFromMemory());
    EXPECT_TRUE(Recipe.mayWriteToMemory());
    EXPECT_TRUE(Recipe.mayReadOrWriteMemory());
    delete Store;
  }

  {
    FunctionType *FTy = FunctionType::get(Int32, false);
    Function *Fn = Function::Create(FTy, GlobalValue::ExternalLinkage, 0);
    auto *Call = CallInst::Create(FTy, Fn);
    VPValue *Op1 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
    VPValue *Op2 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 2));
    VPValue *CalledFn = Plan.getOrAddLiveIn(Call->getCalledFunction());
    SmallVector<VPValue *, 3> Args;
    Args.push_back(Op1);
    Args.push_back(Op2);
    Args.push_back(CalledFn);
    VPWidenCallRecipe Recipe(Call, Fn, Args);
    EXPECT_TRUE(Recipe.mayHaveSideEffects());
    EXPECT_TRUE(Recipe.mayReadFromMemory());
    EXPECT_TRUE(Recipe.mayWriteToMemory());
    EXPECT_TRUE(Recipe.mayReadOrWriteMemory());
    delete Call;
    delete Fn;
  }

  {
    // Test for a call to a function without side-effects.
    Module M("", C);
    PointerType *PtrTy = PointerType::get(C, 0);
    Function *TheFn =
        Intrinsic::getOrInsertDeclaration(&M, Intrinsic::thread_pointer, PtrTy);

    auto *Call = CallInst::Create(TheFn->getFunctionType(), TheFn);
    VPValue *Op1 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
    VPValue *Op2 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 2));
    VPValue *CalledFn = Plan.getOrAddLiveIn(Call->getCalledFunction());
    SmallVector<VPValue *, 3> Args;
    Args.push_back(Op1);
    Args.push_back(Op2);
    Args.push_back(CalledFn);
    VPWidenCallRecipe Recipe(Call, TheFn, Args, VPIRFlags(), VPIRMetadata());
    EXPECT_FALSE(Recipe.mayHaveSideEffects());
    EXPECT_FALSE(Recipe.mayReadFromMemory());
    EXPECT_FALSE(Recipe.mayWriteToMemory());
    EXPECT_FALSE(Recipe.mayReadOrWriteMemory());
    delete Call;
  }

  {
    VPValue *Op1 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
    VPValue *Op2 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 2));
    VPScalarIVStepsRecipe Recipe(Op1, Op2, Op2, Instruction::BinaryOpsEnd);
    EXPECT_FALSE(Recipe.mayHaveSideEffects());
    EXPECT_FALSE(Recipe.mayReadFromMemory());
    EXPECT_FALSE(Recipe.mayWriteToMemory());
    EXPECT_FALSE(Recipe.mayReadOrWriteMemory());
  }

  {
    VPValue *Op1 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
    VPValue *Op2 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 2));
    VPInstruction VPInst(Instruction::Add, {Op1, Op2},
                         VPIRFlags::getDefaultFlags(Instruction::Add));
    VPRecipeBase &Recipe = VPInst;
    EXPECT_FALSE(Recipe.mayHaveSideEffects());
    EXPECT_FALSE(Recipe.mayReadFromMemory());
    EXPECT_FALSE(Recipe.mayWriteToMemory());
    EXPECT_FALSE(Recipe.mayReadOrWriteMemory());
  }
  {
    VPValue *Op1 = Plan.getConstantInt(Int32, 1);
    VPInstruction VPInst(Instruction::FNeg, {Op1},
                         VPIRFlags::getDefaultFlags(Instruction::FNeg));
    VPRecipeBase &Recipe = VPInst;
    EXPECT_FALSE(Recipe.mayHaveSideEffects());
    EXPECT_FALSE(Recipe.mayReadFromMemory());
    EXPECT_FALSE(Recipe.mayWriteToMemory());
    EXPECT_FALSE(Recipe.mayReadOrWriteMemory());
  }
  {
    VPValue *Op1 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
    VPPredInstPHIRecipe Recipe(Op1, {});
    EXPECT_FALSE(Recipe.mayHaveSideEffects());
    EXPECT_FALSE(Recipe.mayReadFromMemory());
    EXPECT_FALSE(Recipe.mayWriteToMemory());
    EXPECT_FALSE(Recipe.mayReadOrWriteMemory());
  }
}

#if !defined(NDEBUG) || defined(LLVM_ENABLE_DUMP)
TEST_F(VPRecipeTest, dumpRecipeInPlan) {
  VPlan &Plan = getPlan();
  VPBasicBlock *VPBB0 = Plan.getEntry();
  VPBasicBlock *VPBB1 = Plan.createVPBasicBlock("");
  VPBlockUtils::connectBlocks(VPBB1, Plan.getScalarHeader());
  VPBlockUtils::connectBlocks(VPBB0, VPBB1);

  IntegerType *Int32 = IntegerType::get(C, 32);
  auto *AI = BinaryOperator::CreateAdd(PoisonValue::get(Int32),
                                       PoisonValue::get(Int32));
  AI->setName("a");
  SmallVector<VPValue *, 2> Args;
  VPValue *ExtVPV1 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPValue *ExtVPV2 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 2));
  Args.push_back(ExtVPV1);
  Args.push_back(ExtVPV2);
  VPWidenRecipe *WidenR = new VPWidenRecipe(*AI, Args);
  VPBB1->appendRecipe(WidenR);

  {
    // Use EXPECT_EXIT to capture stderr and compare against expected output.
    //
    // Test VPValue::dump().
    VPValue *VPV = WidenR;
    EXPECT_EXIT(
        {
          VPV->dump();
          exit(0);
        },
        testing::ExitedWithCode(0), "WIDEN ir<%a> = add ir<1>, ir<2>");

    VPRecipeBase *Def = WidenR;
    EXPECT_EXIT(
        {
          Def->dump();
          exit(0);
        },
        testing::ExitedWithCode(0), "WIDEN ir<%a> = add ir<1>, ir<2>");

    EXPECT_EXIT(
        {
          WidenR->dump();
          exit(0);
        },
        testing::ExitedWithCode(0), "WIDEN ir<%a> = add ir<1>, ir<2>");

    // Test VPRecipeBase::dump().
    VPRecipeBase *R = WidenR;
    EXPECT_EXIT(
        {
          R->dump();
          exit(0);
        },
        testing::ExitedWithCode(0), "WIDEN ir<%a> = add ir<1>, ir<2>");
  }

  // Avoid use-after-free of AI when the VPlan destructor is called.
  WidenR->eraseFromParent();

  delete AI;
}

TEST_F(VPRecipeTest, dumpRecipeUnnamedVPValuesInPlan) {
  VPlan &Plan = getPlan();
  VPBasicBlock *VPBB0 = Plan.getEntry();
  VPBasicBlock *VPBB1 = Plan.createVPBasicBlock("");
  VPBlockUtils::connectBlocks(VPBB1, Plan.getScalarHeader());
  VPBlockUtils::connectBlocks(VPBB0, VPBB1);

  IntegerType *Int32 = IntegerType::get(C, 32);
  auto *AI = BinaryOperator::CreateAdd(PoisonValue::get(Int32),
                                       PoisonValue::get(Int32));
  AI->setName("a");
  SmallVector<VPValue *, 2> Args;
  VPValue *ExtVPV1 = Plan.getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPValue *ExtVPV2 = Plan.getOrAddLiveIn(AI);
  Args.push_back(ExtVPV1);
  Args.push_back(ExtVPV2);
  VPInstruction *I1 =
      new VPInstruction(Instruction::Add, {ExtVPV1, ExtVPV2},
                        VPIRFlags::getDefaultFlags(Instruction::Add));
  VPInstruction *I2 = new VPInstruction(
      Instruction::Mul, {I1, I1}, VPIRFlags::getDefaultFlags(Instruction::Mul));
  VPBB1->appendRecipe(I1);
  VPBB1->appendRecipe(I2);

  // Check printing I1.
  {
    // Use EXPECT_EXIT to capture stderr and compare against expected output.
    //
    // Test VPValue::dump().
    VPValue *VPV = I1;
    EXPECT_EXIT(
        {
          VPV->dump();
          exit(0);
        },
        testing::ExitedWithCode(0), "EMIT vp<%1> = add ir<1>, ir<%a>");

    // Test VPRecipeBase::dump().
    VPRecipeBase *R = I1;
    EXPECT_EXIT(
        {
          R->dump();
          exit(0);
        },
        testing::ExitedWithCode(0), "EMIT vp<%1> = add ir<1>, ir<%a>");
  }
  // Check printing I2.
  {
    // Use EXPECT_EXIT to capture stderr and compare against expected output.
    //
    // Test VPValue::dump().
    VPValue *VPV = I2;
    EXPECT_EXIT(
        {
          VPV->dump();
          exit(0);
        },
        testing::ExitedWithCode(0), "EMIT vp<%2> = mul vp<%1>, vp<%1>");

    // Test VPRecipeBase::dump().
    VPRecipeBase *R = I2;
    EXPECT_EXIT(
        {
          R->dump();
          exit(0);
        },
        testing::ExitedWithCode(0), "EMIT vp<%2> = mul vp<%1>, vp<%1>");
  }

  // Avoid use-after-free of AI when the VPlan destructor is called.
  I2->eraseFromParent();
  I1->eraseFromParent();

  delete AI;
}

TEST_F(VPRecipeTest, dumpRecipeUnnamedVPValuesNotInPlanOrBlock) {
  IntegerType *Int32 = IntegerType::get(C, 32);
  auto *AI = BinaryOperator::CreateAdd(PoisonValue::get(Int32),
                                       PoisonValue::get(Int32));
  AI->setName("a");
  VPValue *ExtVPV1 = getPlan().getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPValue *ExtVPV2 = getPlan().getOrAddLiveIn(AI);

  VPInstruction *I1 =
      new VPInstruction(Instruction::Add, {ExtVPV1, ExtVPV2},
                        VPIRFlags::getDefaultFlags(Instruction::Add));
  VPInstruction *I2 = new VPInstruction(
      Instruction::Mul, {I1, I1}, VPIRFlags::getDefaultFlags(Instruction::Mul));

  // Check printing I1.
  {
    // Use EXPECT_EXIT to capture stderr and compare against expected output.
    //
    // Test VPValue::dump().
    VPValue *VPV = I1;
    EXPECT_EXIT(
        {
          VPV->dump();
          exit(0);
        },
        testing::ExitedWithCode(0), "EMIT <badref> = add ir<1>, ir<%a>");

    // Test VPRecipeBase::dump().
    VPRecipeBase *R = I1;
    EXPECT_EXIT(
        {
          R->dump();
          exit(0);
        },
        testing::ExitedWithCode(0), "EMIT <badref> = add ir<1>, ir<%a>");
  }
  // Check printing I2.
  {
    // Use EXPECT_EXIT to capture stderr and compare against expected output.
    //
    // Test VPValue::dump().
    VPValue *VPV = I2;
    EXPECT_EXIT(
        {
          VPV->dump();
          exit(0);
        },
        testing::ExitedWithCode(0), "EMIT <badref> = mul <badref>, <badref>");

    // Test VPRecipeBase::dump().
    VPRecipeBase *R = I2;
    EXPECT_EXIT(
        {
          R->dump();
          exit(0);
        },
        testing::ExitedWithCode(0), "EMIT <badref> = mul <badref>, <badref>");
  }

  delete I2;
  delete I1;
  delete AI;
}

#endif

TEST_F(VPRecipeTest, CastVPReductionRecipeToVPUser) {
  IntegerType *Int32 = IntegerType::get(C, 32);
  VPValue *ChainOp = getPlan().getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPValue *VecOp = getPlan().getOrAddLiveIn(ConstantInt::get(Int32, 2));
  VPValue *CondOp = getPlan().getOrAddLiveIn(ConstantInt::getTrue(C));
  VPReductionRecipe Recipe(RecurKind::Add, FastMathFlags(), ChainOp, VecOp,
                           CondOp, RdxUnordered{});
  checkVPRecipeCastImpl<VPReductionRecipe, VPUser>(&Recipe);
  EXPECT_TRUE(isa<VPUser>(&Recipe));
  VPRecipeBase *BaseR = &Recipe;
  EXPECT_TRUE(isa<VPUser>(BaseR));
}

TEST_F(VPRecipeTest, CastVPReductionEVLRecipeToVPUser) {
  IntegerType *Int32 = IntegerType::get(C, 32);
  VPValue *ChainOp = getPlan().getOrAddLiveIn(ConstantInt::get(Int32, 1));
  VPValue *VecOp = getPlan().getOrAddLiveIn(ConstantInt::get(Int32, 2));
  VPValue *CondOp = getPlan().getOrAddLiveIn(ConstantInt::getTrue(C));
  VPReductionRecipe Recipe(RecurKind::Add, FastMathFlags(), ChainOp, VecOp,
                           CondOp, RdxUnordered{});
  VPValue *EVL = getPlan().getOrAddLiveIn(ConstantInt::get(Int32, 0));
  VPReductionEVLRecipe EVLRecipe(Recipe, *EVL, CondOp);
  checkVPRecipeCastImpl<VPReductionEVLRecipe, VPUser>(&EVLRecipe);
}
} // namespace

struct VPDoubleValueDef : public VPRecipeBase {
  VPDoubleValueDef(ArrayRef<VPValue *> Operands, Type *Ty)
      : VPRecipeBase(VPRecipeBase::VPInterleaveSC, Operands) {
    new VPMultiDefValue(this, /*UV=*/nullptr, Ty);
    new VPMultiDefValue(this, /*UV=*/nullptr, Ty);
  }

  VPRecipeBase *clone() override { return nullptr; }

  void execute(struct VPTransformState &State) override {}
#if !defined(NDEBUG) || defined(LLVM_ENABLE_DUMP)
  void printRecipe(raw_ostream &O, const Twine &Indent,
                   VPSlotTracker &SlotTracker) const override {}
#endif
};

namespace {

TEST(VPDoubleValueDefTest, traverseUseLists) {
  // Check that the def-use chains of a multi-def can be traversed in both
  // directions.

  // Create a new VPRecipeBase which defines 2 values and has 2 operands.
  LLVMContext C;
  IntegerType *Int32 = IntegerType::get(C, 32);
  VPInstructionWithType Op0(VPInstruction::StepVector, {}, Int32);
  VPInstructionWithType Op1(VPInstruction::StepVector, {}, Int32);
  VPDoubleValueDef DoubleValueDef({&Op0, &Op1}, IntegerType::get(C, 32));

  // Create a new users of the defined values.
  VPInstruction I1(Instruction::Add,
                   {DoubleValueDef.getVPValue(0), DoubleValueDef.getVPValue(1)},
                   VPIRFlags::getDefaultFlags(Instruction::Add));
  VPInstruction I2(Instruction::Freeze, {DoubleValueDef.getVPValue(0)});
  VPInstruction I3(Instruction::Freeze, {DoubleValueDef.getVPValue(1)});

  // Check operands of the VPRecipeBase (traversing upwards).
  SmallVector<VPValue *, 4> DoubleOperands(DoubleValueDef.op_begin(),
                                           DoubleValueDef.op_end());
  EXPECT_EQ(2u, DoubleOperands.size());
  EXPECT_EQ(&Op0, DoubleOperands[0]);
  EXPECT_EQ(&Op1, DoubleOperands[1]);

  // Check users of the defined values (traversing downwards).
  SmallVector<VPUser *, 4> DoubleValueDefV0Users(
      DoubleValueDef.getVPValue(0)->user_begin(),
      DoubleValueDef.getVPValue(0)->user_end());
  EXPECT_EQ(2u, DoubleValueDefV0Users.size());
  EXPECT_EQ(&I1, DoubleValueDefV0Users[0]);
  EXPECT_EQ(&I2, DoubleValueDefV0Users[1]);

  SmallVector<VPUser *, 4> DoubleValueDefV1Users(
      DoubleValueDef.getVPValue(1)->user_begin(),
      DoubleValueDef.getVPValue(1)->user_end());
  EXPECT_EQ(2u, DoubleValueDefV1Users.size());
  EXPECT_EQ(&I1, DoubleValueDefV1Users[0]);
  EXPECT_EQ(&I3, DoubleValueDefV1Users[1]);

  // Now check that we can get the right VPRecipeBase for each defined value.
  EXPECT_EQ(&DoubleValueDef, I1.getOperand(0)->getDefiningRecipe());
  EXPECT_EQ(&DoubleValueDef, I1.getOperand(1)->getDefiningRecipe());
  EXPECT_EQ(&DoubleValueDef, I2.getOperand(0)->getDefiningRecipe());
  EXPECT_EQ(&DoubleValueDef, I3.getOperand(0)->getDefiningRecipe());
}

TEST_F(VPRecipeTest, CastToVPSingleDefRecipe) {
  IntegerType *Int32 = IntegerType::get(C, 32);
  VPValue *Start = getPlan().getOrAddLiveIn(ConstantInt::get(Int32, 0));
  VPCurrentIterationPHIRecipe R(Start, {});
  VPRecipeBase *B = &R;
  EXPECT_TRUE(isa<VPSingleDefRecipe>(B));
  // TODO: check other VPSingleDefRecipes.
}

TEST_F(VPInstructionTest, VPSymbolicValueMaterialization) {
  VPlan &Plan = getPlan();

  // Initially, VF is not materialized.
  EXPECT_FALSE(Plan.getVF().isMaterialized());

  // Create a recipe that uses VF.
  VPValue *VF = &Plan.getVF();
  VPInstruction *I =
      new VPInstruction(VPInstruction::ExplicitVectorLength, {VF});
  VPBasicBlock &VPBB = *Plan.createVPBasicBlock("");
  VPBB.appendRecipe(I);

  // Replace VF with a constant.
  VF->replaceAllUsesWith(Plan.getConstantInt(64, 1));

  // Now VF should be materialized.
  EXPECT_TRUE(Plan.getVF().isMaterialized());
}

using VPUtilsTest = VPlanTestBase;

TEST_F(VPUtilsTest, IsUniformAcrossVFsAndUFsForSingleScalarOpcodes) {
  VPlan &Plan = getPlan();
  IntegerType *Int32 = IntegerType::get(C, 32);

  // Recipes in the entry/preheader are treated as uniform if their operands
  // are; use a separate block connected to the entry so the opcode-based
  // uniformity checks are exercised.
  VPBasicBlock *Body = Plan.createVPBasicBlock("body");
  VPBlockUtils::connectBlocks(Plan.getEntry(), Body);
  VPBuilder Builder(Body);

  // isSingleScalar opcode without operands.
  VPInstruction *VScale = Builder.createVScale(Int32);
  EXPECT_TRUE(vputils::isUniformAcrossVFsAndUFs(VScale));

  // isSingleScalar opcode with a uniform operand.
  VPInstruction *EVL = Builder.createNaryOp(VPInstruction::ExplicitVectorLength,
                                            {&Plan.getVF()});
  EXPECT_TRUE(vputils::isUniformAcrossVFsAndUFs(EVL));

  // isVectorToScalar opcode with a uniform operand.
  VPInstruction *FirstActiveLane = Builder.createNaryOp(
      VPInstruction::FirstActiveLane, {&Plan.getVF()}, Int32);
  EXPECT_TRUE(vputils::isUniformAcrossVFsAndUFs(FirstActiveLane));

  // StepVector produces a distinct value per lane and is non-uniform; use it
  // as the non-single-scalar operand in the negative cases below.
  VPInstruction *StepVector =
      Builder.createNaryOp(VPInstruction::StepVector, {}, Int32);
  EXPECT_FALSE(vputils::isUniformAcrossVFsAndUFs(StepVector));

  // isSingleScalar opcode with a non-single-scalar operand.
  VPInstruction *EVLNonUniform =
      Builder.createNaryOp(VPInstruction::ExplicitVectorLength, {StepVector});
  EXPECT_FALSE(vputils::isUniformAcrossVFsAndUFs(EVLNonUniform));

  // isVectorToScalar opcode with a non-single-scalar operand.
  VPInstruction *FirstActiveLaneNonUniform =
      Builder.createNaryOp(VPInstruction::FirstActiveLane, {StepVector}, Int32);
  EXPECT_FALSE(vputils::isUniformAcrossVFsAndUFs(FirstActiveLaneNonUniform));
}

TEST_F(VPBasicBlockTest, VPRegionValueClonePropagatesMaterialized) {
  VPlan &Plan = getPlan();
  VPBasicBlock *Preheader = Plan.getEntry();
  VPBasicBlock *Header = Plan.createVPBasicBlock("header");
  VPBasicBlock *Latch = Plan.createVPBasicBlock("latch");
  VPRegionBlock *Region = Plan.createLoopRegion(Type::getInt32Ty(C), DebugLoc(),
                                                "loop", Header, Latch);
  VPBlockUtils::connectBlocks(Header, Latch);
  VPBlockUtils::connectBlocks(Preheader, Region);
  VPBlockUtils::connectBlocks(Region, Plan.getScalarHeader());

  VPRegionValue *CanIV = Region->getCanonicalIV();
  EXPECT_TRUE(isa<VPSymbolicValue>(CanIV));
  EXPECT_FALSE(CanIV->isMaterialized());

  // Materialize the canonical IV by replacing all uses, then verify clone
  // propagates the materialized state.
  CanIV->replaceAllUsesWith(Plan.getConstantInt(32, 0));
  EXPECT_TRUE(CanIV->isMaterialized());

  std::unique_ptr<VPlan> Clone(Plan.duplicate());
  VPRegionValue *ClonedCanIV = Clone->getVectorLoopRegion()->getCanonicalIV();
  EXPECT_NE(CanIV, ClonedCanIV);
  EXPECT_TRUE(ClonedCanIV->isMaterialized());
}

#if defined(GTEST_HAS_DEATH_TEST) && !defined(NDEBUG)
TEST_F(VPInstructionTest, VPSymbolicValueConstructUserAfterMaterialization) {
  VPlan &Plan = getPlan();

  // Materialize VF by replacing all uses.
  VPValue *VF = &Plan.getVF();
  VF->replaceAllUsesWith(Plan.getConstantInt(64, 1));
  EXPECT_TRUE(Plan.getVF().isMaterialized());

  // Adding a new user to a materialized value should crash.
  EXPECT_DEATH(new VPInstruction(VPInstruction::ExplicitVectorLength, {VF}),
               "accessing materialized symbolic value");
}

TEST_F(VPInstructionTest, VPSymbolicValueAddOperandAfterMaterialization) {
  VPlan &Plan = getPlan();

  IntegerType *I64 = IntegerType::get(C, 64);
  VPValue *Seed = Plan.getOrAddLiveIn(ConstantInt::get(I64, 0));
  std::unique_ptr<VPInstruction> BV(
      new VPInstruction(VPInstruction::BuildVector, {Seed}));

  // Materialize VF by replacing all uses.
  VPValue *VF = &Plan.getVF();
  VF->replaceAllUsesWith(Plan.getConstantInt(64, 1));
  EXPECT_TRUE(Plan.getVF().isMaterialized());

  // Appending a new operand referencing the materialized VF should crash.
  EXPECT_DEATH(BV->addOperand(VF), "accessing materialized symbolic value");
}
#endif

} // namespace
} // namespace llvm
