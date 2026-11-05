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
| Probing | Materialization, backedge tracking, iteration widths, native suffix/backend, independent observations, raw cache and worker lifetime | Prices, dominance or fallback model order |
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

For N tracked iterations, selection uses the uniform mean
`Wtti × Σ(Cq/Wq) / N`. Each `Wq` already includes IC and proven serial unrolling;
neither factor is divided out again. This is an explicit static cost policy,
not an execution-frequency estimate. The same coefficients apply to MIR R and S,
while configured TTI Et is already in candidate units. Non-MIR spill accesses are
aggregated and priced independently per loop and homogeneous physical group,
class and direction before exact scaling; aggregate hooks need not be linear.
Exact rational scalar, body, ranking and tail costs must
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
slots. Each slot owns status, stage, scope evidence and per-loop widths/payloads. Status
distinguishes not requested, not collected, failed and succeeded. A succeeded
empty payload for a validated loop is an observed zero, including empty MIR
payload. An empty loop collection, gate skip or failure is not an observed zero.
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
<a id="backedge-loop-mapping"></a>

## Body mapping and normalization

Each private probe Function owns a side table of independent iteration IDs,
nominal widths and labeled CFG backedges. Its MachineFunction owns a separate
machine table. Only the actual materialized scalar/main/epilogue target is
registered, with `W0 = actual VF × IC` and the existing exact-vscale conversion;
scalar baseline starts at 1. IDs are local to the probe. Body membership,
nesting and instruction origins are not persistent tracking state. Inactive
native paths do not allocate tracking tables.

Each observer obtains current dominance and LoopInfo independently. Every
registered ID must identify one natural loop: its labeled edges must exist,
share a header dominating their sources, and account for that loop's complete
backedge set. Missing IDs, conflicting labels, invalid widths, irreducible or
ambiguous correspondence and overlap between selected loop bodies fail the
observation. A deleted last backedge does not silently unregister its iteration.
Owned results contain each iteration's ID, width, selected block count and raw
facts, with no IR/MIR object pointers.

Membership is **the current natural loop's static block sum**. Both sides of a
branch and every inner helper-loop block are counted once. Preheaders and exits
outside the loop are excluded; exiting blocks inside it are included. Hoisted
code outside the loop is excluded and code sunk into the loop is included.
Helper dynamic trip counts, branch probabilities, PGO and active-lane averages
are not used. Spill/reload, VSETVLI and PHI-copy instructions need no ancestry.
Unknown code outside the target is not independently a mapping failure.

The tracking rules at completed transformations are:

| Transformation family | Required tracking behavior |
|---|---|
| Split, merge, bypass and successor transfer | Move the labeled logical edge to the actual resulting backedge; duplicate switch operands are one edge |
| Whole target-loop versioning or unswitch cloning | Register each surviving independent iteration separately with the original width |
| Serial partial unroll | Multiply only that iteration's width by the successful expansion factor, with checked overflow; unknown trip count alone is permitted |
| Enclosing-loop simple unroll | Register cloned inner targets separately without multiplying their widths by the outer factor |
| Runtime remainder | Register independently before recursive remainder unroll and preserve its own width |
| Partial latch/tail duplication | Preserve one iteration ID across its resulting latches; validate reducibility and correspondence |
| SelectionDAG branches/switches | Bind actual final machine successor edges, independently of PHI presence; source IRBB identity alone is insufficient |
| Custom insertion, atomic retry, stack probing and restore splitting | Transfer the original boundary through continuations; generated helper backedges do not acquire target IDs |
| Instruction movement, RA, spills, VSETVLI and instruction-local rewrites | No instruction ancestry propagation; observe the resulting current location |

Boundary updates use completed transformation correspondence; transient edge
removal is not itself a permanent failure. Speculative CFG rollback restores
tracking state too. A committed transformation whose mapping cannot be proved
records failure without disabling the native pass or undoing its optimization.
IR is checked after the suffix and before ISel; machine mapping is checked after
bridging and independently at both observers.

Full unroll, initially finite materialization, finite runtime remainders and
peeling prefixes are outside this observation policy. They are reported as
unsupported finite bodies, rather than silently averaging only surviving loops.
Unroll-and-jam that changes a target iteration domain is unsupported. Neither a
constant trip count nor identical widths proves equivalence of independent IDs.
GlobalISel, FastISel and software pipelining remain unsupported for observation;
final native codegen options retain their meanings. Mapping failure never
permits zero substitution or an extra backend retry.

Uniform averaging covers all registered repeated targets, including surviving
alternative clones and repeated backend remainders. It does not assert dynamic
weights or turn a backend remainder into an LV vector epilogue. Scalar and vector
observations use the same composition policy and exact rational arithmetic.
Later transformations may change scope or invalidate MIR without erasing the
independently owned successful Spill snapshot. These are tracking and pricing
contracts, not measured coverage or accuracy claims.

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
policy revision (including current-loop static sum and uniform-loop composition).
Cached snapshots retain every loop width and its geometry evidence; old ancestry
results are never reinterpreted as backedge observations.
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
`backedge-loop-observations-v3` contains `spill_observation` and `mir_observation`.
Slots use `rvv-vector-spill-v3` or `mir-body-observation-v3`, with a `loops` array
containing `id`, `iteration_width`, `selected_block_count` and `spills` or `body`.
There are no single-width/payload compatibility aliases or ancestry statistics.
Stage-level fields retain status/failure, mapping/normalization status/failure,
materialized width, total selected blocks and mapping/normalization revisions.

Mapping reports `mapping_kind=backedge-loops`,
`region_granularity=natural-loop-block-set`, `body_cost_semantics=static-block-sum`
and `composition=uniform-loop-mean`. Prices retain the target's
`direct-instruction-cost-v1` schema. `mir_loops` reports instruction prices,
per-loop raw R/S and exact mean contributions; `spill_loops` reports per-loop raw
spill prices and exact mean contributions. Aggregate R/S and the final selection
cost are exact fractions, not a raw sum scaled by a single synthetic width.
Scalar baseline rows have `role=scalar-baseline` and are excluded from vector
totals. Divide a quarter-cost numerator by four times its denominator to obtain
textual model units. Probe-local loop IDs and object addresses are not persistent
identities. Reports consume already computed facts/prices without re-probing or
re-pricing.

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
establish dynamic execution cost or measured scope coverage. Transformed widths
require transformation evidence; compiler success or unchanged before/after
widths alone do not establish normalization accuracy. Small TSVC smoke checks of
the standalone backedge analysis are distinct from end-to-end production probe
validation and do not establish a dataset-wide success rate.
