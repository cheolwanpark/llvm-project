# RISC-V backend-aware vectorization

This LLVM fork adds in-process VPlan VF selection using TTI costs, observed scalar/vector
spills, and optional MIR body pricing. Enable it with `-vplan-backend`;
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
| `-vplan-backend-prune-cfg=false` | Compatibility option; CFG reduction is disabled |
| `-vplan-backend-probe-threads=N` | Positive main-probe worker limit; 1 |
| `-vplan-backend-force-all` | Bypass candidate cost pruning; OFF |
| `-vplan-backend-jsonl=FILE` | Append passive candidate, selection and grouped failure diagnostics |
| `-print-vplans` / `-print-detailed-vplans` | Summary / detailed cost report |
| `-vplan-backend-time` | Serial probe/cost timing diagnostics |
| `-vplan-backend-pruning-trace` / `-vplan-backend-pruning-dump-ir` | CFG diagnostics / private probe IR |

Only the master flag enables the model. Use a fresh JSONL destination. Cost
printing requires assertions or `LLVM_ENABLE_DUMP`; enabling both print flags
produces one detailed report per original loop. Reports describe the effective
model after fallback, not merely the requested flags.

## Body/spill ablations

| Additional flags | Cost | Model ID |
|---|---|---|
| `-use-estimated-spill` | Native TTI `L` | `llvm-v1` |
| none | Native TTI with observed total spill `L-Et+Ot` | `llvm-real-spill-v2` |
| `-use-mir -use-estimated-spill` | MIR with native estimated spill `R-S+Et` | `mir-me-spill-v2` |
| `-use-mir` | MIR with observed spill `R-S+Ot` | `mir-v2` |

All modes use native RISC-V TTI. `-use-default-tti` has been removed.
TTI estimated mode does not query the backend. MIR and TTI observed modes share
one original-loop VF1/IC1 scalar observation per attempt.

TTI and MIR retain different body and scalar-baseline representations. Both
observed modes collect scalar/vector spill-slot accesses at post-frame-lowering
and price each physical register at one unit per store or reload. TTI observed
adds the original scalar loop's observed spill to its scalar IR baseline.
See the [backend contract](BACKEND_FEEDBACK.md#bodyspill-ablation과-mir-info).

## Targets

XiangShan Kunminghu128 and Saturn GEN/Shuttle256 use the same native TTI and
Generic MIRInfo implementation. Actual ISA, VLEN, DLEN and native tuning remain
inputs; the CPU is not replaced by a generic CPU. K1's dedicated pricing profile
is also removed, while upstream CPU/codegen support remains.

[MIR price specification](costsheet/generic_mirinfo.md) defines the new model;
`costsheet/` retains the former tuning evidence and source snapshots.

```sh
.cache/build/bin/clang --target=riscv64-unknown-elf -march=rv64gcv \
  -mtune=saturn-shuttle-v256d128 -mrvv-vector-bits=256 -O3 \
  -mllvm -vplan-backend kernel.c -S -o .cache/saturn.s
.cache/build/bin/clang --target=riscv64-unknown-elf -mcpu=spacemit-x60 \
  -mrvv-vector-bits=256 -O3 -mllvm -vplan-backend kernel.c -S -o .cache/k1.s
```

## Probe pruning

Pressure-gate skipping and private CFG reduction are disabled for common
post-frame observation. Strict cost lower-bound pruning remains active for
compatible main candidates with disabled vector epilogues and unforced VFs.
Force-all bypasses this candidate pruning; TTI estimated still needs no probe.

Observed costs sum the current natural-loop blocks, including branch alternatives
and inner helper loops. Independently tracked iterations are normalized by their
own widths and combined with equal weights. See
[mapping and normalization](BACKEND_FEEDBACK.md#backedge-loop-mapping) for finite
body exclusions and supported transformation rules.

Parallelism is bounded within one compiler process. Workers own cloned IR,
analyses and target machines; pricing and selection stay on the compiler thread.
Scalar and automatic epilogue probes remain serial. Incompatible diagnostics
force serial execution and report the reason. Required failures trigger
[whole-loop fallback](BACKEND_FEEDBACK.md#probe와-fallback).

## Build and verification

The common external builder forwards CPU, tuning, ABI and code model to opt's
probe TargetMachine.
When no CLI code model is given, opt honors the module's Code Model flag, as llc
does, so a medany executable is also observed with the Medium code model.

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
.cache/build/unittests/IR/IRTests --gtest_filter='LoopBackedge.*'
.cache/build/unittests/Transforms/Vectorize/VectorizeTests --gtest_filter='VPlanBackendPricing.*:VPlanBackendExecution.*:BackendGate.*'
.cache/build/unittests/Target/RISCV/RISCVTests --gtest_filter='RISCVBackendPricing.*:RISCVBackendObservation.*'
.cache/build/bin/llvm-lit -j 1 -v \
  llvm/test/Transforms/LoopVectorize/RISCV/backend-pipeline.ll \
  llvm/test/Transforms/LoopVectorize/RISCV/backend-scopes.ll \
  llvm/test/Transforms/LoopVectorize/RISCV/backend-selection.ll \
  llvm/test/Transforms/LoopVectorize/RISCV/backend-execution.ll
```

The shared lit driver checks cost equations and meaningful observation/selection
fields. Unit checks cover exact arithmetic, native target routing, current-loop scope,
independent iteration widths and observation stages, inline asm argument pricing,
matrix configuration/geometry, raw reuse, cancellation and
injected whole-loop failures. Native report arithmetic/path regressions remain
separate from these backend checks.

Scale additional checks to the change. Run PassManager tests only for relevant
pass-manager changes; do not run the full LLVM suite by default. Opt-only checks
separate private feedback from normal final code generation.

## Experiments and retained data

`~/scripts/gen-cost-model-sweep.sh` builds the four modes from the current binaries
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
