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
``ReductionFissionContribution`` analysis remarks identify each original
accumulator and initial value, its normalization or fallback reason, and its
scratch, borrowed-stream and shared-contribution choices.
If any component cannot vectorize at its requested VF, the function transaction
is discarded and ``ReductionFissionRolledBack`` reports the failure. A provisional
selection remark alone is not proof that fission was applied.

Execution and legality
----------------------

Map executes all original iterations before any reduction executes. Separate
buffers hold independent contributions. Read-only analysis recognizes
homogeneous associative update chains containing the accumulator
exactly once and plans one combined contribution per iteration. Execution
materializes that contribution in Map, leaving one combination with the
accumulator in the reducer. Reassociated integer operations do not inherit
``nsw`` or ``nuw``. FP chains require reassociation permission on every operation
and intersect their rewrite permissions; ``reassoc`` is never promoted to
``fast``. New addition/multiplication drops ``nnan`` and ``ninf`` because reordered
intermediates can overflow even when the original accumulator updates did not.
Integer min/max and FP min/max intrinsic chains also combine their terms in
Map. Min/max selects existing operands and retains justified flags; minnum/maxnum
reassociation requires ``nnan`` and ``nsz``. An ``ninf`` min/max uses the largest
finite value of the appropriate sign as its identity instead of infinity.
An ``llvm.fmuladd`` update may contribute a separately rounded product in Map;
this does not apply to the mandatory fused rounding of ``llvm.fma``.
Reloadable multiplicands do not bypass this product materialization: they are
factors of the contribution, rather than existing contribution streams.

An optionally executed chain can also produce one contribution: its original
PHI or select chooses the combine identity for a skipped update. Loads and
arithmetic remain on their original paths in Map. The resulting unconditional
addition/multiplication reducer drops ``nnan``, ``ninf`` and ``nsz`` because the skipped original
arithmetic imposes no such constraints on the initial accumulator. Floating
addition uses negative zero as the skipped contribution. For NaN-absorbing
recurrences, a scalar exit selection preserves the original initializer's NaN
bits: an all-skipped source loop performs no FP operation that could change its
sign, signaling bit or payload. This does not introduce another vector
accumulator. Conditional FP reductions with non-IEEE denormal modes are rejected
because these identities can change skipped subnormal values.
For conditional min/max, scalar exit selections preserve an exceptional
initializer on paths where the original flagged update was skipped, and retain
the initializer's zero sign when both it and the result are zero. These choices
also respect the original permissions when an update executes. The initial value
is frozen once before seeding/classification so new uses do not duplicate undef
choices. These corrections add no vector accumulator and do not reduce VF.

Other recurrences retain their original accumulator-dependent slice and may
require multiple input streams. This includes more complex dependent joins,
mixed operations, and casts within the dependent slice. A chain whose inputs all
reuse existing streams also keeps that zero-scratch representation instead of
allocating a new buffer for their combined value. Identical input values and
matching normalized expressions share storage while the accumulators still
receive independent reduction loops. Sharing checks the operation, type,
fast-math flags, terms, and any control selecting a skipped update.

For slice fallbacks, independent branch conditions are buffered as bytes. Those
reducers reproduce the original per-iteration control path, loading conditional
contributions only on paths where Map initialized them. This supports branch
CFGs with a unique countable latch exit. Early exits and non-branch control flow
are diagnosed.

If a slice fallback can skip every update, analysis also checks its initial
value against the FP flags used by the eventual horizontal collapse. An
unproven ``nnan``, ``ninf`` or ``nsz`` constraint rejects that candidate instead
of applying flags from unexecuted arithmetic to the returned initializer.

Non-wrapping contiguous read-only inputs can be reused without Map copies when
alias analysis excludes changes by Map writes across all iterations.
Known global-object bounds can prove a constant forward traversal non-wrapping
even when GEP canonicalization did not retain a ``nuw`` annotation.
Exact ``sext``, ``zext`` and ``fpext`` contributions can reuse a narrower stream
and reconstruct their logical value at the reducer load, when the conversion
supports the maximum logical reduction VF. This does not truncate an arbitrary
computed value or lower the reducer width to make a storage encoding work.

Invariant contributions need no per-iteration storage either. If distribution
leaves Map with neither effects nor live-outs, its proven finite loop is deleted;
the
generated result explicitly records an absent Map. All reducer loops still
must vectorize independently. A nonempty Map failure still rolls back the
transaction. A scratch-free loop whose trip count may exceed the reducer index
range is rejected, preserving its original execution without an allocation trap.

Scratch buffers use the exact runtime trip count and checked address-sized byte
arithmetic. Constant-size scratch uses entry allocas if all buffers and existing
allocas fit the aggregate stack budget; otherwise it requires available heap
allocation builtins. Zero-trip paths bypass allocation. Buffers have their
lifetimes ended or are freed after the last reduction, including when nested
in an outer loop or the function is called repeatedly. There is no buffer-capacity or
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

For generated reducers, VPlan retains the vector loop and runtime EVL instead
of folding a single-iteration region or replacing a known EVL with its AVL.
This preserves an EVL-controlled backedge through the current RVV O2 pipeline,
even when the trip count is below VLMAX, so each accumulator collapses before
the next reducer starts. Normal and Map retain single-iteration folding.

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
