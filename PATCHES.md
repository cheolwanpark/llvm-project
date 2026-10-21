# SpillCost

This patch replaces the Python VPlan model's LLVM register-pressure spill
estimate with costs derived from observed spills and reloads after register
allocation. LLVM can estimate zero spill cost even when the backend emits
spills, causing the model to favor a vector width that uses too many registers.
The policy is named `llvm-backend-spill`, with model version
`llvm-backend-spill-v1`.

The driver probes every cost-evaluable fixed and scalable vector candidate.
It counts body-loop spills and reloads separately for GPR, FPR, and vector
registers, weighting vector instructions by their physical register group size
(1, 2, 4, or 8). Those counts use the candidate's existing TTI spill and reload
prices and are normalized by a proven positive integer ratio between the
backend iteration width and the candidate's estimated width.

```text
Qraw = sum(group * (spills * spill_unit + reloads * reload_unit))
Qbackend = saturate(trunc_toward_zero(Qraw / iteration_ratio))
Qeffective = add_sat(add_sat(Qprecomputed, Qvector_region), Qbackend)
```

Costs use integer quarter units. Reconstructing the body cost from its
components avoids subtracting an estimate from an already saturated total.
Scalar costs, other middle-end costs, candidate order, scalable tie preference,
and the incoming candidate's tail policy retain their existing behavior.
Display scores and pairwise selection use the same effective body cost.
Original candidate manifests remain unchanged; derived costs, counts, prices,
and normalization details are recorded in `candidate-status.json`.

If a legal candidate lacks proven backend spill coverage, the entire benchmark
is excluded before selection and final replay. Compiler crashes, timeouts,
malformed observations, and identity mismatches are errors. Evaluation also
checks observed VLEN against the measurement protocol. Policy identities and
evaluation provenance record implementation, database, and compiler hashes.

The patch also adds a reusable strict parser and JSON CLI for this checkout's
`report_version=2` detailed VPlan output. It preserves report identities, graphs,
recipes, repeated evaluations, nested calculations, and exact costs, and checks
boundaries, references, accounting, and ranking consistency. Parsed reports
describe the original LLVM costs. The model continues to consume structured
candidate and backend JSON. Both print commands now support `--skip-build`.

Validation passed 105 tests, including compiler integration, and 137 detailed
reports from all 117 database benchmarks with zero unsupported records or
parsing errors. No LLVM C++ changes, compiler rebuild, fitting, new runtime
measurements, or database changes were required. AArch64-only report paths use
renderer-based fixtures because the shared build provides RISC-V targets.

| Evaluation | Baseline | SpillCost |
| --- | ---: | ---: |
| Eligible benchmarks | 100 | 99 |
| Wrong predictions | 59 | 53 |
| Excluded benchmarks | 17 | 18 |
| Mean regret on the common 98 benchmarks | 7.1318% | 6.1026% |

The common set contains eight solved predictions and three newly wrong
predictions. Two FIR benchmarks became excluded because their backend iteration
mapping could not be proven; these exclusions are not counted as solved
predictions. One previously excluded benchmark became eligible. The full
reevaluation completed with zero compiler failures.

For `polybench/p32-gesummv-l00`, s8 and f16 each have three m8 spills and three
m8 reloads. Their added spill cost is 48 model units, raising body cost from
90 to 138. The model now selects s4, whose body cost remains 46, reducing the
benchmark's DB regret from 68.2775% to 0%.

The [baseline report](wrong-predictions-baseline.md) and
[SpillCost report](wrong-predictions-spillcost.md) contain the full rankings,
exclusions, and artifact links. See the [tools guide](utils/vplan-tools/README.md)
for parser usage and reproduction commands. Evaluation artifacts remain under
`.cache/`.

# StridedMemoryCost

This patch adds an experimental strided-load interaction cost on top of
SpillCost. Counting each memory instruction independently can underestimate
the cost of nearby strided loads at wide vector widths. The new
`memory_cost.py` module models this interaction using backend instruction
order, estimated request counts, and byte strides recovered from saved MIR.
The model version is `backend-memory-interaction-v2`. It is currently an
opt-in offline replay model; the default compilation policy remains SpillCost.

