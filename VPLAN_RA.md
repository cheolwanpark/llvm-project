# Python VPlan selection protocol

LLVM checkpoints IR before LoopVectorize, enumerates vector candidates, and
reproduces explicitly selected candidates. `utils/vplan-tools/selection_policy.py`
supplies the fixed `llvm-backend-spill` policy for evaluation, printing and
`utils/vplan-meta-compile`. `cost_model.py` keeps ordinary LLVM costs and replaces
only spill/reload estimates with post-RA observations. It has no parameters to fit
and reads no database or measurements.

```text
prepare checkpoint → discover candidates + middle-end loop context
                   → post-RA probe of every cost-evaluable fixed/scalable candidate
                   → replace spill estimates; scalar/vector comparison
                   → LLVM replay → IR / assembly / object
```

The interface supports non-LTO RISCV64 O2/O3, inner loops, IC=1, without a vector
epilogue. The fixed policy targets the RISC-V throughput configuration used by
`search-dataset.sqlite`. It ranks both fixed and scalable vectors against scalar
f1, using compiler order and LLVM's scalable tie preference. Structured safety
rejections are recorded as illegal candidates; unavailable observations exclude
the whole benchmark before selection, and compiler errors remain errors.
Multiple loops are selected independently, without function-level aggregation.

## Cost model

Let C be `add_sat(add_sat(precomputed, vector_region), backend_spill) / 4`,
W be the candidate's `estimated_width`, S be `scalar_cost`, and T be `max_trip_count`:

| Condition | Comparison score |
| --- | --- |
| Unknown T | C / W |
| Scalar remainder | C × floor(T/W) + S × (T % W) |
| Folded tail | C × ceil(T/W) |

`backend_spill` is the sum of observed spill/reload counts times physical-register
group size and the candidate's existing TTI units, divided by a proven positive
integer backend-to-candidate iteration ratio, then truncated once in quarter
units and saturated. The original manifest and LLVM estimate remain unchanged.
Comparisons preserve integer quarter units, saturation, invalid propagation and the incoming candidate's tail policy
on both sides. Scores are model units, not CPU cycles. The previous learned
backend resource/latency model and tail coefficient have been removed.

The manifest does not encode every LLVM selection policy. User/forced VF hints,
size optimization, some candidate filters, and outside-loop profitability can
still cause differences from ordinary LLVM. Use `evaluate --compare-baseline`
to measure agreement. See [the tools README](utils/vplan-tools/README.md).

## Backend observations

`--analytics-only --stop-after-ra` retains the raw-observation pipeline.
`RISCVVPlanAnalytics` runs after register allocation cleanup and exposes raw
instructions, register geometry, operand banks, memory direction, spill objects,
predicates, regions, and proven physical RAW dependencies. Its version remains 2.
The default model consumes spill facts and proven iteration mapping. It excludes
the entire benchmark if any legal cost-evaluable candidate has unsupported
coverage. A missing dependency graph alone does not preclude spill costing when
execution frequency is proven. Malformed facts, crashes and timeouts are errors.

## Usage

```sh
uv run --project utils/vplan-tools python utils/vplan-meta-compile \
  --clang build-vplan-tools/bin/clang --input kernel.c \
  --work-dir observations-o3 --output kernel.o \
  -- --target=riscv64-unknown-elf -march=rv64gcv \
  -mcpu=xiangshan-kunminghu -O3 -ffreestanding
```

Use an empty work directory. `--emit llvm|asm|obj` selects the final output.
`--stop-after-ra` remains the compatibility name for stopping before final replay;
with the fixed policy this stops after post-RA scoring.
`--analytics-only --stop-after-ra` instead collects raw backend observations.
`--weights` is rejected. `--detail` retains ordinary VPlan diagnostics and
`--timeout` applies per invocation. `--extract-function NAME` optionally isolates
a function at the checkpoint.

## Protocol v3

