# Printing VPlan costs and decisions

The loop vectorizer provides two hidden diagnostic flags for inspecting how it
costs candidate VPlans and chooses a vectorization strategy:

| Flag | Output |
| --- | --- |
| `--print-vplans` | Loop and CPU identity, scalar baseline, one candidate table, selections, and outcome. |
| `--print-detailed-vplans` | The summary plus annotated plan graphs, grouped recipe costs, and nested calculations. |

Both flags write to **standard error** and default to false. Neither requires
`-debug` or `-debug-only`. Enabling both produces one detailed report per loop
attempt, rather than separate summary and detailed reports.

Reporting observes the existing algorithm. It does not force vectorization,
choose a particular vector width, or request additional cost queries. Costs are
LLVM model units for the displayed cost kind, **not measured CPU cycles**.

## Build requirements

The flags are available when LLVM is built with assertions or
`LLVM_ENABLE_DUMP`, matching the availability of the full VPlan printers.
Release builds without either capability do not register these flags.

For example, from the repository root:

```sh
cmake -S llvm -B build-print-vplans -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_ASSERTIONS=ON
cmake --build build-print-vplans --target opt
```

An alternative is to configure with `-DLLVM_ENABLE_ASSERTIONS=OFF` and
`-DLLVM_ENABLE_DUMP=ON`.

## Usage

Capture a summary while running the loop vectorizer:

```sh
build-print-vplans/bin/opt -passes=loop-vectorize --print-vplans \
  -disable-output input.ll 2> vplans.txt
```

Capture detailed calculations:

```sh
build-print-vplans/bin/opt -passes=loop-vectorize --print-detailed-vplans \
  -disable-output input.ll 2> detailed-vplans.txt
```

To keep the transformed IR as well, replace `-disable-output` with
`-S -o vectorized.ll`. The report remains on standard error, separate from the
IR output. Other diagnostics also written to standard error may appear in the
same file.

Use the target triple, CPU, and features appropriate to the input. For example,
an AArch64 build with SVE support can be inspected with:

```sh
build-print-vplans/bin/opt -passes=loop-vectorize -mtriple=aarch64 \
  -mattr=+sve --print-detailed-vplans -disable-output input.ll \
  2> sve-vplans.txt
```

Target selection and existing vectorizer options still control normal costing
and selection; the reporting flags only expose their effects.

## Reading a report

Each loop report starts with `VPlan report_version=2` and ends with
`End VPlan report`. The header identifies the module, invocation, function,
loop index, original header, and reporting depth. Context includes the target
triple, function CPU attribute (`unspecified` if absent), cost kind,
size-optimization state, tuning vscale, user hints, and debug location.
Exhaustive target feature lists are omitted.

Reports cover loops that reach planning. A loop rejected before planning may
have no report. If planning produces no candidate, the report includes
`outcome=no-plan` and the available failure information.

### Summary table

The scalar baseline precedes one candidate table. Its columns are:

| Column | Meaning |
| --- | --- |
| `phase` | Main-loop or epilogue selection; the same plan/VF can participate in both contexts. |
| `plan` | Snapshot identity; different plans may support the same VF. |
| `vf` | `f4` means four fixed lanes; `s4` means `vscale * 4` lanes. |
| `estimated_width` | Estimated lanes using tuning vscale when available, otherwise the known minimum. |
| `body_cost` | Observed candidate cost, including legacy and spill charges. |
| `score` | Ranking score, printed once per candidate and phase. |
| `score_kind` | `cost-per-lane`, `whole-loop`, `code-size`, or `not-evaluated`. |
| `vs_incumbent` | Whether the candidate replaced the incumbent, its identity, and the comparison reason. |
| `vs_scalar` | The independent scalar-profitability result and reason. |
| `reason` | A skip or shortcut-selection reason, when applicable. |

Unknown-trip-count scores use exact ratios such as `5/4`, preserving fractional
numerators when present. Known-trip-count scores are the observed total costs,
including scalar-tail work or rounding up vector iterations when folding the
tail. Code-size scores use the body cost. Comparison results retain the actual
tie rules and policy overrides; they are not reconstructed from printed scores.

A shortcut can leave a score or scalar baseline `not-evaluated`. In particular,
placeholder zero costs used for user-VF and outer-loop selections do not mean
the loop is free. An epilogue candidate initially accepted without comparison
can acquire a score later when the existing algorithm compares it as incumbent.
No evaluation is performed merely to fill the table.

Invalid-cost diagnostics, discarded-plan reasons, and policy decisions follow
the table. Identical repeated diagnostics are printed once with an occurrence
count. The summary ends with main and epilogue VFs, the final interleave count,
and the transformation outcome. A late rejection can leave the final interleave
count `not-evaluated`, even when an earlier heuristic selected a provisional
count. Successful diagnostic checks are omitted from the summary.

### Detailed graphs and evaluations

Detailed mode adds a `details` section after the summary. Each plan graph is
printed once, with `[R0]`, `[R1]`, and similar annotations attached directly to
its recipes. There is no separate recipe inventory. Cost entries reference
these IDs and retain their nested calculations.

Snapshots are captured before transformation or deletion can invalidate their
contents. Evaluations are grouped by plan and VF, then retain observation order
within each VF. `evaluation=N` distinguishes repeated evaluations; `phase`
identifies `candidate-validation`, `main-selection`, `interleave-selection`,
`outside-loop-profitability`, or `invalid-cost-remarks`. This grouping is not a
chronological trace of all queries. IDs belong to the invocation and snapshot,
not to a persistent identity across compiler revisions.

