# Backend feedback contract

The master flag enables in-process VF selection for supported RISC-V RVV loops
in reciprocal-throughput mode. Other targets, non-RVV functions, outer loops and
other cost kinds retain native selection. [README](README.md) owns options,
usage and build instructions; [pricing rules](costsheet/rule.md) own conversions
and target documents own prices and evidence.

## Ownership

| Module | Owns | Does not own |
|---|---|---|
| MIRInfo / Pricing | Native subtarget pricing, TTI/MIR information, facts pricing, exact normalization and cost composition | Probe execution, observation success or cancellation |
| Probing | Materialization, backedge tracking, iteration widths, native suffix/backend, independent observations, raw cache and worker lifetime | Prices, dominance or fallback model order |
| Gate / Pruning | Pressure bounds, candidate ordering, dominance, cancellation requests | Mapping decisions, payload ownership or worker joins |

LV coordinates attempts: costs, scalar baseline, main/epilogue selection and
provisional reports are adopted or discarded together. The dependency direction
is `LLVMVectorize → analysis callback → LLVMPasses → TargetMachine`. No CodeGen
or target-specific link dependency is introduced into Vectorize. `TargetMIRInfo`
is a read-only pricing service supplied through that callback.

<a id="bodyspill-ablation과-mir-info"></a>

## Costs and comparison scope

| Mode | Vector body | Original scalar baseline |
|---|---|---|
| TTI observed total spill | `L - Et + Ot` | Configured TTI scalar IR cost + `Ot_scalar` |
| TTI estimated | `L` | Configured TTI scalar IR cost |
| MIR observed | `R_vector - S_vector + Ot_vector` | `R_scalar - S_scalar + Ot_scalar` |
| MIR estimated spill | `R_vector - S_vector + Et_vector` | `R_scalar - S_scalar + Et_scalar` |

`L` includes the register-pressure estimates supplied by existing LLVM policy.
`Et` is the existing total scalar/vector register-pressure estimate. An inactive
pressure policy legitimately produces zero; this update does not activate it.
`Ot` prices observed GPR/FPR/vector spill accesses through the aggregate TTI
hook: scalar group 1, vector physical group g, separately by class and direction.
Native RISC-V charges one unit per register for each store or reload, without D.
`R` is the Generic MIRInfo body cost and `S` its spill-slot instruction subtotal.
Separate address calculations remain in `R-S`; ordinary MIR prices are unchanged.

The original scalar baseline uses VF1/IC1. TTI observed adds `Ot_scalar` to its
existing IR baseline, without subtracting an estimate that was never present.
MIR estimated retains the original VF1 register-usage estimation policy.

All TTI queries use native RISCVTTIImpl. Generic MIRInfo snapshots the actual
subtarget's native pricing inputs; CPU-specific sheets and scoped overrides are
removed. Native IC, probe optimization and final codegen retain upstream policy.

For N successfully priced native loops, selection uses the uniform mean
`Wtti × Σ(Cq/Wq) / N`. Each `Wq` includes IC and proven serial unrolling;
neither factor is divided out again. `Wq` need not be a multiple of `Wtti`. This
is an explicit static cost policy, not an execution-frequency estimate. The same coefficients apply to MIR R, S and Ot,
while configured TTI Et is already in candidate units. Observed spill accesses are
aggregated and priced independently per loop and homogeneous physical group,
class and direction before exact scaling; aggregate hooks need not be linear.
Exact rational scalar, body, ranking and tail costs must
survive comparison without truncation. `VPExactCost` uses quarter-cost numerators
and positive denominators, with 128-bit comparison cross products. Required cost
overflow fails the attempt; a pruning-proof overflow leaves the candidate live.

MIR observed composition intersects successfully priced MIR and spill loops by
identity and width, then applies the same exact normalization and uniform mean
to R, S and Ot. An empty intersection fails. Independent raw spill facts remain
available to TTI fallback even when MIR collection or pricing fails.

These ablations are not a fully orthogonal experiment: TTI versus MIR changes
body and scalar-baseline representations. Build success or an
ELF variant name does not establish that the requested model was applied; inspect
the effective model and fallback ledger.

<a id="probe와-fallback"></a>

## One probe pipeline and independent observations

