"""Five-fold benchmark-group CV, independent of the database split labels."""
from __future__ import annotations

import argparse
from dataclasses import replace
import os
from pathlib import Path
import random
import statistics
import sys
import time
from types import SimpleNamespace

import torch

import calibration as cal
from cost_model import DTYPE, MODEL_VERSION, PARAMETERS, P, load_weights
from selection import load_policy
from selection_evaluation import selection_row, summarize_rows
import vplan_tools as vt

FOLDS = 5
FIT_DEFAULTS = {
    "learning_rate": .03, "min_multiplier": .25, "max_multiplier": 4.,
    "min_tail_scale": 1 / 64, "max_tail_scale": 64., "temperature": .1,
    "weight_saturation": 1.25, "pair_threshold": .01, "regularization": .001,
}


def make_folds(ids, seed):
    """Freeze membership before eligibility checks; keep every VF of an ID together."""
    ids = sorted(ids)
    if len(ids) != len(set(ids)):
        raise vt.ToolError("duplicate benchmark IDs")
    if len(ids) < FOLDS:
        raise vt.ToolError("five-fold CV requires at least five benchmarks")
    random.Random(seed).shuffle(ids)
    return [sorted(ids[i::FOLDS]) for i in range(FOLDS)]


def fingerprint(benchmarks):
    # Original partition labels are deliberately not part of the CV population.
    return cal.digest_json([
        dict(id=b.id, source=b.source, args=b.compile_args,
             workload=b.workload, measurements=b.measured)
        for b in sorted(benchmarks, key=lambda b: b.id)
    ])


def parser():
    result = vt.argument_parser("Five-fold cross validation grouped by benchmark ID (all DB partitions).")
    result.add_argument("--output-dir", required=True, type=vt.resolved_path,
                        help="new or empty directory for fold assignments, weights and results")
    result.add_argument("--split-seed", type=int, default=0)
    result.add_argument("--fit-seed", type=int, default=0,
                        help="optimizer seed, reset to this value independently in each fold")
    result.add_argument("--metric-mode", choices=("selection", "ranking"), default="selection")
    result.add_argument("--cache-dir", type=vt.resolved_path, default=vt.TOOLS / ".cache/analytics")
    result.add_argument("--artifacts-dir", type=vt.resolved_path)
    result.add_argument("--skip-build", action="store_true", help="reuse existing clang and llvm-extract")
    result.add_argument("--starts", type=vt.positive_int, default=16)
    result.add_argument("--steps", type=vt.positive_int, default=2000)
    for name, default in FIT_DEFAULTS.items():
        result.add_argument("--" + name.replace("_", "-"), type=cal.finite_float, default=default)
    return result


def parse_args(argv):
    p = parser()
    args = p.parse_args(argv)
    if args.compiler_mode != "meta":
        p.error("cross validation requires --compiler-mode meta")
    if not (0 < args.min_multiplier <= 1 <= args.max_multiplier and args.min_multiplier < args.max_multiplier
            and 0 < args.min_tail_scale <= 1 <= args.max_tail_scale and args.min_tail_scale < args.max_tail_scale
            and args.learning_rate > 0 and args.temperature > 0 and args.weight_saturation > 1
            and args.pair_threshold >= 0 and args.regularization >= 0):
        p.error("invalid fitting bounds, rate, temperature, saturation, threshold, or regularization")
    # calibration.fit owns its own torch.Generator; it never uses the split RNG.
    args.seed = args.fit_seed
    return args


