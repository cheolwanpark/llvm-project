# In-process backend 비용을 이용한 VF 선택

`-enable-vplan-backend-cost-model` (기본값 false)은 후보 비용 조회와 backend
질의를 함께 활성화한다. 모델 ID는 `tti-real-vector-spill-v1`이다. 외부 Python
모델이나 meta-compiler를 호출하지 않는다. 기존 외부 protocol 4와 Python 모델은
별도 경로로 유지한다.

```sh
.cache/compiler-build/bin/clang --target=riscv64-unknown-elf \
  -march=rv64gcv -mcpu=xiangshan-kunminghu -mrvv-vector-bits=128 -O3 \
  -mllvm -enable-vplan-backend-cost-model \
  -mllvm -vplan-backend-feedback-output=.cache/feedback.jsonl \
  kernel.c -S -o .cache/kernel.s
```

`opt`에서는 master flag를 직접 사용한다. 별도 driver 옵션은 없다.
`-enable-vplan-backend-feedback` 이름은 호환성을 위해 남아 있지만 master를
대신하지 않는다. Print/output/timing/force-all 옵션만으로는 질의하지 않는다.
Master OFF에서는 비용 준비, pressure gate, clone, TTI profile scope를 실행하지
않고 기존 VF/IC/epilogue/outside profitability 경로를 유지한다.

## 비용과 선택

각 후보의 native TTI 비용으로 기존 interleave heuristic을 먼저 실행하고,
사용자 hint 및 legality 제한을 적용해 IC를 정한다. 그 IC로 probe하고 최종
출력에도 같은 IC를 사용한다. 새 비용을 이용한 IC 재탐색은 없다.

```text
L  = 후보 TTI body (지원되는 XiangShan에서는 scoped profile)
Ev = L에 포함된 estimated vector-register spill 성분
Sv = 실제 반복 body의 vector spill/reload 비용 × Wtti / Wobs
B  = L − Ev + Sv
```

Scalar 기준과 scalar spill 추정은 native 정책을 유지한다. Ev는 기존 register
pressure 정책과 register-limit override를 그대로 사용하며, 그 정책이 spill을
추가하지 않았으면 0이다. 별도 spill penalty나 실제 machine body 전체 비용,
주소 계산/configuration 비용은 추가하지 않는다.

`VPExactCost`는 quarter-cost 분자와 양의 분모를 유지한다. 비교 전에 float나
정수로 절삭하지 않는다. 비용 산술 overflow는 loop 전체 native 복귀이며,
비교 cross product는 128비트 정수로 계산한다. 기존 정수 비용 소비자에서는
InstructionCost의 정수 변환 의미를 유지한다.

VF 생성·순서·scalar 경쟁·강제 VF·scalable tie-break·trip count/tail 정책은
기존 `computeBestVF()` 및 공통 비교 경로를 사용한다. 새 모듈
`VPlanBackendCostModel.{h,cpp}`가 비용 준비, gate, 질의, 검증과 비용 테이블을
소유한다. 원본 IR을 변환하기 전에 준비를 마친다. 실패한 후보를 비용 0으로
처리하거나 일부 성공 비용만 최종 선택에 사용하지 않는다.

## CPU와 scope

[TTI_PROFILE.md](TTI_PROFILE.md)에 고정 보정식과 한계를 기록했다.
함수별 effective subtarget의 tuning CPU가 정확히 `xiangshan-kunminghu`이고
최소/최대 VLEN이 모두 128인 경우 별도 `XiangShanV2TTIImpl`을 선택한다.
함수의 `target-cpu`, `tune-cpu`, `vscale_range`는 기존 subtarget 해석을 따른다.
NanHu, 다른 CPU/VLEN, 불확정 VLEN에서는 native RISC-V TTI를 사용하되 실제
vector spill 치환은 계속 지원한다.

Thread-local RAII scope는 명시적인 후보 비용 및 spill 가격 조회에만 열린다.
Scope 중첩은 이전 상태를 복원하며, clone의 최적화와 backend 실행은 명시적으로
native scope에서 수행한다. Reciprocal-throughput 외 조회는 보정하지 않는다.
비 RISC-V, RVV 없음, outer loop, code-size 모드는 기존 선택 경로를 사용한다.

## Gate와 실제 spill 판별

기존 `VPlanRegisterUsageBounds`의 지원 recipe/type 범위와 보수적 usage 상한을
그대로 사용한다. 미지원 lowering은 unknown이다.

```text
Usage1  = (PeakBound + HasMask) × MaxRegisterGroup
UsageIC = Usage1 × IC
query   = unknown OR UsageIC >= 32
```

Overflow는 unknown이다. 32 미만이면 질의를 생략하고 Sv=0으로 둔다.
`-vplan-backend-feedback-force-all`은 같은 would_skip을 기록하면서 실제 질의만
강제한다. Scalar spill gate는 없다. 기존 gate의 수학적 근거와 population
검증은 [이전 검증 기록](BACKEND_FEEDBACK_COMPARISON.md)에 보존돼 있다.

