# Post-RA model for VPlan vector cost

The Post-RA model uses RISC-V machine instructions after register allocation to
estimate the cost of each generated VPlan/VF candidate. Backend observations are
returned as version 1 JSON feedback to the middle-end cost hook before final
main-loop VF selection. The model is enabled through the meta-compiler/feedback
path below; an ordinary clang invocation without that feedback uses the existing
costs. Candidate generation, legality, lowering, register allocation, interleave
count (IC), and epilogue policies retain their existing behavior.

`utils/vplan-meta-compile` compiles one C source through a non-LTO RISCV64 `-O2`
pipeline. It checkpoints the module immediately before `LoopVectorizePass`,
enumerates generated main VPlans and their supported fixed/scalable VFs, runs
each valid candidate through register allocation, and returns to that checkpoint
to make the final main-VF decision using the observations. It never reads cycle
measurements or a benchmark database.

## Build and run

The following builds a standalone checkout with CMake, Ninja, a C/C++ toolchain,
and Python 3. RISC-V supplies the model; AArch64 enables the accompanying VPlan
reporting regression tests. The build uses two compile jobs and one link job.

```sh
git clone --depth 1 --single-branch --branch backend-aware-vector-cost \
  https://github.com/cheolwanpark/llvm-project.git
cd llvm-project
cmake -S llvm -B build-vplan-tools -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_ASSERTIONS=ON \
  -DLLVM_ENABLE_PROJECTS=clang '-DLLVM_TARGETS_TO_BUILD=RISCV;AArch64' \
  -DLLVM_INCLUDE_TESTS=ON -DCLANG_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_PARALLEL_COMPILE_JOBS=2 -DLLVM_PARALLEL_LINK_JOBS=1 \
  -DCLANG_ENABLE_STATIC_ANALYZER=OFF -DCLANG_ENABLE_OBJC_REWRITER=OFF
cmake --build build-vplan-tools --parallel 2 --target \
  clang clang-resource-headers opt llc FileCheck count not split-file llvm-config \
  VectorizeTests VPlanRATests

mkdir post-ra-example
cat > post-ra-example/kernel.c <<'C'
void add(float *restrict dst, const float *restrict a,
         const float *restrict b, unsigned n) {
  for (unsigned i = 0; i < n; ++i)
    dst[i] = a[i] + b[i];
}
C
python3 utils/vplan-meta-compile \
  --clang build-vplan-tools/bin/clang --input post-ra-example/kernel.c \
  --work-dir post-ra-example/observations --output post-ra-example/kernel.o \
  --detail \
  -- --target=riscv64-unknown-elf -march=rv64gcv \
  -mcpu=xiangshan-kunminghu -O2 -ffreestanding \
  -mllvm -scalable-vectorization=on \
  -mllvm -force-vector-interleave=1 \
  -mllvm -riscv-v-register-bit-width-lmul=8
```

This creates a RISC-V object, `post-ra-example/kernel.o`, and the candidate,
probe MIR, feedback, and final-selection artifacts under
`post-ra-example/observations`. Use a new example/work directory on another run.
Cross-compilation does not execute the kernel and needs no RISC-V runtime for
this freestanding example.

The work directory must be new or empty. `--emit llvm|asm|obj` selects the final
output (default `obj`). `--stop-after-ra` collects every candidate without running
the final compilation; in that mode `--output` is unnecessary. `--detail` requests
a detailed final VPlan report. Only the final compiler's diagnostics are forwarded
to stderr; stdout is a small JSON result. All intermediate diagnostics are saved.
`--timeout` is seconds per compiler invocation, default 120, with no total timeout.

## Compiler interfaces

Pass these hidden LLVM options through clang's `-mllvm`:

| Option | Meaning |
| --- | --- |
| `-vplan-pipeline=prepare` | Run the optimization prefix and emit checkpoint bitcode with `-emit-llvm -c`. |
| `-vplan-pipeline=resume` | Consume a prepared checkpoint and run the remaining optimization pipeline. |
| `-vplan-candidates-output=PATH` | Write versioned candidate and actual-selection JSON. |
| `-vplan-ra-run-id=DIGEST` | Bind all artifacts to a checkpoint/compiler/options identity. |
| `-vplan-probe-candidate=ID` | Select a specific regenerated plan/VF after ordinary planning. |
| `-vplan-ra-features-output=PATH` | Observe the probe function after complete RISC-V RA. |
| `-stop-after=riscv-vplan-ra-observe` | Stop after observation and emit MIR instead of assembly. |
| `-vplan-ra-feedback=PATH` | Read backend observations for the final cost comparison. |

