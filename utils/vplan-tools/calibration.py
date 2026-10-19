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
from cost_model import CostModel, DTYPE, MODEL_VERSION, PARAMETERS, P

CACHE_VERSION = 1


def digest_file(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def digest_json(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def collector_identity(clang, meta_script):
    return {
        "cache_version": CACHE_VERSION,
        "compiler": digest_file(clang),
        "extractor": digest_file(clang.parent / "llvm-extract"),
        "driver": digest_file(meta_script),
        "collector": digest_file(Path(__file__)),
        "tools": digest_file(Path(vt.__file__)),
        "headers": {p.name: digest_file(p) for p in sorted((vt.TOOLS / "include").iterdir()) if p.is_file()},
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
            stop_after_ra=True)
        if result.returncode:
            lines = [l for l in result.stderr.splitlines() if "error:" in l or "meta-compiler:" in l]
            raise vt.ToolError("analytics compilation failed: " + " | ".join(lines[-2:] or [result.stderr[-1500:]]))
        backend = result.artifact_root / "backend"
        manifest = json.loads((backend / "candidates.json").read_text())
        rows = []
        for index, row in enumerate(manifest["candidates"]):
            if row["function"] != "selected_kernel" or not row["probeable"]:
                continue
            prefix = backend / f"probe-{index:04d}"
            rows.append({"candidate": row,
                         "analytics": json.loads(prefix.with_suffix(".analytics.json").read_text())})
        bundle = {"key": key, "identity": identity, "run_id": manifest["run_id"], "rows": rows}
        validate_bundle(bundle)
        vt.write_json(path, bundle)
        return bundle


def validate_bundle(bundle):
    rows = bundle["rows"]
    if not rows:
        raise vt.ToolError("no candidates for selected_kernel")
    loops = {(r["candidate"]["function"], r["candidate"]["loop"]) for r in rows}
    if len(loops) != 1 or next(iter(loops))[0] != "selected_kernel":
        raise vt.ToolError("ambiguous selected_kernel loops")
    ids = [r["candidate"]["id"] for r in rows]
    if len(ids) != len(set(ids)):
        raise vt.ToolError("duplicate analytics candidate")
    for r in rows:
        a, c = r["analytics"], r["candidate"]
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
    observations, scalar_indices, examples, excluded, provenance = [], [], [], [], []
    for index, b in enumerate(benchmarks, 1):
        print(f"[{index}/{len(benchmarks)}] {b.id}", file=sys.stderr, flush=True)
        try:
            if len(b.measured) < 2:
                raise vt.ToolError("fewer than two measured VFs")
            pairs = make_pairs(b.measured, args.pair_threshold, args.weight_saturation) if fitting else []
            if fitting and not pairs:
                raise vt.ToolError("no pairs above the measurement threshold")
            bundle = collect(b, clang, args, identity)
            # Unmeasured VFs cannot invalidate a measured ranking. Unsupported
            # alternatives for one VF are ignored only if another plan supplies
            # a usable prediction, matching the report evaluator's semantics.
            rows, unsupported = [], {}
            for row in bundle["rows"]:
                vf = row["candidate"]["vf"]
                if vf != "f1" and vf not in {f"s{v}" for v in b.measured}:
                    continue
                try:
                    CostModel([row["analytics"]])
                    rows.append(row)
                except vt.ToolError as exc:
                    unsupported[vf] = str(exc)
            scalars = [i for i, r in enumerate(rows) if r["candidate"]["vf"] == "f1"]
            if len(scalars) != 1:
                raise vt.ToolError("missing or ambiguous scalar reference: " + unsupported.get("f1", ""))
            local = [r["analytics"] for r in rows]
            expected_vlen = metadata["measurement_protocol"].get("vlen_bits")
            if expected_vlen and any(a["VLen"] != expected_vlen for a in local):
                raise vt.ToolError("analytics VLEN differs from measured VLEN")
            groups = [[i for i, r in enumerate(rows) if r["candidate"]["vf"] == f"s{vf}"] for vf in sorted(b.measured)]
            missing = [vf for vf, g in zip(sorted(b.measured), groups) if not g]
            if missing:
                raise vt.ToolError("missing predicted costs for measured VF(s): " + ", ".join(
                    f"s{v} ({unsupported.get(f's{v}', 'not generated')})" for v in missing))
            model = CostModel(local)
            base = model.scores(torch.ones(P, dtype=DTYPE), [scalars[0]] * len(local))
            if not torch.isfinite(base).all() or not (base > 0).all():
                raise vt.ToolError("nonpositive or nonfinite candidate score")
            offset = len(observations)
            observations.extend(local)
            scalar_indices.extend([offset + scalars[0]] * len(local))
            examples.append(Example(b, [[offset + i for i in g] for g in groups], sorted(b.measured), pairs))
            provenance.append({"id": b.id, "cache_key": bundle["key"], "run_id": bundle["run_id"]})
        except (vt.ToolError, OSError, ValueError, KeyError, TypeError) as exc:
            excluded.append({"id": b.id, "reason": str(exc)})
            print(f"  excluded: {exc}", file=sys.stderr, flush=True)
    if not examples:
        raise vt.ToolError("no eligible benchmarks; see exclusions above")
    return CostModel(observations), scalar_indices, examples, excluded, provenance


class RankingLoss:
    def __init__(self, model, scalars, examples, temperature, regularization):
        self.model, self.scalars, self.examples = model, scalars, examples
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
        scores = self.model.scores(log_multipliers.exp(), self.scalars)
        costs = torch.stack([scores[:, g].amin(1) for g in self.groups], 1).log()
        pair = (F.softplus((costs[:, self.left] - costs[:, self.right]) / self.temperature) * self.weights).sum(1)
        return pair + self.regularization * log_multipliers.square().mean(1)


def fit(model, scalars, examples, args):
    torch.set_num_threads(1)
    torch.use_deterministic_algorithms(True)
    generator = torch.Generator(device="cpu").manual_seed(args.seed)
    initial = torch.empty((args.starts, P), dtype=DTYPE).uniform_(math.log(.5), math.log(2), generator=generator)
    initial[0].zero_()
    active = torch.tensor([i in model.active for i in range(P)], dtype=DTYPE)
    lo, hi = math.log(args.min_multiplier), math.log(args.max_multiplier)
    initial.clamp_(lo, hi).mul_(active)
    logs = torch.nn.Parameter(initial)
    optimizer = torch.optim.Adam([logs], lr=args.learning_rate)
    objective = RankingLoss(model, scalars, examples, args.temperature, args.regularization)
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


def results_for(model, scalars, examples, weights):
    with torch.no_grad():
        scores = model.scores(weights, scalars)[0]
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
                          ("temperature", .1), ("weight-saturation", 1.25),
                          ("pair-threshold", .01), ("regularization", .001)):
        parser.add_argument("--" + name, type=finite_float, default=default)
    args = parser.parse_args(argv)
    if not (0 < args.min_multiplier <= 1 <= args.max_multiplier and args.min_multiplier < args.max_multiplier
            and args.learning_rate > 0 and args.temperature > 0 and args.weight_saturation > 1
            and args.pair_threshold >= 0 and args.regularization >= 0):
        parser.error("invalid fitting bounds, rate, temperature, saturation, threshold, or regularization")
    benchmarks, metadata, clang, identity = initialize(args, "tuning")
    model, scalars, examples, excluded, provenance = prepare(benchmarks, clang, args, identity, metadata, True)
    weights, diagnostics = fit(model, scalars, examples, args)
    results = results_for(model, scalars, examples, weights)
    initial = results_for(model, scalars, examples, torch.ones(P, dtype=DTYPE))
    config_keys = ("starts", "steps", "seed", "learning_rate", "min_multiplier", "max_multiplier",
                   "temperature", "weight_saturation", "pair_threshold", "regularization")
    artifact = {"schema_version": 1, "model_version": MODEL_VERSION,
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


def load_weights(path):
    try:
        value = json.loads(path.read_text())
        if value["schema_version"] != 1 or value["model_version"] != MODEL_VERSION:
            raise ValueError("unsupported weights schema/model version")
        if set(value["multipliers"]) != set(PARAMETERS):
            raise ValueError("wrong parameter set")
        if (not isinstance(value["dataset"], dict) or not isinstance(value["compiler_identity"], dict)
                or not isinstance(value["tuning_ids"], list)
                or not all(isinstance(i, str) for i in value["tuning_ids"])):
            raise ValueError("missing or invalid training provenance")
        numbers = [value["multipliers"][p] for p in PARAMETERS]
        if any(type(x) not in (int, float) or not math.isfinite(x) or x <= 0 for x in numbers):
            raise ValueError("multipliers must be finite and positive")
        return value, torch.tensor(numbers, dtype=DTYPE)
    except (OSError, KeyError, TypeError, ValueError) as exc:
        raise vt.ToolError(f"invalid weights {path}: {exc}") from exc


def evaluate_weights_main(argv=None):
    parser = common_parser("Evaluate a fitted analytical model on validation data only.")
    parser.add_argument("--weights", required=True, type=vt.resolved_path)
    parser.add_argument("--json-output", type=vt.resolved_path)
    parser.add_argument("--exclude-reasons", action="store_true")
    args = parser.parse_args(argv)
    artifact, weights = load_weights(args.weights)
    benchmarks, metadata, clang, identity = initialize(args, "validation")
    if artifact["dataset"] != metadata:
        raise vt.ToolError("weights were fitted against different dataset metadata")
    if artifact["compiler_identity"] != identity:
        raise vt.ToolError("weights/compiler extraction context differs; refit with this toolchain")
    overlap = sorted(set(artifact["tuning_ids"]) & {b.id for b in benchmarks})
    if overlap:
        raise vt.ToolError("validation contains IDs used to fit these weights: " + ", ".join(overlap))
    model, scalars, examples, excluded, provenance = prepare(benchmarks, clang, args, identity, metadata, False)
    results = results_for(model, scalars, examples, weights)
    by_id = {b.id: b for b in benchmarks}
    results += [vt.Result(by_id[e["id"]], reason=e["reason"]) for e in excluded]
    results.sort(key=lambda r: r.benchmark.id)
    vt.print_summary("Validation: fitted continuous model", results)
    vt.print_worst_regrets(results)
    if args.exclude_reasons:
        for e in excluded:
            print(f"{e['id']}: {e['reason']}")
    if args.json_output:
        vt.write_json(args.json_output, {"schema_version": 1, "model_version": MODEL_VERSION,
            "weights_sha256": digest_file(args.weights), "metadata": metadata,
            "metrics": vt.summary_json(results), "provenance": provenance,
            "benchmarks": [vt.result_json(r) for r in results]})
    return 0
