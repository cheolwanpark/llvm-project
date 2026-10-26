# MIR cost model and meta-compiler

This repository selects RISC-V vectorization candidates using their generated MIR.
LLVM materializes each VPlan and records machine instructions; a Python model
scores the candidates; the meta-compiler asks LLVM to compile the selected plan.
The target is XiangShan Kunminghu v2 MinimalConfig, VLEN=128.

모델의 목적, 가정과 한계는 [MODEL.md](MODEL.md)에 정리되어 있다.

외부 wrapper 없이 LLVM vectorizer 내부에서 VF 후보의 backend 관찰값을 받는
선택적 연구 경로는 [BACKEND_FEEDBACK.md](BACKEND_FEEDBACK.md)에 정리되어 있다.
`-mllvm -enable-vplan-backend-cost-model` 하나로 활성화하며, 비용은
`TTI body − estimated vector spill + observed vector spill`이다. Scalar spill 추정은
유지한다. XiangShan Kunminghu/확정 VLEN=128에서는 후보 throughput 조회에만
[고정 TTI profile](TTI_PROFILE.md)을 적용한다. 다른 RISC-V/RVV에서는 native TTI를
사용한다. 기본값은 OFF이며 외부 Python/meta-compiler 경로와 중첩하지 않는다.
In-process probe는 RVV allocator와 부분 `VirtRegRewriter` 직후 spill 전용
collector에서 종료한다. VSETVLI·scalar RA·frame lowering은 실행하지 않으며,
전체 MIR 대신 소유권 있는 spill 구조체와 비용·gate 요약을 전달한다. 필요한 후보가
실패하면 원본 loop 전체를 native 선택으로 복귀시키고 post-frame 재질의는 하지 않는다.
Scalar spill의 실제 관측까지 필요해지면 종료 지점을 더 뒤로 옮겨야 한다.
Timing은 단계별 중첩 total을 중복 합산하지 않으며 일반 컴파일 측정과 분리한다.
[새 검증 결과](RVV_SPILL_PROBE_VALIDATION.md)는 저장된 기준 자료와 313개 DB를
비교한다. [이전 검증 결과](BACKEND_COST_MODEL_VALIDATION.md)의 203개 DB 결과와
구분한다. 외부 MIR/Python 경로는 유지하며 `utils/`의 새 요약 호환성은 범위 밖이다.

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

For an application-only Release build, tests can be disabled. This separate build
directory keeps the regression build available:

```sh
cmake -S llvm -B .cache/build-spec -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_PROJECTS="clang;lld" \
  -DLLVM_TARGETS_TO_BUILD="X86;RISCV" \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF

cmake --build .cache/build-spec --parallel 8
```

On ARM64, replace `X86;RISCV` with `AArch64;RISCV` in the configure commands.
For only the required application/loop tools, the last command can instead be:

```sh
cmake --build .cache/build-spec --target clang clang-resource-headers lld opt \
  llvm-nm llvm-objdump llvm-extract llvm-dis --parallel 8
```

For the VPlan experiments and compiler regression tests, use the existing
`.cache/compiler-build` directory with assertions and LLVM tests enabled.
The Python experiment tools require assertions or `LLVM_ENABLE_DUMP=ON` for VPlan
reporting; the application-only configuration above does not enable that reporting.

```sh
uv sync --locked --project utils/vplan-tools

cmake -S llvm -B .cache/compiler-build -G Ninja \
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

cmake --build .cache/compiler-build --target clang clang-resource-headers lld \
  opt llvm-nm llvm-objdump llvm-extract llvm-dis llc FileCheck split-file not \
  --parallel 8
```

When adding the host backend to an existing RISCV-only build, append
`-U LLVM_DEFAULT_TARGET_TRIPLE` to the configure command once. This clears a
possibly empty cached default and lets CMake select the host triple. Confirm it
with `bin/clang -dumpmachine`, and list compiled backends with `bin/llc --version`.
Choose the parallel job count to fit available memory; the regression configuration
above limits concurrent links to one.

The experiment commands below reuse this build with `--build-dir .cache/compiler-build
--skip-build`. After C++ changes, rebuild before using `--skip-build`.
Alternatively, omit `--skip-build` to let the tools configure/build the compiler;
without `--build-dir`, they use `build-vplan-tools`. That automatic configuration
is a minimal RISCV-only experiment build; use the explicit configuration above
for the complete application toolchain.

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
  --build-dir .cache/compiler-build --skip-build \
  --benchmark hpcc/stream-add --artifacts-dir .cache/stream-add --detail --replay
```

Inspect instruction-to-class expansions, per-port demands, bottlenecks, fixed
additions and the chosen VF. `--replay` also verifies the final compiler selection.
Raw MIR, observations, compiler commands and replay manifests stay in the artifact
directory. [PRINT_VPLANS.md](PRINT_VPLANS.md) explains the report fields.

### 2. Evaluate the model against LLVM

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate \
  --build-dir .cache/compiler-build --skip-build \
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
  --clang .cache/compiler-build/bin/clang --input kernel.c \
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
PYTHONPATH=utils/vplan-tools VPLAN_CLANG="$PWD/.cache/compiler-build/bin/clang" \
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
  --build-dir .cache/compiler-build --skip-build --aggregation=sum --window=disabled \
  --output-dir .cache/sum-evaluation
```
