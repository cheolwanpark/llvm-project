# Scalar fission frontier change

This audit compares the contribution-slice selector with
`f100844c3471140791486a7bf35a2a6b0a10dd3b`. The historical overhead report and its
artifacts are preserved. Machine-readable results accompany this report in
[ScalarFissionFrontier.json](ScalarFissionFrontier.json).

## Analysis and cleanup

Contribution identity is `(closed state group, input Value*)`. The analysis
merges overlapping accepted update closures, discovers roots in original order,
and collects one complete backward dependency set per identity. Reconvergent
paths count once in a slice. Header recurrences and nested LCSSA results bound
traversal. All slices contribute to membership, including short inputs.

A structural frontier is a legal computed shared value with a private user of
membership one. The SHTools-shaped regression explicitly has membership four at
`mul87`, two at `mul89`/`mul136`, and one at their private users; only
`mul89`/`mul136` transfer. Direct shared roots and independent uncovered inputs
have computed-result fallbacks. Calls, freezes, scalar aggregate results and
nested LCSSA results impose separate mandatory boundaries.

Availability resolution checks all operands, including branches not covered by
a frontier. It then commits the consumer closure without rollback lists. The
original stable-memory and existing-buffer proofs still cover the full schedule.
Computed PHIs transfer at the merge point using the emitter's existing PHI
support. Distinct extracts from an aggregate require distinct scalar transfers.

The following old mechanisms were removed:

- Local `Shared` classification using `getNumUses()` and users outside `Moved`.
- The recursive `Input` selector and its tentative input/stream/IV rollback lists.
- The first-computed-input-only fallback when no scratch stream was found.

The computed-result/raw-relay check, address and IV reconstruction, call
contracts, memory proofs, capacity selection and emission are reused. The
consumer/producer fixed point remains necessary: it removes unused input work
and moves an FMul suffix only when its operands already have consumer definitions
and its producer demand disappears. It does not seek an earlier common cut or
add reads. `Inputs`, `Streams` and the final `Retained` closure describe the one
partition used for emission, depth and traffic diagnostics.

The depth gate runs after that cleanup. It measures the longest retained data
chain, with unit weight for genuine arithmetic and computational calls. Loads,
address/IV work, casts, control and forwarding add no depth. Data relevance is
traced from state results through their update graphs and from retained producer
data/effects, skipping select conditions and load addresses. Predicate inputs
still contribute to membership; their control-only arithmetic cannot manufacture
data depth. Neither can an address scratch stream. Recurrence PHIs stop backedges, including nested cycles. The
whole producer needs depth at least three; short contributions may coexist with
a qualifying stream or retained effect. No frontier adjustment manufactures a
qualifying depth.

## Evidence and provenance

Artifacts are separate under `build-fission/scalar-fission-frontier-final/`. Baseline
`opt`, `llc`, `clang`, build configuration and hashes were copied before the first
build. Their hashes and the original implementation hash match the committed
`ScalarFissionOverhead.json` report. Both compiler versions use the same saved
frontend bitcode from the pinned corpus, with source and manifest hashes checked
and each input's SHA-256 recorded. Reused frontend command/compiler provenance
is recorded by the corpus runner.

The scalar regression suite covers exact transfer values/counts, stage placement,
contribution/group identity, reconvergence, sharing levels, uncovered operands,
computed PHIs, aggregate results, freezes, depth zero/one/two rejection, depth
three acceptance, opaque calls, parallel work, cleanup-induced shallowness,
address/control exclusions, deterministic output and budget exhaustion without
partial emission. Existing positive storage, control, nested, FP and state
fixtures use genuine qualifying chains. Independent execution oracles were
updated with their arithmetic; the short-producer fixtures retain their original
arithmetic and explicit rejection checks. The current changed-legacy inventory
is `llvm/test/Transforms/ScalarFission/Inputs/frontier-migration.json`; the older
inventory remains a historical snapshot.

The host checker requires per-function selection and intended rejection reasons;
it cannot count an unchanged positive function as fission coverage. It runs
capacities 1, 3 and 64 under both FP policies, with zero/one trips, seeds, relevant
aliases/effects and FP edge cases. It also machine-verifies generated RVV code.
The intentionally unbounded control-only negative is checked structurally rather
than executed; its rejection and machine verification are recorded.

## Results

The combined ScalarFission/LoopVectorize run reports **1,359 passed, 101
unsupported, zero failures**; the unsupported count matches the baseline build.
All **66 Vectorize unit tests** pass. Subsequent exact-frontier and depth/IV-only
checks also pass. IR, dominator-tree, LoopInfo and ScalarEvolution verification
are enabled in the focused tests and captures.

