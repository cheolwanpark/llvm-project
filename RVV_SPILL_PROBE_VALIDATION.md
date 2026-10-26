# RVV RA 직후 spill probe 구현·검증 — 2026-10-26

최종 구현은 RVV allocator와 `VirtRegRewriter(false)` 직후 전용 collector에서
종료한다. 전체 MIR JSON을 반환하지 않고 `Expected<VPlanBackendResult>`로
소유권 있는 spill facts를 전달한다. 필수 회귀 테스트와 최종 313개 입력의
OFF/ON 각 3회 컴파일 및 별도 ON 진단을 완료했다. 기준 compiler는 실행하지 않았다.

## 구현과 회귀 검증

- `RISCVVPlanSpill`의 고유 ID로 backend pipeline을 중단한다. 종료를 우회하던
  공통 pipeline 끝의 직접 추가 `StackFrameLayoutAnalysis`도 중단 조건을 따른다.
  `opt -codegen-opt-level=2 -print-after-all` 기록에서 RVV greedy allocator → 부분
  rewrite → collector 순서를 확인했다. VSETVLI, scalar RA, post-RA 최적화,
  frame lowering 및 stack-frame-layout 분석은 probe에서 실행되지 않는다.
- 유일한 candidate loop, 검증된 iteration mapping, 단일 block innermost loop,
  backedge 이전의 반복 경로만 허용한다. 실제 spill-slot MMO와 physical vector
  data register를 모두 요구한다. Scalar 주소는 virtual register/frame index여도
  정상이며 scalar spill과 일반 whole-register memory access는 제외한다.
- Segment spill은 `lowerSegmentSpillReload()`와 공유하는 물리 encoding 기반
  group 분할 helper를 사용한다. 각 접근 크기·alignment를 보존하며 lowering이나
  자체 명령 생성을 실행하지 않는다.
- Master flag, XiangShan TTI profile, `L − Ev + Sv`, 정확한 유리수 정규화,
  native 비용으로 결정하는 IC, gate 및 main/epilogue 정책은 유지한다.
  필요한 후보가 실패하면 모든 hybrid 비용·선택 상태를 버리고 원본 loop 전체를
  native 선택으로 복귀시킨다. Post-frame 재질의나 관측 지점 선택 옵션은 없다.
- Scalar/configuration 비용 관측, MIR·operand 문자열, dependency JSON,
  ReachingDefInfo의 VL·stride 추론 및 전체 JSON 소유권 복사를 제거했다.
  외부 RA/MIR collector는 유지한다. Scalar spill까지 실제 관측하려면 종료 지점을
  더 뒤로 옮겨야 한다.

| 필수 검증 | 결과 |
|---|---:|
| VectorizeTests | 82/82 |
| VPlanRATests | 1/1 |
| RISCVTests | 34/34 |
| RISC-V LoopVectorize + CodeGen/vplan-ra lit | 150/150 |
| 최종 요청 target 빌드 확인 | `ninja: no work to do.` |

검증 범위에는 load/store group 1/2/4/8, segment 분할, spill MMO 없는 접근과
scalar spill 제외, scalar virtual 주소/frame index, 잘못된 mapping·identity,
IC=1/2/4·fixed/scalable VF·강제/일반 epilogue·여러 loop, 분수 정규화,
두 번째 main 후보/epilogue 실패의 전체 native 복귀, 소멸 후 결과 수명,
실제 pressure에서 발생한 spill, master 없는 진단의 query 0, timing ON/OFF의
동일 비용·IR이 포함된다. 새 구조적 거부 조건도 machine-loop 단위 테스트로 검증했다.

빌드는 Release/assertions ON/tests ON, projects `clang;lld`, targets `X86;RISCV`,
`--parallel 2`를 사용했다. 명령과 로그는 최종 실행 디렉터리의 `validation/`에 있다.
기존 `utils/` Python suite는 실행하지 않았고 새 요약 호환성은 범위에서 제외했다.

## 자료와 측정 방법

최종 실행 디렉터리:
[dataset-rvv-spill-final-audit-20261026T134925Z](.cache/dataset-rvv-spill-final-audit-20261026T134925Z/report.md).
`audit.py`, `compare.py`, `manifest.json`, 원본 source snapshot, compiler 변경 파일
snapshot·diff, `runs.jsonl`, `benchmark_times.{csv,json}`, object와 stderr를 보존했다.

- DB: 이 워크트리의 `dataset.sqlite`, 313개(C 231, C++ 82).
  SHA-256: `8885672e1219a93c91edf3f37c5ccbc177b3fc757a0b161735f11e03a727d7c0`.
- 기준 소스 상태: `5d264abfd3d861f1b5f2afee8b71a6589841ada5`에서 시작한 변경.
- 최종 clang SHA-256:
  `1b356d9c01e91d7ee9186614e01d9f31c6fd0b115f1a1ee694c6dde25a5dca76`.
