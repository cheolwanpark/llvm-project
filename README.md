# RISC-V backend-aware vectorization

This repository provides in-process VF selection using TTI costs and observed
vector spills, plus a separate external MIR/Python meta-compiler workflow.
The target profile is XiangShan Kunminghu v2 MinimalConfig, VLEN=128.

Repository working guidelines are in [AGENTS.md](AGENTS.md).

외부 MIR 모델의 목적, 가정과 한계는 [MODEL.md](MODEL.md)에 정리되어 있다.

외부 wrapper 없이 LLVM vectorizer 내부에서 VF 후보의 backend 관찰값을 받는
선택적 연구 경로는 [BACKEND_FEEDBACK.md](BACKEND_FEEDBACK.md)에 정리되어 있다.
`-mllvm -enable-vplan-backend-cost-model` 하나로 활성화하며, 비용은
`TTI body − estimated vector spill + observed vector spill`이다. Scalar spill 추정은
유지한다. XiangShan Kunminghu/확정 VLEN=128에서는 후보 throughput 조회에만
[고정 TTI profile](TTI_PROFILE.md)을 적용한다. 다른 RISC-V/RVV에서는 native TTI를
사용한다. 기본값은 OFF이며 외부 Python/meta-compiler 경로와 중첩하지 않는다.
In-process probe는 `StackSlotColoring` 직후 종료하고 소유권 있는 vector spill
구조체와 비용·gate 요약을 전달한다. VSETVLI와 scalar RA는 실행하며 frame lowering은
실행하지 않는다. 필요한 후보가 실패하면 원본 loop 전체를 native 선택으로 복귀시킨다.
최종 scalar spill을 관측하려면 더 뒤로 진행하고 collector를 확장해야 한다.
[전수 검증 및 세 버전의 시간 비교](BACKEND_COST_MODEL_VALIDATION.md)에 측정 조건과
결과를 기록한다. 외부 MIR/Python 경로는 별도로 유지한다.
재사용할 post-frame 원본 reference는 `.cache/post-frame-reference/`에 보존하며,
그 안의 `reference.py verify`로 입력·측정·MIR·object의 무결성을 확인한다.

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

The standalone driver uses scalar fallback when no scalable candidate is supported. Compiler
observations and replay use protocol 4. See [VPLAN_RA.md](VPLAN_RA.md) for the
complete compiler contract and observation fields.

## Build

Run these commands from the repository root. Prerequisites are Python 3.12+
(managed by `uv`), CMake 3.20+, Ninja and a host C++ compiler.

The application and loop workflows use the following components:

| Purpose | Required components |
|---|---|
| CMake projects | `clang;lld` |
| CPU backends | `X86;RISCV` on an x86-64 host; `AArch64;RISCV` on an ARM64 host |
| Application builds and ELF inspection | `clang`, `clang++`, `opt`, `ld.lld`, `llvm-nm`, `llvm-objdump` |
| Loop extraction and LLVM IR inspection | `llvm-extract`, `llvm-dis` |
| Compiler regression tests below | `llc`, `FileCheck`, `split-file`, `not`, and the requested unit-test targets |

All executables are in the build directory's `bin/`. Building `clang` also
creates `clang++`; building the CMake target `lld` creates `ld.lld`.
The host backend supports native application builds, while `--target=riscv64-unknown-elf`
selects RISC-V. Executable links also need the application's target libraries,
startup objects and linker script where applicable; the LLVM build does not supply
a RISC-V libc/sysroot.

The current compiler is built in `.cache/build`; its `clang`, `opt`
and `llc` executables are in `.cache/build/bin`. Rebuilding updates
those binaries in place and reuses the existing CMake/Ninja cache.
The existing cache was moved intact; `.cache/compiler-build` is a compatibility
symlink to `build` for generated absolute paths. Use `cmake --build .cache/build`
to reuse it; reconfigure that existing cache through `.cache/compiler-build`.
The configuration command below is for a fresh build directory. Use the
Release build with assertions and LLVM tests enabled for VPlan work.
On ARM64, replace `X86;RISCV` with `AArch64;RISCV` below.
The Python experiment tools require assertions or `LLVM_ENABLE_DUMP=ON` for VPlan
reporting. For the external tools, run `uv sync --locked --project utils/vplan-tools`.
This Python/uv setup is not needed for in-process feedback.

