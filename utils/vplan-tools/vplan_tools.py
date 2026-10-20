"""Shared implementation for the database-backed VPlan command-line tools."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
from contextlib import closing, contextmanager
from dataclasses import dataclass, field, replace
from fractions import Fraction
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import statistics
import subprocess
import sys
import tempfile


TOOLS = Path(__file__).resolve().parent
DEFAULT_LLVM = TOOLS.parents[1]
DEFAULT_DB = DEFAULT_LLVM / "dataset.sqlite"


from model_errors import ToolError


class ReportError(ToolError):
    pass


@dataclass
class Benchmark:
    id: str
    kind: str
    source: str
    compile_args: list[str]
    workload: dict
    measured: dict[int, int]
    ignored_measured: dict[int, int] = field(default_factory=dict)


def restrict_measurements(benchmark: Benchmark, candidate_vfs: set[int]) -> Benchmark:
    """Require measurements for every compiler VF, ignoring DB-only VFs."""
    missing = sorted(candidate_vfs - benchmark.measured.keys())
    if missing:
        raise ToolError("missing measurements for compiler VF(s): " +
                        ", ".join(f"s{vf}" for vf in missing))
    return replace(benchmark,
                   measured={vf: benchmark.measured[vf] for vf in sorted(candidate_vfs)},
                   ignored_measured=benchmark.ignored_measured | {
                       vf: cycles for vf, cycles in benchmark.measured.items()
                       if vf not in candidate_vfs})


def load_database(path: Path, benchmark_id: str | None = None) -> tuple[list[Benchmark], dict]:
    """Read all benchmarks (or one exact ID); split labels are metadata only."""
    path = path.expanduser().resolve()
    if not path.is_file():
        raise ToolError(f"database does not exist: {path}")
    try:
        with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)) as db:
            db.row_factory = sqlite3.Row
            db.execute("BEGIN")
            meta = db.execute("SELECT id, target, measurement_compiler, "
                              "measurement_protocol_json FROM dataset").fetchall()
            if len(meta) != 1 or meta[0]["id"] != 1:
                raise ValueError("expected exactly one dataset metadata row with id=1")
            metadata = dict(meta[0])
            metadata["measurement_protocol"] = json.loads(metadata.pop("measurement_protocol_json"))
            if (not isinstance(metadata["target"], str) or not metadata["target"]
                    or not isinstance(metadata["measurement_compiler"], str) or not metadata["measurement_compiler"]
                    or not isinstance(metadata["measurement_protocol"], dict)):
                raise ValueError("invalid dataset metadata")
            conditions, params = [], []
            if benchmark_id:
                conditions.append("b.id=?")
                params.append(benchmark_id)
            where = " WHERE " + " AND ".join(conditions) if conditions else ""
            rows = db.execute("SELECT b.id,b.split,b.source,b.compile_args_json,b.workload_json "
                              "FROM benchmarks b" + where + " ORDER BY b.id", params).fetchall()
            measurements: dict[str, dict[int, int]] = {}
            for row in db.execute(
                "SELECT m.benchmark_id,m.vf,m.cycles FROM measurements m "
                "JOIN benchmarks b ON b.id=m.benchmark_id" + where +
                " ORDER BY m.benchmark_id,m.vf", params):
                if any(type(row[k]) is not int or row[k] <= 0 for k in ("vf", "cycles")):
                    raise ValueError("VF and cycles must be positive integers")
                values = measurements.setdefault(row["benchmark_id"], {})
                if row["vf"] in values:
                    raise ValueError("duplicate measurement VF")
                values[row["vf"]] = row["cycles"]
            benchmarks = []
            for row in rows:
                args = json.loads(row["compile_args_json"])
                workload = json.loads(row["workload_json"])
                if (not isinstance(args, list) or not all(isinstance(a, str) for a in args)
                        or not isinstance(workload, dict)
                        or not isinstance(row["id"], str) or not row["id"]
                        or not isinstance(row["source"], str) or not row["source"]
                        or row["split"] not in ("tuning", "validation")):
                    raise ValueError(f"invalid benchmark: {row['id']}")
                benchmarks.append(Benchmark(row["id"], row["split"], row["source"], args,
                                            workload, measurements.get(row["id"], {})))
            return benchmarks, metadata
    except (sqlite3.Error, TypeError, ValueError, KeyError) as exc:
        raise ToolError(f"cannot read dataset database {path}: {exc}") from exc


def positive_int(text: str) -> int:
    value = int(text)
    if value < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return value


def resolved_path(text: str) -> Path:
    """Resolve explicit paths against the caller's CWD, including home expansion."""
    return Path(text).expanduser().resolve()


