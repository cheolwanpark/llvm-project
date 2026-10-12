# Reduction Fission: implementation, flags, and validation

This document consolidates the earlier flags guide and implementation report
and describes the experimental implementation on the `reduction-fission` branch
of this LLVM 23.1.3 worktree. It includes the
storage encoding changes in commit `7b5de8dce79b` (separate physical storage and
consumer decoding). These behaviors are local to this implementation; an
unmodified LLVM installation does not accept its selection syntax.

The contract is **N independent reductions → one full-trip Map → N separate
reducer loops**. Each reducer completes its accumulation and horizontal collapse
before the next reducer starts. Existing stream reuse may leave an effect-free
Map empty, in which case it is explicitly removed. Independent products remain
Map contributions; storage sharing never fuses reducers.

Sections 1–8 describe current behavior and usage. Section 9 records validation
of the storage encoding change. Section 10 preserves the earlier report's
**pre-LLVM-23.1.3-rebase** campaign evidence; those campaign and QEMU results have
not been rerun for this change and are not current performance measurements.

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
values, not partial accumulated results. Normalization can combine multiple terms
into one logical contribution. A legal slice fallback can still consume multiple
streams. For example, TSVC `s319` retains two reusable output streams and one
reducer, avoiding a new buffer for their combined value. The copy of `a[i]` in
the example can also disappear when its input stream is safe to borrow.

Heap buffers use the exact runtime trip count and checked address-sized byte
arithmetic. Small constant scratch uses fixed entry-block allocas with lifetime
markers. `-reduction-fission-stack-budget` defaults to 16384 bytes, charging all
scratch together with existing static allocas in the function. Unknown existing
stack use, unknown counts, or an exceeded budget retain heap allocation. The
budget bounds IR storage, not the entire machine frame including spills;
`-reduction-fission-stack-budget=0` disables stack scratch. No dynamic alloca or
zero-fill is introduced. Entry placement prevents accumulation in outer loops.

Heap fallback requires available, correctly declared malloc/free builtins;
otherwise the transformation is rejected without changing the source function.
This matters for `-fno-builtin` and `-ffreestanding`. Zero-trip execution bypasses
allocation. Heap failure or unrepresentable size traps as before.

For a single-block Map, proven stable contiguous input or output streams can
replace scratch; a read-only loop does not need an output store to qualify.
Invariant contributions also need no per-iteration storage. If Map has neither
observable effects nor live-outs and its finite traversal is proved, it is
explicitly deleted. Every original accumulator still has its own reducer.
Conditional, overwritten, and uncertain streams use safe scratch or cause
rejection; a syntactically matching load or store alone is insufficient.

### Contribution normalization and arithmetic

Read-only analysis recognizes homogeneous associative integer/FP chains and
supported min/max intrinsic chains containing the accumulator exactly once.
Map computes their independent terms and combined contribution; the reducer
combines that logical value with its accumulator. An optional `llvm.fmuladd`
may contribute a separately rounded product in Map. Reloadable multiplicands
are not a reason to move that product into the reducer. Mandatory `llvm.fma`
and ordered/strict recurrences retain their rejection behavior.

Reassociated integer intermediates use modular arithmetic and do not inherit
unproven `nsw`/`nuw`. FP operations require the original rewrite permissions;
normalization intersects those permissions rather than promoting `reassoc` to
`fast`. New sums/products drop unproven `nnan`/`ninf`, and skipped identities do
not acquire `nsz`. Supported min/max chains retain justified flags and use finite
extrema when `ninf` excludes an infinite identity.

Conditional contributions keep loads and computations on their original paths
and select the appropriate identity for skipped updates. Scalar exit selections
preserve skipped initial NaN bits, flagged infinities, and zero signs where
required. The initializer is frozen once before its additional uses. Conditional
FP identities require IEEE denormal behavior; unproven initializer constraints
also reject a slice fallback rather than applying flags from skipped arithmetic.

Single subtractive updates and single compare/select min/max idioms can retain
their existing slice. More complex joins, heterogeneous updates, and dependent
casts retain an explicit fallback reason, or reject when no supported plan
exists. A contribution whose inputs already use safe streams keeps that
representation instead of materializing an equivalent combined stream.

