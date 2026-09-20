# Reduction fission implementation and validation

Implementation is confined to the Vectorizer (plus tests, documentation and
validation tools). The three requested policies now operate together: full-trip
Map, one independent reducer per original accumulator, and normalized scalar
contributions with storage reuse. Reducers retain their maximum supported legal
VF and IC1. No grouping, tiling, smaller-VF pressure workaround, scheduling
barrier, new intrinsic definition, or generic CFG/backend exception was added.

## Implementation

- Associative integer/FP chains and min/max intrinsic chains produce one logical
  contribution per iteration. Optional `fmuladd` products are computed in Map;
  mandatory `fma` and ordered/strict cases retain rejection semantics.
- Conditional contributions stay on original execution paths and use the correct
  identity. Scalar exit selections preserve skipped NaN bits, flagged infinities
  and zero signs. Freezing the initializer prevents new undef correlations.
- Integer wrap flags are not copied to reassociated intermediates. FP rewrite
  permissions are intersected; new sums/products drop unproven nnan/ninf, and
  skipped identities do not gain nsz. Min/max retains justified permissions and
  uses finite extrema when ninf excludes infinite identities.
- Identical normalized expressions share storage without sharing reducer loops.
  Stable streams and invariants avoid owned scratch. Exact extensions can reuse
  narrow storage. Known global bounds recover safe traversal proofs when GEP
  canonicalization loses nuw. Unsupported predicated-load alignment keeps scratch.
- An effect-free Map without live-outs is explicitly absent, rather than a failed
  component silently ignored. Nonempty Map failure still rolls back. Checked
  allocation arithmetic, aggregate stack budgets, lifetimes and heap cleanup remain.
- Generated reducer VPlans retain runtime EVL and loop boundaries; Normal/Map
  single-iteration folding is unchanged.

## Source campaign and controls

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

## Representative comparison

All rows request Map VF2. “Empty” means there is no remaining Map work after
stream/invariant reuse. Every listed reducer uses **LMUL8 and IC1**. Payload is
owned contribution storage, not total machine frame size. Before-loop counts
come from current LLVM LoopInfo applied to hash-verified published baseline IR.

| Case | Current Map form | Final reducer loops, before → after | Reducer VFs | Buffers | Payload bytes | Raw vector spill/reloads |
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

Fresh source-regenerated SGEMM8 controls separate the two changes:

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

## Final IR and machine audit

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

## Numerical validation and commands

The packaged [validation tools](llvm/utils/reduction-fission/README.md) document
reproduction. The latest build and regression logs accompany the experiment.
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
seven live allocations and no canary/page/bounds failure. Current checks include 1/2/4/8 accumulators,
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

## Fallback and rejection policy

Every committed campaign reducer uses one logical contribution, except s319's
zero-scratch two-output-stream representation. Adding a combined stream there
would add storage. Existing identical inputs are shared across min/max reducers.
Single subtractive updates and single compare/select min/max idioms retain their
original slice because they already carry one contribution and preserve their
original arithmetic/comparison semantics. More complex joins, heterogeneous
updates and dependent casts retain explicit analysis reasons and the original
legal slice, or reject if no supported maximum-width plan exists.

Reassociation must be permitted; observed intermediate accumulators, cross-
accumulator dependencies, Map memory/control recurrences, unsupported mandatory
fused/ordered/strict operations, unsafe allocation/storage plans and unproven
conditional FP initial-value semantics are rejected. Non-IEEE conditional
identities and unrepresentable scratch-free counts are explicitly rejected.

## Completion evidence matrix

| Goal requirement | Current evidence |
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

The implementation, tests, tools and this report are included on the
`reduction-fission` branch.
