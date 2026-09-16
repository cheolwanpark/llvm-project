# Reduction fission: flags, execution policy, and integration guide

This guide describes the experimental implementation in this worktree on
`codex/reduction-fission`, based on LLVM revision
`ca7933e47d3a3451d81e72ac174dcb5aa28b59d1`. It is intended for developers and
coding agents using or modifying the implementation. These behaviors are local
to this implementation; an unmodified LLVM installation does not accept the
new selection syntax.

The change extends the existing hidden LLVM option **`-force-vector-width`**
with **`fission:N`**. It does not introduce a separate public Clang driver flag.
Pass LLVM options directly to `opt`, or through `-mllvm` when invoking Clang.

## 1. Selection syntax

| Option | Meaning |
|---|---|
| No force option, or `-force-vector-width=0` | Ordinary automatic selection; Fission is never automatically selected. |
| `-force-vector-width=4` | Existing Normal vectorization, requesting width 4. |
| `-force-vector-width=fission:4 -scalable-vectorization=off` | Request Fission with a fixed Map VF of 4. |
| `-force-vector-width=fission:4 -scalable-vectorization=on` | Request Fission with a scalable Map VF of `vscale x 4`. |

`N` is a lane count (the known-minimum element count for scalable vectors),
not a byte count, LMUL, interleave count, or reduction VF. The Fission parser
accepts nonzero powers of two through 64. `fission:0`, `fission:3`, and
`fission:128` are rejected. `fission:1` parses, but fixed VF1 is scalar and is
not a Fission vector candidate; scalable `vscale x 1` can be a vector candidate.
Passing the syntax check does not guarantee a legal plan at that width.

The numeric form retains the existing unsigned parser, including zero and
hexadecimal notation. Numeric non-power-of-two inputs still parse as before;
this is not a promise that the vectorizer can use every such width.

Specify `-scalable-vectorization` explicitly for reproducible experiments.
`on` and `preferred` name the same setting in this revision. With an explicit
width and no scalable loop metadata or scalable override, the existing hint
logic treats the width as fixed. Original loop metadata can affect the
effective width; see the precedence rules below.

## 2. What executes

For independent accumulators, the transformation has this shape:

```c
// Original loop.
for (i = 0; i < n; ++i) {
  sum += a[i];
  dot += a[i] * b[i];
}

// Conceptual Fission result; allocation and initialization omitted here.
for (i = 0; i < n; ++i) {
  sum_input[i] = a[i];
  dot_input[i] = a[i] * b[i];
}
for (i = 0; i < n; ++i)
  sum += sum_input[i];
for (i = 0; i < n; ++i)
  dot += dot_input[i];
```

The entire Map completes before any reduction begins. There is one separate
reduction loop per accumulator: no chunking, tiling, or merging of different
accumulators into one recurrence loop. Buffers contain independent per-iteration
values, not partial accumulated results. One recurrence can require multiple
input buffers, and a shared input can be stored once. For example, TSVC `s319`
has one accumulator updated twice per iteration, so its implementation uses
two input buffers and one reduction loop.

Buffers use the exact runtime trip count and checked address-sized byte
arithmetic. There is no arbitrary buffer-size or profitability limit.
Zero-trip execution bypasses allocation; cleanup follows the reductions,
including for repeated calls and source loops nested in an outer loop.
Allocation failure or unrepresentable size traps.

### Candidates, planning, and rollback

The logical identities are `Normal(VF)` and `Fission(MapVF=VF)`. For each
supported Normal vector factor, an eligible source loop gets a corresponding
Fission candidate. Scalar fallback is counted separately. Adding accumulators
does not create a Cartesian product of VF choices.

Fission's reported cost is `INF (manual only)`. This is an explicit automatic
selection exclusion, not an invalid/max `InstructionCost`; it does not enter
ordinary cost arithmetic or minimum-profitable-trip-count calculations.
Manual selection bypasses profitability, while retaining legality checks.