def fit_fold(train, clang, args, identity, metadata, cv_context, path):
    model, examples, excluded, provenance = cal.prepare(train, clang, args, identity, metadata, True)
    weights, diagnostics = cal.fit(model, examples, args)
    fitted = cal.results_for(model, examples, weights)
    initial = cal.results_for(model, examples, torch.ones(P, dtype=DTYPE))
    artifact = {
        "schema_version": 2, "model_version": MODEL_VERSION,
        "multipliers": dict(zip(PARAMETERS, weights.tolist(), strict=True)),
        "default_multipliers": dict.fromkeys(PARAMETERS, 1.),
        "fixed": {"scalar_instruction": .5,
                  "unobserved_parameters": [p for i, p in enumerate(PARAMETERS) if i not in model.active]},
        "settings": {k: getattr(args, k) for k in ("starts", "steps", "seed", *FIT_DEFAULTS)},
        "optimizer": "Adam/CPU/float64",
        "objective": "loop-mean weighted pairwise logistic + mean log-multiplier L2",
        "dataset": metadata, "compiler_identity": identity,
        # Retain the existing weight reader/provenance contract. These are this
        # fold's training IDs, regardless of their original database labels.
        "tuning_ids": [b.id for b in train], "tuning_fingerprint": fingerprint(train),
        "cv": cv_context, "provenance": provenance, "excluded": excluded,
        "fitting": diagnostics, "initial_metrics": vt.summary_json(initial),
        "fitted_metrics": vt.summary_json(fitted),
        "benchmarks": [vt.result_json(r) for r in fitted],
    }
    vt.write_json(path, artifact)
    return artifact


def validate_fold_weights(path, metadata, identity, train_ids, held_out, context):
    artifact, weights = load_weights(path)
    cal.validate_weight_provenance(artifact, metadata, identity, held_out)
    if artifact.get("cv") != context or artifact["tuning_ids"] != train_ids:
        raise vt.ToolError("weights do not belong to this CV fold and training population")
    return weights


def evaluate_fold(held_out, clang, args, identity, metadata, weights_path):
    policy = load_policy(args.llvm_path, weights_path)
    if args.metric_mode == "ranking":
        model, examples, excluded, provenance = cal.prepare(held_out, clang, args, identity, metadata, False)
        results = cal.results_for(model, examples, load_weights(weights_path)[1])
        by_id = {b.id: b for b in held_out}
        results += [vt.Result(by_id[e["id"]], reason=e["reason"],
                              compile_failed=e["reason"].startswith("analytics compilation failed:"))
                    for e in excluded]
        results.sort(key=lambda r: r.benchmark.id)
        rows = []
        for r in results:
            row = vt.result_json(r)
            winner = min(r.benchmark.measured, key=lambda v: (r.benchmark.measured[v], v)) if r.eligible else None
            row.update(status="scored" if r.eligible else "compile-failed" if r.compile_failed else "excluded",
                       top1_correct=row["predicted_best"] == winner if r.eligible else None)
            rows.append(row)
        return rows, results, provenance, policy.identity

    rows = []
    for index, benchmark in enumerate(held_out, 1):
        print(f"Evaluate [{index}/{len(held_out)}] {benchmark.id}", file=sys.stderr, flush=True)
        artifacts = args.artifacts_dir / "held-out" / vt.report_name(benchmark.id) if args.artifacts_dir else None
        try:
            result = vt.compile_report(clang, benchmark, False, args.timeout,
                meta_script=args.llvm_path / "utils/vplan-meta-compile", artifacts_dir=artifacts,
                weights=weights_path)
            if not result.returncode and result.candidate_status["policy"] != policy.identity:
                raise vt.ToolError("compiler driver and evaluator selected different policies")
            row = selection_row(benchmark, result, metadata["measurement_protocol"].get("vlen_bits"))
            row["artifact"] = str(result.artifact_root / "backend") if artifacts else None
        except (vt.ToolError, OSError, ValueError, KeyError) as exc:
            row = selection_row(benchmark, SimpleNamespace(returncode=1, stderr=str(exc)))
        rows.append(row)
        if not row["eligible"]:
            print(f"  {row['status']}: {row['reason'] or ''}", file=sys.stderr, flush=True)
    return rows, [], [], policy.identity


def summarize(rows, rankings, metric_mode):
    summary = summarize_rows(rows)
    if metric_mode == "ranking":
        summary.update(vt.summary_json(rankings))
    return summary


