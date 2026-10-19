# Audit of the ten selected scalar-fission targets

The generated splits passed the additional semantic checks, but they are **not
free of redundant overhead**. In particular, the transfer-boundary optimization
is incomplete: simple indices and reconstructible suffixes reach scratch. The
earlier validation report establishes test and corpus results, not an optimal
boundary or absence of unnecessary traffic.

This audit examines the same final compiler binaries and the ten Late-selected
targets, under both FP policies. No compiler changes were made. Detailed values,
source/binary hashes, scratch definitions and execution results are preserved in
[ScalarFissionTargetAudit.json](ScalarFissionTargetAudit.json).

## Semantic checks

For every target, the audit captured `bench_kernel` immediately before and after
`ScalarFissionPass`, inspected the final O3 IR and original RVV assembly, and
checked the source loop's state updates and producer effects. The recaptured
final kernel instruction text matches the previously validated kernel after
excluding metadata attachment/attribute-group IDs introduced by filtered IR
printing. Both FP-policy artifacts were checked.

The producer keeps its original computation and continuation; consumers carry
the original seeds and ordered updates across chunks. DUCC's mutated arrays
remain producer-side; SHTools' Legendre recurrence remains producer-side. The
Vina consumer repeats the original conditions and reads scratch only on the
corresponding paths. No raw input-load scratch stream was found in these ten
kernels. All streams are arithmetic results, although six PySCF results are
unnecessarily stored address indices. Changing the FP policy changes only
consumer `fadd` instructions by adding `reassoc`; there are no other instruction
changes in the immediate post-pass comparisons.

Native recompilation and execution of all ten unchanged sources compared
ordinary O3 against fission with capacities 1, 3 and the default, under both FP
policies: **62,556 output values compared, zero mismatches**. All 60 fission
configurations emitted a `Selected` remark at the exact target function and
source line. Capacity-one splits can subsequently collapse during cleanup;
selection was verified from remarks rather than surviving block names.

Seeds were 0, 1, 2, 3, 17, 31, 255, 1024, 4294967295 and
18446744073709551615. Vina's unmodified baseline rejects the last seed, so that
input was excluded for Vina in every mode. Ordered results matched exactly,
including zero sign. Reassociated results used
`abs(actual-reference) <= 1e-10 * max(1, abs(reference))`; the largest observed
scaled difference was approximately `1.02e-14`. DUCC output includes its updated
arrays, not just its reductions. This is differential testing against the
original implementation, not an independent numerical oracle for the workloads.

These executions use native target recompilation, not the RVV machine code.
They strengthen the correctness evidence but do not prove equivalence for every
input or establish RVV runtime performance.

## Findings

### 1. Six PySCF array indices unnecessarily travel through scratch

In `t000159-vv10-hessian-ft-six-trial-grid`, six of the ten streams are:

```llvm
%98  = add nsw i64 %35, %indvars.iv
%100 = add nsw i64 %37, %indvars.iv
%102 = add nsw i64 %39, %indvars.iv
%104 = add nsw i64 %41, %indvars.iv
%106 = add nsw i64 %43, %indvars.iv
%108 = add nsw i64 %45, %indvars.iv
```

The offsets are loop-invariant. These values feed the two trial-array addresses
for each of six trials. They can be reconstructed from the consumer induction
and offsets; they do not require snapshots or new alias assumptions. The six
`i64` arrays and their stores/loads survive O3.

Removing these streams would reduce scratch stores from 80 to 32 bytes and
scratch reads from 80 to 32 bytes per iteration: **96 fewer transferred bytes
per iteration, a 60% reduction in scratch traffic**. At the existing capacity
819, this removes 39,312 bytes of stack allocation. These are static access
widths, not measured cache traffic.

The cause is the local `Shared && Computed` decision in
[ScalarFission.cpp](../lib/Transforms/Scalar/ScalarFission.cpp): a multi-use
integer add qualifies as a scratch boundary before the pass considers cheap
consumer reconstruction. Excluding casts and GEPs is insufficient because the
index arithmetic is a separate instruction. This falls short of PLAN.md's
intended address-reconstruction policy.

### 2. Several streams duplicate private suffixes of values already transferred

These are concrete opportunities that survive O3:

| Target | Unnecessary stream | Available consumer operands | Scratch traffic removable per iteration |
| --- | --- | --- | ---: |
| SHTools gradient | `%mul175 = fmul %mul14, %conv88` | `%mul14` stream and invariant `%conv88` | 16 B |
| SHTools gradient | `%mul297 = fmul %mul219, %conv88` | `%mul219` stream and invariant `%conv88` | 16 B |
| SHTools gradient | `%mul327 = fmul %add322, %conv31` | `%add322` stream and the already reconstructed symmetry factor | 16 B |
| SHTools gravity/potential | `%mul88 = fmul %mul46, %conv78` | `%mul46` stream and invariant `%conv78` | 16 B |
| PySCF UWABCE | `%mul78 = fmul %add57, %mul77` | Both operands already have streams | 16 B |

Each 16-byte saving is one eight-byte store plus one eight-byte load. The listed
multiplication can execute once in the consumer, with the same operands, order
and FP flags; its producer copy has no remaining purpose once that stream is
removed. No FP reassociation or inverse arithmetic is needed.

