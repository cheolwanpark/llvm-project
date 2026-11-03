# Backend 비용 모델과 진단

`-vplan-backend`는 RISC-V RVV의 VPlan VF 선택에 backend 비용을 적용한다.
기본 모델 ID는 `tti-real-vector-spill-v1`이며 master 기본값은 OFF다. 옵션 목록·실행 예제·빌드와
테스트 명령은 [README](README.md)에 있다. 비 RISC-V, RVV 없음, outer loop,
reciprocal-throughput 이외 비용 모드는 native 선택을 유지한다.

## 비용과 선택 정책

```text
L  = 선택한 native/tuned TTI의 후보 body 비용
Ev = L에 포함된 estimated vector-register spill
Sv = 관측된 vector spill/reload 비용 × Wtti / Wobs
B  = L − Ev + Sv
```

`Wtti`는 해당 VF의 예상 runtime 폭, `Wobs`는 검증된 관측 반복 폭이다.
각 후보의 native 비용으로 IC를 정하고 사용자 hint와 legality 제한을 적용한다.
그 IC로 probe하고 최종 출력에도 같은 IC를 사용한다. Scalar 기준은 아래와 같이
현재 선택 시도의 비용 출처를 따른다. VF 생성·순서·강제 VF·scalable tie-break와
trip count/tail/outside-loop profitability 수식은 기존 정책을 유지한다. Ev는 기존 register-pressure 정책이
계산한 값이며, 그 정책이 spill을 추가하지 않으면 0이다.

`VPlanBackendCostModel`이 비용 준비, gate, 질의, 검증과 비용 테이블을 소유한다.
`VPExactCost`는 quarter-cost 분자와 양의 분모를 유지하고 비교 전에 절삭하지
않는다. Cross product는 128비트 정수로 비교한다. 필요한 비용의 산술 overflow는
아래 whole-loop fallback을 적용하고 pruning 증명의 overflow는 probe를 생략하지 않는다.
기존 `InstructionCost` 소비자에서는 해당 타입의 변환 의미를 유지한다.

### Body/spill ablation과 MIR Info