### Logical contributions and physical storage

`ReductionFission.h` separates the two representations:

| Representation | Recorded information |
|---|---|
| Logical reduction input | Original contribution value/type, kept in the reduction plan. Reduction arithmetic retains this type. |
| `Storage` | `StoredValue`, physical `StoredType`, alignment, and optional SCEV `Start`. A null `Start` denotes owned scratch; a non-null `Start` denotes a proven borrowed stream. |
| `Encoding` | Physical buffer index and the consumer's ordered cast chain (`Decode`). The reducer applies this chain after loading. |

Exact integer `sext`/`zext` chains can store a computed narrow value and replay
the extensions after loading it in a reducer. Mixed chains retain every step:
`sext i8 to i16` followed by `zext i16 to i32` is not replaced by `sext i8 to i32`.
Existing `fpext` input-stream reuse is preserved. This is not general value-range
compression: arbitrary FP computations are not narrowed, and an accumulator's
demanded bits do not justify truncating its contribution. Scalar `i1` scratch
continues to occupy an `i8` element, with decoding back to `i1` before any further
extensions.

For example:

```llvm
%v = xor i8 %input, -128
store i8 %v, ptr %out.element, align 1
%wide = zext i8 %v to i32
%next = add i32 %sum, %wide
```

When `%out.element` is a legal contiguous stream, the reducer loads `i8` from
that output and then zero-extends to `i32`; this contribution needs no owned
scratch. Without a reusable output, Map stores `%v` in an owned `i8` buffer.
At 512 iterations its payload is **512 bytes**, rather than an `i32` buffer's
**2,048 bytes**. Computation of `%v` remains in Map.

A `sext(v)` reducer and a `zext(v)` reducer can share the same physical byte
buffer while retaining their separate decoding and reduction loops. Identical
SSA inputs and equivalent normalized contributions also retain their existing
sharing opportunities. Physical sharing requires the same stored value and
iteration coverage; equal types do not establish equivalence. Normalized
contribution sharing additionally checks operations, terms, flags, and guards.
Different guarded values or identities do not become the same stored value.

Already reusable logical streams take precedence over a new encoding. A store
of an intermediate value in an integer extension chain can also be reused.
Flattening control around an otherwise unchanged single contribution retains
its encoding. These rules keep normalization from introducing unnecessary
scratch for existing streams.

### Stream safety, alignment, and buffer lifetime

Borrowing retains the existing conservative legality conditions:

- Map is a single block and the load/store is simple, so its execution covers
  the required iterations. Conditional output borrowing is not broadened.
- The pointer is an affine recurrence for the original loop, with an invariant
  start and a positive stride equal to the physical element's allocation size.
- Traversal is non-wrapping. An unsigned no-wrap proof normally supplies this;
  suitable constant traversal within a known global object's bounds can recover
  the proof after GEP canonicalization loses `nuw`.
- The start pointer can be safely expanded at the loop preheader.
- The access alignment/address space supports the required predicated load,
  and decoding supports the consumers' maximum logical reduction VF. Storage
  selection does not lower reducer widths to make an encoding work.
- Whole-object alias/mod-ref queries exclude every other Map instruction that
  might overwrite the stream. This covers later-iteration overwrites as well
  as writes later in the same iteration. For an output, only its defining store
  is exempted from that check.

Failure to prove reuse leaves owned scratch available, subject to the existing
allocation and component-planning checks. A conditional store of the narrow
value is insufficient when the reducer needs a value on every iteration.

Budgeting, checked byte arithmetic, allocation, GEPs, Map stores, and reducer
loads use the **physical storage type**. Each active owned buffer is charged
once, including alignment, even when multiple consumers decode it differently.
Owned stack buffers use the preferred allocation alignment, but access alignment
accounts for the element stride: a 16-byte-aligned byte buffer does not make
every byte access 16-byte-aligned. Borrowed accesses use their proven stream
alignment. The `storage-encoding` test exercises this distinction with a custom
data layout and a 512-byte stack budget.

