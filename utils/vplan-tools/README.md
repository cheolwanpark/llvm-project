# VPlan tools

The default `llvm-backend-spill-v1` model keeps LLVM's middle-end throughput
costs and replaces its spill estimate with post-RA spill/reload observations. It
has no fitted parameters and does not read measured cycles when selecting a plan.
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
Qraw = sum(group * (spills * spill_unit[bank] + reloads * reload_unit[bank]))
r = backend_iteration_width / candidate.estimated_width
Qbackend = min(INT64_MAX, trunc_toward_zero(Qraw / r))
Qeffective = add_sat(add_sat(precomputed, vector_region), Qbackend)
C = Qeffective / 4
W = candidate.estimated_width
S = loop.scalar_cost
T = loop.max_trip_count

unknown T:      C / W
scalar tail:    C * floor(T/W) + S * (T % W)
folded tail:    C * ceil(T/W)
```

The manifest's `original` and `estimated_spill` remain untouched. Effective cost
is reconstructed from components, avoiding subtraction from an already saturated
total. GPR/FPR use group 1; vector groups 1/2/4/8 weight the physical registers
moved. Both spill and reload counts use the candidate's existing TTI quarter-unit
prices. Positive integral iteration ratios are required. The raw numerator, ratio,
normalized quarters, counts, units, and effective cost are retained in
`candidate-status.json`. Spill replacement applies even when `pressure=false` or
the old estimate is zero. Invalid costs propagate; normalization truncates once
in quarter units and effective additions saturate. T is an upper bound, not
necessarily the runtime trip count. These are model units, not CPU cycles.

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

The driver probes every cost-evaluable fixed/scalable candidate after register
allocation. Structured compiler legality/runtime-safety rejections remain distinct
from unavailable analytics. If any legal candidate lacks proven spill/iteration
coverage, the entire benchmark receives `backend-observation-unavailable` before
selection or final replay. It never selects from a reduced observation set.
Conditional bodies, lost iteration mapping, and unrecognized spill accesses are
explicitly unsupported. Compiler crashes, timeouts, malformed JSON and stale
identity fail compilation, while evaluation continues collecting other benchmarks.
Measured VLEN is checked against every scored candidate's analytics. Final replay
verifies the original manifest and selected loop/configuration.

Policy identity hashes the model, spill projection, observation binding and
selection implementation. Evaluation provenance additionally records HEAD, working
tree, relevant file hashes, DB hash and compiler version/hash.
`--analytics-only --stop-after-ra` on `utils/vplan-meta-compile` collects raw facts
without model scoring. See [VPLAN_RA.md](../../VPLAN_RA.md).

## Detailed report parser

`vplan_report.py` exposes `parse_reports(text, strict=True, stage=None)` and
`validate_manifest_costs(parsed, manifest)`. It supports the current checkout's
`report_version=2`, including summary-only/no-plan reports. The consumer applies
function filters; the parser preserves every report and outside diagnostic.
It is independent of model scoring, which continues to use protocol v3 JSON.

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/print-vplans \
  --db search-dataset.sqlite --benchmark polybench/p32-gesummv-l00 \
  --compiler-mode direct --detail --skip-build --build-dir build-vplan-tools > detail.txt
uv run --project utils/vplan-tools python utils/vplan-tools/vplan_report.py \
  detail.txt --stage ordinary-llvm -o detail.json
# Omit the file or use - to read stdin.
uv run --project utils/vplan-tools python utils/vplan-tools/validate-detail-corpus \
  --db search-dataset.sqlite --output-dir .cache/detail-new-run \
  --skip-build --build-dir build-vplan-tools
```

JSON `schema_version=1` has `reports`, `diagnostics`, and `unsupported` arrays.
Report occurrence/stage/module/invocation/function/loop, plan, VF, evaluation ID
and phase keep repeated evaluations distinct. Plans own graph blocks, recipes,
connections and opaque IR payloads. Evaluations own recipe events and nested
`calculation` children. All records retain source line and raw text; reports also
retain all original lines. Cost fields use exact tagged rationals, for example
`{"state":"valid","numerator":5,"denominator":4}`; Invalid and not-evaluated
use separate state tags. Missing fields remain absent; zero is valid 0/1. Other
instrumented inputs preserve their full spelling, including compound types and
arithmetic expressions. No unprinted TTI internals are invented.

Strict mode rejects unknown report records/fields, broken report/graph/calculation
boundaries, missing/duplicate singletons, invalid references and accounting or
ranking inconsistencies. `--lenient` retains unknown records; structural checks
still apply. Candidate accounting sums contributions, never nested query results;
scalar weighting divides after the block instruction sum. Parsed detail describes
**original LLVM costs**, separately from Python's derived backend costs.
The [fixture coverage table](tests/fixtures/README.md) maps every renderer record
to a regression input, including paths unavailable in the shared RISC-V build.

## Regenerating the comparison report

After full evaluation and detail corpus collection:

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/write-updated-report \
  --summary .cache/wrong-predictions-updated-final/summary.json \
  --baseline .cache/wrong-predictions-current/summary.json \
  --corpus .cache/backend-spill-detail-corpus-final/summary.json \
  --db search-dataset.sqlite --output wrong-predictions-spillcost.md
```

The generator checks completion, model identity, every DB measurement and source,
coverage, exact rational regret ordering, and local artifact links. It reports both
full coverage and the common eligible population, without counting new exclusions
as solved predictions. Use a fresh output/artifact directory for each evaluation.

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
