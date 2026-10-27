# Backend 비용 모델과 진단

`-vplan-backend`는 RISC-V RVV의 VPlan VF 선택에 backend 비용을 적용한다.
기본 모델 ID는 `tti-real-vector-spill-v1`이며 master 기본값은 OFF다. 옵션 목록·실행 예제·빌드와
테스트 명령은 [README](README.md)에 있다. 비 RISC-V, RVV 없음, outer loop,
reciprocal-throughput 이외 비용 모드는 native 선택을 유지한다.

## 비용과 선택 정책

```text
L  = 후보 TTI body (지원되는 XiangShan에서는 scoped profile)
Ev = L에 포함된 estimated vector-register spill
Sv = 관측된 vector spill/reload 비용 × Wtti / Wobs
B  = L − Ev + Sv
```

`Wtti`는 해당 VF의 예상 runtime 폭, `Wobs`는 검증된 관측 반복 폭이다.
각 후보의 native 비용으로 IC를 정하고 사용자 hint와 legality 제한을 적용한다.
그 IC로 probe하고 최종 출력에도 같은 IC를 사용한다. Scalar 기준과 scalar spill
추정, VF 생성·순서·강제 VF·scalable tie-break·trip count/tail·outside-loop
profitability는 native 정책을 유지한다. Ev는 기존 register-pressure 정책이
계산한 값이며, 그 정책이 spill을 추가하지 않으면 0이다.

`VPlanBackendCostModel`이 비용 준비, gate, 질의, 검증과 비용 테이블을 소유한다.
`VPExactCost`는 quarter-cost 분자와 양의 분모를 유지하고 비교 전에 절삭하지
않는다. Cross product는 128비트 정수로 계산하며 산술 overflow는 native fallback이다.
기존 `InstructionCost` 소비자에서는 해당 타입의 변환 의미를 유지한다.

### Body/spill ablation과 MIR Info

