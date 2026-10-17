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

Reduction fission is an opt-in part of `loop-vectorize`. It separates expensive
reduction inputs into a producer loop, stores those inputs in stack scratch
arrays, and consumes them in an accumulator loop. Each stage selects its own
scalable vectorization factor (VF) and has a scalar remainder. All producer
iterations, including its remainder, finish before the accumulator starts.

```sh
opt input.ll -S -o output.ll -passes=loop-vectorize \
  -mtriple=riscv64 -mattr=+v,+zvl128b -force-vector-interleave=1 \
  -enable-vplan-reduction-fission
llc output.ll -mtriple=riscv64 -mattr=+v,+zvl128b -verify-machineinstrs
```

Clang accepts the same option through `-mllvm -enable-vplan-reduction-fission`.
The transform is disabled by default. It supports single-block loops with an
exact constant trip count or an exact runtime trip count with a proven constant
upper bound. Scratch capacity uses the upper bound; all four stages use the
actual count. The original zero-trip entry guard is preserved. It requires
interleave count one, no user-specified VF, and no vectorized epilogue. Unsupported
candidates fall back to the ordinary vectorizer without modifying its plans.
Live-outs must be supported reduction results; other last-iteration values
currently cause the candidate to be rejected.

Integer inductions with invariant start and step retain their modular arithmetic,
including truncated inductions. Each scalar companion resumes at its own stage's
vector bound. Simple consecutive stores are placed in the accumulator stage;
whole-object alias analysis must prove independence from every other memory
access, and scalar evolution must prove nonoverlapping iterations of each store.
Potentially overlapping objects, prefix stores, volatile/atomic accesses,
runtime alias versioning and additional SCEV predicates are not supported.

Ordered and unordered in-loop FP sums support a single ordinary `fadd` update of
an independent contribution. Ordered sums pass the scalar accumulator through
chunks in lane order and then through the scalar remainder. Their register
pressure uses the scalar register class, while contributions and reduction
temporaries use vector registers. New FP candidates also compare TTI scratch and
reduction costs with estimated spill traffic. Known constant counts include setup
and tail costs; dynamic counts use normalized steady-state costs, never the
scratch capacity as an execution-frequency estimate.

`-vplan-reduction-fission-allow-fp-reordering` additionally permits reassociation
of eligible FP sums in a private fission planner. Only the sum's adds and final
reduction gain `reassoc`. No `nnan`, `ninf`, `nsz`, `contract`, reciprocal
approximation or producer reassociation is implied. The initial value is used
once, with `-0.0` as the FP-add identity when `nsz` is absent. Rounding and bitwise
reproducibility may change, including cancellation and overflow results; NaN
payload equality is not promised. This does not turn NaN/Inf into poison. Strict
or constrained FP, FP inductions and accumulator-dependent FMA decomposition
are excluded. The existing `-hints-allow-reordering` policy is unchanged.
Discarding a private candidate preserves the original IR, recurrence descriptors,
planning state and ordinary-vectorizer fallback.

The hidden policy options retain the original defaults:

| Option | Default |
| --- | --- |
| `-vplan-reduction-fission-min-reductions` | `4` |
| `-vplan-reduction-fission-min-chain-depth` | `8` |
| `-vplan-reduction-fission-min-pressure-percent` | `100` |
| `-vplan-reduction-fission-max-scratch-bytes` | `65536` |
| `-vplan-reduction-fission-max-duplicated-recipes` | `8` |
| `-vplan-reduction-fission-max-scalable-vf-multiplier` | `8` |
| `-vplan-reduction-fission-combine-add-contributions` | `true` |
| `-vplan-reduction-fission-allow-fp-reordering` | `false` |

The VF multiplier is relative to the register-width/data-width VF. Stage
selection reserves register headroom, never reduces the producer VF relative to
the selected baseline, and requires lower peak pressure. Private unflagged
integer-add contributions may be combined to save scratch. Floating-point
producer/update expressions retain their operators, flags and operand order,
except for the explicitly opted-in sum reassociation described above. The option
does not force fission or a particular target instruction. A loop with one or two
sums may still fail the default reduction-count or pressure thresholds.

For experiments, specify both
`-vplan-reduction-fission-force-producer-vf=N` and
`-vplan-reduction-fission-force-accumulator-vf=M`. The values must be powers of two
and are scalable lane counts, not LMUL values. They bypass the headroom check,
but retain legality, scratch, duplication and pressure-improvement checks.
Assertions builds can print selection and rejection reasons with
`-debug-only=vplan-reduction-fission`.
`-pass-remarks=vplan-reduction-fission` records selected stage VFs, trip-count
kind, scratch capacity/bytes and each reduction's mode and permission source
(IR, hint or fission option). `-pass-remarks-missed=vplan-reduction-fission`
records rejection reasons.

The implementation is in the `VPlanReductionFission*.h` headers and four
`VPlanReductionFission*.cpp` files in `lib/Transforms/Vectorize`: the main file
owns orchestration and IR emission, `Analysis` owns dependency/pressure and
selection policy, `Transforms` owns stage construction and scratch recipes,
and `FPReordering` owns the optional reassociation policy for private candidates.
The policy is ported from LLVM 21; LLVM 23's baseline costing and VPlan
representation can change automatic VF choices. Fission retains a VPlan before
EVL and header-mask lowering, then constructs full-chunk stages and their scalar
companions. This leaves the ordinary vectorizer's target-specific tail policy
intact. Tests use LLVM 23's `-tail-folding-policy` option in place of the removed
`-prefer-predicate-over-epilogue` option.

To build and test with assertions:

```sh
cmake -G Ninja -S llvm -B build -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_ASSERTIONS=ON -DLLVM_ENABLE_PROJECTS=clang \
  -DLLVM_TARGETS_TO_BUILD=RISCV -DLLVM_INCLUDE_TESTS=ON
ninja -C build clang opt llc FileCheck llvm-config VectorizeTests
build/unittests/Transforms/Vectorize/VectorizeTests
build/bin/llvm-lit -sv llvm/test/Transforms/LoopVectorize/RISCV/reduction-fission-*.ll
```

With RISCV and the host backend enabled, the optional execution check is:

```sh
python3 llvm/utils/check-reduction-fission.py --build-dir build \
  --work-dir build/fission-execution
```

This specializes scalable IR to several fixed vscales and executes it on the
host. It is not RVV emulation. It compares bounded trip counts, independent
stores and canaries, integer wraparound/truncation, and ordered FP against the
original scalar IR, and checks reassociated FP using classification, signed zero
and magnitude-based absolute error bounds. Separate RVV machine verification
and generated assembly complement the host checks. The output directory retains
IR, assembly, selection remarks and a JSON result for reproducibility.

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