All distinct owned buffers remain live through Map and until every consumer has
finished. Sequential reducers do not make their buffer lifetimes disjoint:
**all contents must survive completion of Map**. No overlapping scratch arena,
heap hoisting, new heap policy, tiling, reducer fusion, profitability model, or
new VF search is introduced by the storage encoding change.

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
accumulator-dependent instruction slices. Storage/decoding plans and typed
placeholders for normalized contributions are recorded without creating IR,
allocations, stores, metadata, or loops. A candidate listing is preliminary:
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

The earlier flags-guide validation recorded the following ranges for f32
single- and two-accumulator examples
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
These earlier range checks are compile/lowering evidence, not runtime or
performance measurements. They were not repeated as part of the storage
encoding validation in section 9.

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
| `-ffp-contract=off/fast` | Affects frontend contraction opportunities. An optional `llvm.fmuladd` may normalize to a Map product plus a reducer addition; a mandatory `llvm.fma` is not split. |
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
reductions receive independent loop IDs for scratch or proven stable streams.

## 5. Reproducible examples

Use the modified tools from this worktree's build. A matching base version
string alone does not prove that an executable contains uncommitted changes.
The local validated build is `build-fission` relative to this
worktree. Adjust `RF_BIN` if using another build directory.

### Direct Clang pipeline

Run from the project root. The example has two independent accumulators and
requires no target system headers or linker. `-ffast-math` is intentional for
this example; use only FP permissions appropriate to the real input program.

```sh
RF_BIN="$(cd build-fission/bin && pwd)"
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
  -O2 -ffast-math -ffp-contract=off \
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

The earlier flags-guide validation compiled and machine-verified both direct
configurations. Section 9 identifies the tools and checks rebuilt/run for the
storage encoding change; it does not claim a fresh Clang frontend campaign. For a Normal comparison, replace `fission:4` with `4`, or `fission:16`
with `16`, keeping the other settings the same. Use separate output names.

### Inspect the immediate transformation with opt

The following uses the same `RF_BIN`, `RF_OUT`, and example source. Preparing
scalar IR first avoids comparing against an already-vectorized input.

```sh
"$RF_BIN/clang" --target=riscv64 -march=rv64gcv -mabi=lp64d \
  -O1 -Xclang -disable-llvm-passes -ffast-math -ffp-contract=off \
  -fno-discard-value-names \
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
| `ReductionFissionContribution` | Original accumulator/initializer, normalization or fallback reason, and logical-input scratch/borrowed/shared-contribution choices. Physical buffer counts must also be inspected in IR. |
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

Successful RVV output should have independent Map work when Map is nonempty,
owned or borrowed contribution streams, separate recurrence loops, vector
accumulator updates, and horizontal collapse outside each recurrence's backedge.
Examine actual SEW/LMUL and memory EEW:
`e8,m2` followed by `vle32.v` has EMUL8, just as `e8,m1` with `vle64.v` does.
Look at register use and control flow, not only mnemonic presence.

Generated reducer VPlans retain runtime EVL and loop boundaries even for short
trips, so each accumulator collapses before the next reducer. Normal and Map
retain their ordinary single-iteration folding; later optimization can also
replace a copy Map with `memcpy`. Inspect both immediate and final IR. Wider
groups can still increase register pressure. InstCombine avoids sinking a
vector's final scalar-producing use across a dominating call or a subsequent
natural loop, including backedge uses that precede the exit reduction. Other
register-pressure costs remain possible. No speedup is promised.

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
- `llvm.fmuladd` can contribute a separately rounded Map product;
  genuine `llvm.fma` recurrences are currently not recognized by the existing
  descriptor and are not decomposed. RVV scalable product reductions and some
  min/max variants remain unsupported by existing target legality.
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

Run the focused regression tests from the project root:

```sh
"$RF_BIN/llvm-lit" -j 2 -v \
  llvm/test/Transforms/LoopVectorize/reduction-fission-*.ll \
  llvm/test/Transforms/LoopVectorize/RISCV/reduction-fission-*.ll \
  llvm/test/Transforms/InstCombine/sink-vector-call.ll
```

