# VPlan tools

The default `llvm-backend-spill-v1` model keeps LLVM's middle-end throughput
costs and replaces its spill estimate with post-RA spill/reload observations. It
has no fitted parameters and does not read measured cycles when selecting a plan.
The previous 19-parameter backend model, fitting objectives and five-fold CV have
been removed. PyTorch and NumPy are no longer required.

## Experimental memory interactions

### Maximum sliding-window replacement

`memory_window_cost.py` implements `backend-memory-window-v3`. Service cost
and demand are independent functions of each non-spill load/store. Kind weights
multiply raw requests; optional opcode overrides specify an absolute per-op
cost or demand. Unit accesses use `ceil(bytes/16)` raw requests, strided and
indexed accesses use VL, and segmented accesses use VL times the field count.
Scalar accesses use one request.

The model's operation pricing, cyclic window scan, normalization and quarter-cost
rounding are shared by direct evaluation and the cached calibration path.
`memory_evaluation.py` provides model-independent candidate projection and regret
metrics; the window evaluator imports it directly without loading the earlier
adjacent-pair CLI. Both evaluators use `selection_policy.choose_priced` for the
compiler's VF comparison and scalar-tail rules. Calibration caches operation
prices and window peaks, while the detailed replay checks every candidate cost.

```text
S = sum(Cost(op))
L = min(window_size, body_instruction_count)
T = L * max(1, backend_iteration_width / reference_width)
Q = max over cyclic windows of L instructions (sum(Demand(op)))
I = interaction_weight * max(0, Q - headroom - throughput*T) / throughput
memory = (service_scale*S + I) / backend_to_original_iteration_ratio
body = precomputed + vector_region - selected_memory_subtotal + backend_spill + memory
```

The body is duplicated twice to scan all windows crossing the loop boundary.
Only the first body's start positions are used, service is counted once, and
overlapping windows contribute their maximum penalty. Windows are capped at
one body, so duplication never doubles demand. Positions include all body
instructions. Throughput is demand per proxy time unit; VF increases available
window time, not physical bandwidth. The model deliberately omits adjacent-pair,
address-alias and queue-state interactions. It is a throughput
heuristic, not a prediction of latency in hardware cycles.

By default replacement removes the **complete additive memory recipe contributions**,
including address/shuffle costs inside those recipes. Standalone non-memory
recipes and measured backend spills remain. The combined memory term is
converted to quarter-cost units once; normal candidate selection then handles
VF normalization and scalar tails. Fixed candidates are excluded before costing.

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate-window-cost \
  --output-dir .cache/window-memory-calibration-new
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate-window-cost \
  --parameters utils/vplan-tools/memory-window-calibrated.json \
  --output-dir .cache/window-memory-replay-new
```

The evaluator defaults to the saved 2026-10-21 all-load facts, original spill
baseline, parsed corpus, strided comparison, and prior VF-scaling comparison.
Each can be overridden with its named CLI argument. It verifies source input
hashes, recomputes complete recipe attribution, and checks selected profiles'
cached costs and choices against the general implementation and canonical
selection. Output contains every tested parameter set and summary, exact
candidate terms for selected profiles, all regressions/improvements against
both references, and service-only/no-VF-time ablations. Calibration is a staged,
finite **in-sample** search, not a global optimum or held-out validation. No
new hardware timings are collected and the compiler's default spill policy
is unchanged.

`memory-window-calibrated.json` preserves the setting with the fewest regressions
against the strided reference, breaking ties by mean regret. On the inspected
189-case cohort it changes mean regret from 6.7163% to 4.7930%, with nine
improvements and one regression (s1232: 0% to 3.0730%). Against the preceding
VF-threshold model there are two regressions: s1232 and s351 (0% to 7.6064%).
It is an explicit experimental profile; `Parameters()` is not calibrated.

#### Retaining LLVM costs and scaling service

Version 3 adds `llvm_memory_removal` and nonnegative `service_scale`, with
defaults `recipes` and 1 preserving the preceding model's costs. Scope `recipes`
removes complete memory recipes; `hooks` removes only their recognized memory
TTI leaves and retains separately itemized address/shuffle costs inside them;
`none` retains all LLVM memory costs. With `none`, the model is an additive
correction, not memory replacement. Opaque lowering/shuffle costs embedded
inside a memory hook cannot be separated and are still removed in `hooks` mode.
Precomputed/non-memory costs and backend spill costs are preserved in all modes.

`service_scale` multiplies the complete new service sum, including opcode
overrides, before iteration normalization and combined quarter-cost rounding.
It never scales demand, the capacity threshold or the interaction penalty.

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate-window-cost \
  --parameters utils/vplan-tools/memory-window-calibrated.json --service-sweep \
  --output-dir .cache/window-service-retention-new
```

