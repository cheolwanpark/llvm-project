# TSVC real-spill fallback 수정용 목록

2026-11-04 수집한 XiangShan Kunminghu / VLEN=128 자연 후보 787개 중,
**real-spill을 요청했지만 estimated spill로 fallback한 193개 구성(44개 소스)**의 목록이다.
각 행은 `case × fixed/scalable VF` 하나다. 실패한 관측을 zero spill로 해석하지 않는다.
여기서 `~`는 `/work`이므로 요청한 저장소는 `/work/llvm-integration-ablation`,
benchmark 저장소는 `/work/loop-benchmarks`다.

| 실패 코드 | 관측 실패 이유 | 구성 수 | TP | FP | FN | TN |
|---|---|---:|---:|---:|---:|---:|
| M | `original scalar iteration mapping is unproven` | 186 | 10 | 4 | 102 | 70 |
| B | `only innermost single-block loops have a proven circular execution order` | 7 | 0 | 0 | 0 | 7 |
| 합계 | | 193 | 10 | 4 | 102 | 77 |

Requested model은 `llvm-real-vector-spill-v1`, 실제 effective model은 모든 행에서
`llvm-v1`이다. FP/FN 106개는 전부 M에 속한다. 관측에 성공한 나머지 594개는
이 목록에서 제외했다. 이는 역사적 실패 목록이며, 이후 수정한 compiler에서도
같은 결과가 나올 것으로 가정하지 않는다.

## 실패 이유별 case / VF 색인

아래는 관측된 실패 이유 기준의 분류다. TP/FP/FN/TN은 spill 예측의 정확도이며,
fallback 원인이 아니므로 이유별 그룹을 나누는 기준으로 사용하지 않는다.
193개 구성의 최종 함수에 해당하는 retained `feedback.jsonl`의 실패 attempt를
대조했으며, 아래 M/B 분류와 모두 일치했다. M 세분류의 추가 진단 실행은 아래에 별도로 기록했다.

| 이유 | 소스 수 | Fixed 구성 | Scalable 구성 | 전체 구성 |
|---|---:|---:|---:|---:|
| M — 원본 scalar iteration 대응을 증명하지 못함 | 44 | 78 | 108 | 186 |
| B — machine loop의 순환 실행 순서를 증명하지 못함 | 1 | 5 | 2 | 7 |
| 합계 (소스는 중복 제거) | 44 | 83 | 110 | 193 |

`s332`는 VF에 따라 M과 B 양쪽에 속한다. 그 외 43개 소스의 이 목록에 있는 구성은
모두 M이다. 아래 VF는 실패한 구성만 나타내며, 나열하지 않은 VF의 성공 여부는
이 색인으로 판단하지 않는다. 구성별 분류와 원본 근거 링크는 뒤의 전체 목록에 있다.

### M — iteration mapping 미증명: 증명 가능성별 세분류

진단: `original scalar iteration mapping is unproven`. 이 메시지는 실제 원인을
가린다. `finalizeVPlanBackendIterationMapping`은 mapping을 0으로 초기화한 뒤,
`findVPlanBackendObservedLoop`가 loop를 찾지 못하거나 여러 개를 찾으면 그대로
반환한다. 이후 `collectBody`가 위 공통 메시지를 출력한다.

**186개 전부가 단순한 affine-step 계산 실패는 아니다.** 이번 probe IR 조사에서는
8개 구성은 candidate identity가 여러 loop에 복제되었고, 178개 구성은 관측할
candidate loop 자체가 남지 않았다. 따라서 `iteration-mapping=1`만 설정하거나
width만 복구하는 수정으로는 어느 그룹도 안전하게 해결되지 않는다.

| 그룹 | 직접 확인한 구조적 원인 | 구성 수 | 증명/수정 가능성 |
|---|---|---:|---|
| M1 | 외부 loop unroll로 affine candidate loop가 8개로 복제됨 | 4 | 개별 loop의 mapping은 증명 가능. Clone identity와 관측 통합 지원이 필요한 가장 명확한 수정 후보 |
| M2 | 외부 loop unroll로 EVL candidate loop가 4개로 복제됨 | 4 | 개별 EVL 증명 패턴은 남음. Clone별 trip/active-lane 차이까지 다뤄야 하는 조건부 수정 후보 |
| M3 | 단일 block candidate loop가 suffix 후 소멸 | 156 | 현재 loop observer로는 불가. 유한 region의 출처/범위/실행량을 증명하는 확장 후보 |
| M4 | Materialization 직후부터 vector body에 backedge와 candidate loop marker가 없음 | 19 | 현재 loop observer로는 불가. 단일 vector 실행 region의 provenance와 실제 처리량 지원 필요 |
| M5 | Early-exit candidate loop가 suffix에서 분기 region으로 펼쳐짐 | 3 | 현재 loop observer로는 불가. 경로별 실행량과 spill 비용 증명 없이는 하나의 정확한 비용으로 합칠 수 없음 |
| 합계 | | 186 | |

여기서 **불가**는 현재의 «유일한 candidate machine loop / 순환 실행 / iteration width»
계약을 유지할 때의 판정이다. 수학적으로 어떤 확장으로도 증명할 수 없다는 뜻은
아니다. M1/M2도 구현 완료나 real-spill 성공을 뜻하지 않으며, 아래 수정 방향은
IR 증거에 근거한 제안이다. 기존 observer 조건을 완화하는 것과 새로운 관측 대상을
정의하는 것은 구분해야 한다.

#### 조사 방법과 증거

2026-11-04에 M의 186개 `record.json`에서 opt 명령만 재실행했다. Retained
`forced.ll`을 사용하고 출력 경로를 새 디렉터리로 바꾼 뒤, 기존 passive 옵션
`-vplan-backend-pruning-dump-ir -vplan-backend-pruning-trace`를 추가했다.
`before`는 materialization 직후, `after`는 pruning 직후, `suffix`는 최적화 suffix
직후이며 mapping finalization 직전이다. 최종 assembly에서 원인을 역추정하지 않았다.

- Opt SHA256: `0112e01e1e5275058947e132092cdc4091ead0075d3017de0d15513783dd4fc5`.
  원본 collection의 opt hash 및 checkout `a8aa57f9c94f558b6eb64c8cea2b6ca935cce567`과 일치한다.
- 186개 모두 원래 최종 함수의 M fallback을 재현했고, 입력 forced IR hash도 원본 준비 기록과 일치했다.
- Suffix IR에 `print<loops>`를 실행해 잔존 loop를 확인했다. Marker 정의가 하나여도
  여러 latch가 같은 loop metadata를 참조할 수 있으므로 정의 개수만 세지 않았다.
- 이 조사는 원인 진단이다. Timing 비교, 전체 dataset 측정, 최종 backend 재수집,
  compiler 수정, 테스트 추가/수정은 하지 않았다.
- [조사 manifest](.cache/fallback-mapping-audit-414e8est/manifest.json)에 186개 구성의 subgroup, command/IR 경로,
  pruning trace, fallback 및 marker backedge 개수를 보존했다. 각 구성 디렉터리에는
  `command.json`, `diagnostics.txt`, `feedback.jsonl`, 단계별 IR과 `suffix-loops.txt`가 있다.

#### M1 — affine loop의 중복 identity: 우선 수정 후보 (4개)

`s176`은 외부 loop가 8-way unroll되면서 `vector.body`부터 `vector.body.7`까지
8개의 innermost single-block loop가 같은 candidate marker를 공유한다.
각 loop의 induction metadata와 affine 증가량은 모두 남아 있다. `f2/s1`은
scalar step 2, `f4/s2`는 step 4이고 각 inner loop는 160 scalar iterations를 처리한다.
Scalable 설정은 `vscale_range(2,2)`에서 해당 상수 step으로 접힌다.

`findVPlanBackendObservedLoop`의 `ambiguous-observed-loop`가 첫 장애물이다.
수정 방향은 각 clone의 provenance와 mapping을 보존하고, clone별 관측이 동일함을
검증하거나 정확한 실행 횟수로 통합하는 것이다. 같은 width만으로 같은 spill 비용을
가정할 수 없고, 첫 clone만 선택해서도 안 된다. IR mapping 외에 machine observer와
결과 schema의 단일 loop 가정도 함께 다뤄야 한다.

대표 증거: [suffix IR](.cache/fallback-mapping-audit-414e8est/s176-f2/bench_kernel_2_0_0_f2_ic1_main-suffix.ll), [LoopInfo/SCEV](.cache/fallback-mapping-audit-414e8est/s176-f2/suffix-analysis.txt).

| Case | Fixed VF | Scalable VF | 구성 수 |
|---|---|---|---:|
| `s176` | `f2`, `f4` | `s1`, `s2` | 4 |

#### M2 — EVL loop의 중복 identity: 조건부 수정 후보 (4개)

`s118/s1,s2,s4,s8`에는 4개의 single-block inner loop가 같은 candidate marker를
공유한다. 각 loop에는 하나의 `get.vector.length`, 그 결과의 zext, 그 값만큼의
`index` 증가와 `avl` 감소가 남아 있다. 따라서 affine witness가 없다는 사실 자체가
실패 이유는 아니다. 현재 코드에도 이 EVL 대체 증명이 있으나, 중복 identity 검사에서
먼저 반환하므로 도달하지 못한다.

Clone별 local EVL 증명은 가능한 형태다. 다만 원본 inner trip count는 outer index에
따라 1..31로 달라지고, 마지막 vector 실행의 active lane 수도 다르다. Clone identity를
복구한 뒤 기존 EVL width 의미를 보존하면서 비용 동등성 또는 실행량 기반 통합을
증명해야 한다. 네 clone의 비용을 단순 평균하거나 nominal lane 수를 실제 scalar
실행량으로 간주하는 수정은 근거가 부족하다.

대표 증거: [suffix IR](.cache/fallback-mapping-audit-414e8est/s118-s1/bench_kernel_2_0_0_s1_ic1_main-suffix.ll), [LoopInfo/SCEV](.cache/fallback-mapping-audit-414e8est/s118-s1/suffix-analysis.txt).

| Case | Fixed VF | Scalable VF | 구성 수 |
|---|---|---|---:|
| `s118` | — | `s1`, `s2`, `s4`, `s8` | 4 |

#### M3 — suffix에서 candidate loop 소멸: region 확장 필요 (156개)

Materialization/pruning 직후에는 유일한 single-block candidate와 induction witness가
있지만, suffix 후에는 candidate loop marker와 witness가 모두 없다. 완전히 펼쳐진
vector 코드에서 원래 loop의 한 순환을 찾는 방식은 사용할 수 없다.

이 156개는 증거를 읽는 데 도움이 되도록 다음과 같이 더 나뉜다. 아래는 suffix IR의
형태이며, 남은 다른 loop를 원래 candidate loop로 바꿔 해석하지 않는다.

| Suffix 문맥 | 구성 수 | 해당 case / VF |
|---|---:|---|
| 함수에 conditional branch와 loop가 남지 않음 | 136 | 아래 M3 목록에서 다음 두 행의 case를 제외한 구성 |
| 다른 loop가 남음 | 14 | `s125/s1,s2,s4,s8`; `s176/f8,f16,f32,s4,s8,s16`; `s315/f16,f32,s8,s16` |
| Loop 없이 conditional branch 하나가 남음 | 6 | `s171/f8,f16,f32,s4,s8,s16` |

유한 region 관측을 새로 지원한다면, 변환 전후 candidate의 범위, 원래 scalar
실행량, 잔여 loop/분기 문맥 및 setup/exit와의 경계를 보존해 증명하는 방향이 가능하다.
하지만 현재 자료만으로 156개 모두의 region 비용 증명을 완료했다고 말할 수는 없다.
Unroll을 probe에서만 막으면 관측할 코드와 register allocation이 바뀌므로 현재 native
probe 정책을 보존하는 해결책이 아니다.

대표 증거: `s000/f8`의 [before IR](.cache/fallback-mapping-audit-414e8est/s000-f8/bench_kernel_2_0_0_f8_ic1_main-before.ll)와 [suffix IR](.cache/fallback-mapping-audit-414e8est/s000-f8/bench_kernel_2_0_0_f8_ic1_main-suffix.ll).

