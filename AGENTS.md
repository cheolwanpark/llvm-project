# Repository working guide

## Scope and documentation

This LLVM fork provides in-process VF selection. `BACKEND_FEEDBACK.md`
describes its contract, fixed TTI corrections and cost reports; README covers
usage, build and tests. `BACKEND_COST_MODEL_VALIDATION.md` records dated results.
Preserve existing upstream LLVM options and behavior when cleaning up fork code.

Keep README and these existing documents current instead of adding overlapping
reports. Distinguish historical measurements from the current binary and describe
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

The current in-process probe stops immediately after StackSlotColoring, using
the spill observer's pass ID. Its stage is `post-stack-slot-coloring`. It runs
VSETVLI insertion and scalar allocation but stops before subsequent copy
propagation, post-RA LICM, and frame lowering. The collector and pricing remain
vector-spill-only; final scalar spill support would require revisiting both.

Preserve the master flag, fixed XiangShan profile, `L - Ev + Sv`, exact rational
normalization, native-cost IC, gate, and main/epilogue policy unless the task
explicitly changes them. Failed required candidates retry the whole original
loop once with specific TTI estimated costs when supported, then use native
selection if needed; never treat failure as zero spill. Do not silently add
post-frame retries, benchmark-specific exceptions, or whole-MIR transport
to the in-process path. Keep the two cost-report options passive and discard
failed-attempt reports on whole-loop estimated/native fallback.

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
  FileCheck split-file not VectorizeTests RISCVTests --parallel 2
.cache/build/unittests/Transforms/Vectorize/VectorizeTests
.cache/build/unittests/Target/RISCV/RISCVTests
.cache/build/bin/llvm-lit -v llvm/test/Transforms/LoopVectorize \
  llvm/test/CodeGen/RISCV/rvv/stack-slot-coloring.mir
```

Use opt-only probe tests to distinguish the feedback pipeline from normal final
object codegen. Scale verification to the change; do not repeatedly run passed
tests without a new reason. Integrated compiler and reporting tests live in the
LLVM unit/lit suites.
