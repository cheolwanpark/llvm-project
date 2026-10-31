# RISC-V backend-aware vectorization

This LLVM fork selects VPlan vectorization factors using TTI costs and observed
vector spills, with optional MIR body costs. The model is OFF by default.
Candidate scalar/vector operations and estimated spills use the selected TTI.
Scalar baselines, IC selection, probe optimization and final codegen retain native
LLVM policy. A required probe failure retries the whole loop with specific TTI
estimated costs when supported and requested, then falls back to native selection
if that attempt fails.

- [BACKEND_FEEDBACK.md](BACKEND_FEEDBACK.md): cost model, probe contract, shared
  RISC-V CostSheets, and cost-report formats.
- [AGENTS.md](AGENTS.md): repository working and comparison rules.

## Options and usage

| Option | Meaning |
|---|---|
| `-vplan-backend` | Enable backend costs; default false. |
| `-vplan-backend-prune-cfg=false` | Disable CFG reduction for private vector-spill probes (default ON). |
| `-vplan-backend-probe-threads=N` | Bound concurrent main-candidate probes; positive integer, default `1`. |
| `-use-mir` | Use target MIR direct costs for the body; default false. |
| `-use-estimated-spill` | Keep TTI estimates, or replace all MIR spill costs with the selected TTI estimates; default false. |
| `-use-default-tti` | Use default RISC-V TTI for every TTI query, including MIR estimated spills; default false. |
| `-vplan-backend-force-all` | Bypass both the gate and lower-bound pruning for real-spill candidates; MIR always queries and TTI-only estimates never query. |
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

Print reports show the final effective model: native LLVM costs when OFF or after
native fallback, and exact model costs otherwise. Failed attempts are discarded.
Internal probe clones do not emit cost reports.
The effective tuning CPU selects the pricing implementation. Kunminghu with
exact VLEN=128 uses scoped XiangShan TTI and `xiangshan-direct-v1` MIR pricing.
Other RVV CPU/VLEN settings use native RISC-V TTI and
`riscv-generic-direct-v1` MIR pricing. `-use-default-tti` selects native RISC-V TTI
for all candidate TTI calculations, including MIR estimated spills; MIR sheet
selection still follows the CPU/VLEN. Without RVV or the required probe pipeline,
the configured fallback policy applies.

### Body/spill ablations

All three controls require `-vplan-backend`. LLVM accepts both `-use-mir` and
`--use-mir` spellings; Clang requires `-mllvm` before each LLVM option.

| Additional flags | Body cost | Model ID |
|---|---|---|
| none | `Lt - Evt + Svt` | `tti-real-vector-spill-v1` |
| `-use-estimated-spill` | `Lt` | `tti-v1` |
| `-use-default-tti` | `L0 - Ev0 + Sv0` | `llvm-real-vector-spill-v1` |
| `-use-default-tti -use-estimated-spill` | `L0` | `llvm-v1` |
| `-use-mir` | `R` | `mir-v1` |
| `-use-mir -use-estimated-spill` | `R - S + Et` | `mir-me-spill-v1` |

`L0/Lt` are default/profile-selected TTI body costs; without a supported tuned
profile, `Lt` uses native RISC-V TTI. `Ev/Sv` are estimated/observed
**vector** spill costs, priced with the selected TTI. `R/S` are the MIR body
and its **scalar and vector** spill costs; `Et` is the selected TTI's
**total** estimated spill. MIR cost is normalized by the validated iteration
width before substituting `Et`. Either MIR row also accepts `-use-default-tti`:
`R` and `S` keep the CPU-selected sheet while `Et` uses default TTI. The MIR mode
ID stays the same; `tti_profile` records the separate TTI choice. The raw
`use-default-tti` boolean also controls the failure destination.

MIR uses a separate post-frame-lowering observer, after RISC-V post-RA pseudo
expansion and load/store optimization but before final scheduling/RVV pseudo
expansion. It queries every required candidate even when the vector-spill gate
would skip. TTI-only estimated modes require no backend query. Other modes retain
the existing post-stack-slot-coloring observer and gate.

