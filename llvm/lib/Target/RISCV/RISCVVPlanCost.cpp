//===- RISCVVPlanCost.cpp - Resource and dependency cost model
//--------------===//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVVPlanCost.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/StringSwitch.h"
#include <algorithm>
using namespace llvm;
using namespace llvm::vplan;
namespace {
Error unsupported(const Twine &Why) {
  return createStringError(inconvertibleErrorCode(), Why);
}
bool isBody(const Analytics &A, const InstructionInfo &I) {
  return any_of(A.Blocks, [&](const Block &B) {
    return B.ID == I.Block && B.Role == "body";
  });
}
uint64_t chunks(const Analytics &A, const InstructionInfo &I) {
  return std::max<uint64_t>(1, uint64_t(I.Group8) * A.VLen / (8 * 128));
}
bool plainDef(const InstructionInfo &I) {
  unsigned Count = 0;
  const Operand *Def = nullptr;
  for (const auto &O : I.Operands)
    if (O.Vector && O.Def) {
      Def = &O;
      ++Count;
    }
  return Count == 1 && !Def->Implicit && !Def->Dead && !Def->EarlyClobber &&
         !Def->SubReg && !I.Masked && I.Group8 > 0 && I.SEW >= 8 && !I.Barrier;
}
StringRef loadKind(const InstructionInfo &I) {
  if (!plainDef(I))
    return {};
  StringRef K =
      StringSwitch<StringRef>(StringRef(I.Base).split('_').first)
          .Cases({"VLE8", "VLE16", "VLE32", "VLE64"}, "load")
          .Cases({"VL1RE8", "VL2RE8", "VL4RE8", "VL8RE8", "VL1RE16", "VL2RE16",
                  "VL4RE16", "VL8RE16", "VL1RE32", "VL2RE32", "VL4RE32",
                  "VL8RE32", "VL1RE64", "VL2RE64", "VL4RE64", "VL8RE64"},
                 "load")
          .Cases({"VFADD", "VFSUB", "VFRSUB", "VFMUL"}, "fp")
          .Cases({"VFMACC", "VFNMACC", "VFMSAC", "VFNMSAC", "VFMADD", "VFNMADD",
                  "VFMSUB", "VFNMSUB"},
                 "fused")
          .Cases({"VADD", "VSUB", "VRSUB", "VAND", "VOR", "VXOR", "VSLL",
                  "VSRL", "VSRA", "VMIN", "VMINU", "VMAX", "VMAXU"},
                 "integer")
          .Cases({"VMUL", "VMULH", "VMULHU", "VMULHSU"}, "multiply")
          .Default("");
  if ((K == "fp" || K == "fused") && I.SEW < 32)
    return {};
  if (K == "load" && (!I.Load || I.Store || I.Stack))
    return {};
  return K;
}
unsigned recurrenceKind(const InstructionInfo &I) {
  if (!plainDef(I) || (I.SEW != 32 && I.SEW != 64))
    return 0;
  return StringSwitch<unsigned>(StringRef(I.Base).split('_').first)
      .Cases({"VFADD", "VFSUB", "VFMUL"}, 1)
      .Cases({"VFMACC", "VFNMACC", "VFMSAC", "VFNMSAC"}, 2)
      .Default(0);
}
bool valueEdge(const Analytics &A, const Edge &E, bool Fused) {
  const auto &Use = A.Instructions[E.Destination].Operands[E.OperandIndex];
  return E.WholeValue && Use.Vector && !Use.Implicit && !Use.Undef &&
         !Use.SubReg && (Fused || !Use.Tied);
}
// The policy retains the original narrow recurrence and load-use eligibility.
// Generic physical dependency facts are collected independently by analytics.
void dependencyCosts(const Analytics &A, BodyCost &C) {
  if (A.DependencyCoverage != "single-block-distance-0-1")
    return;
  std::vector<SmallVector<int64_t>> Preds(A.Instructions.size());
  for (const auto &E : A.Edges) {
    const auto &Src = A.Instructions[E.Source];
    const auto &Dst = A.Instructions[E.Destination];
    if (isBody(A, Dst) && recurrenceKind(Src) && recurrenceKind(Dst) &&
        valueEdge(A, E, recurrenceKind(Dst) == 2) &&
        !is_contained(Preds[E.Destination], E.Source))
      Preds[E.Destination].push_back(E.Source);
  }
  for (const auto &E : A.Edges) {
    if (E.Distance != 1 || !is_contained(Preds[E.Destination], E.Source))
      continue;
    int64_t Current = E.Source;
    InstructionCost Bound = 0;
    while (true) {
      const auto &I = A.Instructions[Current];
      Bound += InstructionCost(recurrenceKind(I) == 2 ? 80 : 48) +
               InstructionCost(chunks(A, I) - 1) * 32;
      if (Current == E.Destination) {
        C.Recurrence = std::max(C.Recurrence, Bound);
        break;
      }
      std::optional<int64_t> Previous;
      bool Branching = false;
      for (int64_t P : Preds[Current])
        if (P < Current) {
          if (Previous) {
            Branching = true;
            break;
          }
          Previous = P;
        }
      if (Branching || !Previous || *Previous < E.Destination)
        break;
      Current = *Previous;
    }
  }
  struct Ready {
    bool Known = false;
    InstructionCost First = 0, Last = 0;
  };
  std::vector<Ready> Values(A.Instructions.size());
  for (const auto &I : A.Instructions) {
    if (!isBody(A, I))
      continue;
    StringRef Kind = loadKind(I);
    if (Kind.empty())
      continue;
    Ready R;
    R.Known = Kind == "load";
    for (const auto &E : A.Edges) {
      if (E.Destination != I.ID || E.Distance ||
          !valueEdge(A, E, Kind == "fused"))
        continue;
      const auto &Src = A.Instructions[E.Source];
      const auto &Prev = Values[E.Source];
      if (!Prev.Known || Src.Group8 != I.Group8 || Src.SEW != I.SEW)
        continue;
      R.Known = true;
      R.First = std::max(R.First, Prev.First);
      R.Last = std::max(R.Last, Prev.Last);
    }
    if (!R.Known)
      continue;
    unsigned Latency = StringSwitch<unsigned>(Kind)
                           .Case("load", 4)
                           .Case("fp", 3)
                           .Case("fused", 5)
                           .Case("integer", 1)
                           .Case("multiply", 3)
                           .Default(0);
    R.First += InstructionCost(Latency) * 16;
    R.Last = std::max(R.Last + InstructionCost(Latency) * 16,
                      R.First + InstructionCost(chunks(A, I) - 1) * 16);
    Values[I.ID] = R;
    if (Kind != "load")
      C.LoadUse = std::max(C.LoadUse, R.Last);
  }
}
} // namespace

