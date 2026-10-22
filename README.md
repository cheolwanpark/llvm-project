# MIR local interaction cost model

This LLVM fork observes post-register-allocation RISC-V MIR, scores local
instruction interactions in Python, and replays the selected vector candidate.

```text
op cost = basic + forward-window stall - backward-window ILP
body cost = sum(op cost)
```

Scores are effects in model units. Decoder work comes from XiangShan Kunminghu v2
**MinimalConfig**, pinned to revision `e7bab53e66dfb3c4a1d11cf9519b0396f8576cae`.
The model uses one hardcoded set of machine parameters for all benchmarks and VFs.
Manual calibration and later formula changes happen in
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
accuracy calculations after scoring. They never configure or change the model.

The initial supported CFG is an innermost single-block loop. Unknown dependency
or resource overlap earns no ILP credit. Unsupported candidates remain explicit
exclusions. Exact counts and upper bounds are distinct: unknown exact counts
yield a steady-state per-scalar-iteration score. No benchmark is executed and no
measured cycles are changed.

See the [tools guide](utils/vplan-tools/README.md) for commands, manual calibration
freedom, artifacts and tests; [hardware evidence](utils/vplan-tools/rules/README.md)
for fixed rules and limitations; [compiler contract](VPLAN_RA.md) for observation
and replay; and [report guide](PRINT_VPLANS.md) for interpreting costs.
[LLVM's original README](LLVM_README.md) describes the upstream project.