| Case | Fixed VF | Scalable VF | 구성 수 |
|---|---|---|---:|
| `s000` | `f8`, `f16`, `f32` | `s4`, `s8`, `s16` | 6 |
| `s1112` | `f16`, `f32` | `s8`, `s16` | 4 |
| `s124` | `f16`, `f32` | `s8`, `s16` | 4 |
| `s125` | — | `s1`, `s2`, `s4`, `s8` | 4 |
| `s1251` | `f32` | `s16` | 2 |
| `s127` | `f16`, `f32` | — | 2 |
| `s1281` | `f32` | `s16` | 2 |
| `s1351` | `f16`, `f32` | `s8`, `s16` | 4 |
| `s1421` | `f8`, `f16`, `f32` | `s4`, `s8`, `s16` | 6 |
| `s152` | `f16`, `f32` | `s8`, `s16` | 4 |
| `s171` | `f8`, `f16`, `f32` | `s4`, `s8`, `s16` | 6 |
| `s173` | `f8`, `f16`, `f32` | `s4`, `s8`, `s16` | 6 |
| `s176` | `f8`, `f16`, `f32` | `s4`, `s8`, `s16` | 6 |
| `s251` | `f16`, `f32` | `s8`, `s16` | 4 |
| `s293` | `f4`, `f8`, `f16`, `f32` | `s2`, `s4`, `s8`, `s16` | 8 |
| `s311` | `f8`, `f16`, `f32` | `s4`, `s8`, `s16` | 6 |
| `s313` | `f16`, `f32` | `s8`, `s16` | 4 |
| `s315` | `f16`, `f32` | `s8`, `s16` | 4 |
| `s331` | `f8`, `f16`, `f32` | `s4`, `s8`, `s16` | 6 |
| `s4121` | `f16`, `f32` | `s8`, `s16` | 4 |
| `s422` | `f16`, `f32` | `s8`, `s16` | 4 |
| `s431` | `f8`, `f16`, `f32` | `s4`, `s8`, `s16` | 6 |
| `s443` | `f16`, `f32` | `s8`, `s16` | 4 |
| `s452` | `f16`, `f32` | `s8`, `s16` | 4 |
| `s471` | `f16`, `f32` | `s8`, `s16` | 4 |
| `vbor` | — | `s4`, `s8` | 2 |
| `vdotr` | `f16`, `f32` | `s8`, `s16` | 4 |
| `vpv` | `f8`, `f16`, `f32` | `s4`, `s8`, `s16` | 6 |
| `vpvpv` | `f16`, `f32` | `s8`, `s16` | 4 |
| `vpvts` | `f8`, `f16`, `f32` | `s4`, `s8`, `s16` | 6 |
| `vpvtv` | `f16`, `f32` | `s8`, `s16` | 4 |
| `vsumr` | `f8`, `f16`, `f32` | `s4`, `s8`, `s16` | 6 |
| `vtv` | `f8`, `f16`, `f32` | `s4`, `s8`, `s16` | 6 |
| `vtvtv` | `f16`, `f32` | `s8`, `s16` | 4 |

#### M4 — 단일 vector 실행으로 materialize: region provenance 필요 (19개)

이미 `before`에서 vector body에 backedge가 없고 candidate loop marker/induction
witness도 없다. 이는 suffix가 witness를 지운 경우와 다르다. Vectorization 결과가
반복 loop가 아니라 한 번 실행하는 body로 나타나므로 `markVPlanBackendLoop`가
관측할 candidate loop를 얻지 못한다. 남아 있는 enclosing loop는 별개의 반복이다.

고정 크기/마스크가 있는 body도 실행량을 증명할 여지는 있으므로 «원리적으로 불가»로
분류하지 않는다. 다만 region identity를 materialization부터 전달하고 실제 유효 lane,
원본 trip count, enclosing-loop context를 연결하는 새로운 관측 표현이 필요하다.
특히 `s115/s16`, `s118/s16`, `s1232/s16,s32`의 4개는 원본 inner 실행량이 outer
index에 따라 변한다. 나머지 15개와 구분해 검토해야 한다. `s32`의 nominal 64 lanes를
실제 처리량으로 그대로 쓰거나 빈 loop 관측을 zero spill로 처리해서는 안 된다.

대표 증거: `s1115/s16` [before IR](.cache/fallback-mapping-audit-414e8est/s1115-s16/s1115_1_0_0_s16_ic1_main-before.ll), `s118/s16` [before IR](.cache/fallback-mapping-audit-414e8est/s118-s16/bench_kernel_2_0_0_s16_ic1_main-before.ll).

| Case | Fixed VF | Scalable VF | 구성 수 |
|---|---|---|---:|
| `s1115` | — | `s16`, `s32` | 2 |
| `s115` | — | `s16` | 1 |
| `s118` | — | `s16` | 1 |
| `s119` | — | `s16` | 1 |
| `s1232` | — | `s16`, `s32` | 2 |
| `s125` | — | `s16`, `s32` | 2 |
| `s2101` | — | `s16`, `s32` | 2 |
| `s2275` | — | `s16`, `s32` | 2 |
| `s231` | — | `s16`, `s32` | 2 |
| `s235` | — | `s16`, `s32` | 2 |
| `vbor` | — | `s16`, `s32` | 2 |

#### M5 — early-exit loop의 펼쳐진 경로: 현재 계약에서 유지할 fallback (3개)

`s332/s4,s8,s16`은 `before`에서 candidate가 2-block loop였으나 suffix 후에는
candidate loop가 없고 조건 분기 사슬이 남는다. 각각 40/20/10개의 conditional branch가
있고, `%index.lcssa`에는 어느 chunk에서 종료했는지에 따라 서로 다른 index가 들어온다.
원본은 `a[i] > t`에서 종료하므로 실행량은 입력 데이터에 의존한다.

고정 trip-count region처럼 모든 block의 spill을 합산한 뒤 하나의 상수 실행량으로
나누는 방식은 증명되지 않는다. 모든 경로의 비용/실행량 비율이 같다는 별도 증명,
경로별 결과 표현 또는 명시적인 다른 비용 정책 없이는 정확한 단일 값으로 합칠 수 없다.
이는 그런 확장이 영원히 불가능하다는 주장이 아니라 현재 profile-independent 단일
순환 모델의 범위 밖이라는 판정이다. 이 그룹은 clone identity 수정의 해결 대상으로
세지 않는다. 같은 source의 B 7개도 별도의 loop-shape 제약을 계속 가진다.

대표 증거: `s332/s4` [before IR](.cache/fallback-mapping-audit-414e8est/s332-s4/bench_kernel_2_0_0_s4_ic1_main-before.ll), [suffix IR](.cache/fallback-mapping-audit-414e8est/s332-s4/bench_kernel_2_0_0_s4_ic1_main-suffix.ll).

| Case | Fixed VF | Scalable VF | 구성 수 |
|---|---|---|---:|
| `s332` | — | `s4`, `s8`, `s16` | 3 |

실행 우선순위는 M1 → M2 → M3/M4의 별도 region 설계 → M5다. 진단 개선은
그보다 먼저 가능하다. `missing-observed-loop`와 `ambiguous-observed-loop`를
공통 mapping 오류로 뭉개지 않고 전달하면 이 구분을 다음 수집부터 직접 기록할 수 있다.
이 문서에서는 compiler 동작을 변경하지 않았다.

### B — machine-loop 형태 제약

진단: `only innermost single-block loops have a proven circular execution order`.
Mapping/width 검사와 candidate machine-loop 식별을 통과한 뒤,
innermost, single-block, latch=header 중 하나 이상의 조건을 만족하지 못한 구성이다.
이 공통 진단은 어떤 조건이 실패했는지까지 구분하지 않는다.

| Case | Fixed VF | Scalable VF | 구성 수 |
|---|---|---|---:|
| `s332` | `f2`, `f4`, `f8`, `f16`, `f32` | `s1`, `s2` | 7 |

## Region probe prototype 결과 (2026-11-04)

