# Backend-aware VPlan cost tools

Active variant: **backend-aware-cost**, the full Python backend cost model.

`spill-reject` and `spill-aware` are fixed-policy ablation branches derived
directly from this branch. All three share middle-end/backend observations,
protocol v3 and the meta compiler. `--llvm-path` selects that checkout's compiler
and policy together. Cross-validation fitting requires `backend-aware-cost`;
the fixed policies can still be inspected with `print-vplans`.

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
uv run python evaluate --output-dir .cache/cv-seed0
uv run python evaluate-baseline
uv run python print-vplans --benchmark lcals/first-diff --detail
```

`print-vplan` is an alias for `print-vplans`; use an ID in your database. Sources
and recorded C/C++ flags come from the new dataset schema. The tools isolate
`selected_kernel` from preparation functions and compile without running target
benchmarks or changing measured cycles.

## Five-fold cross validation

The current dataset contains **243 benchmarks and 1,685 measurements**, targeting
XiangShan v2 with VLEN 128. All benchmark IDs, including TSVC, participate.
Existing database split labels are retained as metadata only.

`evaluate` is the model fitting/evaluation command. It groups
all measurements of each benchmark ID together, shuffles sorted IDs with a fixed
seed, and assigns them to five folds. Each fold fits fresh weights on the other
four folds and evaluates only its held-out IDs. Related kernels with different
IDs may cross folds; this is benchmark-ID grouping, not source-family grouping.
The database and its existing labels are never changed.

```sh
# From the repository root; output directory must be new or empty.
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate \
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

Fitting learns 19 shared coefficient multipliers while preserving the hard-max
analytical model. Objectives include weighted pairwise ranking (default, excluding
measured pairs within 1%), within-loop centered log-cycle regression and soft regret.
Learned coefficients are not installed into LLVM. Only scalable VFs can be selected;
loops without a scoreable scalable candidate fall back to scalar.

`evaluate-baseline` evaluates ordinary LLVM's final VF selection once per benchmark
over the same full set of IDs as pooled CV evaluation. Each evaluator reports its
own coverage and exclusions. Baseline needs no fitting and prints results to the
terminal; `--benchmark ID` optionally limits it to one diagnostic case.

The old fixed-partition evaluation and tuning commands are removed. The former
CV command is now named `evaluate`, with no old-name alias. Its `--output-dir` is
required; old `evaluate` options such as `--json-output`, `--weights` and
`--benchmark` are unsupported.

Database precedence is **`--db PATH` > `VPLAN_DB` > checkout/dataset.sqlite**.
`--llvm-path` selects another compiler checkout without changing the default DB.

```sh
VPLAN_DB=/path/to/dataset.sqlite uv run python evaluate --output-dir .cache/cv-env
uv run python evaluate --db /path/to/dataset.sqlite --output-dir .cache/cv-explicit
# From any repository-root shell:
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate --output-dir /tmp/vplan-cv
```

Common options include `--build-dir`, `--llvm-path`, `--jobs` (default 2),
`--timeout` (120 seconds per invocation), and `--artifacts-dir` on `evaluate`.
Printing supports `--detail` and `--compiler-mode meta|direct`. CV requires meta
mode; baseline requires direct mode. O2/O3 options are preserved.

See the [tools guide](utils/vplan-tools/README.md) for the database contract,
model, fitting options, metrics, caching, exclusions and tests;
[VPLAN_RA.md](VPLAN_RA.md) for compiler interfaces; and
[LLVM's original README](LLVM_README.md) for general LLVM guidance.