- 기존 시간 자료: `.cache/dataset-compile-audit-20261026T090440Z/`.
  해당 compiler hash는 `e3aff7264feeab8bec7ccd4609c1060266e90549f83a31eebff2c0f923fbc45b`.
- 기존 관측 자료: `.cache/dataset-gate-count-20261026T110703Z/`. 이것은 호스트
  backend를 추가한 별도 binary의 실행이며 기존 timing 실행과 동일시하지 않았다.
  기존 manifest의 소스 및 313개 object 일치 기록을 재사용했다.

Subagent가 전체 1,878회와 별도 진단 313회를 수행했다. DB source bytes, 언어 및
기존 effective flags를 보존했다. IC=1, vector epilogue 비활성, LMUL=8을 유지하고
한 번에 compiler 하나만 실행했다. OFF/ON 순서를 교대하고 monotonic wall timer,
blocking wait 및 별도 300초 watchdog을 사용했다. 준비·build·hash는 측정에서
제외했고 일반 측정에는 timing/JSON 옵션을 넣지 않았다. 기존 standalone header는
읽어 사용했으며 `utils/` 실행 흐름에 의존하거나 도구를 수정하지 않았다.

## 최종 시간 결과와 독립 검산

평균은 각 benchmark의 3회 평균을 다시 산술평균한 값이다.

| 항목 | 저장된 기존 OFF | 저장된 기존 ON | 새 OFF | 새 ON |
|---|---:|---:|---:|---:|
| 실행 수 / 성공 | 939/939 | 939/939 | 939/939 | 939/939 |
| 평균 compiler wall (초) | 0.0545828655 | 0.3582180089 | 0.0569235483 | 0.2632112204 |
| 총 compiler wall (초) | 51.253310717 | 336.366710349 | 53.451211869 | 247.155335987 |
| timeout | 0 | 0 | 0 | 0 |

새 ON/OFF 비율은 4.623943이다. 과거 대비 ON 측정값은 0.734779배(26.5221% 낮음),
OFF는 1.042883배다. 새 ON/OFF는 같은 세션의 비교지만 과거 대비 비율은 호스트 상태와
빌드 구성 차이가 있는 역사적 비교다. 통제된 동시 비교나 확정적인 speedup으로
해석하지 않는다. 지원 범위가 좁아진 다섯 loop의 native 복귀 효과도 포함된다.

Main agent는 두 원시 `runs.jsonl`을 Decimal로 별도 읽어 실행 수, 고유 key, 성공,
입력별 3회, 교대 순서, source hash와 전체 flag, 합계·평균을 독립 검산했다.
별도 진단 313/313 성공도 확인했고 평균에서 제외했다.
`main_independent_verification.json`과 `validation/independent_verify.py`에 증거가 있다.

## 관측 차이 조사와 보수적 거부

초기 구현의 전수 조사(`.cache/dataset-rvv-spill-audit-20261026T130851Z/`)에서는
7개 후보가 조기 시점에 store 하나를 더 가졌다. 6개는 group 8로 +36 quarters,
1개는 group 4로 +20 quarters였다. 초기 평균·결과는 최종 표에 섞지 않았다.

추가 probe dump로 7개 모두 같은 physical vector register·spill slot·접근 크기의
인접 `reload → store`임을 확인했다. 이후 `StackSlotColoring::RemoveDeadStores()`의
제거 규칙에 해당한다. 기존 post-frame 관측에는 그 store가 없다. 근거는 초기
실행 디렉터리의 `investigation/early_pair_evidence.json`, 모든 해당 probe dump,
저장된 기존 관측 및 `llvm/lib/CodeGen/StackSlotColoring.cpp`에 있다.

새 collector는 이 패턴을 미지원으로 반환한다. Debug instruction만 건너뛰며,
store 비용을 임의로 빼거나 자체 DCE를 수행하지 않는다. Benchmark 이름별 예외도
없다. 이 수정 후 compiler를 다시 빌드·검증하고 **전체 1,878회 + 진단 313회를
새 디렉터리에서 다시 수행**했다.

| 최종 관측 분류 | 기존 | 새 결과 |
|---|---:|---:|
| 후보 행 | 7,635 | 7,618 |
| backend query | 6,304 | 6,287 |
| gate 생략 | 1,331 | 1,331 |
| native fallback loop | 88 | 93 |
| 유효한 backend 관측 | 6,216 | 6,194 |

기존 fallback 88개는 모두 유지됐다: iteration mapping 실패 86, 단일 block
loop 계약 실패 1, materialization 실패 1이다. 새 실패는 아래 구조적 거부 5개다.
비교 가능한 성공 후보 **7,511개는 spill 접근·raw/정규화/body 비용 모두 동일**하다.
변경된 비교 가능 성공 후보는 0개다. 조기 fallback 뒤 미평가된 기존 후보 17개와
앞선 loop 선택 문맥 변화 때문에 비교하지 않은 14개를 별도로 남겼다.
유효 관측 중 spill 0은 5,203개, nonzero는 991개이며 총 15,866개 접근이다.
이 DB에는 segment spill 접근이 없어 해당 기능의 검증 근거는 회귀 테스트다.

