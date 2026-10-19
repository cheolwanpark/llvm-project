# VPlan tools

These tools compile embedded kernels and compare cost rankings with measured
scalable VFs. They do not execute benchmarks, update measurements, or install
learned coefficients into LLVM. Cost values are model units, not predicted CPU
cycles.

## Setup and commands

Use Linux or macOS, [uv](https://docs.astral.sh/uv/), CMake 3.20+, Ninja, and a host
C/C++ compiler. This directory is an independent uv project, pinned to Python
3.12 with a committed `uv.lock`. PyTorch uses CPU wheels on Linux and the normal
macOS wheel; fitting always uses CPU float64.

From the repository root:

```sh
uv sync --locked --project utils/vplan-tools
cd utils/vplan-tools
uv run python split-dataset --check
uv run python calibrate --output /tmp/weights.json
uv run python evaluate --json-output /tmp/llvm-validation.json --exclude-reasons
uv run python evaluate-weights --weights /tmp/weights.json \
  --json-output /tmp/fitted-validation.json --exclude-reasons
uv run python print-vplans --benchmark lcals/first-diff --detail
uv run python print-vplan --benchmark lcals/first-diff
```

`print-vplan` aliases `print-vplans`. Printing requires an exact benchmark ID and
can inspect either partition. Both evaluation commands accept one optional
`--benchmark`, but only in **validation**. `calibrate` accepts one optional ID,
but only in **tuning**. There is no `--split` override. Partition and ID filters
are applied in SQL before sources and measurements are read or compiled.

To run without changing directory:

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate
```

## Database contract and audited split

Only the `dataset.sqlite` schema is supported:

| Table | Columns |
| --- | --- |
| `dataset` | `id=1`, `target`, `measurement_compiler`, `measurement_protocol_json` |
| `benchmarks` | `id`, `split`, `source`, `compile_args_json`, `workload_json` |
| `measurements` | `benchmark_id`, `vf`, `cycles` |

Metadata is one row; the protocol and workload are JSON objects, and compile
arguments are a JSON array of strings. VF and cycles are positive integers, with
one representative measurement per benchmark/VF. The supplied protocol already
specifies how representative samples were selected; there is no run-history
query or fastest-run selection. **VF 1 means scalable s1, not scalar f1.** The
schema has no LMUL column; VF must not be relabeled as LMUL.

The database is opened read-only in a transaction. Missing files, wrong schemas,
invalid selected data, and absent IDs fail before building. Old `summary.sqlite`
and `results.sqlite` schemas are intentionally unsupported. `results.sqlite.old`
is an archive, never a fallback.

Database precedence is **`--db PATH` > `VPLAN_DB` > checkout/dataset.sqlite**.
Unset or empty `VPLAN_DB` uses the default. The checkout containing these tools
determines the default even with another working directory or `--llvm-path`.
Explicit relative paths use the caller's working directory; `~` is expanded.

The checked-in `dataset-split.json` records all 205 IDs and source hashes,
75 source families, and the reasons for selecting or holding out each family.
It assigns 31 benchmarks / 136 measurements to tuning and 174 / 723 to validation.
Related sizes, partial/full kernels, and known duplicate variants stay together.
Selection used source structure and operation diversity, not measured winners.
Normalized source comparison found no cross-partition pair with similarity ≥0.9;
this is not a proof of semantic independence.

```sh
uv run python split-dataset          # apply the audited split in one transaction
uv run python split-dataset --check  # read-only verification
```

The split command verifies the manifest and existing dataset before changing
only `benchmarks.split`; it rolls back if any other data changes. It is not run
automatically by fitting or evaluation. Compiler exclusions and validation
results never trigger repartitioning. Databases, journals, backups, virtual
environments, and local caches are ignored by Git.

## Compilation and analytics

First use configures/builds `clang`, resource headers, and `llvm-extract` in
`build-vplan-tools`: Release, assertions enabled, RISCV and Clang enabled, with
examples and benchmarks disabled. Existing compatible builds are refreshed and
updated under a build lock. The supplied LLVM checkout must implement VPlan
protocol v2. `--jobs` defaults to 2; `--timeout` defaults to 120 seconds per
compiler invocation. Build progress and diagnostics go to stderr.

Source text is unchanged. Its recorded C/C++ language selects the source suffix.
Target, optimization level, IC, pipelining, and kernel options are preserved;
forced VF/reporting flags and container include paths are removed, and the LMUL
search cap is set to 8. Local diagnostic headers provide the C/C++ declarations
needed by this dataset without linking a RISC-V runtime.

In default `meta` mode, the driver prepares the pre-vectorizer checkpoint,
recursively extracts `selected_kernel` and its callees with constant initializers,
then discovers candidates. Preparation/checksum functions are not independently
costed. Each scalar/vector candidate is observed after RA cleanup. Compiler
analytics limitations remain explicit, including unsupported instructions,
conditional regions, and unprovable iteration mappings.

`evaluate` and printing use LLVM's existing backend costs and final replay.
Their optional `--compiler-mode direct` instead extracts frontend IR and runs
LLVM's ordinary cost policy. Direct mode does not enable backend feedback.
`calibrate` and `evaluate-weights` require meta mode, collect **raw analytics only**,
and never replay Python costs into LLVM. Their scalar tail reference is the same
loop's scalar observation. See [VPLAN_RA.md](../../VPLAN_RA.md) for the protocol.

Analytics are cached under `.cache/analytics` (override with `--cache-dir`). Keys
include source, recorded flags, compiler/extractor binaries, driver/collection
code, and local headers. Cache entries contain no measurements or learned scores.
Changing fitting options reuses the facts. `--artifacts-dir` retains source, IR,
MIR, commands and diagnostics on cache misses; otherwise intermediate files are
temporary. Invalid cache entries report their path instead of silently falling
back. Weight files bind the model and extraction context; refit after changing
that context.

## Continuous analytical model

```text
body = (max(memory, arithmetic, movement, scalar,
            divider, recurrence, load_use) + spill + configuration) / 16
unknown trip count: body / observed_width
scalar tail: body * floor(T/width) + scalar_body/scalar_width * (T % width)
folded tail: body * ceil(T/width)
```

Internal resource calculations, predicate sharing, dependency eligibility,
load/store overlap and hard min/max follow `RISCVVPlanCost.cpp`. Geometry,
register groups and chunks are fixed observations. Python omits InstructionCost's
quarter-unit truncation and saturation; its default floating-point costs can
therefore differ from LLVM costs near quantization boundaries. A trip-count bound
is not asserted to be the actual runtime count. Function-call/counter overhead
and other work outside the selected loop are not modeled.

All learned values are positive multipliers relative to existing coefficients:

| Parameters | Shared meaning |
| --- | --- |
| `memory_unit`, `memory_nonunit`, `memory_mask` | Unit, strided/indexed, and masked service; shared by total/load/store demands |
| `strided_group`, `masked_group` | Existing extra group/predicate penalties |
| `arithmetic_integer`, `arithmetic_fp` | Integer and shared FP/FMA throughput |
| `movement_copy`, `movement_slide` | Copy and shared slide service/group overhead |
| `divider`, `spill`, `configuration` | Existing SEW division ratios, spill policy, active/unused configuration |
| `latency_load`, `latency_fp`, `latency_fma`, `latency_integer`, `latency_multiply` | Load-use latency; FP/FMA also used by recurrence |
| `latency_chunk` | Existing load-use/recurrence chunk service ratio |

Scalar instruction cost stays fixed at 0.5 model units to anchor the scale.
Parameters absent from the observations stay at multiplier 1. Dependency graphs
are compiled into batched max-plus operations once, not rebuilt per fitting step.

## Weighted pairwise fitting

For a faster measured candidate a and slower b, retain the pair only when
`(cycles_b - cycles_a) / cycles_a > pair_threshold`. The inclusive comparison is
exact for integer cycles. Default threshold is **1%**, including exact ties.

```text
weight = min(1, log(cycles_b/cycles_a) / log(weight_saturation))
pair_loss = weight * softplus((log(cost_a) - log(cost_b)) / temperature)
loss = mean_over_loops(mean_over_retained_pairs(pair_loss))
       + regularization * mean(log(multiplier)^2)
```

Loops with no retained pairs do not train the model. Pair averaging divides by
pair count, not by the sum of weights, so near-equal measurements contribute less.
The source dataset has one sample per VF and no variance estimate; 1% is an
explicit experimental choice, not an estimated noise bound.

| CLI option | Default |
| --- | --- |
| `--starts`, `--steps`, `--seed` | 16, 2000, 0 |
| `--learning-rate` | 0.03 |
| `--min-multiplier`, `--max-multiplier` | 0.25, 4 |
| `--temperature`, `--weight-saturation` | 0.1, 1.25 |
| `--pair-threshold`, `--regularization` | 0.01, 0.001 |

Adam operates on log multipliers, projected into the configured bounds. The first
start uses existing coefficients; other starts are log-uniform between 0.5 and 2,
clipped to the configured bounds. Starts are independent rows in one CPU float64
batch. The lowest regularized tuning objective across every start and step is
saved. Validation is never loaded for fitting, early stopping, or weight selection.
No regression, soft-regret, or smooth-max objective is implemented.

`--output` is required. Version 1 JSON stores model version, multipliers, defaults,
fixed parameters, settings, optimizer diagnostics, tuning IDs and fingerprint,
compiler provenance, exclusions, and initial/fitted tuning metrics. It is a plain
JSON file, not a pickle or an LLVM configuration file.

## Evaluation and exclusions

Only measured scalable VFs participate. Multiple usable plans for one VF use the
minimum score. A benchmark is excluded if any measured VF lacks a usable score,
the selected loop is ambiguous, or fewer than two VFs were measured. The Python
path can ignore an unsupported unmeasured VF; LLVM final replay still requires
its complete feedback set and may exclude more benchmarks. Compare eligible ID
sets as well as metrics when comparing the two commands.

| Metric | Definition |
| --- | --- |
| Top-k overlap, k=1,2 | Mean size of predicted/measured top-k intersection divided by k |
| Top-k exact | Fraction with equal predicted/measured top-k sets |
| Spearman mean/median | Pearson correlation of average tied ranks per benchmark |
| Top-1 regret mean/median/p95 | Measured cycles of actual argmin choice / oracle cycles − 1 |

Top-k requires more than k measured VFs. Ties select the smaller VF; Spearman uses
average ranks and excludes constant rankings. p95 uses linear interpolation.
Each benchmark has equal metric weight. Reports include denominators, exclusions,
coverage and the ten largest regrets. `--exclude-reasons` prints individual reasons.

`evaluate --json-output` writes schema version 2 with dataset metadata, validation
metrics, exclusions and exact rational LLVM scores. `evaluate-weights` writes
version 1 with model/weights provenance and floating-point scores (`value`);
its metrics use the same definitions. Each command assesses its own eligible
population. Expected analytics limitations can produce substantial exclusions;
the partition size is not a claim of usable fitting/evaluation coverage.

LLVM evaluation retains its existing exit behavior: 1 for compiler failures or
no eligible benchmarks, even when partial metrics were produced. Fitting and
weights evaluation report unsupported benchmarks as exclusions and return 0
when a usable result was produced, 1 for invalid configuration or no usable data.
All commands return 130 on interruption.

## Tests

```sh
uv run python -B -m unittest discover -s tests -v
VPLAN_CLANG="$PWD/../../build-vplan-tools/bin/clang" \
  uv run python -B -m unittest discover -s tests -v
```

The ordinary tests need no external database or LLVM build. Optional integration
tests verify extraction, analytics-only operation, backend/default formula
agreement, and the original O2/O3 feedback pipeline.
