# Bounded scalar fission mitigations

Reference: `da9c6d542` and the unchanged
[frontier audit](ScalarFissionFrontier.md). Detailed observations, compiler and
input hashes, and artifact hashes are in
[ScalarFissionMitigation.json](ScalarFissionMitigation.json).

## Decisions

**Retain the emitted-exit correction.** Separate instruction/CFG and induction
cleanup experiments reproduce all five scalar producer failures under both FP
policies. `simplifycfg` alone and `indvars` alone restore none. `instcombine`
alone restores all ten: dlib chooses fixed VF 4; the other four choose scalable
VF 2. Adding induction cleanup changes dlib to scalable VF 2, without establishing
an advantage over fixed VF 4. The original broad cleanup pipeline is unnecessary.

The emitter now inverts integer comparisons directly, preserving their flags,
instead of wrapping them in XOR. It combines the original continuation with the
chunk-capacity comparison using `and`. The latter operand is nonpoison because
the new 64-bit ordinal starts at zero and is bounded by the checked capacity.
Consequently poison in the original continuation still reaches the branch,
including at capacity one. This exposes both exits to SCEV and LV without
assuming an exact count, expanding SCEVs, changing single-chunk termination, or
adding any cleanup pass. Other predicates retain the generic inversion and
original lazy control. Cloning the comparison also preserves poison flags when
an IR builder would otherwise fold constant operands.

All ten affected producers vectorize automatically. Both spin-2 producers also
choose fixed VF 4. Consumer choices and Nek5000 face's independent stages are
preserved. Scratch and transfer widths are unchanged by this experiment. The
Nek5000 row frame grows by 128 B ordered / 112 B reordered; DUCC scalar and
six-trial frames decrease. These are codegen observations, not runtime results.

**Retain one arithmetic layer in the existing suffix cleanup.** UWABCE's
`mul70` has a private `add69` operand whose leaves already have consumer
definitions. Reusing availability resolution and commit moves that addition and
its multiply entirely into the consumer. No new input walk or read is opened.
The remaining transfer is `add57`, the squared distance. Its final retained data
depth is **four**, measured with the existing depth analysis.

The extension considers one private binary operation in the same block, with
all leaves already available and dominating the multiply. Mandatory boundaries
remain boundaries. The hypothetical retained producer must lose both operations
and pass the real depth gate before committing. Only the final pair of streams
may collapse, so further suffix cleanup cannot invalidate this depth proof.
Failed candidates keep the structural partition; analysis work is charged and
never refunded. Budget exhaustion retains the existing transactional rejection
contract and the 4,096 limit.

| UWABCE, either FP policy | Reference | Retained change |
| --- | ---: | ---: |
| Double streams | 2 | 1 |
| Scratch store + load widths | 32 B | 16 B |
| Duplicated original load widths | 32 B | 0 B |
| Original load widths moved entirely to consumer | 0 B | 32 B |
| Duplicated divisions / multiplies / additions | 3 / 6 / 3 | 0 / 0 / 0 |
| Scratch allocation | 16,384 B | 8,192 B |
| Producer data depth | 11 | 4 |
| Automatic producer / consumer VF | 1 / scalable 2 | scalable 2 / scalable 2 |

Widths are static instruction-access widths; conditional and nested execution
multiplicities vary. The remaining nine-target measurements and exact transfers
are recorded separately for both policies in JSON.

**Reject additional downstream buffering.** An isolated UWABCE experiment
buffering shared divisions eliminates the three repeated divisions, but retains
four repeated multiplies. It needs five streams, 40,960 B scratch, 80 B scratch
store/load widths and 16 B duplicated input-load widths. Its recaptured frame is
41,072 B. This is dominated by the one-stream cut; no selector for this alternative
is retained.

**Reject automatic predicate buffering for Vina.** The distance arithmetic is
still needed by producer control. Moving its cut earlier cannot remove that
work. An isolated generic control-boundary experiment removes the five repeated
FP operations and 16 B duplicated input-load widths, but adds three boolean
streams: scratch grows from 40,960 to 44,032 B and the recaptured frame from
41,024 to 43,088 B. Total added access widths fall from 96 to 86 B, while scratch
stores/loads rise from 80 to 86 B. This trades a modest static saving for more
streams, a larger frame and extra control transfers; without runtime evidence,
there is insufficient reason to introduce a general predicate-buffer policy.
The experiment's code is absent from production. Its verified IR, RVV assembly,
source snapshot, commands and hashes remain in local artifacts.

