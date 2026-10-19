# Backend-aware VPlan cost tools

Active variant: **backend-aware-cost**, the full Python backend cost model.

`spill-reject` and `spill-aware` are fixed-policy ablation branches derived
directly from this branch. All three share middle-end/backend observations,
protocol v3, the meta compiler and tools; only the Python selection policy and
its tests/documentation differ. `--llvm-path` selects that checkout's compiler
and policy together.

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
uv run python calibrate --output /tmp/weights.json
uv run python evaluate-weights --weights /tmp/weights.json \
  --json-output /tmp/fitted-validation.json --exclude-reasons
```

`calibrate` reads tuning only. `evaluate` and `evaluate-weights` read validation only and have
no split override. Evaluation defaults to Top-1/regret of the final replayed VF;
`--metric-mode ranking` retains cost-ranking diagnostics. `evaluate` uses default Python costs; `evaluate-weights` uses fitted
coefficients in the same model. Fitting preserves the hard-max analytical structure, learns 19
shared internal coefficient multipliers with selectable weighted pairwise ranking,
within-loop centered log-cycle regression, or soft regret. Pairwise remains the
default and excludes measured pairs within 1%. Learned coefficients are not installed into
LLVM; the meta compiler accepts `--weights` and sends only selected IDs to LLVM. Unsupported or ambiguous observations are reported as exclusions; the
usable population may be smaller than the partition.

## Five-fold cross validation

The current dataset contains **243 benchmarks and 1,685 measurements**, targeting
XiangShan v2 with VLEN 128. Its existing labels are 35 tuning benchmarks (TSVC,
241 measurements) and 208 validation benchmarks (1,444 measurements).

`evaluate-cv` is an independent alternative to that fixed partition. It groups
all measurements of each benchmark ID together, shuffles sorted IDs with a fixed
seed, and assigns them to five folds. Each fold fits fresh weights on the other
four folds and evaluates only its held-out IDs. Related kernels with different
IDs may cross folds; this is benchmark-ID grouping, not source-family grouping.
The database and its existing labels are never changed.

```sh
# From the repository root; output directory must be new or empty.
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate-cv \
  --split-seed 0 --fit-seed 0 --output-dir utils/vplan-tools/.cache/cv-seed0
```

The held-out sizes are 49/49/49/48/48. Default evaluation verifies the final
replayed selection; `--metric-mode ranking` runs numerical ranking diagnostics.
`--objective` selects the training loss.
Fitting defaults remain 16 starts and 2,000 steps per fold. `--skip-build` reuses
existing compiler binaries. Results include `folds.json`, per-fold weights and
metrics, and `summary.json` with pooled out-of-fold (OOF) metrics and fold
mean/sample standard deviation. See the [CV guide](utils/vplan-tools/README.md#five-fold-cross-validation)
for reproducibility, exclusions and output details.

Fitting and weights are supported only on `backend-aware-cost`. On `spill-aware`,
`--spill-count-unit instruction|register` selects the existing TTI spill counting
rule (default `instruction`). `spill-reject` has neither weights nor a numerical
cost ranking. See the tools guide for a common-cohort comparison of all variants.

Database precedence is **`--db PATH` > `VPLAN_DB` > checkout/dataset.sqlite**.
`--llvm-path` selects another compiler checkout without changing the default DB.

```sh
VPLAN_DB=/path/to/dataset.sqlite uv run python evaluate
uv run python evaluate --db /path/to/dataset.sqlite
# From any repository-root shell:
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate
```

Common options include `--build-dir`, `--llvm-path`, `--jobs` (default 2),
`--timeout` (120 seconds per invocation), and `--artifacts-dir` on
evaluation/calibration commands. Fixed-partition commands also accept
`--benchmark ID`. Printing supports `--detail`. Printing and
evaluation support `--compiler-mode meta|direct`; calibration always uses raw
post-RA analytics. O2/O3 options are preserved.

See the [tools guide](utils/vplan-tools/README.md) for the database contract,
model, fitting options, metrics, caching, exclusions and tests;
[VPLAN_RA.md](VPLAN_RA.md) for compiler interfaces; and
[LLVM's original README](LLVM_README.md) for general LLVM guidance.