## 최종 선택·object 차이

기존 hybrid 선택 행 1,085개 중 1,080개는 동일하고 5개는 native fallback으로
전환됐다. 일반 선택 행이 없는 이 5개는 추가 최종 compiler remark 실행으로
실제 선택을 확인했다. Clone 후보의 remark와 최종 remark를 구분했으며 추가
5개 object는 timed ON object와 byte-identical하다. 모든 아래 IC는 1이고
vector epilogue는 비활성이다.

| 입력 (`media-stats/` 접두사 생략), `bench_prepare` loop | 기존 선택 → 새 native 선택 | 실행 코드 |
|---|---|---|
| libwebp-ssim-clipped, 1 | scalar → scalar | 동일 |
| libyuv-ssim8x8-sums, 1 | vscale×8 → vscale×16 | 변경 |
| openh264-sample-variance16x16, 0 | scalar → scalar | 동일 |
| uvg266-reshape-chroma-stats, 0 | scalar → scalar | 동일 |
| xavs2-ssim-window-stats, 1 | vscale×8 → vscale×16 | 변경 |

OFF 313/313 및 ON 311/313의 executable/allocated sections와 정규화한 relocation이
기존 object와 같다. 두 변경 입력은 `bench_prepare`만 564 → 1,030 bytes로 변했고,
새 함수 bytes는 각각 새 OFF 함수와 정확히 같다. 다른 함수와 데이터 section은
그대로다. Disassembly diff와 함수별 비교는 `object_comparison.json`,
`changed_function_comparison.json` 및 benchmark 디렉터리에 있다.

전체 object hash는 모두 달랐지만 626개 OFF/ON 비교 중 624개는 `.comment`와
`.debug_str`의 compiler revision 문자열 `de1dc1e…` → `5d264abf…`만 바꾸면 전체
bytes가 같다. 이를 codegen 변화로 세지 않았다. 최종 진단 ON 313개 object도 모두
일반 timed ON object와 byte-identical하다. `object_metadata_summary.json` 및
`native-fallback-investigation/`에 추가 검증을 보존했다.

## 단계별 timing

다음은 별도 진단 313회의 구간 합계(초)다. backend 세부 구간은 성공 6,194건과
실행 후 실패 92건을 합쳤고, materialization 실패 1건은 backend에 진입하지 않았다.

| 구간 | Wall | CPU |
|---|---:|---:|
| Native 비용 / native IC / profile 비용 | 0.372161 / 0.006008 / 0.185045 | 0.370907 / 0.005340 / 0.185250 |
| Gate | 0.016735 | 0.016601 |
| Clone | 1.067354 | 1.067765 |
| TargetMachine·분석 준비 | 3.774592 | 3.774414 |
| 후보 materialization | 11.900363 | 11.908420 |
| IR suffix | 5.638315 | 5.636133 |
| Iteration mapping·검증 | 1.038893 | 1.033768 |
| Backend pipeline 구성 | 3.011129 | 3.011783 |
| RVV RA 이전 실행 | 34.716407 | 34.723112 |
| RVV allocation | 1.118079 | 1.110070 |
| 부분 rewrite | 0.185615 | 0.184423 |
| Spill 수집 | 0.083868 | 0.083485 |
| Backend 반환 | 0.822093 | 0.822087 |
| Provider 반환·정리 | 0.605212 | 0.605131 |
| Middle-end spill 가격 계산 | 0.008411 | 0.007873 |

중첩 total은 backend 40.523165초, provider query 64.551625초,
진단 출력까지 포함한 middle-end query 호출 68.533019초다. 이 total들을 세부 구간과
더하지 않는다. Backend allocation/rewrite 구간에는 필요한 분석 실행이 포함된다.
Target backend teardown 등은 상위 total에 포함돼 세부 합과 정확히 같지 않을 수 있다.
Timing OFF에는 clock 조회와 backend marker를 활성화하지 않는다. 원본 CPU/wall과
개수·평균·중앙값·최댓값은 `phase_timings.json`, `phase_timing_summary.{json,csv}`에 있다.

최종 비교 가능한 후보의 미해결 비용 차이는 없지만 전체 후보/전체 codegen의
동등성을 주장하지 않는다. 구조적 거부에 따른 5개 추가 fallback, 2개 코드 변화,
14개 문맥 비교 불가 및 17개 미평가를 명시적으로 남겼다. RISC-V 실행 성능이나
runtime 결과 검증은 이 컴파일 측정의 범위가 아니다.
