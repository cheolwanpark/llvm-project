# Pricing and conversion rules

This document owns units, conversion and evidence policy. Target documents own
prices: [XiangShan](xiangshan.md), [Saturn](saturn.md), [K1](k1.md). The
[backend contract](../BACKEND_FEEDBACK.md) owns observation scope, cost composition,
selection and fallback.

## Units and evidence

Prices are additive nominal core-cycle equivalents for normally supplied
instructions. They do not model global issue overlap, dependency latency, bank
conflicts, cache/TLB misses, runtime VL, stride or mask density. Scalar default
cost 1 is not divided by the number of ALUs. No calibration factor reconciles
native TTI with measured loop time. Saturn/K1 MIR uses native-relative prices,
not hardware service times.

Prefer official specifications, then instruction-specific occupancy evidence
(including fixed-configuration RTL), then explicit `ReleaseAtCycles` from a fixed
scheduler revision, then labelled assumptions. Latency/pipeline depth does not
establish throughput. Record ISA/form, precision, VLEN, execution/memory width,
initiation interval, sequencer and address-generation structure. GHz, TOPS and
peak DRAM bandwidth alone cannot determine prices. Assumptions are not guaranteed
hardware upper bounds; uncertain supported prices are not disguised as unknown.

## TTI and MIR adapters

XiangShan TTI prices its predicted opcode sequence through the target sheet.
Saturn/K1 retain native RISC-V TTI sequence construction and prices. MIRInfo prices
observed opcode/geometry facts directly. Legalization and materialization are
applied once by TTI. Fixed vectors use RVV containers; widening uses narrow-source
geometry, narrowing narrow-destination geometry. Uniform operand forms and index
geometry affect sequence choice. Missing TTI index geometry retains inherited
sequence estimates. Predicted and observed lowering need not have equal totals.

Scalar XiangShan adapters cover supported arithmetic, memory, sqrt/fma and casts;
power-of-two unsigned divide/rem simplifies before pricing. Unsupported sequences
and branch/control adapter paths remain native. Scoped comparison pricing never
changes native IC, probe optimization or final codegen.

Unknown opcode/sequence is distinct from invalid input. MIR unknown costs 1 and
increments the unknown count; unsupported TTI sequences use inherited fallback.
Missing/impossible required geometry, unsupported required precision and overflow
are errors. Observation failure is never converted to zero spill. Rule identifiers
name formulas; XiangShan's retained rule names do not encode evidence quality.

<a id="spill--units--tti--costsheet"></a>

## Spill units and exact normalization

Collectors return facts, not prices. Group observed accesses by register class,
direction and physical register group `g`. For `n` homogeneous accesses, pass
`SpillReloadUnits(Q=g*n, A=n)` to the configured aggregate TTI hook. Never average
different groups: `{1,1,4}` produces `(2,2)+(4,1)`, while `{2,2,2}` produces `(6,3)`.
Estimated excess registers use direction-specific `(n,n)` group-1 assumptions.
Empty units are `(0,0)`; scalar classes use single-register accesses.

The default aggregate hook respects existing single-register overrides and scales
by Q. XiangShan validates `g=Q/A` and uses `A*f(g)`. Saturn/K1 use native aggregate
pricing. Segment facts follow physical register decomposition, retaining actual
sizes, alignment and address spaces. Slot size is not a substitute for an access's
opcode/register geometry.

MIR spill-slot classification determines the removable term; ordinary whole-register
operations have the same instruction price but are not spill-slot costs. Separate
address calculations stay in the body. Multiply observed prices by `Wtti/Wobs`
exactly once: Wobs already incorporates IC and proven suffix unrolling. Preserve
rational scalar/vector/tail costs through ranking. Integer target prices can yield
fractional normalized costs. Quarter-cost numerators divided by `4*denominator`
give model units. Never pre-price units or round before comparisons.

## Generic MIR sheet

Unsupported CPU/exact-VLEN settings use generic MIR and native TTI. Generic MIR
revision is `generic-v1`; nominal VLEN is the subtarget's actual minimum VLEN.
For data LMUL/EMUL D, use `L=max(1,D)` and `N=VLEN*D/SEW`; memory uses EEW.
Geometry validation and unknown/error distinctions remain mandatory.

| 명령군 | 직접 비용 |
|---|---|
| Scalar 일반 정수·load/store·branch·configuration | 1 |
| Scalar integer divide/remainder | 4 |
| Scalar FP 연산·변환·divide/sqrt | 2 |
| 일반 vector 정수·변환 | `L` |
| Vector FP 산술·divide/sqrt | `2L` |
| Vector integer divide/remainder | `4L` |
| 고정 mask 논리·scalar extract/insert | 1 |
| Whole-register copy/load/store, group g | `g` |
| Contiguous vector memory | `L` |
| Strided/indexed memory | `N` |
| Segment memory, F fields | `NF` |
| Gather VV/EI16 | `L²` |
| 기타 shuffle·slide·compress | `L` |
| 일반 reduction | `max(1,ceil(log2(N)))` |
| Ordered FP reduction | `N` |
| 미지원 opcode | Unknown 비용 1 |

Scalar FP loads/stores use memory pricing. These defaults are executable
selection heuristics, not measured cycles or hardware accuracy guarantees.