def fold_statistics(folds):
    """Unweighted fold statistics, distinct from pooled benchmark-level metrics."""
    paths = [("coverage",), ("top1", "exact"),
             *( ("top1_regret", k) for k in ("mean", "median", "p95") )]
    if any("spearman" in f.get("metrics", {}) for f in folds):
        paths += [("spearman", "mean"), ("spearman", "median"),
                  ("topk", 2, "exact"), ("topk", 2, "overlap")]
    output = {}
    for path in paths:
        values = []
        for fold in folds:
            value = fold.get("metrics", {})
            for key in path:
                value = value.get(key) if isinstance(value, dict) else None
            if value is not None:
                values.append(value)
        output[".".join(map(str, path))] = dict(
            n=len(values), mean=statistics.mean(values) if values else None,
            std=statistics.stdev(values) if len(values) > 1 else None)
    return output


def print_metrics(label, metrics):
    def percent(value):
        return f"{value:.2%}" if value is not None else "N/A"
    regret = metrics["top1_regret"]
    print(f"{label}: scored={metrics['scored']}/{metrics['total']}, "
          f"coverage={percent(metrics['coverage'])}, Top-1={percent(metrics['top1']['exact'])}, "
          f"regret mean/median/p95={percent(regret['mean'])}/{percent(regret['median'])}/{percent(regret['p95'])}",
          flush=True)


