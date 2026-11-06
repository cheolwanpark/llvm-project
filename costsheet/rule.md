# Pricing and conversion rules

Current prices are native reciprocal-throughput heuristics, not measured cycles.
[Generic MIRInfo specification](generic_mirinfo.md) owns instruction mappings; the
[backend contract](../BACKEND_FEEDBACK.md) owns observation, composition and fallback.
Target sheets and `archive/` preserve former tuning and are not build inputs.

Native TTI retains legalization and sequence estimation. Generic MIRInfo prices
actual instructions, without adding predicted legalization or materialization.
Unknown instructions and missing/invalid required geometry return errors, never
implicit prices. Explicit policy-ignored zero and nominal pseudo 0/1 remain
separate documented policies.

## Spill units and exact normalization

Collectors return facts, not prices. Group observed accesses by register class,
direction and physical register group `g`. For `n` homogeneous accesses, pass
`SpillReloadUnits(Q=g*n, A=n)` to the configured aggregate TTI hook. Never average
different groups: `{1,1,4}` produces `(2,2)+(4,1)`, while `{2,2,2}` produces `(6,3)`.
Estimated excess registers use direction-specific `(n,n)` group-1 assumptions.
Empty units are `(0,0)`; scalar classes use single-register accesses.

The default aggregate hook respects existing single-register overrides and scales
by Q. The unit type validates `(0,0)` or `0<A≤Q≤INT64_MAX`; the observer/pricing
caller keeps physical groups homogeneous. Segment facts follow physical register decomposition, retaining actual
sizes, alignment and address spaces. Slot size is not a substitute for an access's
opcode/register geometry.

MIR spill-slot classification determines the removable term; ordinary whole-register
operations have the same instruction price but are not spill-slot costs. Separate
address calculations stay in the body. Multiply observed prices by `Wtti/Wobs`
exactly once: Wobs already incorporates IC and proven suffix unrolling. Preserve
rational scalar/vector/tail costs through ranking. Integer target prices can yield
fractional normalized costs. Quarter-cost numerators divided by `4*denominator`
give model units. Never pre-price units or round before comparisons.

Observed spill prices use the same aggregate TTI hook in TTI and MIR modes.
For native RISC-V, Ot is the sum of physical register groups over stores and
reloads; scalar g=1. Do not multiply Ot by D. This controls ablation prices rather
than claiming measured-cycle accuracy. MIR removes its original spill subtotal S
before adding Ot (observed) or Et (estimated). Normalize composed terms over the
same valid loop set and widths; do not combine independently averaged subsets.