| LLVM option | Purpose |
| --- | --- |
| `-vplan-pipeline=prepare\|resume` | Produce/consume the checkpoint. |
| `-vplan-candidates-output=PATH` | Write structured manifest. |
| `-vplan-ra-run-id=DIGEST` | Bind checkpoint/compiler/options. |
| `-vplan-probe-candidate=ID` | Materialize exactly one vector candidate. |
| `-vplan-analytics-output=PATH` | Write raw backend facts. |
| `-stop-after=riscv-vplan-analytics` | Stop after observation. |
| `-vplan-selection-input=PATH` | Replay explicit per-loop decisions. |
| `-print-vplans`, `-print-detailed-vplans` | Ordinary LLVM diagnostics. |

Manifest roots contain `version: 3`, `run_id`, `triple`, `loops`, `candidates`,
`selections` and `failures`. Each loop has `function`, `loop`, `scalar_cost`,
`max_trip_count`, `exact_trip_count`; zero trip counts mean unavailable. Each
candidate has `id`, `function`, `loop`, `vf`, `estimated_width`, `probeable`, and
`scalar_tail` (false uses folded-tail scoring). Scalar VPlans are never probed.
Discovery emits no vector selections and performs no vectorization.

Each candidate also carries `middle_end`: `precomputed`, `vector_region`,
`estimated_spill`, `original`, `pressure`, `spill_units`, `reload_units`, and
`cost_scale: 4`. Costs are exact integer quarter units, or null if invalid;
unit arrays use GPR/FPR/vector order. These are ordinary middle-end/TTI facts,
not backend scores. Invalid middle-end costs remain in the manifest, explicitly
marked invalid and excluded from model scoring.
The full context is checked again during discovery, probing and final replay.

Selection input contains `version: 3`, `run_id`, the full original `loops` and
`candidates` context, and one `selections` row per loop:

```json
{"function":"kernel","loop":0,"scalar":false,
 "id":"kernel:0:1:s4","ic":1,"epilogue_vf":"f0"}
```

A scalar row uses `scalar: true`, omits `id`, and includes a diagnostic `reason`.
The input carries no vector scores. Explicit requests bypass `computeBestVF()`
and require neither a scalar VPlan nor a scalar profitability baseline.
Duplicate/missing/stale decisions, unsupported settings, changed loop/candidate
context, and final materialization mismatches are errors.

Artifacts include `identity.json`, `pre-vectorize.bc`, `candidates.json`,
`probe-*.manifest.json`, post-RA analytics, MIR and compiler logs,
`candidate-status.json`
(status, reason, Python score and breakdown), `selection.json`,
`final.manifest.json`, and `result.json`. Raw analytics mode emits the same
observations without derived costs. Preparation/discovery failure and identity/schema
corruption in successful probe output fail the driver. Final replay failure
never becomes a scalar fallback.

Protocol v2 manifests/feedback and old weights are rejected. Recollect
observations with protocol v3; no refitting is needed. Raw analytics remain v2.
The fixed model is `llvm-backend-spill-v1` and accepts no weights.
The fixed policy does not consume old analytics caches or weights.

## Verification

```sh
cmake --build build-vplan-tools --parallel 2 --target \
  clang opt llc FileCheck llvm-extract VectorizeTests VPlanRATests
python3 build-vplan-tools/bin/llvm-lit -j 2 \
  llvm/test/CodeGen/RISCV/vplan-ra \
  llvm/test/Transforms/LoopVectorize/RISCV/vplan-ra-checkpoint.ll \
  llvm/test/Transforms/LoopVectorize/RISCV/vplan-ra-iteration-mapping.ll \
  llvm/test/Transforms/LoopVectorize/RISCV/vplan-ra-fixed-vscale.ll
build-vplan-tools/unittests/Transforms/Vectorize/VPlanRATests
VPLAN_CLANG="$PWD/build-vplan-tools/bin/clang" \
  uv run --project utils/vplan-tools python -m unittest discover -s utils/vplan-tools/tests
```

LLVM MIR tests compare current raw facts without PyTorch or a legacy feature/cost
projection. Python tests cover fixed cost formulas, selection, rejection and driver
integration. Dataset validation uses previously measured cycles and does not
measure execution performance of newly generated code. See the
[tools guide](utils/vplan-tools/README.md) for evaluation and metrics.
