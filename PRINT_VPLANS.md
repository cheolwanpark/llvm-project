# Reading MIR cost reports

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/print-vplans \
  --benchmark hpcc/stream-add --artifacts-dir .cache/explain --detail --replay
```

`print-vplan` is an alias. `--body-scale`, `--aggregation`, and `--window` are forwarded to scoring and compiler
replay. Model semantics and assumptions are documented in [MODEL.md](MODEL.md).
The current report schema is `uop-demand-report-v1` for `mir-uop-demand-v1`.
Explicit uops carry resource work and rates; counts are diagnostics, not cost multipliers.
Run the command from the project root; keep reports and
temporary analysis artifacts under its `.cache/` directory.

| Field | Meaning |
| --- | --- |
| `ops[].uops[]` | Stable `[mir_id, ordinal]` ID, kind, origin, geometry, resource uses, timing group references, demand, evidence and assumptions |
| `ops[].uops[].resource_uses[]` | `demand_key`, `work_unit`, `work_units`, `demand_per_work_unit`, derived `demand`, `demand_basis`, `possible_ports`, per-port contributions and work/routing/rate evidence |
| `ops[].uops[].geometry` | Resolved LMUL/EMUL, widths, precision or fields used by the rule; VF is not LMUL |
| `ops[].expansion` | Rule ID, modeled uop count, verified decode count (null if unverified), timing groups, completion policy and assumptions |
| `ops[].spill_slot` | Whether the instruction accesses a spill slot; ordinary class rules still determine its cost |
| `class_demands` | Summed service demand per class per body, not instruction or uop counts |
| `port_demands` | Exact fractional equal-share service demands |
| `normalized_port_demands` | Port totals divided by datasheet capacities |
| `bottleneck_ports` | Ports tied for `demand_max`; diagnostics independent of the selected aggregation and W |
| `demand_max`, `demand_sum` | Both aggregations of capacity-normalized port demands |
| `demand_cost`, `window_cost`, `body_entries` | Selected D, optional W (null when disabled) and MIR count B from MODEL.md |
| `dependency_path` | L_path, its instruction IDs and per-node completion estimates |
| `dependency_graph` | Prepared RAW edges and dependency coverage |
| `ops[].timing` | MIR latency and `groups` with nominal latency/II, total work, completion estimates, combination rule, assumptions and fallback status |
| `identity.machine_parameters.rob_entries` | Datasheet ROB capacity |
| `body_cost` | `max(D, W)` when window is enabled, otherwise D; before iteration multiplication and body scale |
| `body_iterations`, `iteration_width`, `scope` | N, original scalar iterations per body, and whether scoring uses an exact trip count or steady state |
| `middle_end.unscaled_additions` | Separate body/setup configuration and scalar-tail contributions |
| `features.body_scale` | Body cost times body iterations; affine analysis slope |
| `features.fixed_additions` | Unchanged configuration/setup/scalar-tail cost; intercept |
| `score_exact`, `score` | Exact rational score and display-only floating-point value |
| `coverage.assumed_ops` | Per-instruction approximation reasons |
| `coverage.timing_fallback_ops` | Instructions whose timing uses an explicit fallback |
| `identity` | Model, implementation/datasheet digests, expansion version, pinned RTL, arithmetic policy, nominal datasheet, observation schema and machine settings |
| `identity.machine_parameters.ports` | Capacities, sources and explicit default assumptions |

For each resource use, `demand = work_units × demand_per_work_unit`. Required
resources add; each resource's alternative ports split its demand equally.
The default D is the largest normalized port demand; W is
`body_entries × dependency_path.cost / rob_entries`. `--aggregation=max --window=enabled`
is the default. `max/disabled` and `sum/disabled` are also supported; `sum/enabled`
is rejected. The score is `body_scale × N × body_cost + fixed_additions`, with body scale
defaulting to 1. Calculation values are integers or exact rational strings; only
display values and evaluation statistics use floats. Costs are cycle proxies for ranking candidates, not guaranteed
CPU cycle predictions. Loop-carried recurrence is not included in W. Independent
memory-queue and issue-queue costs are not implemented or reported as zero terms.

`modeled_uop_count` does not establish a verified decode count or change B.
`origin` distinguishes `rtl-derived`, `assumed`, and `fallback`; resource evidence
separately identifies work, routing and rate assumptions. Memory work allocation
is a nominal full-active approximation even when decode count is verified.
Reports from older models must be regenerated from raw MIR observations using
`score-mir`. `rescore-evaluation` validates persisted Uop work/demand/timing and
changes aggregation, window policy or body scale within the same implementation
and datasheet. It does not verify replay for the new settings.
Selection breaks equal scores by smaller scalable VF, then candidate ID. VF 1
means scalable s1, not scalar execution.

`analyze-boundaries --term body_scale` reports exact selection intervals for a
saved model. Each saved b=1 selection is its own reference.
Regret changes of up to **+0.15 per benchmark** are reported as a qualitative
stability diagnostic; there is no aggregate acceptance threshold.

Full MIR, raw observations, compiler commands and replay manifests are kept in
the printed artifact directory. LLVM baseline diagnostics remain separate.
See [README.md](README.md) for evaluation commands.
Database split labels do not define separate evaluation cohorts. Recorded cycles
come from deterministic RTL execution; one value per benchmark/VF is intentional.
