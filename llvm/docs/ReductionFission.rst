Experimental reduction fission in the Loop Vectorizer
====================================================

This experimental candidate distributes the independent work of a scalar loop
into a Map followed by one reduction loop per accumulator. It is manually
selected and has no profitability model.

Selection
---------

The existing hidden ``-force-vector-width`` option accepts either its existing
numeric argument or ``fission:N``. ``N`` is the Map VF's known-minimum width.
``-scalable-vectorization=off`` selects a fixed Map VF and ``on`` selects a
scalable Map VF. For example::

  opt -passes='loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d \
    -force-vector-width=fission:4 -scalable-vectorization=off \
    -pass-remarks=loop-vectorize -pass-remarks-analysis=loop-vectorize \
    -pass-remarks-missed=loop-vectorize input.ll -S -o distributed.ll

``-force-vector-width=4`` retains ordinary vectorization behavior. Logical
``Normal(VF)`` and ``Fission(MapVF=VF)`` candidates have separate identities.
Fission's ``INF`` cost is an explicit exclusion from automatic selection, not
an invalid or saturated ``InstructionCost``. The original VPlan collection and
``getPlanFor(VF)`` represent Normal candidates; selected fission components
receive new plans after scalar distribution.

Read-only eligibility analysis is based on the existing reduction descriptors
and accumulator-dependent use slices. Analysis does not modify the scalar loop.
Candidate remarks report the structurally and target-eligible alternatives.
Concrete component planning remains a further check on a forced candidate.
Selection is provisional until ``ReductionFissionCommitted`` is reported.
If any component cannot vectorize at its requested VF, the function transaction
is discarded and ``ReductionFissionRolledBack`` reports the failure. A provisional
selection remark alone is not proof that fission was applied.

Execution and legality
----------------------

Map executes all original iterations before any reduction executes. Separate
buffers hold independent contributions, including multiple inputs to one
recurrence. Shared inputs are stored once. Accumulator-dependent instructions
are moved without rewriting their arithmetic; in particular a multiply-add
intrinsic is cloned intact.

Independent branch conditions are buffered as bytes. Each reduction reproduces
the original per-iteration control path, loading a conditional contribution only
on the path where Map initialized it. This supports branch CFGs with a unique
countable latch exit. Early exits and non-branch control flow are diagnosed.

Scratch buffers use the exact runtime trip count, checked address-sized byte
arithmetic, and heap allocation. Zero-trip paths bypass allocation. Buffers are
freed after the last reduction, including when the source loop is nested in an
outer loop or the function is called repeatedly. There is no buffer-capacity or
profitability limit. Unrepresentable allocation sizes and allocation failure
trap; they cannot produce wrapping buffer accesses.

Every header recurrence must be a normal induction or an eligible independent
reduction. An accumulator observed by Map memory/control, an intermediate
observable accumulator, dependencies between accumulators, or an unsupported
recurrence rejects the entire source loop. The Map check also follows SSA,
control, and memory value flow to reject cycles carrying state across iterations,
even when ordinary vectorization can preserve such a cycle at a small VF.
Loop-independent and anti-dependences, and acyclic memory value flow, are allowed.
Unresolved aliasing is rejected when it can close a recurrence cycle, including
on a scalar Map path after a runtime dependence check. Incomplete dependence
information is diagnosed rather than assumed independent.

FP reassociation is not enabled by
the force request. Ordered reductions are rejected because this candidate
requires a vector accumulator followed by a final horizontal collapse.

RISC-V policy
-------------

On RISC-V, reduction VFs are scalable and selected independently of the Map VF.
The implementation probes target legality of the actual contribution and
recurrence types through the vectorizer's supported widths, rather than using
the target's preferred register width. It then checks each generated reduction's
actual VPlan, largest width first, independently of the other accumulators.
There is no search over combinations of accumulator widths. For ordinary f32, f64, and integer
reductions this permits LMUL=8. Wider contribution types can constrain the VF
of mixed-precision recurrences. Each reduction has interleave count one.

Generated loop metadata isolates reduction width and scalable settings from
global force options. The target preference for a horizontal reduction inside
every iteration is disabled for these loops; ordinary vectorization tail
handling remains in effect. RVV scalable FP/integer product and some FP min/max
variants are rejected by existing target reduction legality. Genuine
``llvm.fma`` recurrences are not recognized by the existing reduction descriptor;
``llvm.fmuladd`` and separate multiply-plus-add contributions are distinct cases.

Implementation
--------------

``ReductionFission.cpp`` owns scalar dependency analysis and distribution.
``LoopVectorize.cpp`` owns selection, component planning/execution, and atomic
function replacement. New component planning uses fresh legality/cost analyses,
clears LoopAccessInfo, forgets affected ScalarEvolution state, rebuilds the
dominator tree, and restores LCSSA. Committing a cloned function preserves no
analyses of the replaced body. Address-taken basic blocks are diagnosed because
function-body replacement cannot preserve external blockaddress users.

Tests live under ``llvm/test/Transforms/LoopVectorize/`` and its ``RISCV``
subdirectory with the ``reduction-fission-`` prefix. Benchmark reproduction,
source manifests, tool identities, and execution/lowering evidence belong to the
separate experiment evidence directory; baseline-only runs must not be counted
as transformed validation.
