# RISC-V backend-aware vectorization

This LLVM fork adds in-process VPlan VF selection using TTI costs, observed RVV
vector spills, and optional MIR body pricing. Enable it with `-vplan-backend`;
the default remains native LLVM selection. Native IC selection, probe
optimization, and final code generation retain upstream policy.

[Backend contract](BACKEND_FEEDBACK.md) describes ownership, observations,
selection and fallback. [Pricing rules](costsheet/rule.md) define units and
conversions. [Repository guide](AGENTS.md) covers development and retained data.

## Usage

Clang requires `-mllvm` before each LLVM option; opt accepts options directly.
The compiler does not provide a RISC-V libc or sysroot.

```sh
.cache/build/bin/clang --target=riscv64-unknown-elf -march=rv64gcv \
  -mcpu=xiangshan-kunminghu -mrvv-vector-bits=128 -O3 \
  -mllvm -vplan-backend -mllvm -print-detailed-vplans \
  kernel.c -S -o .cache/kernel.s
```

| Option | Behavior and default |
|---|---|
| `-vplan-backend` | Enable selection; OFF |
| `-use-mir` | Observe and price scalar/vector MIR bodies; OFF |
| `-use-estimated-spill` | Use TTI spill estimates; OFF |
| `-use-default-tti` | Select native comparison TTI independently of MIR sheet; OFF |
| `-vplan-backend-prune-cfg=false` | Disable private vector-spill CFG reduction; normally ON |
| `-vplan-backend-probe-threads=N` | Positive main-probe worker limit; 1 |
| `-vplan-backend-force-all` | Query real-spill candidates despite gate/pruning; OFF |
| `-vplan-backend-jsonl=FILE` | Append passive candidate/fallback diagnostics |
| `-print-vplans` / `-print-detailed-vplans` | Summary / detailed cost report |
| `-vplan-backend-time` | Serial probe/cost timing diagnostics |
| `-vplan-backend-pruning-trace` / `-vplan-backend-pruning-dump-ir` | CFG diagnostics / private probe IR |

Only the master flag enables the model. Use a fresh JSONL destination. Cost
printing requires assertions or `LLVM_ENABLE_DUMP`; enabling both print flags
produces one detailed report per original loop. Reports describe the effective
model after fallback, not merely the requested flags.

## Body/spill ablations

| Additional flags | Cost source | Model ID |
|---|---|---|
| none | Selected TTI body, observed vector spills | `tti-real-vector-spill-v1` |
| `-use-estimated-spill` | Selected TTI estimates | `tti-v1` |
| `-use-default-tti` | Native TTI body, observed vector spills | `llvm-real-vector-spill-v1` |
| `-use-default-tti -use-estimated-spill` | Native TTI estimates | `llvm-v1` |
| `-use-mir` | Observed MIR body | `mir-v1` |
| `-use-mir -use-estimated-spill` | MIR body with selected TTI spill estimates | `mir-me-spill-v1` |

Both MIR modes also accept `-use-default-tti`. It selects both scalar/vector
estimated spill terms, without changing the CPU-selected MIR sheet or successful
pure-MIR selection. TTI estimated modes do not query the backend. MIR shares one
original-loop VF1/IC1 scalar observation per attempt.

