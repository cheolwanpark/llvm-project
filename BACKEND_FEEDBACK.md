# Backend feedback contract

The master flag enables in-process VF selection for supported RISC-V RVV loops
in reciprocal-throughput mode. Other targets, non-RVV functions, outer loops and
other cost kinds retain native selection. [README](README.md) owns options,
usage and build instructions; [pricing rules](costsheet/rule.md) own conversions
and target documents own prices and evidence.

## Ownership

| Module | Owns | Does not own |
|---|---|---|
| CostSheet / Pricing | CPU/exact-VLEN profiles, TTI/MIR information, facts pricing, exact normalization and cost composition | Probe execution, observation success or cancellation |
| Probing | Materialization, related-block tracking, normalization evidence, native suffix/backend, independent observations, raw cache and worker lifetime | Prices, dominance or fallback model order |
| Gate / Pruning | Pressure bounds, candidate ordering, dominance, cancellation requests and CFG reduction policy | Mapping decisions, payload ownership or worker joins |

LV coordinates attempts: costs, scalar baseline, main/epilogue selection and
provisional reports are adopted or discarded together. The dependency direction
is `LLVMVectorize → analysis callback → LLVMPasses → TargetMachine`. No CodeGen
or target-specific link dependency is introduced into Vectorize. `TargetMIRInfo`
is a read-only pricing service supplied through that callback.

<a id="bodyspill-ablation과-mir-info"></a>

## Costs and comparison scope

| Mode | Vector body | Original scalar baseline |
|---|---|---|
| TTI observed vector spill | `L - Ev + Sv` | Configured TTI scalar IR cost |
| TTI estimated | `L` | Configured TTI scalar IR cost |
| MIR observed | `R_vector` | `R_scalar` |
| MIR estimated spill | `R_vector - S_vector + Et_vector` | `R_scalar - S_scalar + Et_scalar` |

`L` includes the register-pressure estimates supplied by existing LLVM policy.
`Ev` is its estimated vector-register spill component. `Sv` prices observed RVV
vector spills. `R` is the observed MIR body cost; `S` is the cost of its
scalar/vector spill-slot accesses. Separate address calculations stay in `R-S`.
`Et` is the configured TTI's total estimated spill cost, not vector-only `Ev`.
An inactive pressure policy can legitimately produce a zero estimate.

Scalar baseline means the original loop at VF1/IC1. Scalar spill means GPR/FPR
spill/reload, including accesses inside a vector body. TTI real-spill replaces
only vector spills and preserves scalar spill estimates. Its scalar baseline
retains upstream IR costing without adding a separate pressure-spill estimate.
MIR observes and prices both scalar and vector bodies with the same sheet.

Default-TTI selects scalar/vector TTI comparison costs and both MIR estimated
spill terms independently of the MIR sheet. Successful pure-MIR pricing and
selection are unchanged by this flag. Saturn/K1 TTI remains native. Native IC,
probe optimization and final codegen always stay outside the tuned comparison
scope. CPU/exact-VLEN selection and prices are in the target sheets.

`Wtti/Wobs` normalizes observed costs once. `Wobs` already includes IC and proven
additional unrolling. Exact rational scalar, body, ranking and tail costs must
survive comparison without truncation. `VPExactCost` uses quarter-cost numerators
and positive denominators, with 128-bit comparison cross products. Required cost
overflow fails the attempt; a pruning-proof overflow leaves the candidate live.

These ablations are not a fully orthogonal experiment: TTI versus MIR changes
body representation, scalar baseline and spill coverage together. Default versus
tuned changes scalar and vector comparison prices together. Build success or an
ELF variant name does not establish that the requested model was applied; inspect
the effective model and fallback ledger.

<a id="probe와-fallback"></a>

## One probe pipeline and independent observations

```text
clone → activate private-function tracking → materialize and register body
  → configured CFG reduction → native post-LV suffix → validate IR evidence
  → instruction selection / pre-RA optimization and scheduling
  → RVV allocation / rewrite → VSETVLI insertion → scalar allocation / rewrite
  → StackSlotColoring → vector-spill observer
  → remaining native backend → post-frame-lowering MIR observer (when requested)
```

