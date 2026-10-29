# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
"""Opt-only serial/parallel equivalence, reports and compatibility diagnostics."""
import json
import re
from fractions import Fraction
from pathlib import Path
import subprocess
import sys

opt, directory, temporary = sys.argv[1:]
directory = Path(directory)
root = Path(temporary)
root.mkdir(parents=True, exist_ok=True)
common = [
    opt, "-codegen-opt-level=2", "-mtriple=riscv64",
    "-mcpu=xiangshan-kunminghu", "-mattr=+v",
    "-riscv-v-register-bit-width-lmul=8", "-disable-loop-unrolling",
    "-passes=loop-vectorize", "-verify-each", "-verify-machineinstrs",
]


def run(name, source, flags, threads, report=None, enabled=True):
    feedback = root / (name + ".jsonl")
    feedback.unlink(missing_ok=True)
    output = root / (name + ".ll")
    args = common + [str(source), "-S", "-o", str(output)] + flags
    args += [f"-vplan-backend-probe-threads={threads}",
             f"-vplan-backend-jsonl={feedback}"]
    if enabled:
        args.append("-vplan-backend")
    if report:
        args.append(report)
    proc = subprocess.run(args, capture_output=True, text=True, timeout=120)
    (root / (name + ".stderr")).write_text(proc.stderr)
    assert proc.returncode == 0, (args, proc.stderr)
    rows = [json.loads(line) for line in feedback.read_text().splitlines()] if feedback.exists() else []
    # Physical cancellation timing can vary; logical results stay ordered.
    for row in rows:
        if row["status"] == "pruned":
            row.pop("execution")
    return output.read_text(), rows, proc.stderr


basic = directory / "backend-feedback.ll"
scalable = ["-scalable-vectorization=always", "-force-vector-interleave=1",
            "-enable-epilogue-vectorization=false"]
# Exercise several batches in a function, gate skips, spill pricing, forced and
# automatic epilogues, and a required-backend failure. All outputs are ordered.
cases = [
    ("gate", basic, scalable),
    ("main", basic, scalable + ["-vplan-backend-force-all"]),
    ("ic2", basic, ["-force-vector-interleave=2", "-scalable-vectorization=always",
                    "-vplan-backend-force-all"]),
    ("epilogue", basic, ["-force-vector-interleave=4", "-scalable-vectorization=off",
                         "-epilogue-vectorization-force-VF=2", "-vplan-backend-force-all"]),
    ("spill", directory / "backend-feedback-spills.ll", scalable + ["-vplan-backend-force-all"]),
    ("failure", basic, scalable + ["-vplan-backend-force-all", "-disable-ssc"]),
]
# Numeric block identifiers must survive context isolation without depending on
# value names. Use the same renamed source path in every execution mode.
unnamed = root / "unnamed.ll"
stripped = subprocess.run([opt, str(basic), "-passes=strip", "-S", "-o", str(unnamed)],
                          capture_output=True, text=True, timeout=120)
assert stripped.returncode == 0, stripped.stderr
cases.append(("unnamed", unnamed, scalable + ["-vplan-backend-force-all"]))
for name, source, flags in cases:
    expected = run(name + "-serial", source, flags, 1)
    assert expected[1], name
    for threads in (2, 4):
        for repeat in range(2):
            actual = run(f"{name}-{threads}-{repeat}", source, flags, threads)
            assert actual == expected, (name, threads, repeat, actual[2])
    # Both report modes remain passive and usable with parallel probes.
    for report in ("-print-vplans", "-print-detailed-vplans"):
        serial = run(name + report + "-serial", source, flags, 1, report)
        parallel = run(name + report + "-parallel", source, flags, 4, report)
        if name == "epilogue":
            warning = "warning: -vplan-backend-probe-threads=4: using serial backend probes because forced-epilogue cost reporting requires serial preparation"
            assert parallel[2].count(warning) == 1, parallel[2]
            cleaned = parallel[2].replace(warning + "\n", "")
            assert parallel[:2] == serial[:2], (name, report)
            # Temporary epilogue/scalar plans use invocation-local IDs keyed by
            # allocation identity, even on the serial path. Check reported
            # decisions and exact backend costs rather than those IDs.
            for text in (serial[2], cleaned):
                sections = re.split(r"(?=VPlan report_version=)", text)[1:]
                for row in serial[1]:
                    section = next(s for s in sections if
                                   f" function={row['function']} loop={row['loop']} "
                                   in s.splitlines()[0])
                    vf = ("s" if row["scalable"] else "f") + str(row["vf"])
                    if "register_usage_bound" in row:
                        line = next(line for line in section.splitlines()
                                    if line.startswith("  backend-cost ")
                                    and f" vf={vf} " in line)
                        body = Fraction(row["body_quarters_numerator"],
                                        4 * row["body_quarters_denominator"])
                        assert Fraction(line.split(" body_cost=")[1]) == body
                        assert f" ic={row['ic']} " in line
                    elif row["status"] == "selected":
                        assert re.search(r"selected-for-main plan=\d+ vf=" + vf + r"\b", section)
                        if row["epilogue_vf"]:
                            evf = ("s" if row["epilogue_scalable"] else "f") + str(row["epilogue_vf"])
                            assert f" vf={evf} " in next(line for line in section.splitlines() if "selected-for-epilogue " in line)
        else:
            assert serial == parallel, (name, report)
        assert serial[:2] == expected[:2], (name, "report changed results")

flags = scalable + ["-vplan-backend-force-all"]
for option in ("-vplan-backend-time", "-print-after=loop-vectorize",
               "-debug-only=loop-vectorize", "-opt-bisect-limit=-1",
               "-time-passes", "-pass-remarks=loop-vectorize",
               "-debug-counter=instcombine-visit=0-1000000",
               "-regalloc-priority-interactive-channel-base=",
               "-regalloc-evict-interactive-channel-base="):
    serial = run("compat-serial", basic, flags + [option], 1)
    parallel = run("compat-parallel", basic, flags + [option], 4)
    assert serial[:2] == parallel[:2], option
    warning = "warning: -vplan-backend-probe-threads=4: using serial backend probes because "
    assert parallel[2].count(warning) == 1, (option, parallel[2])
    assert warning not in serial[2], option
    # Timing values naturally vary. Other upstream output retains its order.
    if option not in ("-vplan-backend-time", "-time-passes", "-debug-only=loop-vectorize"):
        cleaned = "".join(line for line in parallel[2].splitlines(keepends=True)
                          if not line.startswith(warning))
        assert cleaned == serial[2], option

# Master-off remains inert even when threads and diagnostic options are set.
off = run("off", basic, scalable, 1, enabled=False)
parallel_off = run("off-parallel", basic, scalable + ["-vplan-backend-time"], 4,
                   enabled=False)
assert off == parallel_off
assert not off[1] and not off[2]

# An explicitly requested single main candidate does not need a fallback warning.
single = run("single", basic,
             flags + ["-force-vector-width=4", "-vplan-backend-time"], 4)
assert "using serial backend probes" not in single[2]
invalid = subprocess.run(common + [str(basic), "-disable-output",
                                  "-vplan-backend-probe-threads=0"],
                         capture_output=True, text=True, timeout=120)
assert invalid.returncode != 0
assert "vplan-backend-probe-threads must be positive" in invalid.stderr
