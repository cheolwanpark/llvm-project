# Backend feedback 검증 기록

측정 시점과 compiler identity를 구분한다. 사용법은 [README](README.md),
비용·probe·TTI 계약은 [BACKEND_FEEDBACK.md](BACKEND_FEEDBACK.md)에 있다.

## 2026-10-27 — LLVM 내부 body/spill ablation 기본 검증

`cf0330d4664acb831a3c17be8c84c4e671834e25` 기반 작업 트리에 세 ablation 옵션과
타겟별 MIR Info를 구현했다. 이 checkout에는 기존 build cache가 없어
`.cache/build`에 Release/assertions/tests, `clang;lld`, `X86;RISCV` 설정으로 새로
빌드했다. `.cache/compiler-build -> build` 호환 symlink도 유지한다.
빌드는 `--parallel 2`를 사용했고 최종 증분 검사에는 남은 작업이 없었다.
최종 Clang SHA-256은 `b9447658e040ccc9f55b4915c1529ebc817d7cee48dcaf6beeac8bd99f395be3`이다.

| 검증 | 결과 |
|---|---|
| Vectorize unit suite | 86/86 통과 |
| RISC-V unit suite | 38/38 통과 |
| 관련 lit | 6/6 통과 |
| Clang 객체 생성 smoke | 6개 body/spill 조합 모두 성공, native fallback 없음 |
| Python/C++ MIR 가격 규칙 대조 | 2,343 opcode/geometry 사례, 불일치 0 |

Lit 범위는 `backend-ablation.ll`, 기존 `backend-feedback.ll`,
`backend-feedback-spills.ll`, `backend-feedback-parallel.ll`,
`backend-cost-report.ll`, `rvv/stack-slot-coloring.mir`다. 새 테스트는 8개 boolean
조합·master OFF 무효화·MIR에서 default-TTI 무시·TTI estimated 모드의 probe
생략·MIR gate 우회·실제 spill 교체·직렬/병렬 일치·IC=4 정규화·강제 epilogue·
미지원 CPU/VLEN 및 제한된 pipeline의 fallback·상세 report의 수동성을 검사한다.
RISC-V의 기존 자동 epilogue 거부 정책은 바꾸지 않았다.

가격 규칙 대조는 `llvm-cost-model`의 Python service-sum 모델과 이 checkout의
C++ MIR Info를 같은 명령 정보에 적용한 것으로, 전체 dataset이나 최종 실행 성능
비교가 아니다. Unit test는 scalar/vector 전체 spill의 합산, 유리수 정규화와
약분 전 곱셈의 overflow 경계도 검사한다. 실제 후보 probe와 객체 생성은 이
checkout에서 빌드한 compiler로 확인했다.

로그, 가격 대조 스크립트/결과와 smoke 명령·binary/object hash는
`.cache/ablation-implementation/`에 보관한다. 전체 dataset 측정, RTL 실행 및
성능 비교는 수행하지 않았다. 아래의 과거 측정값은 이번 ablation binary의
측정값으로 해석하지 않는다.

## 2026-10-27 — 제한된 probe 병렬 실행

### 조건과 측정 방법

- Clang SHA-256: `1e16febe60089404ba06746b24ff0e7bd20c891bca620a1561ebe7178725e560`.
- 소스: `30da895c26fe074f26c0283f546af4d613982615`에 batch provider와 독립 context의
  제한된 probe pool을 적용한 작업 트리. 관련 소스별 hash는 보존한 `identity.json`에 있다.
- 기존 Release/assertions/tests 빌드, `clang;lld`, `X86;RISCV`를 사용했다.
- 이 checkout의 `dataset.sqlite` 313개(C 231, C++ 82), DB SHA-256
  `8885672e1219a93c91edf3f37c5ccbc177b3fc757a0b161735f11e03a727d7c0`.
- Portable reference의 source bytes·언어·effective flags를 유지했다. IC=1,
  vector epilogue 비활성, LMUL=8이며 ON은 기본 gate, FORCE ALL은 ON에
  `-vplan-backend-force-all=true`를 추가한 설정이다.