The sweep holds all other parameters fixed and compares all three removal
scopes at service scales 0 through 1 in increments of 1/16. The 2026-10-21
replay tested 51 settings around each of the two window profiles, with all 189
eligible cases retained. For the fewest-regressions profile, preserving hook
ancillaries gives mean regret 4.9036% instead of 4.7930% at every tested scale.
Only s127 changes, from s16 (0% regret) to s8 (20.9060%). At s16 LLVM adds two
address-computation leaves of 16 cost units each; these survive `hooks` removal.
Keeping all LLVM memory costs produces the same selected VFs in this sweep.
The mean-oriented profile similarly worsens from 4.5946% to 5.1752% because
s127 changes to s2. These are fixed-geometry, uniform-service-scale experiments,
not a claim about the optimum after independently retuning per-kind coefficients.
Results are in `.cache/window-service-retention-20261021/` and
`.cache/window-service-retention-mean-20261021/`. Defaults remain unchanged.

#### Optional known-stride interval adjustment

Version 2 adds independent stride factors for service and demand. Both strengths
default to zero, reproducing version 1 costs exactly. For an ordinary strided
load or store with a known signed byte stride:

```text
density = min(1, stride_interval_bytes / max(1, abs(stride_bytes)))
factor(strength) = (1 - strength) + strength * density
Cost(op)   = old_Cost(op)   * factor(stride_service_strength)
Demand(op) = old_Demand(op) * factor(stride_demand_strength)
```

Each strength is in [0,1]. Unknown strides retain factor one, zero stride retains
factor one, and reverse strides use their magnitude. Unit, indexed, segmented,
and segment-strided operations are unchanged. Absolute opcode overrides take
precedence over stride factors. Reports count known/unknown strided accesses.

This is a spatial request-density hypothesis for contention, not a claim that
large strides intrinsically have cheaper memory service or fewer cache misses.
Its use in service is an empirical ablation. A service adjustment proportional
to VF can cancel during per-element comparison; demand can change selection
through the window capacity threshold.

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate-window-cost \
  --parameters utils/vplan-tools/memory-window-calibrated.json --stride-sweep \
  --output-dir .cache/window-stride-interval-new
```

This holds the supplied service/demand weights and window geometry fixed and
tests service-only, demand-only, equal-strength joint, and independent-strength
adjustments. It reports comparisons against the unadjusted window model as well
as the original strided and previous VF-threshold models. The search includes
the disabled adjustment; a result with zero strengths means no better adjustment
was found, not that stride information is universally unhelpful.

The 2026-10-21 replay tested 568 settings around each of the two window profiles.
Neither search improved its starting mean regret with this density factor alone.
Around the fewest-regressions profile, demand strength 1/8 and interval 8 bytes
fix s1232 (s2 to s16), but lose gains in symm-l00, s257 and gramschmidt-l03:
mean regret is 5.0501% instead of 4.7930%. Against the original strided model
this is six improvements and zero regressions; against the previous VF-threshold
model s351 still regresses. Results and exact profiles are in
`.cache/window-stride-interval-refined-20261021/`; the mean-oriented search is
in `.cache/window-stride-interval-mean-refined-20261021/`. No default coefficient
was changed based on this experiment.

### Earlier adjacent-pair model

`memory_cost.py` adds an opt-in, offline model with independently reported
distance/request, stride-adjustment, and load/store address terms.
`memory_observations.py` recovers facts from saved post-RA analytics/MIR and
attributes additive LLVM memory-hook costs from the saved detailed cost report.
The default compilation/selection policy remains the spill model.

Replay the three focal kernels before evaluating the complete saved dataset:

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate-memory-cost \
  --output-dir .cache/memory-focal-new \
  --benchmark tsvc/tsvc-s111-l00 --benchmark tsvc/tsvc-s128-l00 \
  --benchmark tsvc/tsvc-s1232-l00
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate-memory-cost \
  --output-dir .cache/memory-full-new
```

The default inputs are `.cache/memory-burst-spill-B/summary.json` and
`.cache/backend-spill-detail-corpus-final/summary.json`; `--baseline` and
`--corpus` override them. Inputs must retain the artifact paths referenced by
their manifests. The command checks the database hash, baseline/corpus compiler
identity, manifest costs, and zero-correction selections. It never recompiles,
times kernels, changes the database, or fits parameters. Evaluation defaults to
scalable candidates only, excluding fixed candidates before pricing. Use
`--candidate-scope all` only to reproduce historical full-candidate evaluation.

The fixed initial hypotheses are:

