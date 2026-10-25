# Reading MIR cost reports

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/print-vplans \
  --benchmark hpcc/stream-add --artifacts-dir .cache/explain --detail --replay
```

`print-vplan` is an alias. `--body-scale` is forwarded to scoring and compiler
replay. Model semantics and assumptions are documented in [MODEL.md](MODEL.md).
The current report describes `mir-service-window-v4`, using service demand rather
than decoded-uop counts. Run the command from the project root; keep reports and
temporary analysis artifacts under its `.cache/` directory.

| Field | Meaning |
| --- | --- |
| `ops[].hardware.components` | Service contributions: `service_class`, `work_unit`, `work_units`, `demand_per_unit`, `demand`, `possible_ports`, `per_port`, and evidence |
| `ops[].hardware.geometry` | Instruction geometry, including applicable LMUL/EMUL and element widths; VF is not LMUL |
| `ops[].spill_slot` | Whether the instruction accesses a spill slot; ordinary class rules still determine its cost |
| `class_demands` | Summed service demand per class per body, not instruction or uop counts |
| `port_demands` | Exact fractional equal-share service demands |
| `normalized_port_demands` | Port totals divided by datasheet capacities |
| `bottleneck_ports` | Ports tied for the highest normalized demand in D; this does not determine whether D or W dominates |
| `demand_cost`, `window_cost`, `body_entries` | D, W and B from MODEL.md |
| `dependency_path` | L_path, its instruction IDs and per-node completion estimates |
| `dependency_graph` | Prepared RAW edges and dependency coverage |
| `ops[].timing` | Instruction latency plus component latency/II, work units, completion estimates, combination rule, assumptions and fallback status |
| `identity.machine_parameters.rob_entries` | Datasheet ROB capacity |
| `body_cost` | `max(demand_cost, window_cost)` before iteration multiplication and body scale |
| `body_iterations`, `iteration_width`, `scope` | N, original scalar iterations per body, and whether scoring uses an exact trip count or steady state |
| `middle_end.unscaled_additions` | Separate body/setup configuration and scalar-tail contributions |
| `features.body_scale` | Body cost times body iterations; affine analysis slope |
| `features.fixed_additions` | Unchanged configuration/setup/scalar-tail cost; intercept |
| `score_exact` | Exact affine score for persisted numeric features |
| `coverage.assumed_ops` | Per-instruction approximation reasons |
| `coverage.timing_fallback_ops` | Instructions whose timing uses an explicit fallback |
| `identity` | Model, implementation/datasheet digests, pinned RTL revision, observation schema and machine settings |
| `identity.machine_parameters.ports` | Capacities, sources and explicit default assumptions |

For each component, `demand = work_units × demand_per_unit`. D is the largest
normalized port demand; W is `body_entries × dependency_path.cost / rob_entries`.
The final score is `body_scale × N × max(D, W) + fixed_additions`, with body scale
defaulting to 1. Costs are cycle proxies for ranking candidates, not guaranteed
CPU cycle predictions. Loop-carried recurrence is not included in W. Independent
memory-queue and issue-queue costs are not implemented or reported as zero terms.

`decode_uops` and `issued_demands` are no longer report fields. Reports from older
models must be regenerated from raw MIR observations using `score-mir`;
`rescore-evaluation` changes only body scale within a matching model identity.
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
