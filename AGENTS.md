# Repository working guide

## Scope and documentation

This LLVM fork provides in-process VF selection. `BACKEND_FEEDBACK.md`
describes its contract, target-specific CostSheets, spill pricing and cost reports; README covers
usage, build and tests.
Preserve existing upstream LLVM options and behavior when cleaning up fork code.

Keep README, BACKEND_FEEDBACK.md and costsheet/ current instead of adding overlapping
reports. costsheet/rule.md owns pricing/conversion rules; target documents own prices and evidence. Distinguish historical measurements from the current binary and describe
retained artifacts accurately.

## Build and cache layout

- Use `.cache/build` for the compiler and its incremental build cache. Current
  executables are `.cache/build/bin/clang`, `opt`, and `llc`.
- Reuse the existing Release/assertions/tests-enabled build (`clang;lld`,
  `X86;RISCV`) with `cmake --build .cache/build ... --parallel 2`.
- `.cache/compiler-build -> build` preserves absolute paths embedded in the
  relocated cache. Keep this compatibility symlink. If reconfiguring that
  existing cache, use the old alias; configure `.cache/build` directly only
  for a fresh build. See README for configuration flags.
- `.cache/post-frame-reference` is retained reference data, not disposable
  scratch space. Do not delete or overwrite it during cache cleanup. Preserve
  the compiler build/cache too unless the user explicitly changes that scope.
- Put new experiment outputs in a distinct `.cache/` directory. Do not commit
  build products, databases, measurements, or force-add ignored cache files.

## Backend feedback invariants

The non-MIR vector-spill probe stops immediately after StackSlotColoring, using
its observer's pass ID (`post-stack-slot-coloring`). It runs VSETVLI insertion and
scalar allocation before subsequent copy propagation, post-RA LICM and frame
lowering. This collector remains vector-spill-only. MIR body observations use the
separate `post-frame-lowering` observer and include scalar/vector spill-slot costs.

Estimated and observed non-MIR spills use profile-independent `SpillReloadUnits`
and the configured aggregate register-class TTI hook. Tuned candidate costs use each target's CostSheet at its documented exact VLEN
(Kunminghu 128, Saturn GEN/Shuttle and K1 256); other RVV CPU/VLEN settings
use the generic MIR sheet and native RISC-V TTI. Observed units are homogeneous
per class, direction and physical register group. Default-TTI selection
also applies to MIR estimated spills, independently of MIR sheet selection.
Scalar baselines, native-cost IC, probe optimization and final codegen stay native.

Preserve the master flag, CPU/VLEN selection, `L - Ev + Sv` / `L` / `R` /
`R - S + Et`, exact rational normalization, gate and main/epilogue policy unless
the task explicitly changes them. Failed required probe candidates retry the
whole original loop with specific TTI estimated costs when raw default-TTI is
false and that profile is supported, then revert to native if unavailable or
unsuccessful. Requested TTI estimated failures go directly native. Never treat
failure as zero spill. Do not add post-frame retries or benchmark-specific
exceptions. Keep reports passive and discard attempted backend reports on
whole-loop native fallback.

## Reference and dataset comparisons

Read `.cache/post-frame-reference/README.md` and use its portable top-level
manifest and `reference.py`. Historical nested manifests/scripts retain old
absolute paths as provenance; they must not be used to execute the current
compiler as though it were the old post-frame compiler.

```sh
python3 -B .cache/post-frame-reference/reference.py verify
```

Use stored post-frame results; do not rerun a baseline compiler. Keep timing
and observation compiler identities separate. Use this checkout's 313-input
`dataset.sqlite` for the documented comparison, not the historical 203-input DB.
Match source bytes, language, effective flags, candidate identity, VF, IC, role,
iteration width, and preceding-loop context. Compare executable/allocated
sections and normalized relocations when debug paths or compiler strings differ.

When a full dataset measurement is requested, run it in a subagent and have the
main agent independently verify raw counts, successes, and averages. Execute one
compiler at a time, alternate OFF/ON, use three repetitions and blocking waits
with a 300-second timeout. Preserve IC=1, disabled vector epilogues, LMUL=8, and
the default gate for comparisons with this reference. Keep diagnostics separate
from ordinary timings; exclude preparation/build/hash work from timers. Historical
timing ratios are not controlled simultaneous speedups. Do not rerun the full
dataset merely for documentation edits.

## Verification

For relevant compiler changes, build and run the affected checks:

```sh
cmake --build .cache/build --target clang clang-resource-headers llc opt \
  FileCheck split-file not count llvm-readobj VectorizeTests RISCVTests IRTests --parallel 2
.cache/build/unittests/Transforms/Vectorize/VectorizeTests
.cache/build/unittests/Target/RISCV/RISCVTests
.cache/build/unittests/IR/IRTests --gtest_filter='PassManager.*:LegacyPassManager.*'
.cache/build/bin/llvm-lit -v llvm/test/Transforms/LoopVectorize \
  llvm/test/CodeGen/RISCV/rvv/stack-slot-coloring.mir
```

Use opt-only probe tests to distinguish the feedback pipeline from normal final
object codegen. Scale verification to the change; do not repeatedly run passed
tests without a new reason. Integrated compiler and reporting tests live in the
LLVM unit/lit suites.
