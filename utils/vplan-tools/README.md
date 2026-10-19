# VPlan tools

These tools compile embedded kernels and compare replayed VF selections with measured
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
uv run python calibrate --output /tmp/weights.json
uv run python evaluate --json-output /tmp/llvm-validation.json --exclude-reasons
uv run python evaluate-weights --weights /tmp/weights.json \
  --json-output /tmp/fitted-validation.json --exclude-reasons
uv run python print-vplans --benchmark lcals/first-diff --detail
uv run python print-vplan --benchmark lcals/first-diff
```

`print-vplan` aliases `print-vplans`. Printing requires an exact benchmark ID and
can inspect either partition. `evaluate` and `evaluate-weights` accept one optional
`--benchmark`, but only in **validation**. `calibrate` accepts one optional ID,
but only in **tuning**. There is no `--split` override. Partition and ID filters
are applied in SQL before sources and measurements are read or compiled.
`evaluate-cv` instead reads all benchmark IDs and uses its own five-fold assignment.

To run without changing directory:

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate
```

## Database contract and current dataset

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

For each benchmark, the current compiler's generated scalable main-loop VF set
defines the fitting/evaluation population. The database must contain every VF in
that set. Extra database VFs are ignored for fitting pairs, winners and all metrics;
they are retained in the database and reported as `ignored_measured_cycles`.
This is a per-benchmark candidate set, not a hard-coded cutoff at VF 16. Failed or
unsupported candidates are not silently removed from the required set. At least
two VFs are needed for fitting/evaluation, and ranking/fitting additionally require
a usable prediction for each VF. Fixed-width VFs are not mapped to scalable VFs.

The database is opened read-only in a transaction. Missing files, wrong schemas,
invalid selected data, and absent IDs fail before building.

Database precedence is **`--db PATH` > `VPLAN_DB` > checkout/dataset.sqlite**.
Unset or empty `VPLAN_DB` uses the default. The checkout containing these tools
determines the default even with another working directory or `--llvm-path`.
Explicit relative paths use the caller's working directory; `~` is expanded.

The current dataset contains **243 benchmark IDs and 1,685 measurements** across
15 suites. Its existing `split` labels are:

| Partition | Benchmarks | Measurements |
| --- | ---: | ---: |
| tuning (TSVC) | 35 | 241 |
| validation | 208 | 1,444 |
| total | 243 | 1,685 |

The measurement target is `xiangshan-v2/MinimalConfig` at RTL revision
`e7bab53e66dfb3c4a1d11cf9519b0396f8576cae`, with VLEN 128 and ELEN 64.
The metadata records measurement compiler Clang 23.1.3. The representative sample
is the latest successful attempt for each benchmark/scalable VF, with positive
integer kernel cycles. There are 238 benchmarks with seven measured VFs, two
with six, one with three, and two with two. Eligibility still depends on the
current compiler's candidate VF set, not the number of database rows alone.

The fixed-partition commands consume these labels as supplied. Cross validation
uses all IDs without updating labels, source, flags, workloads or measurements.
Compiler exclusions and evaluation results never trigger repartitioning.

## Five-fold cross validation

`evaluate-cv` independently fits and evaluates the fittable backend policy on five
folds grouped by **benchmark ID**. Every measured VF and candidate of an ID stays
in the same fold. Different IDs, including related source variants, may appear
on opposite sides of a fold; there is no source-family separation claim.

```sh
# From utils/vplan-tools. Choose a new or empty output directory for each run.
uv run python evaluate-cv --db ../../dataset.sqlite \
  --split-seed 0 --fit-seed 0 --output-dir .cache/cv-seed0

# Numerical cost ranking instead of final selection replay:
uv run python evaluate-cv --metric-mode ranking \
  --split-seed 0 --fit-seed 0 --output-dir .cache/cv-ranking-seed0
```