`StopAfter = Spill | MIR` stops using the selected observer's pass ID. Spill
observations are taken at `post-stack-slot-coloring`, before copy propagation,
post-RA LICM and frame lowering. MIR uses `post-frame-lowering`: after RISC-V
post-RA pseudo expansion, KCFI and load/store optimization in `addPreSched2`,
before final scheduling and RVV pseudo expansion. There is no post-frame retry.
Unsupported allocators, disabled StackSlotColoring, limited/profile-dependent
pipelines or unproven termination are failures, never zero spills.

Each query has one identity-initialized result with independent Spill and MIR
slots. Each slot owns status, stage, scope evidence, width and payload. Status
distinguishes not requested, not collected, failed and succeeded. A succeeded
empty vector-spill list is an observed zero. Gate skips and failures are not.
One failed slot must not erase the other's valid observation; an unrequested MIR
slot must not make a spill-only query fail.

The spill collector accepts spill-slot memory accesses with allocated physical
RVV data registers, preserving direction, group, size, alignment and address
space. Segment accesses use the same physical-group decomposition as lowering.
It excludes scalar spills and ordinary whole-register memory accesses. MIR
records scalar/vector body instructions, geometry and spill-slot classification.
Both collectors omit metadata, upstream pseudoprobes, returns and frame
setup/destroy overhead.
Owned results contain no IR/MachineInstr pointers. MIR text is captured only when
requested for detailed reporting.

<a id="related-block-mapping"></a>

## Body mapping and normalization

Each probe registers tracking on its private Function, after cloning or parsing
its worker snapshot. Materialization registers the actual main, epilogue or
scalar body, including header and latch, and seeds the other live blocks as
non-target origins. The remainder of materialization classifies newly generated
non-observed roles and scaffold without overwriting already propagated ancestry.
The context owns a nullable, function-indexed registry; the MachineFunction owns
its machine table. Neither BasicBlock nor MachineBasicBlock gains data members.
Disabled hooks return before allocating sets or searching a registry. Contexts
with an active probe still check Function ownership. Tables and temporary
instruction-transfer snapshots are destroyed before private IR is published or
destroyed; returned observations contain only owned facts.

`getRelatedBlock()` returns origins and an independent completeness state.
Origins are monotonically assigned within one tracker; deleted block addresses
are removed from the lookup table. Clone/split copy ancestry, while merging,
sharing and cross-block moves union it. Instruction clone and detached
remove/insert paths retain source ancestry. SelectionDAG bridges IR ancestry to
machine blocks; generated machine blocks inherit their current machine cause.
Unknown ancestry is distinct from a known non-target block.

Each observer independently scans its current MachineFunction and selects every
MBB whose origins intersect the registered body. It visits each selected MBB
once, including all branch alternatives and disconnected descendants. Membership
does not use machine loop metadata, dominance, paths, names, layout or debug
locations. An unresolved executable block causes mapping failure. An absent body
is not an observed zero. Payload filters apply to the whole selected block;
there is no latch-instruction cutoff.

The cost semantics are **static block sum**, not expected cost per execution.
Block ancestry deliberately over-includes: split-after-merge, hoisted or shared
code, setup/exit code merged into a target block, and alternative clones can all
increase the selected cost. Mixed-origin and unresolved block counts are reported.
The model does not use branch probabilities, PGO or active-lane averages.

Normalization is independent of membership. The materializer records nominal
`W0 = actual VF × IC`, including an exact vscale for scalable vectors. A retained
body uses W0 even when its trip count is unknown; materialization of one finite
body also preserves W0. Whole-loop SCEV backedge counts supply an exact body trip
count or constant upper bound, using checked integer conversion. Successful IR
unrolling records the actual expansion factor before the loop evidence is lost:
full unroll uses W0 times the expansion count; partial unroll uses W0 times U,
not the total trip count. Full unroll from a bound is reported as upper-bound
normalization, not exact dynamic frequency. Alternative cloning does not multiply
width. Multiplication overflow fails rather than truncating or saturating.

Unknown-trip unrolling, unrolling only one alternative or an enclosing loop,
mixed remainder/repeated domains, peeling and unroll-and-jam are unsupported
normalization cases. Partial unrolling without a
separate runtime remainder is supported when the body count or bound is known.
Loop disappearance without a finite expansion certificate is rejected at the
suffix boundary and again immediately before instruction selection. GlobalISel,
FastISel and software pipelining are explicitly unsupported for observation;
native final-codegen options retain their meanings. Missing provenance can reject
additional lowering paths. No failure authorizes a backend retry or zero cost.

