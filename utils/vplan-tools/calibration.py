"""Raw-analytics collection, weighted pairwise fitting, and holdout evaluation."""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import sys
import tempfile

import torch
import torch.nn.functional as F

import vplan_tools as vt
from cost_model import CostModel, DTYPE, MODEL_VERSION, PARAMETERS, P, same_context, load_weights
from observations import validate_manifest, bind_observation

CACHE_VERSION = 4


def digest_file(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def digest_json(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def collector_identity(clang, meta_script):
    directory = meta_script.parent / "vplan-tools"
    return {
        "cache_version": CACHE_VERSION,
        "compiler": digest_file(clang),
        "extractor": digest_file(clang.parent / "llvm-extract"),
        "driver": digest_file(meta_script),
        "collector": digest_file(directory / "calibration.py"),
        "tools": digest_file(directory / "vplan_tools.py"),
        "protocol": digest_file(directory / "observations.py"),
        "headers": {p.name: digest_file(p) for p in sorted((directory / "include").iterdir()) if p.is_file()},
    }


def collect(benchmark, clang, args, identity):
    """Cache only compiler observations, never measurements or learned scores."""
    key = digest_json({"identity": identity, "source": benchmark.source,
                       "flags": benchmark.compile_args})
    path = args.cache_dir / f"{key}.json"
    if path.exists():
        try:
            cached = json.loads(path.read_text())
            if cached["key"] != key or cached["identity"] != identity:
                raise ValueError("identity mismatch")
            return validate_bundle(cached)
        except (KeyError, ValueError, TypeError) as exc:
            raise vt.ToolError(f"invalid analytics cache {path}: {exc}; remove this entry and retry") from exc
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="collect-", dir=args.cache_dir) as td:
        artifact_dir = (args.artifacts_dir / benchmark.kind / vt.report_name(benchmark.id)
                        if args.artifacts_dir else Path(td))
        result = vt.compile_report(clang, benchmark, False, args.timeout,
            meta_script=args.llvm_path / "utils/vplan-meta-compile", artifacts_dir=artifact_dir,
            stop_after_ra=True, analytics_only=True)
        if result.returncode:
            lines = [l for l in result.stderr.splitlines() if "error:" in l or "meta-compiler:" in l]
            raise vt.ToolError("analytics compilation failed: " + " | ".join(lines[-2:] or [result.stderr[-1500:]]))
        backend = result.artifact_root / "backend"
        manifest = json.loads((backend / "candidates.json").read_text())
        validate_manifest(manifest, manifest["run_id"])
        statuses = json.loads((backend / "candidate-status.json").read_text())["candidates"]
        loops = {(r["function"], r["loop"]): r for r in manifest["loops"]}
        rows = []
        for index, row in enumerate(manifest["candidates"]):
            if row["function"] != "selected_kernel":
                continue
            prefix = backend / f"probe-{index:04d}"
            status = statuses[index]
            observation = (bind_observation(json.loads(prefix.with_suffix(".analytics.json").read_text()),
                           row, loops[(row["function"], row["loop"])], manifest["run_id"])
                           if status["status"] == "collected" else None)
            rows.append({"candidate": row, "analytics": observation,
                         "reason": status.get("reason", "")})
        bundle = {"version": CACHE_VERSION, "loops": manifest["loops"], "key": key, "identity": identity, "run_id": manifest["run_id"], "rows": rows}
        validate_bundle(bundle)
        vt.write_json(path, bundle)
        return bundle


def validate_bundle(bundle):
    if bundle["version"] != CACHE_VERSION:
        raise vt.ToolError("unsupported analytics cache version; recollect")
    rows = bundle["rows"]
    if not rows:
        raise vt.ToolError("no candidates for selected_kernel")
    loops = {(r["function"], r["loop"]) for r in bundle["loops"] if r["function"] == "selected_kernel"}
    if len(loops) != 1 or next(iter(loops))[0] != "selected_kernel":
        raise vt.ToolError("ambiguous selected_kernel loops")
    ids = [r["candidate"]["id"] for r in rows]
    if len(ids) != len(set(ids)):
        raise vt.ToolError("duplicate analytics candidate")
    for r in rows:
        a, c = r["analytics"], r["candidate"]
        if a is None:
            continue
        if (a["RunID"] != bundle["run_id"] or a["Candidate"] != c["id"]
                or a["Function"] != c["function"]
                or ("s" if a["ScalableVF"] else "f") + str(a["VF"]) != c["vf"]):
            raise vt.ToolError("analytics identity mismatch")
    return bundle


@dataclass
class Example:
    benchmark: vt.Benchmark
    groups: list[list[int]]
    vfs: list[int]
    pairs: list[tuple[int, int, float]]


def make_pairs(measured, threshold, saturation):
    vfs = sorted(measured)
    pairs = []
    # Fraction comparison makes the inclusive 1% boundary exact for integer cycles.
    from fractions import Fraction
    cutoff = Fraction(str(threshold))
    for ai in range(len(vfs)):
        for bi in range(ai + 1, len(vfs)):
            a, b = sorted((ai, bi), key=lambda i: (measured[vfs[i]], vfs[i]))
            fast, slow = measured[vfs[a]], measured[vfs[b]]
            if fast <= 0 or slow <= 0:
                raise vt.ToolError("pairwise fitting requires positive cycles")
            if Fraction(slow - fast, fast) <= cutoff:
                continue
            pairs.append((a, b, min(1., math.log(slow / fast) / math.log(saturation))))
    return pairs


def prepare(benchmarks, clang, args, identity, metadata, fitting):
    observations, examples, excluded, provenance = [], [], [], []
    for index, b in enumerate(benchmarks, 1):
        print(f"[{index}/{len(benchmarks)}] {b.id}", file=sys.stderr, flush=True)
        try:
            bundle = collect(b, clang, args, identity)
            candidate_vfs = {int(r["candidate"]["vf"][1:]) for r in bundle["rows"]
                             if r["candidate"]["vf"].startswith("s")}
            b = vt.restrict_measurements(b, candidate_vfs)
            if len(b.measured) < 2:
                raise vt.ToolError("fewer than two compiler scalable VFs with measurements")
            pairs = make_pairs(b.measured, args.pair_threshold, args.weight_saturation) if fitting else []
            if fitting and not pairs:
                raise vt.ToolError("no pairs above the measurement threshold")
            # The compiler defines the comparison set before analytics filtering.
            # Unsupported alternatives are ignored only when another plan for
            # the same VF supplies a usable prediction.
            rows, unsupported = [], {}
            for row in bundle["rows"]:
                vf = row["candidate"]["vf"]
                if vf not in {f"s{v}" for v in b.measured}:
                    continue
                try:
                    if row["analytics"] is None:
                        raise vt.ToolError(row["reason"])
                    CostModel([row["analytics"]])
                    rows.append(row)
                except vt.ToolError as exc:
                    unsupported[vf] = str(exc)
            local = [r["analytics"] for r in rows]
            if any(not same_context(a, local[0]) for a in local):
                raise vt.ToolError("candidate analytics context mismatch")
            expected_vlen = metadata["measurement_protocol"].get("vlen_bits")
            if expected_vlen and any(a["VLen"] != expected_vlen for a in local):
                raise vt.ToolError("analytics VLEN differs from measured VLEN")
            groups = [[i for i, r in enumerate(rows) if r["candidate"]["vf"] == f"s{vf}"] for vf in sorted(b.measured)]
            missing = [vf for vf, g in zip(sorted(b.measured), groups) if not g]
            if missing:
                raise vt.ToolError("missing predicted costs for measured VF(s): " + ", ".join(
                    f"s{v} ({unsupported.get(f's{v}', 'not generated')})" for v in missing))
            model = CostModel(local)
            base = model.scores(torch.ones(P, dtype=DTYPE))
            if not torch.isfinite(base).all() or not (base > 0).all():
                raise vt.ToolError("nonpositive or nonfinite candidate score")
            offset = len(observations)
            observations.extend(local)
            examples.append(Example(b, [[offset + i for i in g] for g in groups], sorted(b.measured), pairs))
            provenance.append({"id": b.id, "cache_key": bundle["key"], "run_id": bundle["run_id"],
                               "evaluated_vfs": sorted(b.measured),
                               "ignored_measured_vfs": sorted(b.ignored_measured)})
        except (vt.ToolError, OSError, ValueError, KeyError, TypeError) as exc:
            excluded.append({"id": b.id, "reason": str(exc)})
            print(f"  excluded: {exc}", file=sys.stderr, flush=True)
    if not examples and fitting:
        raise vt.ToolError("no eligible benchmarks; see exclusions above")
    return CostModel(observations), examples, excluded, provenance


class RankingLoss:
    def __init__(self, model, examples, temperature, regularization):
        self.model, self.examples = model, examples
        self.temperature, self.regularization = temperature, regularization
        self.groups = [torch.tensor(g) for e in examples for g in e.groups]
        left, right, weights = [], [], []
        offset = 0
        for e in examples:
            for a, b, w in e.pairs:
                left.append(offset + a); right.append(offset + b)
                weights.append(w / len(e.pairs) / len(examples))
            offset += len(e.vfs)
        self.left = torch.tensor(left, dtype=torch.long)
        self.right = torch.tensor(right, dtype=torch.long)
        self.weights = torch.tensor(weights, dtype=DTYPE)

    def __call__(self, log_multipliers):
        scores = self.model.scores(log_multipliers.exp())
        costs = torch.stack([scores[:, g].amin(1) for g in self.groups], 1).log()
        pair = (F.softplus((costs[:, self.left] - costs[:, self.right]) / self.temperature) * self.weights).sum(1)
        return pair + self.regularization * log_multipliers.square().mean(1)


def fit(model, examples, args):
    torch.set_num_threads(1)
    torch.use_deterministic_algorithms(True)
    generator = torch.Generator(device="cpu").manual_seed(args.seed)
    initial = torch.empty((args.starts, P), dtype=DTYPE).uniform_(math.log(.5), math.log(2), generator=generator)
    initial[0].zero_()
    active = torch.tensor([i in model.active for i in range(P)], dtype=DTYPE)
    lo = torch.tensor([math.log(args.min_multiplier)] * (P - 1) + [math.log(args.min_tail_scale)], dtype=DTYPE)
    hi = torch.tensor([math.log(args.max_multiplier)] * (P - 1) + [math.log(args.max_tail_scale)], dtype=DTYPE)
    initial.clamp_(lo, hi).mul_(active)
    logs = torch.nn.Parameter(initial)
    optimizer = torch.optim.Adam([logs], lr=args.learning_rate)
    objective = RankingLoss(model, examples, args.temperature, args.regularization)
    best = math.inf
    best_logs, best_start, best_step = None, None, None
    start_best = [math.inf] * args.starts
    baseline_loss = float(objective(torch.zeros((1, P), dtype=DTYPE))[0])
    for step in range(args.steps + 1):
        optimizer.zero_grad(set_to_none=True)
        effective = logs * active
        losses = objective(effective)
        if not torch.isfinite(losses).all():
            raise vt.ToolError("nonfinite fitting objective")
        detached = losses.detach()
        for i, value in enumerate(detached.tolist()):
            start_best[i] = min(start_best[i], value)
        index = int(detached.argmin())
        if float(detached[index]) < best:
            best, best_logs = float(detached[index]), effective[index].detach().clone()
            best_start, best_step = index, step
        if step % 200 == 0 or step == args.steps:
            print(f"Fit step {step}/{args.steps}: best objective={best:.8g}", file=sys.stderr, flush=True)
        if step < args.steps:
            losses.sum().backward()
            optimizer.step()
            with torch.no_grad():
                logs.clamp_(lo, hi).mul_(active)
    return best_logs.exp(), {"initial_objective": baseline_loss, "objective": best,
        "best_start": best_start, "best_step": best_step, "start_objectives": start_best,
        "pairs": sum(len(e.pairs) for e in examples), "benchmarks": len(examples)}


def results_for(model, examples, weights):
    if not examples:
        return []
    with torch.no_grad():
        scores = model.scores(weights)[0]
    return [vt.score_benchmark(e.benchmark, {vf: float(scores[g].min())
             for vf, g in zip(e.vfs, e.groups, strict=True)}) for e in examples]


def common_parser(description):
    parser = vt.argument_parser(description)
    parser.add_argument("--benchmark", help="one exact ID in the tool's fixed partition")
    parser.add_argument("--cache-dir", type=vt.resolved_path, default=vt.TOOLS / ".cache/analytics")
    parser.add_argument("--artifacts-dir", type=vt.resolved_path, help="retain raw compiler artifacts on cache misses")
    return parser


def finite_float(text):
    value = float(text)
    if not math.isfinite(value):
        raise argparse.ArgumentTypeError("must be finite")
    return value


def initialize(args, split):
    if args.compiler_mode != "meta":
        raise vt.ToolError("raw analytics require --compiler-mode meta")
    benchmarks, metadata = vt.load_database(args.db, split=split, benchmark_id=args.benchmark)
    if not benchmarks:
        raise vt.ToolError(f"no benchmarks in {split} partition" + (f": {args.benchmark}" if args.benchmark else ""))
    clang = vt.ensure_compiler(args.llvm_path, args.build_dir, args.jobs)
    return benchmarks, metadata, clang, collector_identity(clang, args.llvm_path / "utils/vplan-meta-compile")


def calibrate_main(argv=None):
    parser = common_parser("Fit shared analytical coefficients using tuning data only.")
    parser.add_argument("--output", required=True, type=vt.resolved_path, help="weights and tuning diagnostics JSON")
    parser.add_argument("--starts", type=vt.positive_int, default=16)
    parser.add_argument("--steps", type=vt.positive_int, default=2000)
    parser.add_argument("--seed", type=int, default=0)
    for name, default in (("learning-rate", .03), ("min-multiplier", .25), ("max-multiplier", 4.),
                          ("min-tail-scale", 1/64), ("max-tail-scale", 64.), ("temperature", .1), ("weight-saturation", 1.25),
                          ("pair-threshold", .01), ("regularization", .001)):
        parser.add_argument("--" + name, type=finite_float, default=default)
    args = parser.parse_args(argv)
    from selection import load_policy
    if not load_policy(args.llvm_path).supports_fit:
        raise vt.ToolError("this is a fixed ablation policy; fitting and weights are unsupported")
    if not (0 < args.min_multiplier <= 1 <= args.max_multiplier and args.min_multiplier < args.max_multiplier
            and 0 < args.min_tail_scale <= 1 <= args.max_tail_scale and args.min_tail_scale < args.max_tail_scale
            and args.learning_rate > 0 and args.temperature > 0 and args.weight_saturation > 1
            and args.pair_threshold >= 0 and args.regularization >= 0):
        parser.error("invalid fitting bounds, rate, temperature, saturation, threshold, or regularization")
    benchmarks, metadata, clang, identity = initialize(args, "tuning")
    model, examples, excluded, provenance = prepare(benchmarks, clang, args, identity, metadata, True)
    weights, diagnostics = fit(model, examples, args)
    results = results_for(model, examples, weights)
    initial = results_for(model, examples, torch.ones(P, dtype=DTYPE))
    config_keys = ("starts", "steps", "seed", "learning_rate", "min_multiplier", "max_multiplier",
                   "temperature", "weight_saturation", "pair_threshold", "regularization", "min_tail_scale", "max_tail_scale")
    artifact = {"schema_version": 2, "model_version": MODEL_VERSION,
        "multipliers": dict(zip(PARAMETERS, weights.tolist(), strict=True)),
        "default_multipliers": dict.fromkeys(PARAMETERS, 1.),
        "fixed": {"scalar_instruction": .5,
                  "unobserved_parameters": [p for i, p in enumerate(PARAMETERS) if i not in model.active]},
        "settings": {k: getattr(args, k) for k in config_keys}, "optimizer": "Adam/CPU/float64",
        "objective": "loop-mean weighted pairwise logistic + mean log-multiplier L2",
        "dataset": metadata, "compiler_identity": identity,
        "tuning_ids": [b.id for b in benchmarks],
        "tuning_fingerprint": digest_json([{"id": b.id, "source": b.source, "args": b.compile_args,
            "workload": b.workload, "measurements": b.measured} for b in benchmarks]),
        "provenance": provenance, "excluded": excluded, "fitting": diagnostics,
        "initial_metrics": vt.summary_json(initial), "fitted_metrics": vt.summary_json(results),
        "benchmarks": [vt.result_json(r) for r in results]}
    vt.write_json(args.output, artifact)
    vt.print_summary("Tuning: initial continuous model", initial)
    vt.print_summary("Tuning: fitted continuous model", results)
    print(f"Excluded before fitting: {len(excluded)}; weights: {args.output}")
    return 0


def evaluate_model_main(argv=None, *, fitted=False):
    parser = common_parser("Evaluate a fitted analytical model on validation data only.")
    parser.add_argument("--weights", required=fitted, type=vt.resolved_path)
    parser.add_argument("--json-output", type=vt.resolved_path)
    parser.add_argument("--exclude-reasons", action="store_true")
    args = parser.parse_args(argv)
    from selection import load_policy
    if not load_policy(args.llvm_path).supports_fit:
        raise vt.ToolError("this is a fixed ablation policy; fitting and weights are unsupported")
    artifact, weights = (load_weights(args.weights) if args.weights else
                         (None, torch.ones(P, dtype=DTYPE)))
    benchmarks, metadata, clang, identity = initialize(args, "validation")
    validate_weight_provenance(artifact, metadata, identity, benchmarks)
    model, examples, excluded, provenance = prepare(benchmarks, clang, args, identity, metadata, False)
    results = results_for(model, examples, weights)
    by_id = {b.id: b for b in benchmarks}
    results += [vt.Result(by_id[e["id"]], reason=e["reason"]) for e in excluded]
    results.sort(key=lambda r: r.benchmark.id)
    vt.print_summary("Validation: " + ("fitted" if artifact else "default") + " Python model", results)
    vt.print_worst_regrets(results)
    if args.exclude_reasons:
        for e in excluded:
            print(f"{e['id']}: {e['reason']}")
    if args.json_output:
        vt.write_json(args.json_output, {"schema_version": 2, "metric_mode": "ranking",
            "policy": load_policy(args.llvm_path, args.weights).identity, "model_version": MODEL_VERSION,
            "weights_sha256": digest_file(args.weights) if args.weights else None, "metadata": metadata,
            "metrics": vt.summary_json(results), "provenance": provenance,
            "benchmarks": [vt.result_json(r) for r in results]})
    return 0 if examples else 1


def evaluate_weights_main(argv=None):
    from selection_evaluation import evaluate_main
    return evaluate_main(argv, fitted=True)


def validate_weight_provenance(artifact, metadata, identity, benchmarks):
    if artifact is None:
        return
    if not all(k in artifact for k in ("dataset", "compiler_identity", "tuning_ids")):
        raise vt.ToolError("weights lack training provenance required for validation")
    if artifact["dataset"] != metadata:
        raise vt.ToolError("weights were fitted against different dataset metadata")
    if artifact["compiler_identity"] != identity:
        raise vt.ToolError("weights/compiler extraction context differs; refit with this toolchain")
    overlap = sorted(set(artifact["tuning_ids"]) & {b.id for b in benchmarks})
    if overlap:
        raise vt.ToolError("validation contains IDs used to fit these weights: " + ", ".join(overlap))
