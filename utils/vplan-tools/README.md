# Local MIR research tools

Python 3.12's standard library implements one fixed machine cost calculation for
reports, selection and regret evaluation. LLVM observes facts and materializes
explicit replay choices. The model is `mir-memory-requests-v4`, with protocol 4 and
`mir-local-observation-v2` observations at `post-frame-lowering`.

## Build and input

Run `uv sync --locked --project utils/vplan-tools` from the repository root.
Tools build `clang`, `clang-resource-headers` and `llvm-extract` automatically
in `build-vplan-tools`, using Release, assertions, the RISC-V target and Clang.
`--build-dir PATH`, `--llvm-path CHECKOUT`, `--jobs N` and `--timeout SECONDS`
control the compiler. `--skip-build` reuses existing binaries.

The default database is this checkout's `search-dataset.sqlite`. Precedence is
`--db PATH` > nonempty `VPLAN_DB` > that default, independently of working directory
or `--llvm-path`. SQLite opens it read-only. Missing files, invalid schemas/JSON,
duplicate measurements and nonpositive VF/cycle values fail.

| Table | Required columns |
| --- | --- |
| `dataset` | `id=1`, `target`, `measurement_compiler`, `measurement_protocol_json` |
| `benchmarks` | `id`, `split`, `source`, `compile_args_json`, `workload_json` |
| `measurements` | `benchmark_id`, `vf`, `cycles` |

Protocol/workload metadata must be JSON objects; compile arguments are strings
in a JSON array. The pinned target, revision, VLEN 128 and ELEN 64 are checked.
VF is a scalable coefficient; `vf=1` is s1. Counts and historical labels are read
from the DB. Measurements enter the regret calculation after model selection;
they never enter instruction scoring or compiler replay.

## Commands

Examples run from this directory; add `--build-dir ../../build-local --skip-build`
to use that local build.

```sh
uv run python collect --output /tmp/population.json
uv run python collect --benchmark hpcc/stream-add --output /tmp/one.json

uv run python evaluate --output-dir /tmp/fixed-evaluation
uv run python evaluate --benchmark hpcc/stream-add --output-dir /tmp/one-evaluation

uv run python print-vplans --benchmark hpcc/stream-add \
  --artifacts-dir /tmp/report --detail --replay

uv run python evaluate-baseline --output /tmp/llvm-baseline.json

# A bundle.json from the collection cache; this command does not open a DB.
uv run python score-mir --bundle .cache/local-observations/KEY/bundle.json \
  --output /tmp/scores.json --detail
```

`print-vplan` is a report alias. Reporting requires `--artifacts-dir` so full MIR
and observations stay available. `--replay` compiles the chosen candidate to final
IR and checks the compiler's final manifest. The lower-level
[`vplan-meta-compile`](../vplan-meta-compile) accepts source/flags directly and
supports object, assembly or IR output without a measurement database.

## Decoder and memory-request work model

Memory request demand replaces the old memory decoder charge. Non-memory decode
weights are unchanged from the previous model. Constants
live in [cost_model.py](cost_model.py); all benchmarks and VFs use the same values.
There is no runtime parameter loader or automatic fitting during selection.

| Constant | Default |
| --- | ---: |
| `basic_move` | 2 |
| All other `basic_*`, including `basic_scalar` | 1 |
| `middle_end_scale` | 1 |
| `memory_requests` | 2 |

These are calibrated model weights, not hardware latency or cycle predictions.
Hardware decoder splits and execution-resource facts remain in
[hardware.py](hardware.py) and [the rule guide](rules/README.md). An instruction
with memory and move components applies 2 to requests and 2 to decode move work.
Spill/reload uses that ordinary memory path without another spill charge.

## Work and iteration mapping

```text
op_cost = sum(non_memory_component_work[class] * basic_coefficient[class])
body_cost = sum(op_cost + 2 * requests)
score = body_iterations * body_cost + middle_end_scale * middle_end_additions
```

