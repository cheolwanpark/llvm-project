# RISC-V backend-aware vectorization

This LLVM fork selects VPlan vectorization factors using TTI costs and observed
vector spills, with optional MIR body-cost ablations. The model is OFF by default. IC and scalar costs retain native
LLVM policy; a required candidate failure returns the whole loop to native
selection.

- [BACKEND_FEEDBACK.md](BACKEND_FEEDBACK.md): cost model, probe contract, fixed
  XiangShan TTI corrections, and cost-report formats.
- [BACKEND_COST_MODEL_VALIDATION.md](BACKEND_COST_MODEL_VALIDATION.md): dated
  measurements and retained reference data.
- [AGENTS.md](AGENTS.md): repository working and comparison rules.

## Options and usage

| Option | Meaning |
|---|---|
| `-vplan-backend` | Enable backend costs; default false. |
| `-vplan-backend-probe-threads=N` | Bound concurrent main-candidate probes; positive integer, default `1`. |
| `-use-mir` | Use target MIR service demand for the body; default false. |
| `-use-estimated-spill` | Keep TTI estimates, or replace all MIR spill demand with tuned TTI estimates; default false. |
| `-use-default-tti` | Use generic RISC-V TTI in non-MIR modes; ignored with `-use-mir`; default false. |
| `-vplan-backend-force-all` | Query every real-spill candidate; MIR always queries and TTI-only estimates never query. |
| `-vplan-backend-jsonl=FILE` | Append candidate and selection/fallback diagnostics as JSONL. |
| `-vplan-backend-time` | Print probe and cost-preparation timings to stderr. |
| `-print-vplans` | Print costs and selection decisions to stderr. |
| `-print-detailed-vplans` | Also print calculation details. |

Only `-vplan-backend` activates the model. Clang requires `-mllvm` before each
option; opt accepts them directly. Use a fresh JSONL file. Cost reporting
requires assertions or `LLVM_ENABLE_DUMP`; enabling both print options produces
one detailed report per original loop.

```sh
.cache/build/bin/clang --target=riscv64-unknown-elf \
  -march=rv64gcv -mcpu=xiangshan-kunminghu -mrvv-vector-bits=128 -O3 \
  -mllvm -vplan-backend -mllvm -print-detailed-vplans \
  kernel.c -S -o .cache/kernel.s
```

Print reports show native LLVM costs when the model is OFF or falls back, and
exact backend costs when applied. Internal probe clones do not emit cost reports.
The fixed XiangShan profile applies to `xiangshan-kunminghu` with exact VLEN=128;
other RISC-V CPU/VLEN settings use native TTI with actual vector spill costs.

### Body/spill ablations

All three controls require `-vplan-backend`. LLVM accepts both `-use-mir` and
`--use-mir` spellings; Clang requires `-mllvm` before each LLVM option.

| Additional flags | Body cost | Model ID |
|---|---|---|
| none | `Lt - Evt + Svt` | `tti-real-vector-spill-v1` (unchanged default) |
| `-use-estimated-spill` | `Lt` | `tti-v1` |
| `-use-default-tti` | `L0 - Ev0 + Sv0` | `llvm-real-vector-spill-v1` |
| `-use-default-tti -use-estimated-spill` | `L0` | `llvm-v1` |
| `-use-mir` | `R` | `mir-v1` |
| `-use-mir -use-estimated-spill` | `R - S + Et` | `mir-me-spill-v1` |

`L0/Lt` are generic/tuned TTI body costs. `Ev/Sv` are estimated/observed
**vector** spill costs, priced with the selected TTI. `R/S` are the MIR body
and its **scalar and vector** spill service demand; `Et` is the tuned TTI's
**total** estimated spill. MIR demand is normalized by the validated iteration
width before substituting `Et`. `-use-default-tti` has no effect in either MIR
mode, including on `Et`.

MIR uses a separate post-frame-lowering observer, after RISC-V post-RA pseudo
expansion and load/store optimization but before final scheduling/RVV pseudo
expansion. It queries every required candidate even when the vector-spill gate
would skip. TTI-only estimated modes require no backend query. Other modes retain
the existing post-stack-slot-coloring observer and gate.

The first MIR Info implementation supports XiangShan Kunminghu, exact VLEN=128.
Other CPU/VLEN settings fall back to native selection in MIR modes. Its
`rtl-service-sum-v1` rules are ported from `llvm-cost-model`; unsupported opcode
rules have explicit unit demand and are reported as unknown, while invalid
geometry or required observations cause whole-loop native fallback. This is
nominal service demand, not a prediction of CPU cycles. The non-MIR real-spill
models retain their earlier stage, vector-only scope and TTI pricing; they are
not numerically identical to the sibling project's full post-frame models.