The driver supplies these options. Do not substitute `force-vector-width`: that
changes planning and takes shortcuts through the normal cost comparison. Probes
bypass the selected candidate's outside-loop *profitability* rejection, while
retaining legality checks and runtime guards. Invalid-cost plans are recorded but
cannot be probed. Any valid candidate that fails to compile or materialize fails
the operation; the driver never silently removes it.

Preparation and resumption share the normal pipeline construction. Prefix passes
are not rerun on the checkpoint. The normal compiler path remains unchanged when
the options are absent. Preparation creates a module-wide boundary between the
function optimization prefix and suffix; analyses are rebuilt on resumption.
The initial supported workload is extracted inner loops. Multiple original loops
are probed independently, leaving other loops at baseline choices. Interacting
loops whose regenerated candidate context changes are rejected, not merged into
a misleading comparison. LTO, profiling, sanitizers, outer-loop VPlans and other
optimization levels are not supported by this initial interface.

The RA observer is immediately after both RVV and general register allocation and
register rewriting, before subsequent post-RA optimizations and frame lowering.
It checks that non-debug instructions have no virtual register operands. Raw MIR
still contains pseudos and frame indices; it is not final assembly or measured
execution time. All target/ABI/codegen options are replayed via the same clang.

## Artifacts and protocol

- `pre-vectorize.bc`, `identity.json`: checkpoint and its SHA-256 identity, including
  the compiler binary, compiler options and protocol version.
- `candidates.json`: candidates with identity, original body cost, VF, scalar-tail
  status and probeability; original selection records are separate.
- `probe-NNNN.mir`, `.json`, `.manifest.json`: machine state, features and actual
  configuration for one candidate; `.stderr`/`.stdout` retain compiler diagnostics.
- `feedback.json`: complete observations returned to the vectorizer.
- `final.manifest.json`, `final.stderr`: actual final choices and effective cost
  report. The candidate manifest's body costs remain the original costs used to
  verify replay; the final VPlan report contains the effective ranking costs.
- `commands.json`, `result.json`: exact invocations and successful completion.

Protocol version 1 uses JSON. Feedback has `version`, `run_id`, and `candidates`.
Each feedback row contains `id`, an extensible `features` object, the probe's
`selection` (`id`, `ic`, `epilogue_vf`, `emitted`), and its `mir` path for diagnosis.
The compiler consumes the feature object, not the MIR path. IDs combine function,
original loop ordinal, generated plan ordinal, and VF (`fN`/`sN`). They are opaque
join keys within one run, never model inputs or persistent IDs across revisions.
Duplicate, missing, extra, stale, and mismatched feedback is rejected. Final IC
and epilogue VF must match the corresponding probe.

## Observations and cost calculation

`llvm/lib/Target/RISCV/RISCVVPlanRAFeatures.cpp` implements
`collectRISCVVPlanRAFeatures(const MachineFunction &)`. It returns a
`resource_demand` object containing a version, support status, aggregate work,
per-operation classifications, and proven dependency observations. Collection is
read-only. The current resource model requires the `xiangshan-kunminghu` tune CPU
and vector instructions. It identifies an unambiguous innermost vector loop,
requires a latch that is its unique exiting block, and requires every region
block to dominate that latch. Unsupported instructions or ambiguous regions mark
the observation unsupported. Recurrence and load-use observations are collected
for single-block regions only.

Aggregate fields ending in `8` represent eighth units of work; vector service
uses 128-bit chunks, SEW, and register grouping where applicable. These are model
units, not CPU cycles. Per-operation records distinguish unit-stride, strided,
and indexed accesses, load/store direction, masks, proven predicate identity,
copies, slides, and floating-point division. Packed-mask Boolean operations use
packed-bit demand with an issue floor. Configuration work is partitioned into
proven-unused scalar results and additive work with live or uncertain results.

`llvm/lib/Transforms/Vectorize/VPlanRACostModel.cpp` implements
`costWithRAFeatures(Plan, VF, OriginalCost, Features)`. Its main-loop body estimate
has the following structure:

```text
body = max(memory + masked_service, arithmetic, movement,
           scalar + unused_configuration, divider,
           recurrence_bound, load_use_bound)
       + spill_service + additive_configuration
```