def argument_parser(description: str) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("--llvm-path", type=resolved_path, default=DEFAULT_LLVM,
                        help="LLVM source checkout (default: the checkout containing these tools)")
    parser.add_argument("--db", type=resolved_path,
                        default=os.environ.get("VPLAN_DB") or str(DEFAULT_DB),
                        help="dataset database (--db > VPLAN_DB > checkout/dataset.sqlite)")
    parser.add_argument("--build-dir", type=resolved_path,
                        help="build directory (default: LLVM checkout/build-vplan-tools)")
    parser.add_argument("--jobs", type=positive_int, default=2,
                        help="parallel build jobs (default: 2; fresh builds use one link job)")
    parser.add_argument("--timeout", type=positive_int, default=120,
                        help="timeout per compiler invocation in seconds (default: 120)")
    parser.add_argument("--compiler-mode", choices=("meta", "direct"), default="meta",
                        help="Python selection pipeline (default) or ordinary LLVM compilation")
    return parser


def run_build(command: list[str]) -> None:
    print("Build: " + " ".join(command), file=sys.stderr, flush=True)
    try:
        subprocess.run(command, check=True, stdout=sys.stderr, stderr=sys.stderr)
    except FileNotFoundError as exc:
        raise ToolError(f"build tool not found: {command[0]}") from exc
    except subprocess.CalledProcessError as exc:
        raise ToolError(f"LLVM build failed (exit {exc.returncode}); see build log above") from exc


@contextmanager
def build_lock(build: Path):
    """Serialize tool-owned CMake/Ninja operations at a stable build path."""
    build.mkdir(parents=True, exist_ok=True)
    with (build / ".vplan-tools.lock").open("a+") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def ensure_compiler(source: Path, build: Path | None, jobs: int) -> Path:
    source = source.expanduser().resolve()
    if not (source / "llvm/CMakeLists.txt").is_file() or not (source / "clang").is_dir():
        raise ToolError(f"--llvm-path must be an LLVM source checkout: {source}")
    build = (build.expanduser() if build else source / "build-vplan-tools").resolve()
    with build_lock(build):
        return _ensure_compiler(source, build, jobs)