The `force-option` test covers parser compatibility; `generated-hints` covers
global VF/IC/scalable isolation. The RISCV tests cover candidates, kinds,
control flow, FP semantics, memory recurrences, allocation limits, aggregate
stack use, lifetimes, allocation address spaces, stream reuse, and rollback.
The [storage encoding regression](llvm/test/Transforms/LoopVectorize/RISCV/reduction-fission-storage-encoding.ll)
adds narrow output reuse, owned byte scratch, sharing with different decoding,
mixed extension chains, alias/coverage negatives, distinct live buffers,
normalization preservation, and physical-byte/alignment budgeting.
Machine-verified cleanup and pressure tests cover independent reductions.
The InstCombine test covers vector-to-scalar sinking around calls and loops,
including accumulator backedges, later vector uses, and shared constants.

Keep compile/lowering checks, runtime checks, and performance measurements
distinct when reporting results. Preserve tool identities, exact flags, target
features, source provenance, remarks, and both immediate/final artifacts when
extending the experiments.

## 9. Storage encoding validation

The storage encoding implementation in `7b5de8dce79b` was built and checked on
this LLVM 23.1.3 worktree. `opt`, `llc`, and `FileCheck` were rebuilt from source.
The following results belong to this change, rather than to the historical
campaign in section 10:

| Check | Result and scope |
|---|---|
| Focused Reduction Fission lit suite | **26/26 passed**, including the new storage encoding file and existing control, FP, widening, normalization/sharing, stack, rollback, and transaction tests. |
| CFG audit self-tests | Passed, including constant-exit, unreachable-loop, and late-collapse negative fixtures. |
| RISC-V machine verification | The new test module's transformed IR lowered with XiangShan Kunminghu, RVV, and `llc -verify-machineinstrs`. |
| Native executable semantic check | An AArch64/macOS harness compared the transformed functions with scalar expectations over **64 datasets**, including negative byte values, mixed extensions, distinct/shared storage, conditional outputs, and overlapping outputs that overwrite preceding iterations. |
| RVV runtime / benchmark measurement | Not rerun for this change. Native checks and RISC-V lowering do not constitute RVV execution or a measured speedup. |

The executable harness was a temporary local check, not a committed lit fixture.
The self-contained IR regression is retained in the repository. It runs with the
default stack budget, with a 512-byte budget that fits one shared byte buffer,
and with a custom preferred byte alignment to check allocation versus access
alignment. Its assertions inspect storage, loads, conversions, and separate
reducers; they do not assert performance.

Reproduce the focused tests and representative machine verification from the
repository root:

```sh
cmake --build build-fission --target opt llc FileCheck -j 8
RF_BIN="$(cd build-fission/bin && pwd)"
RF_OUT="$(mktemp -d "${TMPDIR:-/tmp}/reduction-fission-storage.XXXXXX")"

"$RF_BIN/llvm-lit" -v \
  llvm/test/Transforms/LoopVectorize/RISCV/reduction-fission-*.ll \
  llvm/test/Transforms/LoopVectorize/reduction-fission-*.ll
python3 llvm/utils/reduction-fission/audit.py --self-test "$RF_BIN/opt"

"$RF_BIN/opt" -passes='loop-simplify,lcssa,loop-vectorize,verify' \
  -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v,+f,+d \
  -riscv-v-vector-bits-min=128 -scalable-vectorization=on \
  -force-vector-width=fission:16 -force-vector-interleave=1 \
  -verify-dom-info -verify-loop-info -verify-scev \
  -S llvm/test/Transforms/LoopVectorize/RISCV/reduction-fission-storage-encoding.ll \
  -o "$RF_OUT/storage.ll"
"$RF_BIN/llc" -mcpu=xiangshan-kunminghu -mattr=+v,+f,+d \
  -verify-machineinstrs "$RF_OUT/storage.ll" -o "$RF_OUT/storage.s"
```

### Motivation and measurement limits

The reported signed PackA observation was 652 cycles normally versus 1,897 with
Fission, with vector load/store split-event counters rising from 32/33 to
160/161. Its Fission code materialized a 2 KiB `i32` stream alongside byte output.
These are prior observations motivating the storage change; the split counters
are **whole-program split events, not memory-byte counts**.

