# MIR port-demand cost model and meta-compiler

This repository selects RISC-V vectorization candidates using their generated MIR.
LLVM materializes each VPlan and records machine instructions; a Python model
scores the candidates; the meta-compiler asks LLVM to compile the selected plan.
The target is XiangShan Kunminghu v2 MinimalConfig, VLEN=128.

## Cost model

The current `mir-port-aware-v1` model expands MIR instructions and LMUL/SEW geometry
into RTL-grounded uop classes, maps each class to possible execution ports, and
splits its demand equally across those ports:

```text
u[c] = total issued demand for uop class c
port_demand[p] = sum(u[c] / len(possible_ports[c]) for c executable on p)
port_load[p] = port_demand[p] / capacity[p]
body_cost = max(port_load) or sum(port_load)
score = body_scale * body_iterations * body_cost + configuration + setup_configuration + scalar_tail
```

Only **max and sum** are supported; the default is **max, body scale 1**.
The port model replaces class weights and the separate memory-request R term.
Memory instructions, spills/reloads and I2V/F2V transfers still contribute uop
work. Iteration, configuration, setup and scalar-tail accounting is unchanged.

[hardware_model.py](utils/vplan-tools/hardware_model.py) defines reusable dataclasses.
[kunminghu_v2.py](utils/vplan-tools/kunminghu_v2.py) contains all target mappings,
expansion rules, capacities and evidence, pinned to RTL revision
`e7bab53e66dfb3c4a1d11cf9519b0396f8576cae`.
All port capacities currently use an explicit **1 uop/cycle assumption**.
Unverified mappings use a visible UNKNOWN port. Equal sharing does not model
dynamic scheduling, dependency latency, cache behavior or sustainable FU service
rates; scores are demand proxies rather than predicted CPU cycles.

## LLVM passes and the meta-compiler

[utils/vplan-meta-compile](utils/vplan-meta-compile) is a Python driver that
coordinates multiple compiler invocations. Hardware rules and scoring live in
Python; the LLVM changes expose candidates, observe MIR and replay explicit choices.

| Component | Role |
|---|---|
| Pipeline prepare/resume | `-vplan-pipeline=prepare` saves a checkpoint immediately before loop vectorization; `resume` continues from that checkpoint. |
| Loop-vectorizer candidate discovery/probing | Records deterministic candidate IDs and loop/VF context, then materializes a requested VPlan with interleave count 1 and no separate vector epilogue. |
| `riscv-vplan-analytics` | Passively records post-frame-lowering MIR, including lowered spills and stack-address instructions. It runs before the second scheduler and final RVV pseudo expansion, and does not rewrite MIR. |
| Python selection and final replay | Scores supported candidates, writes `-vplan-selection-input`, resumes compilation, and checks that the final manifest matches the selected candidates. |

```text
Source → pre-vectorization checkpoint → discover VPlans
                                      → probe each VPlan → MIR observations
                                      → Python cost model → select
                                      → replay selection → object / assembly / LLVM IR
```

The model currently scores innermost single-block loops with a proven scalar
iteration mapping. Unsupported observations remain explicit; the standalone
driver uses scalar fallback when no scalable candidate is supported. Compiler
observations and replay use protocol 4. See [VPLAN_RA.md](VPLAN_RA.md) for the
complete compiler contract and observation fields.

## Build

Run these commands from the repository root. Prerequisites are Python 3.12+
(managed by `uv`), CMake 3.20+, Ninja and a host C++ compiler.

```sh
uv sync --locked --project utils/vplan-tools

cmake -S llvm -B build-local -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_PROJECTS=clang \
  -DLLVM_TARGETS_TO_BUILD=RISCV \
  -DLLVM_ENABLE_ASSERTIONS=ON \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_PARALLEL_LINK_JOBS=1 \
  -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
  -DCLANG_ENABLE_OBJC_REWRITER=OFF \
  -DCLANG_INCLUDE_TESTS=OFF

cmake --build build-local --target clang clang-resource-headers llvm-extract --parallel 2
```

