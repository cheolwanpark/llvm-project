# VPlan tools

These standalone Python 3.10+ commands read isolated kernel source and measured
cycles from an external summary database. They compile kernels without executing
benchmarks or updating measurements. Python uses only the standard library.

```sh
utils/vplan-tools/evaluate
utils/vplan-tools/evaluate --benchmark tsvc-s000-l00
utils/vplan-tools/evaluate --split tuning --exclude-reasons
utils/vplan-tools/evaluate --json-output /tmp/evaluation.json --artifacts-dir /tmp/vplan-reports
utils/vplan-tools/print-vplans --benchmark tsvc-s000-l00 --detail
utils/vplan-tools/print-vplan --benchmark tsvc-s000-l00
```

Use a benchmark ID from your database. `print-vplan` and `print-vplans` invoke
exactly the same implementation. Both require `--benchmark`; `evaluate` accepts
one ID or evaluates all selected benchmarks. Repeated IDs are rejected.

## Options and paths

| Option | Commands | Default / meaning |
| --- | --- | --- |
| `--llvm-path PATH` | All | Checkout containing these tools; must contain `llvm/` and `clang/`. |
| `--db PATH` | All | `VPLAN_DB`, then `results.sqlite` at the checkout containing these tools. |
| `--build-dir PATH` | All | Selected LLVM checkout's `build-vplan-tools`. |
| `--jobs N` | All | 2 parallel build jobs; fresh builds limit linking to one job. |
| `--timeout SECONDS` | All | 120 per compiler invocation, separately for each RA probe. |
| `--compiler-mode meta\|direct` | All | `meta` uses backend feedback; `direct` uses ordinary compilation for cost comparisons. |
| `--benchmark ID` | All | Required for printing; evaluate defaults to all, or accepts exactly one ID. |
| `--detail` | Print | Include detailed cost calculations in the final report. |
| `--split all\|tuning\|validation` | Evaluate | `all`; filter before building. |
| `--exclude-reasons` | Evaluate | List excluded benchmark IDs and reasons. |
| `--json-output PATH` | Evaluate | Save schema version 1 metrics and per-benchmark results. |
| `--artifacts-dir PATH` | Evaluate | Save reports and backend artifacts, with detailed tuning reports. |
| `--help` | All | Show usage without a database or build. |

Database precedence is **`--db` > `VPLAN_DB` > default**. `VPLAN_DB` is read when
arguments are parsed; unset or empty values use the default. An explicit missing
or invalid database fails without fallback. `--llvm-path` changes the compiler
checkout, never the default database. Defaults are derived from the actual module
location, independent of the caller's working directory. Explicit paths expand
`~`, and relative paths resolve against the caller's working directory. Quote
paths containing spaces.

```sh
VPLAN_DB=/path/to/results.sqlite utils/vplan-tools/evaluate
utils/vplan-tools/evaluate --db /path/to/results.sqlite
```

## Database contract

Provide the existing `summary.sqlite` schema under any filename. The newer
`dataset.sqlite` schema is not supported. The tools open SQLite with `mode=ro`
and read a transaction snapshot. A missing database is never created. Missing
schema objects/columns, empty metadata, and unknown benchmark IDs fail before
building. The expected objects and columns are:

| Object | Required columns |
| --- | --- |
| `summary_metadata` | `compiler_revision`, `target_platform` (one metadata row) |
| `benchmarks` | `benchmark_id`, `case_order`, `source_suite`, `benchmark_type`, `compilable_code` |
| `benchmark_vf_summary` | `benchmark_id`, `vf`, `lmul`, `interleave_count`, `software_pipelining`, `llvm_flags_json`, `status`, `measured_cycles` |

Source comes from `benchmarks.compilable_code`; `benchmark_type` identifies the
`tuning` or `validation` split. `llvm_flags_json` is an array of compiler argument
strings. The existing `benchmark_vf_summary` view supplies the latest successful
measurement per variant, including when a newer failed run exists. The evaluator
uses that view rather than choosing the fastest historical run. Keep its selection
semantics when supplying another database. Databases and their journal/WAL/SHM
files are external inputs and must not be committed.

## Building and compilation