The command sorts all IDs, shuffles them with a local `random.Random(split_seed)`,
then assigns IDs round-robin to five folds. It freezes assignment before fitting
or checking compiler eligibility. With 243 IDs, held-out sizes are 49/49/49/48/48
and training sizes are 194/194/194/195/195. At least five unique IDs are required.
There is no single-ID filter or database split override for this command.

`--split-seed` and `--fit-seed` both default to 0 and control separate RNGs. Each
fold starts a new optimizer with the same fit seed and initial-state rules.
Only its four training folds determine pairs, active parameters and the winning
training objective. Held-out measurements never select weights or stopping
steps. All fitting settings below, including `--objective`, also apply, except `--fit-seed` replaces
`calibrate`'s `--seed`. Defaults remain 16 starts, 2,000 steps, CPU float64.
Hyperparameters must be fixed before evaluating the held-out folds; this command
does not perform nested CV or choose hyperparameters from the OOF scores.

Selection mode (default) compiles and verifies the final replay with the current
fold's weights. Ranking mode uses the existing numerical metrics and raw
analytics. The measurement-free raw analytics cache is reusable across folds;
replayed selections and learned weights are fold-specific. `--skip-build` reuses
the existing `clang` and `llvm-extract`; otherwise the normal build checks run.
`--artifacts-dir PATH` retains compiler artifacts under fold-specific directories.

Outputs are:

| File | Contents |
| --- | --- |
| `folds.json` | Exact held-out IDs, assignment algorithm, seed, dataset metadata and content fingerprint |
| `fold-N/weights.json` | Existing weights schema 2 plus fold identity, training IDs/fingerprint, fitting diagnostics and exclusions |
| `fold-N/evaluation.json` | Held-out rows, metrics, fold identity and weight hash |
| `fold-N/summary.json` | Training/held-out IDs, status, training exclusions and elapsed time |
| `summary.json` | All OOF rows, pooled metrics, fold statistics, compiler identity and run status |

Fold indices are 0–4. Weight provenance is checked against the exact training IDs,
held-out IDs, dataset fingerprint, assignment and compiler identity before use.
Rows use `split: "held-out"`; `source_split` retains the original database label.
The fingerprint covers source, flags, workloads and measurements, independently
of database split labels. Keep the manifest and recorded Python/PyTorch versions
alongside results to reproduce a run.

Each ID contributes exactly one held-out row, even if it is excluded from scoring.
Pooled OOF metrics give each scored benchmark equal weight; median/p95 are
recomputed from all OOF regrets. Fold statistics separately report the unweighted
mean and **sample standard deviation** (`ddof=1`), with a count of defined folds.
They are not confidence intervals. Ranking mode additionally reports Top-2 and
Spearman metrics. Coverage and exclusion counts always accompany scores.

Unsupported candidates, missing measurements and unscorable selections remain
explicit exclusions; membership is never reshuffled to improve coverage. A fold
with no trainable data, no scoreable held-out data, or a held-out compilation
failure makes the run unsuccessful (exit 1). `complete` means every ID has an OOF
row; `successful` additionally requires every fold to succeed. Reports written
between folds are explicitly partial until the full run finishes. Existing
nonempty output directories are rejected to avoid mixing runs. This produces
five evaluation models; it does not select one fold's weights as a final model.

## Compilation and analytics

First use configures/builds `clang`, resource headers, and `llvm-extract` in
`build-vplan-tools`: Release, assertions enabled, RISCV and Clang enabled, with
examples and benchmarks disabled. Existing compatible builds are refreshed and
updated under a build lock. The supplied LLVM checkout must implement VPlan
protocol v3. `--jobs` defaults to 2; `--timeout` defaults to 120 seconds per
compiler invocation. Build progress and diagnostics go to stderr.

Source text is unchanged. Its recorded C/C++ language selects the source suffix.
Target, optimization level, IC, pipelining, and kernel options are preserved;
forced VF/reporting flags and container include paths are removed, and the LMUL
search cap is set to 8. Local diagnostic headers provide the C/C++ declarations
needed by this dataset without linking a RISC-V runtime.

