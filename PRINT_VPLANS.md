# Printing VPlan costs and decisions

The loop vectorizer provides two hidden diagnostic flags for inspecting how it
costs candidate VPlans and chooses a vectorization strategy:

| Flag | Output |
| --- | --- |
| `--print-vplans` | Plan snapshots, cost contributions, scalar baseline, comparisons, and decisions. |
| `--print-detailed-vplans` | All of the above, plus nested calculations and observed target cost queries. |

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

Each loop report starts with `VPlan report_version=1` and ends with
`End VPlan report`. The header identifies the module, invocation, function,
loop index, original header, and reporting depth. Context includes the target,
available function CPU/features attributes, cost kind, size-optimization state,
tuning vscale, user hints, and debug location when present.

Reports cover loops that reach planning. A loop rejected before planning may
have no report. If planning produces no candidate, the report includes
`outcome=no-plan` and the available failure information.

### Plans, recipes, and evaluations

- `plan=N` identifies a candidate snapshot. Different plans may support the
  same vectorization factor, so a VF alone does not identify a candidate.
- `vf=f4` means four fixed lanes; `vf=s4` means `vscale * 4` lanes.
- `recipe_inventory` assigns names such as `R0` and `R1` to recipes in that
  snapshot. Cost entries use those names to reference the displayed recipes.
- `evaluation=N` distinguishes repeated evaluations, including evaluations of
  the same plan and VF for different purposes.
- `phase` identifies the purpose, such as `candidate-validation`,
  `main-selection`, `interleave-selection`, or `outside-loop-profitability`.
  Additional queries for invalid-cost remarks use `invalid-cost-remarks`.

Snapshots are captured before subsequent transformations or deletion can
invalidate their contents. Each snapshot is printed once, followed by its
evaluations. Loop-level events follow the plan groups, so output order is not
a chronological trace of all queries. Identities belong to this invocation
and snapshot; they are not persistent identifiers across compiler revisions.

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
- `status=not-evaluated` indicates a recipe was not queried in that evaluation.
- Forced instruction-cost replacements and emulated masked-memory penalties
  are identified explicitly.

The scalar baseline comes from the legacy scalar cost model, independently of
the scalar VPlan snapshot. It reports instruction costs and block weighting:

```text
scalar_iteration_cost = sum(block_instruction_sum / block_divisor)
```

Integer division happens **after summing a block**. Dividing individual
instruction costs first would change rounding.

### Comparisons and outcomes

Comparison events distinguish ranking against the incumbent from profitability
against scalar execution. They report costs, estimated widths, the maximum
trip count, the actual scalar-tail argument, and the decision reason.

For throughput comparisons with an unknown maximum trip count, the report
shows the integer cross-products used to compare cost per lane. For known
trip counts, it shows vector iterations, any scalar remainder, and the vector
and scalar-tail terms. Code-size comparisons and fixed/scalable preferences
have their own decision reasons; some preferences decide before numeric
ranking.

`selected-for-main` and `selected-for-epilogue` identify selected plans.
Epilogue events distinguish source plans, reused costs, and cloned plans.
Interleave selection reports its count and applicable policy. Later
outside-loop profitability accounts for runtime checks, early-exit work,
middle-block work, and minimum profitable trip counts. Its current estimate
omits epilogue cost, which the report labels explicitly.

A selection can still end in `outcome=vectorization-rejected` after later
checks. `outcome=vectorization-emitted` records that the transformation ran.
User-hinted, scalar-only, and outer-loop shortcuts can select a plan without
normal cost comparison. These selections are marked `not-evaluated` with a
reason; placeholder zero costs must not be interpreted as modeled free loops.
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

The text layout is identified by `report_version=1` but is not a stable
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
They cover flag behavior, deterministic output, unchanged generated IR,
accounting, scalar rounding, tail handling, spills, invalid costs, and selection
paths. See also the [vectorizer documentation](llvm/docs/Vectorizers.md).