**Keep the capacity and scheduling policy.** UWABCE's scratch reduction already
follows from removing a stream. No extra buffer policy, tuning flag, LV probe,
rollback, benchmark exception or smaller global capacity is introduced. Capacity
1/3/default checks expose the tradeoff; a smaller frame alone does not justify
more chunk transitions. Vina and SHTools gravity retain scalar stages. Spin-2's
consumer remains scalar. Their net profitability remains a separate question.

## Validation and cost

Production changes add 49 net lines to `ScalarFission.cpp`: two local corrections,
no new helper functions, persistent plan fields, options or pipeline passes.
The earlier-cut extension reuses contribution slices, resolved consumer inputs,
retention, depth, memory proofs, transfer accounting and capacity selection.
Only UWABCE changes target transfer sources. It uses 89 additional analysis
budget units (1,095 total of 4,096); the other surviving targets' analysis budgets
are unchanged. There are no new budget rejections. Per-target budgets and
all observed selection changes are included in JSON.

Two focused regression files (503 lines) cover automatic standalone/Early/Late vectorization,
both branch orientations, single chunks, lazy and poison-sensitive exits,
comparison flags, the exact earlier cut, shallow fallback, retained effects and
control, mandatory freezes and unavailable original reads. Existing depth,
budget, nested, alias, aggregate and state fixtures remain in the full suites.
Four existing bounded-schedule expectations change from `select` to `and`.

Validation includes the ScalarFission and LoopVectorize suites, 66 Vectorize
unit tests, the host/RVV checker, all 117 pinned sources in five configurations,
the nine original native harnesses under both FP policies at capacities 1, 3
and default, and the 1,080-case frozen-partition VF/IC matrix. Requested and
realized settings are separate; unavailable requests are not vectorization
successes. Both spin-2 schedules must be selected in every native configuration.
The established Vina baseline-invalid maximum seed remains the only exclusion.
Ordered output comparisons are exact; reordered comparisons retain the existing
tolerance. No corpus source or benchmark arithmetic was edited.

The final results are **1,361 lit tests passed, 101 unsupported, zero failures**,
**66 unit tests passed**, **34,002 host-checker comparisons**, **585 successful
optimizer/RVV configurations**, and **60,396 native comparisons with zero
mismatches**. Selection remains six Early and nine Late targets under each
policy, with no target or helper selection changes. SHTools gradient still
rejects for exhausted analysis budget; its depth is unmeasured and it emits no
fission schedule. Both spin-2 schedules are verified at source locations 156:5
(the manifest target) and 178:5 (the companion), including all six native
configurations. The matrix realizes every requested setting in **834** cases;
**246** requests remain unavailable. All 1,080 outputs pass machine verification.

UWABCE's final fixed frame is 8,272 B under both policies, versus 16,496 B.
Spin-2 still allocates 16 KiB in function IR and colors to 8 KiB of scratch,
with an 8,416 B frame. The six vectorized consumers also vectorize in the unsplit
reference; these observations do not establish net profitability from splitting.

The baseline binaries and CMake configuration were preserved and hashed before
the first rebuild. Compiler runs reuse identical verified frontend bitcode from
the pinned corpus. Three serial paired timing rounds, after concurrent validation
finishes, cover all nine targets and both policies in alternating compiler order.
Per-process times and peak RSS are recorded in JSON. Each round below totals
18 optimizer compiles per compiler (nine targets, two policies); RSS is the
maximum individual process, in bytes.

| Serial round | Reference seconds | New seconds | Reference peak RSS B | New peak RSS B |
| --- | ---: | ---: | ---: | ---: |
| 1 | 49.00 | 48.96 | 53,510,144 | 53,854,208 |
| 2 | 49.59 | 48.01 | 53,575,680 | 53,788,672 |
| 3 | 48.89 | 47.56 | 53,460,992 | 53,805,056 |

