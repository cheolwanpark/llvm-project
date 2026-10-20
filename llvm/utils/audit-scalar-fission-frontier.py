#!/usr/bin/env python3
# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
"""Audit a frontier change against two identical-input pinned-corpus runs.

Capture immediate partitions, final frames and stage choices for all previously
or newly selected Late targets. Optionally execute native harnesses and repeat
frozen-partition VF/IC sweeps. Requires PyYAML, as does the corpus evaluator.
Artifacts and commands are written separately from historical reports.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
from importlib import import_module
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import time

E = import_module("evaluate-scalar-fission")
ROOT = Path(__file__).resolve().parents[2]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def fields(record):
    return {
        k: v
        for a in record.get("Args", [])
        for k, v in a.items()
        if k not in ["String", "DebugLoc"]
    }


def run(command, output):
    command = list(map(str, command))
    write(output.with_suffix(output.suffix + ".command.json"), command)
    start = time.perf_counter()
    result = subprocess.run(command, text=True, capture_output=True, timeout=300)
    output.write_text(result.stderr)
    if result.returncode:
        raise RuntimeError(f"{command}\n{result.stderr}")
    return result, time.perf_counter() - start


def function(text, name):
    match = re.search(
        r"^define [^\n]*@" + re.escape(name) + r"\([\s\S]*?^}", text, re.M
    )
    assert match, name
    return match.group()


def allocas(text):
    result = []
    for m in re.finditer(
        r"(%scalar.fission.scratch[-\w.]*) = alloca \[(\d+) x (\w+)\]", text
    ):
        ty = m[3]
        width = {"double": 8, "float": 4, "ptr": 8}.get(ty)
        if width is None:
            width = (int(ty[1:]) + 7) // 8
        result.append(
            dict(name=m[1], count=int(m[2]), type=ty, bytes=int(m[2]) * width)
        )
    return result


def scratch_transfers(before, after):
    """Recover every actual store independently of the bounded graph remarks."""
    original = dict(re.findall(r"^  (%[-\w.]+) = (.*)$", before, re.M))
    emitted = dict(re.findall(r"^  (%[-\w.]+) = (.*)$", after, re.M))
    addresses = {
        name
        for name, definition in emitted.items()
        if definition.startswith("getelementptr")
        and "ptr %scalar.fission.scratch" in definition
        and "%fission.producer.ordinal" in definition
    }
    return [
        dict(
            Value=m[2][1:],
            type=m[1],
            definition=original.get(m[2]),
            retained_definition=emitted.get(m[2]),
        )
        for m in re.finditer(r"store (\w+) (%[-\w.]+), ptr (%[-\w.]+)", after)
        if m[3] in addresses
    ]


def complete_ir_sources(result, directory, name):
    for policy, row in result["policies"].items():
        tag = "late-" + policy
        before = function((directory / (tag + "-before.ll")).read_text(), name)
        after = function((directory / (tag + "-after.ll")).read_text(), name)
        row["scratch_transfers_from_ir"] = scratch_transfers(before, after)
        selections = [r for r in row["function_decisions"] if r["kind"] == "Selected"]
        streams = sum(int(r["Streams"]) - int(r["ReusedBuffers"]) for r in selections)
        assert streams == len(row["scratch_transfers_from_ir"]), (name, streams)
    return result


def native(entry, build, corpus, output, policies):
    source = corpus / entry["source"]
    assert sha(source) == entry["sha256"]
    directory = output / entry["id"] / "native"
    directory.mkdir(parents=True, exist_ok=True)
    sdk = (
        [
            "-isysroot",
            subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip(),
        ]
        if sys.platform == "darwin"
        else []
    )
    seeds = [0, 1, 2, 3, 17, 31, 255, 1024, 4294967295, 18446744073709551615]
    records, expected = [], {}
    configs = [("baseline", False, 1024)] + [
        ("fission", fp, cap)
        for cap in [1024, 1, 3]
        for fp in [False, True]
        if policies["reordered" if fp else "ordered"]["target_selected"]
    ]
    for mode, fp, cap in configs:
        tag = f"{mode}-fp{int(fp)}-c{cap}"
        ir, obj, exe = [directory / (tag + ext) for ext in [".ll", ".o", ""]]
        flags = (
            []
            if mode == "baseline"
            else [
                "-mllvm",
                "-enable-scalar-fission",
                "-mllvm",
                f"-scalar-fission-chunk-capacity={cap}",
                "-mllvm",
                f"-scalar-fission-allow-fp-reordering={str(fp).lower()}",
            ]
        )
        # Always recompile. A previous executable cannot satisfy a fresh audit.
        run(
            [
                build / "bin/clang",
                "-O3",
                "-ffp-contract=off",
                "-gline-tables-only",
                "-gcolumn-info",
                "-fno-discard-value-names",
                *sdk,
                "-std=c11" if source.suffix == ".c" else "-std=c++17",
                "-fsave-optimization-record",
                "-foptimization-record-file=" + str(directory / (tag + ".yaml")),
                "-mllvm",
                "-force-vector-interleave=1",
                "-mllvm",
                "-hints-allow-reordering=false",
                *flags,
                "-S",
                "-emit-llvm",
                source,
                "-o",
                ir,
            ],
            directory / (tag + ".compile.log"),
        )
        selected = (
            E.records(directory / (tag + ".yaml"), entry)["fission"] == "selected"
        )
        if mode != "baseline" and not selected:
            records.append(
                dict(
                    mode=mode,
                    fp_reordering=fp,
                    capacity=cap,
                    status="native-target-not-selected",
                    values_compared=0,
                )
            )
            continue
        run(
            [
                build / "bin/llc",
                "-filetype=obj",
                "-verify-machineinstrs",
                ir,
                "-o",
                obj,
            ],
            directory / (tag + ".llc.log"),
        )
        run(
            [
                "cc",
                obj,
                "-lc++" if sys.platform == "darwin" else "-lstdc++",
                "-lm",
                "-o",
                exe,
            ],
            directory / (tag + ".link.log"),
        )
        values, worst, mismatches, outputs = 0, 0.0, [], {}
        for seed in seeds:
            if mode != "baseline" and seed not in expected:
                continue
            result = subprocess.run(
                [str(exe), "--seed", str(seed)],
                text=True,
                capture_output=True,
                timeout=30,
            )
            if mode == "baseline" and result.returncode:
                # Preserve the historical Vina baseline-invalid maximum seed.
                assert "vina" in entry["id"] and seed == seeds[-1], (
                    entry["id"],
                    seed,
                    result.stderr,
                )
                continue
            assert result.returncode == 0, (exe, seed, result.stderr)
            data = json.loads(result.stdout)["outputs"]
            outputs[str(seed)] = data
            if mode == "baseline":
                expected[seed] = data
                continue
            assert len(data) == len(expected[seed])
            values += len(data)
            for k, (a, b) in enumerate(zip(data, expected[seed])):
                same = (
                    a == b and (a != 0 or math.copysign(1, a) == math.copysign(1, b))
                ) or (math.isnan(a) and math.isnan(b))
                error = (
                    abs(a - b) / max(1, abs(b))
                    if math.isfinite(a) and math.isfinite(b)
                    else (0 if same else float("inf"))
                )
                worst = max(worst, error)
                if not same and (not fp or error > 1e-10):
                    mismatches.append([seed, k, a, b])
        write(directory / (tag + ".outputs.json"), outputs)
        records.append(
            dict(
                mode=mode,
                fp_reordering=fp,
                capacity=cap,
                status="executed",
                target_selected=selected,
                values_compared=values,
                max_scaled_error=worst,
                mismatch_count=len(mismatches),
                mismatches=mismatches[:20],
            )
        )
    write(directory / "result.json", records)
    return records


def capture(entry, args):
    directory = args.output / entry["id"]
    directory.mkdir(parents=True, exist_ok=True)
    compiler = {
        name: sha(args.build_dir / "bin" / name) for name in ["opt", "llc", "clang"]
    }
    input_sha = sha(args.frontier_results / entry["id"] / "raw.bc")
    options = dict(native=args.native, sweep=args.sweep)
    cached = directory / "audit.json"
    if args.reuse_captures and cached.exists():
        prior = json.loads(cached.read_text())
        assert prior["compiler"] == compiler, "capture compiler mismatch"
        assert prior["input_sha256"] == input_sha, "capture input mismatch"
        assert prior["source_sha256"] == entry["sha256"], "capture source mismatch"
        assert prior["capture_options"] == options, "capture options mismatch"
        for path, digest in prior["artifact_hashes"].items():
            assert sha(directory / path) == digest, ("capture artifact mismatch", path)
        return complete_ir_sources(prior, directory, entry["function"])
    policies = {}
    for policy in ["ordered", "reordered"]:
        tag = "late-" + policy
        command = json.loads(
            (args.frontier_results / entry["id"] / (tag + ".command.json")).read_text()
        )
        command = [c for c in command if c != "-debug-pass-manager"]
        command[0] = str(args.build_dir / "bin/opt")
        command += [
            "-print-before=scalar-fission",
            "-print-after=scalar-fission",
            "-print-module-scope",
            "-verify-dom-info",
            "-verify-loop-info",
            "-verify-scev",
        ]
        command[command.index("-o") + 1] = str(directory / (tag + ".ll"))
        command = [
            (
                "-pass-remarks-output=" + str(directory / (tag + ".yaml"))
                if c.startswith("-pass-remarks-output=")
                else c
            )
            for c in command
        ]
        result, seconds = run(command, directory / (tag + ".dump"))
        parts = re.split(
            r"; \*\*\* IR Dump (Before|After) ScalarFissionPass on ([^\n]+) \*\*\*\n",
            result.stderr,
        )
        for i in range(1, len(parts), 3):
            if parts[i + 1] == entry["function"]:
                (directory / (tag + "-" + parts[i].lower() + ".ll")).write_text(
                    parts[i + 2]
                )
        before = function(
            (directory / (tag + "-before.ll")).read_text(), entry["function"]
        )
        after = function(
            (directory / (tag + "-after.ll")).read_text(), entry["function"]
        )
        final = function((directory / (tag + ".ll")).read_text(), entry["function"])
        definitions = dict(re.findall(r"^  (%[-\w.]+) = (.*)$", before, re.M))
        records = [
            r
            for r in E.yaml.load_all(
                (directory / (tag + ".yaml")).read_text(), Loader=E.Loader
            )
            if r
            and r.get("Pass") in ["scalar-fission", "loop-vectorize"]
            and r.get("Function") == entry["function"]
        ]
        exact = E.records(directory / (tag + ".yaml"), entry)
        run(
            [
                args.build_dir / "bin/llc",
                "-verify-machineinstrs",
                directory / (tag + ".ll"),
                "-o",
                directory / (tag + ".s"),
            ],
            directory / (tag + ".codegen.log"),
        )
        asm = (directory / (tag + ".s")).read_text()
        start = asm.index(entry["function"] + ":")
        end = asm.find(".Lfunc_end", start)
        frame = max(
            [0]
            + list(map(int, re.findall(r"\.cfi_def_cfa_offset (\d+)", asm[start:end])))
        )
        graph = [
            dict(kind=r["Name"], location=r.get("DebugLoc"), **fields(r))
            for r in records
            if r["Name"] in ["Contribution", "Frontier"]
        ]
        transfers = [
            dict(**r, definition=definitions.get("%" + r["Value"]))
            for r in graph
            if r["kind"] == "Frontier"
            and r["Transfer"] in ["scratch", "existing-buffer"]
        ]
        row = dict(
            target_selected=exact["fission"] == "selected",
            target_decisions=[
                dict(kind=r["Name"], **fields(r))
                for r in exact["target_records"]
                if r["Name"] in ["Selected", "Rejected"]
            ],
            function_decisions=[
                dict(kind=r["Name"], location=r.get("DebugLoc"), **fields(r))
                for r in records
                if r["Name"] in ["Selected", "Rejected"]
            ],
            graph=graph,
            final_transfers=transfers,
            immediate_allocas=allocas(after),
            final_allocas=allocas(final),
            final_ir_allocation_bytes=sum(a["bytes"] for a in allocas(final)),
            rvv_max_fixed_cfa=frame,
            automatic_stages=[fields(r) for r in records if r["Name"] == "Stage"],
            capture_seconds=seconds,
        )
        if "spin2" in entry["id"]:
            mir = directory / (tag + ".mir")
            run(
                [
                    args.build_dir / "bin/llc",
                    "-verify-machineinstrs",
                    "-stop-after=stack-coloring",
                    directory / (tag + ".ll"),
                    "-o",
                    mir,
                ],
                directory / (tag + ".stack-coloring.log"),
            )
            text = mir.read_text()
            start = text.index("name:            " + entry["function"])
            end = text.index("body:", start)
            row["colored_scratch_objects"] = list(
                map(int, re.findall(r"size: (1024),", text[start:end]))
            )
        if row["target_selected"] and args.sweep:
            frozen = directory / ("frozen-" + policy + ".ll")
            run(
                [
                    args.build_dir / "bin/llvm-extract",
                    "--func=" + entry["function"],
                    "--rglob=.*",
                    "--keep-const-init",
                    "-S",
                    directory / (tag + "-after.ll"),
                    "-o",
                    frozen,
                ],
                directory / (tag + ".extract.log"),
            )

            def normalized(text):
                return re.sub(
                    r",? ![-\w.]+ !\d+|#\d+|;[^\n]*",
                    "",
                    function(text, entry["function"]),
                )

            assert normalized(frozen.read_text()) == normalized(
                after
            ), "partition changed during extraction"
            row["sweeps"] = []
            for pi, ci in [(1, 1), (2, 1), (1, 2)]:
                output = directory / "sweep" / policy / f"ic{pi}-{ci}"
                run(
                    [
                        sys.executable,
                        ROOT / "llvm/utils/scalar-fission-sweep.py",
                        frozen,
                        "--build-dir",
                        args.build_dir,
                        "--output",
                        output,
                        "--producer",
                        "1",
                        "f2",
                        "s1",
                        "s2",
                        "--consumer",
                        "1",
                        "f2",
                        "f4",
                        "s1",
                        "s2",
                        "--producer-interleave",
                        pi,
                        "--consumer-interleave",
                        ci,
                    ],
                    directory / (tag + f".sweep{pi}-{ci}.log"),
                )
                sweep = json.loads((output / "result.json").read_text())
                assert sweep["opt_sha256"] == sha(args.build_dir / "bin/opt")
                assert sweep["input_sha256"] == sha(frozen)
                row["sweeps"].extend(sweep["rows"])
        else:
            row["sweep_status"] = (
                "not split" if not row["target_selected"] else "not requested"
            )
        policies[policy] = row
    result = dict(
        id=entry["id"],
        source=entry["source"],
        source_sha256=entry["sha256"],
        policies=policies,
    )
    if args.native and any(p["target_selected"] for p in policies.values()):
        result["native"] = native(
            entry, args.build_dir, args.corpus, args.output, policies
        )
    else:
        result["native_status"] = (
            "not split"
            if not any(p["target_selected"] for p in policies.values())
            else "not requested"
        )
    complete_ir_sources(result, directory, entry["function"])
    result["compiler"] = compiler
    result["input_sha256"] = input_sha
    result["capture_options"] = options
    result["artifact_hashes"] = {
        str(path.relative_to(directory)): sha(path)
        for path in directory.rglob("*")
        if path.is_file() and path.name != "audit.json"
    }
    write(directory / "audit.json", result)
    print(
        entry["id"], {p: r["target_selected"] for p, r in policies.items()}, flush=True
    )
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in [
        "build-dir",
        "corpus",
        "baseline-results",
        "frontier-results",
        "output",
    ]:
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument(
        "--baseline-build-dir",
        type=Path,
        help="also recapture baseline partitions with the preserved tools",
    )
    parser.add_argument("--native", action="store_true")
    parser.add_argument("--sweep", action="store_true")
    parser.add_argument(
        "--reuse-captures",
        action="store_true",
        help="reuse only captures with matching tools, inputs, options and all artifact hashes",
    )
    args = parser.parse_args()
    for name, value in vars(args).items():
        if isinstance(value, Path):
            setattr(args, name, value.resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    baseline = json.loads((args.baseline_results / "result.json").read_text())
    frontier = json.loads((args.frontier_results / "result.json").read_text())
    assert baseline["manifest_sha256"] == frontier["manifest_sha256"]
    assert frontier["compiler"]["opt"] == sha(args.build_dir / "bin/opt")
    old = {(r["id"], r["placement"], r["fp_reordering"]): r for r in baseline["rows"]}
    changes = []
    for row in frontier["rows"]:
        prior = old[row["id"], row["placement"], row["fp_reordering"]]
        assert prior["frontend"]["input_sha256"] == row["frontend"]["input_sha256"]
        if row["fission"] != prior["fission"]:
            changes.append(
                dict(
                    id=row["id"],
                    placement=row["placement"],
                    fp_reordering=row["fp_reordering"],
                    before=prior["fission"],
                    after=row["fission"],
                    target_decisions=[
                        dict(kind=r["Name"], **fields(r))
                        for r in row["target_records"]
                        if r["Name"] in ["Selected", "Rejected"]
                    ],
                )
            )
    ids = {
        r["id"]
        for run in [baseline, frontier]
        for r in run["rows"]
        if r["placement"] == "late" and r["fission"] == "selected"
    }
    entries = json.loads((args.corpus / "benchmark-search/targets.json").read_text())[
        "benchmarks"
    ]
    with ThreadPoolExecutor(max_workers=3) as pool:
        rows = list(
            pool.map(lambda e: capture(e, args), [e for e in entries if e["id"] in ids])
        )
    if args.baseline_build_dir:
        assert baseline["compiler"] == {
            name: sha(args.baseline_build_dir / "bin" / name)
            for name in ["opt", "llc", "clang"]
        }, "baseline compiler mismatch"
        base_args = argparse.Namespace(**vars(args))
        base_args.build_dir = args.baseline_build_dir
        base_args.frontier_results = args.baseline_results
        base_args.output = args.output / "baseline"
        base_args.native = base_args.sweep = False
        with ThreadPoolExecutor(max_workers=3) as pool:
            captured = list(
                pool.map(
                    lambda e: capture(e, base_args),
                    [e for e in entries if e["id"] in ids],
                )
            )
        by_id = {row["id"]: row for row in captured}
        for row in rows:
            row["baseline"] = by_id[row["id"]]
    write(
        args.output / "audit.json",
        dict(
            schema=1,
            changes=changes,
            rows=rows,
            compiler=frontier["compiler"],
            source_sha256=sha(ROOT / "llvm/lib/Transforms/Scalar/ScalarFission.cpp"),
            rvv_runtime="unmeasured; no runner available",
            profitability="unmeasured",
        ),
    )


if __name__ == "__main__":
    main()
