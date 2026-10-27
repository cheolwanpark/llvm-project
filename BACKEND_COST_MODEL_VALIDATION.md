# Backend feedback 전수 검증 — 2026-10-26

이 문서는 **2026-10-26에 측정한 compiler와 데이터셋**의 기록이다. 이후 재빌드한
현재 binary의 측정값이 아니며, 문서 정리 과정에서 전수 측정을 다시 실행하지 않았다.
현재 사용법은 [README](README.md), 비용·probe·TTI 계약은
[BACKEND_FEEDBACK.md](BACKEND_FEEDBACK.md)에 있다.

당시 `post-stack-slot-coloring` 버전은 이 데이터셋에서 post-frame 기준과 성공
후보의 vector spill 접근·비용, VF/IC/epilogue 선택과 생성 코드가 일치했다.
기존 fallback 88건은 유지하고 RVV RA 직후 버전의 추가 구조적 거부 5건은 해소했다.
이는 전체 MIR 또는 진단 JSON의 byte 동일성을 뜻하지 않는다.

## 측정 identity와 조건

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

## Compiler wall time

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

## Post-frame 결과 동등성

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

## Post-RA 대비 복구

StackSlotColoring의 연속 reload/store dead-store 제거로 libwebp·libyuv·openh264·
uvg266·xavs2의 `bench_prepare` loop **5건이 복구**됐다. Fallback은 93 → 88,
query는 6,287 → 6,304, 후보 행은 7,618 → 7,635였다. 다섯 loop의 선택은 post-frame과
같았으며 benchmark 이름별 예외는 없었다.

직접 비교 가능한 성공 후보 7,511개는 모두 동일했다. 복구 후보 5개, 이후 새로 평가한
17개, 앞선 loop 선택 문맥이 달라진 14개는 구분했다. 실패한 후보를 spill 0이나
성공 비용으로 집계하지 않았다. Object 코드 차이는 libyuv/xavs2의 ON 두 개뿐이었다.
두 경우 `bench_prepare`가 1,030 → 564 bytes로 post-frame 결과에 복귀하고 다른 함수는 같았다.

## 보존 자료와 검산

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