Decode work uses post-frame-lowering MIR LMUL/SEW/EMUL and opcode-specific splits.
LLVM has already expanded segment spill/reloads and materialized stack addresses.
VF is not multiplied into the score: generated MIR, verified scalar iteration
width and iteration count account for its effect. Meta and configuration ops stay
outside body work. Existing setup/body configuration and scalar-tail additions
are unchanged.

Reports expose per-op decode `basic` and total `cost`, aggregate `basic`,
`body_cost`, `body_breakdown`, `middle_end_cost` and final `score`. Features include
non-memory `basic_*`, `memory_requests` and `middle_end_scale`.
Memory decoder demand D remains in hardware observations, but the score uses
2R instead of 3D; there is no residual subtraction, D floor or line-footprint term.
Observed register and memory coverage, RAW edges, operands and resource mappings
remain available as facts; scoring does not infer instruction interactions from
them. Observation validation and hardware coverage checks still run.

Version 2 removed window analysis and its report fields (`pairs`, `stall`, `ilp`,
op `net`, pair counters and ILP diagnostics) while retaining version 1 scores.
The current observation schema/stage requires recollecting old post-RA bundles.
Protocol 4 is unchanged. There is no legacy scorer or observation conversion path.

Supported CFGs are innermost single-block loops. Exit jumps after a taken backedge
stay outside circular body order. Multi-block paths, uncertain iteration mapping,
missing hardware rules and unsupported geometry are explicit exclusions. Partial
registers, regmasks and opaque effects remain observation coverage limitations.
Register and memory coverage are reported separately; scoring does not perform
alias or independence analysis.

The manifest captures scalar iteration cost from `CM.expectedCost(f1)` and a
configuration unit from `TTI.getIntrinsicInstrCost(riscv_vsetvlimax)`, with explicit
source, quarter-unit transport and scope. Body configurations cost one such unit
per vector iteration; setup configurations occur once. The backend contains no
configuration cost formula.

With an exact scalar count T and verified width W, scalar-tail bodies execute
`floor(T/W)` times followed by `T % W` scalar iterations. Folded tails use
`ceil(T/W)`. An upper bound never substitutes for T: unknown exact counts use
steady-state `body/W`, plus per-iteration configuration/W, and report unknown setup
amortization. Missing required TTI costs exclude the candidate.

## Bounded body memory demand

`memory_work.py` derives per-body logical bytes, distinct element addresses and
16-byte request work. Scalar and whole-register spill
sizes come from the opcode and fixed VLEN, not the scalable MMO minimum. For
regular memory, LLVM-proven VL is used when available; otherwise data geometry
supplies VLMAX. Unknown masks use an all-active upper bound. Unit/whole transfers
use 16-byte chunks; segment/strided/indexed requests use element accesses, without
assuming coalescing. Known strides preserve duplicate and reverse addresses.
Allowed base residues are enumerated from alignment. Unknown indices/strides use
disjoint, boundary-crossing bounds. Address arithmetic wraps at RV64 width.

These are conservative demand features, **not cache misses or cycle estimates**.
There is no cache simulation, cross-instruction reuse, scheduling interaction,
or extra spill penalty. `bytes_kind`, `distinct_kind` and `reasons` distinguish
proofs from bounds. Report categories describe observed operations, not the
provenance of scalarization. Body iteration/configuration/scalar-tail accounting
is unchanged. Setup/final reduction work outside the body remains excluded.

## Coefficient boundary analysis

`analyze-boundaries` intersects affine cost inequalities instead of sampling a
coefficient grid. Use `--term NAME` for any linear feature in the saved evaluation;
repeat it to analyze independent axes. Other coefficients default to that
evaluation's saved weights, not the current model's constants. Use
`--set NAME=VALUE` to override a non-varied coefficient (fractions are accepted).
The baseline always remains the saved evaluation's selections, so an override
does not silently change what "preserve" and "improve" mean. Neither observations
nor production model weights are changed.