입력마다 worker=1 OFF → ON → FORCE ALL → worker=4 ON → worker=8 ON →
worker=16 ON 순으로 **각각 한 번**, 총 1,878회 실행했다. Compiler 프로세스는
한 번에 하나만 실행하고 내부 probe만 병렬화했다. Monotonic wall timer와 blocking
wait, 300초 timeout을 사용했다. 빌드·준비·hash·진단은 일반 시간에서 제외했다.
`-vplan-backend-time`은 사용하지 않았다. 별도 worker=1 ON 진단은 313회로 한 번만
수집했다. 일반 1,878회와 진단 313회가 모두 성공했고 timeout은 없었다.
중단된 이전 3회 반복 실험의 501개 기록은 이번 통계에 포함하지 않았다.

### Compiler wall time

Mean·median·p95는 313개 입력별 단일 compile 시간의 분포다. 총합은 해당
313회 wall time의 합이며, p95는 nearest rank 방식의 298번째 값이다.

| Workers | 설정 | 총합(s) | Mean(ms) | Median(ms) | p95(ms) |
|---:|---|---:|---:|---:|---:|
| 1 | OFF | 17.359278 | 55.460953 | 52.589454 | 72.793135 |
| 1 | ON | 81.006141 | 258.805562 | 129.911879 | 890.127818 |
| 1 | FORCE ALL | 89.247861 | 285.136935 | 136.137248 | 912.626922 |
| 4 | ON | 37.961487 | 121.282707 | 88.171011 | 332.445336 |
| 8 | ON | 32.653200 | 104.323324 | 81.565679 | 219.584065 |
| 16 | ON | 31.326401 | 100.084349 | 78.243622 | 207.595974 |

이 실행에서 ON 총합/평균은 worker=1 대비 worker=4에서 53.14%, worker=8에서
59.69%, worker=16에서 61.33% 줄었다. Worker=16의 비율은 2.586×다.
Worker=1의 ON은 FORCE ALL보다 9.23% 짧았다. 각각 한 번의 측정이며 과거
compiler의 시간과 합쳐 speedup을 계산하지 않았다.

### Gate와 결과 동등성

별도 worker=1 ON 진단에서 후보 **7,635개** 중 **6,304개**를 query하고,
**1,331개(17.432875%)**를 gate로 생략했다. 이는 기본 ON의 논리적 후보 결정
개수이며, 병렬 실패 batch에서 미리 실행한 작업 수나 FORCE ALL의 실제 query
개수를 뜻하지 않는다. 성공 후보 7,547개, 성공 관측 6,216개, 선택 1,085개,
native fallback 88개였다.

구현 전에도 subagent가 `.cache/parallelism-baseline-20261027/`에서 기존 binary를
reference와 대조했다. 일반 1,878회와 진단 313회가 성공했고, raw 기록을 별도로
검산했다. Reference 자체는 top-level `reference.py verify`로 13,515개 보존 파일을
검증했다. 과거 compiler는 실행하지 않았다.

이번 worker=1 진단 313개 stream은 구현 전과 정확히 같았다. Post-frame과는
성공 후보의 spill·정확 비용·선택·gate·fallback이 같고, 아래 역사적 절에서 설명한
기존 실패 87건의 오류 표현 차이만 유지됐다. 각 오류는 저장된 underlying error와
대조했으며 새 실패는 없었다.

OFF 313개와 ON의 각 worker 설정 313개 object는 reference와 실행·allocated
section 및 정규화 relocation이 일치했다. ON의 worker=1·4·8·16 object는 서로
byte 동일했다. 별도 진단 object도 일반 ON과 313/313개 byte 동일했다.
FORCE ALL도 이번 입력에서는 기본 ON과 allocated section·relocation이 모두 같았다.
일반 실행의 stderr는 구현 전과 1,878/1,878개 같고 직렬 전환 warning은 없었다.

### 회귀 검사와 보존 자료

Vectorize unit tests 85개, RISCV unit tests 34개가 통과했다. LoopVectorize와
RVV StackSlotColoring lit 검사는 983개 통과, 377개 unsupported였다. 마지막
진단 옵션 호환성 보완 후 해당 병렬 lit와 두 unit suite를 다시 통과했다.
Opt-only 검사는 1·2·4 workers의 IR·JSON·report, gate·spill·epilogue·실패 및
진단 시 직렬 전환을 확인한다. Pool unit test는 실제 중첩·상한·완료 순서와 무관한
결과 순서·재사용을 확인한다.

