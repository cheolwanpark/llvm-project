# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
"""Independent equations for scalar/vector pricing; no chosen-VF expectations."""
import json
from fractions import Fraction as Q
from pathlib import Path
import subprocess
import sys

opt, source, prefix = sys.argv[1:]
functions = {"divide", "adjacent_difference"}


def exact(row, field):
    return Q(row[field + "_quarters_numerator"],
             row[field + "_quarters_denominator"])


def run(cpu, vscale, name, flags):
    src = Path(prefix + "." + cpu + ".ll")
    src.write_text(Path(source).read_text().replace("vscale_range(4,4)",
                   "vscale_range(%d,%d)" % (vscale, vscale)))
    path = Path(prefix + "." + cpu + "." + name + ".jsonl")
    path.unlink(missing_ok=True)
    command = [opt, "-passes=loop-vectorize", "-codegen-opt-level=3",
               "-mtriple=riscv64", "-mcpu=generic-rv64", "-mtune=" + cpu,
               "-mattr=+v",
               "-scalable-vectorization=always", "-force-vector-interleave=1",
               "-riscv-v-register-bit-width-lmul=8",
               "-enable-epilogue-vectorization=false", "-disable-loop-unrolling",
               "-verify-each",
               "-vplan-backend-jsonl=" + str(path), *flags,
               str(src), "-S", "-o", "-"]
    result = subprocess.run(command, text=True, capture_output=True, timeout=120)
    assert result.returncode == 0, (command, result.stderr)
    rows = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    assert not any("fallback" in row["status"] for row in rows), rows
    return result.stdout, rows


def scalar_tti(rows, profile):
    candidates = [r for r in rows if r.get("role") == "main" and
                  "body_quarters_numerator" in r]
    assert {r["function"] for r in candidates} == functions, rows
    costs = {}
    for row in candidates:
        assert row["scalar_cost_source"] == "tti", row
        assert row["scalar_profile"] == profile, row
        c = exact(row, "scalar")
        assert c > 0
        assert row["function"] not in costs or costs[row["function"]] == c
        costs[row["function"]] = c
    assert not any(r.get("role") == "scalar-baseline" for r in rows)
    return costs


def mir_equations(rows, estimated, revision):
    candidates = [r for r in rows if r.get("role") in
                  ("main", "epilogue", "scalar-baseline")]
    scalar = [r for r in candidates if r["role"] == "scalar-baseline"]
    assert len(scalar) == 2 and {r["function"] for r in scalar} == functions
    baselines = {r["function"]: exact(r, "body") for r in scalar}
    for row in candidates:
        assert row["status"] == "collected", row
        assert row["mir_revision"] == revision, row
        assert row["use_estimated_spill"] == estimated
        observation = row["observation"]
        assert observation["stage"] == "post-frame-lowering"
        assert observation["iteration_mapping"]
        assert len(observation["body"]) == len(row["mir_costs"])
        assert row["unknown_instruction_count"] == sum(c["unknown"] for c in row["mir_costs"])
        body = sum((Q(c["numerator"], c["denominator"])
                    for c in row["mir_costs"]), Q(0))
        spill = sum((Q(c["numerator"], c["denominator"])
                     for op, c in zip(observation["body"], row["mir_costs"])
                     if op["spill_slot"]), Q(0))
        scale = Q(4 * row["tti_width"], observation["iteration_width"])
        assert exact(row, "mir_body") == body * scale
        assert exact(row, "mir_spill") == spill * scale
        cost = body * scale
        if estimated:
            cost += row["estimated_total_spill_quarters"] - spill * scale
        assert exact(row, "body") == cost, row
        if row["role"] == "scalar-baseline":
            assert row["vf"] == row["ic"] == row["tti_width"] == 1
            assert not row["scalable"]
            assert row["candidate"].endswith(":scalar-baseline")
        else:
            assert row["scalar_cost_source"] == ("mir-estimated-spill" if estimated else "mir"), row
            assert exact(row, "scalar") == baselines[row["function"]]
    # Pure MIR observations and chosen output are independent of spill TTI.
    return [(r["candidate"], exact(r, "mir_body"), exact(r, "mir_spill"),
             exact(r, "body"), r["observation"]) for r in candidates]


for cpu, vscale, profile, revision, divide_delta, difference_delta in (
        ("xiangshan-kunminghu", 2, "xiangshan-v2-128",
         "e7bab53e66dfb3c4a1d11cf9519b0396f8576cae", 13, 0),
        ("saturn-shuttle-v256d128", 4, "saturn-shuttle-v256d128",
         "dfe75de2a8868d51d42c20612821431a9fcf645e+vat-clear", 62, -1),
        ("spacemit-x60", 4, "spacemit-k1-256", "llvm-x60-occupancy-v2", 20, -1)):
    costs = []
    for default in (True, False):
        _, rows = run(cpu, vscale, "tti-" + str(default),
                      ["-vplan-backend", "-use-mir=false",
                       "-use-estimated-spill=true",
                       "-use-default-tti=" + str(default).lower()])
        costs.append(scalar_tti(rows, "native" if default else profile))
    assert costs[1]["divide"] - costs[0]["divide"] == 4 * divide_delta, costs
    assert costs[1]["adjacent_difference"] - costs[0]["adjacent_difference"] == 4 * difference_delta, costs
    reference = None
    for default in (True, False):
        ir, rows = run(cpu, vscale, "mir-" + str(default),
                       ["-vplan-backend", "-use-mir=true",
                        "-use-estimated-spill=false",
                        "-use-default-tti=" + str(default).lower()])
        facts = mir_equations(rows, False, revision)
        if reference is None:
            reference = (ir, facts)
        assert (ir, facts) == reference
    for default in (True, False):
        _, rows = run(cpu, vscale, "mir-estimated-" + str(default),
                      ["-vplan-backend", "-use-mir=true",
                       "-use-estimated-spill=true",
                       "-use-default-tti=" + str(default).lower()])
        mir_equations(rows, True, revision)