The propagation audit for the native suffix/backend is:

| Transformation family | Handling |
|---|---|
| Assumption/alignment passes, register allocation, spill rewriting, VSETVLI and instruction-local lowering | Preserve block ancestry and nominal iteration units |
| CloneBasicBlock, IR split/merge, LICM, sinking, SimplifyCFG, CSE, SLP/VectorCombine, detached instruction moves | Common clone/transfer/replacement hooks; void-instruction sharing, LICM memory promotion and control-only block merges explicitly preserve their sources |
| Loop unroll | Success-only expansion certificate with exact/bounded whole-loop SCEV evidence |
| Unswitch and tail duplication | Alternative clones retain origins without changing width |
| Edge/predecessor splitting | Factored predecessor edges supply their causes, including new loop preheaders; other unresolved boundary edges fail conservatively |
| SelectionDAG condition/switch expansion, RISC-V custom inserters and frame/pseudo expansion | Explicit current-MBB inheritance |
| Machine CSE and branch-folding shared tails | Explicit source union before deleting shared code |
| Peeling, unroll-and-jam, software pipelining | Unsupported iteration-domain change |

Later transformations may change the block set or invalidate MIR without
erasing a successful earlier spill observation. The propagation audit describes
supported hooks, not measured coverage or accuracy.

## Scalar, main and epilogue context

A MIR attempt observes one original-loop fixed VF1/IC1 scalar baseline and shares
it across vector candidates and epilogues. It clones the whole function,
preserving preceding-loop context, disables LV vectorization/interleaving only
for the observed scalar loop, and runs the same native suffix. Scalar `Et` comes
from original VF1 register usage before tail-folding/predication changes, not
from inferred register counts in observed spills.

Main probes include forced epilogues. Automatic epilogues retain upstream
main-then-epilogue ordering and filtering and are queried in the selected main
context with epilogue IC1. Forced-selection bypasses and native IC policy remain
unchanged. Known trip counts, scalar tails and profitability use exact scalar
rationals throughout.

## Whole-loop fallback and reuse

| Request | Attempt order |
|---|---|
| MIR observed | MIR → TTI observed → TTI estimated → native |
| MIR estimated | MIR estimated → TTI estimated → native |
| TTI observed | TTI observed → TTI estimated → native |
| TTI estimated | TTI estimated → native |

Every attempt retains the requested default/tuned policy. Scalar selection is a
successful attempt. Required scalar/main/epilogue failure discards that attempt's
cost table, scalar baseline, pruning, selection and provisional reports.

Raw observations survive only within the original-loop invocation. Reuse requires
matching candidate identity, role, VF/IC, main/epilogue and scalar-tail geometry,
materialization context, CFG reduction, mapping policy revision and normalization
policy revision (including static branch sum and trip-bound semantics).
Required slot availability is checked separately. Stop stage alone does not
prevent reuse. MIR's full context cannot be treated as equivalent to a reduced
spill probe. Recompute pricing/pruning for each model; do not persist IR or
machine ranges across stages, attempts or loops.

<a id="비용-하한-pruning"></a>

## Gate and candidate pruning

For TTI observed-spill modes, the pressure gate queries when usage is unknown or
`(PeakBound + HasMask) × MaxRegisterGroup × IC >= 32`. Unsupported lowering and
overflow are unknown. A safe skip applies `Sv=0` without claiming an observation.
MIR bypasses the gate and TTI estimated performs no backend queries.

The real-spill lower bound is `L-Ev`, because observed spill costs are nonnegative.
Prepare native IC, configured costs and gate decisions first. Order queries by
normalized lower bound; prune only strict losers against valid scalar, gate-skip
or completed costs. Ties and proof overflow remain live. Forced vectorization
cannot use scalar selection as a pruning incumbent. A dominated failed query
does not force fallback; a required surviving failure does.

Automatic pruning requires disabled vector epilogues, unforced main/epilogue
VFs and compatible fixed/scalable and scalar-tail policies. Known-trip-count
comparisons use the existing body/tail objective; unknown counts use exact
cost-per-width comparisons. Force-all bypasses gate/pruning but records the gate
decision and does not enable queries for TTI estimated modes.

## Probe pruning

