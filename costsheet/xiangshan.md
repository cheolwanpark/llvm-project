> Source snapshot: `archive/`, from checkout 6e6cf039e3676069dd03ac25c095ef8eaaf6fc0d.
> Retained tuning record; no longer selected by the compiler. Current pricing: [Generic MIRInfo specification](generic_mirinfo.md).

# XiangShan Kunminghu v2

Effective tune CPU: `xiangshan-kunminghu`; exact VLEN: 128.
TTI profile: `xiangshan-v2-128`; MIR model: `xiangshan-direct-v1`.
Reported revision: `e7bab53e66dfb3c4a1d11cf9519b0396f8576cae`.
[Common rules](rule.md) define units, conversion and error handling.

## Evidence and assumptions

The fixed [RTL revision](https://github.com/OpenXiangShan/XiangShan/tree/e7bab53e66dfb3c4a1d11cf9519b0396f8576cae)
provides VecDecoder.scala/DecodeUnit.scala opcode/form classifications alongside
the reviewed opcode table. The [official v2 configuration](https://docs.xiangshan.cc/projects/user-guide/en/kunminghu-v2/typical-configuration/)
is supporting evidence for FU configuration and latency. Later V2R2A prices must
not be retroactively applied to this fixed v2 model.

Decoder support and geometry do not prove throughput. Scalar transfer +1, memory
setup, scalar store=2, divide/sqrt representatives and permutation decomposition
counts below are retained nominal occupancy assumptions, not new measurements.
Rule identifiers retain their historical names and do not encode evidence grade.

## Vector prices

With `G=LMUL8`, use `L=max(1,G/8)`, `W=max(1,G/4)` and
`N=128*(G/8)/SEW`. Memory uses data EMUL and EEW. Validate fractional LMUL,
widening/narrowing and index geometry before selecting the opcode formula.

| 명령군 / 형태 | 직접 비용 |
|---|---|
| 일반 vector VV 산술·변환 | `L` |
| 지원되는 vector VX/VI/VF 산술 | 해당 vector 연산 비용 + 1 |
| Vector integer divide/remainder (SEW 8/16/32/64) | `L × {11,13,17,25}`, scalar 형태는 +1 |
| Vector FP divide (SEW 16/32/64) | `L × {8,10,15}`, VF/reverse VF는 +1 |
| Vector FP sqrt (SEW 16/32/64) | `L × {7,10,17}` |
| Widening/narrowing | opcode별 `2L` 또는 `W`, scalar 형태는 +1 |
| Slide up/down (L=1/2/4/8) | `{1,3,10,36}+1` |
| Slide1 up/down | `L+1` / `(2L-1)+1` |
| Gather VV / VI·VX | `L²` / `L²+1` |
| Gather EI16 VV | SEW=8이고 G≠64이면 `2L²`, 그 외 `L²` |
| Compress (L=1/2/4/8) | `{1,4,13,43}` |
| 일반 integer reduction | `L` |
| Fold FP reduction | `L+Fold`, 아래 정의 |
| Ordered FP reduction | `max(1,N)` |
| Contiguous vector load/store | `L+1` |
| Strided vector load/store | `N+2` |
| Unordered indexed load / indexed store | `N+1` |
| Ordered indexed load | `4N+1` |
| Segment load/store, F fields | `8NF+T` / `4NF+T`; unit stride T=1, strided T=2 |
| Whole-register copy, group g | `g` |
| Whole-register load/store, group g | `g+1`, aggregate spill과 같은 가격 정의 |

For folded FP reduction,
`Fold=(min(log2(G)-3,0)+C+8) mod 8`, where C is 3/2/1 for SEW 16/32/64.
Mask logic, scalar extract/insert and moves use opcode-specific fixed/group rules.
[Opcode classification](archive/RISCVCostSheetTables.inc) and
[geometry/formulas](archive/RISCVCostSheet.cpp) define the exact
supported forms. Unknown opcodes have explicit unknown pricing; invalid geometry
or required unsupported precision fails.

## Scalar prices

| Scalar 명령군 | 비용 | 근거 수준 |
|---|---|---|
| 지원 integer add/sub/mul/shift/logic | 1 | 기존 nominal 기본값 |
| 지원 FP arithmetic/FMA | 1 | 기존 nominal 기본값; pipeline latency 아님 |
| Integer/FP load / store | 1 / 2 | 기존 nominal memory 값; miss/주소 비용 제외 |
| Branch/jump 및 configuration | 1 | 기존 nominal 기본값; predictor 비용 제외 |
| 지원 FP↔integer, FP precision conversion | 1 | 기존 nominal 기본값; latency 아님 |
| Integer divide/rem, W / XLEN, signed/unsigned | 15 / 23 | 기존 모델의 representative occupancy 가정 |
| FP divide, H / S / D | 7 / 9 / 14 | 기존 representative occupancy 가정 |
| FP sqrt, H / S / D | 6 / 9 / 16 | 기존 representative occupancy 가정 |
| Scalar spill / reload, Q registers | 2Q / Q | 기존 nominal scalar store/load와 같은 aggregate 가격 |

These scalar values are nominal defaults or representative occupancy assumptions;
latency has not been converted into throughput and RTL support is not a hardware
accuracy validation. Scalar TTI covers supported arithmetic, memory, sqrt/fma and
casts. Power-of-two unsigned divide/rem simplifies first. Branch/control and
unhandled sequences remain native; legalization/materialization follows inherited
sequence construction. Scalar MIR directly prices supported observed instructions,
including branch/configuration. Unknown opcodes cost 1 with an explicit count.

## Spill and adapter boundaries

Vector access `f(g)=g+1` gives aggregate `Q+A`; scalar store/reload costs `2Q/Q`.
For example, estimated four-register spill/reload costs 16, while one observed
group-4 spill/reload pair costs 10. TTI predicts a sequence; MIRInfo prices its
observed sequence. Legalization and initialization/extraction can make their
totals differ. Scope-outside and other cost-kind queries retain native RISC-V TTI.

Only actual spill-slot accesses contribute to MIR's removable spill term.
Ordinary stack accesses and separate address computation remain in the body.
Exact scalar/vector normalization and symmetric estimated-spill composition are
specified once in the [backend contract](../BACKEND_FEEDBACK.md).