The expanded host checker passes **34,002 comparisons** across both FP policies
and capacities 1, 3 and 64. Every positive function must split and every negative must report
its intended reason. RVV outputs pass machine verification.

Both compiler versions complete **585 configurations**, for **1,170 fresh
optimizer/codegen runs**, using identical frontend inputs for all 117 targets.
The baseline replay reproduces the historical seven Early and ten Late target
selections. The new selector chooses **six Early and nine Late targets** under
both FP policies. There are no newly selected manifest targets. The sole manifest
target selection loss is SHTools gradient, in all four fission configurations,
with `analysis-budget` and zero remaining budget. The budget remains 4,096.

The Late gradient candidate has 36 distinct contribution roots and 1,202 slice
memberships. Its recorded graph confirms membership four at `mul87`, two at
`mul89`/`mul136`, and one at `mul105`/`mul149`. Its initial 20-value frontier and
17-value post-cleanup transfer plan agree with the baseline's final 17 sources.
The budget expires during final depth analysis, after the partition is formed.
Depth is therefore **unmeasured**, not a measured depth-zero or shallow rejection.
The pass emits no split or scratch. These planned crossings are diagnostics,
not an emitted or forced partition.

Two surviving targets change transfers. Vina reconstructs shared `add6.i` in the
consumer, reducing six double streams to five. Its `sub.i.i` structural boundary
is superseded by the `add9.i.i` unavailable-dependency fallback, which checks all
operands. The two original control-read widths remain duplicated (16 B).
UWABCE's initial graph frontier is `add57`, `mul70`, and `mul78`; valid final FMul
cleanup reconstructs `mul78`, leaving two transfers. Shared `mul68` and `mul77`
have no private-user frontier edge and are reconstructed. Its baseline has four
streams. These are graph/cleanup changes, with no extra read widths introduced.
Other surviving targets retain their transfer sources.

The following table reports **Late ordered** results. Allocation is the function
IR sum; capacity and stream counts describe each split. Frames are the maximum
fixed CFA offsets in final RVV code, measured separately from IR allocation.

| Target | Streams, baseline → new | Producer depth | Capacity | IR scratch B, baseline → new | Fixed frame B, baseline → new |
| --- | --- | ---: | ---: | ---: | ---: |
| Vina | 6 → 5 | 8 | 1024 | 49,152 → 40,960 | 49,232 → 41,024 |
| dlib numerical LM | 3 → 3 | 7 | 1000 | 24,000 → 24,000 | 24,016 → 24,016 |
| DUCC scalar | 8 → 8 | 6 | 201 | 12,864 → 12,864 | 12,976 → 12,976 |
| DUCC spin-2 (both splits) | 8+8 → 8+8 | 6/6 | 128/128 | 16,384 → 16,384 | 8,416 → 8,416 |
| Nek5000 face | 6 → 6 | 5 | 64 | 3,072 → 3,072 | 3,184 → 3,184 |
| Nek5000 row | 6 → 6 | 5 | 1024 | 49,152 → 49,152 | 49,456 → 49,456 |
| PySCF six-trial | 4 → 4 | 16 | 1024 | 32,768 → 32,768 | 33,184 → 33,184 |
| PySCF UWABCE | 4 → 2 | 11 | 1024 | 32,768 → 16,384 | 32,896 → 16,496 |
| SHTools gradient | 17 → not split | unmeasured | — | 65,416 → 0 | 65,920 → 144 |
| SHTools gravity/potential | 7 → 7 | 8 | 1024 | 57,344 → 57,344 | 57,520 → 57,520 |

Both spin-2 splits retain depth six, capacity 128 and 8,192 B per split. Their
16,384 B function IR allocation colors to eight 1,024 B objects (8,192 B), with
an 8,416 B fixed frame. The rejected gradient row describes unsplit code and
cannot be interpreted as a fission memory or runtime improvement.

Automatic stage choices follow; `sN` denotes `vscale x N`, plain `1` is scalar,
and plain `4` is fixed width four. Every observed IC is one. Both spin-2 schedules
have the listed choices.

| Target | Ordered producer / consumer | Reordered producer / consumer |
| --- | --- | --- |
| Vina | 1 / 1 | 1 / 1 |
| dlib numerical LM | 1 / s2 | 1 / s1 |
| DUCC scalar | 1 / s2 | 1 / s2 |
| DUCC spin-2 (both splits) | 1 / 1 | 1 / 1 |
| Nek5000 face | 4 / s2 | 4 / s1 |
| Nek5000 row | 1 / s2 | 1 / s1 |
| PySCF six-trial | 1 / s2 | 1 / s1 |
| PySCF UWABCE | 1 / s2 | 1 / s2 |
| SHTools gradient | not split | not split |
| SHTools gravity/potential | 1 / 1 | 1 / 1 |