Provider·cost model·pool test 소스를 TSan으로 계측한 unit/integration 검사가
통과했다. 연결된 upstream LLVM 라이브러리는 계측하지 않았으므로 LLVM 전체
backend 경로의 TSan 검증으로 해석하지 않는다. 범위와 로그는
`.cache/parallelism-tsan-check/`에 보존했다.

이번 raw argv·시간·object·진단·통계·identity는
[.cache/parallelism-single-run-20261027](.cache/parallelism-single-run-20261027/summary.json)에
있다. Main agent가 `independent-audit.json`에서 실행 수·성공·비중첩 순서,
2,191개 argv·소스·옵션, mean·median·p95·총합, gate 개수와 object를 독립 검산했다.
최종 unexpected comparison mismatch는 0이다. 캐시 측정 자료는 commit하지 않는다.

## 2026-10-27 — SPEC 앱 소스 컴파일 시간

`/work/loop-benchmarks/app_benchmarks`의 SPEC 앱 10개에서 `test` workload만
선택했다. Smoke와 train은 제외했다. 기존 builder에서 앱 소스 컴파일은 workload
입력과 독립적이며, 이 실험은 입력 생성·embedding·runtime/helper 빌드·링크·validator·
앱 실행을 하지 않았다. 원본 소스·manifest·SDK와 기존 builder는 수정하지 않았다.

기존 XiangShan 프로필(VLEN=128, LMUL=8, IC=1, vector epilogue 비활성), `-O3`,
원래 FP 정책을 유지했다. 각 앱에서 OFF → ON(worker=1) → ON(worker=4) →
ON(worker=8)을 각각 한 번 실행했다. 앱·TU·compiler 프로세스 모두 순차 실행했다.
각 값은 앱 소스의 frontend → opt → backend → assemble subprocess wall time 합계다.
Source/hash 준비와 Python 기록 처리는 제외했고, 각 subprocess timeout은 300초였다.

기존 builder의 두 opt remark 출력 옵션은 병렬 probe를 직렬로 전환시키므로,
별도 측정 adapter에서 네 설정 모두 이 두 옵션만 제거했다. 변경 전후 argv를
모두 보존했다. 기존 staged pipeline과 `opt`의 codegen 설정을 유지했으므로,
앞의 313-input single-Clang 실험과 absolute time을 직접 섞지 않는다.
Compiler는 위와 동일한 SHA-256 `1e16febe60089404ba06746b24ff0e7bd20c891bca620a1561ebe7178725e560`이고,
opt SHA-256은 `4420e241afcb5c8759948a6f8a60ae738bf674b8f298c8e566d125b0b455320d`다.

| 앱 | OFF(s) | ON worker=1(s) | ON worker=4(s) | ON worker=8(s) |
|---|---:|---:|---:|---:|
| 433.milc | 6.305 | 6.588 | 6.785 | 6.682 |
| 444.namd | 12.440 | 13.553 | 14.565 | 13.901 |
| 456.hmmer | 11.007 | 11.555 | 12.020 | 11.704 |
| 464.h264ref | 21.516 | 24.201 | 25.192 | 24.871 |
| 470.lbm | 0.453 | 0.615 | 0.858 | 0.676 |
| 482.sphinx3 | 6.825 | 7.357 | 7.900 | 7.601 |
| 519.lbm_r | 0.511 | 0.714 | 0.983 | 0.790 |
| 525.x264_r | 17.680 | 18.581 | 19.526 | 18.942 |
| 538.imagick_r | 55.282 | 90.696 | 133.373 | 109.066 |
| 544.nab_r | 7.500 | 8.613 | 9.322 | 9.686 |

40개 측정, 1,516회 TU 빌드(379개 소스 × 4설정), 6,064개 compiler 단계가 모두
성공했고 timeout과 직렬 전환 warning은 없었다. ON worker=4·8은 각각 379개
object의 실행·allocated section 및 정규화 relocation이 worker=1과 같았다.
Main agent가 모든 raw argv, 순차 실행·성공 수, 단계별 ns 합계와 40개 표 값을
독립 검산했다. 이번 단일 실행에서는 모든 앱의 ON worker=1이 worker=4·8보다
짧았다. Gate/probe 실행 횟수는 별도로 측정하지 않았으므로 원인을 시간만으로
단정하지 않는다.