```sh
python analyze-boundaries --evaluation /tmp/fixed-evaluation \
  --term basic_move --term basic_fp_multiply --output-dir /tmp/instruction-boundaries

python analyze-boundaries --evaluation /tmp/fixed-evaluation \
  --term basic_move --set memory_requests=3/2 --output-dir /tmp/move-boundaries
```

The tool reads feature names and coefficients from the saved reports and validates
their identity and candidate coverage. A new term needs to be exported as a
linear feature with its coefficient in the evaluation; the analyzer needs no code
change. Nonlinear interactions and joint multidimensional regions are outside its
scope. Each varied coefficient covers [0, infinity), with exact rational ties.

## Regret evaluation

`evaluate` applies the same hardcoded model once to every selected benchmark ID.
It prints **mean regret, exact top-1 accuracy and worst regret**, including the
worst benchmark and selected/oracle VFs. Regret is
`cycles(selected) / min(cycles(eligible VFs)) - 1`; mean and worst regret use the
same eligible benchmark population. Accuracy requires the deterministic oracle VF
(minimum cycles, then smaller VF). Excluded benchmarks are counted and retain
reasons; they never become zero-regret successes. Median, p95 and rank correlation
are retained as supplementary metrics.

All discovered scalable candidates must be supported and every discovered VF
must have a measurement. A failed alternative cannot silently shrink the cohort.
Extra measured VFs are reported as ignored. Multiple plans for one VF use their
minimum score; selection ties choose smaller VF, then candidate ID.

By default every eligible selection is recompiled and verified, and ordinary LLVM
is evaluated once on every attempted ID. Comparison uses the intersection with
identical benchmark **and VF** populations, with both coverage counts retained.
`--ranking-only` and `--no-baseline` label diagnostic shortcuts. This evaluates
choices against stored measurements; it does not execute benchmarks.

## Artifacts and caches

Use a new/empty evaluation output directory. It contains `summary.json`,
`baseline.json`, op/pair `reports/` and final `replay/` artifacts. Every attempted
ID receives one evaluation row, including exclusions. Summaries remain incomplete
until processing ends. Compiler/replay failures or no eligible data make the run
unsuccessful. Measurements and historical split labels are never updated.

The raw cache defaults to `.cache/local-observations` (`--cache-dir` overrides).
Its key includes source/flags, compiler/extractor digests, observation schema,
stage, driver/collector code and headers. It preserves source, checkpoint IR,
commands, stderr, full MIR and bound JSON. Bundles contain no measured cycles,
parameters or scores. Candidate populations, bound middle-end context, raw JSON
and MIR checksums are validated on reuse. Invalid artifacts fail with paths.
Changing model constants requires rescoring, not collecting machine facts again.
Final selection replay is never inferred from a raw cache hit.

## Tests

```sh
uv run python -B -m unittest discover -s tests -v
VPLAN_CLANG="$PWD/../../build-local/bin/clang" \
  uv run python -B -m unittest discover -s tests -v

# Focused backend corpus for the default tests-disabled LLVM build.
cmake --build ../../build-local --target llc opt FileCheck split-file not --parallel 2
uv run python tests/run_backend.py --build-dir ../../build-local
```

Tests cover calibrated mixed-component sums, geometry, iteration/configuration/tail
costs, identity, preserved resource and observation facts, reconciliation,
read-only DB/default paths, coverage, regret metrics and compiler selection/replay
using the same hardcoded model.

## Historical fixed-model evaluation

The [2026-10-22 results](results/fixed-2026-10-22/summary.json) record the earlier
`mir-local-fixed-v1` model:
both windows 4, all basic weights 1, and pair scales 0.25/0.25/0.125. They do not
describe the current default. All 203 IDs were attempted; 189 were eligible
and all 189 selections replayed successfully. Fourteen exclusions retain their
loop/mapping/measurement reasons. On the 189 matching benchmark/VF populations:

| Model | Mean regret | Accuracy | Worst regret |
| --- | ---: | ---: | ---: |
| Hardcoded machine model | 6.914% | 43.915% (83/189) | 167.261% |
| Ordinary LLVM | 8.998% | 36.508% (69/189) | 167.261% |

Both models' worst case is `tsvc/tsvc-s351-l00`: selected s2, best s4. These
numbers compare choices against the stored measurements. The
[validation record](results/fixed-2026-10-22/validation.json) records source and
compiler identities, reproduction commands, 46 passing Python tests (including
compiler integration) and 35 passing backend/transport regression files. Full
MIR facts, op/pair reports and replay outputs remain under the recorded cache paths.

## Calibrated search reevaluation (2026-10-23)

This historical record describes `mir-basic-calibrated-v1`. Version 2 keeps its
numerical model while removing the inactive window implementation and report fields.

The [summary](results/basic-calibrated-2026-10-23/summary.json) and
[verification record](results/basic-calibrated-2026-10-23/verification.json) record
203 attempted benchmarks, 189 evaluated, 14 exclusions and 843 evaluated
candidates. All 189 selections passed compiler replay. Every candidate matched
the independent reference (the restored scorer with only constants temporarily
changed) in features, score and selected VF. Pair lists are empty, pair features
are exactly zero, scores are finite and positive, and body costs are nonnegative.
The read-only database checksum is unchanged.

| Model | Mean regret | Exact VF accuracy | Worst regret |
| --- | ---: | ---: | ---: |
| Calibrated window 0 | 4.670978485962896% | 47.61904761904761% (90/189) | 55.06360995031292% |
| Restored window 4 | 6.914% | 43.915% (83/189) | 167.261% |
| Ordinary LLVM (matched population) | 8.998% | 36.508% (69/189) | 167.261% |

The worst calibrated case is `tsvc/tsvc-s111-l00` (selected s16, best s2).
Relative to the restored window 4 model, seven selections improve and one
worsens. `polybench/polybench-fdtd-2d-l03` slows down by 12.428% relative to the
previous selection; the verification record includes every changed choice.
These choices are evaluated using stored cycles. Compiler replay verifies the
chosen transformation and does not remeasure hardware runtime.

The weights were selected on Search, which includes calibration cases; these
numbers do not measure independent generalization. Deleted validation data was
not regenerated, reused or included in these artifacts. No new coefficient
search or window sweep was performed.

Evaluate the current implementation from the repository root with a new/empty
output directory (version 2 emits the reduced report format):

```sh
PYTHONPATH="$PWD/utils/vplan-tools" VPLAN_CLANG="$PWD/build-vplan-tools/bin/clang" \
  uv run --project utils/vplan-tools python -B -m unittest discover \
  -s utils/vplan-tools/tests -v
uv run --project utils/vplan-tools python -B utils/vplan-tools/evaluate \
  --db "$PWD/search-dataset.sqlite" --build-dir "$PWD/build-vplan-tools" \
  --skip-build --output-dir /tmp/vplan-window0-calibrated-evaluation
```

`PYTHONPATH` is required for root-level unittest discovery. Raw observations are
reused when the collector identity matches; otherwise collection creates new
cache entries. Scores and reports are recomputed under the current model identity.
On CPython 3.12.15, three alternating passes of `score_observation` over the
same 843 in-memory observations gave median times of 2.591811 s for the restored
4/4 model and 0.557252 s for the calibrated 0/0 implementation. Timings include
validation and report construction, with cyclic GC enabled; they exclude DB/cache
reads, compilation, collection, artifact I/O, replay and hardware execution.
Individual samples are in the verification record; [candidate features and scores](results/basic-calibrated-2026-10-23/candidate-features.json)
retain the checked population. These Python timings make no llvm-mca comparison.