Expected<BodyCost> llvm::vplan::computeBodyCost(const Analytics &A) {
  if (A.Version != 2 || A.Stage != "post-ra-cleanup" || !A.Error.empty())
    return unsupported(Twine("invalid analytics: ") + A.Error);
  if (A.CPU != "xiangshan-kunminghu" || A.VLen <= 0 || A.VLen > 65536 ||
      A.Width <= 0 || A.Width > UINT32_MAX || A.MaxTripCount < 0 || A.VF <= 0)
    return unsupported("unsupported target or loop configuration");
  for (auto [Index, I] : enumerate(A.Instructions)) {
    if (I.ID != int64_t(Index) || I.Group8 < 0 || I.Group8 > 64 || I.Bytes < 0)
      return unsupported("malformed instruction analytics");
  }
  for (const auto &E : A.Edges)
    if (E.Source < 0 || E.Destination < 0 ||
        uint64_t(E.Source) >= A.Instructions.size() ||
        uint64_t(E.Destination) >= A.Instructions.size() ||
        E.OperandIndex < 0 ||
        uint64_t(E.OperandIndex) >=
            A.Instructions[E.Destination].Operands.size() ||
        (E.Distance != 0 && E.Distance != 1) ||
        (!E.Distance && E.Source >= E.Destination))
      return unsupported("malformed dependency analytics");
  BodyCost C;
  InstructionCost Unit = 0, Masked = 0, Strided = 0, Indexed = 0;
  InstructionCost Integer = 0, FP = 0, Fused = 0, Loads = 0, Stores = 0;
  InstructionCost ExtraStrided = 0, PredicateResidual = 0;
  DenseMap<int64_t, InstructionCost> PredicateShared;
  bool SeenBody = false;
  for (const auto &I : A.Instructions) {
    if (!isBody(A, I) || I.Meta)
      continue;
    SeenBody = true;
    StringRef K(I.Category);
    if (I.Barrier || K == "unknown")
      return unsupported(Twine("unsupported instruction ") + I.Opcode);
    if (K == "scalar") {
      C.Scalar += 8;
      continue;
    }
    if (K == "config") {
      (I.ConfigUnused ? C.Scalar : C.Configuration) += 16;
      continue;
    }
    if (K == "spill") {
      InstructionCost W = I.Bytes;
      if (I.ScalableBytes)
        W = W * A.VLen / 128;
      else
        W /= 2;
      C.Spill += std::max(InstructionCost(8), W);
      continue;
    }
    if (I.Group8 <= 0 || (I.Group8 & (I.Group8 - 1)))
      return unsupported("invalid LMUL/register group");
    uint64_t Group = I.Group8;
    StringRef Family = StringRef(I.Base).split('_').first;
    if ((K == "integer" || K == "fp" || K == "fused") &&
        (Family.starts_with("VW") || Family.starts_with("VFW") ||
         Family.starts_with("VNSR") || Family.starts_with("VNCLIP") ||
         Family.starts_with("VFNC")))
      Group *= 2;
    uint64_t RawWork = Group * uint64_t(A.VLen) / 128;
    if (K == "strided" || K == "indexed") {
      if (I.SEW != 8 && I.SEW != 16 && I.SEW != 32 && I.SEW != 64)
        return unsupported("invalid memory SEW");
      RawWork = Group * uint64_t(A.VLen) / I.SEW;
    }
    if (K == "mask_logical")
      RawWork = Group * uint64_t(A.VLen) / (8 * 128);
    InstructionCost W = std::max<uint64_t>(8, RawWork);
    if (K == "copy") {
      C.Movement += I.SameCopy ? InstructionCost(0) : InstructionCost(RawWork);
      continue;
    }
    if (K == "slide") {
      C.Movement +=
          W * 2 + InstructionCost(std::max<int64_t>(I.Group8 - 8, 0)) * 2;
      continue;
    }
    if (K == "fp_div") {
      if (I.SEW != 16 && I.SEW != 32 && I.SEW != 64)
        return unsupported("invalid division SEW");
      C.Divider += W * 2 * (I.SEW == 16 ? 29 : I.SEW == 32 ? 25 : 37);
      continue;
    }
    if (K == "integer" || K == "mask_logical") {
      Integer += W;
      continue;
    }
    if (K == "fp") {
      FP += W;
      continue;
    }
    if (K == "fused") {
      Fused += W;
      continue;
    }
    if (K != "unit" && K != "strided" && K != "indexed")
      return unsupported("unknown operation category");
    if (I.Load == I.Store)
      return unsupported("ambiguous memory direction");
    (K == "unit" ? Unit : K == "strided" ? Strided : Indexed) += W;
    if (I.Masked)
      Masked += W;
    InstructionCost Demand = K == "unit" ? W : W * 2;
    if (I.Masked)
      Demand += W;
    (I.Load ? Loads : Stores) += Demand;
    if (I.Group8 > 8) {
      InstructionCost Extra = W * (I.Group8 - 8);
      if (K == "strided")
        ExtraStrided += Extra;
      if (I.Masked) {
        if (!I.Predicate)
          PredicateResidual += Extra;
        else {
          InstructionCost Shared = Extra / 4;
          PredicateResidual += Extra - Shared;
          PredicateShared[I.Predicate] =
              std::max(PredicateShared[I.Predicate], Shared);
        }
      }
    }
  }
  if (!SeenBody)
    return unsupported("empty or missing candidate body");
  for (const auto &P : PredicateShared)
    PredicateResidual += P.second;
  C.Memory = Unit + Masked + (Strided + Indexed) * 2;
  C.Memory =
      std::min(C.Memory, std::max({Loads, Stores, C.Memory - C.Memory / 8}));
  C.Memory += ExtraStrided / 32 + PredicateResidual / 64;
  C.Arithmetic = Integer * 2 + (FP + Fused) * 4;
  dependencyCosts(A, C);
  C.Total = (std::max({C.Memory, C.Arithmetic, C.Movement, C.Scalar, C.Divider,
                       C.Recurrence, C.LoadUse}) +
             C.Spill + C.Configuration) /
            16;
  return C;
}

json::Object llvm::vplan::costBreakdown(const BodyCost &C) {
  // Bound values are in sixteenth units before the final body division.
  return json::Object{{"memory", costQuarters(C.Memory)},
                      {"arithmetic", costQuarters(C.Arithmetic)},
                      {"movement", costQuarters(C.Movement)},
                      {"scalar", costQuarters(C.Scalar)},
                      {"divider", costQuarters(C.Divider)},
                      {"recurrence", costQuarters(C.Recurrence)},
                      {"load_use", costQuarters(C.LoadUse)},
                      {"spill", costQuarters(C.Spill)},
                      {"configuration", costQuarters(C.Configuration)},
                      {"bound_divisor", 64}};
}