CFG reduction is a separate, default-ON vector-spill policy and never applies to
MIR. After materialization it retains the observed header's forward/backward
closure union. Eligible exclusive paths return using existing available values.
ABI, EH/indirect control, SSA, vector lifetime, surrounding cycles, return
ambiguity and switch guards constrain applicability. Missing/ambiguous observation
identity leaves the clone unchanged. Reduced CFG context belongs in the cache
key; unchanged global allocation is not guaranteed.

<a id="제한된-probe-병렬-실행"></a>

## Worker execution

Main-candidate workers own separate contexts, modules, target machines and
analyses reconstructed from a bitcode snapshot preserving use-list and preceding
loop context. They never share original IR/VPlan pointers or mutable target
state. Pricing, completion callbacks, reporting and selection run on the compiler
thread; final selection follows original candidate order. Scalar and automatic
epilogue queries remain serial. A singleton query avoids worker startup.

Probing owns cancellation checks, cleanup and joins; pruning only requests
cancellation. On-demand analyses finish, legacy passes stop at safe boundaries,
and all workers join before fallback. Fatal assertions are not isolated.
Required costs and selections match serial execution, although speculative
queries and physical completion states may differ. Query-free invocations do
not create pools/snapshots. Only invocation start resets diagnostic accounting.

Cost/JSON reports support parallel execution. Incompatible upstream diagnostics,
interactive allocator channels, timing or forced-epilogue reporting serialize
execution and warn once when multiple main queries actually need it.

<a id="타깃별-costsheet"></a>

## Pricing and reports

Target evidence and prices: [XiangShan](costsheet/xiangshan.md),
[Saturn](costsheet/saturn.md), [K1](costsheet/k1.md). RVV capability is checked
before VLEN queries. Generic MIR and native TTI cover other CPU/VLEN settings.

Reports consume already computed values. They must not cause TTI queries,
reprice candidates or compile probes. Native fallback discards attempted backend
cost reports and restores native reporting. Internal clones emit no cost reports.
Text reports show scalar source and exact cost, main/epilogue identity, body and
ranking costs, comparisons, selected IC and emission. Forced unevaluated costs
remain `not-evaluated` rather than fabricated values.

JSONL distinguishes requested/effective model, ordered fallback attempts,
collection versus use, gate skips and pruning. Independent-observation schema
`related-block-observations-v3` contains `spill_observation` and `mir_observation`;
compatible top-level fields reflect the applied model. MIR records use
`mir-body-observation-v2` and prices use `direct-instruction-cost-v1`. Scalar
baseline rows have `role=scalar-baseline` and are excluded from vector totals.
Unknown opcode counts, sheet revision, `R/S/Et`, exact numerator/denominator,
width and configuration remain distinct. Divide a quarter-cost numerator by
four times its denominator to obtain textual model units.

Mapping reports `mapping_kind=related-blocks`,
`region_granularity=machine-block-set`, and `body_cost_semantics=static-block-sum`.
Mapping and normalization have independent status/failure fields. Counts of
selected, mixed-origin and unresolved blocks accompany materialized/observed
widths, normalization basis, body-domain trip-count kind/value, and policy
revisions. Worker-local origins and object addresses are not persistent identities.
Pruned unobserved candidates have bounds, not invented body costs. Physical
execution may be not-started, cancelled or completed without changing logical
selection. Failed-attempt diagnostic ledgers remain separate from discarded
provisional cost reports.

Timing is inert when disabled. Enabled timing separates probe phases, cost
preparation and failed partial pipelines. Totals include their subintervals and
must not be added again. Diagnostic timings are separate from ordinary compiler
measurements; parallel comparisons require external process measurements.

<a id="scalar-기준과-검증-계약"></a>

## Validation evidence

Behavior tests cover exact pricing, independent slots, scope/width proof,
whole-loop fallback, configured scalar costs, gate/pruning, reuse, cancellation
and report passivity. Opt-only tests isolate observers from final object codegen.

Coverage, payload fidelity and scope accuracy are separate claims. Compare
matched candidates, stage, scope, width and payload before interpreting assembly
differences; never count fallback as a zero spill or MIR observation success.
Matching stage payloads validates collection and classification, but does not
establish loop-only cost for mixed-origin blocks. Transformed iteration widths
remain unverified by independent measurements; compiler success or unchanged
before/after widths do not establish normalization accuracy.
