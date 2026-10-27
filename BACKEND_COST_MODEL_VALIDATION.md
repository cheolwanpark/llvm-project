# Backend feedback 전수 검증 — 2026-10-26

현재 `post-stack-slot-coloring` 버전은 이 데이터셋에서 **post-frame 기준과 성공
후보의 vector spill 접근·비용, VF/IC/epilogue 선택 및 생성 코드가 모두 일치**했다.
기존 fallback 88건은 유지하며, RVV RA 직후 버전의 추가 구조적 거부 5건은 해소했다.
전체 MIR나 진단 JSON의 byte 동일성을 의미하지 않는다.

## 측정 빌드와 검증 범위

새 소스를 증분 빌드해 clang/opt/llc를 교체한 뒤 전수검사했다. 이후 정리 시
실제 빌드와 캐시를 **`.cache/build`로 이동**했고, 이전 절대 경로용
`.cache/compiler-build → build` 호환 링크를 남겼다. 이동 후 증분 빌드는
`ninja: no work to do.`였으며 현재 binary 경로는 `.cache/build/bin/`이다.
Release, assertions/tests ON, projects `clang;lld`, targets `X86;RISCV`, parallel 2다.

- 측정 당시 clang SHA-256: `8d4634fc0de9e41ec29dfa4f9b3fbee848b6fd5beef5da3a06dd31b9af459ed3`.
- 측정 당시 소스는 `1b6cc792c` 이후 StackSlotColoring 변경을 적용한 작업 트리다.
  위 해시는 당시 측정 바이너리의 identity이며 이후 재빌드 결과와 구분한다.
- 같은 바이너리/소스의 회귀 검증: VectorizeTests 82/82, VPlanRATests 1/1,
  RISCVTests 34/34, RISC-V LoopVectorize·vplan-ra·RVV StackSlotColoring lit 151/151.
- Probe 실행 기록에서 RVV RA → 부분 rewrite → 추가 여섯 pass → collector를 확인했다.
  여섯 pass는 InsertVSETVLI, DeadRegisterDefinitions, scalar allocator, 전체
  VirtRegRewriter, RegAllocScoring(기본 no-op), StackSlotColoring이다.
  이후 copy propagation·post-RA LICM·frame lowering은 실행하지 않는다.
- 비용식·gate·native IC·main/epilogue 정책을 유지한다. 실패하면 loop 전체가 native로
  복귀하며 post-frame 재질의는 없다. `utils/` 새 요약 호환성 suite는 범위 밖이다.

계약과 사용법은 [BACKEND_FEEDBACK.md](BACKEND_FEEDBACK.md), 고정 TTI 규칙은
[TTI_PROFILE.md](TTI_PROFILE.md)에 있다. 현재 수집은 vector spill 전용이다.
최종 scalar spill까지 지원하려면 관측 지점과 collector를 확장해야 한다.

## 측정 조건과 세 버전 비교

워크트리의 `dataset.sqlite` 313개(C 231, C++ 82)를 전수 검사했다.
DB SHA-256은 `8885672e1219a93c91edf3f37c5ccbc177b3fc757a0b161735f11e03a727d7c0`다.
다른 203개 DB나 20개 표본의 평균을 섞지 않았다.

Subagent가 새 compiler로 OFF/ON 각각 3회, 총 **1,878회**를 serial로 실행했고
모두 성공했다. 별도 ON timing·요약 진단 **313회**도 모두 성공했다.
DB source bytes·source path·언어·target·최적화·FP 옵션을 그대로 사용했다.
IC=1, vector epilogue 비활성, LMUL=8, 기본 gate다. OFF/ON 순서를 교대하고
monotonic wall timer와 blocking wait, 별도 300초 watchdog을 사용했다.
빌드·준비·hash 계산과 별도 진단 시간은 일반 컴파일 평균에서 제외했다.

아래는 **각 입력의 3회 평균을 다시 산술평균한 compiler wall time**이다.
post-RA는 여기서 *RVV allocator와 부분 rewrite 직후*를 뜻한다.
두 과거 버전은 저장된 결과만 사용했으며 재실행하지 않았다.

| 버전 | OFF 평균(s) | ON 평균(s) | ON/OFF | ON 총 wall(s), 939회 |
|---|---:|---:|---:|---:|
| post-frame, 전체 MIR | 0.054582866 | 0.358218009 | 6.563× | 336.366710 |
| post-RA, spill-only | 0.056923548 | 0.263211220 | 4.624× | 247.155336 |
| 이번 StackSlotColoring 직후 | 0.059423948 | 0.269370997 | 4.533× | 252.939366 |

이번 ON은 저장된 post-RA 대비 **+2.34%**
(평균 +6.160ms), post-frame 대비
**-24.80%**다. OFF는 post-RA 대비
+4.39% 변했다. 새 ON/OFF만 같은 실행 세션의 비교다.
이전 버전 대비 수치는 호스트 상태와 빌드 시점 차이가 있는 역사적 비교이며,
통제된 동시 speedup이나 여섯 pass만의 인과적 비용으로 단정하지 않는다.
생성 프로그램의 실행시간은 측정하지 않았다.

