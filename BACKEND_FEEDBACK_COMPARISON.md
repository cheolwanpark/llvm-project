# Backend feedback 검증 결과

## Register usage gate 추가 검증 — 2026-10-26

`VPlanRegisterUsageBounds` 적용 후 이전과 SHA-256이 같은 203개 입력 DB를
`/work/mir-port-aware-goal/search-dataset.sqlite`에서 읽어 검증했다.
동일 pre-vectorizer checkpoint, 입력별 compile flags, IC=1에서 default gate와
`-vplan-backend-feedback-force-all`을 비교했다. 기본 feedback OFF assembly도
비교했다. Late cleanup OFF/ON을 각각 실행했으며 아래 수치는 **모드별**이다.

| 항목 | Late OFF | Late ON |
|---|---:|---:|
| 전체 입력 / 후보 | 203 / 1,528 | 203 / 1,528 |
| Force-all 실제 backend 호출 | 1,528 | 1,528 |
| Gate 적용 실제 backend 호출 | 815 | 815 |
| 생략 / 감소율 | 713 / 46.66% | 713 / 46.66% |
| 대상 loop body를 관찰한 생략 후보 | 707 | 707 |
| Loop 제거 후 함수 전체를 관찰한 생략 후보 | 3 | 3 |
| 검증한 710개에서 대상 RVV spill/reload | 0 | 0 |
| 후보 미생성으로 spill 검증 불가 | 3 | 3 |
| Mask가 포함된 생략 후보 | 80 | 80 |
| Query 유지: 상한 32 이상 / 미지원 Recipe | 140 / 675 | 140 / 675 |

서브에이전트 하나가 전체 입력을 새로 컴파일하고 실제 provider timing 기록과
후보별 정책을 대조했다. 다른 서브에이전트는 자체 checker로 raw JSONL의 후보,
상한식, register operand의 `group8`, `spill_slot` MMO와 body 소속을 독립 감사했다.
두 모드의 gate/force-all assembly를 feedback OFF와 비교한 **812회 모두 동일**했다.

검증 예외는 다음처럼 분리했다.

* `polybench/polybench-reg_detect-l02` s4/s8/s16은 loop가 사라져 iteration mapping이
  없다. 각 관찰에는 successor 없는 machine block 하나와 11개 명령 전체가 있고,
  함수 전체의 spill-slot 접근이 0이다. 이 세 후보는 함수 전체를 검사한 더 강한
  근거로 검증했으며, 임의의 mapping 실패를 무-spill로 간주한 것은 아니다.
* `polybench/p32-adi-full` loop 0 s1/s2/s4는 force-all에서도 후보가 생성되지 않는다.
  별도 RA probe로 `always-failing-memory-check`를 재현했다. 이 세 후보는
  **spill 0으로 집계하지 않았다**. 따라서 모든 생략 후보에 대한 관찰 검증을
  요구하는 도구의 최종 상태는 `passed=false`, exit 1이다. 발견된 spill 반례는 없다.
* ADI의 다른 후보에서 대상 body **밖** vector spill/reload가 각각 3개,
  scalar spill-slot store/load가 각각 483개 관찰됐다. 이 수치는 생략 후보들의
  정적 관찰 합계이며 대상 RVV body spill과 구분한다. 함수 전체에 spill이 없다는
  주장은 하지 않는다.

검증 binary SHA-256:
`9c73cec243ba9781eb2212f42ce78bcde03d0d1951c7fa6a07e4c8f5a0694dd7`.

재현 명령:

```sh
python3 utils/vplan-tools/check-backend-feedback-gate \
  --clang .cache/compiler-build/bin/clang \
  --db /work/mir-port-aware-goal/search-dataset.sqlite \
  --output-dir .cache/gate-validation-new --jobs 8
```

사용자 요청으로 이번 검증의 임시 산출물, 일회성 감사 스크립트, ADI 진단 파일과
실행 로그를 삭제했다. 위 결과와 재현 명령, 정식 검증 도구 및 회귀 테스트는 보존했다.

## 이전 transport 비교