def main(argv=None):
    args = parse_args(argv)
    policy = load_policy(args.llvm_path)
    if not policy.supports_fit:
        raise vt.ToolError("cross validation fitting requires a fittable policy")
    benchmarks, metadata = vt.load_database(args.db, split=None)
    folds = make_folds([b.id for b in benchmarks], args.split_seed)
    dataset_fingerprint = fingerprint(benchmarks)
    manifest = dict(schema_version=1, group_by="benchmark_id", n_folds=FOLDS,
                    split_seed=args.split_seed, algorithm="sorted-ids-python-random-shuffle-round-robin-v1",
                    dataset=metadata, dataset_fingerprint=dataset_fingerprint,
                    benchmarks=len(benchmarks), measurements=sum(len(b.measured) for b in benchmarks),
                    folds=[dict(fold=i, held_out_ids=ids) for i, ids in enumerate(folds)])
    manifest_hash = cal.digest_json(manifest)
    if args.output_dir.exists() and (not args.output_dir.is_dir() or any(args.output_dir.iterdir())):
        raise vt.ToolError("--output-dir must be new or empty; existing results are never overwritten")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    vt.write_json(args.output_dir / "folds.json", manifest)
    if args.skip_build:
        clang = (args.build_dir or args.llvm_path / "build-vplan-tools") / "bin/clang"
        if not all(p.is_file() and os.access(p, os.X_OK) for p in (clang, clang.parent / "llvm-extract")):
            raise vt.ToolError("existing clang/llvm-extract binaries are missing or not executable")
    else:
        clang = vt.ensure_compiler(args.llvm_path, args.build_dir, args.jobs)
    identity = cal.collector_identity(clang, args.llvm_path / "utils/vplan-meta-compile")
    source_splits = {b.id: b.kind for b in benchmarks}
    report = dict(schema_version=1, evaluation="benchmark-id-5-fold-cv", metric_mode=args.metric_mode,
                  database=str(args.db), metadata=metadata, dataset_fingerprint=dataset_fingerprint,
                  folds_sha256=manifest_hash, split_seed=args.split_seed, fit_seed=args.fit_seed,
                  compiler=str(clang), compiler_identity=identity, policy=policy.identity,
                  python_version=sys.version, torch_version=torch.__version__,
                  cv_implementation=cal.digest_file(Path(__file__)),
                  folds=[], complete=False, successful=False)
    all_rows, all_rankings = [], []
    started = time.perf_counter()
    print(f"CV: {len(benchmarks)} benchmarks; held-out sizes={[len(f) for f in folds]}; "
          f"split seed={args.split_seed}, fit seed={args.fit_seed}", flush=True)
    for index, held_out_ids in enumerate(folds):
        fold_dir = args.output_dir / f"fold-{index}"
        fold_dir.mkdir()
        held_out_set = set(held_out_ids)
        train = [replace(b, kind="train") for b in benchmarks if b.id not in held_out_set]
        held_out = [replace(b, kind="held-out") for b in benchmarks if b.id in held_out_set]
        train_ids = [b.id for b in train]
        context = dict(fold=index, folds_sha256=manifest_hash, dataset_fingerprint=dataset_fingerprint,
                       group_by="benchmark_id", split_seed=args.split_seed, fit_seed=args.fit_seed,
                       held_out_ids=held_out_ids)
        fold_args = argparse.Namespace(**vars(args))
        if args.artifacts_dir:
            fold_args.artifacts_dir = args.artifacts_dir / f"fold-{index}"
        fold = dict(fold=index, train_ids=train_ids, held_out_ids=held_out_ids, status="failed")
        fold_started = time.perf_counter()
        print(f"Fold {index}: train={len(train)}, held-out={len(held_out)}", flush=True)
        try:
            weights_path = fold_dir / "weights.json"
            artifact = fit_fold(train, clang, fold_args, identity, metadata, context, weights_path)
            validate_fold_weights(weights_path, metadata, identity, train_ids, held_out, context)
            rows, rankings, provenance, policy_identity = evaluate_fold(
                held_out, clang, fold_args, identity, metadata, weights_path)
            if sorted(r["id"] for r in rows) != held_out_ids:
                raise vt.ToolError("evaluation did not return exactly the held-out benchmark IDs")
            for row in rows:
                row.update(fold=index, source_split=source_splits[row["id"]])
            metrics = summarize(rows, rankings, args.metric_mode)
            fold.update(status="ok" if metrics["scored"] and not metrics["compile_failed"] else "failed",
                        weights=str(weights_path), weights_sha256=cal.digest_file(weights_path),
                        policy=policy_identity, fitting=artifact["fitting"],
                        training_excluded=artifact["excluded"], metrics=metrics)
            vt.write_json(fold_dir / "evaluation.json", dict(
                schema_version=1, metric_mode=args.metric_mode, cv=context, policy=policy_identity,
                weights_sha256=fold["weights_sha256"], metrics=metrics, benchmarks=rows, provenance=provenance))
            all_rows.extend(rows)
            all_rankings.extend(rankings)
            print_metrics(f"Fold {index}", metrics)
        except vt.ToolError as exc:
            fold["error"] = str(exc)
            print(f"Fold {index} failed: {exc}", file=sys.stderr, flush=True)
        fold["elapsed_seconds"] = time.perf_counter() - fold_started
        vt.write_json(fold_dir / "summary.json", fold)
        report["folds"].append(fold)
        # Keep an explicitly partial report if a run is interrupted later.
        report.update(elapsed_seconds=time.perf_counter() - started,
                      benchmarks=sorted(all_rows, key=lambda r: r["id"]),
                      metrics=summarize(all_rows, all_rankings, args.metric_mode),
                      fold_statistics=fold_statistics(report["folds"]))
        vt.write_json(args.output_dir / "summary.json", report)
    report["complete"] = sorted(r["id"] for r in all_rows) == sorted(source_splits)
    report["successful"] = report["complete"] and all(f["status"] == "ok" for f in report["folds"])
    vt.write_json(args.output_dir / "summary.json", report)
    print_metrics("Pooled OOF" if report["complete"] else "Partial held-out results (incomplete CV)", report["metrics"])
    for metric, values in report["fold_statistics"].items():
        print(f"Fold mean/std {metric}: {values['mean']} / {values['std']} (n={values['n']})")
    print(f"Complete={report['complete']}; successful={report['successful']}; "
          f"elapsed={report['elapsed_seconds']:.1f}s; results={args.output_dir / 'summary.json'}", flush=True)
    return 0 if report["successful"] else 1
