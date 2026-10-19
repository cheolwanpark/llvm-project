"""Continuous counterpart of RISCVVPlanCost.cpp, with shared physical parameters.

Raw geometry and dependency eligibility are fixed. All maxima remain hard maxima;
only InstructionCost's quarter-unit truncation/saturation is deliberately absent.
The compiler is never given these learned costs.
"""
from __future__ import annotations

import math
import torch

from vplan_tools import ToolError

MODEL_VERSION = "rvv-shared-18-v1"
PARAMETERS = (
    "memory_unit", "memory_nonunit", "memory_mask", "strided_group", "masked_group",
    "arithmetic_integer", "arithmetic_fp", "movement_copy", "movement_slide",
    "divider", "spill", "configuration", "latency_load", "latency_fp",
    "latency_fma", "latency_integer", "latency_multiply", "latency_chunk",
)
P = len(PARAMETERS)
DTYPE = torch.float64
LOADS = {f"VLE{s}" for s in (8, 16, 32, 64)} | {
    f"VL{g}RE{s}" for g in (1, 2, 4, 8) for s in (8, 16, 32, 64)}
FP = {"VFADD", "VFSUB", "VFRSUB", "VFMUL"}
FUSED = {"VFMACC", "VFNMACC", "VFMSAC", "VFNMSAC", "VFMADD", "VFNMADD", "VFMSUB", "VFNMSUB"}
INTEGER = {"VADD", "VSUB", "VRSUB", "VAND", "VOR", "VXOR", "VSLL", "VSRL", "VSRA", "VMIN", "VMINU", "VMAX", "VMAXU"}
MULTIPLY = {"VMUL", "VMULH", "VMULHU", "VMULHSU"}


def plain_def(i):
    defs = [o for o in i["Operands"] if o["Vector"] and o["Def"]]
    return (len(defs) == 1 and not any(defs[0][k] for k in
            ("Implicit", "Dead", "EarlyClobber", "SubReg")) and not i["Masked"]
            and i["Group8"] > 0 and i["SEW"] >= 8 and not i["Barrier"])


def recurrence_kind(i):
    if not plain_def(i) or i["SEW"] not in (32, 64):
        return 0
    family = i["Base"].split("_")[0]
    if family in {"VFADD", "VFSUB", "VFMUL"}:
        return 1
    return 2 if family in {"VFMACC", "VFNMACC", "VFMSAC", "VFNMSAC"} else 0


def load_kind(i):
    if not plain_def(i):
        return None
    family = i["Base"].split("_")[0]
    if family in LOADS:
        return "load" if i["Load"] and not i["Store"] and not i["Stack"] else None
    for names, kind in ((FP, "fp"), (FUSED, "fma"), (INTEGER, "integer"), (MULTIPLY, "multiply")):
        if family in names:
            return None if kind in ("fp", "fma") and i["SEW"] < 32 else kind
    return None


def value_edge(a, e, fused):
    use = a["Instructions"][e["Destination"]]["Operands"][e["OperandIndex"]]
    return (e["WholeValue"] and use["Vector"] and not any(use[k] for k in
            ("Implicit", "Undef", "SubReg")) and (fused or not use["Tied"]))


def needs_scalar_reference(a):
    """Require a tail reference unless both the loop and score omit its work."""
    if not a["MaxTripCount"]:
        return False
    if not a["ScalarTail"] and (a["ScalableVF"] or a["VF"] != 1):
        return False
    # A divisible upper bound alone cannot prove that the real tail is empty.
    return not (a["ExactTripCount"] > 0
                and a["ExactTripCount"] % a["Width"] == 0
                and a["MaxTripCount"] % a["Width"] == 0)


def same_context(a, b):
    return (all(a[k] == b[k] for k in
                ("RunID", "Function", "CPU", "VLen", "MaxTripCount", "ExactTripCount"))
            and a["Candidate"].rsplit(":", 2)[0] == b["Candidate"].rsplit(":", 2)[0])