`-use-mir`, `-use-estimated-spill`, `-use-default-tti`는 모두 기본 OFF이며
master가 OFF이면 효과가 없다. 조합별 수식과 실행 명령은 README의
[Body/spill ablations](README.md#bodyspill-ablations)를 따른다.

기본 `L - Ev + Sv` 경로의 stage, vector-only 수집과 TTI pricing은 유지한다.
`use-default-tti`는 비-MIR 모드에서 `RISCVTTIImpl`을 선택하며 body, estimated
vector spill, 실제 vector spill 가격에 같은 TTI를 사용한다.
비-MIR `use-estimated-spill`은 TTI body를 그대로 사용하고 probe를 하지 않는다.

MIR 모드는 별도 observer의 pass ID까지 backend를 실행한다. 위치는
`addPreSched2()`의 RISC-V post-RA pseudo 확장·KCFI·load/store optimization 이후,
최종 scheduling과 RVV pseudo 확장 이전이다. Stage는 `post-frame-lowering`이다.
Pressure gate에 관계없이 필요한 body를 관측하며 post-frame 재시도 경로는 없다.

Collector는 기존 candidate/role/iteration mapping 검증과 단일 block 반복 경로를
공유한다. Meta 명령을 제외하고 backedge까지의 opcode, pseudo 여부,
configuration, load/store, LMUL/SEW/index EMUL/EEW, 물리 vector register group과
spill-slot 표식을 소유권 있는 `VPlanMIRInstruction`으로 복사한다. 이 가산 모델은
VL·stride의 실제 실행값이나 dependency graph를 가격 입력으로 사용하지 않는다.
상세 report에서만 MIR 문자열도 수집하며 MachineInstr/Function 포인터는 경계를
넘지 않는다. Setup/exit/frame prologue 전체를 body에 합산하지 않는다.

`TargetMIRInfo`는 관측 데이터에 대한 read-only 명령별 service-demand API다.
`TargetMachine::getTargetMIRInfo(F)`가 함수의 CPU/VLEN에 맞는 구현을 만들고,
feedback analysis service를 통해 Vectorize에 전달한다. Vectorize에는 CodeGen이나
특정 target에 대한 링크 의존을 추가하지 않는다. 새로운 target/profile은 해당
타겟 디렉터리에 MIR Info 구현과 factory 선택 조건을 추가한다. 다른 ISA는
해당 타겟의 observer/pipeline 지원과 vectorizer의 대상 허용도 함께 확장해야 한다.
미지원 대상은
nullptr를 반환하여 native fallback하며 generic MIR 가격을 추정하지 않는다.

최초 구현은 `XiangShanV2MIRInfo`이며 XiangShan Kunminghu/VLEN=128을 지원한다.
`llvm-cost-model`의 `rtl-service-sum-v1`, RTL revision
`e7bab53e66dfb3c4a1d11cf9519b0396f8576cae`의 opcode/service/geometry 규칙을
C++로 이식했다. 비용은 service별 work × nominal demand의 합이며 port/max,
latency 배수, dependency/window penalty는 없다. Configuration은 body에 한 번
포함한다. Unknown opcode는 명시적 unit demand이고 잘못된 geometry는 오류다.

`R`은 전체 body, `S`는 spill-slot MMO가 있는 scalar/vector load/store의 전체
service demand다. 별도 주소 계산은 `R - S`에 남는다. 두 값에 `Wtti / Wobs`를
정확히 적용한 뒤 `R` 또는 `R - S + Et`를 사용한다. `Et`는 scoped XiangShan
TTI의 전체 추정 spill이며 기존 vector-only `Ev`와 별도 보관한다.
MIR에서는 `use-default-tti`를 무시하여 `Et`도 바뀌지 않는다.

Native scalar 기준, native-cost IC, 후보 순서와 main/epilogue 정책은 동일하다.
필수 관측이나 가격 계산 실패 시 전체 원본 loop가 native 선택으로 복귀한다.

### Pressure gate

```text
Usage1  = (PeakBound + HasMask) × MaxRegisterGroup
UsageIC = Usage1 × IC
query   = unknown OR UsageIC >= 32
```

`VPlanRegisterUsageBounds`가 지원하는 recipe/type의 보수적 상한을 사용한다.
미지원 lowering과 overflow는 unknown이다. UsageIC가 32 미만이면 질의를 생략하고
Sv=0으로 둔다. `-vplan-backend-force-all`은 gate의 `would_skip`을 유지하며 실제
질의만 강제한다. Scalar spill은 이 gate의 대상이 아니다.

## Probe와 fallback

의존 구조는 `LLVMVectorize → analysis callback → LLVMPasses → TargetMachine →
backend observer`다. 기본 직렬 경로는 후보별 함수 clone을 사용한다. 두 실행
경로 모두 fresh analysis, 독립 TargetMachine과 동일한 vector pipeline suffix를
사용하며 전역 command-line 값은 변경하지 않는다.

```text
clone → candidate materialization → IR suffix → iteration mapping 검증
  → instruction selection / pre-RA 최적화·scheduling
  → RVV allocator → VirtRegRewriter(false)
  → InsertVSETVLI → DeadRegisterDefinitions → scalar allocator
  → VirtRegRewriter → RegAllocScoring → StackSlotColoring
  → vector spill collector → 종료
```

Collector의 pass ID가 probe 종료 지점을 지정한다. 기본 real-vector-spill 경로의 stage는
`post-stack-slot-coloring`이다. 이후 copy propagation, post-RA LICM, frame lowering은
일반 최종 codegen에서 실행된다. RegAllocScoring은 기본 설정에서 no-op이다.
Optimized RVV allocator(default/greedy/basic)와 정상 pipeline을 요구한다.
Fast allocator, optnone, limited pipeline, StackSlotColoring 비활성화와 profile 의존
구성 등 종료 지점이나 재현을 보장할 수 없는 경우는 실패로 처리한다.

수집 대상은 유일한 candidate identity와 검증된 iteration mapping을 가진 단일
block innermost machine loop의 반복 경로다. 실제 spill-slot MMO와 physical vector
data register가 확인되는 load/store만 포함한다. Backedge 이후 명령, setup/exit/다른
loop, scalar spill과 일반 whole-register memory는 제외한다. Scalar 주소 operand는
virtual register나 frame index여도 해석할 수 있다. 미할당 vector register,
subregister, 미지원 접근과 불완전 mapping은 실패다.

`TTI::getSpillReloadCost`는 방향, type, alignment, address space, whole-register
여부와 register group을 받아 가격을 계산한다. 기본 구현은 `getMemoryOpCost`에
위임한다. Segment spill은 실제 lowering과 공유하는 물리 register 분할 helper로
접근을 해석하며 각 접근의 크기·alignment·address space를 보존한다.
**이 기본 경로의 수집과 가격 계산은 vector spill 전용이며, 실제 scalar spill과
최종 frame 주소 비용은 포함하지 않는다. MIR 모드의 전체 body 수집과는 구분한다.**

요청은 plan/VF/IC/역할을 포함한다. Main probe는 강제 epilogue를 함께 생성한다.
자동 epilogue는 기존 main-후-epilogue 순서와 후보 필터를 유지하며, 비교가 필요한
후보를 선택된 main 문맥에서 epilogue IC=1로 관측한다. 강제 epilogue는 기존 비용
비교 우회를 유지한다. 관측 ID는 요청한 역할의 loop 하나에만 붙인다.
초기 관측 폭은 Wtti × IC이며, IR suffix 후 검증된 추가 iteration mapping 비율을
한 번 곱한다. 관측 결과는 해당 planning invocation에서만 사용한다.

Provider unavailable, clone/형상/mapping 실패, 미지원 spill, overflow 또는 필요한
epilogue 비용 실패 시 원본 loop의 backend 비용과 ProfitableVFs를 버리고 native
선택을 다시 실행한다. 강제 VF/IC/epilogue 요청은 유지한다. 실패를 spill 0으로
간주하지 않으며 일부 성공 비용만 적용하지 않는다. LLVM fatal error/assertion의
예외 격리는 제공하지 않는다. Probe suffix는 임의의 LTO·module pass·사용자 추가
pass를 재현하지 않으며, 최종 machine instruction 전체와의 동등성을 보장하지 않는다.

### 제한된 probe 병렬 실행

`-vplan-backend-probe-threads=N`은 양의 정수이며 기본값은 1이다. 기본 경로는
기존 후보별 준비 → probe → 반영과 첫 실패 시 중단을 유지한다. N>1의 일반
경로만 한 원본 loop의 main 후보들을 준비하고, gate가 요구한 query들을 batch로
실행한 뒤 기존 후보 순서로 반영한다. LVP·원본 TTI·분석·비용표·report는 기존
컴파일 스레드에서만 접근한다. 자동 epilogue는 직렬이고 강제 epilogue는 기존대로
main probe에 포함된다.

구현 경계는 다음과 같다. Vectorize에는 scheduling이나 CodeGen 의존을 추가하지
않고, 기존 feedback service를 batch query로 확장한다.

| 구성 요소 | 역할과 실행 위치 |
|---|---|
| `VPlanBackendCostModel::prepareCost` / `addBatch` / `applyCost` | 기존 스레드에서 후보·TTI 비용·gate를 준비하고, 완료된 관측을 pricing과 선택에 반영 |
| `VPlanBackendFeedback::getBatch` | 후보 순서와 개수가 같은 개별 결과를 반환하는 service 경계. 기존 `get`은 단일 후보 adapter |
| Passes의 `FeedbackProvider` / `ProbeSnapshot` | 기존 스레드에서 실행 정책·target 설정·snapshot을 준비하고, worker에서 독립 IR과 backend pipeline 실행 |
| `VPlanBackendProbePool` | lazy 생성한 제한된 pool을 재사용. 작업별 결과 슬롯을 채우고 batch 전체 완료를 기다림 |

```text
기존 스레드: 후보 준비 / gate → getBatch → 후보 순서대로 applyCost → VF 선택
                                  │
                     snapshot → 제한된 worker pool → 완료 대기
                                  │
                    독립 context/module → materialize → IR suffix
                           → backend / spill observation
```

Provider는 현재 clone 정책과 use-list order를 보존한 메모리 bitcode snapshot을
batch마다 만든다. 함수·header를 snapshot에서 다시 찾고 작업마다 별도
LLVMContext·module·TargetMachine·분석을 생성한다. 앞선 loop 선택 문맥은 다음
snapshot에 반영한다. Pool만 재사용하며 IR·TM·분석 결과는 cache하지 않는다.
실제 동시 실행은 N과 query 수를 넘지 않고, query가 없으면 snapshot과 pool을
만들지 않는다. 하나뿐인 query는 기존 스레드에서 처리한다.

Worker는 원본 Function·BasicBlock·VPlan 포인터를 받지 않는다. 함수와 header는
snapshot의 ordinal로 찾고, module identifier와 context의 이름/ODR 설정을
보존한다. 원본 TargetMachine의 mutable 상태와 frontend diagnostic handler/VFS도
공유하지 않는다. 기존 후보 재생성·관측 identity 검사는 두 경로 모두 유지한다.
공통 `runProbe`를 사용하므로 materialization·suffix·관측 종료 지점은 같다.
각 작업은 native TTI scope에서 실행하고 작업 종료 시 thread-local 상태를 복원한다.

준비 오류·관측 오류·pricing 오류는 후보 순서로 처리한다. 첫 실패 뒤에 미리
실행된 결과는 선택이나 일반 candidate JSON에 반영하지 않는다. 모든 작업 종료
후 결과를 해제하며 실패를 spill 0으로 사용하지 않는다. 따라서 진단의 논리적
query 수는 기존과 같지만 실제 실행한 probe 수는 실패 loop에서 더 많을 수 있다.
취소와 fatal error/assertion 격리는 제공하지 않는다.

개별 결과는 context와 독립된 관측 값·오류 문자열·diagnostic 문자열을 소유한다.
Service는 반환 개수를 검증하고, snapshot과 결과 저장소는 모든 작업이 끝날
때까지 유지한다. 늦은 준비 오류가 있어도 먼저 준비된 prefix의 query/pricing
오류를 우선 처리한다. 사용하지 않을 결과의 오류도 안전하게 폐기하며, worker가
직접 candidate JSON이나 비용 보고를 출력하지 않는다.

Fork의 JSON과 두 비용 보고는 병렬 실행에서도 passive하며 기존 스레드에서
출력한다. 강제 epilogue와 비용 보고를 함께 사용하면 기존 준비·보고 순서를
보존하기 위해 직렬로 전환한다. `-vplan-backend-time`은 process CPU timer의
기존 의미를 유지하도록 직렬로 전환한다. Upstream debug·pass dump/view·pass
timing/time trace·opt-bisect·opt-disable·debug counter·optimization remark/streamer,
register allocator의 training log·interactive channel도 직렬로 전환한다. 둘
이상의 main query가 실제 요청되면 provider당 한 번 원인을 warning으로 알린다.
Master OFF·query 없음·main query 하나인 경우는 불필요한 warning을 내지 않는다.
Threads 비활성 빌드도 같은 정책을 사용한다. 병렬 성능은 외부에서 compiler
프로세스의 wall·CPU·peak RSS를 측정한다.

## XiangShan TTI 보정

함수별 effective tuning CPU가 `xiangshan-kunminghu`이고 최소/최대 VLEN이 모두
128일 때 `XiangShanV2TTIImpl`을 선택한다. `target-cpu`, `tune-cpu`, `vscale_range`는
기존 subtarget 해석을 따른다. 다른 CPU/VLEN에서는 native RISC-V TTI를 사용한다.
`VPlanCostProfileScope`는 thread-local RAII로 후보 body와 spill의 reciprocal-throughput
질의에만 적용된다. Planning, scalar 기준, clone 최적화와 codegen은 native scope다.
보정식은 고정되어 있으며 benchmark 이름이나 측정 cycle을 입력으로 사용하지 않는다.

아래 표의 **L은 위 비용식의 body L과 별개로**, legalized type의 `getLMULCost`다.
Fractional-LMUL clamp와 DLen 동작을 포함한다. K는 legalization multiplier,
E는 memory hook의 element/field 수이며 candidate VF를 뜻하지 않는다.

| Hook / operation | Native → 보정 | 적용 범위 |
|---|---|---|
| slide up/down VI/VX | L → L(L+1)/2+1 | immediate/scalar forms |
| gather VI | L → L²+1 | VV/EI16은 native |
| FP divide VV/VF/reverse VF | L → L×{8,10,15}, VF는 +1 | SEW 16/32/64 |
| FP sqrt | L → L×{7,10,17} | SEW 16/32/64 |
| signed integer divide/remainder VV | L×TCC_Expensive → L×{11,13,17,25} | SEW 8/16/32/64 |
| narrowing VNSRL_WI | L → max(1,ceil(2×destination-bits/group-bits))+1 | scalable group 64 bits, fixed group real VLEN |
| generic FP arithmetic | 2×opcode cost → opcode cost | 보정된 divide에도 적용 |
| uniform arithmetic operand | opcode cost → opcode cost+1 before K | 원래 hook facts에서 어느 한 operand가 uniform |
| contiguous vector memory | Cost+BaseCost → Cost+BaseCost+K | legalized vector memory op마다 적용 |
| strided vector memory | E×TCC_Basic → E×TCC_Basic+2 | element 흐름과 transfer |
| gather/scatter | E×TCC_Basic → E×TCC_Basic+1 | element 흐름과 transfer |
| segment/interleaved fast path | E×TCC_Basic → E×(8 load / 4 store)+1 | 다른 fallback branch는 native |
| whole-register spill/reload | memory-op default → group+1 | group 1/2/4/8의 가격 2/3/5/9 |

Signed/unsigned IR divide는 signed-opcode hook을 공유하지만 직접 unsigned machine
opcode와 VX 질의는 보정하지 않는다. Uniform operand의 상수 materialization 비용은
별도로 남는다. VNSRL_WI 이외 widening/narrowing, reductions, scalar hooks, shuffle
fallbacks, masking, legalization과 다른 memory fallback은 native다. 따라서 이 TTI
보정값이 개별 emitted MIR 명령열 비용과 정확히 일치한다고 보장하지 않는다.

## 비용 출력

`-print-vplans`는 요약을, `-print-detailed-vplans`는 요약과 계산 상세를 stderr에
출력한다. 두 옵션을 함께 사용하면 원본 loop당 상세 보고 하나를 출력한다.

| 상태 | 출력 |
|---|---|
| Master OFF 또는 native fallback | Native LLVM 비용과 선택 결과 |
| Backend 적용 | 정확한 backend body/ranking 비용과 feedback |
| Gate 생략 | Sv=0을 적용한 backend 비용; 관측된 zero spill과 구분 |

보고는 기존 TTI 질의와 probe 결과를 관찰하며 추가 질의나 후보 compile을 하지
않는다. 내부 clone은 별도 비용 보고를 출력하지 않는다. Main/필요한 epilogue에서
fallback이 발생하면 시도 중인 backend 보고를 폐기하고 native 보고를 출력한다.

요약 표는 main/epilogue, plan, VF, 예상 폭, body cost, score와 비교 종류,
incumbent/scalar 비교 결과와 이유를 담는다. `fN`은 fixed VF, `sN`은 scalable VF다.
Scalar baseline, 최종 main/epilogue 선택, IC와 emission 결과도 표시한다.
`not-evaluated`는 강제 선택 등으로 계산을 생략했다는 뜻이다. Backend body와 score는
분수를 보존하며 cost-per-lane은 폭으로, whole-loop는 trip-count/tail 정책으로 계산한다.

`backend-cost` 행에는 `phase/plan/vf/ic`, `model/profile`,
`queried/would_skip/force_all`과 `body_cost`가 나온다. 상세 `backend-calculation`은
native body, L, Ev, raw vector spill, Wtti, Wobs, Sv, B와 gate bound를 보여준다.
관측된 각 spill에는 방향, 최소 bytes/scalability, group, alignment, address space,
whole-register/segment-lowering 여부와 TTI 가격이 나온다. Gate 생략이면
`Wobs=not-observed`, `spill_source=gate-skip`이다. Recipe 평가 단계는 native body,
profile body, native IC와 native selection context를 구분한다.

## JSONL과 시간 진단

`-vplan-backend-jsonl=FILE`은 candidate·selected·native-fallback 행을 append한다.
Candidate 행에는 identity/VF/IC/role, model/profile, native/profile/estimated/raw 비용,
정확한 정규화 및 body 분자/분모, TTI 폭과 gate 판단을 기록한다. `collected`는 facts
수신을 뜻하며 `cost_failure`가 있으면 선택에 사용하지 않는다. Fallback 행은 reason을
포함한다. JSONL quarter-cost 분자를 **4 × 분모**로 나누면 텍스트의 model unit과 같다.

Provider는 소유권 있는 `VPlanBackendResult`를 반환한다. `rvv-vector-spill-v1`
요약은 candidate/VF/IC/role, stage, 검증된 반복 폭과 vector 접근 목록을 담는다.
Clone의 Type/MachineFunction/MachineInstr/문자열 포인터는 반환하지 않는다.
선택과 텍스트 보고는 C++ 값을 사용하고 JSONL 목적지가 있을 때만 직렬화한다.

`-vplan-backend-time`은 stderr에 다음 시간을 기록한다.

- `VPLAN-BACKEND-FEEDBACK-TIMING`: clone, target/analysis, materialization, IR suffix,
  mapping/verification, backend 구성·allocation·rewrite·StackSlotColoring·수집,
  정리와 query wall/CPU total.
- `VPLAN-BACKEND-COST-TIMING`: native/profile 비용, native IC, gate, query,
  spill pricing과 hybrid 비용·요약 준비.
- `VPLAN-BACKEND-FAILED-TIMING`: 실패 전 실행된 backend 단계만 기록.

Timing OFF는 clock 조회나 marker pass를 활성화하지 않는다. Pass 경계 측정에는
필요한 analysis 실행도 포함된다. Total은 하위 구간을 포함하므로 중복 합산하지
않으며, 진단 실행은 일반 compiler wall 평균과 분리한다.

### Ablation report 추가 항목

기존 기본 mode의 model ID와 vector spill 필드 의미는 유지한다. JSON 후보 행에는
유효한 `use_mir`, `use_estimated_spill`, `use_default_tti`와 전체 추정 spill을
추가한다. MIR 모드의 observation schema는 `mir-body-observation-v1`이고 `body`에
가격 입력을 보존한다. `mir_model`/`mir_revision`, 정규화된 MIR body/spill의
quarter-cost 분자·분모, 명령 순서와 대응하는 `mir_costs`의 rule/unknown/service
항을 보고한다. MIR 값을 기존 vector-spill 필드로 위장하지 않는다.

TTI-only estimated 모드는 `estimated-spill-no-probe`, MIR 상세 report는
`gate=bypassed-for-mir-body`로 구분한다. 상세 MIR report는 raw/정규화 R·S와 Et,
실제 적용 수식 및 명령별 service demand를 출력한다. 모두 실제 비용 계산 결과를
사용하며 추가 query/재계산을 하지 않는다. Whole-loop fallback에서는 기존처럼
시도 중인 두 cost report를 폐기하고 native report를 복구한다. JSONL은 기존처럼
실패 이전 후보 관측과 최종 fallback record를 함께 남긴다.
