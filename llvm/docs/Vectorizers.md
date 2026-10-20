# Auto-Vectorization in LLVM

```{contents}
:local:
```

LLVM has two vectorizers: The {ref}`Loop Vectorizer <loop-vectorizer>`,
which operates on Loops, and the {ref}`SLP Vectorizer
<slp-vectorizer>`. These vectorizers
focus on different optimization opportunities and use different techniques.
The SLP vectorizer merges multiple scalars that are found in the code into
vectors while the Loop Vectorizer widens instructions in loops
to operate on multiple consecutive iterations.

Both the Loop Vectorizer and the SLP Vectorizer are enabled by default.

(loop-vectorizer)=

## The Loop Vectorizer

### Usage

The Loop Vectorizer is enabled by default, but it can be disabled
through clang using the command line flag:

```console
$ clang ... -fno-vectorize  file.c
```

#### Command line flags

The loop vectorizer uses a cost model to decide on the optimal vectorization factor
and unroll factor. However, users of the vectorizer can force the vectorizer to use
specific values. Both 'clang' and 'opt' support the flags below.

Users can control the vectorization SIMD width using the command line flag "-force-vector-width".

```console
$ clang  -mllvm -force-vector-width=8 ...
$ opt -loop-vectorize -force-vector-width=8 ...
```

Users can control the unroll factor using the command line flag "-force-vector-interleave"

```console
$ clang  -mllvm -force-vector-interleave=2 ...
$ opt -loop-vectorize -force-vector-interleave=2 ...
```

#### Pragma loop hint directives

The `#pragma clang loop` directive allows loop vectorization hints to be
specified for the subsequent for, while, do-while, or c++11 range-based for
loop. The directive allows vectorization and interleaving to be enabled or
disabled. Vector width as well as interleave count can also be manually
specified. The following example explicitly enables vectorization and
interleaving:

```c++
#pragma clang loop vectorize(enable) interleave(enable)
while(...) {
  ...
}
```

The following example implicitly enables vectorization and interleaving by
specifying a vector width and interleaving count:

```c++
#pragma clang loop vectorize_width(2) interleave_count(2)
for(...) {
  ...
}
```