MIR and scoped tuned TTI share `RISCVCostSheet` queries. The effective tune CPU
selects `xiangshan-direct-v1` for Kunminghu with exact VLEN=128; other RVV
CPU/VLEN settings select `riscv-generic-direct-v1` for MIR. Generic geometry uses
the subtarget's minimum VLEN. Default TTI remains the upstream RISC-V TTI.
Unknown opcodes cost 1 and carry an unknown marker; invalid geometry and pricing
fail through the whole-loop policy below. These are nominal direct costs.
The XiangShan opcode rules retain RTL provenance
`e7bab53e66dfb3c4a1d11cf9519b0396f8576cae`, independently of the new model version.

Both estimated and observed vector spills use register-class aggregate pricing
with transferred registers `Q` and accesses `A`. Estimated excess registers `n`
produce `(n,n)` per direction; an observed group `g` produces `(g,1)`.
Default TTI charges `Q` times its inherited class unit. Scoped XiangShan charges
vector `Q+A`, scalar stores `2Q`, and scalar loads `Q`. Thus excess 4 registers
costs 8/16 with default/tuned estimates; a group-4 store and reload costs 8/10.
The observed non-MIR collector remains vector-only. Prices are normalized once
by the exact iteration-width ratio, and invalid prices never become zero.

```sh
.cache/build/bin/clang --target=riscv64-unknown-elf \
  -march=rv64gcv -mcpu=xiangshan-kunminghu -mrvv-vector-bits=128 -O3 \
  -mllvm -vplan-backend -mllvm -use-mir -mllvm -use-estimated-spill \
  -mllvm -print-detailed-vplans kernel.c -c -o .cache/kernel.o
```

### Pruning and fallback

Both TTI real-spill modes use the pruning policy below. Automatic candidate
pruning requires vector epilogues to be disabled.

| Required evaluation fails | Whole-loop destination |
|---|---|
| Real-spill or MIR mode, raw `use-default-tti=false`, specific TTI supported | Specific TTI estimated (`Lt`, including estimated spills), then native if it fails |
| Raw `use-default-tti=true`, including MIR | Native |
| Specific TTI unsupported | Native |
| TTI estimated mode | Native, without retrying estimated |

A scalar/non-vectorized result is a successful evaluation. Each attempt owns its
costs, profitable candidates, epilogue clone and reports; none are reused after
failure. Scalar baselines and IC remain native. The retry does not require MIR
cost sheets or backend observations and does not change global options. Reports
identify requested/effective models and the fallback reason.

### Parallel probes

With `-mllvm -vplan-backend-probe-threads=4`, independent main-candidate
probes can run on up to four workers. Preparation, spill pricing and selection
stay on the compiler thread. Each batch snapshots the current loop context;
workers use separate LLVM contexts, target machines and analyses. Compatible real-spill batches run in stable zero-spill cost order. Completed probes immediately refill free workers and may cooperatively cancel proven losers. Final VF
selection retains the original plan/VF order.
Automatic epilogue queries remain serial; forced epilogues remain part of main
probes. Query eligibility and the fallback destination follow the policies above.

```sh
.cache/build/bin/clang --target=riscv64-unknown-elf \
  -march=rv64gcv -mcpu=xiangshan-kunminghu -mrvv-vector-bits=128 -O3 \
  -mllvm -vplan-backend -mllvm -vplan-backend-probe-threads=4 \
  kernel.c -c -o .cache/kernel.o
```

The limit applies to probes inside one compiler process. It does not parallelize
application builds or translation units. Empty batches do no backend work, and
a single query stays on the compiler thread. All tasks finish and private IR is destroyed before the batch returns or a fallback attempt starts. Results apply in original candidate order; only proven losers may have failures ignored. Physical execution states can vary across workers.

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