```sh
cmake -S llvm -B .cache/build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_PROJECTS="clang;lld" \
  -DLLVM_TARGETS_TO_BUILD="X86;RISCV" \
  -DLLVM_ENABLE_ASSERTIONS=ON \
  -DLLVM_INCLUDE_TESTS=ON \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_PARALLEL_LINK_JOBS=1 \
  -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
  -DCLANG_ENABLE_OBJC_REWRITER=OFF \
  -DCLANG_INCLUDE_TESTS=OFF

cmake --build .cache/build --target clang clang-resource-headers lld \
  opt llvm-nm llvm-objdump llvm-extract llvm-dis llc FileCheck split-file not \
  --parallel 2
```

When adding the host backend to an existing RISCV-only build, append
`-U LLVM_DEFAULT_TARGET_TRIPLE` to the configure command once. This clears a
possibly empty cached default and lets CMake select the host triple. Confirm it
with `bin/clang -dumpmachine`, and list compiled backends with `bin/llc --version`.
Choose the parallel job count to fit available memory; the regression configuration
above limits concurrent links to one.

The experiment commands below reuse this build with `--build-dir .cache/build
--skip-build`. After C++ changes, rebuild before using `--skip-build`.
For a fresh, separate build directory, omit `--skip-build` to let the tools
configure/build the compiler; without `--build-dir`, they use `build-vplan-tools`.
That automatic configuration is a minimal RISCV-only experiment build. For the
relocated cache, keep `--skip-build` and rebuild explicitly as described above.

## Experiments

The default dataset is this checkout's `search-dataset.sqlite`, opened read-only.
Use `--db PATH` to override it; precedence is `--db` > nonempty `VPLAN_DB` > the
default path. The DB supplies benchmark sources, compile flags, workloads and
previously measured cycles. **These commands compile candidates and evaluate
rankings; they do not run new hardware measurements.** VF 1 means scalable s1.
Use fresh output/artifact directories for each run.

Use the project-root `.cache/` for temporary files, MIR observations, reports,
logs and experiment results, including one-off analysis scripts. The default raw
observation cache is `.cache/local-observations/`; disposable tool/test directories
are created under `.cache/tmp/`. Run the examples below from the repository root.
Do not commit generated results or create a separate `results/` tree.

The benchmark population is intentionally not divided into tuning and held-out
evaluation sets. Database `split` labels such as `validation` are historical
metadata; ignore them when choosing the population or interpreting results.
For fixed inputs and simulator configuration, RTL execution is deterministic.
One recorded cycle value per benchmark/VF is therefore intentional; repeated
samples and statistical variance estimates are not required. Preserve the recorded
measurement protocol, compiler revision, workload and target configuration when
comparing results: deterministic execution does not make different binaries or
measurement boundaries equivalent.

### 1. Inspect one benchmark

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/print-vplans \
  --build-dir .cache/build --skip-build \
  --benchmark hpcc/stream-add --artifacts-dir .cache/stream-add --detail --replay
```

Inspect instruction-to-class expansions, per-port demands, bottlenecks, fixed
additions and the chosen VF. `--replay` also verifies the final compiler selection.
Raw MIR, observations, compiler commands and replay manifests stay in the artifact
directory. [PRINT_VPLANS.md](PRINT_VPLANS.md) explains the report fields.

### 2. Evaluate the model against LLVM

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate \
  --build-dir .cache/build --skip-build \
  --output-dir .cache/window-model
```

