# Backend-aware VPlan cost tools

Use Linux or macOS with [uv](https://docs.astral.sh/uv/), CMake 3.20+, Ninja, and a
host C/C++ compiler. `utils/vplan-tools` is an independent Python 3.12 uv project.
Supply an external `dataset.sqlite`; databases are not committed.

## Build and evaluate

```sh
uv sync --locked --project utils/vplan-tools

# Optional explicit build; the tools also configure/build automatically.
cmake -S llvm -B build-vplan-tools -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_ASSERTIONS=ON \
  -DLLVM_ENABLE_PROJECTS=clang -DLLVM_TARGETS_TO_BUILD=RISCV \
  -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_PARALLEL_LINK_JOBS=1 \
  -DCLANG_INCLUDE_TESTS=OFF -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
  -DCLANG_ENABLE_OBJC_REWRITER=OFF
cmake --build build-vplan-tools --parallel 2 \
  --target clang clang-resource-headers llvm-extract

cp /path/to/dataset.sqlite ./dataset.sqlite
cd utils/vplan-tools
uv run python split-dataset --check
uv run python evaluate --json-output /tmp/llvm-validation.json --exclude-reasons
uv run python print-vplans --benchmark lcals/first-diff --detail
```

`print-vplan` is an alias for `print-vplans`; use an ID in your database. Sources
and recorded C/C++ flags come from the new dataset schema. The tools isolate
`selected_kernel` from preparation functions and compile without running target
benchmarks or changing measured cycles.

## Calibrate and evaluate weights

```sh
# Run from utils/vplan-tools.
uv run python split-dataset  # one-time audited 31 tuning / 174 validation split
uv run python calibrate --output /tmp/weights.json
uv run python evaluate-weights --weights /tmp/weights.json \
  --json-output /tmp/fitted-validation.json --exclude-reasons
```

`calibrate` reads tuning only. Both evaluation tools read validation only and have
no split override. `evaluate` uses default Python costs; `evaluate-weights` uses fitted
coefficients in the same model. Fitting preserves the hard-max analytical structure, learns 19
shared internal coefficient multipliers with weighted pairwise ranking, and
excludes measured pairs within 1%. Learned coefficients are not installed into
LLVM; the meta compiler accepts `--weights` and sends only selected IDs to LLVM. Unsupported or ambiguous observations are reported as exclusions; the
usable population may be smaller than the partition.

Database precedence is **`--db PATH` > `VPLAN_DB` > checkout/dataset.sqlite**.
`--llvm-path` selects another compiler checkout without changing the default DB.
Old schemas are unsupported; `results.sqlite.old` is an archive only.

```sh
VPLAN_DB=/path/to/dataset.sqlite uv run python evaluate
uv run python evaluate --db /path/to/dataset.sqlite
# From any repository-root shell:
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate
```

Common options include `--benchmark ID`, `--build-dir`, `--llvm-path`, `--jobs`
(default 2), `--timeout` (120 seconds per invocation), and `--artifacts-dir` on
evaluation/calibration commands. Printing supports `--detail`. Printing and
evaluation support `--compiler-mode meta|direct`; calibration always uses raw
post-RA analytics. O2/O3 options are preserved.

See the [tools guide](utils/vplan-tools/README.md) for the database contract,
model, fitting options, metrics, caching, exclusions and tests;
[VPLAN_RA.md](VPLAN_RA.md) for compiler interfaces; and
[LLVM's original README](LLVM_README.md) for general LLVM guidance.
