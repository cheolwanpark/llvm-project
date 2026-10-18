# Backend-aware VPlan cost tools

## Build and evaluate

Use Linux or macOS with Python 3.10+ (`python3`), CMake 3.20+, Ninja, and a host
C/C++ compiler. Supply an external database using the existing `summary.sqlite`
schema; databases are not included in this repository.

```sh
git clone --depth 1 --single-branch \
  --branch backend-aware-vector-cost \
  https://github.com/cheolwanpark/llvm-project.git
cd llvm-project

cmake -S llvm -B build-vplan-tools -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_ASSERTIONS=ON \
  -DLLVM_ENABLE_PROJECTS=clang \
  -DLLVM_TARGETS_TO_BUILD=RISCV \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_PARALLEL_LINK_JOBS=1 \
  -DCLANG_INCLUDE_TESTS=OFF \
  -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
  -DCLANG_ENABLE_OBJC_REWRITER=OFF

cmake --build build-vplan-tools --parallel 2 \
  --target clang clang-resource-headers

# Supply a database using the existing summary.sqlite schema.
cp /path/to/results.sqlite ./results.sqlite

utils/vplan-tools/evaluate
utils/vplan-tools/print-vplans --benchmark tsvc-s000-l00 --detail
```

`tsvc-s000-l00` is an example ID from the existing database; use an ID from your
database. If you skip the explicit build, the tools configure and build LLVM
automatically. They compile kernels for comparison without running benchmarks
or updating measured cycles.

Database precedence is **`--db PATH` > `VPLAN_DB` > `results.sqlite` at the
checkout containing the tools**. An unset or empty `VPLAN_DB` uses the default;
`--llvm-path` does not change it. For example:

```sh
VPLAN_DB=/path/to/results.sqlite utils/vplan-tools/evaluate
utils/vplan-tools/evaluate --db /path/to/results.sqlite
```

See the [tools guide](utils/vplan-tools/README.md) for the database contract,
metrics, and artifacts, and [LLVM's original README](LLVM_README.md) for general
LLVM guidance.

The meta pipeline supports non-LTO RISCV64 `-O2` and `-O3`; it preserves the selected
optimization level through preparation, probes and final compilation.

## Flags

`print-vplan` is an alias for `print-vplans`. Explicit relative paths use the
current working directory; paths also expand `~`.

| Tool option | Commands | Usage |
| --- | --- | --- |
| `--benchmark ID` | Both | Evaluate one ID (default: all); required for printing. |
| `--detail` | Print only | Include detailed VPlan cost calculations. |
| `--db PATH` / `VPLAN_DB` | Both | Select the external summary database. |
| `--build-dir PATH` | Both | Build directory; default: selected LLVM checkout's `build-vplan-tools`. |
| `--llvm-path PATH` | Both | LLVM source checkout; default: checkout containing these tools. |
| `--jobs N` | Both | Build parallelism; default 2, with one link job in fresh builds. |
| `--timeout SECONDS` | Both | Per compiler invocation, including each probe; default 120. |
| `--split all\|tuning\|validation` | Evaluate only | Select a split; default `all`. |
| `--json-output PATH` | Evaluate only | Save metrics and exact rational VF costs. |
| `--artifacts-dir PATH` | Evaluate only | Save reports and backend artifacts; tuning reports include details. |
| `--exclude-reasons` | Evaluate only | List excluded benchmarks and reasons. |
| `--compiler-mode meta\|direct` | Both | Default `meta` runs the backend analytics/cost feedback pipeline; `direct` compares existing costs. |

Pass LLVM options to clang with `-mllvm` before each option. The reporting flags
alone do not enable the Post-RA model; the default meta evaluation path generates
the required feedback.

| LLVM option | Usage |
| --- | --- |
| `-mllvm -print-vplans` | Print VPlan cost reports. |
| `-mllvm -print-detailed-vplans` | Include detailed calculations. |
| `-vplan-pipeline=prepare\|resume` | Meta-compiler: create or resume the pre-vectorizer checkpoint. |
| `-vplan-candidates-output=PATH` | Meta-compiler: write candidate and selection JSON. |
| `-vplan-ra-run-id=DIGEST` | Meta-compiler: bind artifacts to a run identity. |
| `-vplan-probe-candidate=ID` | Meta-compiler: probe one generated plan/VF. |
| `-vplan-analytics-output=PATH` | Meta-compiler: dump cost-independent backend observations. |
| `-vplan-ra-feedback=PATH` | Meta-compiler: provide observations for final costing. |
| `-vplan-cost-output=PATH` | Meta-compiler: write backend-computed scores. |
| `-stop-after=riscv-vplan-cost` | Stop after analytics and costing, and emit MIR. |

See [VPLAN_RA.md](VPLAN_RA.md#compiler-interfaces) for the compiler interfaces and
manual invocation details.
