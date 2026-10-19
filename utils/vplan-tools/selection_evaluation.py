"""Evaluate replayed selections on validation measurements, never scalar guesses."""
from collections import Counter
import json
from pathlib import Path
import statistics
import sys

import vplan_tools as vt
from selection import load_policy


def selection_row(benchmark, result, expected_vlen=None):
    row = dict(id=benchmark.id, split=benchmark.kind, eligible=False,
               compile_failed=bool(result.returncode), status="compile-failed",
               reason=None, actual_selection=None, selected_vf=None,
               measured_cycles={str(v): c for v, c in benchmark.measured.items()},
               ignored_measured_cycles={}, evaluated_vfs=[],
               top1_correct=None, top1_regret=None)
    if result.returncode:
        row["reason"] = result.stderr[-3000:]
        return row
    manifest, final = result.manifest, result.final_manifest
    if (final["selections"] != result.selection["selections"] or final["failures"]
            or final["candidates"] != manifest["candidates"] or final["loops"] != manifest["loops"]
            or final["run_id"] != result.selection["run_id"] or final["run_id"] != manifest["run_id"]):
        raise vt.ToolError("final replay mismatch")
    loops = manifest["loops"]
    choices = final["selections"]
    if len(loops) != 1 or len(choices) != 1 or loops[0]["function"] != "selected_kernel":
        row.update(status="ambiguous-loops" if loops else "no-loop", reason="expected one selected_kernel loop")
        return row
    candidate_vfs = {int(c["vf"][1:]) for c in manifest["candidates"]
                     if c["function"] == loops[0]["function"] and c["loop"] == loops[0]["loop"]
                     and c["vf"].startswith("s")}
    row["evaluated_vfs"] = sorted(candidate_vfs)
    try:
        benchmark = vt.restrict_measurements(benchmark, candidate_vfs)
    except vt.ToolError as exc:
        row.update(status="missing-measurements", reason=str(exc))
        return row
    row["measured_cycles"] = {str(v): c for v, c in benchmark.measured.items()}
    row["ignored_measured_cycles"] = {str(v): c for v, c in benchmark.ignored_measured.items()}
    actual = dict(choices[0])
    row["actual_selection"] = actual
    if actual["scalar"]:
        actual.update(main_vf="f1", emitted=False)
        row.update(status="scalar-selection", reason=actual.get("reason"))
        return row
    candidate = next(c for c in manifest["candidates"] if c["id"] == actual["id"])
    actual.update(main_vf=candidate["vf"], emitted=True)
    statuses = {s["id"]: s for s in result.candidate_status["candidates"]}
    if expected_vlen and statuses[actual["id"]].get("vlen") != expected_vlen:
        row.update(status="vlen-mismatch", reason="analytics VLEN differs from measured VLEN")
        return row
    vf = candidate["vf"]
    if vf.startswith("s"):
        row["selected_vf"] = int(vf[1:])
    selected, measured = row["selected_vf"], benchmark.measured
    if selected not in measured:
        row.update(status="unmeasured-vf", reason=f"no measurement for {vf}")
    elif len(measured) < 2:
        row.update(status="insufficient-measurements", reason="fewer than two measured VFs")
    else:
        winner = min(measured, key=lambda v: (measured[v], v))
        row.update(status="scored", eligible=True, top1_correct=selected == winner,
                   top1_regret=measured[selected] / measured[winner] - 1)
    return row


def summarize_rows(rows):
    scored = [r for r in rows if r["eligible"]]
    regrets = [r["top1_regret"] for r in scored]
    return dict(total=len(rows), scored=len(scored), excluded=len(rows) - len(scored),
                compile_failed=sum(r["compile_failed"] for r in rows),
                coverage=len(scored) / len(rows) if rows else None,
                statuses=dict(Counter(r["status"] for r in rows)),
                top1=dict(n=len(scored), exact=statistics.mean(r["top1_correct"] for r in scored) if scored else None),
                top1_regret=dict(n=len(regrets), mean=statistics.mean(regrets) if regrets else None,
                                median=statistics.median(regrets) if regrets else None,
                                p95=vt.percentile(regrets, .95) if regrets else None))


def without_metric_option(argv):
    result, skip = [], False
    for arg in list(sys.argv[1:] if argv is None else argv):
        if skip:
            skip = False
        elif arg == "--metric-mode":
            skip = True
        elif not arg.startswith("--metric-mode="):
            result.append(arg)
    return result


