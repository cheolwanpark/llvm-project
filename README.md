# LLVM Scalar Fission

This branch implements the independent `scalar-fission` function pass. It splits
producer computations from ordered scalar state updates, then lets ordinary LLVM
vectorization process each stage independently. The VPlan fission implementation
has been removed.

```sh
cmake -G Ninja -S llvm -B build-fission \
  -DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_ASSERTIONS=ON \
  -DLLVM_ENABLE_PROJECTS=clang -DLLVM_TARGETS_TO_BUILD="RISCV;AArch64;X86"
ninja -C build-fission clang opt llc FileCheck VectorizeTests

build-fission/bin/opt -passes=scalar-fission -S input.ll -o split.ll
build-fission/bin/opt -passes=loop-vectorize -S split.ll -o vectorized.ll
```

Use `-enable-scalar-fission` with an O2/O3 default pipeline, or Clang's
`-mllvm -enable-scalar-fission`. Late placement is the default;
`-scalar-fission-early` selects the comparison position before full unrolling.
Fission does not depend on vector legality, reduction count, producer depth,
register pressure, forced vector width or expected speedup.

The producer retains internal recurrences, nested loops, safe calls and its
original termination test. Fixed scratch capacity supports runtime counts and
data-dependent termination. Consumers preserve branch/PHI and select updates,
independent participation conditions, seeds, operand order and flags. Strict FP,
EH, irreducible control and unproven memory schedules are rejected.

Raw input loads cannot be relayed through scratch, even through wrappers or
identity operations. Stable inputs are read directly; computed shared values can
use scratch, and proven existing result buffers can be reused. The analysis
finishes before emission. The default FP policy preserves update order; explicit
`-scalar-fission-allow-fp-reordering` grants only consumer FP sums `reassoc`.

The complete option, migration and effects contracts are in
[Vectorizers.md](llvm/docs/Vectorizers.md#experimental-reduction-fission).
The old enable, byte-budget and FP-policy options remain aliases. Old scalable
VF flags now control metadata on scalar stages. VPlan-only isolation is diagnosed.

## Validation and experiments

See the [final validation report](llvm/docs/ScalarFissionValidation.md) for
execution results, the 117-target Early/Late comparison, migration coverage and
measurement limits.

```sh
build-fission/unittests/Transforms/Vectorize/VectorizeTests
build-fission/bin/llvm-lit -sv llvm/test/Transforms/ScalarFission \
  llvm/test/Transforms/LoopVectorize/RISCV/reduction-fission-*.ll
python3 llvm/utils/check-scalar-fission.py --build-dir build-fission \
  --work-dir build-fission/scalar-fission-execution

# Requires PyYAML. Fission is run once; pairs only change stage metadata.
python3 llvm/utils/scalar-fission-sweep.py split.ll --build-dir build-fission \
  --output build-fission/vf-sweep --producer 1 f2 f4 --consumer 1 f2 f4
```

`1` means scalar and `s1` means scalable vscale x 1. Requested and actual VF/IC
are recorded separately. Unsupported pairs are unavailable. An optional external
benchmark command can run generated artifacts; code generation alone is never
reported as performance measurement.

`evaluate-scalar-fission.py --help` describes the pinned-corpus runner. It saves
source/tool hashes, exact commands, pass order, original-LV/Early/Late artifacts,
compile time, peak memory and target-loop-attributed remarks. Historical inputs
and results are not rewritten. The migration inventory is
[legacy-migration.json](llvm/test/Transforms/ScalarFission/Inputs/legacy-migration.json).
Obsolete VPlan structural checkers and their harness have been removed; current
semantic checks use the new execution checker and scalar regression suite.
`check-reduction-fission.py` remains a small command-line compatibility wrapper.