Analysis examines untouched scalar IR using `RecurrenceDescriptor` and
accumulator-dependent instruction slices. A candidate listing is preliminary:
the actual generated components must also have supported VPlans. After
selection, a private function clone is distributed and its components are
planned with fresh analyses. The Map must use the selected VF. Each reduction
is tested at its legal widths, largest first, independently of other reductions.

Only a successful transaction replaces the original function body. If any
selected component fails, all selected transformations in that function are
rolled back, including earlier successful ones. An ineligible source loop is
not partially distributed. Other eligible source loops in the same function
can still be selected; eligibility is assessed per original loop, while
rollback after a selected component failure is at function scope.

The pass does not provide a scalar-only distributed recurrence fallback.
Ordinary vectorization tails and supported runtime-versioned paths remain
possible. Later optimization passes may vectorize an untouched loop normally;
that is not evidence of successful Fission.

## 3. RVV width policy and LMUL tuning

The Map uses its selected fixed or scalable VF. On RISC-V, each reduction uses
a separately selected **scalable** VF and interleave count **1**. The
implementation probes actual contribution, intermediate, and accumulator type
legality, and then the generated VPlan. It does not equate the target's preferred
register width with the maximum legal reduction width.

Typical supported same-type reductions reach the following widths:

| Actual reduction type | LLVM scalable VF | RVV arithmetic LMUL |
|---|---|---:|
| i16 | `vscale x 32` | 8 |
| i32 / f32 | `vscale x 16` | 8 |
| i64 / f64 | `vscale x 8` | 8 |

This table describes width mapping, not a guarantee that every reduction kind
on each type is supported. Wider inputs/intermediates or unsupported plans can
constrain the width or reject the transformation. RVV uses `vscale = VLEN / 64`;
for example, `vscale x 16 x float` has 32 lanes on VLEN128 hardware.

### Expanding the Map candidate range

`-riscv-v-register-bit-width-lmul=L` is an existing target tuning option, with
default 2 in this revision. It changes the register width reported to the
vectorizer and can expand Normal and corresponding Fission Map candidates.
It neither selects Fission by itself nor fixes Fission reduction LMUL to `L`.

The following ranges were verified for f32 single- and two-accumulator examples
with generic `riscv64`, `+v,+f,+d`, and minimum VLEN128. Other types, targets,
loop structure, or metadata can produce different ranges.

| Tuning LMUL | Fixed Normal/Fission candidate VFs | Scalable Normal/Fission known-minimum VFs |
|---:|---|---|
| 1 | 2, 4 | 1, 2 |
| 2 | 2, 4, 8 | 1, 2, 4 |
| 4 | 2, 4, 8, 16 | 1, 2, 4, 8 |
| 8 | 2, 4, 8, 16, 32 | 1, 2, 4, 8, 16 |

Each configuration's largest forced Fission candidate committed. Source-derived
TSVC `s311` and `s319` also compiled and lowered at the corresponding maximum
Map VF in Normal and Fission modes. The Fission f32 reductions retained LMUL8
for every tuning value. Automatic-selection controls did not apply Fission.
These additional range checks are compile/lowering evidence, not new runtime
or performance measurements.

Examples of option groups for `opt`:

```sh
# Fixed Map VF32; independently selected scalable reductions.
-riscv-v-register-bit-width-lmul=8 \
-scalable-vectorization=off -force-vector-width=fission:32

# Scalable Map VF=vscale x 16; independently selected scalable reductions.
-riscv-v-register-bit-width-lmul=8 \
-scalable-vectorization=on -force-vector-width=fission:16
```

These are option groups, not standalone shell commands. In Clang, prefix each
LLVM option with `-mllvm`.

The separate `-riscv-v-fixed-length-vector-lmul-max` option limits fixed-length
vector lowering and already defaults to **8**. It is not interchangeable with
the register-width tuning option and does not cap scalable Fission reductions.
Changing this cap can affect fixed Map lowering; do not assume the table above
still applies after changing it. The expanded-range verification used the
default cap. Supply consistent target features and backend options to `opt`
and `llc` when using a split pipeline.