```sh
.cache/build/bin/clang --target=riscv64-unknown-elf \
  -march=rv64gcv -mcpu=xiangshan-kunminghu -mrvv-vector-bits=128 -O3 \
  -mllvm -vplan-backend -mllvm -use-mir -mllvm -use-estimated-spill \
  -mllvm -print-detailed-vplans kernel.c -c -o .cache/kernel.o
```

### Parallel probes

With `-mllvm -vplan-backend-probe-threads=4`, independent main-candidate
probes can run on up to four workers. Preparation, spill pricing and selection
stay on the compiler thread. Each batch snapshots the current loop context;
workers use separate LLVM contexts, target machines and analyses. The default
`1` retains the existing serial clone path and stops at the first failure.
Automatic epilogue queries remain serial; forced epilogues remain part of main
probes. Whole-loop native fallback applies to every mode; query eligibility follows
the selected ablation as described above.

```sh
.cache/build/bin/clang --target=riscv64-unknown-elf \
  -march=rv64gcv -mcpu=xiangshan-kunminghu -mrvv-vector-bits=128 -O3 \
  -mllvm -vplan-backend -mllvm -vplan-backend-probe-threads=4 \
  kernel.c -c -o .cache/kernel.o
```

The limit applies to probes inside one compiler process. It does not parallelize
application builds or translation units. Empty batches do no backend work, and
a single query stays on the compiler thread. Tasks finish before results are
applied in candidate order; a failed required candidate still discards the
whole loop's backend costs.

JSON and both cost-report options support parallel probes. Cost reports combined
with a forced epilogue use the serial path to preserve preparation and reporting
order. `-vplan-backend-time`, upstream debug/pass printing, pass timing/time
tracing, optimization bisection, debug counters, optimization remarks and
register allocator training logs/interactive channels use the serial path.
A warning explains the reason once when more than one main probe is actually
requested. A build without thread support also uses this warning and serial path.
The master flag
must be enabled; zero queries or a single main query do not produce this warning.
Use external process timing for parallel comparisons: `-vplan-backend-time`
retains its serial process-CPU interpretation.

The [dated measurements](BACKEND_COST_MODEL_VALIDATION.md) cover the 313-input
corpus and ten SPEC applications. In those single-run measurements, more workers
reduced time for the small-input corpus but increased time for every SPEC app
relative to worker count `1`.
Worker count remains an explicit choice with a default of `1`; the app timings
use a separate frontend/opt/backend/assemble pipeline. See the
[parallel execution contract](BACKEND_FEEDBACK.md#제한된-probe-병렬-실행) for module
boundaries, ownership and diagnostic compatibility.

## Build

Reuse `.cache/build` for the Release/assertions/tests-enabled build. Keep the
compatibility symlink `.cache/compiler-build -> build`, which preserves paths
embedded in the relocated cache. Reconfigure that cache through the alias;
configure `.cache/build` directly only for a fresh build.

```sh
cmake --build .cache/build --target clang clang-resource-headers llc opt \
  FileCheck split-file not count llvm-config llvm-readobj \
  VectorizeTests RISCVTests --parallel 2
```

Fresh configuration:

```sh
cmake -S llvm -B .cache/build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_PROJECTS="clang;lld" \
  -DLLVM_TARGETS_TO_BUILD="X86;RISCV" \
  -DLLVM_ENABLE_ASSERTIONS=ON -DLLVM_INCLUDE_TESTS=ON \
  -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_PARALLEL_LINK_JOBS=1 \
  -DCLANG_ENABLE_STATIC_ANALYZER=OFF -DCLANG_ENABLE_OBJC_REWRITER=OFF \
  -DCLANG_INCLUDE_TESTS=OFF
```

Use `AArch64;RISCV` on an ARM64 host. The compiler does not supply a RISC-V
libc/sysroot.

## Verification and data

```sh
.cache/build/unittests/Transforms/Vectorize/VectorizeTests
.cache/build/unittests/Target/RISCV/RISCVTests
.cache/build/bin/llvm-lit -v llvm/test/Transforms/LoopVectorize \
  llvm/test/CodeGen/RISCV/rvv/stack-slot-coloring.mir
```

Tests cover exact costs, spill collection, gate decisions, selection, passive
reporting and whole-loop fallback. Parallel tests cover pool overlap and limits,
ordered results, reuse, serial compatibility and 1/2/4-worker equivalence.
Opt-only tests isolate the probe from normal final codegen. Lit marks tests for
backends absent from the build as unsupported.

Keep experiment outputs in a distinct `.cache/` directory. Preserve the compiler
cache and `.cache/post-frame-reference/`. Use this checkout's 313-input
`dataset.sqlite` for requested reference comparisons, following AGENTS.md.
Historical measurements describe their recorded compiler identities, not the
current binary at the same path.