가격 계산에는 유일한 candidate identity, 검증된 iteration mapping 및 단일 block
innermost machine loop의 반복 경로에서 실제 spill-slot MMO와 physical vector data
register가 확인되는 load/store만 포함한다. Backedge 뒤의 명령도 제외한다.
부분 rewrite 시점의 scalar 주소 operand는 virtual register 또는 frame index여도
유효하다. Vector data register의 미할당·subregister나 미지원 접근은 실패다. Scalar spill, 일반 whole-register memory, setup/exit/다른 loop spill은
제외한다. Mapping 실패, 불완전 register 정보, 해석할 수 없는 vector spill은
실패다. Observer는 address space와 whole-register 여부를 포함한 사실만 제공한다.
같은 physical vector register·spill slot·접근 크기의 연속 reload/store는 이후
`StackSlotColoring`에서 제거될 수 있으므로 명시적 미지원이다. Debug instruction을
제외한 인접 관계를 검사하며, benchmark 이름별 예외나 자체 dead-store 제거 없이
원본 loop 전체를 native로 복귀시킨다. 이 조건은 저장된 post-frame 자료와의 실제
차이에서 도출했으며 근거는 새 검증 보고서에 기록한다.

새 `TTI::getSpillReloadCost`는 방향, 실제 접근 type, alignment, address space,
whole-register 여부와 실제 group 크기를 받는다. 기본 구현은 memory-op 비용에
위임한다. XiangShan/128 profile의 whole-register 명령은 group+1 (2/3/5/9)이다.
Segment spill pseudo는 `lowerSegmentSpillReload()`와 공유하는 순수 helper의
물리 register encoding 분할 규칙으로 접근을 해석한다. 명령 생성이나 frame
lowering 없이 각 분할 접근의 크기·alignment·address space를 보존한다.
Stack slot 전체 크기를 각 접근에 반복 적용하지 않는다. 기존 register-class spill/reload hook의 의미는 바꾸지 않는다.

## Probe, epilogue, fallback

의존 구조는 `LLVMVectorize → analysis callback → LLVMPasses → TargetMachine →
backend observer`이다. LLVMVectorize가 CodeGen이나 Passes에 직접 의존하지 않는다.
후보별 함수 clone, fresh analysis, 독립 TargetMachine, 기존 vector pipeline suffix를
재사용한다. 전역 command-line 값이나 외부 RA replay 상태를 바꾸지 않는다.

```text
clone → candidate materialization → 기존 IR suffix → iteration mapping 검증
  → instruction selection / pre-RA 최적화·scheduling
  → RVV allocator → VirtRegRewriter(false) → vector spill collector → 종료
```

Collector 고유 pass ID를 `addPassesToBackendObserver()`의 종료 대상으로 지정한다.
Probe는 VSETVLI 삽입, scalar RA, post-RA 최적화, frame lowering을 실행하지 않는다.
최종 object 생성의 정상 backend는 계속 전체 pipeline을 실행한다. 지원되는
optimized RVV allocator(default/greedy/basic)와 정상 codegen pipeline을 요구하며,
fast allocator, optnone, limited pipeline 등 종료 위치를 보장할 수 없는 구성은
미지원이다. 실패 시 post-frame으로 재질의하거나 관측 지점을 선택하는 옵션은 없다.
**Scalar spill까지 실제로 관측해야 한다면 관측 지점을 더 뒤로 옮겨야 한다.**

요청은 VF/plan/IC/관측 역할을 포함한다. Epilogue 요청에는 선택된 main 형상도
전달한다. Main probe는 실제 강제 epilogue를 함께 생성한다. 자동 epilogue는
기존 main-후-epilogue 순서와 후보 필터를 사용하며, 비용 비교가 필요한 후보는
해당 main 문맥에서 epilogue IC=1로 별도 관측한다. 강제 epilogue는 기존 비용
비교 우회를 유지한다. 관측 ID는 요청한 역할의 loop에만 붙여 동일 ID loop 하나라는
iteration mapping 계약을 유지한다.

초기 관측 폭은 VF의 예상 runtime 폭 × IC다. Cleanup 후 검증된 추가 iteration
mapping 비율을 한 번만 곱한다. Wobs를 이용해 TTI body 폭으로 정규화한다.
관측은 해당 planning invocation 안에서만 사용하며 다른 loop 변경 뒤 재사용하지 않는다.

Provider unavailable, clone/형상/mapping 실패, 미지원 spill, 비용 overflow,
필요한 epilogue 비용 실패는 그 원본 loop의 비용 테이블과 ProfitableVFs를 버리고
scope 밖에서 native 선택을 다시 실행한다. 강제 VF/IC/epilogue 요청은 유지한다.
LLVM fatal error/assertion까지 복구하는 예외 격리는 제공하지 않는다.

최종 빌드·회귀·데이터셋 수치와 검증 불가 항목은
[BACKEND_COST_MODEL_VALIDATION.md](BACKEND_COST_MODEL_VALIDATION.md)에 기록했다.

## 진단과 재현