In default `meta` mode, the driver prepares the pre-vectorizer checkpoint,
recursively extracts `selected_kernel` and its callees with constant initializers,
then discovers candidates. Preparation/checksum functions are not independently
costed. Each vector candidate is observed after RA cleanup. Compiler
analytics limitations remain explicit, including unsupported instructions,
conditional regions, and unprovable iteration mappings.

`evaluate`, `evaluate-weights`, and `calibrate` share observation formats and the
checkout's policy interface. Default evaluation verifies final replay before
scoring its selected VF. `print-vplans` and its alias show policy scores or
acceptance/rejection reasons and selections; `--detail` adds ordinary VPlan diagnostics.
Printing accepts `--weights PATH` for a fittable policy. `--compiler-mode direct` uses ordinary LLVM
costs and the text report parser; meta mode uses structured JSON only.

Scalar tail cost comes from the manifest's middle-end scalar iteration cost.
No scalar probe is collected. It may be unavailable when the formula has no tail
term: unknown trip bound, folded tail, or both positive exact count and upper
bound divisible by the verified width. An upper bound alone does not prove an
empty actual tail. Missing required scalar cost excludes that candidate explicitly.
Candidates must agree on run, function/loop, CPU, VLEN and trip-count context.
See [VPLAN_RA.md](../../VPLAN_RA.md) for the protocol and final compilation usage.

Calibration and backend `--metric-mode ranking` cache analytics under
`.cache/analytics` (override with `--cache-dir`). Default selection evaluation
runs the full driver and does not reuse a raw-only cache as evidence of replay. Keys
include source, recorded flags, compiler/extractor binaries, driver/collection
code, and local headers. Cache entries contain no measurements or learned scores.
Changing fitting options reuses the facts. `--artifacts-dir` retains source, IR,
MIR, commands and diagnostics (on cache misses for cached commands); otherwise intermediate files are
temporary. Invalid cache entries report their path instead of silently falling
back. Weight files bind the model and extraction context; refit after changing
that context.

## Continuous analytical model

```text
body = (max(memory, arithmetic, movement, scalar,
            divider, recurrence, load_use) + spill + configuration) / 16
unknown trip count: body / observed_width
scalar tail: body * floor(T/width) + tail_scale * middle_end_scalar_cost * (T % width)
folded tail: body * ceil(T/width)
```

`cost_model.py` implements resource calculations, predicate sharing, dependency
eligibility, load/store overlap and hard min/max. Geometry and register groups
are fixed observations. Scores use continuous float64 arithmetic. A trip-count
bound is not asserted to be the actual runtime count. One-time initialization,
guards, exits and other work outside the selected loop are excluded.

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

## Training objectives

`calibrate` and `evaluate-cv` accept `--objective
weighted-pairwise|log-cycle-regression|soft-regret`. The default is
`weighted-pairwise`. All three use the existing 19-parameter hard-min/max model,
positive bounded multipliers and identical optimizer settings. Multiple usable
plans for one VF contribute their minimum predicted cost. Every training loop
has equal weight.

Use the existing commands with the desired objective, for example from
`utils/vplan-tools`:

```sh
uv run python calibrate --objective log-cycle-regression --output /tmp/regression-weights.json
uv run python calibrate --objective soft-regret --temperature 0.1 --output /tmp/regret-weights.json
uv run python evaluate-weights --weights /tmp/regret-weights.json --metric-mode ranking
uv run python evaluate-cv --objective soft-regret --temperature 0.1 \
  --output-dir .cache/cv-soft-regret
```

Use `--objective weighted-pairwise` or omit `--objective` for the original loss.
Evaluation reads the saved weights and does not need an objective option.

### Weighted pairwise

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
| `--min-tail-scale`, `--max-tail-scale` | 1/64, 64 |
| `--temperature`, `--weight-saturation` | 0.1, 1.25 |
| `--pair-threshold`, `--regularization` | 0.01, 0.001 |

