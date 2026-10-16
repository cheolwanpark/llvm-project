# VPlan meta-compiler and post-RA research hooks

`utils/vplan-meta-compile` compiles one C source through a non-LTO RISCV64 `-O2`
pipeline. It checkpoints the module immediately before `LoopVectorizePass`,
enumerates generated main VPlans and their supported fixed/scalable VFs, runs
each valid candidate through register allocation, and returns to that checkpoint
to make the final main-VF decision using the observations. It never reads cycle
measurements or a benchmark database.

```sh
python3 utils/vplan-meta-compile \
  --clang build-vplan-tools/bin/clang --input kernel.c \
  --work-dir /tmp/kernel-ra --output /tmp/kernel.o \
  -- --target=riscv64-unknown-elf -march=rv64gcv \
  -mcpu=xiangshan-kunminghu -O2 -ffreestanding \
  -mllvm -scalable-vectorization=on \
  -mllvm -force-vector-interleave=1 \
  -mllvm -riscv-v-register-bit-width-lmul=8
```

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

## Research surfaces

`llvm/lib/Target/RISCV/RISCVVPlanRAFeatures.cpp` implements
`collectRISCVVPlanRAFeatures(const MachineFunction &)`. It initially returns `{}`.
Researchers define useful observations and their units here, preserving machine
instructions. The observer, scheduling and JSON envelope remain fixed.

`llvm/lib/Transforms/Vectorize/VPlanRACostModel.cpp` implements
`costWithRAFeatures(Plan, VF, OriginalCost, Features)`. It initially returns
`OriginalCost`. Researchers can define the main-loop cost model here without
changing the transport. Return a valid nonnegative `InstructionCost`; the normal
vectorizer handles width normalization, tails and profitability. IC and epilogue
selection use the original costs so they stay consistent with the probed variant.
Scalar machine state is collected as a reference; the existing scalar cost
baseline remains unchanged. The official metric still ranks measured scalable
VFs, with smaller-VF tie breaking independent of the compiler's policy overrides.

The standalone `VPlanRATests` binary supplies a synthetic cost hook to prove that
feedback changes actual vectorizer selection. That hook is not linked into clang
or opt. The production hook intentionally introduces no predictive heuristic.