## 4. Interaction with other vectorization controls

| Control | Behavior with Fission |
|---|---|
| `-force-vector-width=N` | Selects the Normal path. Use this as the numeric-force comparison, with matching scalable/target settings. |
| `-scalable-vectorization=off/on/preferred` | Controls the original loop's effective Map setting. It does not force generated RVV reductions to become fixed. |
| `-force-vector-interleave=N` | Retains its ordinary effect on original loop planning. Generated Map **and** reduction loops get IC1; this global override is not reapplied to them. VF and IC are separate quantities. |
| `-interleave-loops=false` | Controls ordinary interleaving policy. Generated components already request IC1. This is distinct from interleaved-memory-access transformations. |
| `-riscv-v-register-bit-width-lmul=L` | Tunes the ordinary/Map candidate range; reductions still independently probe their maximum legal supported scalable width. |
| `-mtriple`, `-mattr`, `-mcpu`; Clang `--target`, `-march`, `-mcpu` | Determine target support and costs. The force syntax does not enable RVV or invent support for an unavailable operation. |
| `-force-target-supports-scalable-vectors` | A testing override for vectorizer support queries, not a substitute for backend instruction/type legality. Real RVV examples below do not need it. |
| `-ffast-math` or explicit IR fast-math flags | Supply the FP permissions required by the recurrence. Fission itself does not grant reassociation, discard signed-zero semantics, or weaken ordered FP. |
| `-ffp-contract=off/fast` | Affects frontend contraction opportunities. Fission preserves the selected recurrence slice; it does not split a fused operation to fit a one-buffer design. |
| `-enable-epilogue-vectorization` | Ordinary/Map policy still applies. Generated reduction loops explicitly disable a smaller vectorized epilogue. A supported scalar tail or tail-folded implementation remains possible. |
| `-prefer-predicate-over-epilogue`, `-force-tail-folding-style` | Still affect component planning where applicable; generated-loop isolation is not a blanket override of all vectorizer options. Incompatible tail requirements can reject a component and roll back Fission. Arbitrary combinations have not all been tested. |
| `-fno-slp-vectorize` / `-vectorize-slp=false` | Disable SLP, a different vectorizer. They do not disable this Loop Vectorizer candidate. |
| `-fno-vectorize` / `-vectorize-loops=false` | Do not use these as a guaranteed cancellation of an explicit Fission request. This implementation marks eligible original loops forced; the Loop Vectorizer can run in forced-only mode. Direct Clang O2 with `-fno-vectorize` and `fission:4` was verified to commit. |
| `-O0`, a pipeline without `loop-vectorize`, or an `optnone` function | The option is not a standalone transformation pass and does not guarantee that the necessary pass executes. Use the explicit pipeline below or a verified optimization pipeline. |

To run a no-Fission control, remove the `fission:N` request (or use the numeric
form). Do not rely on unrelated vectorization-disable flags while retaining
an explicit Fission force request.

### Original metadata versus generated metadata

For an original loop, the constructor initializes width from the command line
and then reads loop metadata. A valid `llvm.loop.vectorize.width` hint can
therefore override the command-line width. The effective hinted VF is used for
Fission selection. For controlled sweeps, remove conflicting pragmas/metadata
or inspect the actual selected Map VF in remarks.

An explicit `llvm.loop.vectorize.enable = false` is respected. The Fission
request enables forced selection only if the original loop is not explicitly
disabled. Original `llvm.loop.isvectorized` markers and other ordinary pass
gates can also prevent a loop from reaching candidate planning. For original
loops, an explicit global scalable setting overrides the scalable hint, and
the global interleave force overrides the original interleave hint.

Generated components carry internal metadata:

- `llvm.loop.reduction.fission.generated` identifies both Map and reductions.
- `llvm.loop.reduction.fission.reduction` additionally identifies reductions.
- Their own `llvm.loop.vectorize.width`, `llvm.loop.vectorize.scalable.enable`,
  `llvm.loop.vectorize.enable`, and `llvm.loop.interleave.count` specify the
  selected component policy.