```text
clone → activate private-function tracking → materialize and register body
  → native post-LV suffix → verify IR
  → instruction selection / pre-RA optimization and scheduling
  → RVV allocation / rewrite → VSETVLI insertion → scalar allocation / rewrite
  → StackSlotColoring → remaining native backend
  → common post-frame-lowering observer (optional MIR facts)
```

All executed probes stop at the common observer pass ID at post-frame-lowering,
after RISC-V post-RA pseudo expansion, KCFI and load/store optimization in
`addPreSched2`, before final scheduling and RVV pseudo expansion. There is no
earlier observer or post-frame retry. Spill-only and MIR probes keep identical
CFG and materialization policies. The later stop does not guarantee faster probes.
PGO, GlobalISel and user start/stop pipelines remain outside the supported
research scope. FastISel flags use RISC-V's existing SelectionDAG path. Allocator
names do not restrict support: each slot uses its actual observation result.
Missing StackSlotColoring or frame lowering affects the corresponding slot;
missing observations never become zero spills.

Each query has one identity-initialized result with independent Spill and MIR
slots. Each slot owns status, stage, scope evidence and per-loop widths/payloads.
Status distinguishes not requested, not collected, failed and succeeded. A succeeded
empty payload for a validated loop is an observed zero, including empty MIR
payload. An empty loop collection or failure is not an observed zero.
One failed slot must not erase the other's valid observation; an unrequested MIR
slot must not make a spill-only query fail.

The spill collector accepts spill-slot memory accesses with allocated physical
GPR/FPR/RVV data registers, preserving direction, group, size, alignment and address
space. Segment accesses use the same physical-group decomposition as lowering.
It excludes ordinary non-spill stack and whole-register memory accesses. MIR
records scalar/vector body instructions, geometry and spill-slot classification.
Both collectors omit metadata, upstream pseudoprobes, returns and frame
setup/destroy overhead.
Owned results contain no IR/MachineInstr pointers. MIR text is captured only when
requested for detailed reporting.

<a id="backedge-loop-mapping"></a>

## Body mapping and normalization

Each private probe Function owns a side table of independent iteration IDs,
nominal widths and labeled CFG backedges. Its MachineFunction owns a separate
machine table. Only the actual materialized scalar/main/epilogue target is
registered, with `W0 = actual VF × IC` and the existing exact-vscale conversion;
scalar baseline starts at 1. IDs are local to the probe. Body membership,
nesting and instruction origins are not persistent tracking state. Inactive
native paths do not allocate tracking tables.

Both observers use the same collection and backedge-mapping path, independently
recomputing dominance and LoopInfo at their observation stages. Their surviving
loop sets can differ. Actual backedges identify current native loops; missing
edges, eliminated loops and undefined widths are excluded. The observer does not
require all registered
IDs, all backedges, old headers, reducible helper CFGs, or disjoint historical
bodies to survive. Same-loop/same-width aliases count once. Several independent
loops sharing q count separately. Width contradictions invalidate affected IDs
and aliases, including dependent clones, rather than unrelated targets.
Owned results use a unique common mapped `id` for joins and retain q as
`tracking_id`.

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
| Partial latch/tail duplication | Preserve one iteration ID across its resulting latches; preserve the resulting iteration boundary |
| SelectionDAG branches/switches | Bind actual final machine successor edges, independently of PHI presence; source IRBB identity alone is insufficient |
| Custom insertion, atomic retry, stack probing and restore splitting | Transfer the original boundary through continuations; generated helper backedges do not acquire target IDs |
| Instruction movement, RA, spills, VSETVLI and instruction-local rewrites | No instruction ancestry propagation; observe the resulting current location |

Boundary updates use completed transformation correspondence. Deletion removes
connections without sticky failure; speculative CFG rollback restores tracking
state too. No pass-boundary completeness verifier rejects surviving targets.
Width overflow makes only affected q undefined and stays undefined through
cloning. Unroll-and-jam multiplies the inner target width by the actual factor;
enclosing simple unroll/peel clones independent inner targets without changing
their widths. Finite trip counts are supported while a loop remains. Full-unrolled bodies and
peeled finite prefixes are excluded, with no usable target reported unavailable.
Default/peeling software-pipeline kernels retain W; MVE kernels use
W × NumUnroll while the original fallback loop retains its independent W.

