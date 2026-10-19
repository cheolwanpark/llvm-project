# Backend analytics and VPlan cost selection

The meta compiler checkpoints IR immediately before LoopVectorize, materializes
each generated scalar/vector candidate, and uses backend-computed scores for the
final selection. It supports non-LTO RISCV64 `-O2` and `-O3`. Both levels use their
normal optimization pipelines; the cost functions do not inspect the optimization
level. All invocations replay the same target, ABI and optimization options.

Ordinary compilations without the meta/feedback options retain LLVM's normal
cost policy. The backend cost model currently targets `xiangshan-kunminghu` RVV
inner loops. Its values are heuristic model units, not measured CPU cycles.

## Pipeline

```text
prepare checkpoint -> discover candidates
                   -> scalar probe: analytics -> body cost -> score
                   -> vector probes: analytics -> body cost -> score
                                      ^ same loop's scalar analytics
                   -> final replay using backend scores
```

IC is fixed to one. The existing tail-folding legality and target preferences are
retained, with scalar tails where folding is unavailable. Separate vector
epilogues are disabled. Candidate construction and recipe lowering still use
LLVM; the meta path does not use the original body/scalar/spill costs to rank or
exclude generated candidates. Runtime safety guards remain, while the old
outside-loop profitability test is bypassed.

### Observation boundary

Previously observation ran immediately after register assignment/rewrite.
The two backend passes now run consecutively at the end of RISC-V `addPostRegAlloc`.
This is after RVV and scalar register assignment/rewrite, stack-slot coloring,
copy propagation, post-RA LICM and RISC-V redundant-copy elimination when those
passes are enabled. It precedes post-RA sinking, frame lowering, later pseudo
expansion and scheduling. Frame indices and RVV pseudo operand information are
therefore available. The snapshot is not final assembly or a finalized frame.

### Analytics only

`RISCVVPlanAnalytics` preserves the MachineFunction and exposes a typed result to
its consumer. JSON is only an optional dump and a process-boundary format.

The result includes opcode/base opcode and category, SEW and fractional LMUL,
physical operands and register units, operand register groups, masks and proven
predicate identities, memory direction, spill/reload frame objects and fixed or
scalable byte sizes, CFG/region membership, and physical RAW dependency edges.
Physical register reuse is not treated as a value dependency. Implicit uses,
partial definitions, undef operands and clobbers are retained explicitly.

Single-block regions expose proven iteration distances zero and one; other
regions have block-local dependency coverage. Unsupported/unknown facts remain
visible. Instruction/byte counts and physical-register liveness are observations;
chunk service, issue floors, latencies, resource demand and coefficients are not
part of analytics.

Cost-free IR metadata connects a probe to its loop and carries VF, tuning width,
trip-count upper bound and exact constant trip count when available. At the end
of the IR suffix, induction information verifies the iteration mapping; provable
constant-stride unrolling adjusts the observed width. Single-block EVL loops are
recognized by their VL-based induction update. Lost/ambiguous identities,
unprovable mappings and fully unrolled loops are diagnosed rather than scored
using the original VF by assumption.

The dump includes instructions outside the selected body for inspection. Their
cost, including one-time guards, initialization and exit work, is excluded from
this version's ranking. Dynamic trip count and runtime VL are not fabricated.

### Backend cost

`RISCVVPlanCost` consumes analytics only. `RISCVVPlanCost.cpp` and `RISCVVPlanScoring.cpp`
are separate modules with no VPlan, TTI or MachineFunction access in their
calculation interfaces.

The vector body formula and coefficients are retained from the preceding model:

```text
body = max(memory + masked_service, arithmetic, movement,
           scalar + unused_configuration, divider,
           recurrence_bound, load_use_bound)
       + spill_service + additive_configuration
```

This includes separate load/store services with a shared floor, predicate sharing,
strided group service, movement, FP division, and the original conservative
recurrence/load-use eligibility. New dependency observations do not automatically
introduce new latency assumptions. Whole-register loads/stores use the same
unit-stride memory service, with their physical transfer width. Arithmetic remains saturating with fractional
InstructionCost precision. The test-only frozen formula oracle checks migration.

Scalar candidates use the existing scalar resource coefficient (0.5 per ordinary
scalar instruction) and the same spill/configuration policy. This is a new scalar
reference, not the previous TTI scalar estimate. A scalar candidate means that
LoopVectorize leaves that loop scalar; ordinary later optimizations still run.

For effective width W and the original comparison's constant trip-count bound T:

```text
unknown T:    body / W
scalar tail:  body * floor(T/W) + (scalar_body / scalar_width) * (T % W)
folded tail:  body * ceil(T/W)
```

A known bound is not claimed to be the actual execution count. These are scores
for repeated loop-body work, not full function execution estimates. Scalar probes
also use the tail formula when their bodies have been unrolled. The middle
end compares the returned rational scores without recomputing normalization or
tails. Ties retain scalar first, then candidate manifest order.

