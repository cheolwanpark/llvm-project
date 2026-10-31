# XiangShan Kunminghu v2 CostSheet

적용: effective tune CPU `xiangshan-kunminghu`, exact VLEN=128.
Model `xiangshan-direct-v1`, TTI profile `xiangshan-v2-128`.
[공통 규칙](rule.md)을 따르는 nominal 가격 모델이다.
이는 실측 throughput 표가 아니다. 기존 모델의 분해/이동 점유 대용값이다.

## 근거와 가정

고정 [RTL e7bab53e](https://github.com/OpenXiangShan/XiangShan/tree/e7bab53e66dfb3c4a1d11cf9519b0396f8576cae)의
VecDecoder.scala/DecodeUnit.scala 분류와 기존 reviewed opcode 표를 사용한다.
[공식 v2 구성](https://docs.xiangshan.cc/projects/user-guide/en/kunminghu-v2/typical-configuration/)은
FU 구성·latency의 보조 근거다. 최신 V2R2A 가격을 고정 v2에 소급하지 않는다.
Opcode 지원·형태와 geometry는 RTL 근거다. 아래 +1 scalar 전달, memory setup,
scalar store=2, divide/sqrt 대표값, permutation 분해 횟수는 기존 모델의 명목 점유
근사다. Decoder 분류만으로 실제 throughput이 증명된 것은 아니며 별도 실측은 없다.
이러한 가정도 이 표에 명시된 지원 가격으로 사용한다.

### Vector 직접 비용

아래에서 `G=LMUL8`, `L=max(1,G/8)`, `W=max(1,G/4)`이고,
data element 수 `N=128×(G/8)/SEW`다. Memory는 data EMUL과 EEW로 element 수를
계산한다. Fractional LMUL, widening/narrowing과 index geometry를 검증한 뒤
opcode 분류에 따라 직접 가격을 반환한다.

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

Fold는 `(min(log2(G)-3,0)+C+8) mod 8`이며 C는 SEW 16/32/64에 대해 3/2/1이다.
Mask 논리, scalar extract/insert와 move는 opcode별 고정 또는 group 규칙을 사용한다.
지원 opcode와 형태의 정확한 분류는
[`RISCVCostSheetTables.inc`](../llvm/lib/Target/RISCV/RISCVCostSheetTables.inc),
geometry와 직접식은
[`RISCVCostSheet.cpp`](../llvm/lib/Target/RISCV/RISCVCostSheet.cpp)에 있다.
미지원 opcode는 unknown 표식과 명시적인 가격으로 구분하고, 잘못된 geometry나
지원하지 않는 산술 precision은 실패다. RTL revision
`e7bab53e66dfb3c4a1d11cf9519b0396f8576cae`는 출처이며 모델 버전과 별개다.
## Spill와 adapter

Vector 접근당 f(g)=g+1, aggregate Q+A. Scalar store=2Q, reload=Q.
예상 n=4 spill/reload는 총16, 관측 group-4 한 쌍은10이다.
TTI는 해당 opcode/형태를 예상하고 MIRInfo는 관측 opcode를 전달한다.
TTI lowering의 legalization·init/extract가 MIR과 다를 수 있다.
Scope 밖 및 다른 cost kind는 기존 RISCVTTIImpl을 사용한다.

## Scalar 가격의 근거와 범위

아래 scalar 가격도 위 RTL 분류와 기존 nominal 모델을 사용한다. RTL이 모든 숫자의
reciprocal throughput을 증명하는 것은 아니다.

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

위 값은 latency 표를 throughput으로 바꾼 값이나 새 실기기 측정치가 아니다.
RTL에 supported opcode가 있다는 것과 숫자의 hardware-validated accuracy는 별개다.

Scalar TTI adapter는 지원 산술, load/store, sqrt/fma intrinsic과 FP/정수 cast를
sheet로 가격화한다. Unsigned power-of-two divide/rem은 shift/and 단순화 가격을
먼저 사용한다. Branch/control 및 다루지 않는 sequence는 native TTI로 남으며
legalization/materialization은 inherited sequence를 따른다. Backend TTI 모드의
scalar 기준은 vector와 같은 configured TTI다. Scope 밖, 다른 cost kind와 미지원
CPU/VLEN은 native다. IC/probe 최적화/final codegen은 native 경로를 유지한다.

Scalar MIR은 실제 지원 scalar opcode와 branch/configuration, spill-slot access를
동일 sheet로 가격화한다. Unknown opcode는 비용 1과 unknown 표식을 남기며 수를
보고한다. 지원 가격의 불확실성은 unknown으로 숨기지 않는다. 일반 stack access와
주소 계산은 spill-slot `S`로 빼지 않는다. Scalar/vector MIR의 같은 관측 stage와
정확한 반복 폭 정규화, symmetric `R-S+Et`는 [공통 규칙](rule.md)을 따른다.
