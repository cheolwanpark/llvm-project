# RISC-V backend-aware vectorization

This LLVM fork selects VPlan vectorization factors using TTI costs and observed
vector spills, with optional MIR body costs. The model is OFF by default.
TTI modes price scalar baselines with the same TTI as vector candidates. MIR
modes observe both scalar and vector bodies with the same post-frame sheet.
IC selection, probe optimization and final codegen retain native LLVM policy. A
required evaluation failure follows the whole-loop retry policy below.

- [BACKEND_FEEDBACK.md](BACKEND_FEEDBACK.md): cost model, probe contract,
  target-specific RISC-V CostSheets, and cost-report formats.
- [AGENTS.md](AGENTS.md): repository working and comparison rules.

## Options and usage

| Option | Meaning |
|---|---|
| `-vplan-backend` | Enable backend costs; default false. |
| `-vplan-backend-prune-cfg=false` | Disable CFG reduction for private vector-spill probes (default ON). |
| `-vplan-backend-probe-threads=N` | Bound concurrent main-candidate probes; positive integer, default `1`. |
| `-use-mir` | Use target MIR direct costs for the body; default false. |
| `-use-estimated-spill` | Keep TTI estimates, or replace all MIR spill costs with the selected TTI estimates; default false. |
| `-use-default-tti` | Use native TTI for scalar/vector comparison costs in TTI modes and both estimated spill terms in MIR modes; default false. |
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
CPU/VLEN selects the target sheet and scoped TTI:

| Effective tune CPU | Exact VLEN | CostSheet documentation |
|---|---|---|
| `xiangshan-kunminghu` | 128 | [XiangShan](costsheet/xiangshan.md) |
| `saturn-shuttle-v256d128` (tune-only CPU) | 256 | [Saturn](costsheet/saturn.md) |
| `spacemit-x60` | 256 | [K1](costsheet/k1.md) |

K1 uses pricing revision `k1-structural-service-v1`: nominal 128-bit services
and explicit reference algorithms, documented in the [K1 CostSheet](costsheet/k1.md).
Historical scheduler occupancy prices and measurements describe the previous model.

Other CPU/VLEN combinations retain native TTI and generic MIR pricing.
`-use-default-tti` changes TTI selection independently of the MIR sheet.
Pricing units, evidence policy and conversions live in [CostSheet rules](costsheet/rule.md).

```sh
.cache/build/bin/clang --target=riscv64-unknown-elf -march=rv64gcv \
  -mtune=saturn-shuttle-v256d128 -mrvv-vector-bits=256 -O3 \
  -mllvm -vplan-backend kernel.c -S -o .cache/saturn-kernel.s
.cache/build/bin/clang --target=riscv64-unknown-elf -mcpu=spacemit-x60 \
  -mrvv-vector-bits=256 -O3 -mllvm -vplan-backend kernel.c -S -o .cache/k1-kernel.s
```

### Body/spill ablations

All three controls require `-vplan-backend`. LLVM accepts both `-use-mir` and
`--use-mir` spellings; Clang requires `-mllvm` before each LLVM option.

| Additional flags | Cost source | Model ID |
|---|---|---|
| none | Selected TTI body, observed vector spills | `tti-real-vector-spill-v1` |
| `-use-estimated-spill` | Selected TTI estimates | `tti-v1` |
| `-use-default-tti` | Native TTI body, observed vector spills | `llvm-real-vector-spill-v1` |
| `-use-default-tti -use-estimated-spill` | Native TTI estimates | `llvm-v1` |
| `-use-mir` | Observed MIR body | `mir-v1` |
| `-use-mir -use-estimated-spill` | MIR body with selected TTI spill estimates | `mir-me-spill-v1` |

The combination formulas and scalar/vector coverage are specified in
[BACKEND_FEEDBACK.md](BACKEND_FEEDBACK.md#bodyspill-ablation과-mir-info).
For inherited LLVM policies, scalar-loop versus scalar-spill coverage, and the
limits of comparisons between these models, see [ABLATION.md](ABLATION.md).
Either MIR row accepts `-use-default-tti`; the MIR sheet remains CPU-selected.
The flag selects both estimated spill terms in MIR-estimated mode; successful
pure-MIR pricing and selection are unchanged by toggling it. Each MIR attempt
shares one VF1/IC1 scalar observation across the vector candidates and bypasses
the vector-spill gate. TTI-only estimated modes require no backend query.

```sh
.cache/build/bin/clang --target=riscv64-unknown-elf \
  -march=rv64gcv -mcpu=xiangshan-kunminghu -mrvv-vector-bits=128 -O3 \
  -mllvm -vplan-backend -mllvm -use-mir -mllvm -use-estimated-spill \
  -mllvm -print-detailed-vplans kernel.c -c -o .cache/kernel.o
```

### Pruning and fallback

Both TTI real-spill modes use the [pruning policy](#probe-pruning) below.

| Required evaluation fails | Whole-loop destination |
|---|---|
| Real-spill or MIR mode, raw `use-default-tti=false`, specific TTI supported | Specific TTI estimated (`Lt`, including estimated spills), then native if it fails |
| Raw `use-default-tti=true`, including MIR | Native |
| Specific TTI unsupported | Native |
| TTI estimated mode | Native, without retrying estimated |

A scalar/non-vectorized result is a successful evaluation. Each attempt owns its
costs, scalar observations/exact values, profitable candidates, epilogue clone
and reports; none are reused after failure. The retry prices both scalar and
vector code with the supported tuned TTI; IC remains native. It does not require MIR
cost sheets or backend observations and does not change global options. Reports
identify requested/effective models and the fallback reason.

### Parallel probes

With `-mllvm -vplan-backend-probe-threads=4`, independent main-candidate
probes can run on up to four workers. Preparation, pricing and selection stay on
the compiler thread, and selection retains the original plan/VF order. Scalar
baseline and automatic epilogue queries remain serial; forced epilogues remain
part of main probes.

```sh
.cache/build/bin/clang --target=riscv64-unknown-elf \
  -march=rv64gcv -mcpu=xiangshan-kunminghu -mrvv-vector-bits=128 -O3 \
  -mllvm -vplan-backend -mllvm -vplan-backend-probe-threads=4 \
  kernel.c -c -o .cache/kernel.o
```

The limit applies inside one compiler process, independently of application build
concurrency. Worker count defaults to `1`. JSON and cost reports support parallel
probes; incompatible diagnostics use the serial path and warn when they prevent
overlap. See the [parallel execution contract](BACKEND_FEEDBACK.md#제한된-probe-병렬-실행)
for ownership, cancellation and diagnostic compatibility. Use external process
timing for parallel comparisons; `-vplan-backend-time` uses the serial path.

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
observe required candidates; estimated-only modes do not probe.

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
Current verification results and the six-case, three-target diagnostic selections
are recorded in [BACKEND_FEEDBACK](BACKEND_FEEDBACK.md#scalar-기준-통합과-k1-occupancy-v2-검증).