## Usage

Build with the instructions in [README.md](README.md), then run:

```sh
uv run --project utils/vplan-tools python utils/vplan-meta-compile \
  --clang build-vplan-tools/bin/clang --input kernel.c \
  --work-dir observations-o3 --output kernel.o --detail \
  -- --target=riscv64-unknown-elf -march=rv64gcv \
  -mcpu=xiangshan-kunminghu -O3 -ffreestanding
```

Use a new or empty work directory. `-O2` works identically as an interface, but
may generate different candidates and machine code. No optimization option is
silently replaced with `-O2`. Other optimization levels, size optimization, LTO,
profiling, sanitizers and new-PM codegen are outside the initial meta interface.

`--emit llvm|asm|obj` selects the final artifact. `--stop-after-ra` collects all
analytics and backend costs without final replay. `--timeout` applies separately
to each compiler invocation. No benchmark database or measurements are read by
the meta compiler. Evaluation tools preserve the database's compilation context;
O2 and O3 measurements must not be mixed as if they were equivalent.

## Compiler interfaces and artifacts

Pass hidden options through clang with `-mllvm`:

| Option | Purpose |
| --- | --- |
| `-vplan-pipeline=prepare\|resume` | Produce or consume the pre-vectorizer checkpoint. |
| `-vplan-candidates-output=PATH` | Candidate/configuration manifest. |
| `-vplan-ra-run-id=DIGEST` | Checkpoint/compiler/options identity. |
| `-vplan-probe-candidate=ID` | Materialize one generated candidate. |
| `-vplan-analytics-output=PATH` | Raw cost-independent observations. |
| `-stop-after=riscv-vplan-analytics` | Run analytics without costing. |
| `-vplan-scalar-analytics-input=PATH` | Same loop's scalar observations for vector scoring. |
| `-vplan-cost-output=PATH` | Cost result and resource breakdown. |
| `-stop-after=riscv-vplan-cost` | Stop after both backend passes. |
| `-vplan-ra-feedback=PATH` | Read computed scores for final selection. |
| `-print-vplans`, `-print-detailed-vplans` | Report effective scores and optional breakdown. |

Protocol v2 intentionally rejects old v1 feedback; regenerate artifacts.
`pre-vectorize.bc` records the optimization level and rejects mismatched resume.
`identity.json` binds the checkpoint, compiler and complete flags.
`candidates.json` records generated candidates without a legacy cost prerequisite.
Each probe writes `.analytics.json`, `.cost.json`, `.mir`, `.manifest.json` and
compiler logs. `feedback.json` contains costs and observed selections, not feature
objects for the middle end to reinterpret. Quarter-unit numerators and integer
denominators preserve exact score comparisons; cross-products avoid overflow.

Missing, extra, stale and duplicate feedback, unsupported model operations,
unprovable regions and probe/final configuration changes fail explicitly. They
never silently drop a candidate or fall back to the old cost model. Analytics
can still be dumped for unsupported cases, with the reason available for diagnosis.

## Validation

```sh
cmake --build build-vplan-tools --parallel 2 --target \
  clang opt llc FileCheck RISCVTests VectorizeTests VPlanRATests
python3 build-vplan-tools/bin/llvm-lit -j 2 \
  llvm/test/CodeGen/RISCV/vplan-ra \
  llvm/test/Transforms/LoopVectorize/RISCV/vplan-ra-checkpoint.ll
build-vplan-tools/unittests/Target/RISCV/RISCVTests --gtest_filter=VPlanBackendCost.*
build-vplan-tools/unittests/Transforms/Vectorize/VPlanRATests
VPLAN_CLANG="$PWD/build-vplan-tools/bin/clang" \
  uv run --project utils/vplan-tools python -m unittest discover -s utils/vplan-tools/tests
```

Formula preservation applies to equivalent observations. Cleanup changes the
observations, and the scalar reference and ranking policy have changed, so old
selected VFs and frozen evaluation metrics are not claimed as current results.

## Dataset calibration tools

The independent uv project in `utils/vplan-tools` reads `dataset.sqlite` only.
`calibrate` learns shared internal coefficients from tuning data; `evaluate-weights`
uses them on validation, while `evaluate` uses LLVM's unchanged backend model.
See the [tools guide](utils/vplan-tools/README.md) for commands and the audited split.

The driver optionally accepts `--extract-function NAME` and `--llvm-extract PATH`
to isolate a function and its callees at the pre-vectorizer checkpoint.
`--analytics-only --stop-after-ra` emits candidate observations without backend
costs, feedback, or final replay. Unsupported analytics remain visible to the
consumer. The Python fitting model preserves hard max/min but computes continuous
costs without InstructionCost quantization; learned coefficients never enter LLVM.
