# Local MIR research tools

Python 3.12's standard library implements one fixed machine cost calculation for
reports, selection and regret evaluation. LLVM observes facts and materializes
explicit replay choices. The model is `mir-local-fixed-v1`, with protocol 4 and
`mir-local-observation-v1` observations.

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

## Fixed machine model and manual calibration freedom

Edit the constants at the top of [cost_model.py](cost_model.py) to calibrate the
machine by hand. All benchmarks and VFs use these same constants. There is no
parameter-file loader, fitting command, optimizer, training split or automatic
parameter search. Changing the model's formulas later is also a source change.

| Constant | Current value | Manual calibration freedom |
| --- | --- | --- |
| Ten vector `basic_*` classes | 1 each | Relative effect per unit of decoder work for convert, divide, FP ALU, FP multiply, integer, mask, memory, move, multiply and permute |
| `basic_scalar` | 1 | Reference unit; keep fixed while changing relative scales |
| `contention` | 0.25 | Forward shared-class penalty per pair-work unit |
| `raw` | 0.25 | Forward dependency penalty per pair-work unit |
| `ilp` | 0.125 | Backward independent-overlap credit per pair-work unit |
| `middle_end_scale` | 1 | Conversion from middle-end TTI costs to model effects |
| `FORWARD_WINDOW`, `BACKWARD_WINDOW` | 4, 4 ops | Machine's local interaction horizons |

There are fourteen relative coefficient choices with scalar scale anchored at 1,
plus the two window lengths. The current coefficients are explicit manual starting
assumptions, not measured machine latencies or values selected using benchmark
cycles. Four unit pairs contribute one unit of contention or RAW stall, or half a
unit of ILP credit. Hardware decoder split rules and supported execution-resource
assignments come from the pinned XiangShan MinimalConfig RTL in
[hardware.py](hardware.py) and [the rule guide](rules/README.md). Decoder work is
not a cycle prediction. Calibrating scales does not change the RTL split facts.

The current formula uses `min(work_a, work_b)`, sums pairs without distance decay,
and adds contention and RAW effects when both apply. Configuration and scalar
remainder additions are enabled. These are hardcoded model decisions that can be
revised along with the model. Reports snapshot constants and source/rule digests
for reproduction; those snapshots are output data and cannot configure scoring.

## Local effects and iteration mapping

```text
op cost = basic + forward-window stall - backward-window ILP
body cost = sum(op cost)
score = body_iterations * body_cost + middle_end_cost
```

Meta and configuration ops stay outside body work and window distance.
Configuration definitions still participate in dependency paths. Wrapping keeps
`(instruction ID, iteration offset)`, including windows spanning several loops.
Only anchors in iteration zero contribute to one body's total.

Contention requires a shared cost class. RAW includes direct/transitive physical
register-unit paths and proven stack-memory RAW. ILP requires proven independence
and a constructive assignment to distinct execution units. A class difference is
insufficient. Same-class contention and ILP can both contribute. Unknown relations
receive no ILP credit. Signed costs and cancellation remain visible; no hidden
ILP cap, global resource max or recurrence bound is applied. Spill/reload ops use
the ordinary memory-instruction path.

Supported CFGs are innermost single-block loops. Exit jumps after a taken backedge
stay outside circular body order. Multi-block paths, uncertain iteration mapping,
missing hardware rules and unsupported geometry are explicit exclusions. Partial
registers, regmasks and opaque effects make independence unknown. Ordinary
non-stack stores may alias. Register and memory coverage are reported separately.

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

Tests cover fixed hardware splits, multi-lap windows, carried/transitive
register and memory dependencies, unknown cases, additive effects, signed scores,
configuration/tails, reconciliation, read-only DB/default paths, coverage, regret
metrics and compiler selection/replay using the same hardcoded model.

## Recorded fixed-model evaluation

The [2026-10-22 results](results/fixed-2026-10-22/summary.json) use the constants
above unchanged for the whole run. All 203 IDs were attempted; 189 were eligible
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
