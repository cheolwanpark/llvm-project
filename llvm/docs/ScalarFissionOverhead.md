# Scalar fission overhead implementation and validation

This follow-up implements the concrete reductions identified by the historical
[ten-target audit](ScalarFissionTargetAudit.md). The compiler changes are local to
`ScalarFission.cpp`: bounded original-operation index reconstruction, final
producer dependency analysis and private multiply pruning, proven trip-count
capacity limits and single-chunk emission, scoped scratch lifetimes, and final
read/allocation diagnostics. No target names, new compiler switches, profitability
heuristics, raw-load transfers, or new semantic assumptions were introduced.

[ScalarFissionOverhead.json](ScalarFissionOverhead.json) records before/after
values, source/compiler/runner hashes, exact target attribution, automatic stage
VF/IC, missed-vectorization remarks, and individual sweep results. Historical
audit files and artifacts are preserved. New artifacts are under
`build-fission/scalar-fission-overhead-final/`; earlier exploratory work is under
`build-fission/scalar-fission-overhead/` and is not the final validation evidence.

## Stream and traffic reductions

Both FP policies produce the following boundaries. Widths are static accesses,
not measured memory/cache traffic; conditional execution and nested multiplicity
still matter.

| Target | Streams before → after | Scratch store + read widths before → after | Reduction |
| --- | ---: | ---: | ---: |
| PySCF six-trial grid | 10 → 4 | 80 + 80 → 32 + 32 B | 96 B |
| SHTools gradient | 20 → 17 | 160 + 160 → 136 + 136 B | 48 B |
| SHTools gravity/potential | 8 → 7 | 64 + 64 → 56 + 56 B | 16 B |
| PySCF UWABCE | 5 → 4 | 40 + 40 → 32 + 32 B | 16 B |

The six shared integer indices in the grid are cloned from invariant offsets
and consumer IVs. No integer index scratch remains in immediate or final O3 IR.
The four computed FP payload streams remain. With capacity explicitly fixed at
819, allocation falls from 65,520 to **26,208 B**, saving **39,312 B**. At default
settings capacity grows from 819 to 1,024, so allocation is **32,768 B**, saving
**32,752 B**. These are separate comparisons.

The exact audited SHTools suffixes `%mul175`, `%mul297`, `%mul327`, and `%mul88`,
and UWABCE's `%mul78`, now occur only as consumer calculations. Their operands
and FP flags are preserved. The fixed-point cleanup accounts for remaining
stream stores, producer effects/control/recurrences/live-outs, dominating
consumer definitions, and existing-buffer addresses. It does not introduce new
input reads or duplicate producer calculations. Dead original users are included
in emission cleanup so they cannot retain a pruned suffix.

Removing the symmetry-dependent SHTools suffix also moves its one-byte input
read entirely into the consumer. Neither SHTools target now duplicates that read.
Dlib's residual load (8 B) and Nek5000's coordinate loads (24 B) are classified as
moved, not duplicated. Vina still duplicates 16 B of original control-load widths.

## Proven bounds, control and storage

ScalarEvolution's unconditional maximum-trip-count query proves all four planned
bounds on the actual pre-fission loops. Zero means unavailable; unknown counts
and byte-budget-limited capacities retain chunking. The single-chunk consumer
uses the actual completed count, not the maximum, and both stages keep their
original seeds and live-outs.

| Target | Proven maximum | Scratch per split before → after | Fixed RVV frame after |
| --- | ---: | ---: | ---: |
| DUCC scalar ring pair | 201 | 65,536 → 12,864 B | 12,976 B |
| DUCC spin-2, each loop | 128 | 65,536 → 8,192 B | 8,416 B for the function |
| dlib numerical LM | 1,000 | 24,576 → 24,000 B | 24,016 B |
| Nek5000 face | 64 | 49,152 → 3,072 B | 3,184 B |

The known-fitting schedules have no producer capacity select or chunk restart
backedge in immediate IR; final O3 does not reintroduce them. Setup blocks may
remain, but they are not chunk loops and carry no chunk-loop metadata.

DUCC spin-2 still has sixteen IR allocas totaling **16,384 B**. Inspection after
machine stack coloring shows **eight 1,024-byte objects**, proving a shared
**8,192 B scratch footprint**. Its fixed frame is **8,416 B**, including 224 B of
other storage, versus the audited **131,312 B**. Lifetime starts dominate the
whole schedule and ends occur after all consumers finish, including repeated
invocation inside an enclosing loop. No explicit scratch allocator was needed.
The new function-allocation remark reports the IR sum; it does not label that
sum as peak live memory or machine-frame size. The byte budget remains per split.

## Remaining reads and vectorization

A separate Vina experiment transfers the already-computed `%cmp54.not` predicate
as an `i1` stream at its original producer position. Its matching consumer branch
reads that stream on the corresponding path. SimplifyCFG removes the other empty
consumer branch, making both original 64-bit control reads unnecessary. This is
a computed comparison, not a raw-load relay. The experiment is an artifact-only
boundary comparison, not a new compiler selection rule.