The experiment commands below reuse this build with `--build-dir build-local
--skip-build`. After C++ changes, rebuild before using `--skip-build`.
Alternatively, omit `--skip-build` to let the tools configure/build the compiler;
without `--build-dir`, they use `build-vplan-tools`.

## Experiments

The default dataset is this checkout's `search-dataset.sqlite`, opened read-only.
Use `--db PATH` to override it; precedence is `--db` > nonempty `VPLAN_DB` > the
default path. The DB supplies benchmark sources, compile flags, workloads and
previously measured cycles. **These commands compile candidates and evaluate
rankings; they do not run new hardware measurements.** VF 1 means scalable s1.
Use fresh output/artifact directories for each run.

### 1. Inspect one benchmark

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/print-vplans \
  --build-dir build-local --skip-build \
  --benchmark hpcc/stream-add --artifacts-dir /tmp/stream-add --detail --replay
```

Inspect instruction-to-class expansions, per-port demands, bottlenecks, fixed
additions and the chosen VF. `--replay` also verifies the final compiler selection.
Raw MIR, observations, compiler commands and replay manifests stay in the artifact
directory. [PRINT_VPLANS.md](PRINT_VPLANS.md) explains the report fields.

### 2. Evaluate max against LLVM

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate \
  --build-dir build-local --skip-build --aggregation max \
  --output-dir /tmp/port-max
```

The default evaluation replays every eligible selection and compares ordinary
LLVM using matching benchmark and VF populations. It writes `summary.json`,
`baseline.json`, candidate `reports/` and `replay/` artifacts. Metrics include
mean/median/p95/worst regret, top-1 accuracy and explicit exclusions.
Measured cycles are used only after selection; scoring does not read them.

### 3. Compare sum using the same saved candidates

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/rescore-evaluation \
  --evaluation /tmp/port-max --aggregation sum --output-dir /tmp/port-sum
```

Rescoring needs neither recompilation nor DB access and preserves the candidate
population and measurements. This is a ranking-only result. For full sum replay,
run `evaluate --aggregation sum` with the same build options and a fresh output
directory instead.

### 4. Analyze body-scale selection intervals

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/analyze-boundaries \
  --evaluation /tmp/port-max --term body_scale --output-dir /tmp/port-max-boundaries
```

Each candidate has an affine score in body scale. The analyzer computes exact
selection intervals for the saved numeric features, including endpoint ties,
instead of sweeping a grid. Each setting's saved b=1 selection is its reference;
a per-benchmark regret increase of 0.15 is a diagnostic, not an acceptance rule.
To try a specific scale, pass `--body-scale 3/2` to evaluation or rescoring.

## Compile your own source without the dataset

Replace `kernel.c` and `selected_kernel` with your source and function name.
The meta-compiler needs no database or measured cycles:

```sh
uv run --project utils/vplan-tools python utils/vplan-meta-compile \
  --clang build-local/bin/clang --input kernel.c \
  --extract-function selected_kernel \
  --work-dir /tmp/kernel-meta --output /tmp/kernel.o --aggregation max -- \
  --target=riscv64-unknown-elf -march=rv64gcv -mcpu=xiangshan-kunminghu \
  -mrvv-vector-bits=128 -O3 -fno-unroll-loops -fno-slp-vectorize \
  -mllvm -scalable-vectorization=always -mllvm -force-vector-interleave=1 \
  -mllvm -enable-epilogue-vectorization=false
```

Use `--emit asm` or `--emit llvm` to change output format.
`--analytics-only --stop-after-ra` collects observations without scoring or final
replay; despite the flag name, the observation stage is post-frame-lowering.

## Validation and results

Run the Python tests, including compiler integration, after building:

```sh
cd utils/vplan-tools
VPLAN_CLANG="$PWD/../../build-local/bin/clang" uv run --locked python -B -m unittest discover -s tests -q
```

The [saved max/sum evaluation](utils/vplan-tools/results/port-aware-v1/README.md)
contains results, assumptions, exact intervals and a rescorable candidate archive.
See the [tools guide](utils/vplan-tools/README.md) for additional commands and
[RTL evidence](utils/vplan-tools/rules/README.md) for mapping verification.