The new 512-iteration synthetic regression proves byte output reuse or a
512-byte owned payload, according to legality. The PackA benchmark itself has
not been rerun for this change, so neither new PackA buffer totals nor cycle
improvements are inferred from that regression. Historical PackA rows below
remain labeled historical.

## 10. Historical campaign and numerical evidence

The remainder preserves the merged report's pre-rebase experiment results.
**These results predate the LLVM 23.1.3 rebase and the storage encoding change;
the complete source campaign and QEMU numerical campaign have not been rerun.**
Counts, table entries, compiler comparisons, and validation totals in this
section refer to those recorded builds. Artifact links point into the local
experiment directory and require those artifacts to be present.

### Source campaign and controls

All **345 C source contexts** were regenerated with the recorded compiler profile
and target headers. Discovery and the union of old/new requests produced **1,463
variants**. No published generated directory, manifest or measurement database was
changed.

| Classification | Count |
|---|---:|
| Committed and audited Fission | 325 variants / 72 contexts |
| Fission requests rejected with transaction rollback | 4 |
| Normal vectorized at requested VF | 1,130 |
| Normal compiled but not vectorized (unchanged baseline) | 4 |

Ten new Fission variants are the five requested VFs each for `tsvc-s3111-l00`
and `tsvc-s352-l00`; reduced storage makes them eligible. The four Fission and
four Normal non-successes are `npb-ft-checksum` at VF1/2/4/8. Fission's Map does
not vectorize at the selected width and the transaction is rolled back. They are
not presented as successful transformations or measurements.

An isolated compiler built from the baseline Vectorizer sources produced
**byte-identical final IR for all 1,134 Normal variants**. The explicit Normal
short-loop folding control also passes.

The complete variant table, statuses and artifact directories are in
[summary.csv](build-fission/experiments/reduction-fission-goal/full-source-final/summary.csv).
Each variant directory records the C input identity, commands, before/after/final
IR, YAML/JSON remarks, verified MIR, raw and XiangShan-patched assembly, and object.
Headers, compiler binaries and external target helpers have recorded hashes.

This is C **kernel frontend regeneration**, not just archived-IR replay. It is
not a new bare-metal benchmark harness/image or RTL measurement campaign.

### Representative comparison

All historical rows request Map VF2. “Empty” means there is no remaining Map work after
stream/invariant reuse. Every listed reducer uses **LMUL8 and IC1**. Payload is
owned contribution storage, not total machine frame size. Before-loop counts
came from the campaign LLVM LoopInfo applied to hash-verified published baseline IR.

| Case | Historical transformed Map form | Final reducer loops, before → after | Reducer VFs | Buffers | Payload bytes | Raw vector spill/reloads |
|---|---|---:|---|---:|---:|---:|
| mlas-sgemm-8acc | loop | 0 → 8 | 16,16,16,16,16,16,16,16 | 16 → 8 | 1984 → 992 | 54 → 0 |
| mlas-sgemm-4acc | loop | 0 → 4 | 16,16,16,16 | 8 → 4 | 992 → 496 | 18 → 0 |
| mlas-q4-minmax | loop | 0 → 2 | 16,16 | 1 → 1 | 128 → 128 | 0 → 0 |
| lcals-fir | loop | 0 → 1 | 8 | 1 → 1 | 128 → 128 | 0 → 0 |
| mlas-linear-query | loop | 0 → 1 | 16 | 1 → 1 | 128 → 128 | 0 → 0 |
| mlas-linear-retrieval | loop | 0 → 1 | 16 | 1 → 1 | 128 → 128 | 0 → 0 |
| npb-ep-bin-sum | empty | 0 → 1 | 8 | 1 → 0 | 80 → 0 | 0 → 0 |
| tsvc-s311-l00 | empty | 1 → 1 | 16 | 1 → 0 | 16384 → 0 | 0 → 0 |
| tsvc-s316-l00 | empty | 1 → 1 | 16 | 1 → 0 | 16384 → 0 | 0 → 0 |
| tsvc-s319-l00 | loop | 1 → 1 | 16 | 0 → 0 | 0 → 0 | 0 → 0 |
| rajaperf-reduce-struct | empty | 6 → 6 | 8,8,8,8,8,8 | 2 → 0 | 16384 → 0 | 0 → 0 |
| rodinia-srad-row | loop | 2 → 2 | 16,16 | 2 → 1 | 8192 → 4096 | 0 → 0 |
| mlas-rmsnorm-copy-sumsq | loop | 1 → 1 | 16 | 1 → 1 | 16384 → 16384 | 0 → 0 |
| mlas-globalavg-signed | empty | 1 → 1 | 16 | 1 → 0 | 784 → 0 | 0 → 0 |
| mlas-globalavg-unsigned | empty | 1 → 1 | 16 | 1 → 0 | 784 → 0 | 0 → 0 |
| mlas-qgemm-dot4 | loop | 1 → 1 | 16 | 4 → 1 | 2048 → 512 | 4 → 0 |
| mlas-qgemm-packa-signed | loop | 1 → 1 | 16 | 1 → 1 | 2048 → 2048 | 0 → 0 |
| mlas-qgemm-packa-unsigned | loop | 1 → 1 | 16 | 1 → 0 | 2048 → 0 | 0 → 0 |
| mlas-qgemm-packb-signed | loop | 1 → 1 | 16 | 1 → 1 | 2048 → 2048 | 0 → 0 |
| mlas-qgemm-packb-unsigned | loop | 1 → 1 | 16 | 1 → 1 | 2048 → 2048 | 0 → 0 |