There is no observed aggregate compile-time regression; peak RSS rises by about
0.3 MB. Vina dominates these totals. Per-kernel medians of both policies' summed
times show Nek5000 row at 0.329 → 0.348 s and UWABCE at 0.141 → 0.148 s. These
small absolute costs accompany restored vectorization and, for UWABCE, removal
of repeated divisions and half its scratch. The raw paired samples are retained;
three rounds do not support a statistical compile-time speedup claim. RVV
execution performance remains unmeasured.

## Fresh benchmark recheck, 2026-10-20

A second run freshly compiles all 117 pinned sources and executes **585 current
and 585 preserved-baseline optimizer/RVV configurations** on identical new
frontend bitcode. All **1,170** configurations pass. Exact target and helper
selection/rejection decisions match both the last commit and the previous
validation: six Early and nine Late targets under each FP policy. The bounded
contribution/frontier records match the last commit in all 18 Late captures
(nine kernels, both policies); final transfers, automatic stage choices and
frames reproduce the previous validation.

Fresh native builds again pass **60,396 comparisons with zero mismatches** at
capacities 1, 3 and default under both policies, including both spin-2 schedules.
The fresh 1,080-case VF/IC matrix again has 834 available and 246 unavailable
requests, with every output passing machine verification. The established Vina
maximum-seed exclusion and SHTools gradient budget rejection are retained.

Fresh Clang output contains the newer compiler revision in `DICompileUnit`
producer and `llvm.ident` metadata. Disassembling and comparing all 117 inputs
confirms these are the only differences from the historical inputs (apart from
the disassembler's ModuleID path comment). The strict input-hash comparison
initially rejected reuse of the historical captures. The completed recheck uses
new captures and reruns the preserved baseline on the exact fresh inputs.

Commands, hashes, the metadata comparison and complete results are archived in
`build-fission/benchmark-recheck-20261020-025812/`; the machine-readable report's
`benchmark_recheck` entry records the verified summary and its hash. No production
code or benchmark source changed during the recheck. RVV runtime is unmeasured.

## Reproduction

The baseline tool hashes must match the reference audit before reuse. Preserve
`opt`, `llc`, `clang` and `CMakeCache.txt` from `da9c6d542` before building the new
source. With `PYTHON` set to a Python interpreter with PyYAML and `SYSROOT` to the
verified RVV sysroot:

```sh
ninja -C build-fission clang opt llc FileCheck VectorizeTests
build-fission/bin/llvm-lit -sv llvm/test/Transforms/ScalarFission \
  llvm/test/Transforms/LoopVectorize
build-fission/unittests/Transforms/Vectorize/VectorizeTests
$PYTHON llvm/utils/check-scalar-fission.py --build-dir build-fission \
  --work-dir build-fission/scalar-fission-mitigation/release-execution
$PYTHON llvm/utils/evaluate-scalar-fission.py --build-dir build-fission \
  --corpus ~/Research/search-fission-benchmarks --sysroot "$SYSROOT" \
  --frontend-input-dir build-fission/benchmark-final-check-20261020/corpus \
  --output build-fission/scalar-fission-mitigation/release-corpus
$PYTHON llvm/utils/audit-scalar-fission-frontier.py --build-dir build-fission \
  --corpus ~/Research/search-fission-benchmarks \
  --baseline-results build-fission/benchmark-final-check-20261020/corpus \
  --frontier-results build-fission/scalar-fission-mitigation/release-corpus \
  --output build-fission/scalar-fission-mitigation/release-validation \
  --native --sweep
```

For cleanup minimization, run the preserved baseline `opt` on each captured
`late-{ordered,reordered}-after.ll` with each pipeline listed in the JSON,
`-verify-each -force-vector-interleave=1 -hints-allow-reordering=false`, and
capture scalar-fission stage remarks. Machine-verify generated RVV assembly.
Do not substitute requested VFs or helper-loop successes. Rejected experiments
are archived under `build-fission/scalar-fission-mitigation/rejected/`; their
snapshots are experimental inputs, never corpus edits. The timing command is
the recorded Late optimizer command with the same frontend input, alternating
the preserved and new `opt`, measured with `/usr/bin/time -l` on this host.

RVV runtime and net profitability are **unmeasured**; no RVV runner is available.
