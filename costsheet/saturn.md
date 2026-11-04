# Saturn GEN/Shuttle V256D128

Effective tune CPU: `saturn-shuttle-v256d128`; exact VLEN: 256.
TTI profile: `saturn-shuttle-v256d128`. MIR model: `saturn-shuttle-direct-v1`;
revision: `saturn-native-relative-v1`. [Common rules](rule.md) define units,
conversion and error handling.

## TTI policy

All operation-family coefficients relative to native `RISCVTTIImpl` are 1:
scalar/vector arithmetic, memory, spill/reload, reductions, intrinsics, casts,
divide and sqrt. Legalization, promotion, materialization and constant
simplification remain native. There is no additional setup penalty, calibration
or CLI coefficient. The named profile identifies CPU/VLEN and fallback context.

## MIR 가격과 계수

MIR prices observed instructions using native-relative defaults, with vector fused
FP operations priced at L. For data LMUL or memory data EMUL D,
`L=max(1,D)` and `N=max(1,256D/SEW)`; memory uses opcode EEW instead of SEW.
These are assumed selection prices, not hardware timing evidence.

| 명령군 | 직접 비용 |
|---|---:|
| Scalar integer / memory / branch / configuration | 1 |
| Scalar integer divide / remainder | 4 |
| Scalar FP arithmetic / conversion / divide / sqrt | 2 |
| 일반 vector integer / conversion | L |
| Vector FP arithmetic / divide / sqrt | 2L |
| Vector FP fused multiply-add/subtract, widening 포함 | L |
| Vector integer divide / remainder | 4L |
| 고정 mask 논리 / scalar extract·insert | 1 |
| Contiguous vector memory | L |
| Strided / indexed memory | N |
| Unit-stride 또는 strided segment, F fields | NF |
| Gather VV / EI16 | L² |
| 기타 shuffle / slide / compress | L |
| 일반 reduction | max(1,ceil(log2 N)) |
| Ordered FP reduction | N |
| Whole-register copy / load / store, group g | g |

Memory, reduction and DIV/SQRT multipliers are 1. Spill/reload uses direction-specific
Q, consistent with whole-register instruction prices. Group/access validation is
retained. Unknown opcodes cost 1 with an explicit unknown flag; invalid geometry
fails. Ordinary MIR body cost already includes spills.

The implementation is [RISCVCostSheet.cpp](../llvm/lib/Target/RISCV/RISCVCostSheet.cpp),
with opcode classification in [the tables](../llvm/lib/Target/RISCV/RISCVCostSheetTables.inc).
This MIR table does not reproduce every TTI legalization/materialization sequence,
so equality with all IR prices is not claimed. Default-TTI does not replace the
MIR sheet; scalar/vector composition follows the backend contract.