Adam operates on log multipliers, projected into the configured bounds. The first
start uses existing coefficients; other starts are log-uniform between 0.5 and 2,
clipped to the configured bounds. Starts are independent rows in one CPU float64
batch. The lowest regularized tuning objective across every start and step is
saved. Validation is never loaded for fitting, early stopping, or weight selection.
The hard min/max model is used for every objective; there is no smooth-max approximation.

### Relative log-cycle regression

`--objective log-cycle-regression` means **within-loop centered log MSE**:

```text
predicted = log(cost) - mean_over_vfs(log(cost))
measured  = log(cycles) - mean_over_vfs(log(cycles))
loss = mean_over_loops(mean_over_vfs((predicted - measured)^2))
       + regularization * mean(log(multiplier)^2)
```

Centering removes each loop's multiplicative scale difference between model units
and whole-kernel cycle measurements. This fits relative VF cycle differences and
does not calibrate absolute CPU cycles. Additive overhead in measurements is not
removed by centering. `temperature`, `pair-threshold`, and `weight-saturation`
do not affect this objective.

### Soft regret

`--objective soft-regret` uses the measured oracle-relative cost of each VF:

```text
p = softmax_over_vfs(-log(cost) / temperature)
regret = cycles / min_over_vfs(cycles) - 1
loss = mean_over_loops(sum_over_vfs(p * regret))
       + regularization * mean(log(multiplier)^2)
```

Softmax is evaluated stably. `--temperature` defaults to 0.1 and must be positive.
Pair threshold and saturation do not affect soft regret. Both new objectives
include otherwise eligible loops whose VF differences are at most 1%; pairwise
continues excluding loops with no retained pairs. Thus actual training populations
can differ, and the weights artifacts record their counts and exclusions.
Evaluation always uses the hard argmin VF or verified final choice, never the
soft expected training regret.

`--output` is required. Version 2 JSON stores model version, multipliers, defaults,
fixed parameters, settings, optimizer diagnostics, tuning IDs and fingerprint,
compiler provenance, exclusions, and initial/fitted tuning metrics. It also records
`objective_id`, `formulation`, `settings.objective`, and `ignored_settings`. The
model version and weights schema remain unchanged; existing weight files remain
readable, subject to the existing compiler/extraction provenance checks. It is a plain
JSON file, not a pickle or an LLVM configuration file.

## Evaluation and exclusions

`evaluate-baseline` evaluates the ordinary LLVM middle-end vectorizer's
actual selected VF using the direct compilation pipeline. It reads
`selected-for-main` and the final transformation outcome, rather than inferring
selection from the lowest printed cost. Late vectorization rejections, missing
reports, multiple loops, fixed/scalar selections and measurement gaps are explicit
exclusions. Measurements require IC=1 and no vector epilogue. The compiler VF
subset rule above also applies. This evaluates selections against existing DB
measurements; it does not execute the generated binaries.

```sh
uv run python evaluate-baseline --db ../../dataset.sqlite --skip-build
```

`--skip-build` reuses `build-vplan-tools/bin/clang` and `llvm-extract` without
running CMake/Ninja. The command prints coverage, Top-1 accuracy, mean/median/p95
regret, exclusion counts, the highest regrets and evaluation time directly to the
terminal. Progress and individual exclusion reasons go to stderr. There are no
result-file output options; compilation uses temporary files that are cleaned up.

The default `--metric-mode selection` selects from all generated candidates before
joining to measurements. Top-1 exact compares the replayed VF with the measured
winner within the compiler's scalable VF set (smaller VF breaks measured ties).
Regret is its measured cycles divided by the best measured cycles in that set,
minus one. Missing measurements for any compiler VF, scalar or fixed VF choices,
VLEN mismatches, multiple-loop kernels and compilation failures remain explicit
exclusions. At least two compiler scalable VFs with measurements are required. Unavailable alternative
candidate costs do not exclude a successfully replayed, measured choice.
Results use schema 3 and include the policy identity, actual choice, coverage,
exclusions and metrics, without fabricated candidate rankings.

