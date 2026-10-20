# Detailed report v2 renderer coverage

`gesummv-detail.txt` is a real ordinary RISC-V report captured with the shared
compiler; only its module path is shortened. `renderer-variants.txt` is a
synthetic renderer fixture grounded in `VPlanCostReport.{h,cpp}`, all
`VP_COST_*` sites, and `AArch64/print-vplans{,-costs,-paths}.ll`.
It covers size/epilogue/shortcut, fractional weighting, payloads and repeated
evaluations. Tests derive an Invalid variant and inject structural/accounting
faults. AArch64/opt execution is unavailable in the shared build; it was not rebuilt.

Every record below is asserted by `test_real_detail_and_full_renderer_record_inventory`.
Graph/header/table/calculation boundaries have separate positive and negative tests.

| Renderer record | Fixture |
| --- | --- |
| `candidate_cost` | gesummv-detail.txt |
| `cast` | renderer-variants.txt |
| `cost` | gesummv-detail.txt |
| `cost_kind` | gesummv-detail.txt |
| `coverage` | renderer-variants.txt |
| `discarded` | renderer-variants.txt |
| `div-rem` | renderer-variants.txt |
| `epilogue-selection` | gesummv-detail.txt |
| `getInstructionCost` | renderer-variants.txt |
| `hoisted-memory-checks` | renderer-variants.txt |
| `interleave` | renderer-variants.txt |
| `interleave-register-class` | renderer-variants.txt |
| `interleave-selection` | gesummv-detail.txt |
| `invalid-cost` | renderer-variants.txt |
| `ir` | gesummv-detail.txt |
| `known_trip_count` | gesummv-detail.txt |
| `legacy` | gesummv-detail.txt |
| `legacy-fallback` | gesummv-detail.txt |
| `legacy-instruction` | gesummv-detail.txt |
| `legacy_precomputed` | gesummv-detail.txt |
| `memory` | gesummv-detail.txt |
| `no-plan` | renderer-variants.txt |
| `not-evaluated` | gesummv-detail.txt |
| `operation` | gesummv-detail.txt |
| `outcome` | gesummv-detail.txt |
| `outside-loop` | gesummv-detail.txt |
| `outside-loop-profitability` | renderer-variants.txt |
| `owner` | renderer-variants.txt |
| `predication` | renderer-variants.txt |
| `predication_divisor` | renderer-variants.txt |
| `ranking-context` | gesummv-detail.txt |
| `region-backedge` | gesummv-detail.txt |
| `register-pressure-policy` | gesummv-detail.txt |
| `register_class` | gesummv-detail.txt |
| `register_pressure` | gesummv-detail.txt |
| `rejection` | renderer-variants.txt |
| `replacement` | renderer-variants.txt |
| `replicated_operations` | renderer-variants.txt |
| `replication` | gesummv-detail.txt |
| `scalar` | gesummv-detail.txt |
| `scalar-baseline` | gesummv-detail.txt |
| `scalar-baseline-details` | gesummv-detail.txt |
| `scalar-block` | gesummv-detail.txt |
| `scalar_operation` | renderer-variants.txt |
| `selected-for-epilogue` | gesummv-detail.txt |
| `selected-for-main` | gesummv-detail.txt |
| `selected_interleave_count` | gesummv-detail.txt |
| `selection-override` | renderer-variants.txt |
| `target` | gesummv-detail.txt |
| `term` | gesummv-detail.txt |
| `unweighted_subtotal` | renderer-variants.txt |
| `validity-checks` | gesummv-detail.txt |
| `vector_region` | gesummv-detail.txt |
| `vector_region_body` | gesummv-detail.txt |
| `vf` | gesummv-detail.txt |
| `weighted_subtotal` | renderer-variants.txt |