See the Clang
[language extensions](https://clang.llvm.org/docs/LanguageExtensions.html#extensions-for-loop-hint-optimizations)
for details.

### Experimental reduction fission

`ScalarFissionPass` is an independent, opt-in function pass. It separates closed
scalar state updates from their producer before normal loop vectorization:

```sh
opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' \
    -verify-each -S input.ll -o split.ll
opt -passes=loop-vectorize -S split.ll -o vectorized.ll
```

Use `-enable-scalar-fission` with `default<O2>`, `default<O3>`, or Clang's
`-mllvm` to enable pipeline integration. The default placement is Late, immediately
before LV after loop normalization. `-scalar-fission-early` selects the independent
placement before full unrolling. Explicit `-passes=scalar-fission` runs the pass
without the enable flag. Vectorization-disable hints do not disable fission;
`llvm.loop.scalar_fission.disable` does. Optnone is respected.

The pass first builds a plan, validates its complete chunk schedule and only then
creates IR. Rejections allocate no scratch and do not partially split a loop.
Standard LoopSimplify, LCSSA and rotation normalization can remain after rejection.
The original entry guard and termination test are preserved. A bounded local
ordinal limits producer execution to a chunk, then the consumer visits exactly
those completed iterations. Neither a constant trip bound nor a separate total
iteration counter is required. Scalar/scalar execution is supported.

Supported state includes scalar integer arithmetic, bitwise and min/max updates,
ordinary FP addition/subtraction and closed compound update slices. Branch/PHI
and select representations retain their execution semantics, including different
participation conditions. Producer-local recurrences and final live-outs remain
in the producer. Reducible inner producer loops with dedicated unique exits are
retained, with outer consumers using their LCSSA outputs. State influencing a
producer address, predicate, effect or termination cannot move.

Consumer-only loads can move, and stable shared loads can be reread. The proof
checks every producer writer against the underlying memory object, covering all
iterations reordered by the chunk schedule. Unknown aliases are rejected; there
is no new noalias assumption or runtime alias versioning. Conditional loads stay
on their original paths. Existing result buffers can replace scratch when stores
use a nonwrapping canonical IV, are injective, and are disjoint from other writers.
Computed shared values cross through private scratch; private suffixes remain in
the consumer. Constants, addresses and affine integer IVs are reconstructed.

Raw input snapshots cannot cross through scratch, including cast, select, PHI,
freeze and identity-operation wrappers. If a safe original read is impossible,
the analysis retries a computed-result boundary or rejects. Recomputed freezes
are prohibited because repeated freezes can choose different values. Scratch
allocation is bounded by the per-split byte budget, pointer index representation,
and an unconditional small constant maximum trip count when ScalarEvolution can
prove one. A missing bound never prevents a split. When that bound fits the final
capacity, the producer keeps its original continuation without a capacity test,
and the consumer runs for the actual completed count, with no chunk restart.

Shared invariant-offset/IV address expressions are cloned with their original
widths, flags and control. A final dependency cleanup moves private multiply
suffixes only when their operands are already available in the consumer and no
producer demand survives removal of the stream. This does not introduce loads,
reassociation or input snapshots.

Scratch lifetimes span the complete schedule, across all chunks, from the
original preheader through the dedicated exit after the last consumer read.
Fixed allocas remain in the function entry; existing user buffers are excluded.
LLVM stack coloring may share storage between nonoverlapping schedules, including
schedules invoked repeatedly inside an enclosing loop.

`FunctionScratchAllocaBytes` reports the sum of scratch IR allocation sizes after
all splits in a function. The byte budget remains **per split**, so this sum may
exceed it. It is distinct from peak live scratch and the machine frame (which
also includes spills and other objects). Lifetime-based sharing can reduce the
machine frame without reducing the IR allocation sum; inspect codegen to measure
actual reuse.

Traffic remarks distinguish static original access widths, moved and duplicated
original reads, reused buffers, and scratch bytes. `MovedOriginalLoadInstructionBytes`
counts consumer reads whose producer dependencies disappear;
`DuplicatedOriginalLoadInstructionBytes` counts reads retained by both stages.
The compatibility field `AdditionalLoadInstructionBytesUpperBound` now uses the
same final producer-dependency count as the duplicated-read field. It remains a
conservative static count, not a measure of dynamic extra traffic. Nested and conditional execution multiplicities
vary, and opaque calls’ dynamic access volume is not estimated; these counts do
not estimate cache traffic or runtime.

Producer calls need no vector mapping or `speculatable` attribute. They must be
ordinary non-tail calls, `nounwind` and `willreturn`, without bundles, convergence,
returns-twice, strict FP or other special control constraints. Memory-effect calls
also require `nosync`, `nofree`, `nocallback`, and no inaccessible-memory effects.
The original call count, condition and order are retained. Calls are not cloned
into the consumer. No contracts are inferred from library or helper names.

Irreducible outer control, multiple outer completion exits, EH, volatile/atomic
accesses, strict/constrained FP, nonreconstructible state inputs and unsupported
call effects are rejected with specific reasons. Analysis has a 4096-step budget per candidate, with at most two state-slice candidates.
There is no minimum reduction count, producer depth, register-pressure gate,
whole-loop vector-legality prerequisite or speedup requirement.

By default FP flags, operand order, seeds and update order are preserved. Explicit
`-scalar-fission-allow-fp-reordering` adds only `reassoc` to recognized consumer FP
sums, including simple conditional sums. It adds no `nnan`, `ninf`, `nsz`,
`contract` or reciprocal permission. Subtraction, compensated updates,
accumulator-dependent FMA, producer expressions and unrelated loops are unchanged.

| Option | Default | Meaning |
| --- | --- | --- |
| `enable-scalar-fission` | false | Enable default-pipeline integration. |
| `scalar-fission-early` | false | Use the position before full unrolling. |
| `scalar-fission-max-scratch-bytes` | 65536 | Static scratch byte budget per split. |
| `scalar-fission-chunk-capacity` | 1024 | Maximum completed iterations per chunk; the byte budget or a proven trip bound may lower it. |
| `scalar-fission-allow-fp-reordering` | false | Consumer FP sum reassociation. |
| `scalar-fission-producer-vf`, `scalar-fission-consumer-vf` | 0 | Independent VF requests; 0 is automatic, fixed 1 is scalar. |
| `scalar-fission-producer-scalable`, `scalar-fission-consumer-scalable` | false | Interpret the respective VF as scalable, including vscale x 1. |
| `scalar-fission-producer-interleave`, `scalar-fission-consumer-interleave` | 0 | Independent interleave requests; 0 is automatic. |

Stage requests use ordinary LLVM loop metadata. Normal LV decides legality,
tails and code generation; fission does not construct vector plans. Stage remarks
report actual VF/IC separately from requests. An unsupported forced pair may
fall back or be ignored, and must be classified as unavailable.

`enable-vplan-reduction-fission`, `vplan-reduction-fission-max-scratch-bytes` and
`vplan-reduction-fission-allow-fp-reordering` remain aliases. The old
`vplan-reduction-fission-force-producer-vf` and `...-force-accumulator-vf` flags
now request scalable metadata on scalar stages independently. Disabling
`enable-scalar-reduction-fission` to isolate VPlan fission is an error: that path
was removed. Obsolete recipe limits, VF search, pressure/count/depth options and
contribution combining produce migration diagnostics and never become gates.

Use `-pass-remarks=scalar-fission` and `-pass-remarks-missed=scalar-fission` for
selection and rejection evidence. Stage provenance prevents repeated splitting
and is propagated through normal vectorization.

`llvm/utils/check-scalar-fission.py` executes original and transformed host IR
against independent oracles, then machine-verifies RVV code separately.
`llvm/utils/scalar-fission-sweep.py` changes only metadata on a frozen split IR
and records actual VF/IC and unavailable pairs. `--producer-interleave` and
`--consumer-interleave` independently override its shared `--interleave` default.
Its optional external benchmark command saves execution results; without one,
performance remains unmeasured.
`llvm/utils/evaluate-scalar-fission.py` checks the pinned 117-case corpus, matches
exact target-loop locations and compares independent original-LV, Early and Late
runs under both FP policies. The sweep and corpus tools require PyYAML.

### Diagnostics

Many loops cannot be vectorized including loops with complicated control flow,
unvectorizable types, and unvectorizable calls. The loop vectorizer generates
optimization remarks which can be queried using command line options to identify
and diagnose loops that are skipped by the loop-vectorizer.

Optimization remarks are enabled using:

`-Rpass=loop-vectorize` identifies loops that were successfully vectorized.

`-Rpass-missed=loop-vectorize` identifies loops that failed vectorization and
indicates if vectorization was specified.

`-Rpass-analysis=loop-vectorize` identifies the statements that caused
vectorization to fail. If in addition `-fsave-optimization-record` is
provided, multiple causes of vectorization failure may be listed (this behavior
might change in the future).

Consider the following loop:

```c++
#pragma clang loop vectorize(enable)
for (int i = 0; i < Length; i++) {
  switch(A[i]) {
  case 0: A[i] = i*2; break;
  case 1: A[i] = i;   break;
  default: A[i] = 0;
  }
}
```

The command line `-Rpass-missed=loop-vectorize` prints the remark:

```console
no_switch.cpp:4:5: remark: loop not vectorized: vectorization is explicitly enabled [-Rpass-missed=loop-vectorize]
```

And the command line `-Rpass-analysis=loop-vectorize` indicates that the
switch statement cannot be vectorized.

```console
no_switch.cpp:4:5: remark: loop not vectorized: loop contains a switch statement [-Rpass-analysis=loop-vectorize]
  switch(A[i]) {
  ^
```

To ensure line and column numbers are produced include the command line options
`-gline-tables-only` and `-gcolumn-info`. See the Clang [user manual](https://clang.llvm.org/docs/UsersManual.html#options-to-emit-optimization-reports)
for details

### Features

The LLVM Loop Vectorizer has a number of features that allow it to vectorize
complex loops.

#### Loops with unknown trip count

The Loop Vectorizer supports loops with an unknown trip count.
In the loop below, the iteration `start` and `finish` points are unknown,
and the Loop Vectorizer has a mechanism to vectorize loops that do not start
at zero. In this example, 'n' may not be a multiple of the vector width, and
the vectorizer has to execute the last few iterations as scalar code. Keeping
a scalar copy of the loop increases the code size.

```c++
void bar(float *A, float* B, float K, int start, int end) {
  for (int i = start; i < end; ++i)
    A[i] *= B[i] + K;
}
```

#### Runtime Checks of Pointers

In the example below, if the pointers A and B point to consecutive addresses,
then it is illegal to vectorize the code because some elements of A will be
written before they are read from array B.

Some programmers use the 'restrict' keyword to notify the compiler that the
pointers are disjointed, but in our example, the Loop Vectorizer has no way of
knowing that the pointers A and B are unique. The Loop Vectorizer handles this
loop by placing code that checks, at runtime, if the arrays A and B point to
disjointed memory locations. If arrays A and B overlap, then the scalar version
of the loop is executed.

```c++
void bar(float *A, float* B, float K, int n) {
  for (int i = 0; i < n; ++i)
    A[i] *= B[i] + K;
}
```

#### Reductions

In this example the `sum` variable is used by consecutive iterations of
the loop. Normally, this would prevent vectorization, but the vectorizer can
detect that 'sum' is a reduction variable. The variable 'sum' becomes a vector
of integers, and at the end of the loop the elements of the array are added
together to create the correct result. We support a number of different
reduction operations, such as addition, multiplication, XOR, AND and OR.

```c++
int foo(int *A, int n) {
  unsigned sum = 0;
  for (int i = 0; i < n; ++i)
    sum += A[i] + 5;
  return sum;
}
```

Fully vectorizing reductions requires reordering operations, which is
problematic for floating-point arithmetic because it is not associative;
therefore results may depend on the evaluation order.

Changing floating-point results is implicitly prohibited by the C and C++
standards, therefore LLVM supports vectorizing floating point reductions only
when at least the `-fassociative-math -fno-signed-zeros -fno-trapping-math`
subset of `-ffast-math` is used on most targets. On some targets, such as
AArch64 and RISC-V, LLVM can generate ordered reductions that preserve the
exact result, enabling limited, standards-compliant vectorization. However,
ordered reductions are typically less efficient than traditionally vectorized
reductions, therefore enabling floating-point reordering may still result in
more performant reductions on these targets.

#### Inductions

In this example the value of the induction variable `i` is saved into an
array. The Loop Vectorizer knows to vectorize induction variables.

```c++
void bar(float *A, int n) {
  for (int i = 0; i < n; ++i)
    A[i] = i;
}
```

#### If Conversion

The Loop Vectorizer is able to "flatten" the IF statement in the code and
generate a single stream of instructions. The Loop Vectorizer supports any
control flow in the innermost loop. The innermost loop may contain complex
nesting of IFs, ELSEs and even GOTOs.

```c++
int foo(int *A, int *B, int n) {
  unsigned sum = 0;
  for (int i = 0; i < n; ++i)
    if (A[i] > B[i])
      sum += A[i] + 5;
  return sum;
}
```

#### Pointer Induction Variables

This example uses the "accumulate" function of the standard c++ library. This
loop uses C++ iterators, which are pointers, and not integer indices.
The Loop Vectorizer detects pointer induction variables and can vectorize
this loop. This feature is important because many C++ programs use iterators.

```c++
int baz(int *A, int n) {
  return std::accumulate(A, A + n, 0);
}
```

#### Reverse Iterators

The Loop Vectorizer can vectorize loops that count backwards.

```c++
void foo(int *A, int n) {
  for (int i = n; i > 0; --i)
    A[i] +=1;
}
```

#### Scatter / Gather

The Loop Vectorizer can vectorize code that becomes a sequence of scalar instructions
that scatter/gathers memory.

```c++
void foo(int * A, int * B, int n) {
  for (intptr_t i = 0; i < n; ++i)
      A[i] += B[i * 4];
}
```

In many situations the cost model will inform LLVM that this is not beneficial
and LLVM will only vectorize such code if forced with "-mllvm -force-vector-width=#".

#### Vectorization of Mixed Types

The Loop Vectorizer can vectorize programs with mixed types. The Vectorizer
cost model can estimate the cost of the type conversion and decide if
vectorization is profitable.

```c++
void foo(int *A, char *B, int n) {
  for (int i = 0; i < n; ++i)
    A[i] += 4 * B[i];
}
```

#### Global Structures Alias Analysis

Access to global structures can also be vectorized, with alias analysis being
used to make sure accesses don't alias. Run-time checks can also be added on
pointer access to structure members.

Many variations are supported, but some that rely on undefined behaviour being
ignored (as other compilers do) are still being left un-vectorized.

```c++
struct { int A[100], K, B[100]; } Foo;

void foo() {
  for (int i = 0; i < 100; ++i)
    Foo.A[i] = Foo.B[i] + 100;
}
```

#### Vectorization of function calls

The Loop Vectorizer can vectorize intrinsic math functions.
See the table below for a list of these functions.

```{list-table}
:header-rows: 0

* - pow
  - exp
  - exp2
* - sin
  - cos
  - sqrt
* - log
  - log2
  - log10
* - fabs
  - floor
  - ceil
* - fma
  - trunc
  - nearbyint
* -
  -
  - fmuladd
```

Note that the optimizer may not be able to vectorize math library functions
that correspond to these intrinsics if the library calls access external state
such as "errno". To allow better optimization of C/C++ math library functions,
use "-fno-math-errno".

The loop vectorizer knows about special instructions on the target and will
vectorize a loop containing a function call that maps to the instructions. For
example, the loop below will be vectorized on Intel x86 if the SSE4.1 roundps
instruction is available.

```c++
void foo(float *f) {
  for (int i = 0; i != 1024; ++i)
    f[i] = floorf(f[i]);
}
```

Many of these math functions are only vectorizable if the file has been built
with a specified target vector library that provides a vector implementation
of that math function. Using clang, this is handled by the "-fveclib" command
line option with one of the following vector libraries:
"Accelerate,libmvec,MASSV,SVML,SLEEF,Darwin_libsystem_m,ArmPL,AMDLIBM"

```console
$ clang ... -fno-math-errno -fveclib=libmvec file.c
```

#### Partial unrolling during vectorization

Modern processors feature multiple execution units, and only programs that contain a
high degree of parallelism can fully utilize the entire width of the machine.
The Loop Vectorizer increases the instruction level parallelism (ILP) by
performing partial-unrolling of loops.

In the example below the entire array is accumulated into the variable 'sum'.
This is inefficient because only a single execution port can be used by the processor.
By unrolling the code the Loop Vectorizer allows two or more execution ports
to be used simultaneously.

```c++
int foo(int *A, int n) {
  unsigned sum = 0;
  for (int i = 0; i < n; ++i)
      sum += A[i];
  return sum;
}
```

The Loop Vectorizer uses a cost model to decide when it is profitable to unroll loops.
The decision to unroll the loop depends on the register pressure and the generated code size.

#### Epilogue Vectorization

When vectorizing a loop, often a scalar remainder (epilogue) loop is necessary
to execute tail iterations of the loop if the loop trip count is unknown or it
does not evenly divide the vectorization and unroll factors. When the
vectorization and unroll factors are large, it's possible for loops with smaller
trip counts to end up spending most of their time in the scalar (rather than
the vector) code. In order to address this issue, the inner loop vectorizer is
enhanced with a feature that allows it to vectorize epilogue loops with a
vectorization and unroll factor combination that makes it more likely for small
trip count loops to still execute in vectorized code. The diagram below shows
the CFG for a typical epilogue vectorized loop with runtime checks. As
illustrated the control flow is structured in a way that avoids duplicating the
runtime pointer checks and optimizes the path length for loops that have very
small trip counts.

```{image} epilogue-vectorization-cfg.png
```

#### Early Exit Vectorization

When vectorizing a loop with a single early exit, the loop blocks following the
early exit are predicated and the vector loop will always exit via the latch.
The loop terminates with a single BranchOnTwoConds VPInstruction, which takes
both the early and latch exiting conditions. If the early exiting condition is
true, BranchOnTwoConds exits to an intermediate block (`vector.early.exit`
below). This intermediate block is responsible for calculating any exit values
of loop-defined variables that are used in the early exit block. If the latch
exiting condition is true, BranchOnTwoConds exits to the `middle.block` which
selects between the exit block and the scalar remainder loop. Otherwise
BranchOnTwoConds continues executing the loop by jumping back to the region
header.

```{image} vplan-early-exit.png
```

BranchOnTwoConds is lowered to a chain of conditional branches exiting
the vector loop after dissolving loop regions:

```{image} vplan-early-exit-lowered.png
```

### Performance

This section shows the execution time of Clang on a simple benchmark:
[gcc-loops](https://github.com/llvm/llvm-test-suite/tree/main/SingleSource/UnitTests/Vectorizer).
This benchmarks is a collection of loops from the GCC autovectorization
[page](http://gcc.gnu.org/projects/tree-ssa/vectorization.html) by Dorit Nuzman.

The chart below compares GCC-4.7, ICC-13, and Clang-SVN with and without loop vectorization at -O3, tuned for "corei7-avx", running on a Sandybridge iMac.
The Y-axis shows the time in msec. Lower is better. The last column shows the geomean of all the kernels.

```{image} gcc-loops.png
```

And Linpack-pc with the same configuration. Result is Mflops, higher is better.

```{image} linpack-pc.png
```

### Ongoing Development Directions

```{toctree}
:hidden: true

VectorizationPlan
```

{doc}`VectorizationPlan`

: Modeling the process and upgrading the infrastructure of LLVM's Loop Vectorizer.

(slp-vectorizer)=

## The SLP Vectorizer

### Details

The goal of SLP vectorization (a.k.a. superword-level parallelism) is
to combine similar independent instructions
into vector instructions. Memory accesses, arithmetic operations, comparison
operations, PHI-nodes, can all be vectorized using this technique.

For example, the following function performs very similar operations on its
inputs (a1, b1) and (a2, b2). The basic-block vectorizer may combine these
into vector operations.

```c++
void foo(int a1, int a2, int b1, int b2, int *A) {
  A[0] = a1*(a1 + b1);
  A[1] = a2*(a2 + b2);
  A[2] = a1*(a1 + b1);
  A[3] = a2*(a2 + b2);
}
```

The SLP-vectorizer processes the code bottom-up, across basic blocks, in search of scalars to combine.

### Usage

The SLP Vectorizer is enabled by default, but it can be disabled
through clang using the command line flag:

```console
$ clang -fno-slp-vectorize file.c
```

## The Sandbox Vectorizer

```{toctree}
:hidden: true

SandboxVectorizer
```

The {doc}`Sandbox Vectorizer <SandboxVectorizer>` is an experimental framework for building modular vectorization pipelines on top of {doc}`Sandbox IR <SandboxIR>`, with a focus on ease of testing and ease of development.