Successful validity-only checks are summarized with a count and recipe-ID
ranges. Unvisited recipes likewise use a single `not-evaluated` count and range
list per evaluation. Invalid checks retain their individual entries and
available calculation details.

### Cost accounting

Candidate accounting follows the existing additions:

```text
candidate_cost = legacy_precomputed + vector_region + spill_cost
```

Legacy charges identify their instruction and category: induction,
non-backedge branches, forced scalar instructions, or scalarization. The vector
region contains charged recipe costs and separately reported region backedges.
Register-pressure entries describe the policy, available usage observations,
register limits, and spill/reload costs when that analysis ran.

Recipe entries separate `cost` from `contribution` and describe their `source`:

- A recipe can have zero contribution because its instruction was precomputed,
  ignored, or already charged to another recipe. Zero contribution does not
  necessarily mean a free operation.
- `scope=validity-only` queries check recipes outside the vector region. Their
  numeric costs do not enter the body total, but an invalid result can reject
  the candidate. `vector_region_body` exposes the body result before those
  checks; `vector_region` includes their effect on validity.
- Outside-loop profitability and invalid-cost remark queries also have their
  own scope; their recipe entries do not contribute to the candidate body.
- `Invalid` is preserved as an invalid cost, not converted to zero.
- `not-evaluated count=... recipes=...` lists recipes not queried in that evaluation.
- Forced instruction-cost replacements and emulated masked-memory penalties
  are identified explicitly.

The scalar baseline comes from the legacy scalar cost model, independently of
the scalar VPlan snapshot. It reports instruction costs and block weighting:

```text
scalar_iteration_cost = sum(block_instruction_sum / block_divisor)
```

Division happens **after summing a block**, using the existing
`InstructionCost` precision (quarter units in this checkout). For example,
`3 / 2` is reported as `1.5`. Dividing individual instruction costs first
would change rounding.

### Comparisons and outcomes

The table separates ranking against the incumbent from profitability against
scalar execution. For throughput comparisons with an unknown maximum trip
count, the existing algorithm compares cross-products; the table displays the
equivalent cost-per-lane ratio. For known trip counts, the score accounts for
vector iterations and any scalar remainder. Detailed ranking context records
the maximum trip count and actual scalar-tail argument without repeating the
scores. Code-size comparisons and fixed/scalable preferences retain their
own decision reasons; some preferences decide before numeric ranking.

`selected-for-main` and `selected-for-epilogue` identify selected plans.
Epilogue events distinguish source plans, reused costs, and cloned plans.
Interleave selection reports its count and applicable policy. Later
outside-loop profitability accounts for runtime checks, early-exit work,
middle-block work, and minimum profitable trip counts. Its current estimate
omits epilogue cost, which the report labels explicitly.

A selection can still end in `outcome=vectorization-rejected` after later
checks. `outcome=vectorization-emitted` records that the transformation ran.
User-hinted, scalar-only, and outer-loop shortcuts can select a plan without
normal cost comparison. Their unavailable costs and scores are marked `not-evaluated`, with a
selection reason; placeholder zero costs must not be interpreted as modeled free loops.
Forced vectorization's scalar-incumbent sentinel is likewise reported as an
override, separately from the real scalar baseline.

## Additional detail

Detailed mode adds `calculation=...` scopes and named `term`, `result`, and
`coverage` fields. These expose observed query results and arithmetic in
recipe and legacy costing, including memory accesses, scalarization,
replication, arithmetic, casts, calls, reductions, inductions, and spills.
Available inputs and intermediate values are printed at instrumented sites.

Coverage labels distinguish:

| Label | Meaning |
| --- | --- |
| `expanded` | An observed vectorizer calculation or result. |
| `tti-leaf` | A result returned by a target cost API; target-internal calculations are not expanded. |
| `opaque-legacy` | A legacy value or accounting source whose construction is not attached to this calculation. |

Nested query results, intermediate values, and enclosing totals describe the
same computation. Do not sum every number printed in a detailed report; use
the contribution fields and component totals for accounting.

The text layout is identified by `report_version=2` but is not a stable
machine-readable schema. There is no JSON output or report-specific filtering
option. Existing VPlan transformation-printing options remain useful for
inspecting intermediate transformation states.

## Implementation and tests

The collector and rendering live in
[`VPlanCostReport.h`](llvm/lib/Transforms/Vectorize/VPlanCostReport.h) and
[`VPlanCostReport.cpp`](llvm/lib/Transforms/Vectorize/VPlanCostReport.cpp).
Observations are recorded at existing costing and selection sites. With both
flags disabled, the collector is null; snapshots, detailed terms, and report
formatting are not collected.

Focused tests are in
[`print-vplans.ll`](llvm/test/Transforms/LoopVectorize/AArch64/print-vplans.ll),
[`print-vplans-costs.ll`](llvm/test/Transforms/LoopVectorize/AArch64/print-vplans-costs.ll),
and
[`print-vplans-paths.ll`](llvm/test/Transforms/LoopVectorize/AArch64/print-vplans-paths.ll).
They cover flag behavior, deterministic output, unchanged generated IR and
cost/selection debug traces, exact fractional accounting, tail handling, spills,
invalid costs, and selection paths. A recording-TTI unit test also checks that
reporting modes preserve the cost-query sequence and returned values. See also the [vectorizer documentation](llvm/docs/Vectorizers.md).
