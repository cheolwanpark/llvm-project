# 현재 cost model: resource demand와 finite window

이 모델의 목적은 같은 loop의 vectorization 후보 중 실행 비용이 작을 후보를
고르는 것이다. 입력은 register allocation과 frame lowering 이후의 MIR이다.
따라서 실제로 남은 scalar 연산, spill/reload, vector instruction의 LMUL 등을
반영한다. 대상은 XiangShan Kunminghu v2 **MinimalConfig, VLEN=128**이며,
모델 식별자는 `mir-service-window-v4`이다.

한 body의 비용은 다음 두 관점 중 큰 값으로 정한다.

```text
body_cost = max(D, W)
W = L_path × B / C_ROB       C_ROB = 48
```

W는 window 비용을 뜻한다. 두 항은 같은 실행을 서로 다른 병목 관점에서
바라본 것이므로 더하지 않는다. 이 값은 후보 순위를 위한 cycle 단위의 proxy이며,
실제 cycle 수나 엄밀한 수학적 하한을 보장하지 않는다.

## D: 실행 자원이 처리해야 하는 일

D는 충분한 독립 작업이 준비되어 있을 때, 가장 바쁜 실행 자원의 처리량이
제약하는 비용을 근사한다. 명령을 service class별 작업으로 해석하고, 모든 작업을
동일한 demand 계산 경로에 넣는다.

```text
demand(class, instruction) = work_units(class, geometry) × service_interval(class, precision)
D = max_port(sum_class(distributed demand) / port capacity)
```

기준 단위는 II=1인 ALU 작업 하나다. 일반 vector ALU의 m1 작업은 1이고,
LMUL이 커지면 128-bit datapath 작업량이 증가한다. II=1인 pipelined multiply/FMA도
같은 작업량이면 demand는 같다. Pipeline stage 수는 여기에 곱하지 않는다.
`max(work_units, stages)`도 사용하지 않는다. Pipeline fill은 아래 latency에 남기고,
D는 독립 작업을 지속 처리할 때의 자원 사용량을 나타낸다.

Decode uop 수를 비용으로 사용하거나 report에 유지하지 않는다. RTL의 split 구조는
산술·permutation의 실제 datapath 작업량을 얻는 근거로만 활용한다. Memory는
register 그룹 수 대신 실제 실행 방식에 맞는 flow 단위를 선택한다.

| Service class | 작업량 | 작업당 고정 demand |
|---|---|---|
| 일반 scalar/vector pipelined 연산 | scalar 연산 또는 128-bit datapath 작업 | 1 |
| `i2v`, `f2v` | 임시 scalar→vector 전달 | 1; vector LMUL을 다시 곱하지 않음 |
| `vload128`, `vstore128` | `max(1, data EMUL)`; whole-register는 register 수 | 1; 16-byte 정렬, 무정체 경로 |
| `vload_element`, `vstore_element` | `128 × data EMUL / data EEW` | 1; full-active element flow |
| `vload_ordered` | 같은 element flow 수 | 4; load fast path 3 + registered restart 1 |
| `vsegload`, `vsegstore` | element 수 × field 수 | 각각 8, 4; 고정된 no-stall FSM 근사 |
| `div`, `vidiv`, `fdiv`, `fsqrt`, `vfdiv`, `vfsqrt` | scalar 연산 또는 vector datapath 작업 | 정밀도별 FSM 기반 보수적 II |

Unit-stride load/store는 모두 128-bit flow를 지원한다. Load의 두 64-bit bank
접근은 병렬이므로 폭만을 이유로 demand를 2로 두지 않는다. Store는 별도 class로
구분하지만 SQ/store-buffer 정체를 임의의 가중치로 넣지 않는다. Indexed 접근은
index EEW가 커져도 data element 수는 늘지 않는다. Index register 전달 자체의
추가 압력은 생략한다. VL/mask, misalignment, replay는 현재 flow 작업량에 반영하지
않으며, 이 기준 조건은 각 class의 evidence에도 기록한다.