```text
q = active element count for strided memory; ceil(bytes/16) for unit memory;
    one request for scalar memory (non-spill body accesses only)
near(gap) = 4 / (4 + gap)           # instruction positions, not CPU cycles
pair(i,j) = (1/2) * near(gap) * max(0, q_i + q_j - 8)
locality(stride) = min(1, 16 / max(1, abs(stride_bytes)))
                  zero for reverse-contiguous; one for unknown stride
distance = sum(pair)               # next strided load, including iteration wrap
stride_adjustment = sum(pair * (min(locality_i, locality_j) - 1))
address = sum(max same-object strided load/store pair cost per load)
```

The address pair cost uses the same request threshold/distance factor, stride
locality, and average shared-line fraction over 64 possible base alignments.
Only same-object pairs with known offsets/stride and equal sampled iteration
deltas qualify. Different/unknown objects contribute no address term, without
claiming they cannot contend. True byte overlap and cache-line sharing are not
treated as equivalent. This first address term is within one iteration; the
load/load term includes iteration wrap at full weight, even for a one-body loop.
Version 2 removes the finite-trip frequency factor and direct-dependence gate;
stride locality is the only extra weight on the distance/request penalty.
The interaction heuristic does not model dependence serialization. Unknown
stride/address facts are listed.

All terms divide by the proven backend/original iteration ratio. The three
stages are `distance`, `distance + stride_adjustment`, and all three terms.
Every stage is evaluated with three composition modes:

* `residual`: spill baseline + interaction terms.
* `add`: spill baseline + backend request service + interaction terms. This
  deliberately retains the existing memory cost to expose double counting.
* `replace`: spill baseline - observed LLVM memory hooks + the same backend
  service and interaction terms.

Replacement subtracts the additive **vector-region memory hook subtotal**,
not an estimated fraction of the entire loop cost. Opaque interleaved hooks
include lowering/shuffle costs: these disappear on replacement and are not
recreated by simple request counting. Separate address/shuffle recipes,
precomputed costs, scalar comparator/tail, and observed spill costs remain.
Subtraction occurs before saturated addition; quarters are truncated once.

These are exploratory model units, not a cycle simulator. Full-active VL/masks,
aligned unit service and first-two-iteration address recovery are assumptions.
Cache state, exact bank mapping, dynamic issue order and config/shuffle service
are not modeled. Historical measured binaries are not verified identical to the
probed MIR. Unsupported candidates trigger whole-benchmark baseline fallback,
reported separately. In full-candidate mode, new unmeasured fixed/scalar choices
remain explicit exclusions; each variant reports its own and common-population regret, all
regressions, per-candidate terms, and source/input hashes in `results.json`.

### Explicit coefficient tuning

`tune-memory-cost` searches coefficients against the already inspected measured
cycles. This is **in-sample tuning**, not independent validation. It uses the
original residual-stride replay as the reference, defaults to scalable-only
candidates, and recommends only settings with no new unmeasured choices and no
per-case regret increase. It reports the unconstrained full-coverage winner too.

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/tune-memory-cost \
  --grid broad --output-dir .cache/memory-tuning-new
uv run --project utils/vplan-tools python utils/vplan-tools/tune-memory-cost \
  --grid refine --output-dir .cache/memory-refinement-new
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate-memory-cost \
  --memory-parameters utils/vplan-tools/memory-cost-tuned.json \
  --output-dir .cache/memory-tuned-replay-new
```

The broad grid has 4,050 settings and the follow-up refinement has 1,750. All
settings, losses of coverage, regressions, and reachable VF choices are retained.
`reverse_weight` (default 0) and `unknown_stride_weight` (default 1) expose the
previous constants; coefficient validation rejects negative or invalid values.
Profile JSON stores exact rational strings or numerator/denominator objects.

The experimental profile changes `distance_scale` 4→8 and `locality_bytes` 16→8;
the default `Parameters()` and compilation policy remain unchanged. On the
frozen dataset this lowers band-lin-eq-outer regret from 14.34% to 8.73%, with no
other selection changes. However, its gain depends on the current unknown-stride
extraction for that kernel: diagnosing it with the actual +40-byte stride removes
the gain. The profile is an experiment, not a recommended production default.
The [StridedMemoryCost report](../../wrong-predictions-stridedload.md) records the
full rankings, exclusions, sensitivity artifacts, and remaining failure cases.

Version 2 retains these coefficients and removes only the load-pair finite-trip
factor and direct-dependence gate. Replaying all 117 benchmarks with both default
and tuned coefficients preserves every VF choice and eligibility result across
all composition modes/stages. Tuned residual-stride still scores 99 benchmarks,
with 48 optimal choices and 5.192% mean regret. The default remains 5.248%.
This is a frozen-data check, not new timing or validation on unseen workloads.

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