These give at least 20→17 streams for gradient, 8→7 for gravity/potential, and
5→4 for UWABCE. They are lower bounds on improvement, not claims of globally
minimal boundaries. The planner needs a final consumer-dependency partition and
dominated-boundary cleanup, rather than treating every multi-use computed value
as independently worth transferring.

### 3. Known short loops allocate the full generic capacity

Capacity selection only considers the configured maximum and byte budget. It
does not use an already proven trip-count bound:

| Kernel | Known target iterations | Allocated capacity | Scratch allocated | Sufficient at known bound |
| --- | ---: | ---: | ---: | ---: |
| DUCC scalar ring pair | 201 | 1024 | 65,536 B | 12,864 B |
| DUCC spin-2, each of two loops | 128 | 1024 | 65,536 B each | 8,192 B each |
| dlib numerical LM | 1000 | 1024 | 24,576 B | 24,000 B |
| Nek5000 face | 64 | 1024 | 49,152 B | 3,072 B |

These bounds appear directly in the pre-fission exits. Supporting unknown trip
counts does not require ignoring known ones. The final IR also retains the
capacity check and outer chunk control for these loops even though their trip
counts fit within one chunk. A proven single-chunk case can use a simpler
schedule. This is separate from the requirement to preserve the general bounded
chunk implementation for unknown counts.

### 4. Sequential DUCC spin-2 loops reserve independent scratch sets

The spin-2 `bench_kernel` has two sequential fissioned loops. The selected target
remark describes eight streams and 64 KiB, but the whole function contains
sixteen scratch arrays totaling **128 KiB**. The RVV assembly's maximum fixed
CFA offset is **131,312 bytes**, confirming that this allocation survives codegen.
Scratch allocations have no scoped lifetime markers, and their storage is not
shared across these non-overlapping schedules. Reusing storage would reduce the
footprint; combining reuse with the proven 128-iteration bound would reduce it
further. The current byte budget is per split, not a whole-function stack cap.

## Per-target assessment

Every row passed the semantic checks above. “No redundant payload identified”
means no concrete removable stream was established by this inspection, not that
the target has zero overhead.

| Target | Streams in target split | Scratch B/iteration, store + read | Ordered producer/consumer VF | Assessment |
| --- | ---: | ---: | --- | --- |
| Vina non-cache derivative | 6 | up to 96 | scalar / scalar | Conditional computed streams are valid; repeats two stable 64-bit control loads and predicates. Alternative predicate/boundary cuts involve a tradeoff |
| DUCC scalar ring pair | 8 | 128 | scalar / scalable 2 | Producer mutations preserved; no redundant payload identified under the available alias proof. Capacity/control overprovisioned |
| DUCC spin-2 ring pair | 8 per loop | 128 per loop | scalar / scalar | Same semantic rationale; two scratch sets and excessive capacity |
| dlib numerical LM | 3 | 48 | scalar / scalable 2 | Three computed derivatives shared by gradient/Hessian consumers; residual read belongs in consumer. Small capacity overprovisioning |
| Nek5000 face | 6 | 96 | scalar / scalable 2 | Six force components shared with torque suffixes; coordinate reads belong in consumer. Severe capacity overprovisioning |
| Nek5000 row | 6 | 96 | scalar / scalable 2 | Same valid six-component boundary; general chunk overhead, no redundant payload established |
| SHTools gradient | 20 | 320 | scalar / scalar | At least three unnecessary suffix streams; symmetry-byte read occurs in both stages |
| SHTools gravity/potential | 8 | 128 | scalar / scalar | At least one unnecessary suffix stream; symmetry-byte read occurs in both stages |
| PySCF six-trial grid | 10 | 160 | scalar / scalable 2 | Six unnecessary index streams; the four computed FP intermediates are useful shared boundaries |
| PySCF UWABCE | 5 | 80 | scalar / scalable 2 | At least one unnecessary suffix stream |

The `AdditionalLoadInstructionBytesUpperBound` remark is conservative: it counts
consumer input reads even if cleanup removes the corresponding producer load.
For example, dlib's residual and Nek5000's coordinate reads should not all be
called duplicated reads merely from that remark. Vina's control loads and
SHTools' symmetry bytes really are needed by both current stage bodies. Avoiding
those may require a different computed predicate or boundary and a cost tradeoff;
copying raw input loads through scratch remains forbidden.

No producer vectorizes automatically in these ten selected target loops. Six
ordered consumers use scalable VF 2; Vina, DUCC spin-2 and both SHTools targets
remain scalar/scalar. With reassociation enabled, dlib, both Nek5000 targets and
the six-trial PySCF consumer choose scalable VF 1; scalable 1 still represents
vector execution. Scalar/scalar is allowed by the design, but neither selection
nor codegen demonstrates a speedup. All splits incur some scratch and scheduling
cost; runtime benchmarking is still required after removing the avoidable costs.

## Artifacts and next changes

`build-fission/scalar-fission-audit/` contains per-target before/after/final IR,
exact capture commands, native IR/object/executable/remarks/output files, and
`check-native.py` plus `native-results.json`. The checker compares complete
printed output arrays and can be rerun from the repository root. The versioned
JSON preserves its hash, compiler hashes, source hashes and summarized results.

Priority fixes are: reconstruct cheap address indices; prune suffix streams
using the final stage dependency graph; cap scratch with proven iteration bounds
and simplify single-chunk schedules; then scope/reuse sequential scratch
allocations. Those changes should get focused IR regressions and rerun this
ten-target differential audit. The audit itself does not modify the compiler.