위 M1..M5는 수정 전 compiler의 원인 분류다. 이후 최소 구현으로
`-vplan-backend-region-probes`를 추가했고 기본값은 OFF로 유지했다.
구현 계약과 제한은 [BACKEND_FEEDBACK.md](BACKEND_FEEDBACK.md#experimental-region-probes),
사용법은 [README](README.md#probe-pruning)에 있다.

Disposable clone의 affine single-block vector loop에 `llvm.pseudoprobe` begin/end를
넣고 native suffix/backend를 실행한다. 기존 loop 관측이 구조적으로 실패하면 같은
post-StackSlotColoring 실행에서 모든 pair가 속한 **machine block 전체**의 vector spill을
수집한다. Pair count와 원래 materialized iteration width로 정규화한다.

초기 실험에서 marker 사이 명령만 수집하면 spill을 놓쳤다. 실제로 scheduling은
pseudo probe를 block 앞에 모았고, spill은 그 뒤에 남았다. 따라서 marker 위치는
명령 경계로 사용하지 않는다. 현재 prototype은 block 단위 근사 관측이며 같은 block의
setup/exit/합쳐진 작업도 포함할 수 있다. Hoist/sink로 block을 벗어난 작업은 추적하지 않는다.

193개 구성 모두 보존한 forced IR과 원래 opt argv로 OFF → ON 순서로 한 번씩 실행했다.
각 실행에 `-verify-each -verify-machineinstrs`를 켰으며 출력은 별도 cache에 보존했다.
이는 fallback 진단 비교이며 timing 측정이나 전체 dataset 재측정이 아니다.

| 원인 그룹 | 구성 수 | OFF fallback | ON region 관측 성공 | ON fallback |
|---|---:|---:|---:|---:|
| M1 — affine loop 복제 | 4 | 4 | 0 | 4 |
| M2 — EVL loop 복제 | 4 | 4 | 0 | 4 |
| M3 — suffix에서 loop 소멸 | 156 | 156 | 154 | 2 |
| M4 — materialization부터 loop 없음 | 19 | 19 | 0 | 19 |
| M5 — early-exit region | 3 | 3 | 0 | 3 |
| B — machine-loop 형태 제약 | 7 | 7 | 0 | 7 |
| 합계 | 193 | 193 | 154 | 39 |

- 성공 154개 모두 `scope=probe-region`, `region_granularity=machine-block`,
  `real_spill_used=true`, effective model `llvm-real-vector-spill-v1`이다.
  그중 91개는 실제 vector spill/reload access가 있으며 63개는 관측된 access가 없다.
- M3 중 남은 것은 `s125/s4,s8`이다. M1 4개와 함께 marker가 여러 machine block에
  흩어져 거절된다. 나머지 26개는 기존 mapping 실패, B 7개는 기존 shape 실패다.
- `s124/f16`은 20 pair, iteration width 320, vector spill/reload access 36개를
  관측했다. 근거: [feedback](.cache/fallback-region-block-probes-e5nwampe/s124-f16/on/feedback.jsonl).
- 193개 모두 selected VF/IC와 epilogue 설정은 유지되었고 최종 IR에 probe가 없다.
  189개는 OFF/ON bitcode bytes가 같다. `s125/s4,s8`, `s176/f32,s16` 4개는 debug
  `atomGroup` 번호만 달랐으며 disassembler ModuleID와 이 번호를 정규화하면 모두 같다.
- 이 성공 수는 fallback 복구 수다. 원래 표의 함수 전체 assembly GT와 같은 범위의
  정확도나 최종 binary spill 예측 정확도를 입증한 수치로 해석하지 않는다.
- 실험 opt SHA256: `7e0c05302a6d1d74055f8242464ec69e02bb7e3a78904e2f05e30cfbaaaaf96e`.
  기존 checkout 위의 working-tree 수정으로 빌드했으며 변경 내용은 아래 cache의
  `source.diff`에 보존했다. 원본 compiler hash와 구분한다.
- [실행 manifest](.cache/fallback-region-block-probes-e5nwampe/manifest.json),
  [별도 raw feedback 검증 집계](.cache/fallback-region-block-probes-e5nwampe/verification.json),
  [재현 driver](.cache/fallback-region-block-probes-e5nwampe/replay.py).
  각 case/VF 디렉터리의 `off/`, `on/`에 command, feedback, opt stderr와 optimized IR이 있다.

회귀 검증은 새 focused check(fully-unrolled nonzero-spill 복구, disjoint clone 거절),
기존 backend 관련 lit 11개와 StackSlotColoring lit 1개, VectorizeTests 105개,
RISCVTests 51개, PassManager/LegacyPassManager 7개가 통과했다.
새 테스트는 사용자 승인 후 추가했다.

## Vectorization 직후 삽입 확장 결과 (2026-11-04)

위 첫 prototype 결과를 보존하고, VPlan의 single-block/single-exit vector body
identity를 backedge 제거 전에 보관하도록 확장했다. 삽입 자체는 VPlan 실행과
`fixVectorizedLoop` 직후다. 이때 Loop가 없어도 emitted body에 begin/end를 넣는다.
Surviving affine loop 경로와 backend region collector는 동일하다.

같은 193개 구성을 OFF → ON으로 재실행했다. 복구는 **154 → 172개
(79.8% → 89.1%)**, fallback은 **39 → 21개**다. 이전 성공의 regression은 없다.

| 원인 그룹 | 구성 수 | 이전 복구 | 이번 복구 | 이번 fallback |
|---|---:|---:|---:|---:|
| M1 — affine loop 복제 | 4 | 0 | 0 | 4 |
| M2 — EVL loop 복제 | 4 | 0 | 0 | 4 |
| M3 — suffix에서 loop 소멸 | 156 | 154 | 154 | 2 |
| M4 — materialization부터 loop 없음 | 19 | 0 | 18 | 1 |
| M5 — early-exit region | 3 | 0 | 0 | 3 |
| B — machine-loop 형태 제약 | 7 | 0 | 0 | 7 |
| 합계 | 193 | 154 | 172 | 21 |

추가 복구 18개: `s1115/s16,s32`, `s115/s16`, `s119/s16`,
`s1232/s16,s32`, `s125/s16,s32`, `s2101/s16,s32`, `s2275/s16,s32`,
`s231/s16,s32`, `s235/s16,s32`, `vbor/s16,s32`.
M4의 `s118/s16`에도 이제 marker가 삽입되지만, 여러 machine block에 흩어져 거절된다.

남은 21개는 다음과 같다.

| 현재 실패 이유 | Case/VF | 수 |
|---|---|---:|
| Marker가 여러 machine block에 분산 | `s118/s16`; `s125/s4,s8`; `s176/f2,f4,s1,s2` | 7 |
| Surviving EVL loop mapping 미증명 | `s118/s1,s2,s4,s8` | 4 |
| Early-exit mapping 미증명 | `s332/s4,s8,s16` | 3 |
| Machine-loop 형태 제약 | `s332/f2,f4,f8,f16,f32,s1,s2` | 7 |

172개 모두 실제 region 관측을 사용한다. 101개는 vector spill/reload access가 있고,
71개는 관측된 access가 없다. 정규화는 기존과 같은 **nominal VF × IC × pair count**다.
Masked/EVL body의 실제 active scalar lane 수를 입증한 값은 아니다.
`s125/s16,s32`는 suffix 후 각각 8 pair로, nominal 폭 256/512다.
관측은 여전히 machine-block 전체의 근사 scope이며 binary 정확도 검증 수치가 아니다.

193개 모두 `-verify-each -verify-machineinstrs`를 통과했다. Raw feedback을 별도로
검증하여 selected VF/IC 및 epilogue 설정 유지, 최종 IR에 marker 없음도 확인했다.
187개는 bitcode bytes가 같고, 나머지 6개(`s125/s4,s8,s16,s32`, `s176/f32,s16`)는
ModuleID와 debug `atomGroup` 번호를 정규화하면 같다. 새로운 backedge-free body를
추가한 승인된 focused lit 1개, 기존 backend lit 11개, VectorizeTests 105개가 통과했다.
전체 dataset/timing 측정은 실행하지 않았다.

- opt SHA256: `b5818ddf28021e167df56713afa769a81605b19b96a12dd9b7f14b7f550e60ab`.
- [실행 manifest](.cache/fallback-post-vector-probes-ez7g9odd/manifest.json),
  [raw feedback/IR 독립 검증](.cache/fallback-post-vector-probes-ez7g9odd/verification.json),
  [검증 script](.cache/fallback-post-vector-probes-ez7g9odd/verify.py),
  [재현 driver](.cache/fallback-post-vector-probes-ez7g9odd/replay.py).
  각 구성의 `off/`, `on/`에 command, feedback, stderr, optimized bitcode를 보존했다.

## Marker 관측과 assembly 교차 검증 (2026-11-04)

사용자 요청에 따라 별도 subagent가 복구된 172개 전부를 검증하고, main agent가
raw feedback, 관측된 machine block, assembly를 독립적으로 다시 집계했다.
Sequential/multi-block 지원은 추가하지 않았다. 현재 소스로 clang/llc를 재링크했고,
각 구성에서 같은 후보의 probe suffix를 저장하여 standalone llc assembly를 생성했다.
최종 selected assembly는 보존한 optimized bitcode에서 관측 대상 함수를 추출한 후
원래 실험의 clang target/codegen 옵션으로 생성했다. Timing 측정은 하지 않았다.

| 비교 대상 | 방향·register group별 access 수 일치 | 불일치 |
|---|---:|---:|
| Report ↔ 실제 in-process 관측 machine block | 172/172 | 0 |
| Report ↔ standalone probe의 같은 관측 시점 marked block | 165/172 | 7 |
| Report ↔ standalone probe 함수 전체 assembly | 162/172 | 10 |
| Report ↔ 최종 selected 함수 전체 assembly | 149/172 | 23 |

모든 report의 4,808개 access는 whole-register vector spill/reload이며 segment
분해 case는 없었다. 방향과 register group별로 집계했으며 scalar spill, 일반 vector
load/store는 제외했다. Standalone probe 함수 전체 assembly는 4,869개, selected 함수
전체 assembly는 5,155개다. 이 합계는 **정적 instruction 수**로, loop 실행 빈도나
iteration width로 가중한 비용 비교가 아니다. Marked block과 함수 전체는 scope가 다르므로
차이 전체를 counting 버그로 해석해서는 안 된다. 반대로 최종 assembly와 같다고도 할 수 없다.

Selected assembly와 다른 23개:

| Case | VF | Report access → selected assembly access |
|---|---|---|
| `s1115` | `s32` | 37 → 33 |
| `s1232` | `s32` | 3 → 6 |
| `s1421` | `f8,s4`; `f16,s8`; `f32,s16` | 0 → 16; 0 → 12; 0 → 18 |
| `s171` | `f8,s4`; `f16,s8`; `f32,s16` | 0 → 54; 0 → 30; 24 → 36 |
| `s176` | `f8`; `f16`; `f32`; `s4`; `s8`; `s16` | 22 → 34; 16 → 28; 26 → 34; 26 → 38; 16 → 30; 26 → 34 |
| `s2275` | `s32` | 8 → 2 |
| `s422` | `f16,s8` | 30 → 32 |

직접 확인한 scope 차이: `s1232/s32`의 marked block에는 reload 3개가 있고,
spill store 3개는 unmarked entry block에 있다. `s176/f8,s4`도 in-process 함수 전체
access 수가 marked block보다 이미 크다. 한편 standalone lowering이 관측 시점부터
다른 7개는 late backend pass의 영향이라고 단정할 수 없다.

`s1421/f8`은 scope 차이만으로 설명되지 않는 probe CFG 차이도 확인했다.
원래 probe assembly는 0 access이고 selected assembly는 16개다. Probe에서 marker만
제거하면 여전히 0개지만, 제거 후 `simplifycfg`를 적용하면 16개가 되어 selected와 같다.
Codegen driver/옵션을 바꿔도 원래 probe/selected의 0/16 차이는 유지된다.
이는 probe IR의 block 경계가 scheduling/RA 결과에 영향을 줄 수 있다는 구체적 증거다.
`s171/f8`도 driver 교체 후 0/54 차이를 유지하지만 같은 단순화로 해결되지는 않았고,
pruning/주변 CFG 차이가 있어 원인을 완전히 분리하지 못했다.
[추가 진단](.cache/marker-assembly-verification-48skagfz/simplifycfg-check.json)을 보존했다.

Spill 유무만 비교하면 101개는 양쪽 모두 nonzero, 61개는 양쪽 모두 zero다.
**10개는 report가 zero지만 selected 함수 assembly에는 vector spill이 있다**
(`s1421` 6개, `s171/f8,f16,s4,s8` 4개). 따라서 172개 복구는 관측 가능 범위이며,
172개 모두 최종 assembly의 spill을 정확히 예측한다는 의미가 아니다.

- [실행/집계 script](.cache/marker-assembly-verification-48skagfz/audit.py),
  [전체 비교 결과](.cache/marker-assembly-verification-48skagfz/results.json),
  [binary hash와 요약](.cache/marker-assembly-verification-48skagfz/summary.json).
- [main agent 독립 재집계](.cache/marker-assembly-verification-48skagfz/independent-check.json),
  [독립 script](.cache/marker-assembly-verification-48skagfz/independent_check.py).
- 각 case/VF에 실행 command, `observed-block.txt`, `probe.ll`, `probe.s`,
  `selected.s`, diagnostics와 feedback을 보존했다.

## 구조적 eligibility 축소 결과 (2026-11-04)

사용자가 요청한 narrowing은 benchmark 이름이나 최종 assembly 정답을 참조하지 않는다.
명확한 거절 신호는 **IR suffix 후 marked block 밖에 실행 작업이 남는 경우**다.
`s1421/f8`의 별도 entry store는 CFG/codegen 차이의 사례이고,
`s1232/s32`의 별도 작업은 spill scope/실행 빈도 차이의 사례다.

구현한 조건:

1. IR suffix에서 해당 candidate의 모든 probe가 하나의 IR block에 있어야 한다.
2. 나머지 IR block에는 debug intrinsic과 unconditional branch만 허용한다.
   따라서 빈 entry/trampoline은 허용하지만 계산, load/store, phi, conditional branch,
   별도 return block 등은 보수적으로 거절한다.
3. Backend에서 marked machine block 밖에 vector spill/reload가 있으면 거절한다.
   다른 block의 access를 합치거나 marked body의 빈도로 정규화하지 않는다.

IR 조건은 `vplan.backend.region-isolated`로 전달한다. 기존 loop 관측 성공 경로는
그대로이며 이 제한은 marker fallback 경로에만 적용한다. Region 검증 실패는 기존
whole-loop fallback을 따른다. 옵션은 여전히 기본 OFF이고 post-frame 재시도는 없다.
이 조건은 지원 범위를 보수적으로 줄이며 marker가 codegen에 영향을 주지 않는다는
일반적인 증명은 아니다.

별도 subagent가 193개 OFF → ON 진단과 살아남은 132개의 assembly 검증을 새로
실행했다. Main agent는 raw feedback/IR/관측 block/assembly를 다시 독립 집계했다.

| 지표 | 축소 전 | 축소 후 |
|---|---:|---:|
| Region 관측 성공 | 172/193 (89.1%) | 132/193 (68.4%) |
| Fallback | 21 | 61 |
| 최종 함수 assembly와 방향·register group별 static access 수 일치 | 149/172 | 130/132 |
| 최종 assembly와 불일치 | 23 | 2 |
| Report zero / 최종 assembly nonzero | 10 | 0 |

새 거절 40개는 전부 `region probe has executable IR outside its single marked block`
진단이며, 이 표본에서 backend의 outside-spill check가 추가로 거절한 경우는 없다.
기존 fallback 21개는 이유까지 동일하다. 새 거절은 이전 불일치 21개와 이전 일치 19개를
함께 제외한 결과다. 단순히 function에 block이 둘 이상이라는 조건은 사용하지 않았다.

| 원인 그룹 | 이번 성공 | 이번 fallback |
|---|---:|---:|
| M1 | 0 | 4 |
| M2 | 0 | 4 |
| M3 | 119 | 37 |
| M4 | 13 | 6 |
| M5 | 0 | 3 |
| B | 0 | 7 |
| 합계 | 132 | 61 |

132개 모두 report와 실제 관측 marked block의 access가 일치한다.
Report는 총 4,267개, selected/probe 함수 assembly는 각각 4,257개다.
84개는 양쪽 모두 nonzero이며 48개는 양쪽 모두 zero다. 남은 두 차이는 다음과 같다.

| 구성 | Report | 최종 assembly |
|---|---:|---:|
| `s1115/s32` | 37 | 33 |
| `s2275/s32` | 8 | 2 |

두 경우는 이미 함수 전체가 single block이라 새 isolation 조건에 걸리지 않는다.
Standalone lowering과 in-process 관측이 관측 시점부터 다르며 원인은 미해결이다.
별도의 근거 없는 scalable VF 제한이나 case별 예외를 넣지 않았다.
130개의 일치는 static signature 비교이며 dynamic execution/active-lane 정규화까지
증명한 값은 아니다.

193개 모두 `-verify-each -verify-machineinstrs` 통과, selected VF/IC/epilogue 유지,
최종 IR에 probe 없음, debug identifier 정규화 후 OFF/ON IR 동일을 확인했다.
기존 lit 13개, VectorizeTests 105개, RISCVTests 51개도 통과했다.
사용자 선택에 따라 새 테스트를 추가하거나 기존 테스트를 수정하지 않았다.

- opt SHA256: `a734e2502f301768f487a729c5ffe52797e89d6409d1efb920cc93a65649a79c`.
- [193개 새 실행 manifest](.cache/fallback-narrow-region-probes-aocubimy/manifest.json),
  [main 독립 검증](.cache/fallback-narrow-region-probes-aocubimy/parent-verification.json),
  [새 거절 40개 목록](.cache/fallback-narrow-region-probes-aocubimy/parent-eligibility-delta.json).
- [132개 assembly 결과](.cache/marker-narrow-assembly-osp20l2d/results.json),
  [binary hash와 요약](.cache/marker-narrow-assembly-osp20l2d/summary.json),
  [main assembly 독립 검증](.cache/marker-narrow-assembly-osp20l2d/independent-check.json).

## Spill/MIR 공통 region 분석과 전체 TSVC 결과 (2026-11-04)

요청한 흐름으로 refactor했다. 옵션 ON일 때 모든 materialized disposable candidate에
marker를 먼저 삽입하고, spill/MIR observer가 공통 `findObservedRegion`으로 loop를 먼저
찾은 뒤 구조적 실패 시 marker region을 찾는다. 공통 `collectBody`가 선택한 범위를
순회하여 spill access 또는 MIR list를 만든다. Scalar baseline도 같은 삽입/분석 경로를
쓰며 원본의 block 수를 미리 제한하지 않는다. 최종 scope 판정은 suffix/backend 뒤에 한다.

옵션 `-vplan-backend-region-probes`의 기존 default OFF는 유지했다. 본 실험에서는
명시적으로 OFF/ON을 비교했다. 최종 출력용 vectorization에는 marker를 삽입하지 않는다.
Spill 관측 지점은 post-StackSlotColoring, MIR은 post-frame-lowering을 유지하며 각각
region을 독립 선택한다. Metadata/probe, function return, frame setup/destroy는 양쪽
body 순회에서 제외한다. Marker 경로는 기존 IR 격리 조건에 더해 다른 machine block의
모든 executable body work를 거절하므로 scalar spill/MIR 명령도 빠뜨리지 않는다.
가격식, sheet, scalar baseline, nominal width/rational 정규화 정책은 유지했다.

### 전체 suite 범위와 재현

현재 TSVC source inventory **151개**의 source hash를 대조하고 현재 compiler로
natural candidate census를 다시 생성했다. **93개 source에 787개 case×VF 구성**이
있으며 58개는 natural vector candidate가 없다. `s2710`의 10개 VF에는 대상 loop가
둘씩 있어 loop denominator는 **797개**다. 기존 193개 fallback만 재실행한 결과가 아니다.

Kunminghu/VLEN128, IC1, vector epilogue OFF, LMUL8, default TTI, real spill 정책으로
동일 natural geometry를 강제했다. Spill 및 pure-MIR 요청 각각 marker OFF → ON을
3회 반복했다. Force-all은 gate 결정을 보존하면서 관측을 요구하는 진단 옵션이다.
한 번에 compiler 하나, command별 timeout 300초를 사용했다. **9,444 optimizer 실행**과
assembly generation은 모두 성공했다. Timing/speedup 또는 전체 313-input dataset 측정은 아니다.

### Coverage

| 요청 model | OFF 성공 구성 | ON 성공 구성 | ON 추가 복구 | ON fallback |
|---|---:|---:|---:|---:|
| Real vector spill | 594/787 (75.5%) | 726/787 (92.2%) | 132 | 61 |
| Pure MIR | 397/787 (50.4%) | 512/787 (65.1%) | 115 | 275 |

Loop 기준 spill은 604 → 736/797, MIR은 397 → 512/797이다.
기존 성공 구성 손실은 없다. MIR의 275개 fallback 중 214개는 real-spill model로
관측을 유지하고 61개는 estimated 경로로 간다. 따라서 MIR 요청의 실제 관측 사용은
512 MIR + 214 spill = 726개지만 **MIR coverage에는 512개만** 센다.

Source별 최소 한 구성의 model 성공은 spill 89/93, MIR 65/93으로 OFF/ON 동일하다.
모든 natural VF가 model 성공인 source는 spill 49 → 80/93, MIR 29 → 57/93이다.
Scalar baseline MIR 성공은 OFF/ON 모두 562/797이다. 이번 TSVC의 MIR 증가 115개는
vector marker region 복구이며 scalar marker 복구를 관측한 사례는 없다.

### 관측 충실도와 assembly 비교

Subagent가 actual observer dump와 직접 대조하고 main agent가 raw reports/assembly를
독립 집계했다. **5,406/5,406 성공 payload**가 해당 candidate/stage/block과 일치한다.
각 payload의 context와 matching block은 정확히 하나였다.

- Spill payload 3,373개, vector access 9,234개.
- Ordered MIR list 2,033개, instruction 131,370개. 목록 전체의 순서와 내용을 대조했다.
- 위 수는 OFF/ON과 MIR 실패 시 보존된 independently valid 관측도 포함한다.
  Coverage 구성 수나 실행 instruction frequency와 혼동하지 않는다.

최종 선택 함수의 assembly와는 **방향·physical register group별 정적 vector
spill/reload access signature**를 비교했다. 여러 대상 loop가 있는 함수는 보고된
main observation들을 합쳤다. Scalar frame overhead, runtime frequency, latency/cycle
정확도 또는 모든 MIR opcode의 최종 assembly 1:1 대응을 검증한 값은 아니다.
Fallback을 zero로 간주하지 않고 성공 관측 구성만 아래 accuracy denominator에 포함했다.

| Model | OFF exact signature | ON exact signature | ON TP / FP / FN / TN |
|---|---:|---:|---:|
| Spill | 589/594 (99.2%) | 719/726 (99.0%) | 110 / 0 / 0 / 616 |
| MIR의 vector spill | 397/397 (100%) | 510/512 (99.6%) | 84 / 0 / 0 / 428 |

TP/FP/FN/TN은 vector spill **유무** 비교다. 성공 관측 중 유무 불일치는 없지만
정확한 access 수는 다를 수 있다. Marker 경로만 보면 spill 130/132, MIR 113/115가
exact signature 일치다. Normal loop 경로의 signature는 OFF/ON에서 변하지 않았다.

남은 marker 불일치는 양쪽 model에서 동일하다:

| 구성 | Report access | Final assembly access |
|---|---:|---:|
| `s1115/s32` | 37 | 33 |
| `s2275/s32` | 8 | 2 |

Spill의 나머지 5개 불일치는 이미 OFF에서도 있는 loop 관측이다:
`s276/f16,s8,s16`, `s442/f32,s16`. Loop body와 함수 전체 scope 및 backend stage 차이가
있으므로 이를 marker counting 오류라고 단정하지 않는다. MIR list extraction의 100%
일치도 최종 codegen 동일성이나 비용 정확도의 증명은 아니다.

3회 반복은 3,148개 mode-configuration 모두 coverage/선택 및 complete observation
facts가 동일했다. Ordered MIR body는 diagnostic text를 제외한 사실 전체를 비교했다.
Compiler hash도 전 구간 동일했다. 최종 backend 관련 lit 13개, VectorizeTests 105개,
RISCVTests 51개가 통과했다. 테스트는 추가/수정하지 않았다.

### Artifact

- opt SHA256: `0cda9c59482f67bd60e574baf51a49c04ec5ad9c2ea8c509d4b0d9c5125ee0db`.
- [전체 manifest](.cache/tsvc-unified-region-final-u9_tdguc/manifest.json),
  [coverage/accuracy summary](.cache/tsvc-unified-region-final-u9_tdguc/summary.json),
  [151-source inventory 검증](.cache/tsvc-unified-region-final-u9_tdguc/inventory-verification.json).
- [observer audit](.cache/tsvc-unified-region-final-u9_tdguc/observer-summary.json),
  [3회 반복 검증](.cache/tsvc-unified-region-final-u9_tdguc/repetition-verification.json),
  [main 독립 coverage/assembly 집계](.cache/tsvc-unified-region-final-u9_tdguc/parent-verification.json),
  [main 독립 payload 집계](.cache/tsvc-unified-region-final-u9_tdguc/parent-payload-counts.json).
- 같은 cache에 source diff, compiler/source hash, 실행 script, 모든 command와
  case/model/OFF-ON/rep별 feedback, observer dump, optimized bitcode와 assembly가 있다.
  이전 41개 partial run은 superseded로 보존하며 위 집계에는 포함하지 않았다.

## 기본 ON 전환 (2026-11-04)

사용자 요청으로 `-vplan-backend-region-probes` 기본값을 ON으로 변경했다.
Backend feedback probe에서 적용되며 비교용 `=false` override는 유지한다.
위 전체 TSVC 수치는 명시적 OFF/ON 비교의 역사적 결과이고, 기본값 변경 뒤에 전체
suite를 다시 실행한 수치는 아니다. 현재 기본 경로는 그중 ON 동작을 사용한다.

사용자가 불필요하다고 한 기존 테스트 중 loop 소멸을 반드시 fallback으로 기대하던
두 부분만 제거했다. 새 테스트는 추가하지 않았다. 기존 backend 관련 lit 13개가
통과했고, 기존 IR 입력으로 spill/MIR 각각 기본값과 명시적 ON의 출력 IR/feedback이
같으며 marker region이 관측되는 것을 확인했다.

- [기본값 검증](.cache/region-probes-default-on-ygnuccwe/verification.json)
- 현재 opt SHA256: `1c322ff699b0e882223fedb5e4a09917777139808ab517c516d9c2be48118435`.

## 수정 시작 지점과 판정 범위

- M: [finalizeVPlanBackendIterationMapping](llvm/lib/Transforms/Vectorize/VPlanBackendFeedback.cpp#L262)과
  [collectBody의 iteration-mapping/width 검사](llvm/lib/Target/RISCV/RISCVVPlanSpill.cpp#L180).
  관측기의 원본 scalar iteration 대응 검사가 실패했다는 뜻이다. 로그만으로 모든
  실패의 세부 원인이 같다고 단정하지 않으며, mapping 생산 단계부터 확인한다.
- B: [collectBody의 innermost/single-block/latch 검사](llvm/lib/Target/RISCV/RISCVVPlanSpill.cpp#L193).
  이 목록에서는 `s332`의 7개 VF다.
- Fallback 기록: [VPlanBackendCostModel::commit](llvm/lib/Transforms/Vectorize/VPlanBackendCostModel.cpp#L944).
  수정 후 `feedback.jsonl`의 `attempts`, `effective_model`, `spill_observation.status`,
  `iteration_mapping`, `iteration_width`, `real_spill_used`를 함께 확인한다.
  Failure를 빈 spill 목록의 성공으로 바꾸거나 관측 실패 검사를 무조건 통과시키지 않는다.

표의 pred는 fallback에서 실제 사용된 기본 추정이고, GT는 최종 계산 함수 전체의
vector `Spill`/`Reload` 명령 유무다. 완전히 unroll된 코드와 setup/exit도 포함하며
scalar callee-save는 제외한다. 따라서 **분류 오류와 관측 실패는 별개**다.
TP/TN도 관측에 실패했으므로 수정 대상에 포함했다.

## 공통 컴파일 설정

아래 플래그는 193개 구성의 원본 `record.json`과 대조했다. VF 종류/값 및
입출력 경로 이외의 opt/backend 플래그는 동일하다. Case 전용 추가 플래그는 없다.
입력은 `small`, `LEN_1D=320`, `LEN_2D=32`, dtype `float`다.

### 타깃 및 frontend

```text
-std=gnu11 -O3
--target=riscv64-unknown-elf
-march=rv64gcv_zba_zbb_zbc_zbs_zfh_zvfh_zvbb_zvl128b
-mcpu=xiangshan-kunminghu -mabi=lp64d -mcmodel=medany -mno-relax
-mrvv-vector-bits=128
-DBENCH_NO_MAIN -DBENCH_LOOP_SIZE_BIG=0 -DBENCH_FULL=0
-gline-tables-only -fno-discard-value-names
--sysroot=/work/loop-benchmarks/.deps/xpack-riscv-none-elf-15.2.0-1/riscv-none-elf
-isystem /work/loop-benchmarks/.deps/xpack-riscv-none-elf-15.2.0-1/riscv-none-elf/include
-mllvm -riscv-v-register-bit-width-lmul=8
-mllvm -force-vector-interleave=1
-mllvm -enable-epilogue-vectorization=false
-mllvm -vplan-backend=true
-mllvm -use-default-tti=true
-mllvm -use-mir=false
-mllvm -use-estimated-spill=true
-fno-lto -Xclang -disable-llvm-passes -emit-llvm -c
```

Frontend은 자연 후보 수집 시 설정을 재사용해서 raw IR만 생성하므로 여기에는
`-use-estimated-spill=true`가 기록되어 있다. **실제 분석의 real-spill 요청은 아래
opt 단계의 `-use-estimated-spill=false`**다. 이 둘을 바꿔 적지 않았다.
원래 frontend 명령에는 `-DBENCH_NO_MAIN`이 두 번 있으며 위에는 한 번만 표시했다.

수집은 원본 `.c` 파일을 단독으로 clang에 넘기는 방식이 아니다. Benchmark 도구가
fixture/driver 문맥과 size 설정을 반영한 translation unit을 생성했다.
실제 frontend 입력은 다음 snapshot이며, 원본 benchmark 소스 경로는 아래 표에 있다.

```text
RAW=/work/llvm-integration-ablation/.cache/llvm-spill-errors-20261104/tsvc-candidates
$RAW/natural/metadata/sources/tsvc__<case>.c
```

Frontend 이후 `llvm-extract --func=bench_kernel --recursive --keep-const-init`로
raw kernel closure를 추출했다. 이어 자연 후보 source 위치와 일치하는 raw loop에
`llvm.loop.vectorize.enable=true` metadata를 추가한 `forced.ll`을 opt 입력으로 썼다.
**명령줄의 force-vector-width만 재현하면 이 metadata 조건이 빠진다.**
기존 explicit-disable/already-vectorized loop는 보존했고, 변경 전후 값은 각 case의
`record.json`에 `force_enable_metadata`로 남아 있다.

### 최적화 및 real-spill 요청 (`opt`)

```text
-passes=default<O3>
-codegen-opt-level=3
-riscv-v-register-bit-width-lmul=8
-force-vector-interleave=1
-enable-epilogue-vectorization=false
-vplan-backend=true
-use-default-tti=true
-use-mir=false
-print-detailed-vplans
-hints-allow-reordering=false
-use-estimated-spill=false
-vplan-backend-force-all=true
-vplan-backend-jsonl=<새 출력 디렉터리>/feedback.jsonl
```

| 표의 VF | 추가 opt 플래그 |
|---|---|
| `fN` (fixed) | `-force-vector-width=N -scalable-vectorization=off` |
| `sN` (scalable) | `'-force-vector-width=vscale x N'` — 전체를 한 argv로 전달 |

모두 IC=1, vector epilogue OFF, 최대 LMUL=8이다. `force-all`은 관측 시도를 위한
설정이며 iteration mapping/loop-shape 유효성 검사를 없애지 않는다.
Scalable의 N은 LLVM ElementCount의 known-min 값이다. VLEN=128에서 nominal lane은
2×N이지만, 재현 명령에는 표에 기록된 N을 그대로 사용한다.

### 최종 assembly 생성 (`clang`)

위 타깃 플래그와 `-O3 -DBENCH_NO_MAIN -DBENCH_LOOP_SIZE_BIG=0
-gline-tables-only -fno-discard-value-names`를 사용한다. 공통 `-mllvm` 옵션은
LMUL=8, IC=1, epilogue OFF, master ON, default-TTI ON, MIR OFF이며,
`-mllvm -use-estimated-spill=false`다. 나머지 backend 전용 플래그는 다음과 같다.

```text
-Wno-unused-command-line-argument -x ir -S
-Xclang -disable-llvm-passes -fno-lto
```

Opt가 생성한 `optimized.bc`에서 다시 recursive `bench_kernel` closure를 추출한
`kernel.bc`를 입력한다. 최종 backend에서 IR 최적화를 다시 실행하지 않는다.
모든 원본 argv는 각 행의 `record` 링크에 보존되어 있다.

## 한 구성 재현: 보존한 forced IR로 현재 compiler 실행

아래 코드는 Bash에서 실행한다. 기본 예시는 M/FN인 `s124/f16`이며,
`fallback_case`, `fallback_tag`만 아래 목록의 값으로 바꾸면 된다.
새 `.cache/` 디렉터리에 출력을 만들고 역사적 자료를 덮어쓰지 않는다.
원본 목록 작성 때에는 재컴파일하지 않았다. 이후 M 세분류 조사에서는 위에 기록한
opt 진단 실행만 수행했다.

```bash
fallback_case=s124
fallback_tag=f16
python3 - "$fallback_case" "$fallback_tag" <<'PY_REPLAY'
import json, shlex, subprocess, sys, tempfile
from pathlib import Path
repo = Path('/work/llvm-integration-ablation')
raw = repo / '.cache/llvm-spill-errors-20261104/tsvc-candidates'
case, tag = sys.argv[1:]
old = raw / 'cases' / ('tsvc__' + case) / tag / 'llvm-real-spill'
record = json.loads((old / 'record.json').read_text())
new = Path(tempfile.mkdtemp(prefix=f'fallback-{case}-{tag}-', dir=repo / '.cache'))
print('Output:', new, flush=True)
for stage in record['stages']:
    # Only variant output/input paths change. The retained forced.ll stays input.
    command = [arg.replace(str(old) + '/', str(new) + '/') for arg in stage['command']]
    print(shlex.join(command), flush=True)
    with (new / Path(stage['stdout']).name).open('w') as stdout:
        with (new / Path(stage['stderr']).name).open('w') as stderr:
            subprocess.run(command, cwd='/work/loop-benchmarks', stdout=stdout,
                           stderr=stderr, check=True)
print('Inspect:', new / 'feedback.jsonl')
PY_REPLAY
```

Source부터 다시 수집하려면 다음처럼 기존 collector를 사용할 수 있다.
이 명령은 지정 case의 자연 후보 census 후 지정 VF의 **두 모델**을 수집한다.
출력 경로는 새 경로로 지정한다. Compiler 수정으로 자연 후보 목록이 바뀐 경우에는
위의 retained `forced.ll` 재현과 결과를 구분한다.

```sh
python3 /work/writing/llvm-spill-errors/collect_candidates.py \
  --workspace /work --case tsvc/s124 --vf f16 \
  --out /work/llvm-integration-ablation/.cache/fallback-s124-f16-from-source
```

## 전체 fallback 목록

`source:line:column`은 원본 source loop 위치다. 함수는 최종 계산 코드에 남은 함수이며,
inline 전의 원래 함수와 다를 수 있다. `record`에는 정확한 stage argv가,
`feedback`에는 fallback attempts와 실패 사유가 있다. 같은 디렉터리의 `final.s`,
`kernel.ll`, `opt.stderr`에서 최종 코드와 register report를 확인할 수 있다.


### M: iteration mapping 미증명 — 186개 구성

| Case / VF | 원본 source:line:column | 최종 함수 | Pred | GT | 분류 | 근거 |
|---|---|---|---|---|---|---|
| `s000/f8` | [benchmarks/tsvc/s000.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s000.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s000/f8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s000/f8/llvm-real-spill/feedback.jsonl) |
| `s000/f16` | [benchmarks/tsvc/s000.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s000.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s000/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s000/f16/llvm-real-spill/feedback.jsonl) |
| `s000/f32` | [benchmarks/tsvc/s000.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s000.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s000/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s000/f32/llvm-real-spill/feedback.jsonl) |
| `s000/s4` | [benchmarks/tsvc/s000.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s000.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s000/s4/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s000/s4/llvm-real-spill/feedback.jsonl) |
| `s000/s8` | [benchmarks/tsvc/s000.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s000.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s000/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s000/s8/llvm-real-spill/feedback.jsonl) |
| `s000/s16` | [benchmarks/tsvc/s000.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s000.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s000/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s000/s16/llvm-real-spill/feedback.jsonl) |
| `s1112/f16` | [benchmarks/tsvc/s1112.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s1112.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1112/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1112/f16/llvm-real-spill/feedback.jsonl) |
| `s1112/f32` | [benchmarks/tsvc/s1112.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s1112.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1112/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1112/f32/llvm-real-spill/feedback.jsonl) |
| `s1112/s8` | [benchmarks/tsvc/s1112.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s1112.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1112/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1112/s8/llvm-real-spill/feedback.jsonl) |
| `s1112/s16` | [benchmarks/tsvc/s1112.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s1112.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1112/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1112/s16/llvm-real-spill/feedback.jsonl) |
| `s1115/s16` | [benchmarks/tsvc/s1115.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s1115.c:37) | `s1115` | T | F | FP | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1115/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1115/s16/llvm-real-spill/feedback.jsonl) |
| `s1115/s32` | [benchmarks/tsvc/s1115.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s1115.c:37) | `s1115` | T | T | TP | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1115/s32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1115/s32/llvm-real-spill/feedback.jsonl) |
| `s115/s16` | [benchmarks/tsvc/s115.c:38:13](/work/loop-benchmarks/benchmarks/tsvc/s115.c:38) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s115/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s115/s16/llvm-real-spill/feedback.jsonl) |
| `s118/s1` | [benchmarks/tsvc/s118.c:38:13](/work/loop-benchmarks/benchmarks/tsvc/s118.c:38) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s118/s1/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s118/s1/llvm-real-spill/feedback.jsonl) |
| `s118/s2` | [benchmarks/tsvc/s118.c:38:13](/work/loop-benchmarks/benchmarks/tsvc/s118.c:38) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s118/s2/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s118/s2/llvm-real-spill/feedback.jsonl) |
| `s118/s4` | [benchmarks/tsvc/s118.c:38:13](/work/loop-benchmarks/benchmarks/tsvc/s118.c:38) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s118/s4/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s118/s4/llvm-real-spill/feedback.jsonl) |
| `s118/s8` | [benchmarks/tsvc/s118.c:38:13](/work/loop-benchmarks/benchmarks/tsvc/s118.c:38) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s118/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s118/s8/llvm-real-spill/feedback.jsonl) |
| `s118/s16` | [benchmarks/tsvc/s118.c:38:13](/work/loop-benchmarks/benchmarks/tsvc/s118.c:38) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s118/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s118/s16/llvm-real-spill/feedback.jsonl) |
| `s119/s16` | [benchmarks/tsvc/s119.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s119.c:37) | `s119` | T | F | FP | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s119/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s119/s16/llvm-real-spill/feedback.jsonl) |
| `s1232/s16` | [benchmarks/tsvc/s1232.c:38:13](/work/loop-benchmarks/benchmarks/tsvc/s1232.c:38) | `bench_kernel` | T | F | FP | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1232/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1232/s16/llvm-real-spill/feedback.jsonl) |
| `s1232/s32` | [benchmarks/tsvc/s1232.c:38:13](/work/loop-benchmarks/benchmarks/tsvc/s1232.c:38) | `bench_kernel` | T | T | TP | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1232/s32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1232/s32/llvm-real-spill/feedback.jsonl) |
| `s124/f16` | [benchmarks/tsvc/s124.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s124.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s124/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s124/f16/llvm-real-spill/feedback.jsonl) |
| `s124/f32` | [benchmarks/tsvc/s124.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s124.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s124/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s124/f32/llvm-real-spill/feedback.jsonl) |
| `s124/s8` | [benchmarks/tsvc/s124.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s124.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s124/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s124/s8/llvm-real-spill/feedback.jsonl) |
| `s124/s16` | [benchmarks/tsvc/s124.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s124.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s124/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s124/s16/llvm-real-spill/feedback.jsonl) |
| `s125/s1` | [benchmarks/tsvc/s125.c:40:13](/work/loop-benchmarks/benchmarks/tsvc/s125.c:40) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s125/s1/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s125/s1/llvm-real-spill/feedback.jsonl) |
| `s125/s2` | [benchmarks/tsvc/s125.c:40:13](/work/loop-benchmarks/benchmarks/tsvc/s125.c:40) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s125/s2/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s125/s2/llvm-real-spill/feedback.jsonl) |
| `s125/s4` | [benchmarks/tsvc/s125.c:40:13](/work/loop-benchmarks/benchmarks/tsvc/s125.c:40) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s125/s4/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s125/s4/llvm-real-spill/feedback.jsonl) |
| `s125/s8` | [benchmarks/tsvc/s125.c:40:13](/work/loop-benchmarks/benchmarks/tsvc/s125.c:40) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s125/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s125/s8/llvm-real-spill/feedback.jsonl) |
| `s125/s16` | [benchmarks/tsvc/s125.c:40:13](/work/loop-benchmarks/benchmarks/tsvc/s125.c:40) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s125/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s125/s16/llvm-real-spill/feedback.jsonl) |
| `s125/s32` | [benchmarks/tsvc/s125.c:40:13](/work/loop-benchmarks/benchmarks/tsvc/s125.c:40) | `bench_kernel` | T | T | TP | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s125/s32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s125/s32/llvm-real-spill/feedback.jsonl) |
| `s1251/f32` | [benchmarks/tsvc/s1251.c:38:9](/work/loop-benchmarks/benchmarks/tsvc/s1251.c:38) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1251/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1251/f32/llvm-real-spill/feedback.jsonl) |
| `s1251/s16` | [benchmarks/tsvc/s1251.c:38:9](/work/loop-benchmarks/benchmarks/tsvc/s1251.c:38) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1251/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1251/s16/llvm-real-spill/feedback.jsonl) |
| `s127/f16` | [benchmarks/tsvc/s127.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s127.c:39) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s127/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s127/f16/llvm-real-spill/feedback.jsonl) |
| `s127/f32` | [benchmarks/tsvc/s127.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s127.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s127/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s127/f32/llvm-real-spill/feedback.jsonl) |
| `s1281/f32` | [benchmarks/tsvc/s1281.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s1281.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1281/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1281/f32/llvm-real-spill/feedback.jsonl) |
| `s1281/s16` | [benchmarks/tsvc/s1281.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s1281.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1281/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1281/s16/llvm-real-spill/feedback.jsonl) |
| `s1351/f16` | [benchmarks/tsvc/s1351.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s1351.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1351/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1351/f16/llvm-real-spill/feedback.jsonl) |
| `s1351/f32` | [benchmarks/tsvc/s1351.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s1351.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1351/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1351/f32/llvm-real-spill/feedback.jsonl) |
| `s1351/s8` | [benchmarks/tsvc/s1351.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s1351.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1351/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1351/s8/llvm-real-spill/feedback.jsonl) |
| `s1351/s16` | [benchmarks/tsvc/s1351.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s1351.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1351/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1351/s16/llvm-real-spill/feedback.jsonl) |
| `s1421/f8` | [benchmarks/tsvc/s1421.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s1421.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1421/f8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1421/f8/llvm-real-spill/feedback.jsonl) |
| `s1421/f16` | [benchmarks/tsvc/s1421.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s1421.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1421/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1421/f16/llvm-real-spill/feedback.jsonl) |
| `s1421/f32` | [benchmarks/tsvc/s1421.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s1421.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1421/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1421/f32/llvm-real-spill/feedback.jsonl) |
| `s1421/s4` | [benchmarks/tsvc/s1421.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s1421.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1421/s4/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1421/s4/llvm-real-spill/feedback.jsonl) |
| `s1421/s8` | [benchmarks/tsvc/s1421.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s1421.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1421/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1421/s8/llvm-real-spill/feedback.jsonl) |
| `s1421/s16` | [benchmarks/tsvc/s1421.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s1421.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1421/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1421/s16/llvm-real-spill/feedback.jsonl) |
| `s152/f16` | [benchmarks/tsvc/s152.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s152.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s152/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s152/f16/llvm-real-spill/feedback.jsonl) |
| `s152/f32` | [benchmarks/tsvc/s152.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s152.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s152/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s152/f32/llvm-real-spill/feedback.jsonl) |
| `s152/s8` | [benchmarks/tsvc/s152.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s152.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s152/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s152/s8/llvm-real-spill/feedback.jsonl) |
| `s152/s16` | [benchmarks/tsvc/s152.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s152.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s152/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s152/s16/llvm-real-spill/feedback.jsonl) |
| `s171/f8` | [benchmarks/tsvc/s171.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s171.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s171/f8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s171/f8/llvm-real-spill/feedback.jsonl) |
| `s171/f16` | [benchmarks/tsvc/s171.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s171.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s171/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s171/f16/llvm-real-spill/feedback.jsonl) |
| `s171/f32` | [benchmarks/tsvc/s171.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s171.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s171/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s171/f32/llvm-real-spill/feedback.jsonl) |
| `s171/s4` | [benchmarks/tsvc/s171.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s171.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s171/s4/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s171/s4/llvm-real-spill/feedback.jsonl) |
| `s171/s8` | [benchmarks/tsvc/s171.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s171.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s171/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s171/s8/llvm-real-spill/feedback.jsonl) |
| `s171/s16` | [benchmarks/tsvc/s171.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s171.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s171/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s171/s16/llvm-real-spill/feedback.jsonl) |
| `s173/f8` | [benchmarks/tsvc/s173.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s173.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s173/f8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s173/f8/llvm-real-spill/feedback.jsonl) |
| `s173/f16` | [benchmarks/tsvc/s173.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s173.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s173/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s173/f16/llvm-real-spill/feedback.jsonl) |
| `s173/f32` | [benchmarks/tsvc/s173.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s173.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s173/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s173/f32/llvm-real-spill/feedback.jsonl) |
| `s173/s4` | [benchmarks/tsvc/s173.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s173.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s173/s4/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s173/s4/llvm-real-spill/feedback.jsonl) |
| `s173/s8` | [benchmarks/tsvc/s173.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s173.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s173/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s173/s8/llvm-real-spill/feedback.jsonl) |
| `s173/s16` | [benchmarks/tsvc/s173.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s173.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s173/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s173/s16/llvm-real-spill/feedback.jsonl) |
| `s176/f2` | [benchmarks/tsvc/s176.c:39:13](/work/loop-benchmarks/benchmarks/tsvc/s176.c:39) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s176/f2/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s176/f2/llvm-real-spill/feedback.jsonl) |
| `s176/f4` | [benchmarks/tsvc/s176.c:39:13](/work/loop-benchmarks/benchmarks/tsvc/s176.c:39) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s176/f4/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s176/f4/llvm-real-spill/feedback.jsonl) |
| `s176/f8` | [benchmarks/tsvc/s176.c:39:13](/work/loop-benchmarks/benchmarks/tsvc/s176.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s176/f8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s176/f8/llvm-real-spill/feedback.jsonl) |
| `s176/f16` | [benchmarks/tsvc/s176.c:39:13](/work/loop-benchmarks/benchmarks/tsvc/s176.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s176/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s176/f16/llvm-real-spill/feedback.jsonl) |
| `s176/f32` | [benchmarks/tsvc/s176.c:39:13](/work/loop-benchmarks/benchmarks/tsvc/s176.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s176/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s176/f32/llvm-real-spill/feedback.jsonl) |
| `s176/s1` | [benchmarks/tsvc/s176.c:39:13](/work/loop-benchmarks/benchmarks/tsvc/s176.c:39) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s176/s1/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s176/s1/llvm-real-spill/feedback.jsonl) |
| `s176/s2` | [benchmarks/tsvc/s176.c:39:13](/work/loop-benchmarks/benchmarks/tsvc/s176.c:39) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s176/s2/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s176/s2/llvm-real-spill/feedback.jsonl) |
| `s176/s4` | [benchmarks/tsvc/s176.c:39:13](/work/loop-benchmarks/benchmarks/tsvc/s176.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s176/s4/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s176/s4/llvm-real-spill/feedback.jsonl) |
| `s176/s8` | [benchmarks/tsvc/s176.c:39:13](/work/loop-benchmarks/benchmarks/tsvc/s176.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s176/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s176/s8/llvm-real-spill/feedback.jsonl) |
| `s176/s16` | [benchmarks/tsvc/s176.c:39:13](/work/loop-benchmarks/benchmarks/tsvc/s176.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s176/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s176/s16/llvm-real-spill/feedback.jsonl) |
| `s2101/s16` | [benchmarks/tsvc/s2101.c:38:9](/work/loop-benchmarks/benchmarks/tsvc/s2101.c:38) | `bench_kernel` | T | T | TP | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s2101/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s2101/s16/llvm-real-spill/feedback.jsonl) |
| `s2101/s32` | [benchmarks/tsvc/s2101.c:38:9](/work/loop-benchmarks/benchmarks/tsvc/s2101.c:38) | `bench_kernel` | T | T | TP | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s2101/s32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s2101/s32/llvm-real-spill/feedback.jsonl) |
| `s2275/s16` | [benchmarks/tsvc/s2275.c:36:9](/work/loop-benchmarks/benchmarks/tsvc/s2275.c:36) | `s2275` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s2275/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s2275/s16/llvm-real-spill/feedback.jsonl) |
| `s2275/s32` | [benchmarks/tsvc/s2275.c:36:9](/work/loop-benchmarks/benchmarks/tsvc/s2275.c:36) | `s2275` | T | T | TP | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s2275/s32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s2275/s32/llvm-real-spill/feedback.jsonl) |
| `s231/s16` | [benchmarks/tsvc/s231.c:36:9](/work/loop-benchmarks/benchmarks/tsvc/s231.c:36) | `s231` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s231/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s231/s16/llvm-real-spill/feedback.jsonl) |
| `s231/s32` | [benchmarks/tsvc/s231.c:36:9](/work/loop-benchmarks/benchmarks/tsvc/s231.c:36) | `s231` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s231/s32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s231/s32/llvm-real-spill/feedback.jsonl) |
| `s235/s16` | [benchmarks/tsvc/s235.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s235.c:37) | `s235` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s235/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s235/s16/llvm-real-spill/feedback.jsonl) |
| `s235/s32` | [benchmarks/tsvc/s235.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s235.c:37) | `s235` | T | F | FP | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s235/s32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s235/s32/llvm-real-spill/feedback.jsonl) |
| `s251/f16` | [benchmarks/tsvc/s251.c:38:9](/work/loop-benchmarks/benchmarks/tsvc/s251.c:38) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s251/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s251/f16/llvm-real-spill/feedback.jsonl) |
| `s251/f32` | [benchmarks/tsvc/s251.c:38:9](/work/loop-benchmarks/benchmarks/tsvc/s251.c:38) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s251/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s251/f32/llvm-real-spill/feedback.jsonl) |
| `s251/s8` | [benchmarks/tsvc/s251.c:38:9](/work/loop-benchmarks/benchmarks/tsvc/s251.c:38) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s251/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s251/s8/llvm-real-spill/feedback.jsonl) |
| `s251/s16` | [benchmarks/tsvc/s251.c:38:9](/work/loop-benchmarks/benchmarks/tsvc/s251.c:38) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s251/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s251/s16/llvm-real-spill/feedback.jsonl) |
| `s293/f4` | [benchmarks/tsvc/s293.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s293.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s293/f4/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s293/f4/llvm-real-spill/feedback.jsonl) |
| `s293/f8` | [benchmarks/tsvc/s293.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s293.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s293/f8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s293/f8/llvm-real-spill/feedback.jsonl) |
| `s293/f16` | [benchmarks/tsvc/s293.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s293.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s293/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s293/f16/llvm-real-spill/feedback.jsonl) |
| `s293/f32` | [benchmarks/tsvc/s293.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s293.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s293/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s293/f32/llvm-real-spill/feedback.jsonl) |
| `s293/s2` | [benchmarks/tsvc/s293.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s293.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s293/s2/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s293/s2/llvm-real-spill/feedback.jsonl) |
| `s293/s4` | [benchmarks/tsvc/s293.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s293.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s293/s4/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s293/s4/llvm-real-spill/feedback.jsonl) |
| `s293/s8` | [benchmarks/tsvc/s293.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s293.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s293/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s293/s8/llvm-real-spill/feedback.jsonl) |
| `s293/s16` | [benchmarks/tsvc/s293.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s293.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s293/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s293/s16/llvm-real-spill/feedback.jsonl) |
| `s311/f8` | [benchmarks/tsvc/s311.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s311.c:39) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s311/f8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s311/f8/llvm-real-spill/feedback.jsonl) |
| `s311/f16` | [benchmarks/tsvc/s311.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s311.c:39) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s311/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s311/f16/llvm-real-spill/feedback.jsonl) |
| `s311/f32` | [benchmarks/tsvc/s311.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s311.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s311/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s311/f32/llvm-real-spill/feedback.jsonl) |
| `s311/s4` | [benchmarks/tsvc/s311.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s311.c:39) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s311/s4/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s311/s4/llvm-real-spill/feedback.jsonl) |
| `s311/s8` | [benchmarks/tsvc/s311.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s311.c:39) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s311/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s311/s8/llvm-real-spill/feedback.jsonl) |
| `s311/s16` | [benchmarks/tsvc/s311.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s311.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s311/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s311/s16/llvm-real-spill/feedback.jsonl) |
| `s313/f16` | [benchmarks/tsvc/s313.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s313.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s313/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s313/f16/llvm-real-spill/feedback.jsonl) |
| `s313/f32` | [benchmarks/tsvc/s313.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s313.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s313/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s313/f32/llvm-real-spill/feedback.jsonl) |
| `s313/s8` | [benchmarks/tsvc/s313.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s313.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s313/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s313/s8/llvm-real-spill/feedback.jsonl) |
| `s313/s16` | [benchmarks/tsvc/s313.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/s313.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s313/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s313/s16/llvm-real-spill/feedback.jsonl) |
| `s315/f16` | [benchmarks/tsvc/s315.c:35:5](/work/loop-benchmarks/benchmarks/tsvc/s315.c:35) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s315/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s315/f16/llvm-real-spill/feedback.jsonl) |
| `s315/f32` | [benchmarks/tsvc/s315.c:35:5](/work/loop-benchmarks/benchmarks/tsvc/s315.c:35) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s315/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s315/f32/llvm-real-spill/feedback.jsonl) |
| `s315/s8` | [benchmarks/tsvc/s315.c:35:5](/work/loop-benchmarks/benchmarks/tsvc/s315.c:35) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s315/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s315/s8/llvm-real-spill/feedback.jsonl) |
| `s315/s16` | [benchmarks/tsvc/s315.c:35:5](/work/loop-benchmarks/benchmarks/tsvc/s315.c:35) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s315/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s315/s16/llvm-real-spill/feedback.jsonl) |
| `s331/f8` | [benchmarks/tsvc/s331.c:40:9](/work/loop-benchmarks/benchmarks/tsvc/s331.c:40) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s331/f8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s331/f8/llvm-real-spill/feedback.jsonl) |
| `s331/f16` | [benchmarks/tsvc/s331.c:40:9](/work/loop-benchmarks/benchmarks/tsvc/s331.c:40) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s331/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s331/f16/llvm-real-spill/feedback.jsonl) |
| `s331/f32` | [benchmarks/tsvc/s331.c:40:9](/work/loop-benchmarks/benchmarks/tsvc/s331.c:40) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s331/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s331/f32/llvm-real-spill/feedback.jsonl) |
| `s331/s4` | [benchmarks/tsvc/s331.c:40:9](/work/loop-benchmarks/benchmarks/tsvc/s331.c:40) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s331/s4/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s331/s4/llvm-real-spill/feedback.jsonl) |
| `s331/s8` | [benchmarks/tsvc/s331.c:40:9](/work/loop-benchmarks/benchmarks/tsvc/s331.c:40) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s331/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s331/s8/llvm-real-spill/feedback.jsonl) |
| `s331/s16` | [benchmarks/tsvc/s331.c:40:9](/work/loop-benchmarks/benchmarks/tsvc/s331.c:40) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s331/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s331/s16/llvm-real-spill/feedback.jsonl) |
| `s332/s4` | [benchmarks/tsvc/s332.c:44:9](/work/loop-benchmarks/benchmarks/tsvc/s332.c:44) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s332/s4/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s332/s4/llvm-real-spill/feedback.jsonl) |
| `s332/s8` | [benchmarks/tsvc/s332.c:44:9](/work/loop-benchmarks/benchmarks/tsvc/s332.c:44) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s332/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s332/s8/llvm-real-spill/feedback.jsonl) |
| `s332/s16` | [benchmarks/tsvc/s332.c:44:9](/work/loop-benchmarks/benchmarks/tsvc/s332.c:44) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s332/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s332/s16/llvm-real-spill/feedback.jsonl) |
| `s4121/f16` | [benchmarks/tsvc/s4121.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s4121.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s4121/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s4121/f16/llvm-real-spill/feedback.jsonl) |
| `s4121/f32` | [benchmarks/tsvc/s4121.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s4121.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s4121/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s4121/f32/llvm-real-spill/feedback.jsonl) |
| `s4121/s8` | [benchmarks/tsvc/s4121.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s4121.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s4121/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s4121/s8/llvm-real-spill/feedback.jsonl) |
| `s4121/s16` | [benchmarks/tsvc/s4121.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s4121.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s4121/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s4121/s16/llvm-real-spill/feedback.jsonl) |
| `s422/f16` | [benchmarks/tsvc/s422.c:40:9](/work/loop-benchmarks/benchmarks/tsvc/s422.c:40) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s422/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s422/f16/llvm-real-spill/feedback.jsonl) |
| `s422/f32` | [benchmarks/tsvc/s422.c:40:9](/work/loop-benchmarks/benchmarks/tsvc/s422.c:40) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s422/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s422/f32/llvm-real-spill/feedback.jsonl) |
| `s422/s8` | [benchmarks/tsvc/s422.c:40:9](/work/loop-benchmarks/benchmarks/tsvc/s422.c:40) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s422/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s422/s8/llvm-real-spill/feedback.jsonl) |
| `s422/s16` | [benchmarks/tsvc/s422.c:40:9](/work/loop-benchmarks/benchmarks/tsvc/s422.c:40) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s422/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s422/s16/llvm-real-spill/feedback.jsonl) |
| `s431/f8` | [benchmarks/tsvc/s431.c:41:9](/work/loop-benchmarks/benchmarks/tsvc/s431.c:41) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s431/f8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s431/f8/llvm-real-spill/feedback.jsonl) |
| `s431/f16` | [benchmarks/tsvc/s431.c:41:9](/work/loop-benchmarks/benchmarks/tsvc/s431.c:41) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s431/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s431/f16/llvm-real-spill/feedback.jsonl) |
| `s431/f32` | [benchmarks/tsvc/s431.c:41:9](/work/loop-benchmarks/benchmarks/tsvc/s431.c:41) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s431/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s431/f32/llvm-real-spill/feedback.jsonl) |
| `s431/s4` | [benchmarks/tsvc/s431.c:41:9](/work/loop-benchmarks/benchmarks/tsvc/s431.c:41) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s431/s4/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s431/s4/llvm-real-spill/feedback.jsonl) |
| `s431/s8` | [benchmarks/tsvc/s431.c:41:9](/work/loop-benchmarks/benchmarks/tsvc/s431.c:41) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s431/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s431/s8/llvm-real-spill/feedback.jsonl) |
| `s431/s16` | [benchmarks/tsvc/s431.c:41:9](/work/loop-benchmarks/benchmarks/tsvc/s431.c:41) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s431/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s431/s16/llvm-real-spill/feedback.jsonl) |
| `s443/f16` | [benchmarks/tsvc/s443.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s443.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s443/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s443/f16/llvm-real-spill/feedback.jsonl) |
| `s443/f32` | [benchmarks/tsvc/s443.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s443.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s443/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s443/f32/llvm-real-spill/feedback.jsonl) |
| `s443/s8` | [benchmarks/tsvc/s443.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s443.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s443/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s443/s8/llvm-real-spill/feedback.jsonl) |
| `s443/s16` | [benchmarks/tsvc/s443.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s443.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s443/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s443/s16/llvm-real-spill/feedback.jsonl) |
| `s452/f16` | [benchmarks/tsvc/s452.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s452.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s452/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s452/f16/llvm-real-spill/feedback.jsonl) |
| `s452/f32` | [benchmarks/tsvc/s452.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s452.c:37) | `bench_kernel` | T | T | TP | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s452/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s452/f32/llvm-real-spill/feedback.jsonl) |
| `s452/s8` | [benchmarks/tsvc/s452.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s452.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s452/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s452/s8/llvm-real-spill/feedback.jsonl) |
| `s452/s16` | [benchmarks/tsvc/s452.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s452.c:37) | `bench_kernel` | T | T | TP | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s452/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s452/s16/llvm-real-spill/feedback.jsonl) |
| `s471/f16` | [benchmarks/tsvc/s471.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s471.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s471/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s471/f16/llvm-real-spill/feedback.jsonl) |
| `s471/f32` | [benchmarks/tsvc/s471.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s471.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s471/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s471/f32/llvm-real-spill/feedback.jsonl) |
| `s471/s8` | [benchmarks/tsvc/s471.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s471.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s471/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s471/s8/llvm-real-spill/feedback.jsonl) |
| `s471/s16` | [benchmarks/tsvc/s471.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/s471.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s471/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s471/s16/llvm-real-spill/feedback.jsonl) |
| `vbor/s4` | [benchmarks/tsvc/vbor.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/vbor.c:39) | `vbor` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vbor/s4/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vbor/s4/llvm-real-spill/feedback.jsonl) |
| `vbor/s8` | [benchmarks/tsvc/vbor.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/vbor.c:39) | `vbor` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vbor/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vbor/s8/llvm-real-spill/feedback.jsonl) |
| `vbor/s16` | [benchmarks/tsvc/vbor.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/vbor.c:39) | `vbor` | T | T | TP | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vbor/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vbor/s16/llvm-real-spill/feedback.jsonl) |
| `vbor/s32` | [benchmarks/tsvc/vbor.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/vbor.c:39) | `vbor` | T | T | TP | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vbor/s32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vbor/s32/llvm-real-spill/feedback.jsonl) |
| `vdotr/f16` | [benchmarks/tsvc/vdotr.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/vdotr.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vdotr/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vdotr/f16/llvm-real-spill/feedback.jsonl) |
| `vdotr/f32` | [benchmarks/tsvc/vdotr.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/vdotr.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vdotr/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vdotr/f32/llvm-real-spill/feedback.jsonl) |
| `vdotr/s8` | [benchmarks/tsvc/vdotr.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/vdotr.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vdotr/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vdotr/s8/llvm-real-spill/feedback.jsonl) |
| `vdotr/s16` | [benchmarks/tsvc/vdotr.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/vdotr.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vdotr/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vdotr/s16/llvm-real-spill/feedback.jsonl) |
| `vpv/f8` | [benchmarks/tsvc/vpv.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/vpv.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpv/f8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpv/f8/llvm-real-spill/feedback.jsonl) |
| `vpv/f16` | [benchmarks/tsvc/vpv.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/vpv.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpv/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpv/f16/llvm-real-spill/feedback.jsonl) |
| `vpv/f32` | [benchmarks/tsvc/vpv.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/vpv.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpv/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpv/f32/llvm-real-spill/feedback.jsonl) |
| `vpv/s4` | [benchmarks/tsvc/vpv.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/vpv.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpv/s4/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpv/s4/llvm-real-spill/feedback.jsonl) |
| `vpv/s8` | [benchmarks/tsvc/vpv.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/vpv.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpv/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpv/s8/llvm-real-spill/feedback.jsonl) |
| `vpv/s16` | [benchmarks/tsvc/vpv.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/vpv.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpv/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpv/s16/llvm-real-spill/feedback.jsonl) |
| `vpvpv/f16` | [benchmarks/tsvc/vpvpv.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/vpvpv.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvpv/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvpv/f16/llvm-real-spill/feedback.jsonl) |
| `vpvpv/f32` | [benchmarks/tsvc/vpvpv.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/vpvpv.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvpv/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvpv/f32/llvm-real-spill/feedback.jsonl) |
| `vpvpv/s8` | [benchmarks/tsvc/vpvpv.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/vpvpv.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvpv/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvpv/s8/llvm-real-spill/feedback.jsonl) |
| `vpvpv/s16` | [benchmarks/tsvc/vpvpv.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/vpvpv.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvpv/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvpv/s16/llvm-real-spill/feedback.jsonl) |
| `vpvts/f8` | [benchmarks/tsvc/vpvts.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/vpvts.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvts/f8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvts/f8/llvm-real-spill/feedback.jsonl) |
| `vpvts/f16` | [benchmarks/tsvc/vpvts.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/vpvts.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvts/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvts/f16/llvm-real-spill/feedback.jsonl) |
| `vpvts/f32` | [benchmarks/tsvc/vpvts.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/vpvts.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvts/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvts/f32/llvm-real-spill/feedback.jsonl) |
| `vpvts/s4` | [benchmarks/tsvc/vpvts.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/vpvts.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvts/s4/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvts/s4/llvm-real-spill/feedback.jsonl) |
| `vpvts/s8` | [benchmarks/tsvc/vpvts.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/vpvts.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvts/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvts/s8/llvm-real-spill/feedback.jsonl) |
| `vpvts/s16` | [benchmarks/tsvc/vpvts.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/vpvts.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvts/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvts/s16/llvm-real-spill/feedback.jsonl) |
| `vpvtv/f16` | [benchmarks/tsvc/vpvtv.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/vpvtv.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvtv/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvtv/f16/llvm-real-spill/feedback.jsonl) |
| `vpvtv/f32` | [benchmarks/tsvc/vpvtv.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/vpvtv.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvtv/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvtv/f32/llvm-real-spill/feedback.jsonl) |
| `vpvtv/s8` | [benchmarks/tsvc/vpvtv.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/vpvtv.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvtv/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvtv/s8/llvm-real-spill/feedback.jsonl) |
| `vpvtv/s16` | [benchmarks/tsvc/vpvtv.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/vpvtv.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvtv/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvtv/s16/llvm-real-spill/feedback.jsonl) |
| `vsumr/f8` | [benchmarks/tsvc/vsumr.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/vsumr.c:39) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vsumr/f8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vsumr/f8/llvm-real-spill/feedback.jsonl) |
| `vsumr/f16` | [benchmarks/tsvc/vsumr.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/vsumr.c:39) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vsumr/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vsumr/f16/llvm-real-spill/feedback.jsonl) |
| `vsumr/f32` | [benchmarks/tsvc/vsumr.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/vsumr.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vsumr/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vsumr/f32/llvm-real-spill/feedback.jsonl) |
| `vsumr/s4` | [benchmarks/tsvc/vsumr.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/vsumr.c:39) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vsumr/s4/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vsumr/s4/llvm-real-spill/feedback.jsonl) |
| `vsumr/s8` | [benchmarks/tsvc/vsumr.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/vsumr.c:39) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vsumr/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vsumr/s8/llvm-real-spill/feedback.jsonl) |
| `vsumr/s16` | [benchmarks/tsvc/vsumr.c:39:9](/work/loop-benchmarks/benchmarks/tsvc/vsumr.c:39) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vsumr/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vsumr/s16/llvm-real-spill/feedback.jsonl) |
| `vtv/f8` | [benchmarks/tsvc/vtv.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/vtv.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vtv/f8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vtv/f8/llvm-real-spill/feedback.jsonl) |
| `vtv/f16` | [benchmarks/tsvc/vtv.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/vtv.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vtv/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vtv/f16/llvm-real-spill/feedback.jsonl) |
| `vtv/f32` | [benchmarks/tsvc/vtv.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/vtv.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vtv/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vtv/f32/llvm-real-spill/feedback.jsonl) |
| `vtv/s4` | [benchmarks/tsvc/vtv.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/vtv.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vtv/s4/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vtv/s4/llvm-real-spill/feedback.jsonl) |
| `vtv/s8` | [benchmarks/tsvc/vtv.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/vtv.c:37) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vtv/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vtv/s8/llvm-real-spill/feedback.jsonl) |
| `vtv/s16` | [benchmarks/tsvc/vtv.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/vtv.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vtv/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vtv/s16/llvm-real-spill/feedback.jsonl) |
| `vtvtv/f16` | [benchmarks/tsvc/vtvtv.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/vtvtv.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vtvtv/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vtvtv/f16/llvm-real-spill/feedback.jsonl) |
| `vtvtv/f32` | [benchmarks/tsvc/vtvtv.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/vtvtv.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vtvtv/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vtvtv/f32/llvm-real-spill/feedback.jsonl) |
| `vtvtv/s8` | [benchmarks/tsvc/vtvtv.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/vtvtv.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vtvtv/s8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vtvtv/s8/llvm-real-spill/feedback.jsonl) |
| `vtvtv/s16` | [benchmarks/tsvc/vtvtv.c:37:9](/work/loop-benchmarks/benchmarks/tsvc/vtvtv.c:37) | `bench_kernel` | F | T | FN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vtvtv/s16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vtvtv/s16/llvm-real-spill/feedback.jsonl) |

