# MIR decoder work cost model

This LLVM fork observes post-register-allocation RISC-V MIR, scores weighted
instruction decoder work in Python, and replays the selected vector candidate.

```text
op_cost = sum(component_work[class] * basic_coefficient[class])
body_cost = sum(op_cost)
score = body_iterations * body_cost + middle_end_scale * middle_end_additions
```

Scores are effects in model units. Decoder work comes from XiangShan Kunminghu v2
**MinimalConfig**, pinned to revision `e7bab53e66dfb3c4a1d11cf9519b0396f8576cae`.
The default `mir-basic-calibrated-v2` model uses memory weight 3,
move weight 2, all other basic weights (including scalar) 1, and middle-end scale 1.
These weights were selected using the search dataset and apply to every benchmark
and VF. Scoring sums weighted decoder work and middle-end additions.
Actual MIR LMUL/SEW/EMUL and opcode splits determine work; VF has no separate
multiplier and enters through generated MIR and verified iteration width.
Source constants and later formula changes live in
[cost_model.py](utils/vplan-tools/cost_model.py); there are no parameter files or
fitting tools. Spill/reload instructions follow the ordinary instruction paths.

Install [uv](https://docs.astral.sh/uv/), CMake 3.20+, Ninja and a host C++ compiler,
then run from this checkout:

```sh
uv sync --locked --project utils/vplan-tools

# Configures/builds clang, resource headers and llvm-extract automatically.
uv run --project utils/vplan-tools python utils/vplan-tools/collect \
  --benchmark hpcc/stream-add --output /tmp/collection.json

# One fixed model: mean regret, accuracy, worst regret, verified replay and LLVM.
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate \
  --output-dir /tmp/fixed-evaluation

uv run --project utils/vplan-tools python utils/vplan-tools/print-vplans \
  --benchmark hpcc/stream-add --artifacts-dir /tmp/stream-add --detail --replay
```

The default database is **this checkout's `search-dataset.sqlite`**, regardless of
working directory or `--llvm-path`. Precedence is `--db` > nonempty `VPLAN_DB` >
that default. SQLite opens it read-only. Sources, compile arguments, workloads,
split labels and measurements are preserved. VF 1 means scalable **s1**.

Evaluation queries benchmark/measurement counts from the DB and uses the same
fixed scoring formula for every ID. It verifies selections and compares ordinary
LLVM using matching benchmark and VF populations. Measurements enter regret and
accuracy calculations after scoring. Production scoring never reads cycles or
fits weights.

The initial supported CFG is an innermost single-block loop. Unsupported
candidates remain explicit exclusions. Exact counts and upper bounds are distinct: unknown exact counts
yield a steady-state per-scalar-iteration score. No benchmark is executed and no
measured cycles are changed.

The [2026-10-23 search reevaluation](utils/vplan-tools/results/basic-calibrated-2026-10-23/summary.json)
attempted 203 benchmarks: 189 evaluated, 14 excluded, 843 candidates, and 189
verified compiler replays. Mean regret is 4.671%, exact VF accuracy 90/189
(47.619%), and worst regret 55.064%. This includes the search calibration cases
and does not establish independent generalization. See the tools guide for the
seven improved selections, one regression, and the fdtd-2d slowdown.

See the [tools guide](utils/vplan-tools/README.md) for commands, manual calibration
freedom, artifacts and tests; [hardware evidence](utils/vplan-tools/rules/README.md)
for fixed rules and limitations; [compiler contract](VPLAN_RA.md) for observation
and replay; and [report guide](PRINT_VPLANS.md) for interpreting costs.
[LLVM's original README](LLVM_README.md) describes the upstream project.