Collection errors exclude a complete loop from that stage. Model-local pricing
errors exclude a complete loop only from that model, preserving raw facts for
reuse. MIR R/S share the same included set, and the mean uses only successfully
priced loops. N=0 is unavailable. Unknown-opcode prices and estimated-spill
substitution retain their existing meaning. Report-only raw-sum overflow is
represented as JSON null and cannot reject valid normalized selection costs.

Uniform averaging estimates the surviving repeated targets rather than total
execution cost or dynamic path weights. Later exclusions cannot erase an earlier
successful Spill snapshot. These are contracts, not measured coverage or
accuracy claims.

## Scalar, main and epilogue context

A MIR or TTI observed attempt observes one original-loop fixed VF1/IC1 scalar baseline and shares
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

Every attempt retains the requested spill policy. Scalar selection is a
successful attempt. Required scalar/main/epilogue failure discards that attempt's
cost table, scalar baseline, pruning, selection and provisional reports.

Raw observations survive only within the original-loop invocation. Reuse requires
matching candidate identity, role, VF/IC, main/epilogue and scalar-tail geometry,
materialization context, CFG reduction, mapping policy revision and normalization
policy revision (including current-loop static sum and uniform-loop composition).
Cached snapshots retain every loop width and its geometry evidence.
Required slot availability is checked separately. Stop stage alone does not
prevent reuse. Both modes now use the same full CFG. Recompute pricing/pruning for each model; do not persist IR or
machine ranges across stages, attempts or loops.

<a id="비용-하한-pruning"></a>

## Gate and candidate pruning

The vector pressure-bound implementation is retained for diagnostics and future
use, but disabled in selection: it cannot prove absence of scalar spills.
Bounds are hypothetical and never skip observation or supply zero costs.
TTI estimated performs no backend queries.

The real-spill lower bound is `L-Et`, because observed spill costs are nonnegative.
Prepare native IC, configured costs first. Order queries by
normalized lower bound; prune only strict losers against valid scalar or completed costs. Ties and proof overflow remain live. Forced vectorization
cannot use scalar selection as a pruning incumbent. A dominated failed query
does not force fallback; a required surviving failure does.

Automatic pruning requires disabled vector epilogues, unforced main/epilogue
VFs and compatible fixed/scalable and scalar-tail policies. Known-trip-count
comparisons use the existing body/tail objective; unknown counts use exact
cost-per-width comparisons. Force-all bypasses candidate pruning but records the hypothetical bound and does not enable queries for TTI estimated modes.

## Probe pruning

CFG reduction is disabled for all feedback probes. The compatibility switch is
inert and diagnostics report this disabled state. Raw reuse still requires the
same full CFG, mapping and materialization context.

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

Current instruction pricing follows [Generic MIRInfo specification](costsheet/generic_mirinfo.md),
revision `generic-mirinfo-native-v1`. RVV capability is checked before VLEN
queries. All supported CPUs use native TTI and Generic MIRInfo. Former target
tuning and evidence are retained under `costsheet/`, outside the build.

Reports consume already computed values. They must not cause TTI queries,
reprice candidates or compile probes. Native fallback discards attempted backend
cost reports and restores native reporting. Internal clones emit no cost reports.
Text reports show scalar source and exact cost, main/epilogue identity, body and
ranking costs, comparisons, selected IC and emission. Forced unevaluated costs
remain `not-evaluated` rather than fabricated values.

JSONL distinguishes requested/effective model, ordered fallback attempts,
collection versus use, disabled gate state and pruning. Independent-observation schema
`backedge-loop-observations-v5` contains `spill_observation` and `mir_observation`.
Slots use `register-spill-v6` or `mir-body-observation-v6`, with a `loops` array
containing `id`, `tracking_id`, `iteration_width`, `selected_block_count` and
`spills` or `body`. Priced loop arrays may be subsets of raw observations; join
them by common mapped `id` and use the priced set size for its mean.
Slot-level fields retain independent slot status, stage, `iteration_mapping`,
materialized width, total selected blocks and mapping/normalization policy
revisions (mapping 4, normalization 3). Mapping and normalization have no separate status or failure
fields.

