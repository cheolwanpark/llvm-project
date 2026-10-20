# VPlan tools

The default model replays LLVM's middle-end reciprocal-throughput costs. It has
no fitted parameters and does not read measured cycles when selecting a plan.
The previous 19-parameter backend model, fitting objectives and five-fold CV have
been removed. PyTorch and NumPy are no longer required.

## Commands

Run from the repository root with Python 3.12+, `uv`, CMake, Ninja and a host C++
compiler:

```sh
uv sync --locked --project utils/vplan-tools
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate \
  --db search-dataset.sqlite --output-dir .cache/llvm-middle-end \
  --compare-baseline
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate-baseline \
  --db search-dataset.sqlite
uv run --project utils/vplan-tools python utils/vplan-tools/print-vplans \
  --db search-dataset.sqlite --benchmark hpcc/stream-add --detail
```

`evaluate` evaluates each benchmark once, without fitting or a train/test split.
`--benchmark ID` selects one exact ID. `--compare-baseline` also compiles through
ordinary LLVM, reporting selected VF and full decision agreement separately from
accuracy/regret against the measured cycles. `--output-dir` must be new or empty;
its `summary.json` includes every benchmark, exclusions, both sets of metrics,
comparison denominators, and completion status. Partial reports are marked
`complete: false`. Compiler failures make the command fail. Ambiguous multi-loop
kernels and missing measurements remain explicit exclusions.

`--artifacts-dir PATH` retains compiler inputs and manifests. Otherwise compiler
artifacts are temporary. `--skip-build --build-dir PATH` uses an existing compiler;
without `--skip-build` the tools configure/update `build-vplan-tools` in this
checkout and build Clang, resource headers and llvm-extract. The compiler must
support this checkout's VPlan protocol v3. `--jobs` defaults to 2 and `--timeout`
to 120 seconds per compiler invocation. `--llvm-path` selects another checkout
and its policy. `print-vplan` is an alias of `print-vplans`.

`--weights` is rejected by the fixed policy. The old optimizer, fold and ranking
CLI options are no longer supported. `--compiler-mode direct` remains available
for printing ordinary LLVM diagnostics; `evaluate-baseline` uses direct mode.

## Fixed model and selection

For each candidate, the compiler exports exact quarter-unit costs:

```text
C = middle_end.original / 4
  = (precomputed + vector_region + estimated_spill) / 4
W = candidate.estimated_width
S = loop.scalar_cost
T = loop.max_trip_count

unknown T:      C / W
scalar tail:    C * floor(T/W) + S * (T % W)
folded tail:    C * ceil(T/W)
```

`original` already includes the LLVM register-pressure spill estimate. Actual
backend spills, resource bottlenecks, latency graphs and learned multipliers are
not added. T is an upper bound, not necessarily the actual runtime trip count.
Costs are LLVM model units, not CPU cycles.

`cost_model.py` implements integer quarter-unit arithmetic, invalid propagation
and InstructionCost's intermediate saturation. Display scores include an exact
numerator/denominator. Selection uses the pairwise LLVM comparison rather than
rounded floating-point scores: it starts with scalar f1, considers fixed and
scalable candidates in compiler order, prefers scalable on a fixed/scalar tie
(the RISC-V TTI default), and retains the incumbent on other ties. Known-trip
comparisons use the incoming candidate's tail policy for both sides, as LLVM does.
Scalar cost is not replaced by a learned tail coefficient.

The model targets the search dataset's RISC-V O3 throughput configuration,
IC=1, no vector epilogue. It is not a complete reimplementation of LLVM's policy:
forced-vectorization/user-VF hints, always-scalable hints, size optimization,
vector-generation filters, tiny-trip candidate pruning and outside-loop
profitability are not all represented by the v3 manifest. Different extraction
points in the direct and checkpoint pipelines can also change loop/candidate
sets. Thus agreement is measured, not assumed, and multi-loop results are not
collapsed into an arbitrary single VF.

The driver scores discovery observations directly without RA probes. It then
materializes each chosen candidate to LLVM IR to check legality and runtime
safety. A structured rejection leaves that loop scalar, with its reason recorded;
compiler crashes and malformed/stale observations are errors. Final replay
verifies the selected candidates and context. `--analytics-only --stop-after-ra`
on `utils/vplan-meta-compile` still collects raw post-RA observations for diagnostics,
independently of the default model. See [VPLAN_RA.md](../../VPLAN_RA.md).

## Dataset contract

The database is opened read-only. Precedence is `--db` > `VPLAN_DB` > this
checkout's `dataset.sqlite`; use `--db search-dataset.sqlite` for the search set.
No database, split label, source, compile flag, workload or measurement is updated.

Supported tables are `dataset(id=1, target, measurement_compiler,
measurement_protocol_json)`, `benchmarks(id, split, source, compile_args_json,
workload_json)`, and `measurements(benchmark_id, vf, cycles)`. VF and cycles must
be positive integers with one measurement per benchmark/VF. VF 1 is scalable s1,
not scalar f1 or an LMUL value. Fixed/scalar selections have no measured score.

All benchmark IDs and historical split labels are eligible. For cycle metrics,
the compiler's scalable candidate set defines the required measurement population;
extra database VFs are reported and ignored, and missing candidate measurements
exclude the benchmark. At least two candidate VFs are needed for cycle metrics.
Decision agreement does not require cycle coverage. No generated binaries are
executed and no new cycle measurements are collected.

Compilation preserves recorded optimization, target, interleave and kernel flags,
removes forced VF/reporting and container include paths, and sets the LMUL search
cap to 8. The language flag selects the source suffix. Local diagnostic headers
supply the declarations required by the dataset without a RISC-V runtime.

## Tests

```sh
uv run --project utils/vplan-tools python -B -m unittest discover \
  -s utils/vplan-tools/tests -v
VPLAN_CLANG="$PWD/build-vplan-tools/bin/clang" \
  uv run --project utils/vplan-tools python -B -m unittest discover \
  -s utils/vplan-tools/tests -v
```

The second command includes compiler integration tests. Tests cover quarter costs,
trip/tail arithmetic, scalar/fixed/scalable decisions and ties, invalid costs,
saturation, final replay, read-only database handling and baseline comparisons.
