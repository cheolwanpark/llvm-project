# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
"""Cost pruning, gate incumbents, fallback and passive reporting."""
import json
from pathlib import Path
import subprocess
import sys

opt, directory, temporary = sys.argv[1:]
directory, temporary = Path(directory), Path(temporary)
temporary.mkdir(parents=True, exist_ok=True)
common = [opt, "-codegen-opt-level=2", "-mtriple=riscv64",
          "-mcpu=xiangshan-kunminghu", "-mattr=+v",
          "-scalable-vectorization=always", "-force-vector-interleave=1",
          "-riscv-v-register-bit-width-lmul=8",
          "-enable-epilogue-vectorization=false", "-disable-loop-unrolling",
          "-passes=loop-vectorize", "-vplan-backend", "-verify-each",
          "-verify-machineinstrs"]
count = 0

def run(source, prune, threads=1, extra=()):
    global count
    count += 1
    report = temporary / f"{count}.jsonl"
    report.unlink(missing_ok=True)
    ir = temporary / f"{count}.ll"
    cmd = common + [str(directory / source), "-S", "-o", str(ir),

                    f"-vplan-backend-probe-threads={threads}",
                    f"-vplan-backend-jsonl={report}"] + list(extra)
    if not prune:
        cmd.append("-vplan-backend-force-all")
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    assert p.returncode == 0, (cmd, p.stderr)
    rows = [json.loads(x) for x in report.read_text().splitlines()]
    return ir.read_text(), rows

for source in ["backend-feedback-candidate-pruning.ll",
               "backend-feedback-spills.ll", "backend-feedback.ll"]:
    baseline, _ = run(source, False)
    for threads in (1, 2, 4):
        ir, rows = run(source, True, threads)
        assert ir == baseline, (source, threads)
        for flag in ("-print-vplans", "-print-detailed-vplans"):
            reported, _ = run(source, True, threads, [flag])
            assert reported == ir
        if source == "backend-feedback-candidate-pruning.ll":
            assert any(r["status"] == "skipped" for r in rows)
            pruned = [r for r in rows if r["status"] == "pruned"]
            assert pruned and all(r["execution"] == "not-started" for r in pruned)
            # No backend must be started: even an unsupported backend is harmless.
            failed_backend, disabled_rows = run(source, True, threads, ["-disable-ssc"])
            assert failed_backend == ir
            assert not any(r["status"] == "native-fallback" for r in disabled_rows)
        if source == "backend-feedback-spills.ll":
            assert any(r["status"] == "pruned" for r in rows)
    for flags in (["-vplan-backend-force-all"],
                  ["-enable-epilogue-vectorization=true"],
                  ["-force-vector-width=4"]):
        old, old_rows = run(source, True, 1, flags)
        new, new_rows = run(source, True, 2, flags)
        assert (old, old_rows) == (new, new_rows)
        assert not any(r["status"] == "pruned" for r in new_rows)

_, rows = run("backend-feedback-spills.ll", True, 4, ["-disable-ssc"])
assert any(r["status"] == "estimated-fallback" for r in rows)

help_result = subprocess.run([opt, "--help-hidden"], capture_output=True,
                             text=True, timeout=120)
assert help_result.returncode == 0
assert "vplan-backend-prune-cfg" in help_result.stdout
assert "vplan-backend-prune-candidates" not in help_result.stdout
assert "vplan-backend-prune-loop-regions" not in help_result.stdout