Segment load의 8은 TLB request/wait/permission의 3개 상태와 cache request에서
response까지 3-cycle 가정, merge 및 다음 요청으로의 전환을 합친 근사다.
Store의 4는 TLB request/wait/permission/send-data 상태에 대응한다. 둘 다 TLB hit와
즉시 응답 가능한 buffer를 가정하며, 시작 시 store-buffer drain과 종료 비용은 생략한다.
Ordered load의 4도 writeback 대기를 단순화한 값이다. 이들은 RTL에서 유도한
고정 근사이며, 보장된 실제 II나 측정된 평균 처리율은 아니다.

여러 EXU에서 실행 가능한 작업은 균등하게 분배한다. Port capacity는 1 normalized
service cycle/cycle로 두고, class별 II는 demand에 반영한다. 실제 scheduler의 분배,
공유 writeback, cache bank, SQ/store-buffer를 각각의 독립 자원으로 재현하지는 않는다.
여러 downstream 자원을 동일한 EXU demand로 대표하므로 혼합 workload에는 오차가 남는다.

Datasheet는 hardware revision별 고정값과 명시적인 근사로 관리한다. Class별 fitting
계수나 runtime override는 없다. 근거가 바뀌면 datasheet 자체를 수정하고 digest를
바꾼다. 기존 `body_scale` 옵션은 전체 body의 기존 외부 배율이며, hardware class
parameter가 아니다. 기본값은 1이다.

## W: 유한한 ROB 안에서 latency를 숨기는 정도

L_path는 한 반복 안의 RAW dependency를 따라 얻는 최장 latency 경로다.
다른 명령의 자원 간섭 없이 결과가 준비되는 시간을 근사한다. 독립 반복을
충분히 겹쳐 실행할 수 있다면 이 latency 전부가 매 반복의 처리 비용이 되지는
않는다. W는 ROB가 허용하는 중첩 정도를 통해 이를 throughput 관점으로 바꾼다.

B는 **전체 loop body의 non-meta MIR 명령 수**다. Critical path 밖의 명령도
ROB 공간을 사용하므로 포함한다. Body 안의 configuration, scalar 주소 갱신,
분기, spill/reload도 포함하며 body 밖의 setup은 제외한다. B는 uop 수가 아니고,
LMUL 배수를 별도로 곱하지 않는다. LMUL은 D의 작업량과 L_path의 명령 latency에
반영된다. 이 RTL의 ROB는 `firstUop`에 entry를 할당하므로 split uop마다 entry를
세는 방식보다 명령 단위의 B가 대응된다. MIR 명령과 ROB entry의 일대일 대응은
fusion, elimination, 최종 pseudo 확장 등을 생략한 근사다.

`C_ROB / B`를 동시에 수용할 수 있는 반복 수의 근사로 보면,
`L_path / (C_ROB / B)`가 W다. 같은 latency라도 body가 작으면 더 많은 독립
반복으로 숨길 수 있고, body가 크면 숨길 여지가 줄어든다는 의도다.
C_ROB=48은 pinned MinimalConfig의 실제 RobSize이며 benchmark에 맞춘 값이 아니다.
B가 48보다 커도 비율을 clamp하지 않는다.

핵심 가정은 L_path가 body 전체의 대표적인 ROB 점유 시간을 대신할 수 있다는
것이다. 실제 entry의 수명은 allocation, 실행 완료, in-order retirement에 따라
각각 달라지며, 전체 ROB 용량이 언제나 유효하게 활용되는 것도 아니다.
W는 이 과정을 시뮬레이션하지 않는다. 특히 body가 ROB보다 큰 경우에도 같은
식을 연장해서 사용하는 단순한 점유 비용 근사다.

## Dependency와 latency의 가정