After identical scalar cleanup, this alternative changes six double streams to
six double streams plus one byte stream: scratch store/read widths rise from
48/48 to 49/49 B, while original consumer read widths fall from 16 to zero.
Consumer GEPs decrease from nine to seven, integer comparisons from two to one,
and integer adds from two to one; FP computation is unchanged. Static combined
store/read width falls by 14 B, but conditional multiplicity differs. Under an
identical post-split O3/codegen pipeline, the fixed frame grows from 49,280 to
50,288 B. Both variants remain scalar/scalar and pass machine verification.
These experimental pipeline frame sizes are distinct from the production
pipeline's 49,232 B Vina frame. With no RVV timing evidence, this tradeoff does
not justify changing selection in this patch.

Automatic VF/IC is recorded for every target and both policies below. `sN` means
`vscale x N`, including `s1`; all observed ICs are 1. The corpus comparison retains
the baseline's `-force-vector-interleave=1` and `-hints-allow-reordering=false`.

| Target | Ordered producer / consumer | Reordered producer / consumer |
| --- | --- | --- |
| Vina | 1 / 1 | 1 / 1 |
| DUCC scalar | 1 / s2 | 1 / s2 |
| DUCC spin-2 (both loops) | 1 / 1 | 1 / 1 |
| dlib numerical LM | 1 / s2 | 1 / s1 |
| Nek5000 face | 4 / s2 | 4 / s1 |
| Nek5000 row | 1 / s2 | 1 / s1 |
| SHTools gradient | 1 / 1 | 1 / 1 |
| SHTools gravity/potential | 1 / 1 | 1 / 1 |
| PySCF six-trial grid | 1 / s2 | 1 / s1 |
| PySCF UWABCE | 1 / s2 | 1 / s2 |

Most remaining scalar producers receive uncountable-loop or inability-to-compute-
iteration-count remarks, even where a small maximum bound was available. A
maximum bound is not necessarily the exact count required by LV. Ordered scalar
consumers also report inability to reorder FP operations; SHTools reports
non-reduction live-outs, and reordered scalar-stage evidence is recorded
separately in JSON. Selection and codegen success are not profitability evidence.

## Validation

The final compiler was built with `clang`, `opt`, `llc`, `FileCheck`, and
`VectorizeTests`. ScalarFission and LoopVectorize regression directories report
**1,356 passed, 101 unsupported, zero failures**. The unsupported tests require
unbuilt target support. All **66 Vectorize unit tests** pass. Focused tests use
`-verify-each` and DT/LoopInfo/ScalarEvolution verification and cover wrapping
indices and conditional uses, unavailable operands and producer-side users,
repeated suffix pruning and dead users, existing buffers, exact/inexact bounds,
zero/one trips, capacity/budget limits, guarded entries and enclosing schedules.
Existing narrow/large-count and restricted-index tests also pass.

The expanded existing execution checker passes **29,334 host comparisons** at
capacities 1, 3 and 64 under both FP policies. These include aliases, producer
effects, state seeds/live-outs, floating-point edge cases, conditional wrapping
indices, bound-clamped counts, and sequential/enclosing lifetimes. Generated RVV
code is machine-verified.

The ten-target native differential audit passes **62,556 output comparisons,
zero mismatches**, at capacities 1, 3 and default under both policies. The copied
local native checker now requires an output directory and always recompiles; no
existing executable can satisfy a fresh run. Every fission configuration is
matched to the manifest's exact target function/source location, not a helper
remark. Source hashes, seeds and comparison tolerances match the historical
audit: ordered output is exact (including signed zero), reassociated output uses
`1e-10 * max(1, abs(reference))`, and Vina's baseline-invalid maximum seed is
excluded consistently. Complete output arrays, including mutated DUCC arrays,
are compared.

The pinned 117-target corpus completes **585 independent configurations**: one
baseline and Early/Late under both FP policies, all starting from the same
frontend IR per target. All verification and machine-codegen checks pass. Exact
target selection remains seven Early and ten Late under each policy.

| Configuration | Selected targets | Sum of optimizer wall time | Maximum optimizer RSS |
| --- | ---: | ---: | ---: |
| baseline-fp0 | 0 | 401.97 s | 56,131,584 B |
| early-fp0 | 7 | 440.86 s | 56,229,888 B |
| early-fp1 | 7 | 379.96 s | 56,279,040 B |
| late-fp0 | 10 | 370.28 s | 56,180,736 B |
| late-fp1 | 10 | 310.49 s | 56,360,960 B |

These process-resource observations were collected during concurrent validation;
they are not isolated compile-time performance measurements. Per-command
frontend, optimization and codegen times/resources are retained in the corpus
artifacts, separately from native execution evidence.

For VF/IC sweeps, each target function and its globals are extracted once from
the immediate post-split module, retaining the target's instruction text and
partition. The two sequential spin-2 schedules stay frozen together. Helper
function definitions are excluded so their stage results cannot be mistaken for
target results. Within each sweep, only loop metadata changes. Producer requests
are scalar, fixed 2, scalable 1 and scalable 2; consumer requests additionally
include fixed 4. Independent producer/consumer IC pairs are (1,1), (2,1), and
(1,2), for **1,200 configurations** across ten targets and both policies.

**264 configurations realize every requested stage VF/IC; 936 are unavailable**
because the request was not realized. All 1,200 complete codegen with machine
verification and no errors. Requested and actual settings, including scalar
fallbacks, are recorded separately; unavailable requests are not counted as
successful forced configurations.

The user confirmed there is no RVV runner. RVV runtime and profitability remain
**unmeasured**; native differential execution is not RVV execution. No speedup is
claimed.