Global VF, scalable, and interleave force options are not reapplied to these
components. This prevents recursive Fission and accidental reuse of Map width
for reductions. Do not add these internal markers to arbitrary user loops as
a public configuration mechanism. Relevant unrelated Map metadata is preserved;
reductions receive independent loop IDs for their scratch-storage accesses.

## 5. Reproducible examples

Use the modified tools from this worktree's build. A matching base version
string alone does not prove that an executable contains uncommitted changes.
The local validated build is `../reduction-fission-build` relative to this
worktree. Adjust `RF_BIN` if using another build directory.

### Direct Clang pipeline

Run from the project root. The example has two independent accumulators and
requires no target system headers or linker. `-ffast-math` is intentional for
this example; use only FP permissions appropriate to the real input program.

```sh
RF_BIN="$(cd ../reduction-fission-build/bin && pwd)"
RF_OUT="$(mktemp -d "${TMPDIR:-/tmp}/reduction-fission-guide.XXXXXX")"

cat > "$RF_OUT/example.c" <<'EOF'
void reduce_pair(const float *restrict a, const float *restrict b,
                 int n, float initial_sum, float initial_dot,
                 float *restrict result) {
  float sum = initial_sum;
  float dot = initial_dot;
  for (int i = 0; i < n; ++i) {
    sum += a[i];
    dot += a[i] * b[i];
  }
  result[0] = sum;
  result[1] = dot;
}
EOF

"$RF_BIN/clang" --target=riscv64 -march=rv64gcv -mabi=lp64d \
  -O2 -ffast-math -ffp-contract=off -ffreestanding -fno-builtin \
  -mllvm -force-vector-width=fission:4 \
  -mllvm -scalable-vectorization=off \
  -Rpass=loop-vectorize -Rpass-analysis=loop-vectorize \
  -Rpass-missed=loop-vectorize -fsave-optimization-record=yaml \
  -foptimization-record-file="$RF_OUT/clang.remarks.yaml" \
  -S -emit-llvm "$RF_OUT/example.c" -o "$RF_OUT/clang.ll"

"$RF_BIN/llc" -mtriple=riscv64 -mattr=+v,+f,+d \
  -verify-machineinstrs "$RF_OUT/clang.ll" -o "$RF_OUT/clang.s"
```

For the wider scalable example, replace the two `-mllvm` settings with:

```sh
-mllvm -force-vector-width=fission:16 \
-mllvm -scalable-vectorization=on \
-mllvm -riscv-v-register-bit-width-lmul=8
```

Both direct configurations were compiled and machine-verified with the modified
tools. For a Normal comparison, replace `fission:4` with `4`, or `fission:16`
with `16`, keeping the other settings the same. Use separate output names.

### Inspect the immediate transformation with opt

The following uses the same `RF_BIN`, `RF_OUT`, and example source. Preparing
scalar IR first avoids comparing against an already-vectorized input.

```sh
"$RF_BIN/clang" --target=riscv64 -march=rv64gcv -mabi=lp64d \
  -O1 -Xclang -disable-llvm-passes -ffast-math -ffp-contract=off \
  -ffreestanding -fno-builtin -fno-discard-value-names \
  -S -emit-llvm "$RF_OUT/example.c" -o "$RF_OUT/raw.ll"

"$RF_BIN/opt" \
  -passes='default<O1>,mem2reg,sroa,instcombine,simplifycfg,loop-simplify,lcssa,loop-rotate,instcombine,simplifycfg,loop-simplify,lcssa' \
  -vectorize-loops=false -vectorize-slp=false -verify-each \
  -S "$RF_OUT/raw.ll" -o "$RF_OUT/scalar.ll"

"$RF_BIN/opt" -passes='loop-vectorize,verify' \
  -mtriple=riscv64 -mattr=+v,+f,+d \
  -force-vector-width=fission:4 -scalable-vectorization=off \
  -verify-dom-info -verify-loop-info -verify-scev \
  -pass-remarks=loop-vectorize -pass-remarks-analysis=loop-vectorize \
  -pass-remarks-missed=loop-vectorize \
  -pass-remarks-output="$RF_OUT/opt.remarks.yaml" \
  -S "$RF_OUT/scalar.ll" -o "$RF_OUT/after-fission.ll"

"$RF_BIN/opt" -passes='default<O2>' -verify-each \
  -mtriple=riscv64 -mattr=+v,+f,+d \
  -S "$RF_OUT/after-fission.ll" -o "$RF_OUT/final.ll"

"$RF_BIN/llc" -mtriple=riscv64 -mattr=+v,+f,+d \
  -verify-machineinstrs "$RF_OUT/final.ll" -o "$RF_OUT/final.s"
```