Worker count defaults to `1`. See the
[parallel execution contract](BACKEND_FEEDBACK.md#제한된-probe-병렬-실행) for module
boundaries, ownership and diagnostic compatibility.

## Probe pruning

With `-vplan-backend`, private vector-spill probe CFG reduction is enabled by default. MIR observations never apply CFG reduction.
`-vplan-backend-prune-cfg=false` disables only this transformation. After candidate
materialization and before the IR suffix, it retains the observed header's CFG
ancestors and descendants and shortens eligible exclusive paths using existing
return values. ABI, SSA, returns, vector lifetime and surrounding-cycle guards
limit applicability. This is an empirical probe reduction: it does not prove
identical global register allocation for arbitrary programs.

Cost-bound candidate pruning and cooperative cancellation are automatic, with no
separate switch. They apply when vector epilogues are disabled, main/epilogue VFs
are not forced, and all candidates share fixed/scalable and scalar-tail policies.
The latter is an automatic compatibility check, not a user option. Existing
LLVM epilogue defaults are unchanged, so use
`-enable-epilogue-vectorization=false` to satisfy that condition.
`-vplan-backend-force-all` retains its diagnostic meaning and bypasses candidate
pruning/cancellation; the CFG switch still controls probe reduction independently.

Queries run in stable zero-spill cost order. Eligible completed costs, gate-skip
costs and permitted scalar selection bound other queries. Only strictly losing
candidates are removed; ties are measured. Failures of candidates proven to lose do not trigger fallback. A surviving required
failure still discards all backend costs for the loop.

`-vplan-backend-pruning-trace` reports CFG applicability and sizes;
`-vplan-backend-pruning-dump-ir` dumps `before`, `after` and `suffix` stages.
Both are passive. Timing includes `probe_pruning`. JSONL uses `status=pruned`
and `execution=not-started/cancelled/completed`; physical execution states may
vary with scheduling while logical results retain original candidate order.
See [the contract](BACKEND_FEEDBACK.md#probe-pruning) for ownership and failure rules.

The bound applies to default and tuned TTI real-spill modes. MIR modes always
observe required candidates; estimated-only modes do not probe. JSONL includes
body-unit `lower_bound_quarters_*`, normalized `score_lower_bound_quarters_*`,
proof basis, `score_kind`, execution state and requested/effective model IDs.

## Cost-model sweeps

The sibling `~/scripts/gen-cost-model-sweep.sh` defaults to this checkout's
`.cache/build/bin`. New sweeps use the binaries currently at that path. `--llvm`
selects a different bin directory; `--workspace` changes the default checkout
location. The script builds the six modes above and records tool paths, versions
and hashes. It does not rebuild LLVM or update previous sweep outputs.

```sh
~/scripts/gen-cost-model-sweep.sh --target xiangshan \
  --llvm /work/llvm-integration-ablation/.cache/build/bin \
  --out .cache/cost-model-sweep
```

Use a new or empty output directory. The sweep preserves IC=1, LMUL=8 and disabled
vector epilogues. Sweep build concurrency is separate from compiler probe workers.

## Build

Reuse `.cache/build` for the Release/assertions/tests-enabled build. Keep the
compatibility symlink `.cache/compiler-build -> build`, which preserves paths
embedded in the relocated cache. Reconfigure that cache through the alias;
configure `.cache/build` directly only for a fresh build.

```sh
cmake --build .cache/build --target clang clang-resource-headers llc opt \
  FileCheck split-file not count llvm-config llvm-readobj \
  VectorizeTests RISCVTests IRTests --parallel 2
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
.cache/build/unittests/IR/IRTests --gtest_filter='PassManager.*:LegacyPassManager.*'
.cache/build/bin/llvm-lit -v llvm/test/Transforms/LoopVectorize \
  llvm/test/CodeGen/RISCV/rvv/stack-slot-coloring.mir
```

Tests cover direct CostSheet prices and TTI/MIR agreement, effective tune CPU
and VLEN selection, aggregate spill units and asymmetric class hooks, all four
default/tuned × estimated/observed spill combinations, exact normalization,
scalar scope restoration, MIR default-TTI selection, gate/pruning decisions,
epilogue preservation, passive reporting and configured whole-loop retries. Parallel tests cover pool overlap and limits,
ordered results, reuse, serial compatibility and 1/2/4-worker equivalence.
Opt-only tests isolate the probe from normal final codegen. Lit marks tests for
backends absent from the build as unsupported.

Keep experiment outputs in a distinct `.cache/` directory. Preserve the compiler
cache and `.cache/post-frame-reference/`. Use this checkout's 313-input
`dataset.sqlite` for requested reference comparisons, following AGENTS.md.
Historical measurements describe their recorded compiler identities, not the
current binary at the same path.