The campaign's source-regenerated SGEMM8 controls separate the two changes:

| Compiler | Final reducer loops | Buffers / payload | Folded vector spill/reloads | Raw assembly instruction statements |
|---|---:|---:|---:|---:|
| Baseline | 0 | 16 / 1,984 B | 54 | 515 |
| Loop preservation only | 8 | 16 / 1,984 B | 0 | 304 |
| Integrated normalization | 8 | 8 / 992 B | 0 | 235 |

Map VF16 still creates pressure: across the campaign 26 vector spill/reload
statements are in Map loops, and 70 are in entry/setup for folded Maps (SGEMM4,
SGEMM8 and NPB CG). None is in a reducer or collapse block. Scalar register saves
and spills are counted separately in the complete table. The target extraction
workaround is applied separately and its sites/instruction overhead are recorded.
No static instruction count is converted into a runtime speedup claim.

### Final IR and machine audit

All 325 committed variants pass the LLVM-side audit:

- Original PHI names/indexes map bijectively to generated contribution plans.
- Requested Map VF and IC1 are confirmed, or an explicit empty Map is recorded.
- LLVM LoopInfo identifies each final data accumulator loop. Constant branch
  edges are pruned; unreachable or noncyclic loops do not count.
- SSA tracing identifies the horizontal collapse for each vector accumulator.
  It is outside its loop and precedes the next reducer on the vector path.
- All 420 generated data reducers have one vector accumulator: VF16 for f32/i32
  and VF8 for f64/i64, each LMUL8. Actual maximum-supported plan schedules match.
- Machine headers/backedges and hardware collapse positions agree with final IR.
  Pre-RA vector definitions do not cross into another data reducer; no reduction
  contribution vector load is hoisted ahead of its reducer. All 325 also pass a
  separately recorded machine-verifier stop after register allocation.
- All 327 owned static buffers are full-trip sized. Each has one lifetime start
  and end; CFG dominance/postdominance places every consumer within its lifetime.

For the five new `s3111` variants, codegen makes the final horizontal instruction
conditional on the initializer not being NaN. The vector loop remains, and the
NaN path returns the original scalar bits instead of consuming an unused vector
result. This is recorded separately, not misreported as an unconditional hardware
collapse. That context has one reducer, and no vector accumulator crosses into a
subsequent component.

The audit has negative tests for constant exits, unreachable loops and collapses
moved after the next reducer. The sibling suite's old SCC verifier remains
unmodified: it includes infeasible constant edges and does not recheck final-loop
structure. Its successful status was not used as this implementation's proof.

### Numerical validation and commands