기존 JSONL/stderr 출력에는 candidate/VF/IC/role, model/profile,
native/profile/estimated-vector-spill/raw-vector-spill quarter 비용,
정확 body 분자/분모, TTI 폭, IC 이전/이후 bound, would_skip/queried를 기록한다.
선택 행은 status=selected, loop fallback 행은 status=native-fallback과 reason을
기록한다. Candidate 행의 collected는 raw facts 수신을 뜻하며 cost_failure가 있으면
성공한 비용으로 사용하지 않는다. JSONL은 append 방식이므로 새 경로를 사용한다.

Provider와 TargetMachine hook은 `Expected<VPlanBackendResult>`를 반환한다.
`rvv-vector-spill-v1` 요약의 stage는 `post-rvv-ra-rewrite`이며 candidate/VF/IC/역할,
검증된 반복 폭과 vector 접근 목록만 담는다. 접근은 load 방향, 최소 bytes,
scalable 여부, alignment, address space, whole-register 여부, register group 및
`segment_lowering` 여부를 기록한다. 소유권 있는 값만 전달하며 clone의 Type,
MachineFunction, MachineInstr 또는 문자열 포인터는 반환하지 않는다.
TTI 가격 조회와 정확한 정규화는 middle-end에서 수행한다.

In-process 경로의 전체 MIR 문자열, operand 문자열, dependency JSON,
ReachingDefInfo 기반 VL·stride 추론, scalar/configuration 비용 관측은 제거했다.
전체 MIR 출력 복원 옵션은 없다. 외부 `riscv-vplan-analytics`는 별도 경로로 유지한다.
기존 `utils/` Python 도구의 새 요약 호환성은 이번 변경 범위가 아니며 해당 suite는
완료 조건으로 실행하지 않는다.

`-time-vplan-backend-feedback`은 stderr에 다음 진단을 기록한다.
Timing OFF에는 clock 조회나 backend marker pass를 활성화하지 않는다.

- `VPLAN-BACKEND-FEEDBACK-TIMING`: clone, target/analysis 준비, materialization,
  IR suffix, iteration mapping/verification, backend pipeline 구성, pre-RVV-RA,
  RVV allocation, 부분 rewrite, spill 수집, backend 반환, clone/analysis/TM 정리,
  query wall/CPU total.
- `VPLAN-BACKEND-COST-TIMING`: native/profile 비용 준비, native IC, gate,
  query total, middle-end spill pricing, hybrid 비용·요약 준비.

Backend marker는 pass 경계를 측정하므로 allocation/rewrite 구간에는 해당 pass에
필요한 분석 실행도 포함된다. `backend_total`, `query_total`, `query_*_seconds`는
하위 구간을 포함하므로 세부 구간과 중복 합산하지 않는다. 실패한 관측의 실행된 backend 단계는
`VPLAN-BACKEND-FAILED-TIMING`에 기록하며, 실행하지 못한 단계의 측정값은 생략한다. Timing 진단 실행은 일반 compiler wall 평균에 섞지 않는다.


[README의 빌드 설정](README.md#build)에서 `clang;lld` 및 호스트/RISCV backend를
설정한다. 아래 회귀 테스트는 `LLVM_INCLUDE_TESTS=ON`과 assertions가 활성화된
`.cache/compiler-build`를 사용한다. 앱용 `LLVM_INCLUDE_TESTS=OFF` 빌드와 구분한다.

```sh
cmake --build .cache/compiler-build --target clang clang-resource-headers lld \
  llvm-nm llvm-objdump llvm-extract llvm-dis llc opt FileCheck split-file not \
  VectorizeTests VPlanRATests \
  RISCVTests --parallel 2
.cache/compiler-build/unittests/Transforms/Vectorize/VectorizeTests
.cache/compiler-build/unittests/Target/RISCV/RISCVTests
.cache/compiler-build/bin/llvm-lit -v llvm/test/Transforms/LoopVectorize/RISCV
.cache/compiler-build/unittests/Transforms/Vectorize/VPlanRATests
.cache/compiler-build/bin/llvm-lit -v llvm/test/CodeGen/RISCV/vplan-ra
```

313개 `dataset.sqlite` 전수 비교의 재현 스크립트·실행 수·평균 및 관측 차이는
[RVV_SPILL_PROBE_VALIDATION.md](RVV_SPILL_PROBE_VALIDATION.md)에 기록한다.
기준 compiler는 재실행하지 않고 저장된 자료를 비교한다. 과거 다른 DB의 203개
결과와 population을 섞지 않는다.

Probe suffix는 임의의 전체 LTO, module pass, 사용자 추가 pass를 재현하지 않는다.
조기 spill 관측과 post-frame/최종 machine instruction 전체가 동일하다고 주장하지
않는다. 관측 차이가 남으면 비용 모델이나 관측 지점을 임의로 바꾸지 않고 보고한다.
이전 transport/gate 결과는 BACKEND_FEEDBACK_COMPARISON.md 및
BACKEND_COST_MODEL_VALIDATION.md의 당시 commit 기준 결과와 구별해야 한다.