The only failure/exclusion report is `schema=vplan-backend-failures-v1`,
`status=backend-failures`, appended through `-vplan-backend-jsonl`. One row per
original LV loop is emitted only when records exist and contains `function`,
`invocation`, `loop`, `requested_model`, `effective_model` and ordered `attempts`. Each attempt retains `model`,
`use_estimated_spill`, `status` (`failed` or `succeeded`), owned
`observations`, and `failures`. An exclusion can accompany a successful requested
model; actual fallback means requested and effective models differ. Native fallback
uses `effective_model=native` and the same ledger, discarding attempted cost rows.

Failure groups appear in this order; empty groups are omitted:

| ID | Owning checks |
|---|---|
| `availability` | Unsupported input/configuration, unavailable provider/model, missing observer/stage |
| `integrity` | Candidate/function/role/materialization identity, malformed owned payload, invalid service result |
| `tracking` | No observable native target loop, lost correspondence, undefined/conflicting/overflowing width |
| `collection` | Uninterpretable spill accesses, register groups, memory operands or collected facts |
| `pricing` | Instruction/TTI prices, normalization, composition, ranking or cost arithmetic |
| `execution` | Snapshot restoration, invalid IR, TargetMachine/pipeline construction or backend diagnostics |

Each group contains `id`, `count`, and `items`; `count` is the number of deduplicated
items. An item owns `candidate`, `stage`, `detail` and, when known, `tracking_id`
(q) and `observation_id`. Stages are `input`, `materialization`, `probe`,
`selection` and `post-frame-lowering`. Unknown IDs
are omitted. Detailed errors remain intact within stable groups; classification
is explicit at checks or subsystem boundaries, never inferred from text.

Results and evaluated costs own records until consumption. Consumed candidates
retain failures in either requested slot and local tracking, collection and
pricing exclusions, including partial success and all-excluded results. Per-attempt
records sort/deduplicate by group, candidate, stage, optional IDs and detail;
cache reuse and propagation do not multiply evidence. Distinct attempts retain
distinct contexts. Cancelled, dominated and unconsumed work creates no ledger
entries. Gate/pruning skips, serial execution, cache misses, unknown opcode prices
and successful scalar selection are not failures. Exclusion capture is enabled
only for JSONL; primary errors still propagate when reporting is disabled.
Only LV emits the combined failure row after choosing the effective model.

Selected, candidate, scalar and pruned rows also carry `invocation`. Join final
outcomes by `(case, configuration, function, invocation, loop)`. Native fallback
outcomes report unknown VF and emission as JSON null. Candidate IDs and q/observation
IDs are local identities, qualified by configuration, attempt and observation
stage. No separate fallback rows, concatenated reasons, candidate `cost_failure`,
observation failure strings or text fallback summary are emitted. Cost, pruning
and timing diagnostic records remain separate from this failure ledger.

Mapping reports `mapping_kind=backedge-loops`,
`region_granularity=natural-loop-block-set`, `body_cost_semantics=static-block-sum`
and `composition=uniform-loop-mean`. Prices retain the target's
`direct-instruction-cost-v1` schema. `mir_loops` reports instruction prices,
per-loop raw R/S and exact mean contributions; `spill_loops` reports per-loop raw
spill prices and exact mean contributions. Aggregate R/S and the final selection
cost are exact fractions, not a raw sum scaled by a single synthetic width.
Scalar baseline rows have `role=scalar-baseline` and are excluded from vector
totals. Divide a quarter-cost numerator by four times its denominator to obtain
textual model units.

Pruned unobserved candidates have bounds, not invented body costs. Physical
execution may be not-started, cancelled or completed without changing logical
selection. Failed-attempt diagnostic ledgers remain separate from discarded
provisional cost reports.

Timing is inert when disabled. Enabled timing separates probe phases, cost
preparation and failed partial pipelines. The `ir_verification` phase measures
module verification after the native post-LV suffix; backedge mapping runs later
inside each observer's collection interval. Its timing fields are
`ir_verification_wall_seconds` and `ir_verification_cpu_seconds`. Totals include
their subintervals and must not be added again. Diagnostic timings are separate
from ordinary compiler measurements; parallel comparisons require external
process measurements.

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