The packaged [validation tools](llvm/utils/reduction-fission/README.md) document
reproduction. The recorded build and regression logs accompany that historical experiment.
The source and IR profiles use XiangShan Kunminghu, RVV, minimum VLEN128,
requested Map VF, IC1, SLP/unrolling disabled as recorded, and unchanged backend
policy. Both llc stages use `-verify-machineinstrs`:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools /opt/homebrew/bin/ninja -C build-fission -j 6 opt clang llc
python3 build-fission/bin/llvm-lit -sv llvm/test/Transforms/LoopVectorize/RISCV llvm/test/Transforms/LoopVectorize/reduction-fission-*.ll
llc <recorded target flags> -verify-machineinstrs -stop-before=riscv-vl-optimizer final.ll -o before-vl.mir
llc <recorded target flags> -verify-machineinstrs -start-after=riscv-vl-optimizer before-vl.mir -o xiangshan.raw.s
```

**116/116 regression tests passed** (the full RISCV LoopVectorize directory plus
the upper-directory Fission tests). The CFG audit negative fixtures also pass.

The actual Clang pass traces confirm InstCombine, SimplifyCFG, VectorCombine,
LoopUnroll, SROA, LICM and later LoopSink/InstSimplify/DivRemPairs/TailCallElim/
SimplifyCFG cleanup after LV. Validation uses their final output, not just an LV
commit remark.

QEMU RVV 8.2.2 executes scalar reference and transformed fixture objects at
**VLEN128/256/512**, ELEN64, v1.0. **51,231 scalar-reference/transformed comparisons passed** across the three
VLEN settings (17,077 each). Guarded allocation/free counts are recorded
per run, including the explicitly guarded harness inputs; all balance with peak
seven live allocations and no canary/page/bounds failure. Those checks included 1/2/4/8 accumulators,
shared/different streams, i32 and signed/unsigned i8 widening, f32/f64, N=0/1,
VLMAX boundaries and multiple iterations up to N=513. Input seeds and exact
commands are recorded. Exact dyadic inputs avoid imposing a particular legal
reassociation rounding order. Special checks cover noncanonical quiet/signaling
NaN bits, infinities, signed zeros, subnormals in IEEE mode, skipped invalid
addresses/divisions, integer overflow after reassociation, nested loops and
live-outs. Protected-page inputs and wrapped allocation canaries check bounds,
lifetime leaks and duplicate frees.

A real all-skipped NaN payload failure was found and fixed (0x7fc12345 had become
0x7fc00000); the counterexample log and bit-exact regression are retained. Strict
and non-IEEE conditional cases are explicit rejection tests. This is emulator
ISA correctness evidence; **XiangShan RTL/hardware cycles were not remeasured**.
The existing result DB's measurement/image identity is not reused.

### Historical completion evidence matrix

| Goal requirement | Historical evidence |
|---|---|
| Full-trip Map then reducers | Before/after/final CFG, effect-free Map proof, source campaign |
| One independent reducer per accumulator | PHI-plan mapping; 325 CFG/MIR/assembly audits; 420 m8 reducers |
| Minimum scalar contribution / reuse | Normalized IR, per-component remarks, complete storage table, stream/identity tests |
| Preserve short-loop boundary at largest VF, IC1 | Full O2 + llc regressions, source SGEMM controls, maximum plan schedules |
| FP/integer/control/initial semantics | Flag checks, strict rejection, bit-exact special values, executable comparisons |
| Allocation size, stack/heap, lifetime, rollback | Existing/new LLVM tests, lifetime CFG audit, guarded allocations and zero-trip execution |
| Full campaign, expanded scope, failures visible | 345 discovery contexts; 1,463 requests; full status table |
| Normal unchanged | 1,134 byte-identical baseline/current final IR outputs |
| Exact pipeline/backend provenance | Per-variant command.json, binary/header/helper hashes, both machine verifier stages |
| Raw vs patched assembly / no fabricated cycles | Separate assemblies and workaround records; no RTL speedup claim |
| Sibling verifier caveat | Explicitly documented; independent LLVM-side auditor with negative tests |

The historical implementation, tests, tools, and experiment report were
recorded on the `reduction-fission` branch. Section 9 describes the narrower
validation completed for the subsequent storage encoding change.
