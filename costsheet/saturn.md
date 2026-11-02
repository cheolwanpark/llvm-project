# Saturn GEN/Shuttle V256D128 CostSheet

적용: effective tune CPU `saturn-shuttle-v256d128`, exact VLEN=256.
TTI profile `saturn-shuttle-v256d128`, MIR model `saturn-shuttle-direct-v1`,
revision `saturn-native-relative-v1`. [공통 규칙](rule.md)을 따른다.

## TTI 계수

Saturn TTI는 `RISCVTTIImpl`의 가격과 lowering sequence를 그대로 사용한다.
Scalar/vector 산술, memory, reduction, intrinsic, cast와 spill hook을
별도 Saturn 가격으로 대체하지 않는다. Legalization, materialization,
promotion과 constant simplification도 native 구현을 따른다.

| 연산군 | Native TTI 대비 계수 |
|---|---:|
| Scalar memory / spill / reload | 1 |
| Vector memory / spill / reload | 1 |
| Reduction | 1 |
| Integer divide / remainder | 1 |
| FP divide / sqrt | 1 |
| 나머지 지원 연산 | 1 |

계수는 고정값이며 별도 CLI 설정은 없다. 전체 비용 재정규화나 setup penalty를
추가하지 않는다. Profile 이름은 CPU/VLEN 식별과 fallback 경로를 위한 것이다.
다른 cost kind, native IC, probe 최적화와 final codegen도 native 정책을 따른다.

## MIR 가격과 계수

MIR은 관측 opcode와 geometry를 직접 가격화한다. Generic MIR의 native-relative
기본값에 vector fused FP 연산의 가격 `L`을 적용한다. Data LMUL 또는 memory
data EMUL을 D라 하면 `L=max(1,D)`, `N=max(1,256D/SEW)`다. Memory N은
SEW 대신 opcode EEW를 사용한다.
아래 값은 선택용 상대가격이며 물리적 처리시간을 뜻하지 않는다.

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

Memory, reduction, DIV/SQRT의 추가 배율은 모두 1이다. Scalar/vector spill과
reload는 방향별 Q이며, whole-register body 가격과 같은 단위를 사용한다.
Group별 접근 정보와 aggregate units 검증은 유지한다.

MIR 표는 IR TTI의 legalization·materialization sequence 전체를 복원하지 않는다.
특히 intrinsic과 일반 산술의 가격 경로, widening, conversion 등에 차이가 있으므로
MIR 표와 native TTI가 모든 연산에서 동일하다는 뜻은 아니다.
Unknown은 비용 1과 unknown 표식을 유지하고 잘못된 geometry는 실패다.
Scalar/vector 기준, exact rational 정규화와 `R` / `R-S+Et`는 공통 계약을 따른다.
일반 MIR R에는 실제 spill이 이미 포함되며 spill 가격을 다시 더하지 않는다.
`use-default-tti=true`도 successful MIR의 표를 교체하지 않는다.