def evaluate_main(argv=None, *, fitted=False):
    parser = vt.argument_parser("Evaluate replayed VF selections on validation data only.")
    parser.add_argument("--metric-mode", choices=("selection", "ranking"), default="selection")
    parser.add_argument("--benchmark")
    parser.add_argument("--weights", type=vt.resolved_path, required=fitted)
    parser.add_argument("--spill-count-unit", choices=("instruction", "register"))
    parser.add_argument("--json-output", type=vt.resolved_path)
    parser.add_argument("--artifacts-dir", type=vt.resolved_path)
    parser.add_argument("--cache-dir", type=vt.resolved_path, help="raw cache for fitted-model ranking evaluation")
    parser.add_argument("--exclude-reasons", action="store_true")
    args = parser.parse_args(argv)
    policy = load_policy(args.llvm_path, args.weights, args.spill_count_unit)
    if fitted and not policy.supports_fit:
        raise vt.ToolError("this is a fixed ablation policy; fitting and weights are unsupported")
    if args.compiler_mode != "meta":
        raise vt.ToolError("selection evaluation requires --compiler-mode meta; direct evaluation uses ordinary LLVM ranking")
    if args.metric_mode == "ranking" and not policy.supports_ranking:
        raise vt.ToolError(f"{policy.name} has no cost ranking; use --metric-mode selection")
    if args.metric_mode == "ranking" and policy.supports_fit:
        from calibration import evaluate_model_main
        return evaluate_model_main(without_metric_option(argv), fitted=fitted)
    benchmarks, metadata = vt.load_database(args.db, split="validation", benchmark_id=args.benchmark)
    if not benchmarks:
        raise vt.ToolError("no benchmarks in validation partition")
    clang = vt.ensure_compiler(args.llvm_path, args.build_dir, args.jobs)
    from calibration import collector_identity, digest_file, validate_weight_provenance
    identity = collector_identity(clang, args.llvm_path / "utils/vplan-meta-compile")
    if args.weights:
        from cost_model import load_weights
        validate_weight_provenance(load_weights(args.weights)[0], metadata, identity, benchmarks)
    rows, rankings = [], []
    for index, benchmark in enumerate(benchmarks, 1):
        print(f"[{index}/{len(benchmarks)}] {benchmark.id}", file=sys.stderr, flush=True)
        artifacts = args.artifacts_dir / benchmark.kind / vt.report_name(benchmark.id) if args.artifacts_dir else None
        try:
            result = vt.compile_report(clang, benchmark, False, args.timeout,
                meta_script=args.llvm_path / "utils/vplan-meta-compile", artifacts_dir=artifacts,
                weights=args.weights, spill_count_unit=args.spill_count_unit)
            if not result.returncode and result.candidate_status["policy"] != policy.identity:
                raise vt.ToolError("compiler driver and evaluator selected different policies")
            row = selection_row(benchmark, result, metadata["measurement_protocol"].get("vlen_bits"))
            row["artifact"] = str(result.artifact_root / "backend") if artifacts else None
            if args.metric_mode == "ranking":
                if row["status"] in ("compile-failed", "ambiguous-loops", "no-loop", "vlen-mismatch"):
                    rankings.append(vt.Result(benchmark, reason=row["reason"] or row["status"], compile_failed=row["compile_failed"]))
                else:
                    scores = {}
                    for candidate, status in zip(result.manifest["candidates"], result.candidate_status["candidates"], strict=True):
                        vf = candidate["vf"]
                        if vf.startswith("s") and status["status"] == "scored":
                            number = int(vf[1:])
                            scores[number] = min(scores.get(number, float("inf")), status["score"])
                    candidate_vfs = set(row["evaluated_vfs"])
                    if row["status"] == "missing-measurements":
                        rankings.append(vt.Result(benchmark, reason=row["reason"]))
                    else:
                        rankings.append(vt.score_benchmark(vt.restrict_measurements(benchmark, candidate_vfs), scores))
        except (vt.ToolError, OSError, ValueError, KeyError) as exc:
            from types import SimpleNamespace
            row = selection_row(benchmark, SimpleNamespace(returncode=1, stderr=str(exc)))
            if args.metric_mode == "ranking":
                rankings.append(vt.Result(benchmark, reason=str(exc), compile_failed=True))
        rows.append(row)
        if not row["eligible"]:
            print(f"  {row['status']}: {row['reason'] or ''}", file=sys.stderr)
    if args.metric_mode == "ranking":
        vt.print_summary("Validation: " + policy.name, rankings)
        vt.print_worst_regrets(rankings)
        data = dict(schema_version=2, metric_mode="ranking", policy=policy.identity,
                    metadata=metadata, metrics=vt.summary_json(rankings),
                    benchmarks=[vt.result_json(r) for r in rankings])
        successful = any(r.eligible for r in rankings)
    else:
        summary = summarize_rows(rows)
        data = dict(schema_version=3, metric_mode="selection", policy=policy.identity,
                    metadata=metadata, compiler_identity=identity, compiler=str(clang),
                    database=str(args.db), weights_sha256=digest_file(args.weights) if args.weights else None,
                    metrics={"validation": summary}, benchmarks=rows)
        print(policy.name + ": " + json.dumps(summary, sort_keys=True))
        print("Highest selection regrets:")
        for row in sorted((r for r in rows if r["eligible"]), key=lambda r: (-r["top1_regret"], r["id"]))[:10]:
            print(f"  {row['id']}: s{row['selected_vf']} {row['top1_regret']:.3%}")
        successful = summary["scored"] > 0
    if args.exclude_reasons:
        for row in rows:
            if not row["eligible"]:
                print(f"{row['id']}: {row['status']}: {row['reason'] or ''}")
    if args.json_output:
        vt.write_json(args.json_output, data)
    return 0 if successful and not any(r["compile_failed"] for r in rows) else 1
