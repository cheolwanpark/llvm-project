# Python VPlan selection protocol

LLVM checkpoints IR before LoopVectorize, enumerates vector candidates, collects
post-register-allocation facts, and reproduces explicitly selected candidates.
`utils/vplan-tools/selection_policy.py` supplies this checkout's policy to
evaluation, printing and `utils/vplan-meta-compile`. On `backend-aware-cost`,
`cost_model.py` supplies the same backend costs to selection and calibration.
The two ablation branches replace only the policy, not the compiler pipeline.
No measurements or dataset
are read by the meta compiler. Scores are heuristic model units, not CPU cycles.

```text
prepare checkpoint → discover candidates + middle-end loop context
                   → vector probes → raw post-RA analytics
                   → Python default/fitted scores → per-loop selection
                   → LLVM replay → IR / assembly / object
```

The supported interface is non-LTO RISCV64 O2/O3, inner loops, IC=1, without a
separate vector epilogue. Ordinary LLVM compilation and `--compiler-mode direct`
retain the normal TTI cost and selection policy. Meta selection ranks evaluable
vectors only; it does not compare profitability against scalar execution.
If no vector is evaluable, that loop stays scalar with an explicit reason.
Multiple loops are selected independently, without function-level aggregation.

## Observation and scoring

`RISCVVPlanAnalytics` runs at the end of RISC-V `addPostRegAlloc`, after register
assignment/rewrite, stack-slot coloring, copy propagation, post-RA LICM and
redundant-copy elimination when enabled. It preserves the MachineFunction and
only collects and writes facts. Observation precedes post-RA sinking, frame
lowering, later pseudo expansion and scheduling; it is not final assembly.

Raw analytics version 2 contains instructions, register geometry, operand
flags, memory direction, spill objects, predicate identities, regions and proven
physical RAW dependency edges. Instructions outside the selected body remain
visible but are not costed. Single-block regions have distance-0/1 dependency
coverage; other regions expose block-local coverage. Unknown facts are explicit.

Operands additionally expose `Bank` (`gpr`, `fpr`, `vector`, or `unknown`). Each
instruction's `SpillSlotAccess` checks both frame-index operands and fixed-stack
MMOs, independently of recognized `Spill` transfers. The shared Python spill
projection rejects incomplete coverage rather than interpreting it as zero.

IR metadata identifies the selected loop. Induction witnesses verify its
post-optimization iteration mapping, including fixed-vscale folding and provable
unrolling. Single-block EVL loops are recognized by VL-based induction updates.
Lost or ambiguous loops and unproven mappings are unavailable, rather than scored
at the original estimated VF width.

Let B be body cost including spill and per-iteration mask/VL configuration, W the
verified post-RA width, S the middle-end cost of one original scalar iteration,
and T the known trip-count upper bound:

| Condition | Python score |
| --- | --- |
| Unknown T | B / W |
| Scalar remainder | B × floor(T/W) + tail_scale × S × (T % W) |
| Folded tail | B × ceil(T/W) |

S comes from `CM.expectedCost(f1)`, with invalid values represented by JSON null.
Zero is a valid scalar cost. S is required only for scalar-tail candidates with a
known T, unless both the positive exact trip count and T divide W. Divisibility
of an upper bound alone does not establish that the real remainder is empty.
The bound is used for scoring and is never presented as an exact runtime count.

The model retains resource hard maxima, load/store overlap, predicate sharing,
recurrence/load-use bounds, spill and configuration formulas. Floating-point
costs are continuous, without InstructionCost quantization. `tail_scale` defaults
to 1 and is learned in positive log space, separately bounded to [1/64, 64]. It
stays 1 when no nonzero remainder term is observed. Breakdown and scores use the
same computation, so spill/configuration are never added a second time.

One-time guards, initialization and exits are excluded. Reduced body cost at a
short VL, precise epilogue modeling, new instructions and function aggregation
remain future work. LLVM legality and runtime safety checks remain active.
Known always-failing memory/SCEV checks produce structured probe failures.

## Usage

```sh
uv run --project utils/vplan-tools python utils/vplan-meta-compile \
  --clang build-vplan-tools/bin/clang --input kernel.c \
  --work-dir observations-o3 --output kernel.o \
  -- --target=riscv64-unknown-elf -march=rv64gcv \
  -mcpu=xiangshan-kunminghu -O3 -ffreestanding
```

Use an empty work directory. `--emit llvm|asm|obj` selects the output.
`--weights PATH` loads current fitted coefficients; omission uses all multipliers
at 1. `--stop-after-ra` collects and scores without final compilation;
`--analytics-only --stop-after-ra` collects raw facts without loading the model.
`--detail` retains ordinary VPlan diagnostics. `--timeout` applies per invocation.
`--extract-function NAME` optionally isolates a function at the checkpoint.

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
not backend scores. Invalid middle-end costs do not remove common probe candidates.
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

Artifacts include `identity.json`, `pre-vectorize.bc`, `candidates.json`, per-probe
`.analytics.json`, `.manifest.json`, `.mir` and logs, `candidate-status.json`
(status, reason, Python score and breakdown), `selection.json`,
`final.manifest.json`, and `result.json`. Individual unsupported or failed probes
do not stop other probes. Preparation/discovery failure and identity/schema
corruption in successful probe output fail the driver. Final replay failure
never becomes a scalar fallback.

Protocol v2 manifests/feedback, old cache bundles, and old weights are rejected.
Recollect and refit; there is no compatibility mode. Raw analytics remain v2,
cache bundles are v4, and weights schema 2 uses model `rvv-python-19-v3`.
Existing caches must be recollected for the added common observations.

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
projection. Python tests cover formulas, fitting, weight persistence and driver
integration. Dataset validation uses previously measured cycles and does not
measure execution performance of newly generated code. See the
[tools guide](utils/vplan-tools/README.md) for partitioning and metrics.