def _ensure_compiler(source: Path, build: Path, jobs: int) -> Path:
    cache_path = build / "CMakeCache.txt"
    if cache_path.exists():
        cache = {}
        for line in cache_path.read_text().splitlines():
            match = re.match(r"([^:#/][^:]*):[^=]+=(.*)", line)
            if match:
                cache[match[1]] = match[2]
        if Path(cache.get("CMAKE_HOME_DIRECTORY", "")).resolve() != source / "llvm":
            raise ToolError(f"build directory belongs to another source tree: {build}")
        enabled = {"ON", "YES", "TRUE", "1"}
        if not any(cache.get(key, "").upper() in enabled
                   for key in ("LLVM_ENABLE_ASSERTIONS", "LLVM_ENABLE_DUMP")):
            raise ToolError("build needs LLVM_ENABLE_ASSERTIONS=ON or LLVM_ENABLE_DUMP=ON; "
                            "choose a fresh --build-dir")
        if "clang" not in cache.get("LLVM_ENABLE_PROJECTS", "").split(";"):
            raise ToolError("build does not enable clang; choose a fresh --build-dir")
        if not {"RISCV", "all"}.intersection(cache.get("LLVM_TARGETS_TO_BUILD", "").split(";")):
            raise ToolError("build does not enable RISCV; choose a fresh --build-dir")
        # LLVM resolves Git metadata paths during configuration. Converting a
        # checkout to a submodule moves .git/logs/HEAD; Ninja cannot repair that
        # missing dependency itself. Refresh the graph, preserving cache options
        # and compiled objects, before asking the build system what is outdated.
        run_build(["cmake", "-S", str(source / "llvm"), "-B", str(build)])
    else:
        run_build([
            "cmake", "-S", str(source / "llvm"), "-B", str(build), "-G", "Ninja",
            "-DCMAKE_BUILD_TYPE=Release", "-DLLVM_ENABLE_ASSERTIONS=ON",
            "-DLLVM_ENABLE_PROJECTS=clang", "-DLLVM_TARGETS_TO_BUILD=RISCV",
            "-DLLVM_INCLUDE_TESTS=OFF", "-DLLVM_INCLUDE_EXAMPLES=OFF",
            "-DLLVM_INCLUDE_BENCHMARKS=OFF", "-DLLVM_PARALLEL_LINK_JOBS=1",
            "-DCLANG_ENABLE_STATIC_ANALYZER=OFF", "-DCLANG_ENABLE_OBJC_REWRITER=OFF",
            "-DCLANG_INCLUDE_TESTS=OFF",
        ])
    # Always ask the build system: checking the executable mtime misses headers,
    # generated files, changed build commands, and library dependencies.
    run_build(["cmake", "--build", str(build), "--target", "clang",
               "clang-resource-headers", "llvm-extract", "--parallel", str(jobs)])
    clang = build / "bin/clang"
    try:
        probe = subprocess.run(
            [str(clang), "-x", "c", "-c", os.devnull, "-o", os.devnull,
             "-mllvm", "--help-hidden"], capture_output=True, text=True, timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ToolError(f"cannot run built compiler {clang}: {exc}") from exc
    help_text = probe.stdout + probe.stderr
    if probe.returncode or not all(re.search(r"--" + flag + r"\b", help_text)
                                  for flag in ("print-vplans", "print-detailed-vplans")):
        raise ToolError(f"built compiler does not expose both VPlan reporting flags: {clang}")
    return clang


def normalized_flags(flags: list[str]) -> list[str]:
    if not isinstance(flags, list) or not all(isinstance(f, str) for f in flags):
        raise ToolError("compile_args_json must contain an array of strings")
    out = []
    index = 0
    while index < len(flags):
        flag = flags[index]
        if flag == "-x":
            if index + 1 == len(flags) or flags[index + 1] not in ("c", "c++"):
                raise ToolError("recorded language must be c or c++")
            index += 2
            continue
        # These are build-container paths, not dependencies of the isolated kernel.
        if flag in ("-I", "-idirafter", "-isystem", "--sysroot", "-isysroot"):
            if index + 1 == len(flags):
                raise ToolError(f"missing argument after {flag}")
            index += 2
            continue
        if flag.startswith(("-I", "--sysroot=", "-isystem=", "-idirafter=")):
            index += 1
            continue
        if flag == "-mllvm":
            if index + 1 == len(flags):
                raise ToolError("missing argument after -mllvm")
            option = flags[index + 1].lstrip("-")
            if option.split("=", 1)[0] in ("force-vector-width", "riscv-v-register-bit-width-lmul",
                                           "print-vplans", "print-detailed-vplans"):
                if "=" not in option and option in ("force-vector-width", "riscv-v-register-bit-width-lmul"):
                    raise ToolError(f"expected recorded -{option}=VALUE syntax")
                index += 2
                continue
            out.extend(flags[index:index + 2])
            index += 2
            continue
        out.append(flag)
        index += 1
    return out


def benchmark_flags(benchmark: Benchmark) -> list[str]:
    if not benchmark.compile_args:
        raise ToolError("no recorded compilation flags")
    return normalized_flags(benchmark.compile_args) + [
        "-mllvm", "-riscv-v-register-bit-width-lmul=8",
        "-nostdlibinc", "-I", str(TOOLS / "include"), "-fno-color-diagnostics",
    ]


def source_name(benchmark: Benchmark) -> str:
    args = benchmark.compile_args
    language = "c"
    for i, arg in enumerate(args):
        if arg == "-x" and i + 1 < len(args):
            language = args[i + 1]
    return "kernel.cpp" if language == "c++" else "kernel.c"


def compile_report(clang: Path, benchmark: Benchmark, detail: bool, timeout: int,
                   compiler_mode: str = "meta", meta_script: Path | None = None,
                   artifacts_dir: Path | None = None,
                   *, stop_after_ra: bool = False, analytics_only: bool = False,
                   weights: Path | None = None, spill_count_unit: str | None = None) -> subprocess.CompletedProcess:
    flags = benchmark_flags(benchmark)
    with tempfile.TemporaryDirectory(prefix="vplan-tools-") as temporary:
        root = Path(temporary)
        if artifacts_dir is not None:
            artifacts_dir.mkdir(parents=True, exist_ok=True)
            root = Path(tempfile.mkdtemp(prefix="run-", dir=artifacts_dir))
        source = root / source_name(benchmark)
        source.write_text(benchmark.source)
        if compiler_mode == "meta":
            if meta_script is None:
                # The CLI supplies this explicitly, including for custom builds.
                if len(clang.resolve().parents) < 3:
                    raise ToolError("meta compilation requires an LLVM source checkout")
                meta_script = clang.resolve().parents[2] / "utils/vplan-meta-compile"
            if not meta_script.is_file():
                raise ToolError(f"LLVM checkout has no meta-compiler: {meta_script}")
            command = [sys.executable, str(meta_script), "--clang", str(clang),
                       "--input", str(source), "--work-dir", str(root / "backend"),
                       "--output", str(root / "final.ll"), "--emit", "llvm",
                       "--extract-function", "selected_kernel",
                       "--llvm-extract", str(clang.parent / "llvm-extract"),
                       "--timeout", str(timeout)]
            if stop_after_ra:
                command += ["--stop-after-ra"]
            if analytics_only:
                command += ["--analytics-only"]
            if weights:
                command += ["--weights", str(weights)]
            if spill_count_unit:
                command += ["--spill-count-unit", spill_count_unit]
            if detail:
                command.append("--detail")
            command += ["--", *flags]
            try:
                # The driver enforces the timeout separately for every probe.
                result = subprocess.run(command, capture_output=True, text=True, errors="replace")
                result.artifact_root = root
                if result.returncode == 0:
                    result.driver_result = json.loads((root / "backend/result.json").read_text())
                    result.manifest = json.loads((root / "backend/candidates.json").read_text())
                    result.candidate_status = json.loads((root / "backend/candidate-status.json").read_text())
                    excluded = result.driver_result.get("status") == "backend-observation-unavailable"
                    if not analytics_only and not excluded:
                        result.selection = json.loads((root / "backend/selection.json").read_text())
                    if not stop_after_ra and not excluded:
                        result.final_manifest = json.loads((root / "backend/final.manifest.json").read_text())
                    if detail:
                        result.stderr += (root / "backend/discover.stderr").read_text()
                        for log in sorted((root / "backend").glob("probe-*.stderr")):
                            result.stderr += log.read_text()
                return result
            except OSError as exc:
                raise ToolError(f"cannot execute meta-compiler: {exc}") from exc
        if compiler_mode != "direct":
            raise ToolError(f"unknown compiler mode: {compiler_mode}")
        frontend = root / "frontend.bc"
        kernel = root / "kernel.bc"
        from importlib.machinery import SourceFileLoader
        import types
        driver_path = meta_script or DEFAULT_LLVM / "utils/vplan-meta-compile"
        driver = types.ModuleType("vplan_meta_driver")
        driver.__file__ = str(driver_path)
        SourceFileLoader(driver.__name__, str(driver_path)).exec_module(driver)
        # Direct mode retains LLVM's ordinary cost policy. Extract before the
        # ordinary optimization pipeline rather than enabling the meta pipeline.
        preparation = [
            [str(clang), *flags, "-Xclang", "-disable-llvm-passes", "-emit-llvm", "-c", str(source), "-o", str(frontend)],
            [str(clang.parent / "llvm-extract"), str(frontend), "--func", "selected_kernel",
             "--recursive", "--keep-const-init", "-o", str(kernel)],
        ]
        command = [str(clang), *driver.resume_flags(flags), "-mllvm", "--print-vplans"]
        if detail:
            command += ["-mllvm", "--print-detailed-vplans"]
        command += ["-S", "-emit-llvm", str(kernel), "-o", os.devnull]
        try:
            for prep in preparation:
                result = subprocess.run(prep, capture_output=True, text=True,
                                        errors="replace", timeout=timeout)
                if result.returncode:
                    return result
            return subprocess.run(command, capture_output=True, text=True,
                                  errors="replace", timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            raise ToolError(f"compilation timed out after {timeout}s") from exc
        except OSError as exc:
            raise ToolError(f"cannot execute compiler: {exc}") from exc


def fields(line: str) -> dict[str, str]:
    return dict(re.findall(r"\b([a-z][a-z_-]*)=([^\s]+)", line))


def average_ranks(values: list) -> list[float]:
    indices = sorted(range(len(values)), key=values.__getitem__)
    ranks = [0.0] * len(values)
    start = 0
    while start < len(indices):
        end = start + 1
        while end < len(indices) and values[indices[end]] == values[indices[start]]:
            end += 1
        for position in range(start, end):
            ranks[indices[position]] = (start + 1 + end) / 2
        start = end
    return ranks


def spearman(predicted: list, measured: list) -> float | None:
    if len(predicted) < 2:
        return None
    x, y = average_ranks(predicted), average_ranks(measured)
    xmean, ymean = statistics.mean(x), statistics.mean(y)
    numerator = sum((a - xmean) * (b - ymean) for a, b in zip(x, y))
    denominator = math.sqrt(sum((a - xmean) ** 2 for a in x) * sum((b - ymean) ** 2 for b in y))
    return max(-1.0, min(1.0, numerator / denominator)) if denominator else None


@dataclass
class Result:
    benchmark: Benchmark
    scores: dict[int, Fraction | float] = field(default_factory=dict)
    reason: str | None = None
    compile_failed: bool = False

    @property
    def eligible(self) -> bool:
        return self.reason is None and len(self.benchmark.measured) >= 2

    @property
    def top1_regret(self) -> float | None:
        if not self.eligible:
            return None
        measured = self.benchmark.measured
        best_cycles = min(measured.values())
        if best_cycles <= 0:
            return None
        winner = min(measured, key=lambda vf: (self.scores[vf], vf))
        return measured[winner] / best_cycles - 1


def score_benchmark(benchmark: Benchmark, scores: dict[int, Fraction | float]) -> Result:
    measured = benchmark.measured
    missing = sorted(measured.keys() - scores.keys())
    if missing:
        return Result(benchmark, scores, "missing predicted costs for measured VF(s): " +
                      ", ".join(f"s{vf}" for vf in missing))
    if len(measured) < 2:
        return Result(benchmark, scores, f"insufficient successful measurements ({len(measured)})")
    return Result(benchmark, {vf: scores[vf] for vf in measured})


def percentile(values: list[float], probability: float) -> float:
    ordered = sorted(values)
    index = (len(ordered) - 1) * probability
    lower = math.floor(index)
    upper = math.ceil(index)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (index - lower)


def aggregate(results: list[Result]) -> dict:
    eligible = [r for r in results if r.eligible]
    metrics = {"total": len(results),
               "measured": sum(bool(r.benchmark.measured) for r in results),
               "scored": len(eligible), "excluded": len(results) - len(eligible),
               "compile_failed": sum(r.compile_failed for r in results), "topk": {}}
    for k in (1, 2):
        overlaps, exact = [], []
        for result in eligible:
            measured = result.benchmark.measured
            if len(measured) <= k:
                continue
            predicted_top = set(sorted(measured, key=lambda vf: (result.scores[vf], vf))[:k])
            measured_top = set(sorted(measured, key=lambda vf: (measured[vf], vf))[:k])
            overlaps.append(len(predicted_top & measured_top) / k)
            exact.append(predicted_top == measured_top)
        metrics["topk"][k] = {"n": len(overlaps),
                              "overlap": statistics.mean(overlaps) if overlaps else None,
                              "exact": statistics.mean(exact) if exact else None}
    correlations, regrets = [], []
    predicted_ties = measured_ties = 0
    for result in eligible:
        measured = result.benchmark.measured
        vfs = sorted(measured)
        predicted_values = [result.scores[vf] for vf in vfs]
        measured_values = [measured[vf] for vf in vfs]
        predicted_ties += len(set(predicted_values)) < len(vfs)
        measured_ties += len(set(measured_values)) < len(vfs)
        correlation = spearman(predicted_values, measured_values)
        if correlation is not None:
            correlations.append(correlation)
        regret = result.top1_regret
        if regret is not None:
            regrets.append(regret)
    metrics.update(correlations=correlations, regrets=regrets,
                   predicted_ties=predicted_ties, measured_ties=measured_ties)
    return metrics


def summary_json(results: list[Result]) -> dict:
    """Summarize numerical rankings with benchmark-level denominators."""
    metrics = aggregate(results)
    correlations = metrics.pop("correlations")
    regrets = metrics.pop("regrets")
    metrics["spearman"] = {
        "n": len(correlations),
        "mean": statistics.mean(correlations) if correlations else None,
        "median": statistics.median(correlations) if correlations else None,
    }
    metrics["top1_regret"] = {
        "n": len(regrets),
        "mean": statistics.mean(regrets) if regrets else None,
        "median": statistics.median(regrets) if regrets else None,
        "p95": percentile(regrets, .95) if regrets else None,
    }
    return metrics


def result_json(result: Result) -> dict:
    measured = result.benchmark.measured
    winner = min(measured, key=lambda vf: (result.scores[vf], vf)) if result.eligible else None
    return {
        "id": result.benchmark.id, "split": result.benchmark.kind,
        "eligible": result.eligible, "reason": result.reason,
        "compile_failed": result.compile_failed,
        "measured_cycles": {str(vf): cycles for vf, cycles in measured.items()},
        "ignored_measured_cycles": {str(vf): cycles for vf, cycles in result.benchmark.ignored_measured.items()},
        "scores": {str(vf): ({"numerator": cost.numerator, "denominator": cost.denominator}
                            if isinstance(cost, Fraction) else {"value": float(cost)})
                   for vf, cost in result.scores.items()},
        "predicted_best": winner, "top1_regret": result.top1_regret,
    }


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")
    temporary.replace(path)


def report_name(benchmark_id: str) -> str:
    return (re.sub(r"[^A-Za-z0-9_.-]", "_", benchmark_id) + "-"
            + hashlib.sha256(benchmark_id.encode()).hexdigest()[:8])


def print_vplans_main(argv: list[str] | None = None) -> int:
    parser = argument_parser("Print VPlan costs for a benchmark stored in a dataset database.")
    parser.add_argument("--benchmark", required=True, help="exact benchmark ID")
    parser.add_argument("--detail", action="store_true", help="include detailed cost calculations")
    parser.add_argument("--skip-build", action="store_true", help="use existing compiler binaries")
    parser.add_argument("--weights", type=resolved_path)
    parser.add_argument("--spill-count-unit", choices=("instruction", "register"))
    args = parser.parse_args(argv)
    from selection import load_policy
    if args.compiler_mode == "direct" and (args.weights or args.spill_count_unit):
        raise ToolError("direct compilation does not consume policy weights/options")
    benchmarks, _ = load_database(args.db, benchmark_id=args.benchmark)
    benchmark = next((b for b in benchmarks if b.id == args.benchmark), None)
    if benchmark is None:
        raise ToolError(f"unknown benchmark: {args.benchmark}")
    if args.compiler_mode == "meta":
        load_policy(args.llvm_path, args.weights, args.spill_count_unit)
    clang = ((args.build_dir or args.llvm_path / "build-vplan-tools") / "bin/clang" if args.skip_build
             else ensure_compiler(args.llvm_path, args.build_dir, args.jobs))
    if args.skip_build and not all(p.is_file() and os.access(p, os.X_OK) for p in (clang, clang.parent / "llvm-extract")):
        raise ToolError("existing clang/llvm-extract binaries are missing or not executable")
    result = compile_report(clang, benchmark, args.detail, args.timeout,
                            compiler_mode=args.compiler_mode,
                            meta_script=args.llvm_path.resolve() / "utils/vplan-meta-compile",
                            stop_after_ra=args.compiler_mode == "meta", weights=args.weights,
                            spill_count_unit=args.spill_count_unit)
    if args.compiler_mode == "meta" and result.returncode == 0:
        for row in result.candidate_status["candidates"]:
            print(f"{row['id']}: {row['status']} " + (f"score={row['score']:.12g}" if 'score' in row else row.get('reason', '')))
            if args.detail and 'breakdown' in row:
                print(json.dumps(row['breakdown'], sort_keys=True))
        for choice in getattr(result, "selection", {}).get("selections", []):
            print(f"{choice['function']} loop={choice['loop']}: " +
                  ("scalar (" + choice['reason'] + ")" if choice['scalar'] else "selected=" + choice['id']) +
                  " IC=1 epilogue=f0")
        if result.driver_result.get("status"):
            print(result.driver_result["status"] + ": " + result.driver_result["reason"])
    sys.stdout.write(result.stderr)
    if result.returncode:
        raise ToolError(f"compilation failed for {benchmark.id} (exit {result.returncode})")
    if args.compiler_mode == "direct" and "VPlan report_version=" not in result.stderr:
        print(f"{benchmark.id}: compilation succeeded but LLVM emitted no VPlan report", file=sys.stderr)
    return 0


def cli(main) -> None:
    try:
        raise SystemExit(main())
    except (ToolError, OSError, subprocess.CalledProcessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        raise SystemExit(130)