Use Linux or macOS, Python 3.10+ available as `python3`, CMake 3.20+, Ninja, and a
host C/C++ compiler. See the [root build instructions](../../README.md#build-and-evaluate).
First use configures Release, assertions ON, Clang, and RISCV, with tests,
examples, benchmarks, the Clang static analyzer, and Objective-C rewriter disabled.
It builds `clang` and `clang-resource-headers`. Reused builds must belong to the
selected source checkout, enable Clang and RISCV, and enable assertions or
`LLVM_ENABLE_DUMP`. Tools refresh the CMake graph and ask the build system to
update dependencies on every invocation; evaluation builds once for all kernels.
Build logs and progress go to stderr. A per-build lock serializes tool-owned
CMake/Ninja operations; direct CMake/Ninja commands do not acquire that lock.

The selected checkout must implement version 2 VPlan reports and both reporting
flags. Meta mode also requires its `utils/vplan-meta-compile` and checkpoint/RA
feedback support. Compiler options preserve the recorded target, CPU,
optimization level, interleave, pipelining, and benchmark-specific settings, with
these adjustments:

- Remove forced VF and existing reporting options to permit ordinary costing.
- Replace the recorded LMUL search limit with `-riscv-v-register-bit-width-lmul=8`
  so larger measured variants can participate.
- Replace container include paths with diagnostic-only `include/stdio.h`,
  `include/stdlib.h`, `include/math.h`, and Clang's resource headers. These provide
  the declarations used by the isolated kernels without a RISC-V sysroot.
  Recorded `SWEEP_KERNEL_ONLY` excludes the harness. Other C library APIs may
  require additional declarations.
- Emit final optimized LLVM IR; no runtime library is linked or target code run.

The embedded source is unchanged. Meta mode prepares a pre-vectorizer checkpoint,
enumerates generated candidates, probes each valid plan/VF through RISC-V vector
and general register allocation, and resumes with collected resource features.
The final report contains the effective Post-RA costs used in main-loop selection.
Unsupported resource observations retain original costs under the model's
fallback rules. Compilation, replay, or feedback transport failures fail the
operation. See [VPLAN_RA.md](../../VPLAN_RA.md) for the model and protocol.
Coefficients are empirical heuristics; costs are model units, not measured CPU
cycles.

Printing writes the final compiler's stderr stream, including reports and
optimization remarks, to stdout. `--detail` adds detailed calculations to that
report. A successfully compiled kernel rejected before planning may have no
report; printing then returns success with a note on stderr.

## Ranking and metric definitions

`evaluate` attempts every selected benchmark and uses the `benchmark_vf_summary` view's
latest successful measurement per variant, even if a newer failed run exists.
It does not select the fastest observed run. Only successfully measured scalable
VFs participate in rankings; scalar `f1` is distinct from scalable `s1`.

Predictions come from `main` candidate-table scores in the report for
`selected_kernel`. For a known trip count, LLVM reports a `whole-loop` score,
which includes vector iterations and any scalar tail. For an unknown trip count,
it reports a `cost-per-lane` score: body cost divided by estimated vector width. These
are model units, not predicted CPU cycles. Fractions preserve exact ties. If
multiple plans support a VF, the minimum comparable score is used. Validation,
epilogue, invalid, and unevaluated placeholder costs are not predictions.

A benchmark is excluded if **any successfully measured VF lacks a usable
prediction**, if its loop report is ambiguous, or if it has fewer than two
successful measurements. Use `--exclude-reasons` to list excluded benchmark IDs
and their reasons, including unsupported report versions and compilation problems.
Available costs are never silently used to
shrink an otherwise measured candidate set.

Top-k metrics are reported for **k=1 and k=2**. A benchmark must have **more
than k** measured VFs. Each metric prints its own contributing benchmark count.

| Metric | Definition |
| --- | --- |
| Top-k overlap | Mean `size(predicted_top_k ∩ measured_top_k) / k`, for k=1–2 |
| Top-k exact | Fraction with equal predicted and measured top-k sets |
| Spearman mean/median | Per-benchmark Pearson correlation of average tied ranks, then mean/median across benchmarks |
| Top-1 regret mean/median/p95 | `measured_cycles(predicted_best) / min(measured_cycles) - 1`; lower is better |

Top-k sets ignore internal ordering. Equal predicted costs and equal measured
cycles use smaller VF first for deterministic selection. Spearman uses average
ranks instead; constant rankings have undefined correlation and are excluded
from its denominator. A zero minimum cycle count makes regret undefined without
invalidating the ranking metrics. p95 uses linear interpolation between sorted
samples. Benchmarks have equal weight, irrespective of runtime or VF count.

Output includes overall and separate tuning/validation summaries, tie counts,
measurement coverage, and the ten benchmarks with the highest top-1 cycle
regret, printed as benchmark IDs and percentages in descending regret order.
Tied regrets sort by benchmark ID. Only selected, scored benchmarks with defined
regret appear; fewer than ten are shown when fewer qualify. If none qualify,
the list displays `N/A`.

Exclusion counts are always shown; the detailed exclusion list appears only
with `--exclude-reasons`. Compiler diagnostics and progress remain on stderr.
Exit status is 0 for a completed
evaluation with at least one scored benchmark, 1 for a build/configuration
failure, any benchmark compilation failure, or no scored benchmarks, and 130
for interruption. Missing measurements or predictions alone do not make a
partially useful evaluation fail.

## JSON and artifacts

`--json-output PATH` writes schema version 1 metadata, summary metrics, and each
benchmark's split, eligibility, exclusion reason, compilation status, measured
cycles, exact rational scores (numerator/denominator), selected VF, and regret.
Undefined statistics are JSON null. This uses the same populations as text output.

`--artifacts-dir PATH` creates the following structure:

```text
PATH/
  tuning/                         # validation/ has the same layout
    BENCHMARK-HASH.txt             # final compiler report; tuning includes details
    BENCHMARK-HASH.ra/
      run-UNIQUE/
        kernel.c
        final.ll
        backend/
          pre-vectorize.bc
          identity.json
          candidates.json
          probe-NNNN.mir           # also JSON, manifests, stdout/stderr
          feedback.json
          final.manifest.json
          final.stderr
          commands.json
          result.json
```

Benchmark filenames are sanitized and hash-suffixed. Each meta invocation creates
its own `run-` directory. Failed invocations may leave partial diagnostic artifacts.
Direct mode retains the source and report but has no backend feedback artifacts.
Use a new artifact directory for each evaluation attempt to keep reports and runs
unambiguous. Without artifacts, temporary source and backend files are removed.
Keep evaluation JSON, reports, logs, and builds outside tracked source paths.

## Tests

```sh
python3 -B -m unittest discover -s utils/vplan-tools/tests -v
```

Tests require no LLVM build or external database. They cover path selection,
read-only database access and latest-successful measurements, build dispatch and
validation, compiler flags, report interpretation, ties, exclusions, failure
handling, and standalone command behavior.
