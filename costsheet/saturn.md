# Saturn GEN/Shuttle V256D128 CostSheet

선택: `-mtune=saturn-shuttle-v256d128 -march=rv64gcv -mrvv-vector-bits=256`.
Model `saturn-shuttle-direct-v1`, TTI profile `saturn-shuttle-v256d128`.
[공통 규칙](rule.md)을 따른다. Tune 이름은 ISA를 추가하지 않는다.

## 구성과 출처

로컬 rvv-simulator image의 Chipyard 1.14.0 (`0acc1e1d`), Saturn
`dfe75de2a8868d51d42c20612821431a9fcf645e`, GENV256D128ShuttleConfig,
pipelinedVatClear=true에 대응한다. VLEN=256, DLEN=MLEN=128, Split issue,
SIMD integer multiply/FMA, VRF banking=4다. VAT-clear 패치는 구성 식별에 포함하며
명령별 추가 penalty는 넣지 않는다. Application image의 RAM 크기는 가격 입력이 아니다.

고정 revision의 공식
[구성](https://github.com/ucb-bar/saturn-vectors/blob/dfe75de2a8868d51d42c20612821431a9fcf645e/chipyard/SaturnConfigs.scala),
[parameters](https://github.com/ucb-bar/saturn-vectors/blob/dfe75de2a8868d51d42c20612821431a9fcf645e/src/main/scala/common/Parameters.scala),
[datapath](https://github.com/ucb-bar/saturn-vectors/blob/dfe75de2a8868d51d42c20612821431a9fcf645e/docs/execute.adoc),
[memory](https://github.com/ucb-bar/saturn-vectors/blob/dfe75de2a8868d51d42c20612821431a9fcf645e/docs/memory.adoc),
[frontend](https://github.com/ucb-bar/saturn-vectors/blob/dfe75de2a8868d51d42c20612821431a9fcf645e/docs/frontend.adoc)가 근거다.

## 실제 가격 규칙

B=256*LMUL(또는 data EMUL), C=max(1,ceil(B/128)), N=max(1,B/SEW).
Memory N은 opcode EEW, indexed는 관측 data SEW를 사용한다. 위에서 아래 우선이다.

| 명령군 | 비용 | 근거 수준 |
|---|---|---|
| Whole-register copy/load/store group g | 2g | DLEN/MLEN에서 도출한 이상적 service |
| Contiguous memory, F fields | max(1,ceil(BF/128)) | F=1 도출, segment는 전치 효율을 생략한 가정 |
| Strided/indexed memory | NF | 주소 생성률 근거, segment는 보수적인 직렬 가정 |
| Vector divide/remainder/sqrt | 64N | iterative-elementwise 근거 + element당64 가정 |
| Reduction | integer N, FP 4N | 직렬 accumulator와 FMA depth 기반 가정 |
| Gather/compress | 2N | element-wise read/write를 직렬 합산한 가정 |
| VW/VFW/VNS/VNC/VFNC prefix의 지원 연산 | 2C | 넓은 데이터 처리 대용값 가정 |
| 기타 지원 SIMD (slide 포함) | C | DLEN sequencing, 특수 mask에도 이 근사 적용 |

64는 operand별 실제 하드웨어 상한 보장이 아니다. 데이터 의존 단축을 모델링하지
않기 위한 보수적인 대표 가정이며 vendor-guaranteed upper bound가 아니다. Scalar/vector spill은 방향별 Q / 2Q다.
예: m2 i32 add는4, m2 strided i32 load는16, group4 spill/reload 한 쌍은16.

이 표의 wide-service 분기는 위에 명시한 opcode prefix에만 적용한다.
`VSEXT_VF2/4/8`, `VZEXT_VF2/4/8`은 기타 지원 SIMD의 `C` 가격을 사용한다.

## Adapter와 한계

SaturnTTI는 자기 sheet로 예상 opcode를 가격화한다. SaturnMIRInfo는 같은 sheet를
전달한다. 공통 geometry 검증만 기존 generic decoder를 이용하며 generic 가격은
지원 타깃의 가격으로 재사용하지 않는다. 지원 외 opcode의 unknown 동작만 유지한다.
Shuttle의 vset forwarding 때문에 Rocket의 2-cycle bubble을 더하지 않는다.
Vector memory는 scalar L1 우회 coherent 경로이며 모든 접근을 L1 hit로 가정하지 않는다.
정상 공급 service만 가격화하고 miss·TLB·page replay·bank conflict·chaining은 제외한다.
Native scheduler는 기존 generic-rv64와 같은 X60 기반 근사이며 Shuttle scheduler를
구현한 것이 아니다. Scope 밖/native IC/probe/final codegen은 이 기존 native 경로다.

## Scalar 가격의 근거와 범위

Source는 위 고정 Saturn revision `dfe75de2a8868d51d42c20612821431a9fcf645e`의
Shuttle 구성과 이 sheet의 명시적 nominal 가정이다. 해당 vector RTL 문서가 scalar
core의 아래 명령별 throughput을 보장하는 것은 아니다.

| Scalar 명령군 | 비용 | 근거 수준 |
|---|---|---|
| 지원 integer add/sub/mul/shift/logic | 1 | nominal 기본 가정 |
| 지원 FP arithmetic/FMA | 1 | nominal 기본 가정; FMA latency와 별개 |
| Integer/FP load와 store | 1 | nominal 정상 공급 memory 가정 |
| Branch/jump 및 configuration | 1 | nominal 기본 가정; branch prediction 비용 제외 |
| 지원 FP↔integer, FP precision conversion | 1 | nominal 기본 가정 |
| Signed/unsigned integer divide/rem, 모든 지원 폭 | 64 | 제한된 정보에 대한 iterative 대표 가정 |
| FP divide/sqrt, 모든 지원 precision | 64 | 같은 대표 가정; vendor upper bound 아님 |
| Scalar spill / reload, Q registers | Q / Q | nominal scalar memory와 같은 aggregate 가정 |

Scalar TTI adapter는 지원 산술, load/store, sqrt/fma intrinsic과 FP/정수 cast를
sheet로 가격화한다. Unsigned power-of-two divide/rem은 shift/and 단순화 가격을
먼저 사용한다. Branch/control 및 다루지 않는 sequence는 native TTI이며 inherited
legalization/materialization을 따른다. Backend TTI scalar 기준은 vector와 같은 TTI다.
Scope 밖, 다른 cost kind와 미지원 CPU/VLEN은 native TTI다. Native IC/probe 최적화와
final codegen에 이 가격 scope를 전달하지 않는다.

Scalar MIR은 지원 scalar opcode, branch/configuration과 spill-slot access를 같은
sheet로 가격화한다. 미지원 opcode는 1+unknown이며 unknown 수를 보고한다. 일반
stack memory나 별도 주소 계산은 spill-slot `S`로 빼지 않는다. Supported price와
hardware-validated accuracy는 별개이며 scalar nominal=1과 iterative=64의 물리적
정확성을 새로 검증하지 않았다. Scalar/vector MIR의 같은 관측 stage, exact 반복 폭
정규화와 symmetric `R-S+Et`는 [공통 규칙](rule.md)을 따른다.