실험 조건·해석 범위·raw 시간·단계별 합계·identity는
[.cache/app-compile-single-run-20261027](.cache/app-compile-single-run-20261027/README.md)에
보존했다. `summary.json`은 앱별 결과, `commands.jsonl`은 원시 단계 기록,
`independent-audit.json`은 독립 검산이다. 기존 앱 저장소의 수정 사항은 보존했다.

## 2026-10-26 — post-stack-slot-coloring 검증

이 절은 **2026-10-26에 측정한 compiler와 데이터셋**의 역사적 기록이다.
아래 수치는 위의 2026-10-27 병렬 probe 측정과 별개이며, 당시 compiler를 다시 실행하지 않았다.
현재 사용법은 [README](README.md), 비용·probe·TTI 계약은
[BACKEND_FEEDBACK.md](BACKEND_FEEDBACK.md)에 있다.

당시 `post-stack-slot-coloring` 버전은 이 데이터셋에서 post-frame 기준과 성공
후보의 vector spill 접근·비용, VF/IC/epilogue 선택과 생성 코드가 일치했다.
기존 fallback 88건은 유지하고 RVV RA 직후 버전의 추가 구조적 거부 5건은 해소했다.
이는 전체 MIR 또는 진단 JSON의 byte 동일성을 뜻하지 않는다.

### 측정 identity와 조건

- Clang SHA-256: `8d4634fc0de9e41ec29dfa4f9b3fbee848b6fd5beef5da3a06dd31b9af459ed3`.
- 소스: `1b6cc792c` 이후 StackSlotColoring 변경을 적용한 작업 트리.
- 빌드: Release, assertions/tests ON, `clang;lld`, `X86;RISCV`, parallel 2.
- 데이터: `dataset.sqlite` 313개(C 231, C++ 82).
  DB SHA-256: `8885672e1219a93c91edf3f37c5ccbc177b3fc757a0b161735f11e03a727d7c0`.
- 원본 source bytes·path·언어·target·최적화·FP 옵션을 유지하고 IC=1,
  vector epilogue 비활성, LMUL=8, 기본 gate를 적용했다.

OFF/ON을 교대하며 각각 3회, 총 **1,878회**를 serial로 실행했고 모두 성공했다.
별도 ON timing·요약 진단 **313회**도 성공했다. Monotonic wall timer, blocking wait와
별도 300초 watchdog을 사용했다. 빌드·준비·hash와 별도 진단은 일반 시간에서 제외했다.
다른 DB나 표본의 평균은 섞지 않았다. Probe 기록에서 RVV RA → 부분 rewrite →
InsertVSETVLI, DeadRegisterDefinitions, scalar allocator, 전체 VirtRegRewriter,
RegAllocScoring, StackSlotColoring → collector 순서를 확인했다.

### Compiler wall time

각 입력의 3회 평균을 다시 산술평균했다. Post-RA는 RVV allocator와 부분 rewrite
직후를 뜻한다. 두 비교 버전은 저장된 결과만 사용했으며 재실행하지 않았다.

| 측정 버전 | OFF 평균(s) | ON 평균(s) | ON/OFF | ON 총 wall(s), 939회 |
|---|---:|---:|---:|---:|
| post-frame | 0.054582866 | 0.358218009 | 6.563× | 336.366710 |
| post-RA | 0.056923548 | 0.263211220 | 4.624× | 247.155336 |
| post-stack-slot-coloring | 0.059423948 | 0.269370997 | 4.533× | 252.939366 |

Post-stack-slot-coloring ON은 저장된 post-RA 대비 **+2.34%**(평균 +6.160ms),
post-frame 대비 **−24.80%**였다. OFF도 post-RA 대비 +4.39% 변했다.
Post-stack-slot-coloring의 OFF/ON만 같은 실행 세션에서 측정했다. 버전 간 비율은
호스트 상태와 빌드 시점이 다른 역사적 비교이며 통제된 동시 speedup이나 추가 pass만의
인과적 비용으로 단정하지 않는다. 생성 프로그램의 실행시간은 측정하지 않았다.