검증일: 2026-10-25. 정리일: 2026-10-26.

사용자 요청으로 실행 산출물, 입력 snapshot, 빌드, 일회성 진단 스크립트는 삭제했다.
이 문서에는 최종 결과, 비교 조건, 확인한 원인과 한계를 남긴다. 구현과 회귀 테스트는
보존했다. 전체 203개 입력을 다시 검증하려면 원본 benchmark DB를 다시 준비해야 한다.
구현 구조와 옵션은 [BACKEND_FEEDBACK.md](BACKEND_FEEDBACK.md)에 있다.

## 비교 조건

* 기준 commit: `c8f36b9af1b424827d2aa6f9332287909cd0dfff`와 현재 작업 트리의 변경.
* LLVM 23.1.3, Release, assertions ON, RISC-V target. CPU는 XiangShan Kunminghu,
  VLEN=128, O3, IC=1, 별도 vector epilogue 없음. 입력별 기존 compile flags를 유지했다.
* 기존 DB의 203개 입력에서 `selected_kernel`을 추출하고, 양 경로에 같은
  pre-vectorizer checkpoint를 사용했다. 새로운 하드웨어 성능 측정은 하지 않았다.
* 최종 비교는 use-list 순서 보존 및 `-vplan-backend-feedback-late-cleanup` ON이다.
  Feedback와 late cleanup 옵션의 기본값은 모두 OFF다.
* 함수/loop/plan/VF로 후보를 대응시켰다. Raw 비교에서 제외한 것은 최상위
  `candidate`, `run_id`, `feedback_pipeline`뿐이다. MIR 문자열, IR 이름, debug 번호,
  명령 순서, register, memory operand, dependency는 그대로 비교했다.
* 관찰 지점은 `post-frame-lowering` MIR이다. 최종 assembly의 명령 목록과 같다는
  뜻은 아니다. Spill 수는 `spill_slot=true`인 MMO의 정적 load/store 접근 수이며,
  callee-save 저장·복원을 포함할 수 있다. 동적 실행 횟수가 아니다.

마지막 검증 binary의 SHA-256:
`d331eda81f827baeed7d081c3c2f5c408529933091ad940542cfa399bc39128f`.
원본 DB `search-dataset.sqlite`의 SHA-256:
`3d5e09ed2346be109a887192c36422073a4a6650b0f38cc29765d72ad063ff37`.

## 최종 결과

| 항목 | 기존 203개 입력 | 별도 4개 입력 |
|---|---:|---:|
| 양 경로 후보의 합집합 | 1,531 | 24 |
| Middle-end 수신 후보 | 1,528 | 24 |
| 수집되어 비교 가능한 후보 | 1,524 | 24 |
| 전체 raw 관찰 일치 | 1,464 | 24 |
| 전체 raw 관찰 불일치 | 60 | 0 |
| 수집 불가 / 후보 누락 | 4 / 3 | 0 / 0 |
| 기존 모델 점수 일치 / 불일치 / 미지원 | 1,507 / 0 / 17 | 24 / 0 / 0 |
| Feedback on/off 원본 assembly 일치 | 203/203 | 4/4 |

별도 입력은 상수 trip-count double add, runtime trip-count alias check,
12개 독립 reduction으로 spill을 유발하는 입력, 조건부 load/store다. 초기 24개는
이 4개 입력의 VF 후보 수였으며 전체 검증을 대신하지 않는다.

서브에이전트 3개가 양 경로 전체 재실행, 원인 분류, spill/operand 감사를 나눠 수행했다.
현재 binary로 203개 입력을 양 경로에서 새로 실행해 후보별 판정까지 재현했고,
별도 24개 후보도 다시 실행했다. CostModel 계산과 VF 선택은 변경하지 않았다.

## 남은 60개 불일치

모두 아래 9개 PolyBench 입력, 15개 loop의 scalable VF `s1/s2/s4/s8`이다.
Loop 번호는 출력의 0-based `loop` 필드다.