The default evaluation replays every eligible selection and compares ordinary
LLVM using matching benchmark and VF populations. It writes `summary.json`,
`baseline.json`, candidate `reports/` and `replay/` artifacts. Metrics include
mean/median/p95/worst regret, top-1 accuracy and explicit exclusions.
Measured cycles are used only after selection; scoring does not read them.

### 3. Rescore saved candidates with a different body scale

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/rescore-evaluation \
  --evaluation .cache/window-model --body-scale 3/2 --output-dir .cache/window-scaled
```

Rescoring needs neither recompilation nor DB access and preserves the candidate
population and measurements. It requires matching implementation/datasheet identity
and reports ranking-only status. Older model archives require rescoring from raw
observation bundles with `score-mir`.

### 4. Analyze body-scale selection intervals

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/analyze-boundaries \
  --evaluation .cache/window-model --term body_scale --output-dir .cache/window-model-boundaries
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
  --clang .cache/build/bin/clang --input kernel.c \
  --extract-function selected_kernel \
  --work-dir .cache/kernel-meta --output .cache/kernel.o -- \
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
PYTHONPATH=utils/vplan-tools VPLAN_CLANG="$PWD/.cache/build/bin/clang" \
  uv run --locked --project utils/vplan-tools python -B -m unittest discover -s utils/vplan-tools/tests -q
```

Evaluation results are local artifacts under `.cache/`; they are not committed.
Keep each run in a new directory and compare its recorded model/datasheet identity
before treating it as a baseline for the current implementation.

## Raw observation tools

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/collect --output .cache/population.json
uv run --project utils/vplan-tools python utils/vplan-tools/score-mir \
  --bundle .cache/local-observations/KEY/bundle.json --output .cache/scores.json
```

Raw caches validate compiler/driver/collector identity and MIR/raw JSON checksums.
Full raw MIR and replay artifacts remain outside committed summaries.

## Datasheet verification

[`rules/extract.py`](utils/vplan-tools/rules/extract.py) is an offline verifier for
[`kunminghu_v2.py`](utils/vplan-tools/kunminghu_v2.py). Supply the pinned RTL files
in a flat directory, named as listed in `SOURCE_HASHES`:

```sh
python3 utils/vplan-tools/rules/extract.py /path/to/flat-pinned-rtl-files
```

It checks source hashes, scalar/vector opcode records, fixed FU latency literals
and MinimalConfig ROB capacity. Source URLs and revisions are recorded in the
datasheet. It does not download RTL or generate runtime rules, and scoring does
not invoke it.

The current `mir-uop-demand-v1` model expands MIR into explicit Uops with resource
work and demand per work unit, normalized to ALU II=1. Pipelined work, iterative
division/sqrt, 128-bit memory flows and element memory flows have separate rules.
There are no fitted class weights or calibration profiles. The
`uop-demand-report-v1` report exposes Uops, their resource uses, work/rate evidence,
timing groups and both MAX/SUM port aggregates. Verified decode counts are separate
from nominal work; neither Uop count nor LMUL is multiplied into demand again.
All calculation and ranking use exact fractions. JSON calculation values are
integers or rational strings, with `score` retained as a display float.
Old model reports must be recomputed from raw observations using `score-mir`;
`rescore-evaluation` validates Uop records and changes policy/body scale within a
matching implementation and datasheet. Rescoring is ranking-only until replay.
See [MODEL.md](MODEL.md) for the fixed fast-path assumptions and exclusions.

The default is `--aggregation=max --window=enabled --body-scale=1`.
MAX-only (`--aggregation=max --window=disabled`) and SUM-only
(`--aggregation=sum --window=disabled`) are supported by reporting, scoring,
evaluation and compiler replay. SUM with an enabled window is rejected. For example:

```sh
uv run --locked --project utils/vplan-tools python -B utils/vplan-tools/evaluate \
  --build-dir .cache/build --skip-build --aggregation=sum --window=disabled \
  --output-dir .cache/sum-evaluation
```
