# Reading local MIR cost reports

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/print-vplans \
  --benchmark hpcc/stream-add \
  --artifacts-dir /tmp/explain --detail --replay
```

`print-vplan` is an alias. Reports use the hardcoded machine model in
[cost_model.py](utils/vplan-tools/cost_model.py). Edit its coefficient and window
constants to change the model in source. Every candidate and benchmark uses
`mir-basic-calibrated-v1`: memory weight 3, move weight 2, every other basic
weight (including scalar) 1, middle-end scale 1, and both windows 0. The weights
were selected on Search; they are not measured hardware latencies.

Every candidate shows VF, verified scalar iteration width, scoring scope and
support status. Per-body totals obey:

```text
op.basic = sum(component_work[class] * basic_coefficient[class])
body_cost = basic = sum(op.net)
score = body_iterations * body_cost + middle_end_scale * middle_end_additions
```

Each op row retains its instruction ID and complete MIR text. `--detail` adds
its exact RTL split rule, source revision/link, decode uops, resource components,
cost class and known/unknown geometry. Additional scalar move uops remain separate
resource components. These are static decode workloads, not execution-cycle counts.
Memory/move components apply their respective weights separately. MIR LMUL,
SEW, EMUL and opcode splits determine work; VF has no separate multiplier.
Spill/reload instructions have the same memory cost path as other memory ops
and incur no duplicate charge.

The default skips dependency/overlap analysis and all pair computation. Reports
retain `pairs=[]`, zero contention/RAW/ILP features and `stall=ilp=0`. The retained
0.25/0.25/0.125 pair coefficients are inactive. Zero pair coverage counters mean
analysis was not performed, not that all pairs are independent. Observed register
and memory coverage remains available.

If nonzero windows are enabled in source, pair rows identify the anchor and
`(other instruction, iteration offset)`, forward or backward direction, distance,
dependency/independence evidence, possible
execution overlap, shared classes, coefficient features and actual contributions.
Structured pair rows expose `pair_work` (the minimum total decode work, used for
RAW and ILP) and `contention_work` (the sum of classwise minimum component work
over shared classes). `contention_work` describes shared work in either direction;
only forward pairs apply it as a contention feature. Forward contention and RAW can
add; backward independent overlap subtracts ILP.
Multiple dynamic instances of one static instruction remain distinct. Neither a
different class nor a missing register RAW edge proves eligibility for ILP.

When pair analysis is enabled, coverage reports unknown memory/register
relations and unknown overlap. Unknown pairs receive no ILP credit. Unsupported
rules are reported under either setting. Unsupported candidate reasons are
retained even when other candidates can be selected. Signed op/body scores and
excessive cancellation remain visible; no unreported discount cap is applied.

The structured `candidate-status.json` uses the same score result as the human
report. It includes coefficients and their digest, model/schema/rule identities,
hardcoded window/formula settings, compiler/target/stage, per-op features, pair contributions,
iteration mapping and middle-end additions. These permit independent reconciliation
of pair, op, body and final totals. Exact counts are distinct from upper bounds;
steady-state scores do not claim a known scalar remainder or setup amortization.
Full raw JSON, MIR, checkpoint IR, compiler commands and final selection artifacts
are retained under the printed artifact directory.

Ordinary LLVM baseline diagnostics still use `VPlanCostReport`: those are the
middle-end's actual cost observations and final transformation outcome. They are
parsed only by `evaluate-baseline` and never mixed into the local model's body
breakdown. `--detail` on the local reporting command always explains the local
calculation.

The [2026-10-23 search reevaluation](utils/vplan-tools/results/basic-calibrated-2026-10-23/summary.json)
scored 843 candidates across 189 of 203 attempted benchmarks, with 14 exclusions
and 189 verified replays: mean regret 4.671%, exact VF accuracy 90/189, worst
regret 55.064%. Seven selections improved and one worsened relative to window 4;
`polybench/polybench-fdtd-2d-l03` was 12.428% slower than its old selection.
These are stored-cycle results on Search including calibration cases, not an
independent generalization estimate or new hardware timing. Historical fixed-model
reports describe their recorded window 4 model.
