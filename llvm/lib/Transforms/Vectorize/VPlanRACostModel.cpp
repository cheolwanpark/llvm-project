//===- VPlanRACostModel.cpp - Research hook for RA-informed costs -----------===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "VPlanRACostModel.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringSwitch.h"
#include <algorithm>
#include <array>

void llvm::detail::VPlanRAPredicateCost::add(InstructionCost Delay,
                                          int64_t Predicate) {
  if (!Predicate || !SharedDivisor) {
    Residual += Delay;
    return;
  }
  InstructionCost PredicateDelay = Delay / SharedDivisor;
  // Subtract the shared part rather than separately multiplying fractions:
  // the residual stays nonnegative, and one access retains its entire delay
  // even when the input saturated or the shared fraction was rounded down.
  Residual += Delay - PredicateDelay;
  Shared[Predicate] = std::max(Shared[Predicate], PredicateDelay);
}

llvm::InstructionCost llvm::detail::VPlanRAPredicateCost::getCost() const {
  InstructionCost Total = Residual;
  for (const auto &Entry : Shared)
    Total += Entry.second;
  return Total;
}

llvm::InstructionCost llvm::costWithRAFeatures(
    const VPlan &Plan, ElementCount VF, InstructionCost OriginalCost,
    const json::Object &Features) {
  // Scalar reference costs, width normalization and tails stay with the caller.
  const json::Object *R = Features.getObject("resource_demand");
  if (VF.isScalar() || !R || R->getInteger("version") != 1 ||
      R->getBoolean("supported") != true)
    return OriginalCost;

  static constexpr const char *Keys[] = {
      "unit8", "spill8", "strided8", "indexed8", "masked8",
      "integer8", "fp8", "fused8", "scalar8", "config8"};
  std::array<InstructionCost, 10> Work;
  for (unsigned I = 0; I != Work.size(); ++I) {
    auto Value = R->getInteger(Keys[I]);
    if (!Value || *Value < 0)
      return OriginalCost;
    Work[I] = *Value;
  }

  // Optional version-one classification. Require a complete, nonnegative
  // partition of the raw configuration work before constructing saturating
  // costs. Missing, partial or inconsistent classifications conservatively
  // keep the existing universally additive configuration service.
  InstructionCost ConfigUnused = 0, ConfigAdditive = Work[9];
  auto Unused = R->getInteger("config_unused8");
  auto Additive = R->getInteger("config_additive8");
  int64_t Config = *R->getInteger("config8");
  if (Unused && Additive && *Unused >= 0 && *Additive >= 0 &&
      *Unused <= Config && *Additive == Config - *Unused) {
    ConfigUnused = *Unused;
    ConfigAdditive = *Additive;
  }

  // Hypothesis: successive chunks of a masked memory instruction wait for
  // predicate delivery. Model the aggregate service as triangular in grouping,
  // on the memory resource so arithmetic and copies can overlap it.
  // With work8 = 8 * G,
  // work8 * (group8 - 8) / 1024 = G * (G - 1) / 16: an eighth cost unit per
  // pair of register chunks. Fractional groups have no inter-chunk wait.
  // work8 already reflects SEW for strided/indexed accesses; do not estimate
  // active mask density or apply this term to masked arithmetic or spills.
  // Aggregate-only observations retain their existing cost behavior.
  // Retain the fixed one-quarter shared, three-quarter per-access split:
  // the largest delivery term for each proven predicate plus every residual.
  // Missing/zero identities keep independent service for older observations.
  // Ordinary memory work still counts every access. The combined demand stays
  // on memory so arithmetic and copies can overlap it.
  detail::VPlanRAPredicateCost PredicateCost(/*SharedDivisor=*/4);
  // Strided element service grows with the additional register chunks in an
  // instruction. At coefficient 1/8, the extra memory demand in cost units is
  // (work8 / 8) * max(group8 / 8 - 1, 0) / 8. Keep it inside the resource
  // maximum so arithmetic can overlap it; spills remain additive.
  // SEW already affects work8 and must not be counted twice.
  InstructionCost StridedDemand = 0;
  // Copies and slides share one movement resource, preserving their sum.
  // Copies retain half a unit per transferred chunk. Slides add one unit per
  // chunk plus one per additional LMUL register boundary; fractional LMUL
  // has no boundary. Movement overlaps memory, arithmetic, scalar throughput
  // and the conservative recurrence bound. Spills remain additive.
  InstructionCost Movement = 0;
  // Provisional divider service per 128-bit chunk: 29/25/37 units for
  // e16/e32/e64. RISCVSchedSiFiveP600.td (also P800) assigns these explicit
  // occupancies to a separate vector FP divider, with identical VV/VF writes
  // and an LMUL issue floor. Kunminghu has NoSchedModel and the frozen tuning
  // candidates contain no divide: this is an uncalibrated cross-target prior,
  // not measured Kunminghu throughput or a scalar latency estimate.
  // Fractional groups issue one chunk in the collector. Masked and reverse
  // forms retain full service; neither mask density nor operand values are
  // observed. Independent division instructions add on their own resource,
  // competing with the existing demands without a new dependency floor.
  InstructionCost Divider = 0;
  const json::Array *Operations = R->getArray("operations");
  // Direction is an optional extension of version-one observations. Apply
  // separate service only when every ordinary access supplies it, and its
  // access-class totals agree with the unchanged aggregate observations.
  // Older and partially extended observations keep symmetric memory demand.
  bool CompleteMemoryDirections = Operations != nullptr;
  bool HasMemoryDirection = false;
  std::array<InstructionCost, 4> ObservedMemory = {0, 0, 0, 0};
  InstructionCost Loads = 0, Stores = 0;
  if (R->get("operations") && !Operations)
    return OriginalCost;
  if (Operations) {
    for (const json::Value &Value : *Operations) {
      const json::Object *Op = Value.getAsObject();
      if (!Op)
        return OriginalCost;
      auto Kind = Op->getString("kind");
      if (!Kind)
        return OriginalCost;
      if (*Kind == "fp_div") {
        auto SEW = Op->getInteger("sew");
        auto Group = Op->getInteger("group8");
        auto OpWork = Op->getInteger("work8");
        auto Masked = Op->getBoolean("masked");
        auto Form = Op->getString("form");
        if (!SEW || (*SEW != 16 && *SEW != 32 && *SEW != 64) ||
            !Group || (*Group != 1 && *Group != 2 && *Group != 4 &&
                       *Group != 8 && *Group != 16 && *Group != 32 &&
                       *Group != 64) ||
            !OpWork || *OpWork < 0 || !Masked ||
            !Form || (*Form != "vv" && *Form != "vf" &&
                      *Form != "reverse_vf"))
          return OriginalCost;
        int64_t Service = *SEW == 16 ? 29 : (*SEW == 32 ? 25 : 37);
        // work8 is eight times the chunk demand; multiply by two to use
        // the same sixteenth-unit accumulator as the competing resources.
        Divider += InstructionCost(*OpWork) * 2 * Service;
        continue;
      }
      if (*Kind == "slide" || *Kind == "copy") {
        auto Group = Op->getInteger("group8");
        auto OpWork = Op->getInteger("work8");
        if (!Group || (*Group != 1 && *Group != 2 && *Group != 4 &&
                       *Group != 8 && *Group != 16 && *Group != 32 &&
                       *Group != 64) ||
            !OpWork || *OpWork < 0)
          return OriginalCost;
        if (*Kind == "copy") {
          Movement += InstructionCost(*OpWork);
        } else {
          Movement += InstructionCost(*OpWork) * 2;
          if (*OpWork && *Group > 8)
            Movement += InstructionCost(*Group - 8) * 2;
        }
        continue;
      }
      if (*Kind != "unit" && *Kind != "strided" && *Kind != "indexed")
        continue;
      auto Masked = Op->getBoolean("masked");
      if (!Masked)
        return OriginalCost;
      auto Direction = Op->getString("direction");
      if (Op->get("direction") &&
          (!Direction || (*Direction != "load" && *Direction != "store")))
        return OriginalCost;
      if (!Direction)
        CompleteMemoryDirections = false;
      else
        HasMemoryDirection = true;
      if (!*Masked && *Kind != "strided" && !Direction)
        continue;
      auto Group = Op->getInteger("group8");
      auto OpWork = Op->getInteger("work8");
      if (!Group || (*Group != 1 && *Group != 2 && *Group != 4 &&
                     *Group != 8 && *Group != 16 && *Group != 32 &&
                     *Group != 64) ||
          !OpWork || *OpWork < 0)
        return OriginalCost;
      if (*Kind == "strided" || Direction) {
        auto SEW = Op->getInteger("sew");
        if (!SEW || (*SEW != 8 && *SEW != 16 && *SEW != 32 && *SEW != 64))
          return OriginalCost;
      }
      if (Direction) {
        unsigned Class = *Kind == "unit" ? 0 : (*Kind == "strided" ? 1 : 2);
        InstructionCost Demand = *OpWork;
        ObservedMemory[Class] += Demand;
        if (*Masked)
          ObservedMemory[3] += Demand;
        // Same base service coefficients as the aggregate model, in
        // sixteenth units. Mask presence retains its independent demand;
        // predicate sharing and additional strided service stay below.
        if (Class != 0)
          Demand *= 2;
        if (*Masked)
          Demand += InstructionCost(*OpWork);
        (*Direction == "load" ? Loads : Stores) += Demand;
      }
      int64_t Predicate = 0;
      if (*Masked && Op->get("predicate_id")) {
        auto ID = Op->getInteger("predicate_id");
        if (!ID || *ID < 0)
          return OriginalCost;
        Predicate = *ID;
      }
      if (*Group > 8) {
        InstructionCost Extra = InstructionCost(*OpWork) * (*Group - 8);
        if (*Masked)
          PredicateCost.add(Extra, Predicate);
        if (*Kind == "strided")
          StridedDemand += Extra;
      }
    }
  }
  InstructionCost MaskedSerial = PredicateCost.getCost();
  // Convert to sixteenth units after accumulation, keeping sub-quarter work
  // until the final body division. All arithmetic above saturates safely.
  MaskedSerial /= 64;
  StridedDemand /= 32;

  // Conservative latency prior for proven loop-carried vector value chains:
  // 3 per FP add/subtract/multiply, 5 per accumulating FMA, and 2 per extra
  // 128-bit service chunk. Independent chains overlap, so take their maximum.
  // Missing observations retain aggregate-only behavior. Malformed observations
  // and unsupported resource feedback retain the original body cost.
  InstructionCost Recurrence = 0;
  const json::Array *Chains = R->getArray("recurrences");
  if (R->get("recurrences") && !Chains)
    return OriginalCost;
  if (Chains) {
    for (const json::Value &Value : *Chains) {
      const json::Object *Chain = Value.getAsObject();
      if (!Chain)
        return OriginalCost;
      auto FP = Chain->getInteger("fp_steps");
      auto Fused = Chain->getInteger("fused_steps");
      auto Extra = Chain->getInteger("extra_chunks");
      if (!FP || *FP < 0 || !Fused || *Fused < 0 || !Extra || *Extra < 0)
        return OriginalCost;
      // Accumulate directly in sixteenth units using saturating operations.
      InstructionCost Bound = InstructionCost(*FP) * 48 +
                              InstructionCost(*Fused) * 80 +
                              InstructionCost(*Extra) * 32;
      Recurrence = std::max(Recurrence, Bound);
    }
  }

  // Load-rooted, block-local arithmetic paths compete with throughput and
  // recurrence demand; independent paths and fanout are never summed.
  // Optimistic architectural priors in model units: first load result 4,
  // FP add/sub/mul 3, FMA 5, integer ALU 1, multiply 3. NanHu's scalar
  // LoadLatency=4 and ALU/FP writes motivate these priors, not measured RVV
  // Kunminghu timings. FP priors match the existing recurrence model.
  // Assume chunk forwarding at one 128-bit chunk/unit on same-shaped edges.
  // A path's completion is sum(first-chunk latencies) + max(chunks - 1),
  // rather than charging full-register latency at every dependent step.
  // Maintain first and last chunk bounds separately so joins do not combine
  // an unrelated longest path with an unrelated largest chunk count.
  // Only arithmetic endpoints bind: independent loads retain resource costs.
  InstructionCost LoadUse = 0;
  struct ChunkReady {
    InstructionCost First, Last;
  };
  SmallVector<ChunkReady> Ready;
  const json::Array *LoadUses = R->getArray("load_use_nodes");
  if (R->get("load_use_nodes") && !LoadUses)
    return OriginalCost;
  if (LoadUses) {
    for (const json::Value &Value : *LoadUses) {
      const json::Object *Node = Value.getAsObject();
      if (!Node)
        return OriginalCost;
      auto Kind = Node->getString("kind");
      auto Chunks = Node->getInteger("chunks");
      const json::Array *Preds = Node->getArray("predecessors");
      if (!Kind || !Chunks || *Chunks < 1 || !Preds)
        return OriginalCost;
      int64_t Latency = StringSwitch<int64_t>(*Kind)
                            .Case("load", 4)
                            .Case("fp", 3)
                            .Case("fused", 5)
                            .Case("integer", 1)
                            .Case("multiply", 3)
                            .Default(0);
      if (!Latency || ((*Kind == "load") != Preds->empty()))
        return OriginalCost;
      InstructionCost First = 0, Last = 0;
      for (const json::Value &Pred : *Preds) {
        auto Index = Pred.getAsInteger();
        if (!Index || *Index < 0 || uint64_t(*Index) >= Ready.size())
          return OriginalCost;
        First = std::max(First, Ready[*Index].First);
        Last = std::max(Last, Ready[*Index].Last);
      }
      First += InstructionCost(Latency) * 16;
      Last = std::max(Last + InstructionCost(Latency) * 16,
                     First + InstructionCost(*Chunks - 1) * 16);
      Ready.push_back({First, Last});
      if (*Kind != "load")
        LoadUse = std::max(LoadUse, Last);
    }
  }

  // Eighth-unit observations, accumulated in sixteenth units before the
  // final division, retain InstructionCost's quarter-unit precision.
  // ordinary = (unit + masked) / 2 + strided + indexed
  // memory = ordinary + strided_service (legacy observations)
  // Complete directions instead bound ordinary demand by separate services
  // and a shared floor before adding the unchanged strided/predicate service.
  // arithmetic = integer + 2 * (fp + fused)
  // movement = copy_work / 2 + slide_work
  //            + sum(nonzero slides: max(group8 / 8 - 1, 0))
  // scalar = scalar_work / 2 + config_unused
  // divider = sum(divide_work8 / 8 * service(sew))
  // body = max(memory + masked_serial, arithmetic, movement, scalar, recurrence,
  //            divider, load_use)
  //        + spill / 2 + config_additive
  // Hypothesis: recurring scalar throughput can overlap vector execution.
  // Treat it as a competing resource at its existing coefficient. This does
  // not model scalar/vector dependency latency or prove that work is parallel.
  // Proven unused scalar configuration results compete on the scalar resource
  // at the unchanged configuration coefficient. Live or uncertain results,
  // including live AVL production, retain additive service. This overlap prior
  // does not remove VL/VTYPE dependencies or establish their latency.
  // Recurring spill demand remains visible even when arithmetic dominates.
  // Saturating InstructionCost arithmetic keeps even extreme inputs valid.
  InstructionCost Memory = Work[0] + Work[4] + (Work[2] + Work[3]) * 2;
  if (HasMemoryDirection && CompleteMemoryDirections) {
    if (ObservedMemory[0] != Work[0] || ObservedMemory[1] != Work[2] ||
        ObservedMemory[2] != Work[3] || ObservedMemory[3] != Work[4])
      return OriginalCost;
    // Provisional bounded overlap: two chunks/unit on each of the separate
    // load/store resources, with shared service retaining at least 7/8 of
    // the old symmetric demand. NanHu's scalar XS2LD/XS2ST and SiFive P600's
    // vector VLD/VST support the structural separation, not these Kunminghu
    // capacities: Kunminghu has NoSchedModel. A tuning-only dyadic sensitivity
    // check preserved Top-1 at 1/8 overlap; 1/4 and larger worsened it. This
    // conservative positive allowance is a research prior, not CPU cycles.
    // Subtraction avoids multiplying a saturated total before dividing.
    // Round shared service upward in accumulation units; keep fractions until
    // the final body division. Savings are bounded by 1/8 of ordinary demand.
    InstructionCost Shared = Memory - Memory / 8;
    // Independently saturated direction accumulators must not increase the
    // aggregate bound, even at InstructionCost's representational limits.
    Memory = std::min(Memory, std::max({Loads, Stores, Shared}));
  }
  Memory += StridedDemand;
  // integer8 includes mask Boolean work measured in packed 128-bit chunks.
  // The collector already applies its issue floor; use the integer coefficient.
  InstructionCost Arithmetic = Work[5] * 2 + (Work[6] + Work[7]) * 4;
  InstructionCost Body =
      std::max({Memory + MaskedSerial, Arithmetic, Movement,
                Work[8] + ConfigUnused * 2,
                Recurrence, Divider, LoadUse}) +
      Work[1] + ConfigAdditive * 2;
  Body /= 16;
  return Body;
}