| 입력 | loop | 불일치 후보 | 함수 전체 spill 수가 다른 후보 |
|---|---|---:|---:|
| p32-adi-full | 2, 3, 4 | 12 | 12 |
| p32-fdtd-2d-full | 1, 2, 3 | 12 | 4 |
| p32-jacobi-1d-imper-full | 1 | 4 | 0 |
| p32-jacobi-2d-imper-full | 1 | 4 | 4 |
| p421-fdtd-2d-full | 1, 2, 3 | 12 | 8 |
| p421-heat-3d-full | 1 | 4 | 4 |
| p421-jacobi-1d-full | 1 | 4 | 0 |
| p421-jacobi-1d-outer | 1 | 4 | 0 |
| p421-jacobi-2d-full | 1 | 4 | 4 |

| 60개 후보에서 비교한 정보 | 불일치 후보 |
|---|---:|
| 대상 body opcode 순서·개수 | 0 |
| 대상 body 물리 register operand | 60 |
| 대상 body immediate operand | 2 |
| 대상 body spill load/store 수 및 spill opcode 순서 | 0 |
| 함수 전체 opcode 순서·개수 | 60 |
| 함수 전체 spill load/store 수 | 36 |

Dependency는 raw로 60개 모두 다르다. 진단용으로 instruction ID를 body 안의 위치로
바꾸고 register unit만 제외하면 source/destination, operand_index, iteration_distance,
kind를 포함한 edge multiset은 모두 같다. 이 진단으로 raw 일치 기준을 완화하지 않았다.

Immediate 차이는 두 후보의 stack 주소 계산이다. 다음은 새 경로 / 기존 경로의 값이다.

* ADI loop 2/s8: `ADDI sp, 80` / `ADDI sp, 96`, spill slot 21 / 22.
  Body spill은 양쪽 load 2개 + store 2개다.
* Heat-3d loop 1/s8: offset 144/272/16 / 160/288/32, 주소 register X26/X23 / X15.
  Body spill은 양쪽 load 3개 + store 3개다.

함수 전체 spill 차이에는 callee-save도 포함된다. 예를 들어 p421-jacobi-2d-full
loop 1/s1은 새 경로 load 2개 + store 2개, 기존 load 5개 + store 5개지만 모두
body 밖 callee-save SD/LD다. 새 경로는 x8/x9, 기존은 x8/x9/x18/x19/x20을 저장·복원한다.
함수 전체 차이를 대상 loop의 register-pressure spill 오류로 해석하면 안 된다.

원본 LV는 loop를 차례로 처리하므로 새 probe의 함수에는 앞서 벡터화한 sibling
loop가 남는다. 기존 wrapper는 후보마다 scalar checkpoint에서 시작해 다른 loop를
벡터화하지 않는다. 불일치한 15개 target loop 각각의 s1에서 LSR 직전 IR을 확인하면
새 경로에는 vector body가 2~4개, 기존 경로에는 1개였다.

p421-jacobi-1d-full에서 앞서 처리되는 sibling `for.body16.us.us`에만
`llvm.loop.vectorize.enable=false`를 추가한 같은 checkpoint를 양 경로에 주었다.
Use-list 순서를 보존했으며 원래 불일치하던 4개 VF가 register/MIR/dependency까지
완전히 일치했다. 이 대표 사례에서는 sibling 문맥이 원인임을 확인했다. 나머지
56개 각각의 모든 차이까지 같은 원인만으로 설명되는지는 별도 대조하지 않았다.
실제 구현은 사용자가 수용한 현재 LV 문맥을 유지하며 sibling을 되돌리지 않는다.

## 수집 불가와 후보 누락

* **p32-adi-full loop 0, s1/s2/s4/s8:** 양 경로 모두 생성한 memory runtime check가
  항상 실패하여 `always-failing-memory-check`에서 materialization을 중단한다.
  기존 analytics 파일은 존재했지만 `selections=[]`, `iteration_mapping=false`,
  `header=-1`, `body_order=[]`였으므로 성공한 VF 관찰이 아니다. 새 전달 경로만의
  관찰 손실이 아니다. 왜 memory check가 상수로 결정되는지까지는 추가 추적하지 않았다.