Each non-spill strided load pairs with the next strided load in body order.
The last load pairs with the first load of the next iteration, including a
self-pair when the body has only one strided load. The residual-stride variant
retains LLVM's existing memory costs and adds the following penalty:

```text
w(stride) = 1                              if stride is unknown
            0                              if reverse-contiguous
            min(1, L / max(1, abs(stride))) otherwise
P = sum(alpha * H/(H + gap) * max(0, q_i + q_j - K)
        * min(w(stride_i), w(stride_j))) / iteration_ratio
Qeffective = add_sat(Qspill_baseline, saturate(floor(4 * P)))
```

`gap` counts intervening non-meta backend instructions, not issue cycles.
For strided loads, `q` is the estimated active element count, derived from
VLEN, EMUL, and element width with full-active VL/masks assumed. Strides and
`L` are in bytes. The iteration ratio is the same proven backend-to-candidate
normalization used for spills. `P` uses model units and is converted to integer
quarter units once after summation. Scalar costs, tail policy, and observed
spill/reload costs retain their existing behavior.

Version 2 keeps the stride weight but removes the finite-iteration frequency
factor and direct-RAW-dependence gate. Wrap pairs receive full weight even in
a one-body loop. The model therefore does not account for dependence
serialization. Large strides attenuate the extra interaction penalty; this is
an exploratory hypothesis, not a measured hardware contention law.

| Parameter | Default | Experimental tuned profile |
| --- | ---: | ---: |
| Strength, alpha | 0.5 | 0.5 |
| Request threshold, K | 8 | 8 |
| Distance scale, H | 4 | 8 |
| Stride scale, L | 16 bytes | 8 bytes |

The replay tool also compares adding a backend request-service cost while
keeping LLVM memory costs (`add`) against replacing the observed additive
LLVM memory-hook subtotal (`replace`). The former can double-count service;
the latter can discard shuffle/lowering costs bundled into interleaved memory
hooks. A separate experimental load/store shared-line term remains available
but is excluded from residual-stride. Unsupported memory observations cause
a reported whole-benchmark fallback to SpillCost; newly selected unmeasured
fixed/scalar VFs are explicit exclusions.

Validation replays all 117 benchmarks with frozen candidates and historical
measurements. Both coefficient settings preserve the previous VF choices,
eligibility, and regret after removing the frequency/dependence factors, across
all replay modes and stages. The Python suite passes 102 tests; 15 tests requiring
a compiler environment are skipped.

| Evaluation | SpillCost | Strided default | Strided tuned |
| --- | ---: | ---: | ---: |
| Eligible benchmarks | 99 | 99 | 99 |
| Wrong predictions | 53 | 51 | 51 |
| Mean regret on these same 99 benchmarks | 6.2521% | 5.2482% | 5.1916% |
| Regressions relative to SpillCost | — | 0 | 0 |

The default interaction term changes s111 and s128 from s16 to their measured
optimal s2, while retaining s16 for s1232. The tuned profile additionally changes
band-lin-eq-outer from s4 to s2, lowering its regret from 14.34% to 8.73%.
That extra gain depends on the extractor reporting an unknown stride: supplying
the actual +40-byte stride removes it. The profile was selected by in-sample
coefficient search and has no held-out validation. Historical measured binaries
are not verified identical to the probed MIR. These results concern VF selection;
no new runtime measurements or compiler changes were made.

See the [default replay](.cache/memory-interaction-v2-default-20261021/report.md),
[tuned replay](.cache/memory-interaction-v2-tuned-20261021/report.md), and
[StridedMemoryCost report](wrong-predictions-stridedload.md) for full rankings,
exclusions, per-case results, and limitations. The
[tools guide](utils/vplan-tools/README.md) documents replay commands and the
[tuned profile](utils/vplan-tools/memory-cost-tuned.json).
