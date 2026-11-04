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
| Probing | Materialization, marker policy, scope proof, native suffix/backend, independent observations, raw cache and worker lifetime | Prices, dominance or fallback model order |
| Gate / Pruning | Pressure bounds, candidate ordering, dominance, cancellation requests and CFG reduction policy | Marker decisions, payload ownership or worker joins |

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
clone → materialize candidate → assess marker policy → insert eligible markers
  → configured CFG reduction → native post-LV suffix → finalize IR evidence
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
Both collectors omit metadata, markers, returns and frame setup/destroy overhead.
Owned results contain no IR/MachineInstr pointers. MIR text is captured only when
requested for detailed reporting.

<a id="experimental-region-probes"></a>

## Scope and marker policy

`VPlanBackendMarkerPolicy::assess` is read-only and returns insertion eligibility
and a reason. It checks identity, existing legal insertion positions and
instrumentation conflicts. The insertion helper adds constant-operand markers
without splitting blocks, changing edges or introducing live values. Markers are
normally enabled only in disposable probes; final emitted IR contains none.
Unknown geometry can carry identity markers but cannot authorize normalization.
Policy rejection leaves structural observation available. Eligibility does not
certify observation success or absence of scheduling/allocation effects.

IR suffix evidence is finalized once. Each machine stage independently proves:

1. **Structural scope:** a uniquely identified innermost loop whose header-to-latch
   path visits every body block once. Internal divergence and side entries are
   rejected; exits and backedges are confined to the latch. Affine or EVL width
   witnesses describe the whole path. Collection stops at the latch backedge.
2. **Marker scope, only if structural proof fails:** a finite linear execution
   path without branching, merging, cycles or side entries. Select the minimal
   block path containing matching candidate markers. Outside work or spills
   invalidate completeness; only debug, empty trampolines and computation-free
   return scaffolding are permitted, with the existing machine-frame exclusions.
3. Traverse the proved scope once for the requested payload. Payload/geometry
   failures do not choose another scope or rerun codegen.

Only after proving scope may marker order be ignored: begin and end counts must
be equal, positive and equal to the suffix pair count. GUID/index checks and
checked width multiplication remain mandatory. Observed marker width is nominal
materialized width times pair count, not active lanes or execution frequency.
Scalar marker pairs initially represent one original iteration.

Markers are not instruction fences. Work merged into a marked block can be
included; marker placement can affect optimization, scheduling and allocation.
The model does not prove equivalence to final assembly. Setup cost allocation,
probability-weighted early exits and averaging duplicated/nested regions are
unsupported. Structural and marker rejection reasons are preserved separately.

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
materialization context, CFG reduction and marker configuration/policy revision.
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
`independent-observations-v2` contains `spill_observation` and `mir_observation`;
compatible top-level fields reflect the applied model. MIR records use
`mir-body-observation-v1` and prices use `direct-instruction-cost-v1`. Scalar
baseline rows have `role=scalar-baseline` and are excluded from vector totals.
Unknown opcode counts, sheet revision, `R/S/Et`, exact numerator/denominator,
width and configuration remain distinct. Divide a quarter-cost numerator by
four times its denominator to obtain textual model units.

Marker recovery reports `scope=probe-region`, `region_granularity=machine-path`
and `region_probe_count`. `structural_failure` and `marker_failure` retain scope
rejections independently. Pruned unobserved candidates have bounds, not invented
body costs or observations. Physical execution may be not-started, cancelled or
completed without changing logical selection. Failed-attempt diagnostic ledgers
are distinct from discarded tentative cost reports.

Timing is inert when disabled. Enabled timing separates probe phases, cost
preparation and failed partial pipelines. Totals include their subintervals and
must not be added again. Diagnostic timings are separate from ordinary compiler
measurements; parallel comparisons require external process measurements.

<a id="scalar-기준과-검증-계약"></a>

## Validation evidence

Behavior tests cover exact pricing, independent slots, scope/width proof,
whole-loop fallback, configured scalar costs, gate/pruning, reuse, cancellation
and report passivity. Opt-only tests isolate observers from final object codegen.
Historical TSVC success counts describe retained compiler versions, not acceptance
thresholds. Compare matched candidates, stage, scope, width and payload before
interpreting assembly differences; never count fallback as a zero spill or MIR
observation success. The historical investigation remains available at baseline
commit `9106f2bc4734c4919467d20bae7bc8430f358f2d` and retained experiment artifacts.