`-use-mir`, `-use-estimated-spill`, `-use-default-tti`는 모두 기본 OFF이며
master가 OFF이면 효과가 없다. 실행 명령은 README의
[Body/spill ablations](README.md#bodyspill-ablations)를 따른다. 조합별 수식은 다음과 같다.
`Lt`는 타깃 profile TTI(미지원 시 native), `L0`는 default TTI의 body이며
`Ev/Sv`도 각각 선택한 TTI로 가격화한다.

기존 LLVM에서 유지한 scalar 기준 정책, scalar loop와 scalar spill의 구분 및
모델 비교의 해석 범위는 [ABLATION](ABLATION.md)에 설명한다.

| 추가 옵션 | Vector body 비용 | Scalar 기준 |
|---|---|---|
| 없음 | `Lt - Evt + Svt` | tuned TTI scalar IR |
| `-use-estimated-spill` | `Lt` | tuned TTI scalar IR |
| `-use-default-tti` | `L0 - Ev0 + Sv0` | native TTI scalar IR |
| `-use-default-tti -use-estimated-spill` | `L0` | native TTI scalar IR |
| `-use-mir` | `R_vector` | `R_scalar` |
| `-use-mir -use-estimated-spill` | `R_vector - S_vector + Et_vector` | `R_scalar - S_scalar + Et_scalar` |

두 MIR 조합에도 `-use-default-tti`를 추가할 수 있다. `R/S`의 sheet는 유지하고
양쪽 `Et`만 default TTI를 사용한다. 정상 pure-MIR의 scalar/vector `R/S`와 선택은
이 flag에 독립적이다. `R`, `S`, `Et`의 범위는 아래에서 정의한다.

비-MIR real-spill 모드는 `L - Ev + Sv`를 사용하며 vector spill만 관측한다.
`use-default-tti`는 MIR 여부와 관계없이 `RISCVTTIImpl`을 선택한다. 비-MIR body의
scalar/vector 연산과 estimated/observed spill은 같은 설정된 TTI로 가격화한다.
MIR body의 sheet 선택은 별도이며, 이 옵션은 `R-S+Et`의 `Et`에 적용된다.
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

`TargetMIRInfo`는 관측 데이터에 대한 read-only 명령별 direct-cost API다.
`TargetMachine::getTargetMIRInfo(F)`가 함수의 CPU/VLEN에 맞는 구현을 만들고,
feedback analysis service를 통해 Vectorize에 전달한다. Vectorize에는 CodeGen이나
특정 target에 대한 링크 의존을 추가하지 않는다. 새로운 target/profile은 해당
타겟 디렉터리에 MIR Info 구현과 factory 선택 조건을 추가한다. 다른 ISA는
해당 타겟의 observer/pipeline 지원과 vectorizer의 대상 허용도 함께 확장해야 한다.
RVV가 없는 대상은 nullptr를 반환한다.

TTI/MIR sheet 선택과 직접 가격표는
[타깃별 CostSheet](#타깃별-costsheet)에 정의한다.

`R`은 전체 body, `S`는 spill-slot MMO가 있는 scalar/vector load/store의 직접
비용이다. 별도 주소 계산은 `R-S`에 남는다. 두 값에 `Wtti/Wobs`를 정확히 적용한
뒤 `R` 또는 `R-S+Et`를 사용한다. `Et`는 설정한 default/tuned TTI의 전체 추정
spill이며 vector-only `Ev`와 별도 보관한다. Scalar `Et`는 원본 VF1 plan의 register
usage와 기존 `VPRegisterUsage::spillCost()` 정책으로 계산한다. 이 scalar plan은
tail-fold mask와 predication linearization 전에 원본 VF1 geometry를 보존한 snapshot이다.
관측 `S_scalar`에서 추정 register 수를 만들지 않는다. 유효한 zero estimate는 실패와 구분한다. MIR sheet와
TTI profile은 독립적으로 보고한다. Raw requested boolean은 기존 fallback 목적지를 유지한다.

Estimated/real spill의 units와 target 가격은 [변환 규칙](costsheet/rule.md#spill--units--tti--costsheet)을 따른다.
관측값은 register class·방향·group별로 묶으며 가격화 후 반복 폭을 한 번 정규화한다.

### MIR scalar probe와 정확한 기준

원본 loop별 MIR 시도에서 scalar baseline을 한 번 관측하고 vector VFs와 epilogue가
공유한다. `ScalarBaseline`은 vector와 다른 candidate kind/ID이며 fixed VF=1, IC=1,
non-scalable이다. 전체 함수를 clone하여 preceding-loop 문맥을 보존하고, 선택한 원본
loop에는 LV vectorization/interleaving을 하지 않고 observation marker를 붙인다.
그 뒤 vector probe와 같은 native post-LV suffix와 backend를 실행한다. 전역 CLI와
최종 codegen 설정을 바꾸지 않는다. 비-MIR post-stack-slot-coloring collector는 계속
vector-spill 전용이며 scalar 관측을 추가하지 않는다.

Scalar도 innermost·single-block·identity·backedge와 affine induction witness 검증을
통과해야 한다. Suffix unroll이 관측 폭을 바꾸면 원래 scalar iteration 하나로 정확히
정규화한다. Loop 제거 또는 증명 불가능한 mapping은 실패이며 비용 0이 아니다.
관측은 한 시도 안에서만 공유하고 persistent/cross-loop cache를 만들지 않는다.

Known TC, scalar tail, epilogue와 최종 profitability는 exact scalar rational을
사용하며 ranking 전에 integer/quarter-cost로 절삭하지 않는다. 강제 VF/IC 경로와
pruning도 같은 기준을 사용한다. Native IC 계산은 이 tuned scope 밖이다.

### Pressure gate

```text
Usage1  = (PeakBound + HasMask) × MaxRegisterGroup
UsageIC = Usage1 × IC
query   = unknown OR UsageIC >= 32
```

이 gate는 비-MIR real-spill 모드에만 적용한다.
`VPlanRegisterUsageBounds`가 지원하는 recipe/type의 보수적 상한을 사용한다.
미지원 lowering과 overflow는 unknown이다. UsageIC가 32 미만이면 질의를 생략하고
Sv=0으로 둔다. `-vplan-backend-force-all`은 gate의 `would_skip`을 유지하며 실제
질의를 강제하며 아래 pruning도 우회한다. Scalar spill은 이 gate의 대상이 아니다.

### 비용 하한 pruning

비-MIR TTI real-spill 모드에서 `LB = L - Ev`이고 `B = LB + Sv`, `Sv >= 0`이다.
모든 후보의 metadata/native IC/profile 비용과 gate-skip 확정 비용을 먼저 준비한다.
Gate는 모델 정책으로 `Sv=0`을 적용한다. Query 후보의 LB는 확정 body나 관측된
zero spill이 아니다. Scalar 기준은 같은 선택 시도에서 이미 준비한 configured TTI
비용을 재사용하며 pruning을 위해 다시 가격화하지 않는다.

기존 수치 계산을 공유하여 unknown TC는 exact cross product, known TC는
scalar tail일 때 `floor(TC/W)*B + (TC%W)*C_scalar`, tail folding일 때 `ceil(TC/W)*B`로
비교한다. IC/관측 폭 정규화 후 IC를 다시 곱하지 않는다. 엄격히 싼 유효 기준이
있어야 pruning하며 동률은 남긴다. 증명 overflow는 probe하고 실제 비용 실패와 구분한다.

자동 pruning은 vector epilogue OFF, main/epilogue VF 비강제, 후보의 fixed/scalable 및 scalar-tail 정책 일치 조건에서 적용한다. Scalar, gate-skip, 완료 probe의 엄격히 싼 유효 비용을 기준으로 사용하며 강제 vectorization에서는 scalar 기준을 사용하지 않는다. MIR에는 이 하한을 적용하지 않고 TTI estimated는 probe하지 않는다. Pruned 후보는 선택에서 명시적으로 제외하며 zero-spill 관측을 만들어 넣지 않는다. 자세한 CFG·취소 계약은 아래 Probe pruning 절을 따른다.

## Probe와 fallback

의존 구조는 `LLVMVectorize → analysis callback → LLVMPasses → TargetMachine →
backend observer`다. 기본 직렬 경로는 후보별 함수 clone을 사용한다. 두 실행
경로 모두 fresh analysis, 독립 TargetMachine과 동일한 vector pipeline suffix를
사용하며 전역 command-line 값은 변경하지 않는다.

```text
clone → candidate materialization → guarded vector-spill CFG reduction → IR suffix → iteration mapping 검증
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

`priceVPlanVectorSpills`는 검증된 접근을 class·방향·group별 `SpillReloadUnits`로
누적한 뒤 설정된 TTI의 `getRegisterClassSpillReloadCost`를 묶음마다 한 번씩 호출한다.
Default aggregate hook은 기존 단일-register spill/reload hook의 override를 존중한다.
Spill 가격 질의의 단일 진입점은 aggregate hook이다. Segment spill은 실제 lowering과
공유하는 물리 register 분할 helper로 접근을 해석하고 각 접근의 크기·alignment·
address space를 보존한다.
**이 기본 경로의 수집과 가격 계산은 vector spill 전용이며, 실제 scalar spill과
최종 frame 주소 비용은 포함하지 않는다. MIR 모드의 전체 body 수집과는 구분한다.**

요청은 plan/VF/IC/역할을 포함한다. Main probe는 강제 epilogue를 함께 생성한다.
자동 epilogue는 기존 main-후-epilogue 순서와 후보 필터를 유지하며, 비교가 필요한
후보를 선택된 main 문맥에서 epilogue IC=1로 관측한다. 강제 epilogue는 기존 비용
비교 우회를 유지한다. 관측 ID는 요청한 역할의 loop 하나에만 붙인다.
초기 관측 폭은 Wtti × IC이며, IR suffix 후 검증된 추가 iteration mapping 비율을
한 번 곱한다. 관측 결과는 해당 planning invocation에서만 사용한다.

필수 scalar probe/가격/추정 실패를 포함한 provider unavailable, clone/형상/mapping
실패, 미지원 spill, overflow 또는 필요한
epilogue 비용 실패 시 원본 loop의 backend 비용·scalar 항목/exact 값·ProfitableVFs·epilogue clone·보고를
버리고 새 객체로 전체 loop를 다시 선택한다. Probe 모드이고 raw
`use-default-tti=false`이며 함수의 specific TTI profile이 지원되면 기존 TTI estimated
builder로 한 번 재시도한다. 비용은 추정 vector/scalar spill을 포함한 `Lt`이고
scalar 기준도 같은 tuned TTI를 쓰고 IC는 native다. MIR sheet나 provider query는 요구하지 않는다.
Specific 미지원, raw default-TTI=true, requested TTI estimated 실패 또는 estimated
재시도 실패는 native 선택으로 간다. Scalar/non-LV 선택도 성공이며 native로
진행하지 않는다. 전역 옵션 변경이나 일부 후보만 대체하는 경로는 없다. 강제 VF/IC/epilogue 요청은 유지한다. 실패를 spill 0으로
간주하지 않으며 일부 성공 비용만 적용하지 않는다. LLVM fatal error/assertion의
예외 격리는 제공하지 않는다. Probe suffix는 임의의 LTO·module pass·사용자 추가
pass를 재현하지 않으며, 최종 machine instruction 전체와의 동등성을 보장하지 않는다.

### 제한된 probe 병렬 실행

`-vplan-backend-probe-threads=N`은 양의 정수이며 기본값은 1이다. Pruning 가능한 TTI real-spill 후보는 `(L-Ev)/Wtti` 순서로 실행한다. Provider는 완료 콜백을 기존 compiler thread에서 실행하고 빈 worker를 즉시 채운다. 최종 비용과 선택은 원래 후보 순서를 따른다. Pruning 미적용·N=1은 후보별 직렬 실행이며, N>1은 일반 batch를 사용한다. MIR에는 CFG 축소·candidate pruning·취소를 적용하지 않는다. 자동 epilogue는 직렬이며 강제 epilogue는 기존대로 main probe에 포함된다.

Service의 `canBatch`는 호환성·진단 직렬화를 반영하며 `beginInvocation`만 진단 accounting을 초기화한다. 완료 콜백은 관측 검증과 pricing을 한 번 수행하고 최종 반영에 재사용한다. 원본 분석·TTI·비용표·report는 compiler thread에서만 접근한다.

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

Batch의 준비 오류가 있으면 준비된 prefix는 pruning 없이 처리하고 필요한 실패를 판정한다. Pruning 경로는 최종 dominance까지 실패를 유예하고 proven loser만 무시한다. 협력 취소는 IR 단계 사이와 완료된 legacy pass 경계에서 확인한다. On-demand 분석은 완료하며 정상 finalization 후 모든 작업을 회수한다. 이후에만 현재 시도를 폐기하고 설정된 estimated/native 재시도를 시작한다. Fatal error/assertion 격리는 제공하지 않는다.

개별 결과는 context와 독립된 관측 값·오류 문자열·diagnostic 문자열을 소유한다.
Service는 반환 개수를 검증하고, snapshot과 결과 저장소는 모든 작업이 끝날
때까지 유지한다. Worker는 직접 candidate JSON이나 비용 보고를 출력하지 않는다.
N=1/2/4는 필요한 비용과 최종 선택을 보존하지만 speculative 관측 수와 JSON 행의
관측 사실은 다를 수 있다. 물리적 실행 상태는 scheduling에 따라 달라질 수 있다.

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

## 타깃별 CostSheet

가격의 정의와 IR/MIR/spill 변환은 [작성 규칙](costsheet/rule.md), 가격표와 출처는
[XiangShan](costsheet/xiangshan.md), [Saturn](costsheet/saturn.md),
[K1](costsheet/k1.md)이 소유한다. CPU/VLEN별 선택은 README를 따른다.

RVV가 없는 함수는 tune CPU와 관계없이 native RISC-V TTI를 사용하며
`getTargetMIRInfo()`는 `nullptr`를 반환한다. Scalar support TU의 TTI 생성은
RVV 기능 검사 뒤에만 실제 VLEN을 조회한다.

Saturn TTI는 native RISC-V TTI를 그대로 사용하며 연산군 계수는 모두 1이다.
MIR은 [Saturn 가격표](costsheet/saturn.md)의 native-relative opcode 가격을 쓴다.
Scalar/vector spill과 body의 단위를 맞추며, default-TTI flag는 successful MIR의
sheet를 교체하지 않는다. CPU/VLEN 선택과 whole-loop fallback 계약은 그대로다.

K1의 exact VLEN256 가격은 `k1-native-relative-v1`이다.
TTI는 spacemit-x60의 native RISC-V 가격이며 MIR은 Saturn과 같은 정책을 사용한다.
가격·근거·가정은 [K1 CostSheet](costsheet/k1.md)에 있다.
기존 scheduler occupancy, structural service 및 과거 timing과 구분한다.

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
실패 시 시도 중인 backend 보고를 폐기한다. 최종 성공한 estimated/backend 보고만
출력하며 native까지 갔을 때 native 보고를 복구한다.

요약 표는 main/epilogue, plan, VF, 예상 폭, body cost, score와 비교 종류,
incumbent/scalar 비교 결과와 이유를 담는다. `fN`은 fixed VF, `sN`은 scalable VF다.
Scalar baseline의 source 및 exact cost, 최종 main/epilogue 선택, IC와 emission 결과도 표시한다.
`not-evaluated`는 강제 선택 등으로 계산을 생략했다는 뜻이다. Backend body와 score는
분수를 보존하며 cost-per-lane은 폭으로, whole-loop는 trip-count/tail 정책으로 계산한다.

`backend-cost` 행에는 `phase/plan/vf/ic`, `model/profile`,
`queried/would_skip/force_all`과 `body_cost`가 나온다. 상세 `backend-calculation`은
native body, L, Ev, raw vector spill, Wtti, Wobs, Sv, B와 gate bound를 보여준다.
관측된 각 spill에는 방향, 최소 bytes/scalability, group, alignment, address space,
whole-register/segment-lowering 여부가 나온다. 별도 `spill-price`는 class·방향·group별
누적 Q/A, 설정한 TTI profile, 가격과 Wtti/Wobs를 출력한다. Gate 생략이면
`Wobs=not-observed`, `spill_source=gate-skip`이다. Recipe 평가 단계는 native body,
profile body, native IC와 native selection context를 구분한다.

## JSONL과 시간 진단

`-vplan-backend-jsonl=FILE`은 최종 시도의 candidate·selected와
estimated-fallback/native-fallback 행을 append한다.
MIR scalar-baseline 행은 `role=scalar-baseline`을 사용하며 source, sheet revision, `R/S/Et`,
관측 폭, exact 분자/분모와 unknown 수를 담는다. Vector candidate 집계에서 제외한다.
`scalar_cost_source`는 `mir`/`mir-estimated-spill`, `scalar_profile`과 `scalar_revision`은
실제로 선택한 sheet를 식별한다. `mir_body_quarters_*`, `mir_spill_quarters_*`는 정규화된
`R/S`이고 `estimated_total_spill_quarters`는 `Et`다.
TTI 모드는 vector 행에 scalar source `tti`, profile/revision과 `scalar_quarters_*`를
함께 기록하며 별도 scalar probe 행을 만들지 않는다. Native revision은 `native-tti`,
tuned profile의 revision provider가 없으면 `unavailable`로 표시한다. Text `backend-scalar`는 같은
소유된 값으로 source/profile/revision, VF1/IC1, 비용과 MIR `R/S/Et/Wobs/unknown`을 출력한다.
Candidate 행에는 identity/VF/IC/role, model/profile, native/profile/estimated/raw 비용,
정확한 정규화 및 body 분자/분모, TTI 폭과 gate 판단을 기록한다. `collected`는 facts
수신을 뜻한다. `cost_source`는 gate/observation/estimated를 구분한다.
Pruned 행은 body-unit `lower_bound_quarters_*`, 정규화한
`score_lower_bound_quarters_*`, 비교 기준 비용/폭·TC/tail·queried를 담고 exact body를
만들지 않는다.
미관측 Pruned에는 observation/Wobs/observed spill도 없다. 실제 실행한 speculative
성공의 관측은 보관할 수 있다. Selected/fallback 행은 requested/effective model을,
fallback 행은 reason을 포함한다. JSONL quarter-cost 분자를 **4 × 분모**로 나누면 텍스트의 model unit과 같다.

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

### MIR 비용 보고 형식

JSON 후보 행에는 적용한 `use_mir`, `use_estimated_spill`, `use_default_tti`와 전체 추정 spill을
기록한다. MIR 모드의 observation schema는 `mir-body-observation-v1`이고 `body`에
가격 입력을 보존한다. `mir_cost_schema=direct-instruction-cost-v1`, `mir_model`, `mir_revision`,
`mir_cpu`, `mir_nominal_vlen`, 별도 `tti_profile`, 정규화된 MIR body/spill의
quarter-cost 분자·분모, 명령 순서와 대응하는 `mir_costs`의 rule/unknown/numerator/denominator
항과 `unknown_instruction_count`를 보고한다. MIR 값을 기존 vector-spill 필드로 위장하지 않는다.

TTI-only estimated 모드는 `estimated-spill-no-probe`, MIR 상세 report는
`gate=bypassed-for-mir-body`로 구분한다. 상세 MIR report는 raw/정규화 R·S와 Et,
실제 적용 수식 및 명령별 직접 비용을 출력한다. 모두 실제 비용 계산 결과를
사용하며 추가 query/재계산을 하지 않는다. 실패 시도의 두 cost report와 tentative
candidate JSON은 폐기한다. 최종 성공 시도만 채택하고 native까지 갔다면 native
보고와 짧은 fallback 이유만 남긴다. MIR 요청 후 TTI estimated가 성공하면 실제
계산을 `Lt`로 표시하며 `native-fallback`으로 표시하지 않는다.

## Probe pruning

Private vector-spill CFG reduction defaults ON with the master model (never for MIR) and is controlled only
by `-vplan-backend-prune-cfg` (`false` disables it). It runs after materialization
and before the suffix, using the unique observation marker shared with iteration
mapping and diagnostics. Missing/ambiguous markers leave the probe unchanged.
The observed header's forward/backward closures are computed independently and
their union retained; shared exits do not pull in unrelated predecessors.
Exclusive paths may return early only using existing, available return values.
Vector/aggregate/target-extension ABI, vector live-out/live-through, surrounding
vector cycles, EH/indirect control, retained SSA definitions, unknown/ambiguous
return outcomes and exact infeasible switch guards constrain applicability.
There is no general proof that shortened probes retain identical global allocation.

Cost-bound candidate pruning은 [비용 하한 pruning](#비용-하한-pruning), worker
수명과 취소는 [병렬 실행 계약](#제한된-probe-병렬-실행)을 따른다.
`-vplan-backend-pruning-trace`는 CFG 적용 여부와 크기를,
`-vplan-backend-pruning-dump-ir`는 `before`, `after`, `suffix` IR을 출력한다.
두 진단은 수동적이며 timing phase는 `probe_pruning`이다.


## Scalar 기준과 검증 계약

Scalar TTI 기준은 vector body와 같은 configured TTI를 사용한다. Saturn과 K1은
두 기준 모두 native RISC-V TTI이며, MIR은 같은 표로 원본 VF1/IC1 scalar
probe와 vector body를 가격화한다. Scalar/vector `R-S+Et`는 대칭적으로 적용한다.

단위/통합 검사는 scalar TTI scope와 power-of-two divide/rem, scalar VF1/IC1 identity,
원본 함수 문맥, fractional unroll 정규화, scalar/vector `R-S+Et`, 추정/관측 spill의
독립성, native/tuned estimated spill, 보고의 수동성, whole-loop fallback, forced VF와
trip-count/tail/epilogue 비교 및 opcode별 fractional LMUL 경계를 다룬다.
Pure MIR의 body 가격과 관측은 default-TTI flag와 독립적이다. 필수 probe 실패 시의
estimated/native fallback 목적지는 successful MIR 가격과 별도로 취급한다.