### B: machine-loop 형태 제약 — 7개 구성

| Case / VF | 원본 source:line:column | 최종 함수 | Pred | GT | 분류 | 근거 |
|---|---|---|---|---|---|---|
| `s332/f2` | [benchmarks/tsvc/s332.c:44:9](/work/loop-benchmarks/benchmarks/tsvc/s332.c:44) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s332/f2/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s332/f2/llvm-real-spill/feedback.jsonl) |
| `s332/f4` | [benchmarks/tsvc/s332.c:44:9](/work/loop-benchmarks/benchmarks/tsvc/s332.c:44) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s332/f4/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s332/f4/llvm-real-spill/feedback.jsonl) |
| `s332/f8` | [benchmarks/tsvc/s332.c:44:9](/work/loop-benchmarks/benchmarks/tsvc/s332.c:44) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s332/f8/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s332/f8/llvm-real-spill/feedback.jsonl) |
| `s332/f16` | [benchmarks/tsvc/s332.c:44:9](/work/loop-benchmarks/benchmarks/tsvc/s332.c:44) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s332/f16/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s332/f16/llvm-real-spill/feedback.jsonl) |
| `s332/f32` | [benchmarks/tsvc/s332.c:44:9](/work/loop-benchmarks/benchmarks/tsvc/s332.c:44) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s332/f32/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s332/f32/llvm-real-spill/feedback.jsonl) |
| `s332/s1` | [benchmarks/tsvc/s332.c:44:9](/work/loop-benchmarks/benchmarks/tsvc/s332.c:44) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s332/s1/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s332/s1/llvm-real-spill/feedback.jsonl) |
| `s332/s2` | [benchmarks/tsvc/s332.c:44:9](/work/loop-benchmarks/benchmarks/tsvc/s332.c:44) | `bench_kernel` | F | F | TN | [record](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s332/s2/llvm-real-spill/record.json) · [feedback](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s332/s2/llvm-real-spill/feedback.jsonl) |