* **tsvc-s31111-l00 loop 0, s1/s2/s4:** trip count가 4다. 일반 LV와 기존 RA 경로의
  작은 trip-count 후보 생성 정책 차이로 새 경로에 후보 row가 없다. 전송 누락과
  구분하며 기존 LV의 후보 정책은 그대로 유지한다.

## 구현 보완과 효과

| 203개 입력 비교 | Raw 일치 / 불일치 | 점수 불일치 |
|---|---|---:|
| Use-list 순서 보존 전 | 1,387 / 137 | 18 |
| Use-list 순서 보존 후 | 1,441 / 83 | 0 |
| 추가 late cleanup ON | 1,464 / 60 | 0 |

각 단계의 수집 불가 4개·누락 3개는 동일하다.

**CloneModule:** operand 재매핑이 use-list 순서를 바꾸고, IVUsers/LSR의 순회 순서와
LoopTermFold의 선택까지 달라지는 사례를 확인했다. IR 의미를 깨뜨리는 버그는 아니지만
기계 코드 비교에는 영향을 준다. 선택적인 `PreserveUseListOrder`를 추가해 module 소유
값의 mapped user/operand 순서를 복원했다. 공유 non-global constant는 재정렬하지 않는다.
전체/부분 clone, 중복 operand, 원본 불변성을 unit test로 검사한다. s279/s442의
18개 점수 차이가 해소됐고 두 입력의 20개 후보는 raw 관찰도 모두 일치했다.

**Late cleanup:** 기존 vector suffix 뒤 `LoopSink`, `InstSimplify`, `SimplifyCFG`를
LLVM의 기존 구현으로 실행하는 옵션을 추가했다. s332의 남은 LCSSA PHI를 정리하면
LSR 선택이 바뀌며 f16 body가 10개에서 11개 명령으로 변한다. 세 pass ON에서는
s332의 10개 후보가 기존 backend와 raw 일치한다. 이름/debug 차이도 일부 해소됐다.
별도 alias 4개도 일치하여 별도 테스트 24개가 모두 같아졌다.

동일 함수 상태에서 late OFF/ON을 비교하면 수집 1,548개 중 opcode 목록은 s332의
10개에서 바뀌고 spill load/store 수는 모두 같았다. 이는 late ON과 기존 wrapper를
비교한 앞 표의 함수 전체 spill 차이 36개와 비교 대상이 다르다.

## Late cleanup 추가 비용

Xeon Platinum 8558P 호스트의 Release/assertions-on 빌드에서 207개 입력 전체를
warmup 후 5회씩 순차 실행했다. 입력 순서를 섞고 on/off 순서를 교대했다. 관찰값
파일 출력은 끄고 메모리 반환과 별도 timing 진단을 사용했다. 아래는 기존 203개
입력의 집계이며, query는 clone·재계획·cleanup·backend·객체 정리를 포함한다.

| 측정 항목 | 결과 |
|---|---:|
| 세 pass 직접 실행 / 수집 후보 | 중앙값 13.1 µs, 평균 17.7 µs, p95 52.2 µs |
| 전체 query / 수집 후보, 중앙값 | OFF 7.015 ms / ON 7.024 ms |
| 세 pass의 전체 query 시간 비중 | 0.226% |
| Query 시간 합 증가율, 5회 중앙값 | +0.285% (범위 +0.092~+0.348%) |
| Checkpoint resume compile 시간 합 증가율, 5회 중앙값 | +0.156% (범위 −0.058~+0.299%) |

이번 비-PGO 입력에서 LoopSink는 profile 부재로 바로 반환한다. 주된 추가 비용은
InstSimplify와 SimplifyCFG다. 결과는 해당 입력·호스트의 측정이며 일반적인 overhead
보장값이나 PGO 측정값이 아니다.

## 코드에서 확인한 보장과 한계