- Memory includes ordinary access demand and extra strided group service. When
  all access directions are present and consistent with aggregate work, separate
  load/store services compete with a shared floor that retains at least 7/8 of
  symmetric ordinary demand. Masked group service shares one quarter of its
  delivery term among accesses with a proven common predicate; unproven
  identities keep independent service.
- Arithmetic combines integer and floating-point demand. Copies and slides share
  a movement resource; division has its own service bound. Scalar work and
  proven-unused configuration results compete with vector resources. Recurring
  spill traffic and live/uncertain configuration work remain additive.
- Proven loop-carried FP chains contribute a recurrence bound. Load-rooted,
  block-local arithmetic paths contribute a load-use bound with chunk forwarding.
  Independent chains and paths compete by maximum rather than summation.

The implementation accumulates with saturating `InstructionCost` arithmetic and
preserves fractional precision through the final body-cost division. The caller
continues to handle VF normalization, scalar tails, profitability, and the scalar
reference cost. IC and epilogue selection use original costs, preserving the
configuration observed by the probe.

Scalar VFs, missing or unsupported `resource_demand`, unsupported versions, and
malformed required cost observations return `OriginalCost`. Optional extensions
have conservative compatibility behavior: missing dependency observations add
no new bound; incomplete direction information retains symmetric memory service;
and missing or inconsistent configuration partitions retain additive
configuration service. This cost fallback is distinct from invalid feedback
transport: stale, incomplete candidate sets or mismatched probe selections are
rejected by the protocol rather than silently accepted.

Coefficients are empirical heuristics informed by hardware structure, not a
calibrated model of measured CPU cycles. Some priors come from other RISC-V
scheduling descriptions; Kunminghu itself has `NoSchedModel`. In particular,
divider service and dependency latencies should not be read as measured Kunminghu
RVV timings. The resource maximum expresses assumed overlap, not a proof that
instructions execute in parallel.

## Tests and provenance

After the build above, run the focused regression suites and reporting tests:

```sh
python3 build-vplan-tools/bin/llvm-lit -j 2 \
  llvm/test/Analysis/CostModel/RISCV \
  llvm/test/Transforms/LoopVectorize/RISCV \
  llvm/test/CodeGen/RISCV/vplan-ra \
  llvm/test/Transforms/LoopVectorize/AArch64/print-vplans.ll \
  llvm/test/Transforms/LoopVectorize/AArch64/print-vplans-costs.ll \
  llvm/test/Transforms/LoopVectorize/AArch64/print-vplans-paths.ll
build-vplan-tools/unittests/Transforms/Vectorize/VectorizeTests
build-vplan-tools/unittests/Transforms/Vectorize/VPlanRATests
```

`VectorizeTests` covers model arithmetic and fallback behavior. MIR tests cover
resource and dependency collection. `VPlanRATests` uses a separate synthetic hook
to test that feedback changes actual vectorizer selection; that synthetic hook
is not linked into clang or opt. Clang and opt use the production Post-RA model
when supplied with valid feedback.

The published implementation is the frozen Old final model (experiment e000051),
source commit `4a5ff1127e111754133ddfe3712dc89dcb01520b`. Its supporting reporting
code comes from `0a3f77007be9520449ea8ec854a0a777ee48329c`, and post-RA transport
and meta-compilation infrastructure from
`c93c542395f5c014ad2d98f96a125f408cb3eed3`. The publication preserves the final
source tree apart from this documentation, without experimental switches or
additional model tuning.

Reproduction against the frozen development evaluation assets gives:

| Metric | Original-cost baseline | Post-RA model |
| --- | ---: | ---: |
| Tuning Top-1 correct | 3/8 | 5/8 |
| Validation Top-1 correct | 62/132 | 81/132 |
| Validation mean regret | 0.06188774993050167 | 0.026960697618935218 |
| Compilation failures across all benchmarks | 0/214 | 0/214 |

Scoring uses the same fixed 140-benchmark cohort (8 tuning, 132 validation); the
other 74 benchmarks are not newly admitted to the score. Reproduction checks
compare exact rational VF costs, per-plan body/ranking costs, selections,
measurements, candidate/probe policy, resource observations, and serialized probe
MachineFunctions, separating run identities and paths as provenance. Only
aggregate floating-point metrics use a `1e-12` tolerance.

The validation set was used during model selection and is a development
evaluation set, not an independent test set. These results measure agreement
with frozen measured-VF rankings; they do not demonstrate an improvement in
measured execution speed from this compiler. Evaluation databases, campaign
logs, and build outputs are not part of this branch.