## 소스 및 입력 provenance

- Compiler checkout: `a8aa57f9c94f558b6eb64c8cea2b6ca935cce567`.
- Benchmark checkout: `55f5975579fdb5edce1268e476f9f9e5fa4d0408`.
- 원시 수집: `/work/llvm-integration-ablation/.cache/llvm-spill-errors-20261104/tsvc-candidates`.
- 전체 분류 입력: `/work/writing/llvm-spill-errors/full-set-results/rows.jsonl`.
- 분류 JSONL SHA256: `a23a4b4a680300ccc42900e55ee3d95733dce47b0360e13c2c81c934afedb185`.
- 44개 원본 source의 현재 bytes를 수집 당시 `source_sha256`과 대조했고 모두 일치했다.
- 193개 구성의 feedback/assembly/IR/report hash, selected-loop fallback 사유, VF 강제 플래그, forced IR hash를 검증했다.
- 전체 193개 구성은 중복 없이 포함하며 M=186/B=7, TP=10/FP=4/FN=102/TN=77이다.
- 원본 목록 작성 시 컴파일러 변경, 재측정, 테스트 추가/수정은 수행하지 않았다.
  이후 M 세분류 조사에서는 동일 opt binary로 186개 구성의 probe IR을 추가 수집했다.
  Timing 재측정, compiler 변경, 테스트 추가/수정은 하지 않았다.