[공통 backend 구성](llvm/lib/CodeGen/CodeGenTargetMachineImpl.cpp)의
`addPassesToGenerateCode()`를 재사용한다. [공통 observer](llvm/lib/Target/RISCV/RISCVVPlanPasses.cpp)는
같은 지점에서 `collectAnalytics(MF)`를 호출한 뒤 파일/메모리 출력을 선택한다.
`ownObservation()`은 key/string 소유권만 확보한다. Opcode는 MachineInstr에서,
spill 정보는 MMO와 frame 정보에서 읽으며 새 경로에서 별도로 계산하거나 걸러내지 않는다.

이 구조는 수집·전달 과정의 보존 근거다. 서로 다른 함수 문맥에서 생성한 opcode와
spill 수가 항상 같다는 보장은 아니다.

* [Register allocator](llvm/lib/CodeGen/RegAllocGreedy.cpp)는 함수 전체 live range,
  할당 순서와 callee-save 사용 상태를 보고 split/spill을 결정한다. RISC-V의
  `getCSRCost()`도 5를 반환해 최초 사용 비용에 따른 선택을 활성화한다.
* [Frame 주소 계산](llvm/lib/Target/RISCV/RISCVRegisterInfo.cpp)은 offset이 immediate
  범위를 넘으면 명령을 추가한다. Spill 수가 같아도 opcode 목록은 달라질 수 있다.
* 세 pass를 추가해도 일반 pipeline의 DivRemPairs, ExpandMemCmp, TailCallElim,
  extension callback 및 이후 module pass까지 모두 공유하는 것은 아니다.
* 관찰 뒤의 scheduling, branch 처리, RVV pseudo expansion까지 마친 최종 assembly와
  동일하다고 보장하지 않는다.

현재 결론은 검증한 수집 후보에서 대상 body의 주요 정보가 같았고 공통 전달 경로가
이를 변형하지 않는다는 것이다. 모든 입력에 대한 불변성을 증명한 것은 아니다.

## 남겨 둔 검증 코드

2026-10-25 실행 결과는 Utils unit **183/183**, 관련 LLVM lit **149/149**,
Python **73/73** 통과다. 재실행 전 [README의 빌드 절차](README.md)를 따른다.

```sh
cmake --build .cache/compiler-build --target UtilsTests count llvm-config --parallel 2
.cache/compiler-build/unittests/Transforms/Utils/UtilsTests
.cache/compiler-build/bin/llvm-lit -j 16 -v \
  llvm/test/Transforms/LoopVectorize/RISCV llvm/test/CodeGen/RISCV/vplan-ra
PYTHONPATH=utils/vplan-tools VPLAN_CLANG="$PWD/.cache/compiler-build/bin/clang" \
  python3 -B -m unittest discover -s utils/vplan-tools/tests -q
```

* [CloneModule unit test](llvm/unittests/Transforms/Utils/CloningTest.cpp): use-list 보존.
* [Feedback lit test](llvm/test/Transforms/LoopVectorize/RISCV/backend-feedback.ll):
  반환 데이터, geometry, late cleanup/timing, 원본 IR 불변성.
* [Clang integration test](utils/vplan-tools/tests/test_feedback.py): memory/출력 경로,
  assembly 불변성, 모델 호환성, 기존 backend와 simple/spill/alias 후보 비교.
* [비교 도구](utils/vplan-tools/compare-backend-feedback)와
  [비교 테스트](utils/vplan-tools/tests/test_feedback_comparison.py): raw 필드 차이,
  누락/수집 실패 검출. Alias 회귀 테스트의 IR 이름 suffix 허용은 전체 raw 비교
  도구의 엄격한 일치 기준을 바꾸지 않는다.

새 실행 결과를 비교하는 도구 사용법은 다음과 같다. 경로는 새로 생성한 산출물을
지정한다. Exit status는 전체 일치 0, 차이/누락/수집 실패 1, 입력 오류 2다.

```sh
python3 utils/vplan-tools/compare-backend-feedback \
  --middle-end PATH_TO_FEEDBACK_JSONL --backend-dir PATH_TO_LEGACY_RUN \
  --output PATH_TO_COMPARISON_JSON
```
