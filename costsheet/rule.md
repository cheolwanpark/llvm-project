# CostSheet 작성·변환 규칙

이 문서는 가격과 변환의 규범이다. [README](../README.md)는 실행·빌드,
[BACKEND_FEEDBACK](../BACKEND_FEEDBACK.md)는 probe·선택·fallback 계약을 소유한다.
타깃 가격은 [XiangShan](xiangshan.md), [Saturn](saturn.md), [K1](k1.md)에 있다.

## 모델링하는 값

단위는 nominal core-cycle equivalent다. 정상적으로 operand와 메모리가 공급되는
명령의 서비스/자원 점유 비용을 합산한다. 독립 실행 경로의 overlap, 전체 issue 폭,
RAW/WAW dependency와 bank conflict를 합성하지 않으므로 합은 실제 loop cycles가 아니다.
Scalar 일반 연산의 기본값 1은 두 개의 ALU가 있어도 1이다. 코어 전체의 독립 명령
처리율로 나눠 재정규화하지 않는다. Native scalar baseline은 LLVM 값을 유지하므로
이 값과도 완전한 cycle 정확성을 주장하지 않는다.

근거 우선순위는 공식 spec → 고정 configuration의 RTL → 기존 LLVM target schedule
→ 명시적 가정이다. Pipeline depth/latency를 reciprocal throughput으로 복사하지 않는다.
고정 initiation interval/점유값을 우선하고, iterative 연산은 공개된 범위의 상한을 쓴다.
정보가 없는 지원 연산은 scalar 1, SIMD 처리 group당 1, iterative element당 64를 사용한다.
이는 가정이며 하드웨어가 보장한 상한이 아니다. Saturn/K1은 가격 Rule의
`assumed`로 이를 표시한다. XiangShan은 기존 opcode/form Rule 식별자를 유지하므로
Rule 문자열만으로 근거 수준을 판별할 수 없다. 해당 타깃 문서의 가정 구분을 따른다.

## 사양에서 가져오는 정보

ISA·operand form, precision, VLEN, 연산별 datapath 폭, MLEN, sequencer 및 FU의
처리 단위·initiation interval, 주소 생성률, segment·reduction의 실행 구조를 가져온다.
VLEN과 execution width는 다르다. 자료마다 revision과 적용 configuration을 고정한다.
Core GHz, SoC TOPS, DRAM의 peak bandwidth만으로 명령 가격을 만들지 않는다.
Full nominal vector, 모든 element 활성, 정상 공급을 가정한다. Cache/TLB miss,
runtime VL·stride·mask density·페이지 경계·의존성·전력은 입력이 아니다.

## TTI와 MIR

각 target TTI는 예상 opcode sequence를 자기 CostSheet에 보낸다. Target MIRInfo는
관측된 base opcode·geometry를 같은 sheet에 보낸다. Scalar/vector 연산과 spill은
같은 단위를 쓴다. TTI는 legalization multiplier와 materialization을 한 번 더한다.
Fixed vector는 RVV container, widening은 좁은 source, narrowing은 좁은 destination
geometry를 사용한다. Uniform operand의 VV/VX/VF/reverse 선택은 sequence 구성이다.
Gather/scatter처럼 TTI에 index geometry가 없으면 inherited sequence 추정을 유지한다.
예상 sequence와 관측 lowering이 다르면 전체 body 가격은 달라도 된다.

명령별 `Rule`은 문서의 식을 식별한다. Saturn/K1의 `assumed`는 채택한 근사이며,
XiangShan의 기존 Rule 식별자는 위 예외를 따른다. Unknown은 아직
지원하지 않는 opcode/sequence이며, MIR에서는 1+unknown, TTI에서는 inherited
fallback을 쓴다. 지원 가격의 불확실성을 unknown으로 숨기지 않는다. 누락/불가능한
필수 geometry와 overflow는 오류다. 유효한 spill 관측 실패를 0으로 바꾸지 않는다.
Profile은 명시적인 후보 reciprocal-throughput scope에서만 활성화된다.

## Spill → units → TTI → CostSheet

관측 변환은 target-independent다. 실제 접근의 register class, 방향, group g별로
묶어 n개를 `(Q=g*n,A=n)`으로 전달한다. 각 묶음은 homogeneous이며 TTI가 `g=Q/A`를
검증하고 CostSheet의 `A*f(g)`로 가격화한다. 서로 다른 group을 평균내지 않는다.
추정 초과 register n개는 방향별 `(n,n)`으로 group-1 접근을 가정한다.
Default aggregate hook은 기존 단일-register hook의 Q배다. Empty units는 (0,0)이다.
Scalar class는 단일-register 접근을 사용한다. TTI hook의 public signature는 유지한다.

예를 들어 K1에서 `{1,1,4}`는 `(2,2)+(4,1)`로 14, `{2,2,2}`는 `(6,3)`으로 12다.
가격을 units에 미리 넣지 않는다. Backend collector는 가격 규칙을 모른다.
Spill-slot 여부는 MIR body에서 제거할 비용을 분류하며 일반 whole-register 접근도
동일 명령이면 같은 sheet 가격이다. 별도 주소 계산은 MIR body에 남는다.

가격 계산 후 `Wtti/Wobs`를 정확히 한 번 곱한다. Wobs는 IC와 검증된 추가 unroll을
포함하므로 IC를 다시 곱하지 않는다. MIR rational을 quarter-cost rational로 바꾸고,
기존 VPExactCost 비교를 사용한다. TTI는 기존 quarter-cost 표현을 사용한다.
현재 타깃 표는 정수 가격이므로 TTI/MIR간 precision 손실은 없다.

## Generic fallback

아래는 미지원 CPU/VLEN용 기존 generic MIR sheet다. Tuned TTI의 대체물이 아니다.

### 가격

Generic sheet의 nominal VLEN은 subtarget의 실제 최소 VLEN이다.
`L=max(1,data LMUL/EMUL)`, `N=nominal VLEN×data LMUL/SEW`이며 memory는 EEW를
사용한다. Geometry 검증과 unknown/error 구분은 공통 경로를 사용한다.

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

이는 실행 가능한 기본 가격 모델이며 CPU cycles 예측 정확도나 runtime 측정값을
뜻하지 않는다. Scalar FP load/store는 memory 규칙을 사용한다.