The nine surviving targets pass **60,396 native output comparisons**, zero
mismatches, at capacities 1, 3 and default under both FP policies. Complete
harness output arrays, including mutated DUCC arrays, are compared. Ordered
results are exact, including signed zero; reassociated results use
`1e-10 * max(1, abs(reference))`. The historical Vina baseline-invalid maximum
seed is excluded consistently. Both spin-2 schedules remain selected. There is
no missing native coverage for a surviving manifest target. The rejected gradient
is recorded as not split, with no fission execution claim.

The frozen-partition VF/IC matrix completes **1,080 configurations** across the
nine survivors and both policies, including both spin-2 schedules. All pass
machine verification. **246** realize every requested VF/IC; **834** are
unavailable because requests are not realized. Requested and actual values are
retained separately in JSON. The rejected gradient has no frozen partition or
forced matrix configurations.

The corpus also contains helper and non-manifest loops. Their selections are
reported separately: 286 location/configuration changes account for 374 fewer
non-target selection records (472 → 98). Of these, 282 location/configuration
changes directly report `producer-too-shallow`. Two Dipy Early changes are
indirect depth-policy effects: `_local_variance` rejects at depth two before
inlining/unrolling; the former `bench_prepare` loop at line 259 is no longer a
separate candidate, and its containing line-258 loop rejects at depth two.
Two OpenLB Early changes reject `no-computed-boundary`: the baseline crossed a
`zext` of the original `z` IV, which the new analysis reconstructs. Captured
before/after IR and every attribution are in the JSON/artifacts. These helper
records are not counted as manifest target selections or native target coverage.

## Compile observations

The full-corpus measurements below were collected concurrently with other
validation. Times sum optimizer wall time; memory is maximum optimizer RSS.
They are not isolated compile-time comparisons.

| Pipeline / FP policy | Baseline optimizer s | New optimizer s | Baseline max RSS B | New max RSS B |
| --- | ---: | ---: | ---: | ---: |
| baseline-fp0 | 387.38 | 209.63 | 56,180,736 | 56,279,040 |
| early-fp0 | 406.48 | 217.64 | 55,787,520 | 56,229,888 |
| early-fp1 | 372.06 | 212.80 | 56,688,640 | 56,344,576 |
| late-fp0 | 385.54 | 222.33 | 56,475,648 | 56,246,272 |
| late-fp1 | 395.15 | 211.06 | 56,213,504 | 56,360,960 |

After the corpus, native and matrix jobs finished, 40 serial paired Late
compiles covered the original ten-target set under both FP policies. The 20
baseline compiles total **49.18 s** (maximum RSS **53,903,360 B**); the 20 new
compiles total **49.57 s** (maximum RSS **53,592,064 B**). These are one sample per
target/version/policy, with exact commands and per-process resources saved
separately. They do not support a statistical compile-time speedup claim.

## Reproduction

Use the full commands and hashes in the JSON report. The core commands are:

```sh
ninja -C build-fission clang opt llc FileCheck VectorizeTests
build-fission/bin/llvm-lit -sv llvm/test/Transforms/ScalarFission \
  llvm/test/Transforms/LoopVectorize
build-fission/unittests/Transforms/Vectorize/VectorizeTests
python3 llvm/utils/check-scalar-fission.py --build-dir build-fission \
  --work-dir build-fission/scalar-fission-frontier-final/execution
```

`evaluate-scalar-fission.py --frontend-input-dir` runs the baseline and changed
compilers on identical verified frontend inputs. The new
`audit-scalar-fission-frontier.py` takes both completed result directories, captures
all previously/newly selected Late targets, and optionally runs native harnesses
and frozen-partition sweeps with `--native --sweep`. `--baseline-build-dir`
recaptures the old partitions from the same inputs with the preserved tools.
Historical immediate-IR captures have different frontend hashes, so fresh
baseline captures are used here. `--baseline-build-dir`
recaptures the old partitions from the same inputs with the preserved tools.
Historical immediate-IR captures have different frontend hashes, so fresh
baseline captures are used here. Capture reuse is explicit and
checks tool, input, option and artifact hashes. Rejected targets are recorded as
not split; the matrix never forces a rejected old partition.

RVV runtime and profitability are **unmeasured**: there is no RVV runner. Scratch
widths, vectorization, native correctness and machine verification are separate
observations and do not establish a speedup.
