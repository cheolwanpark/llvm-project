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

가격 계산에는 검증된 `body_order`에 속하는 실행 명령 중 실제 MMO의
`spill_slot=true`와 physical vector register group이 확인되는 load/store만
포함한다. Scalar spill, 일반 whole-register memory, setup/exit/다른 loop spill은
제외한다. Mapping 실패, 불완전 register 정보, 해석할 수 없는 vector spill은
실패다. Observer는 address space와 whole-register 여부를 포함한 사실만 제공한다.

새 `TTI::getSpillReloadCost`는 방향, 실제 접근 type, alignment, address space,
whole-register 여부와 실제 group 크기를 받는다. 기본 구현은 memory-op 비용에
위임한다. XiangShan/128 profile의 whole-register 명령은 group+1 (2/3/5/9)이다.
Segment spill은 분할된 실제 명령마다 계산하며 stack slot 전체 크기를 반복 적용하지
않는다. 기존 register-class spill/reload hook의 의미는 바꾸지 않는다.

## Probe, epilogue, fallback

의존 구조는 `LLVMVectorize → analysis callback → LLVMPasses → TargetMachine →
backend observer`이다. LLVMVectorize가 CodeGen이나 Passes에 직접 의존하지 않는다.
후보별 함수 clone, fresh analysis, 독립 TargetMachine, 기존 vector pipeline suffix를
재사용한다. 전역 command-line 값이나 외부 RA replay 상태를 바꾸지 않는다.

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
PYTHONPATH=utils/vplan-tools VPLAN_CLANG="$PWD/.cache/compiler-build/bin/clang" \
  uv run --locked --project utils/vplan-tools python -B -m unittest discover \
  -s utils/vplan-tools/tests -q
python3 utils/vplan-tools/check-backend-feedback-gate \
  --clang .cache/compiler-build/bin/clang \
  --db /work/mir-port-aware-goal/search-dataset.sqlite \
  --output-dir .cache/backend-cost-gate --jobs 2
```

Gate 검증은 exact 비용, 관측 spill, provider 호출 수 및 최종 assembly를 비교한다.
Native 대비 assembly 변경은 이 경로에서 허용하며 별도로 보고한다. 참조 모델의
`/work/llvm-cost-model/dataset.sqlite`와 같은 population으로 취급하지 않는다.

관측은 post-frame-lowering이며 최종 scheduling/RVV pseudo expansion 이전이다.
Probe suffix는 임의의 전체 LTO, module pass, 사용자 추가 pass를 재현하지 않는다.
관측 MIR과 최종 machine instruction 전체가 동일하다고 주장하지 않는다.
이전 transport/gate의 수치와 한계는 BACKEND_FEEDBACK_COMPARISON.md의 당시
commit 기준 결과이며, 새 선택 모델의 검증 결과와 구별해야 한다.