`--metric-mode ranking` is available for numerical policies. Only the compiler's
scalable VF set participates in this diagnostic, with full measurement coverage
required. Multiple usable plans for one VF use the minimum score. A benchmark is
excluded if any compiler VF lacks a measurement or usable score, the selected
loop is ambiguous, or the set has fewer than two VFs. Extra database VFs do not
invalidate the ranking. Final compilation selects each loop
independently; function-level aggregation for dataset evaluation is not implemented.

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

Ranking commands write schema 2 with provenance, scores, metrics and exclusions.
Default and fitted selection evaluation use the same replay/coverage rules.
Direct evaluation retains rational LLVM report scores. No eligible benchmarks,
invalid configuration, or a compilation failure returns 1; completed successful evaluation returns 0.
All commands return 130 on interruption.

`tail_scale` is the nineteenth positive multiplier and has its own search bounds.
It defaults to 1 and stays fixed when no nonzero tail term is observed. Body
multipliers retain [0.25, 4] bounds. Scores and diagnostic breakdown come from the
same code. Model `rvv-python-19-v3`, weights schema 2 and cache bundle v4 reject
older artifacts; recollect and refit without automatic conversion.

## Ablation branches and common comparison

`backend-aware-cost` is the parent and the only fittable variant. `spill-reject`
and `spill-aware` branch directly from the same common compiler/tools commit.
Each checkout's `selection_policy.py` implements candidate evaluation and loop
selection plus capability declarations. The common driver, projection, tail
formula, dataset partition and CLI implementation are identical across branches.
`--llvm-path` chooses the target checkout's policy as well as its compiler;
the default database still belongs to the invoking checkout.

`spill-reject` accepts complete zero-vector-spill scalable candidates and chooses
the largest VF, ignoring GPR/FPR traffic. It does not require a valid middle-end
cost or invent a ranking. `spill-aware` replaces only the pressure-policy spill
term with TTI-priced observed transfers. Its `--spill-count-unit` defaults to
`instruction`; `register` multiplies vector transfers by their register group.
Incomplete spill facts or needed TTI units use the old estimate, but unproven
iteration mappings and failed probes are excluded. Both policies use v3 replay,
IC=1 and no separate vector epilogue; neither compares vector profitability with
scalar execution. They reject fitting/weights requests as fixed ablations.

Run `evaluate --llvm-path CHECKOUT --artifacts-dir RESULTS/VARIANT
--json-output RESULTS/VARIANT.json` separately for each variant, using the same
database. The three names are `backend-aware-cost`, `spill-reject`, and
`spill-aware`. Then run:

```sh
uv run python compare-vf-selection RESULTS
```

The comparison audits saved v3 replay artifacts, policy identities, common
candidate contexts, measurements and splits. It reports metrics on the common
scoreable cohort and retains individual coverage and every exclusion.
Compilation failures are rejected unless `--allow-compile-failures` is explicitly
supplied; such a comparison is marked partial. These metrics use existing
measurements, not execution timings of the newly generated code.

## Tests

```sh
uv run python -B -m unittest discover -s tests -v
VPLAN_CLANG="$PWD/../../build-vplan-tools/bin/clang" \
  uv run python -B -m unittest discover -s tests -v
```

The ordinary tests need no external database or LLVM build. Optional integration
tests verify extraction, analytics-only operation, backend/default formula
agreement, and the original O2/O3 feedback pipeline.

Objective tests cover centered-log scale invariance, expected-regret values,
temperature limits, padded loop averaging, gradients, bounds and near-tie
eligibility.

CV tests additionally cover deterministic ID grouping, training/held-out
separation, held-out measurement isolation, per-fold replay weights, pooled
quantiles, failure reporting and read-only database access.
