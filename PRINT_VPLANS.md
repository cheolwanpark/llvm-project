# Reading MIR port-demand reports

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/print-vplans \
  --benchmark hpcc/stream-add --artifacts-dir /tmp/explain --detail --replay
```

`print-vplan` is an alias. `--aggregation {max,sum}` and `--body-scale`
select the same settings for scoring and compiler replay. The default is max with body scale 1.

| Field | Meaning |
| --- | --- |
| `ops[].hardware.components` | Uop class, count, possible ports and equal share |
| `ops[].hardware.decode_uops` | Static decode count |
| `ops[].hardware.issued_demands` | Required issue tasks; scalar store address/data are separate |
| `class_demands` | Summed class counts per body |
| `port_demands` | Exact fractional equal-share totals |
| `normalized_port_demands` | Port totals divided by datasheet capacities |
| `bottleneck_ports` | All ports tied for the highest normalized demand |
| `body_cost` | Chosen aggregate, before iteration multiplication and body scale |
| `features.body_scale` | Body cost times body iterations; affine analysis slope |
| `features.fixed_additions` | Unchanged configuration/setup/scalar-tail cost; intercept |
| `score_exact` | Exact affine score for persisted numeric features |
| `coverage.assumed_ops` | Per-instruction approximation reasons |
| `identity.machine_parameters.ports` | Capacities, sources and explicit default assumptions |

Nonlinear body costs have no additive per-instruction cost decomposition. Inspect
instruction class/port contributions to understand the bottleneck instead.
The printed values are demand proxies, not CPU cycle estimates.

Exact trip counts produce an accounted loop total. Unknown exact counts produce
a steady-state per-scalar-iteration score and report unknown setup amortization.
Upper bounds never substitute for exact trip counts. Body-outside work other than
setup configurations remains outside this score.

`analyze-boundaries --term body_scale` reports exact selection intervals for a
fixed aggregation. Each saved b=1 selection is its own reference.
Regret changes of up to **+0.15 per benchmark** are reported as a qualitative
stability diagnostic; there is no aggregate acceptance threshold.

Full MIR, raw observations, compiler commands and replay manifests are kept in
the printed artifact directory. LLVM baseline diagnostics remain separate.
See [the tools guide](utils/vplan-tools/README.md) for evaluation and limitations.
