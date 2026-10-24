# Reading MIR cost reports

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/print-vplans \
  --benchmark hpcc/stream-add --artifacts-dir /tmp/explain --detail --replay
```

`print-vplan` is an alias. `--body-scale` is forwarded to scoring and compiler
replay. Model semantics and assumptions are documented in [MODEL.md](MODEL.md).

| Field | Meaning |
| --- | --- |
| `ops[].hardware.components` | Uop class, count, possible ports and equal share |
| `ops[].hardware.decode_uops` | Static decode count |
| `ops[].hardware.issued_demands` | Required issue tasks; scalar store address/data are separate |
| `class_demands` | Summed class counts per body |
| `port_demands` | Exact fractional equal-share totals |
| `normalized_port_demands` | Port totals divided by datasheet capacities |
| `bottleneck_ports` | All ports tied for the highest normalized demand |
| `demand_cost`, `window_cost`, `body_entries` | D, W and B from MODEL.md |
| `dependency_path` | L_path, its instruction IDs and per-node completion estimates |
| `dependency_graph` | Prepared RAW edges and dependency coverage |
| `ops[].timing` | Per-op latency/II, expansion and source evidence |
| `identity.machine_parameters.rob_entries` | Datasheet ROB capacity |
| `body_cost` | Body score before iteration multiplication and body scale |
| `features.body_scale` | Body cost times body iterations; affine analysis slope |
| `features.fixed_additions` | Unchanged configuration/setup/scalar-tail cost; intercept |
| `score_exact` | Exact affine score for persisted numeric features |
| `coverage.assumed_ops` | Per-instruction approximation reasons |
| `identity.machine_parameters.ports` | Capacities, sources and explicit default assumptions |

`analyze-boundaries --term body_scale` reports exact selection intervals for a
saved model. Each saved b=1 selection is its own reference.
Regret changes of up to **+0.15 per benchmark** are reported as a qualitative
stability diagnostic; there is no aggregate acceptance threshold.

Full MIR, raw observations, compiler commands and replay manifests are kept in
the printed artifact directory. LLVM baseline diagnostics remain separate.
See [README.md](README.md) for evaluation commands.
