"""Evaluate the fixed model and optionally compare actual LLVM decisions."""
import os
from pathlib import Path
import sys
import time
from types import SimpleNamespace

import llvm_baseline
from selection import load_policy
from selection_evaluation import selection_row, summarize_rows
import vplan_tools as vt


def decision(row):
    """Only compare observed decisions, never infer them from cycle measurements."""
    actual = row.get("actual_selection")
    if not actual or actual.get("main_vf") == "not-evaluated":
        return None
    result = {k: actual.get(k) for k in ("main_vf", "ic", "epilogue_vf", "emitted")}
    if result["epilogue_vf"] == "not-evaluated":
        result["epilogue_vf"] = "f0"
    return result


def compare(model, baseline):
    a, b = decision(model), decision(baseline)
    return {"model": a, "baseline": b,
            "comparable": a is not None and b is not None,
            "same_vf": a["main_vf"] == b["main_vf"] if a and b else None,
            "same_decision": a == b if a and b else None}


def main(argv=None):
    parser = vt.argument_parser("Evaluate the fixed LLVM middle-end model; no fitting or weights.")
    parser.add_argument("--benchmark", help="one exact benchmark ID")
    parser.add_argument("--output-dir", type=vt.resolved_path, required=True)
    parser.add_argument("--artifacts-dir", type=vt.resolved_path)
    parser.add_argument("--compare-baseline", action="store_true",
                        help="also compile with ordinary LLVM and report decision agreement")
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args(argv)
    if args.compiler_mode != "meta":
        parser.error("fixed evaluation requires meta mode; use evaluate-baseline for direct mode")
    policy = load_policy(args.llvm_path)
    if policy.supports_fit:
        raise vt.ToolError("fixed evaluation requires a non-fittable policy")
    benchmarks, metadata = vt.load_database(args.db, benchmark_id=args.benchmark)
    if not benchmarks:
        raise vt.ToolError("no matching benchmarks")
    if args.output_dir.exists() and (not args.output_dir.is_dir() or any(args.output_dir.iterdir())):
        raise vt.ToolError("--output-dir must be new or empty")
    if args.skip_build:
        clang = (args.build_dir or args.llvm_path / "build-vplan-tools") / "bin/clang"
        if not all(p.is_file() and os.access(p, os.X_OK) for p in (clang, clang.parent / "llvm-extract")):
            raise vt.ToolError("existing clang/llvm-extract binaries are missing or not executable")
    else:
        clang = vt.ensure_compiler(args.llvm_path, args.build_dir, args.jobs)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    rows, baseline_rows, comparisons = [], [], []
    report = dict(schema_version=1, evaluation="fixed-llvm-middle-end", database=str(args.db),
                  metadata=metadata, compiler=str(clang), policy=policy.identity,
                  complete=False, benchmarks=rows, baseline=baseline_rows, comparisons=comparisons)
    started = time.perf_counter()
    for index, benchmark in enumerate(benchmarks, 1):
        print(f"[{index}/{len(benchmarks)}] {benchmark.id}", file=sys.stderr, flush=True)
        for mode in (("meta", "direct") if args.compare_baseline else ("meta",)):
            artifacts = args.artifacts_dir / vt.report_name(benchmark.id) / mode if args.artifacts_dir else None
            try:
                result = vt.compile_report(clang, benchmark, False, args.timeout,
                    compiler_mode=mode, meta_script=args.llvm_path / "utils/vplan-meta-compile",
                    artifacts_dir=artifacts)
                if mode == "meta" and not result.returncode and result.candidate_status["policy"] != policy.identity:
                    raise vt.ToolError("driver/evaluator policy mismatch")
                row = (selection_row(benchmark, result) if mode == "meta"
                       else llvm_baseline.selection_row(benchmark, result))
            except (vt.ToolError, OSError, ValueError, KeyError) as exc:
                result = SimpleNamespace(returncode=1, stderr=str(exc))
                row = selection_row(benchmark, result)
            (rows if mode == "meta" else baseline_rows).append(row)
            if not row["eligible"]:
                print(f"  {mode}: {row['status']}: {row['reason'] or ''}", file=sys.stderr, flush=True)
        if args.compare_baseline:
            comparisons.append({"id": benchmark.id, **compare(rows[-1], baseline_rows[-1])})
        report.update(metrics=summarize_rows(rows), elapsed_seconds=time.perf_counter() - started)
        vt.write_json(args.output_dir / "summary.json", report)
    valid = [c for c in comparisons if c["comparable"]]
    report.update(complete=True,
                  successful=not any(r["compile_failed"] for r in rows + baseline_rows),
                  baseline_metrics=summarize_rows(baseline_rows) if args.compare_baseline else None,
                  agreement={"total": len(comparisons), "comparable": len(valid),
                             "same_vf": sum(c["same_vf"] for c in valid),
                             "same_decision": sum(c["same_decision"] for c in valid)})
    vt.write_json(args.output_dir / "summary.json", report)
    metrics = report["metrics"]
    print(f"Fixed model: scored={metrics['scored']}/{metrics['total']}; no fitting")
    if args.compare_baseline:
        print(f"LLVM agreement: VF={report['agreement']['same_vf']}/{len(valid)}, "
              f"full decision={report['agreement']['same_decision']}/{len(valid)} "
              f"({len(comparisons) - len(valid)} not comparable)")
    print(f"Report: {args.output_dir / 'summary.json'}")
    return 0 if report["successful"] else 1