별도 진단의 `post_rvv_to_stack_slot_coloring` 구간은 총 2.125947s,
6,303개 실행 구간당 평균 0.337ms,
313개 compile당 합계 평균 **6.792ms**였다.
이는 여섯 pass와 필요한 분석 재구성을 포함한다. 6,304개 query 중 1개는 이 단계
전에 실패했다. 중첩된 backend/query total과 세부 phase는 중복 합산하지 않는다.

## post-frame 결과 동등성

| 비교 항목 | 결과 |
|---|---:|
| 후보 / 실제 query / gate 생략 | 7,635 / 6,304 / 1,331, 모두 동일 |
| 성공 후보의 접근·raw/정확 정규화 비용 | 7,547/7,547 동일 |
| 최종 VF·IC·epilogue 선택 | 1,085/1,085 동일 |
| native fallback loop 집합 | 기존 88/88 동일, 신규 0 |
| OFF object 실행·allocated section + 정규화 relocation | 313/313 동일 |
| ON object 실행·allocated section + 정규화 relocation | 313/313 동일 |
| timing/요약 ON object와 일반 ON object | 313/313 byte 동일 |

Candidate identity·VF·IC·역할·검증된 iteration 폭과 앞선 loop 선택 문맥을 맞춰
비교했다. 전체 object hash의 차이는 626개 모두 `.comment`와 `.debug_str`의 compiler
version 문자열뿐이다. 구 version 문자열을 새 문자열로 치환하면 626/626개 전체
object bytes도 일치한다. 실행·allocated section과 정규화 relocation은 별도로 대조했다.
전체 MIR·실행 순서 전부의 동일성이나 다른 입력·설정에서의 동등성을 주장하지 않는다.
이번 DB에는 segment spill이 없으며, segment 분할 지원은 LLVM 회귀 테스트로 검증했다.

기존 실패 88건 중 **87건은 진단 표현이 다르다**. 예를 들어 post-frame의
`collected` + `cost_failure="invalid backend loop/iteration mapping"`은 현재
`unavailable` + `"original scalar iteration mapping is unproven"`이다.
해당 fallback 이유 87행(38개 입력)도 달라진다. 이는 모두 post-RA spill-only
버전부터 존재한 Error 전달 계약 차이이며, 실패한 loop 집합과 native 복귀 결과는 같다.

## post-RA 대비 복구와 비교 범위

연속 reload/store의 dead store를 StackSlotColoring에서 실제로 제거하므로,
libwebp·libyuv·openh264·uvg266·xavs2의 `bench_prepare` loop **5건이 복구**됐다.
총 fallback은 93 → 88, query는 6,287 → 6,304, 후보 행은 7,618 → 7,635다.
다섯 loop의 선택은 post-frame 기준과 같고, benchmark 이름별 예외는 없다.

post-RA와 직접 비교 가능한 성공 후보 7,511개는 모두 동일했다.
복구 후보 5개, 이후 새로 평가한 후보 17개, 앞선 loop 선택이 달라진 문맥의 후보
14개는 별도로 분리했다. post-frame과의 전수 비교에서는 성공 후보와 선택의
차이가 남지 않았다. 실패한 후보를 spill 0 또는 성공 비용으로 집계하지 않았다.
post-RA 대비 object 코드 차이는 libyuv/xavs2의 ON 두 개뿐이다. 두 경우
`bench_prepare`가 1,030 → 564 bytes로 post-frame 결과에 복귀했으며 다른 함수는 같다.

## 보존 자료와 독립 검산

재사용할 기준은 [post-frame reference](.cache/post-frame-reference/README.md)에
통합했다. 원본 DB·소스·header·옵션, OFF/ON 1,878회 시간과 object,
전체 MIR 관측 313개, 보조 gate 측정 및 두 compiler identity를 보존한다.
MIR JSONL은 무손실 gzip이며 portable manifest와 전체 해시 검증 도구를 제공한다.

```sh
python3 -B .cache/post-frame-reference/reference.py verify
```

당시 Main은 raw journal의 실행 수·성공 여부·순서, Decimal 평균·합계,
DB/source/flags와 compiler·LLVM source hash를 독립 검산했다. 성공 비용·접근·선택·gate,
fallback loop 집합과 진단 계약 차이도 대조했다. Compiler version 문자열만 치환한
전체 object 626개의 byte 일치를 독립 확인했다.

정리 요청에 따라 post-RA·StackSlotColoring 전수/표본 실행 원본과 일회성 검증 로그,
중복 과거 보고서는 삭제했다. 이 문서의 세 버전 집계·검증 결과는 당시 기록이며,
이후 비교를 위해 보존한 raw reference는 post-frame 자료다. 실제 compiler와
증분 빌드 캐시는 `.cache/build/`에 유지한다.

Post-frame 시간과 관측은 서로 다른 바이너리의 실행이다. 관측 object는 보조
`gate-timing`의 gate-on object와 byte 동일하고, 주 시간 측정 ON object와는 실행·
allocated section/정규화 relocation이 동일함을 보존 검사에서 확인한다.
이를 하나의 바이너리 실행으로 간주하지 않는다.
