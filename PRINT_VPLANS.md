# Reading local MIR cost reports

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/print-vplans \
  --benchmark hpcc/stream-add \
  --artifacts-dir /tmp/explain --detail --replay
```

`print-vplan` is an alias. Reports use the hardcoded machine model in
[cost_model.py](utils/vplan-tools/cost_model.py). Edit its coefficient and window
constants for manual machine calibration; model formulas can also change there.
Every candidate and benchmark uses the same model.

Every candidate shows VF, verified scalar iteration width, scoring scope and
support status. Per-body totals obey:

```text
body_cost = basic + stall - ilp = sum(op.net)
score = body_iterations * body_cost + middle_end_cost
```

Each op row retains its instruction ID and complete MIR text. `--detail` adds
its exact RTL split rule, source revision/link, decode uops, resource components,
cost class and known/unknown geometry. Additional scalar move uops remain separate
resource components. These are static decode workloads, not execution-cycle counts.
Spill/reload instructions have the same memory cost path as other memory ops.

Pair rows identify the anchor and `(other instruction, iteration offset)`, forward
or backward direction, distance, dependency/independence evidence, possible
execution overlap, shared classes, coefficient features and actual contributions.
Forward contention and RAW can add; backward independent overlap subtracts ILP.
Multiple dynamic instances of one static instruction remain distinct. Neither a
different class nor a missing register RAW edge proves eligibility for ILP.

Coverage reports unknown memory/register relations, unknown overlap and unsupported
rules. Unknown pairs receive no ILP credit. Unsupported candidate reasons are
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