Compiler가 제공한 register RAW graph에 전처리 단계에서 알려진 frame slot의
byte 범위별 store→reload RAW를 추가한다. 부분 overwrite와 완전 overwrite를
구분하며, 이후 path 계산은 모든 RAW edge를 동일하게 취급한다. Spill만을 위한
별도 cost penalty는 없다. 불완전한 register 정보와 지원하지 않는 stack 접근은
scoring 오류로 처리한다. 일반 pointer 사이의 memory alias는 아직 모델링하지 않는다.

Latency는 machine datasheet의 RTL 근거와 명시적인 가정에서 얻는다. Pipeline의
첫 결과 latency와 독립 작업의 시작 간격을 구분하고, 여러 작업으로 나뉘는 명령은
`L + (work_units - 1) × II`로 완료 시간을 근사한다. D의 가중 demand를 작업 수로
재사용하지 않으므로 divide의 점유 시간을 중복 곱하지 않는다. Latency를 pipeline
stage 수로 나누지는 않는다.
Memory는 빠른 cache-hit/no-replay 경로와 위의 실행 순서 근사, divide/sqrt는
정밀도별 FSM 추정치를 사용한다. Divide는 입력별 early exit를 무시하고 restart
한 사이클을 포함한 고정 II를 쓴다. Vector wrapper/OG2까지 보수적으로 포함하므로
정확한 FU-only II로 해석해서는 안 된다. 의존적인 내부 분할은 보수적으로 직렬화하며,
lane 단위 streaming이나 정확한 내부 uop scheduling은 생략한다. 미검증 opcode의 fallback도 report에 표시한다.

L_path는 **한 반복 내부**의 경로다. Graph의 iteration-distance 1 edge는 보존하지만
이 경로에서는 순회하지 않는다. 현재 모델에는 loop-carried recurrence 비용이
없으며, W를 recurrence로 해석하면 안 된다. 반복을 독립적으로 겹칠 수 있다는
가정이 깨지는 경우는 별도 개선 대상이다.

## 적용 범위와 남은 한계

현재는 iteration mapping이 확인된 single-block loop body를 지원한다. Body 비용을
실제 반복 수에 맞추고 기존의 configuration 및 scalar tail 비용을 더한다.
정확한 trip count가 없으면 원래 scalar iteration당 steady-state 비용으로 비교한다.
Configuration은 B에는 포함하되 D와 path에서는 별도로 가중하지 않고 기존 TTI
비용으로 과금한다. Body 밖의 일반 setup/final reduction은 비용에 포함하지 않는다.
기본 body scale은 1이며 benchmark 측정으로 맞춘 weight는 없다.

D와 W를 각각 계산한 뒤 max를 취하므로 둘 사이의 간섭은 반영하지 않는다.
특히 load가 몰릴 때의 queue 압력, cache miss/replay, 외부 자원 정체 때문에 늘어나는
latency는 현재 값보다 실행 비용을 크게 만들 수 있다. Iterative 연산의 nominal
점유 시간은 D에 반영하지만, 그로 인한 다른 명령의 latency 증가는 계산하지 않는다.
Load/store queue, issue queue, rename 자원, fetch/decode/retire bandwidth도 독립적인 병목 항으로 계산하지 않는다.

계산은 graph의 node와 edge를 한 번씩 처리하는 O(N+E) 방식이다. Stack RAW
전처리에는 접근 byte 수에 비례하는 비용이 추가되지만 target의 접근 폭은 제한된다.
Path 열거, 여러 반복의 unroll, 동적 ROB simulation은 필요하지 않다.

구현은 [cost_model.py](utils/vplan-tools/cost_model.py), target 값과 근거는
[kunminghu_v2.py](utils/vplan-tools/kunminghu_v2.py), 실행 방법은
[README](README.md)에 있다.

Report의 `components`는 service class, work unit, work units, demand per unit, demand,
port 분배와 근거를 제공한다. `decode_uops`/`issued_demands`는 없다. 이전 count 기반
report는 새 모델로 재표시할 수 없으며, raw MIR observation부터 다시 scoring해야 한다.
