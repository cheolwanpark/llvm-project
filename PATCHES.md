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