def validate_analytics(a):
    try:
        if a["Version"] != 2 or a["Stage"] != "post-ra-cleanup" or a["Error"]:
            raise ValueError("invalid analytics: " + str(a.get("Error", "")))
        if (a["CPU"] != "xiangshan-kunminghu" or not 0 < a["VLen"] <= 65536
                or not 0 < a["Width"] <= 2**32 - 1 or a["MaxTripCount"] < 0
                or a["ExactTripCount"] < 0 or a["VF"] <= 0):
            raise ValueError("unsupported target or loop configuration")
        instructions = a["Instructions"]
        for index, i in enumerate(instructions):
            if i["ID"] != index or not 0 <= i["Group8"] <= 64 or i["Bytes"] < 0:
                raise ValueError("malformed instruction analytics")
        for e in a["Edges"]:
            src, dst = e["Source"], e["Destination"]
            if (not 0 <= src < len(instructions) or not 0 <= dst < len(instructions)
                    or not 0 <= e["OperandIndex"] < len(instructions[dst]["Operands"])
                    or e["Distance"] not in (0, 1) or (e["Distance"] == 0 and src >= dst)):
                raise ValueError("malformed dependency analytics")
    except (KeyError, TypeError, ValueError) as exc:
        raise ToolError(f"unsupported analytics: {exc}") from exc