The scalar preparation command deliberately contains no Fission force option.
For candidate-range discovery, run the vectorizer command without
`-force-vector-width`, add the desired LMUL tuning value, and retain analysis
remarks. No Fission should commit in that automatic-selection run. Then use
separate forced invocations to validate particular Fission candidates.

## 6. Recognizing success and diagnosing rejection

| Remark name | Interpretation |
|---|---|
| `VectorizationCandidate` | Logical Normal/Fission candidate listing; not proof of transformation. |
| `ReductionFissionSelected` | Provisional selection on the trial function. |
| `ReductionFissionSchedule` | Actual generated reduction's maximum supported VF and IC1. |
| `ReductionFissionCommitted` | The function transaction succeeded and replaced the original body. |
| `ReductionFissionOriginalLegality` | The original loop failed ordinary vectorization legality. |
| `ReductionFissionRejected` | Structural/target eligibility failed, or requested Map VF has no plan. |
| `ReductionFissionPartFailed` | A generated component could not use its required plan/width. |
| `ReductionFissionRolledBack` | The selected transformation was discarded; original function preserved. |
| `ReductionFissionBlockAddress` | Function-body replacement is unsupported for address-taken blocks. |

A zero exit status, a vector instruction, or `ReductionFissionSelected` alone
is insufficient. Check the final commit remark, associate selected source loops
with that transaction, and inspect the output IR. For LLVM debugging builds,
`-debug-only=loop-vectorize` also prints the scalar IR immediately after the
selected split and before component vectorization.

Successful RVV output should have independent Map work and buffer stores,
separate recurrence loops, vector accumulator updates, and horizontal collapse
outside each recurrence's backedge. Examine actual SEW/LMUL and memory EEW:
`e8,m2` followed by `vle32.v` has EMUL8, just as `e8,m1` with `vle64.v` does.
Look at register use and control flow, not only mnemonic presence.

Later optimization can change presentation: TSVC `s311`'s fixed Map copy can
become `memcpy`, even though the immediate Map IR used the requested VF.
Inspect both immediate and final IR. Wider groups also increase register
pressure. TSVC `s352` has observed in-loop vector spills, and direct Clang O2
examples have observed vector spills around cleanup `free` calls. Such costs
are recorded, not filtered by a profitability policy. No speedup is promised.

## 7. Supported scope and invariants for maintainers

- Every source-loop recurrence must be an induction or an eligible independent
  reduction. Intermediate accumulator observation, dependencies between
  accumulators, or accumulator-dependent Map control/addresses reject the loop.
- Map must not retain a true carried recurrence. SSA, control, and memory value
  flow are considered, including cycles that ordinary LLVM can vectorize at a
  sufficiently small VF. Incomplete dependence information is diagnosed.
- Branch CFGs require a countable unique latch exit. Conditions may be buffered;
  conditional values are loaded only along paths where Map initialized them.
  Early exits and unsupported non-branch CFGs are rejected.
- FP permissions must already permit the chosen reduction. Ordered FP is not
  silently converted to unordered FP. Initial values, zero trips, tails, and
  required signed-zero behavior remain part of legality and execution.