별도 진단의 `post_rvv_to_stack_slot_coloring` 구간은 총 2.125947s,
6,303개 실행 구간당 평균 0.337ms, 313개 compile당 합계 평균 **6.792ms**였다.
여섯 pass와 필요한 분석 재구성을 포함한다. 6,304개 query 중 1개는 이 단계 전에
실패했다. 중첩된 backend/query total과 세부 phase는 중복 합산하지 않았다.

### Post-frame 결과 동등성

| 비교 항목 | 결과 |
|---|---:|
| 후보 / 실제 query / gate 생략 | 7,635 / 6,304 / 1,331, 모두 동일 |
| 성공 후보의 접근·raw/정확 정규화 비용 | 7,547/7,547 동일 |
| 최종 VF·IC·epilogue 선택 | 1,085/1,085 동일 |
| native fallback loop 집합 | 기존 88/88 동일, 신규 0 |
| OFF object 실행·allocated section + 정규화 relocation | 313/313 동일 |
| ON object 실행·allocated section + 정규화 relocation | 313/313 동일 |
| timing/요약 ON object와 일반 ON object | 313/313 byte 동일 |

Candidate identity·VF·IC·역할·반복 폭과 앞선 loop 선택 문맥을 맞췄다.
전체 object hash 차이는 626개 모두 `.comment`와 `.debug_str`의 compiler version
문자열뿐이었고, 그 문자열을 맞추면 전체 object bytes도 626/626개 일치했다.
실행·allocated section과 정규화 relocation은 별도로 대조했다. 이 DB에는 segment
spill이 없으며 segment 분할은 LLVM 회귀 테스트로 검증했다.

기존 실패 88건 중 87건(38개 입력)은 진단 표현이 달랐다. 예를 들어 post-frame의
`collected` + `cost_failure="invalid backend loop/iteration mapping"`이
`unavailable` + `"original scalar iteration mapping is unproven"`으로 바뀌었다.
Post-RA부터 존재한 Error 전달 차이이며 실패 loop 집합과 native 복귀 결과는 같았다.

### Post-RA 대비 복구

StackSlotColoring의 연속 reload/store dead-store 제거로 libwebp·libyuv·openh264·
uvg266·xavs2의 `bench_prepare` loop **5건이 복구**됐다. Fallback은 93 → 88,
query는 6,287 → 6,304, 후보 행은 7,618 → 7,635였다. 다섯 loop의 선택은 post-frame과
같았으며 benchmark 이름별 예외는 없었다.

직접 비교 가능한 성공 후보 7,511개는 모두 동일했다. 복구 후보 5개, 이후 새로 평가한
17개, 앞선 loop 선택 문맥이 달라진 14개는 구분했다. 실패한 후보를 spill 0이나
성공 비용으로 집계하지 않았다. Object 코드 차이는 libyuv/xavs2의 ON 두 개뿐이었다.
두 경우 `bench_prepare`가 1,030 → 564 bytes로 post-frame 결과에 복귀하고 다른 함수는 같았다.

### 보존 자료와 검산

재사용할 raw reference는 [.cache/post-frame-reference](.cache/post-frame-reference/README.md)에
있다. DB·소스·header·옵션, OFF/ON 1,878회 시간과 object, MIR 관측 313개,
보조 gate 측정과 compiler identity를 보존한다. Portable manifest와 해시 검증을 사용한다.

```sh
python3 -B .cache/post-frame-reference/reference.py verify
```

Post-RA·StackSlotColoring 결과는 이 문서의 당시 집계로 남아 있다. 당시 측정 담당과
별도로 raw 실행 수·성공·순서, Decimal 평균·합계, DB/source/flags와 compiler/source
hash, 비용·접근·선택·gate·fallback, 전체 object 626개의 문자열 보정 후 일치를 검산했다.

Post-frame 시간과 관측은 서로 다른 binary의 실행이다. 관측 object는 보조
`gate-timing`의 gate-on object와 byte 동일하고, 주 timing ON object와는 실행·allocated
section/정규화 relocation이 동일함을 보존 검사에서 확인한다. 이를 하나의 binary
실행으로 간주하지 않는다. 현재 compiler와 증분 캐시는 `.cache/build/`에 유지한다.