class CostModel:
    """Compile observations into batched linear resources and a max-plus DAG.

    A row of multipliers is one independent optimizer start. Dependency edges are
    evaluated in topological batches, so no graph is reconstructed during fitting.
    """

    def __init__(self, observations: list[dict]):
        self.observations = observations
        self.count = len(observations)
        self.resources = []
        self.scalar_fixed = []
        self.graph = [[]]  # node zero is the constant zero
        self.terminals = []
        self.recurrences = []
        self.active = set()
        for ci, a in enumerate(observations):
            validate_analytics(a)
            try:
                self._compile_body(ci, a)
            except (KeyError, TypeError, ValueError, IndexError) as exc:
                raise ToolError(f"unsupported analytics for {a.get('Candidate')}: {exc}") from exc
        self.resources = torch.tensor(self.resources, dtype=DTYPE).reshape(self.count, 10, P)
        self.scalar_fixed = torch.tensor(self.scalar_fixed, dtype=DTYPE)
        self._compile_graph()
        self.rec_coeff = torch.tensor([v for _, v in self.recurrences], dtype=DTYPE).reshape(-1, P)
        self.rec_owner = torch.tensor([c for c, _ in self.recurrences], dtype=torch.long)
        self.terminal_owner = torch.tensor([c for c, _ in self.terminals], dtype=torch.long)
        self.terminal_node = torch.tensor([self.node_map[n] for _, n in self.terminals], dtype=torch.long)
        for tensor in (self.resources.reshape(-1, P), self.rec_coeff):
            self.active.update(torch.nonzero(tensor.abs().sum(0), as_tuple=True)[0].tolist())
        for _, coeff, _ in self.layers:
            self.active.update(torch.nonzero(coeff.abs().sum((0, 1)), as_tuple=True)[0].tolist())

    def _compile_body(self, ci, a):
        body = {b["ID"] for b in a["Blocks"] if b["Role"] == "body"}
        # memory total/load/store/extra, arithmetic, movement, scalar,
        # divider, spill, additive configuration
        r = [[0.0] * P for _ in range(10)]
        scalar = extra_strided = residual = 0.0
        shared = {}
        seen = False
        for i in a["Instructions"]:
            if i["Block"] not in body or i["Meta"]:
                continue
            seen = True
            k = i["Category"]
            if i["Barrier"] or k == "unknown":
                raise ValueError("unsupported instruction " + i["Opcode"])
            if k == "scalar":
                scalar += 8
                continue
            if k == "config":
                r[6 if i["ConfigUnused"] else 9][11] += 16
                continue
            if k == "spill":
                w = i["Bytes"] * a["VLen"] / 128 if i["ScalableBytes"] else i["Bytes"] / 2
                r[8][10] += max(8, w)
                continue
            group = i["Group8"]
            if group <= 0 or group & (group - 1):
                raise ValueError("invalid LMUL/register group")
            family = i["Base"].split("_")[0]
            if k in ("integer", "fp", "fused") and family.startswith(("VW", "VFW", "VNSR", "VNCLIP", "VFNC")):
                group *= 2
            raw = group * a["VLen"] // 128
            if k in ("strided", "indexed"):
                if i["SEW"] not in (8, 16, 32, 64):
                    raise ValueError("invalid memory SEW")
                raw = group * a["VLen"] // i["SEW"]
            if k == "mask_logical":
                raw = group * a["VLen"] // (8 * 128)
            w = max(8, raw)
            if k == "copy":
                r[5][7] += 0 if i["SameCopy"] else raw
            elif k == "slide":
                r[5][8] += 2 * w + 2 * max(i["Group8"] - 8, 0)
            elif k == "fp_div":
                if i["SEW"] not in (16, 32, 64):
                    raise ValueError("invalid division SEW")
                r[7][9] += w * 2 * {16: 29, 32: 25, 64: 37}[i["SEW"]]
            elif k in ("integer", "mask_logical"):
                r[4][5] += w * 2
            elif k in ("fp", "fused"):
                r[4][6] += w * 4
            elif k in ("unit", "strided", "indexed"):
                if i["Load"] == i["Store"]:
                    raise ValueError("ambiguous memory direction")
                p, amount = (0, w) if k == "unit" else (1, 2 * w)
                direction = 1 if i["Load"] else 2
                r[0][p] += amount
                r[direction][p] += amount
                if i["Masked"]:
                    r[0][2] += w
                    r[direction][2] += w
                if i["Group8"] > 8:
                    extra = w * (i["Group8"] - 8)
                    if k == "strided":
                        extra_strided += extra
                    if i["Masked"]:
                        if i["Predicate"]:
                            share = extra / 4
                            residual += extra - share
                            shared[i["Predicate"]] = max(shared.get(i["Predicate"], 0), share)
                        else:
                            residual += extra
            else:
                raise ValueError("unknown operation category " + k)
        if not seen:
            raise ValueError("empty or missing candidate body")
        r[3][3] = extra_strided / 32
        r[3][4] = (residual + sum(shared.values())) / 64
        self.resources.append(r)
        self.scalar_fixed.append(scalar)
        if a["DependencyCoverage"] == "single-block-distance-0-1":
            self._dependencies(ci, a, body)

    def _dependencies(self, ci, a, body):
        ins = a["Instructions"]
        rk = [recurrence_kind(i) for i in ins]
        preds = [set() for _ in ins]
        incoming = [[] for _ in ins]
        for e in a["Edges"]:
            s, d = e["Source"], e["Destination"]
            incoming[d].append(e)
            if ins[d]["Block"] in body and rk[s] and rk[d] and value_edge(a, e, rk[d] == 2):
                preds[d].add(s)
        chunks = lambda i: max(1, i["Group8"] * a["VLen"] // (8 * 128))
        for e in a["Edges"]:
            s, d = e["Source"], e["Destination"]
            if e["Distance"] != 1 or s not in preds[d]:
                continue
            current = s
            coeff = [0.0] * P
            while True:
                coeff[14 if rk[current] == 2 else 13] += 80 if rk[current] == 2 else 48
                coeff[17] += (chunks(ins[current]) - 1) * 32
                if current == d:
                    self.recurrences.append((ci, coeff))
                    break
                previous = [p for p in preds[current] if p < current]
                if len(previous) != 1 or previous[0] < d:
                    break
                current = previous[0]
        ready = {}
        for i in ins:
            if i["Block"] not in body:
                continue
            kind = load_kind(i)
            if kind is None:
                continue
            predecessors = []
            for e in incoming[i["ID"]]:
                s = e["Source"]
                if (e["Distance"] == 0 and value_edge(a, e, kind == "fma") and s in ready
                        and ins[s]["Group8"] == i["Group8"] and ins[s]["SEW"] == i["SEW"]):
                    predecessors.append(ready[s])
            if not predecessors and kind != "load":
                continue
            lat = [0.0] * P
            p, value = {"load": (12, 4), "fp": (13, 3), "fma": (14, 5),
                        "integer": (15, 1), "multiply": (16, 3)}[kind]
            lat[p] = value * 16
            first = len(self.graph)
            self.graph.append([(p[0], lat) for p in predecessors] or [(0, lat)])
            chunk = [0.0] * P
            chunk[17] = (chunks(i) - 1) * 16
            last = len(self.graph)
            self.graph.append([(p[1], lat) for p in predecessors] + [(first, chunk)])
            ready[i["ID"]] = first, last
            if kind != "load":
                self.terminals.append((ci, last))

    def _compile_graph(self):
        depth = [0]
        groups = {}
        for node, edges in enumerate(self.graph[1:], 1):
            d = 1 + max(depth[parent] for parent, _ in edges)
            depth.append(d)
            groups.setdefault(d, []).append(node)
        self.layers = []
        self.node_map = {0: 0}
        for d in sorted(groups):
            nodes = groups[d]
            width = max(len(self.graph[n]) for n in nodes)
            parents, coeffs, masks = [], [], []
            for n in nodes:
                edges = self.graph[n]
                parents.append([self.node_map[p] for p, _ in edges] + [0] * (width - len(edges)))
                coeffs.append([c for _, c in edges] + [[0.0] * P] * (width - len(edges)))
                masks.append([0.0] * len(edges) + [-math.inf] * (width - len(edges)))
            for n in nodes:
                self.node_map[n] = len(self.node_map)
            self.layers.append((torch.tensor(parents), torch.tensor(coeffs, dtype=DTYPE),
                                torch.tensor(masks, dtype=DTYPE)))

    def bodies(self, multipliers):
        if multipliers.ndim == 1:
            multipliers = multipliers.unsqueeze(0)
        n = multipliers.shape[0]
        r = torch.einsum("bp,crp->bcr", multipliers, self.resources)
        memory = torch.minimum(r[:, :, 0], torch.stack(
            (r[:, :, 1], r[:, :, 2], r[:, :, 0] * (7 / 8)), -1).amax(-1)) + r[:, :, 3]
        recurrence = torch.zeros((n, self.count), dtype=DTYPE)
        if len(self.recurrences):
            recurrence = recurrence.scatter_reduce(1, self.rec_owner.expand(n, -1),
                multipliers @ self.rec_coeff.T, reduce="amax", include_self=True)
        values = torch.zeros((n, 1), dtype=DTYPE)
        for parents, coeff, mask in self.layers:
            next_values = (values[:, parents] + torch.einsum("bp,nep->bne", multipliers, coeff) + mask).amax(-1)
            values = torch.cat((values, next_values), dim=1)
        load_use = torch.zeros_like(recurrence)
        if len(self.terminals):
            load_use = load_use.scatter_reduce(1, self.terminal_owner.expand(n, -1),
                values[:, self.terminal_node], reduce="amax", include_self=True)
        bounds = torch.stack((memory, r[:, :, 4], r[:, :, 5],
                              r[:, :, 6] + self.scalar_fixed, r[:, :, 7], recurrence, load_use), -1)
        return (bounds.amax(-1) + r[:, :, 8] + r[:, :, 9]) / 16

    def scores(self, multipliers, scalar_indices: list[int | None]):
        body = self.bodies(multipliers)
        main, tail, destinations, references = [], [], [], []
        for index, (a, si) in enumerate(zip(self.observations, scalar_indices, strict=True)):
            if si is None:
                if needs_scalar_reference(a):
                    raise ToolError("missing scalar reference for scalar tail")
            else:
                scalar = self.observations[si]
                if scalar["ScalableVF"] or scalar["VF"] != 1 or not same_context(a, scalar):
                    raise ToolError("scalar analytics context mismatch")
            t, w = a["MaxTripCount"], a["Width"]
            if not t:
                main.append(1 / w)
            elif a["ScalarTail"] or not a["ScalableVF"] and a["VF"] == 1:
                main.append(t // w)
                if t % w:
                    destinations.append(index)
                    references.append(si)
                    tail.append((t % w) / self.observations[si]["Width"])
            else:
                main.append((t + w - 1) // w)
        scores = body * torch.tensor(main, dtype=DTYPE)
        if destinations:
            scores = scores.index_add(1, torch.tensor(destinations),
                body[:, references] * torch.tensor(tail, dtype=DTYPE))
        return scores