These modes differ in scalar baseline and spill coverage as well as body
representation. TTI real-spill replaces only estimated vector spills; it retains
scalar spill estimates inside vector bodies. TTI scalar baselines retain LLVM's
IR-cost policy without a separate pressure-spill term. MIR prices scalar and
vector spill-slot accesses inside both bodies. The exact formulas and comparison
limits are in the [backend contract](BACKEND_FEEDBACK.md#bodyspill-ablation과-mir-info).

## Targets

| Effective tune CPU | Exact VLEN | Prices and evidence |
|---|---|---|
| `xiangshan-kunminghu` | 128 | [XiangShan](costsheet/xiangshan.md) |
| `saturn-shuttle-v256d128` (tune-only) | 256 | [Saturn GEN/Shuttle](costsheet/saturn.md) |
| `spacemit-x60` | 256 | [K1](costsheet/k1.md) |

Other CPU/VLEN settings use native RISC-V TTI and generic MIR prices. Functions
without RVV retain native TTI. Saturn and K1 use native TTI even with their named
profiles. Their MIR prices are native-relative models, not measured cycles.

```sh
.cache/build/bin/clang --target=riscv64-unknown-elf -march=rv64gcv \
  -mtune=saturn-shuttle-v256d128 -mrvv-vector-bits=256 -O3 \
  -mllvm -vplan-backend kernel.c -S -o .cache/saturn.s
.cache/build/bin/clang --target=riscv64-unknown-elf -mcpu=spacemit-x60 \
  -mrvv-vector-bits=256 -O3 -mllvm -vplan-backend kernel.c -S -o .cache/k1.s
```

## Probe pruning

Gate and strict lower-bound pruning reduce candidate queries; CFG reduction
changes the private probe's code context. These are separate policies. CFG
reduction never applies to MIR. Candidate pruning requires compatible main
candidates, disabled vector epilogues and unforced VFs. Force-all bypasses the
gate and candidate pruning while leaving the CFG switch independent.

Observed costs sum related machine blocks, including branch alternatives and
mixed-origin code. See [mapping and normalization](BACKEND_FEEDBACK.md#related-block-mapping)
for scope limits and supported loop transformations.

Parallelism is bounded within one compiler process. Workers own cloned IR,
analyses and target machines; pricing and selection stay on the compiler thread.
Scalar and automatic epilogue probes remain serial. Incompatible diagnostics
force serial execution and report the reason. Required failures trigger
[whole-loop fallback](BACKEND_FEEDBACK.md#probe와-fallback).

## Build and verification

Reuse the Release/assertions/tests-enabled `.cache/build` and preserve
`.cache/compiler-build -> build`. Reconfigure an existing cache through that
compatibility alias. Use `.cache/build` directly only for a fresh configuration:

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

Build only affected targets, with two jobs:

```sh
cmake --build .cache/build --target clang clang-resource-headers opt llc \
  FileCheck split-file not count llvm-readobj IRTests VectorizeTests RISCVTests --parallel 2
```

Focused backend contract checks:

```sh
.cache/build/unittests/IR/IRTests --gtest_filter='RelatedBlock.*'
.cache/build/unittests/Transforms/Vectorize/VectorizeTests --gtest_filter='VPlanBackendPricing.*:VPlanBackendExecution.*:BackendGate.*'
.cache/build/unittests/Target/RISCV/RISCVTests --gtest_filter='RISCVBackendPricing.*:RISCVBackendSheets.*:RISCVBackendObservation.*'
.cache/build/bin/llvm-lit -j 1 -v \
  llvm/test/Transforms/LoopVectorize/RISCV/backend-pipeline.ll \
  llvm/test/Transforms/LoopVectorize/RISCV/backend-scopes.ll \
  llvm/test/Transforms/LoopVectorize/RISCV/backend-selection.ll \
  llvm/test/Transforms/LoopVectorize/RISCV/backend-execution.ll
```

The shared lit driver checks cost equations and meaningful observation/selection
fields. Unit checks cover exact arithmetic, target profiles, block ancestry,
independent mapping/normalization boundaries, raw reuse, cancellation and injected
whole-loop failures. Native
report arithmetic/path regressions remain separate from these backend checks.

Scale additional checks to the change. Run PassManager tests only for relevant
pass-manager changes; do not run the full LLVM suite by default. Opt-only checks
separate private feedback from normal final code generation.

## Experiments and retained data

`~/scripts/gen-cost-model-sweep.sh` builds the six modes from the current binaries
without rebuilding LLVM. Use `--llvm` to specify binaries and a new `--out`
directory. Sweeps preserve IC1, LMUL8 and disabled vector epilogues; `k1-linux`
selects K1 VLEN256. Identical execution images may cause ELF publication to be
omitted, as recorded in the sweep metadata. The `llvm` variant is master-ON
native-TTI estimated selection, not master-OFF selection.

Keep outputs under a distinct `.cache/` directory and record compiler hashes,
source bytes and effective flags. Existing results never become current merely
because binaries at their recorded paths were replaced. Reference comparisons
use stored baseline results; follow [the repository guide](AGENTS.md#experiments-and-protected-data).
The `.cache/post-frame-reference` directory is absent in this checkout.