- `llvm.fmuladd` is a supported distinct case whose operation is retained;
  genuine `llvm.fma` recurrences are currently not recognized by the existing
  descriptor. RVV scalable product reductions and some min/max variants remain
  unsupported by existing target legality.
- Preserve logical candidate identity above `ElementCount`. Normal
  `getPlanFor(VF)` still has its existing single-plan role; Fission components
  use fresh plans after distribution. Keep automatic exclusion explicit.
- Preserve generated-loop option isolation, IC1, independent maximum-width
  planning, and suppression of per-iteration horizontal collapse. Do not infer
  maximum legal reduction width from a preferred-register-width query.
- Rebuild affected analyses after distribution and invalidate original-body
  analyses on commit. Do not reuse original scalar-loop legality/cost results
  as if they described generated components.

## 8. Code, tests, and evidence

| Area | Source |
|---|---|
| Extended parser and global selection state | [LoopAccessAnalysis.cpp](llvm/lib/Analysis/LoopAccessAnalysis.cpp), [LoopAccessAnalysis.h](llvm/include/llvm/Analysis/LoopAccessAnalysis.h) |
| Candidate identity and scalar distribution | [ReductionFission.h](llvm/lib/Transforms/Vectorize/ReductionFission.h), [ReductionFission.cpp](llvm/lib/Transforms/Vectorize/ReductionFission.cpp) |
| Candidate enumeration | [LoopVectorizationPlanner.h](llvm/lib/Transforms/Vectorize/LoopVectorizationPlanner.h) |
| Selection, component planning, transaction, and reduction policy | [LoopVectorize.cpp](llvm/lib/Transforms/Vectorize/LoopVectorize.cpp) |
| Hint precedence and FP safeguards | [LoopVectorizationLegality.cpp](llvm/lib/Transforms/Vectorize/LoopVectorizationLegality.cpp) |
| Existing RVV tuning options | [RISCVTargetTransformInfo.cpp](llvm/lib/Target/RISCV/RISCVTargetTransformInfo.cpp), [RISCVSubtarget.cpp](llvm/lib/Target/RISCV/RISCVSubtarget.cpp) |
| Concise implementation documentation | [ReductionFission.rst](llvm/docs/ReductionFission.rst) |

Run the nine focused lit files from the project root:

```sh
"$RF_BIN/llvm-lit" -j 2 -v \
  llvm/test/Transforms/LoopVectorize/reduction-fission-*.ll \
  llvm/test/Transforms/LoopVectorize/RISCV/reduction-fission-*.ll
```

The `force-option` test covers parser compatibility; `generated-hints` covers
global VF/IC/scalable isolation; the RISCV tests cover candidates, kinds,
control flow, FP semantics, memory recurrences, and rollback/transactions.

Local experiment evidence is outside the repository and is not automatically
included in a checkout. In this workspace it is available at
`../reduction-fission-evidence/`:

- [REPORT.md](../reduction-fission-evidence/REPORT.md): implementation, build,
  benchmark provenance, limitations, and runtime scope.
- [BUILD.md](../reduction-fission-evidence/BUILD.md): exact tool build commands,
  including the host-Clang-only O0 memory workaround.
- [LMUL range verification](../reduction-fission-evidence/lmul-range-check/README.md):
  candidate ranges, maximum-force checks, commands, IR/assembly, and tool hashes.
- [Documentation example results](../reduction-fission-evidence/documentation-examples/results.json):
  direct Clang examples and vectorization-disable flag interactions.
- [Benchmark results](../reduction-fission-evidence/BENCHMARK_RESULTS.md):
  final TSVC/PolyBench compilation and lowering classifications.
- [Runtime results](../reduction-fission-evidence/runtime/rvv/RESULTS.md):
  separately identified benchmark-derived RVV execution evidence.

Keep compile/lowering checks, runtime checks, and performance measurements
distinct when reporting results. Preserve tool identities, exact flags, target
features, source provenance, remarks, and both immediate/final artifacts when
extending the experiments.
