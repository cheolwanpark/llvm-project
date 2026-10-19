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

For each benchmark, the current compiler's generated scalable main-loop VF set
defines the fitting/evaluation population. The database must contain every VF in
that set. Extra database VFs are ignored for fitting pairs, winners and all metrics;
they are retained in the database and reported as `ignored_measured_cycles`.
This is a per-benchmark candidate set, not a hard-coded cutoff at VF 16. Failed or
unsupported candidates are not silently removed from the required set. At least
two VFs are needed for fitting/evaluation, and ranking/fitting additionally require
a usable prediction for each VF. Fixed-width VFs are not mapped to scalable VFs.

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
| `--min-tail-scale`, `--max-tail-scale` | 1/64, 64 |
| `--temperature`, `--weight-saturation` | 0.1, 1.25 |
| `--pair-threshold`, `--regularization` | 0.01, 0.001 |

Adam operates on log multipliers, projected into the configured bounds. The first
start uses existing coefficients; other starts are log-uniform between 0.5 and 2,
clipped to the configured bounds. Starts are independent rows in one CPU float64
batch. The lowest regularized tuning objective across every start and step is
saved. Validation is never loaded for fitting, early stopping, or weight selection.
No regression, soft-regret, or smooth-max objective is implemented.

`--output` is required. Version 2 JSON stores model version, multipliers, defaults,
fixed parameters, settings, optimizer diagnostics, tuning IDs and fingerprint,
compiler provenance, exclusions, and initial/fitted tuning metrics. It is a plain
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
uv run python evaluate-baseline --db ../../vf-xs-run.sqlite --skip-build
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
supplied; such a comparison is marked partial. These metrics use historical
measurements, not execution timings of the newly generated code.

### Historical coverage verification after the minimal fixes

The following records protocol v2 experiments before the Python selection migration.
They are preserved as historical results, not reruns of the current compiler.

Fresh analytics from the modified Release/assertions compiler, using the audited
205-benchmark dataset and unchanged fitting defaults, give:

| Path | Before fixes | After fixes |
| --- | ---: | ---: |
| Python tuning | 5/31 | 20/31 |
| Python validation | 65/174 | 133/174 |
| LLVM validation | — | 130/174 |

All previously eligible Python benchmarks remain eligible: 15 tuning and 68
validation IDs were recovered. All 786 retained candidate scores across the
153 benchmarks are finite and positive; eight benchmarks use no scalar
reference. Compiler and collector identities changed, and weights were refitted
against the new context. The database and its split were unchanged.

The 15 recovered tuning IDs are:

```text
lcals/energy-calc-l03
media-stats/flac-loose-mid-side-sum-abs
minimd/force-eam-file2array-l630
minimd/force-eam-file2array-l658
minimd/force-eam-file2array-l696
mlas/mlas-dequant8-perchannel
mlas/mlas-dequant8-pertensor
mlas/mlas-linear-query-dk128
mlas/mlas-linear-query-dk512
mlas/mlas-sgemm-4acc
mlas/mlas-sgemm-8acc
rajaperf/gen-lin-recur-forward
rajaperf/gen-lin-recur-reverse
rodinia/rodinia-pathfinder-row
rodinia/rodinia-pathfinder-traverse
```

The 145 tuning pairs reduce the regularized objective from 0.438089 to 0.102186
(start 14, step 1914, zero-based). Coverage gains do not imply better validation
regret:

| Population and model | Top-1 exact | Mean regret | p95 regret | Mean Spearman |
| --- | ---: | ---: | ---: | ---: |
| Tuning 20, default continuous | 45.00% | 11.91% | 51.65% | 0.5727 |
| Tuning 20, fitted | 80.00% | 0.60% | 3.49% | 0.8382 |
| Validation 133, default continuous | 29.32% | 12.73% | 56.52% | 0.5657 |
| Validation 133, fitted | 34.59% | 14.95% | 58.77% | 0.4871 |
| Common validation 130, LLVM | 28.46% | 12.88% | 56.56% | 0.5637 |
| Common validation 130, fitted | 34.62% | 14.33% | 53.19% | 0.4938 |

Python additionally scores `lcals/pressure-calc-l01`,
`media-stats/vtk-ssim-var-covar-u8`, and
`minimd/force-lj-compute-fullneigh-l410`. LLVM's scalar-first cost probes fail
on conditional body blocks for these three. LLVM evaluation wrote its report
and returned 1 with 33 compiler failures and 44 total exclusions.

The remaining Python exclusions are unproved iteration mappings, unsupported
square-root/segment operations, ambiguous multiple loops, the ADI probe
materialization failure, and the unsupported early-exit loop in
`tealeaf/eigenvalue-driver-tqli-l72`. No guards were relaxed to include them.

| Exclusion reported | Tuning | Validation |
| --- | ---: | ---: |
| Iteration mapping | 6 | 11 |
| Square root | 4 | 7 |
| Segment memory | 0 | 10 |
| Multiple loops | 0 | 12 |
| Probe materialization | 0 | 1 |
| Loop shape / early exit | 1 | 0 |

Local artifacts are kept under `.cache/minimal-fixes/`: `weights.json`,
`validation-weights.json`, `validation-llvm.json`, and `verification.json`.
The last file records every recovered ID, exclusions, identity checks, and
metrics on the common validation set. These artifacts and the raw analytics
remain ignored by Git. Reproduce the run with the commands above, passing
`--cache-dir .cache/minimal-fixes/analytics` to the Python cost tools and choosing
output paths under `.cache/minimal-fixes/`.

## Tests

```sh
uv run python -B -m unittest discover -s tests -v
VPLAN_CLANG="$PWD/../../build-vplan-tools/bin/clang" \
  uv run python -B -m unittest discover -s tests -v
```

The ordinary tests need no external database or LLVM build. Optional integration
tests verify extraction, analytics-only operation, backend/default formula
agreement, and the original O2/O3 feedback pipeline.

The minimal-fix verification passed all 87 Python tests with `VPLAN_CLANG` set
and all 25 LLVM lit tests in `llvm/test/CodeGen/RISCV/vplan-ra/` plus the
`vplan-ra-checkpoint.ll`, `vplan-ra-iteration-mapping.ll`, and
`vplan-ra-fixed-vscale.ll` RISCV LoopVectorize tests. The latter exercises a
STREAM-shaped kernel through actual prepare/resume and machine analytics.