| 원본 소스 (`/work/loop-benchmarks/` 기준) | Source SHA256 | 준비 기록 |
|---|---|---|
| [benchmarks/tsvc/s000.c](/work/loop-benchmarks/benchmarks/tsvc/s000.c) | `f4b93a95fecbdd53a7caad459ac6d0356c1641a2ceb0f043d9f55cbfbc123f9f` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s000/record.json) |
| [benchmarks/tsvc/s1112.c](/work/loop-benchmarks/benchmarks/tsvc/s1112.c) | `c1951a1ba7edf98d892c3238e521cafb24c3e9695907464f3519e2e3582e9761` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1112/record.json) |
| [benchmarks/tsvc/s1115.c](/work/loop-benchmarks/benchmarks/tsvc/s1115.c) | `d05724b69f25680563e04b79f32d9cb74b74c0eb00ed853237fac54c7b3fb6f0` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1115/record.json) |
| [benchmarks/tsvc/s115.c](/work/loop-benchmarks/benchmarks/tsvc/s115.c) | `31cbe4e374a703d7eeb6a7c228220cd9309025308d235c141d5deef9070b92aa` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s115/record.json) |
| [benchmarks/tsvc/s118.c](/work/loop-benchmarks/benchmarks/tsvc/s118.c) | `24e550562c50d058f22bc231d01bbae6ccd121a9fc06dd8217152937ea339902` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s118/record.json) |
| [benchmarks/tsvc/s119.c](/work/loop-benchmarks/benchmarks/tsvc/s119.c) | `c99bdc7221724e09989206aaf578748613621c399c48c03feec36d897cf84464` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s119/record.json) |
| [benchmarks/tsvc/s1232.c](/work/loop-benchmarks/benchmarks/tsvc/s1232.c) | `4fa80abd9b17b8c399a34e80066b0f1b62467bf05f43fafb9d774f7d04b34b2d` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1232/record.json) |
| [benchmarks/tsvc/s124.c](/work/loop-benchmarks/benchmarks/tsvc/s124.c) | `746f58674a21166a673b5d33ce420f43dd17ccd7916dc21280752c2f55606662` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s124/record.json) |
| [benchmarks/tsvc/s125.c](/work/loop-benchmarks/benchmarks/tsvc/s125.c) | `46b74ddbf7291e43c2b1f74058b3628c50724ce8dc60c0716d758c45dc8a46ed` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s125/record.json) |
| [benchmarks/tsvc/s1251.c](/work/loop-benchmarks/benchmarks/tsvc/s1251.c) | `f57a0d18acd80c305991d72bb272df5314317db9b40bacba682945e3ccf554e5` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1251/record.json) |
| [benchmarks/tsvc/s127.c](/work/loop-benchmarks/benchmarks/tsvc/s127.c) | `0b4037b0e4882956b57dc0ae998ffa88b86f780c339884a91b89a2af9edcf899` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s127/record.json) |
| [benchmarks/tsvc/s1281.c](/work/loop-benchmarks/benchmarks/tsvc/s1281.c) | `85e467f414a4a2d885fbb958bbdda9959279d4e5153efaef760173d982890b91` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1281/record.json) |
| [benchmarks/tsvc/s1351.c](/work/loop-benchmarks/benchmarks/tsvc/s1351.c) | `48928464d3f644fca8eec08a035623174e7093d250c6d4ec042bb3cc359b9e44` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1351/record.json) |
| [benchmarks/tsvc/s1421.c](/work/loop-benchmarks/benchmarks/tsvc/s1421.c) | `da6f9274a4ca847d5d16052a01e93037e21d74b0ca7bcbbe8fca953aa13893bb` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s1421/record.json) |
| [benchmarks/tsvc/s152.c](/work/loop-benchmarks/benchmarks/tsvc/s152.c) | `f4721e54850cd0bd3914ea1e81be8bbbe7d9cf0941782fb986ee768e797b3ee9` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s152/record.json) |
| [benchmarks/tsvc/s171.c](/work/loop-benchmarks/benchmarks/tsvc/s171.c) | `68b634a912468ddb7ef053c7214059ddac795e59edf17d63f9d2df669e992829` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s171/record.json) |
| [benchmarks/tsvc/s173.c](/work/loop-benchmarks/benchmarks/tsvc/s173.c) | `7add3e335d994ac2dd67889ea1421cd29ac3d19db5a20c2e75e7172a887cfbb3` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s173/record.json) |
| [benchmarks/tsvc/s176.c](/work/loop-benchmarks/benchmarks/tsvc/s176.c) | `66d5392e78facda36a08802da29f71160f5eabb530d01dea9313c0df06849c4c` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s176/record.json) |
| [benchmarks/tsvc/s2101.c](/work/loop-benchmarks/benchmarks/tsvc/s2101.c) | `a96b45241ad20ce3dd727a0304ce57f7f7d2612499883ff6e8be5d6fa9a140c5` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s2101/record.json) |
| [benchmarks/tsvc/s2275.c](/work/loop-benchmarks/benchmarks/tsvc/s2275.c) | `b4c16291684ef919306136c0b2bf50e9bdb3cb19ce9b5415d9fdc1a4920fa828` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s2275/record.json) |
| [benchmarks/tsvc/s231.c](/work/loop-benchmarks/benchmarks/tsvc/s231.c) | `e049b9a645cb316c3dcdb58ad5312c2b21f53f75762f8cb5d9c018739c819f58` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s231/record.json) |
| [benchmarks/tsvc/s235.c](/work/loop-benchmarks/benchmarks/tsvc/s235.c) | `48ede569035356ed27abf41c1f3936c8a969b64a536d44b3b6b8d0baf7c224fc` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s235/record.json) |
| [benchmarks/tsvc/s251.c](/work/loop-benchmarks/benchmarks/tsvc/s251.c) | `5c4e9aaf8edbe675824696e9a0949a6ac846057447a8355f864f004da1cc609d` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s251/record.json) |
| [benchmarks/tsvc/s293.c](/work/loop-benchmarks/benchmarks/tsvc/s293.c) | `0570575a6f9d665a9988f592f667a8f9a9bb92fff0841f1b6bb34ee398e952d3` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s293/record.json) |
| [benchmarks/tsvc/s311.c](/work/loop-benchmarks/benchmarks/tsvc/s311.c) | `ed86030bc49a0d975447187f7db3ef0794fb960f364bce19b73b9744464c90d9` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s311/record.json) |
| [benchmarks/tsvc/s313.c](/work/loop-benchmarks/benchmarks/tsvc/s313.c) | `0d13f0d02c9365cf09aad1d7378c63e38f846e893e47273db2a499706080fa2d` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s313/record.json) |
| [benchmarks/tsvc/s315.c](/work/loop-benchmarks/benchmarks/tsvc/s315.c) | `c3a6bf2da361d84d67429353ea60947c390dc676ac9abacfc7a8331c93c26866` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s315/record.json) |
| [benchmarks/tsvc/s331.c](/work/loop-benchmarks/benchmarks/tsvc/s331.c) | `4c014786c9a414e607c3a713354a1e5bb7e275b26cb1f8a9eea82000708ea6a3` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s331/record.json) |
| [benchmarks/tsvc/s332.c](/work/loop-benchmarks/benchmarks/tsvc/s332.c) | `be06d7d44bde45327d5fe365a746fd136255a2f3e8095db4ef1e550e6efbf7c2` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s332/record.json) |
| [benchmarks/tsvc/s4121.c](/work/loop-benchmarks/benchmarks/tsvc/s4121.c) | `65bcd84bda1e5e66741c9db849ac6cd2efca16baaae2a3cd0810c9ddfc3c9008` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s4121/record.json) |
| [benchmarks/tsvc/s422.c](/work/loop-benchmarks/benchmarks/tsvc/s422.c) | `76c9e64dabf019747c7b05ddd166e44f09d1f87b38201097c649296e3de33cc1` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s422/record.json) |
| [benchmarks/tsvc/s431.c](/work/loop-benchmarks/benchmarks/tsvc/s431.c) | `4dc971ab9c436e80bd5d7efc6e861372ec1b3064616ad7b3bd789a694dfc1565` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s431/record.json) |
| [benchmarks/tsvc/s443.c](/work/loop-benchmarks/benchmarks/tsvc/s443.c) | `be948e16e3480f63e58e2dfc83dba6440c641384b57d5e1dcffdd86a227417d3` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s443/record.json) |
| [benchmarks/tsvc/s452.c](/work/loop-benchmarks/benchmarks/tsvc/s452.c) | `b18b61b6c1d73402d6e752159337cb9e7a71ea1857868d7710b8b67bf2bd3b3b` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s452/record.json) |
| [benchmarks/tsvc/s471.c](/work/loop-benchmarks/benchmarks/tsvc/s471.c) | `b7c14b2e533a8760cb3a344c42610308eccef020c4a89a73a9244e1eb57599d7` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__s471/record.json) |
| [benchmarks/tsvc/vbor.c](/work/loop-benchmarks/benchmarks/tsvc/vbor.c) | `52731280c1195d26cba58bc8a001e4202bce08953565b4b3e8869db20bf8c9d7` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vbor/record.json) |
| [benchmarks/tsvc/vdotr.c](/work/loop-benchmarks/benchmarks/tsvc/vdotr.c) | `1f2336baafad022595da49b8471b426836280c1ce12a73242b63b4420150975e` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vdotr/record.json) |
| [benchmarks/tsvc/vpv.c](/work/loop-benchmarks/benchmarks/tsvc/vpv.c) | `afd633403f084f7467f30fb1fcb1165d5971059778c003d6d664c125a51660f0` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpv/record.json) |
| [benchmarks/tsvc/vpvpv.c](/work/loop-benchmarks/benchmarks/tsvc/vpvpv.c) | `f7782fdb9d4169b7bb80883f0eb084df23275ce19a70de9ddd90919672523368` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvpv/record.json) |
| [benchmarks/tsvc/vpvts.c](/work/loop-benchmarks/benchmarks/tsvc/vpvts.c) | `44f28802ee1682ac1df2c5438042834b69b8d9a56df59c157af61d3725d9c41a` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvts/record.json) |
| [benchmarks/tsvc/vpvtv.c](/work/loop-benchmarks/benchmarks/tsvc/vpvtv.c) | `14c6a18c5e62368015d0d2adc34b54f40ea9c317c506822592c7c2e6d42c2eba` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vpvtv/record.json) |
| [benchmarks/tsvc/vsumr.c](/work/loop-benchmarks/benchmarks/tsvc/vsumr.c) | `3c5c18f243abd54a8236045457ef588a76ae5154cc369251f1ec3ac47ab9d285` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vsumr/record.json) |
| [benchmarks/tsvc/vtv.c](/work/loop-benchmarks/benchmarks/tsvc/vtv.c) | `826aac24b491b6104a1eabf93a95deabde2a1ade5c6b7045b9d58bb1a65fa119` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vtv/record.json) |
| [benchmarks/tsvc/vtvtv.c](/work/loop-benchmarks/benchmarks/tsvc/vtvtv.c) | `1ff0b728096b8b47da3c148ac76750a253675910f2e108a0229cd5359713dcd8` | [frontend argv / metadata / IR hash](.cache/llvm-spill-errors-20261104/tsvc-candidates/cases/tsvc__vtvtv/record.json) |

각 source의 fixture/support dependency와 translation-unit SHA256는
[natural build metadata](.cache/llvm-spill-errors-20261104/tsvc-candidates/natural/metadata/build.json)의
`units[].details.source_dependencies`, `translation_unit_sha256`에서 확인할 수 있다.
전체 compiler executable hash와 수집 stage 기록은
[collection.json](.cache/llvm-spill-errors-20261104/tsvc-candidates/collection.json)에 있다.
