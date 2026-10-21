# MemCost 오예측 평가

평가일: 2026-10-22 (Asia/Seoul). 현재 HEAD `f32ba07863b02bbded0f1ed3463fb2f8e788725d`의 `backend-memory-window-v3`를 저장된 [calibrated 프로파일](utils/vplan-tools/memory-window-calibrated.json)로 다시 평가했다. `search-dataset.sqlite` 전체 203개 benchmark, 901개 측정을 사용하고 기존 split 표시는 필터로 사용하지 않았다.

전체 **203개** 중 **189개 평가 가능**, **88개 정답**, **101개 오예측**, **14개 제외**다. 정확도 **46.5608%**, 평균 regret **4.7930%**, P95 **25.3582%**, 최대 regret **39.6818%**다. runtime 측정이나 새 calibration은 하지 않았다.

여기서 MemCost는 opt-in window 프로파일을 뜻한다. 일반 meta compiler의 기본 정책은 여전히 `llvm-backend-spill-v1`이다. `Parameters()`의 비보정 기본값이나 `evaluate`의 기본 spill 결과를 이 수치와 혼동하지 않는다.

## 입력·재현 범위

- DB SHA-256: `3d5e09ed2346be109a887192c36422073a4a6650b0f38cc29765d72ad063ff37`.
- 관측용 compiler SHA-256: `9c455960b6753d54beac15fa564c458a1bcc73ef4caa445ffb805fab96096ff9`. 현재 Python 코드로 저장된 post-RA analytics/MIR/detail을 재해석했다. compiler를 새로 빌드/실행하지 않았다.
- 실제 replay HEAD는 위 `f32ba078…`이며, 결과 JSON의 `provenance.head`는 **관측 수집 당시**의 `c51c893…`다. 둘의 구분과 현재 코드 hash는 [실행 provenance](.cache/wrong-predictions-memcost-20261022/run-provenance.json)에 있다.
- 타깃: XiangShan v2 / VLEN=128 / IC=1 / vector epilogue 없음. DB 측정 compiler와 probe compiler의 동일성은 검증되지 않았다.
- 현재 [평가 결과](.cache/wrong-predictions-memcost-20261022/results.json)의 `profiles.explicit.versus_strided.rows`에 전체 203개 판정과 후보 비용, `profiles.explicit.details`에 memory 제거량·추가량·window 값이 있다.
- [분석 evidence](.cache/wrong-predictions-memcost-20261022/analysis.json)는 각 benchmark의 소스 발췌, 측정 VF/cycles, 후보별 원본/새 비용, spill 수, opcode 분포, analytics/MIR/detail 경로를 제공한다. [관측 재검증](.cache/wrong-predictions-memcost-20261022/facts-verification.json)에서 현재 extractor로 다시 만든 939개 후보 facts가 저장된 값과 모두 일치한다.
- 프로파일은 과거 search set에 in-sample calibration된 값이다. 이번 재평가를 독립 검증이나 새로운 하드웨어 측정으로 해석하지 않는다.

## 비용과 판정 기준

```text
window_size=12, throughput=2, reference_width=8, headroom=0, interaction_weight=2
service: unit=1/4, strided=1/2, segment=1, indexed=1/2
demand weights: 기본 1; llvm_memory_removal=recipes; service_scale=1
stride_service_strength=stride_demand_strength=0

S = Σ Cost(non-spill memory op)
L = min(window_size, body_instruction_count)
T = L * max(1, backend_iteration_width/reference_width)
Q = max cyclic-window Σ Demand(op)
I = interaction_weight * max(0, Q-headroom-throughput*T) / throughput
memory = (service_scale*S + I) / iteration_ratio
body = precomputed + vector_region - whole_memory_recipes + backend_spill + memory
```

memory를 iteration ratio로 정규화한 뒤 quarter-unit으로 한 번 내림/포화 처리한다. memory recipe 안의 주소/shuffle 항은 제거하지만 독립된 non-memory recipe와 실제 spill 비용은 유지한다. window 위치는 instruction index이고 실제 issue cycle이 아니다. masks는 full-active로 가정한다.

선택은 현재 scalable-only 정책과 compiler 후보 순서·pairwise 비교·trip count/tail 규칙을 따른다. 현재 관측에서 `estimated_width=2*VF`이며 `s1`도 vector다. scalar `f1`과 다르다. 최적 VF는 저장된 evaluator의 측정 가능한 compiler scalable 후보 중 cycles 최소인 값이며 DB에만 있는 후보는 제외한다. 측정 cycles 동률이면 작은 VF를 정답으로 삼는다. 후보를 임의로 버려 oracle을 바꾸지 않는다.

`regret = 선택 cycles / 최소 cycles - 1`. 전체 workload의 측정 cycles이며 candidate body의 모델 비용과 단위가 다르다. 평균/P95에는 정답의 0 regret도 포함한다. P95는 정렬된 189개 값의 `(n-1)*0.95` 위치 선형보간이다. 표는 정확한 유리수 regret 내림차순, 동률은 benchmark ID 오름차순이며 출력만 소수 네 자리로 반올림한다.

## 같은 scalable 후보 범위에서 비교

| 모델 | 평가 수 | 정답 | 오예측 | 정확도 | 평균 regret | P95 | 최대 regret |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Strided (scalable-only) | 189 | 84 | 105 | 44.4444% | 6.7163% | 29.8851% | 167.2611% |
| 직전 VF-threshold | 189 | 86 | 103 | 45.5026% | 5.3583% | 25.5511% | 39.6818% |
| 현재 MemCost | 189 | 88 | 101 | 46.5608% | 4.7930% | 25.3582% | 39.6818% |

공통 189개에서 Strided 대비 개선 9개·악화 1개·동일 179개, 직전 VF-threshold 대비 개선 7개·악화 2개·동일 180개다. 두 비교 모두 신규 제외·fallback은 0개다.

기존 [Strided 문서](wrong-predictions-stridedload.md)는 fixed/scalar 선택을 포함한 예전 후보 범위에서 188개 평가·83개 정답이다. 현재는 `tsvc/tsvc-s1111-l00`을 fixed f16 선택에 따른 제외 대신 scalable s16으로 평가하며 정답이다. 따라서 예전 문서의 6.7520%와 현재 4.7930%를 같은 모집단 수치처럼 비교하지 않는다. 위 표의 Strided는 [scalable-only 재평가](.cache/scalable-strided-comparison-20261021/results.json)를 사용한다.

### Strided 대비 실제 선택 변화

| Benchmark | 이전 → 현재 VF | 이전 regret | 현재 regret |
| --- | --- | ---: | ---: |
| [tsvc/tsvc-s351-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s351-l00-be55ca3d/meta/run-4iyoywax/kernel.c) | s2 → s16 | 167.2611% | 7.6064% |
| [tsvc/tsvc-s353-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s353-l00-3fc028fb/meta/run-w5f9a5g9/kernel.c) | s2 → s16 | 89.4003% | 0.0000% |
| [polybench/polybench-symm-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-symm-l00-248585b3/meta/run-0xxx4sno/kernel.c) | s8 → s2 | 33.5058% | 2.9762% |
| [tsvc/tsvc-s2101-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2101-l00-5bf538b9/meta/run-rxezzsgz/kernel.c) | s8 → s2 | 24.4313% | 0.0000% |
| [tsvc/tsvc-s127-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s127-l00-05409684/meta/run-qnz24auh/kernel.c) | s8 → s16 | 20.9060% | 0.0000% |
| [tsvc/tsvc-s257-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s257-l00-9897e012/meta/run-6wg35ene/kernel.c) | s16 → s2 | 15.9915% | 0.0000% |
| [polybench/polybench-adi-l01](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-adi-l01-a1be4de9/meta/run-kgxzmdf7/kernel.c) | s8 → s2 | 21.2076% | 5.9721% |
| [tsvc/tsvc-s2275-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2275-l00-18913cc7/meta/run-w4_0m73f/kernel.c) | s16 → s2 | 5.2797% | 0.0000% |
| [polybench/polybench-gramschmidt-l03](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-gramschmidt-l03-49576383/meta/run-36xutvpu/kernel.c) | s8 → s2 | 6.8209% | 1.6794% |
| [tsvc/tsvc-s1232-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1232-l00-e402d643/meta/run-z42brtul/kernel.c) | s16 → s2 | 0.0000% | 3.0730% |

## 큰 regret의 원인 후보

regret ≥10%인 37개가 전체 regret 합의 **82.9041%**를 차지한다. 아래 9개 가설은 상위 26개를 모두 포함하는 31개 오예측을 대상으로 한다. 같은 benchmark는 주 원인에 한 번만 배정했으며 실제 원인이 확정됐다는 의미는 아니다.

**상위 38개 오예측은 비용이 산출된 모든 후보에서 window interaction=0이다.** memory 비용 전반의 정확성을 뜻하지는 않지만, 현재 interaction 계수만 조금 바꾸는 방식으로는 이 후보들의 순위를 바꾸기 어렵다. throughput/time geometry가 threshold를 넘도록 바꾸거나, 주소 관계·opcode·의존성 등 다른 근거가 필요하다. service가 VF에 선형이면 상수 배수 변경은 per-element 비교에서 상쇄될 수 있다.

| 원인 ID | 추정 공통 원인 | 연결 benchmark 수 | 최대 현재 regret |
| --- | --- | ---: | ---: |
| C1 | 겹치는 store의 순서 제약과 주소 관계 누락 | 1 | 39.6818% |
| C2 | stencil·first-order recurrence의 slide와 의존 경로 비용 | 9 | 35.0389% |
| C3 | masked FP·sqrt와 spill 경계: energy-calc-l04 | 1 | 34.3167% |
| C4 | 다중 unit-stride load/store와 큰 LMUL의 처리 한계 | 6 | 32.7667% |
| C5 | reduction 누적 의존성과 루프 밖 마무리 비용 | 6 | 21.1732% |
| C6 | store-only 루프의 폭 증가 이득 과대평가 | 3 | 19.3192% |
| C7 | 같은 stride라도 다른 주소 관계·window 길이: s233 대 s1232 | 2 | 17.7222% |
| C8 | 짧은 조건부 루프의 partial-VL·설정비용 | 2 | 16.8914% |
| C9 | segment → strided lowering 이후 남은 s351 오예측 | 1 | 7.6064% |

원인별 benchmark·regret·관측 근거·반증 조건·실험 지침은 [GOAL.md](GOAL.md)의 C1–C9에 정리했다. 하드웨어 bank/queue/cache stall이나 mask 활성률은 측정되지 않았으므로 가설로만 취급한다.

### 대표 후보의 비용 대조

아래 비용은 모델 단위이며 runtime cycles가 아니다. body/W는 설명용이고 실제 선택은 tail을 포함한 pairwise 규칙으로 검증했다. service/interaction은 iteration ratio 정규화 후 값, peak/capacity는 정규화 전 window 값이다.

| Benchmark | VF | body/W | spill | service | interaction | peak / capacity | DB cycles |
| --- | --- | ---: | ---: | ---: | ---: | --- | ---: |
| tsvc/tsvc-s2244-l00 | s8 | 1.625 | 0 | 5 | 0 | 20 / 48 | 182,149 |
| tsvc/tsvc-s2244-l00 | s16 | 1.46875 | 0 | 10 | 0 | 40 / 96 | 254,429 |
| polybench/p32-jacobi-1d-imper-l00 | s4 | 5.125 | 0 | 3 | 0 | 12 / 24 | 99,498 |
| polybench/p32-jacobi-1d-imper-l00 | s8 | 4.75 | 0 | 6 | 0 | 24 / 48 | 134,361 |
| lcals/energy-calc-l04 | s4 | 27.75 | 8 | 15 | 0 | 24 / 24 | 9,051 |
| lcals/energy-calc-l04 | s2 | 27.625 | 0 | 7.5 | 0 | 12 / 24 | 12,157 |
| tsvc/tsvc-s252-l00 | s4 | 1.9375 | 0 | 1.5 | 0 | 6 / 24 | 159,922 |
| tsvc/tsvc-s252-l00 | s16 | 1.75 | 0 | 6 | 0 | 24 / 96 | 212,418 |
| tsvc/tsvc-s471-l00 | s8 | 2.5 | 0 | 6 | 0 | 20 / 48 | 263,212 |
| tsvc/tsvc-s471-l00 | s16 | 2.4375 | 0 | 12 | 0 | 40 / 96 | 349,458 |
| rajaperf/dot | s2 | 2.75 | 0 | 1 | 0 | 4 / 16 | 5,232 |
| rajaperf/dot | s8 | 2.375 | 0 | 4 | 0 | 16 / 32 | 6,324 |
| tsvc/tsvc-s293-l00 | s8 | 0.1875 | 0 | 1 | 0 | 4 / 16 | 47,911 |
| tsvc/tsvc-s293-l00 | s16 | 0.125 | 0 | 2 | 0 | 8 / 32 | 57,167 |
| tsvc/tsvc-s233-l01 | s2 | 3.5 | 0 | 6 | 0 | 12 / 24 | 11,906 |
| tsvc/tsvc-s233-l01 | s16 | 2.625 | 0 | 48 | 0 | 96 / 96 | 14,016 |
| tsvc/tsvc-s1232-l00 | s16 | 3.03125 | 0 | 48 | 16 | 96 / 80 | 18,581 |
| tsvc/tsvc-s1232-l00 | s2 | 2.75 | 0 | 6 | 0 | 12 / 20 | 19,152 |
| tsvc/tsvc-s351-l00 | s4 | 16.625 | 0 | 60 | 24 | 48 / 24 | 409,430 |
| tsvc/tsvc-s351-l00 | s16 | 16.53125 | 0 | 240 | 96 | 192 / 96 | 440,573 |

## 오예측 전체 — regret 내림차순

Benchmark 링크는 DB와 일치하는 소스다. `입력 후보` 링크는 기존 spill 관측과 manifest를 추적하기 위한 것으로, 현재 MemCost 비용은 [현재 결과](.cache/wrong-predictions-memcost-20261022/results.json)와 [분석 evidence](.cache/wrong-predictions-memcost-20261022/analysis.json)를 참조한다.

| 순위 | Benchmark / 입력 후보 | 선택 VF | 최적 VF | 선택 cycles | 최소 cycles | 초과 cycles | regret |
| ---: | --- | --- | --- | ---: | ---: | ---: | ---: |
| 1 | [tsvc/tsvc-s2244-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2244-l00-d85baaea/meta/run-ufpdy3jz/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2244-l00-d85baaea/meta/run-ufpdy3jz/backend/candidate-status.json) | s16 | s8 | 254,429 | 182,149 | 72,280 | 39.6818% |
| 2 | [polybench/p32-jacobi-1d-imper-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-jacobi-1d-imper-l00-e35be639/meta/run-8htg62fp/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-jacobi-1d-imper-l00-e35be639/meta/run-8htg62fp/backend/candidate-status.json) | s8 | s4 | 134,361 | 99,498 | 34,863 | 35.0389% |
| 3 | [lcals/energy-calc-l04](.cache/wrong-predictions-20261021/spill/artifacts/lcals_energy-calc-l04-9d0673bd/meta/run-45p0f2qz/kernel.cpp) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/lcals_energy-calc-l04-9d0673bd/meta/run-45p0f2qz/backend/candidate-status.json) | s2 | s4 | 12,157 | 9,051 | 3,106 | 34.3167% |
| 4 | [polybench/p421-jacobi-1d-l01](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-jacobi-1d-l01-4aae641c/meta/run-0sr1oy5c/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-jacobi-1d-l01-4aae641c/meta/run-0sr1oy5c/backend/candidate-status.json) | s8 | s4 | 25,107 | 18,891 | 6,216 | 32.9046% |
| 5 | [tsvc/tsvc-s252-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s252-l00-87217f91/meta/run-4honkdjw/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s252-l00-87217f91/meta/run-4honkdjw/backend/candidate-status.json) | s16 | s4 | 212,418 | 159,922 | 52,496 | 32.8260% |
| 6 | [tsvc/tsvc-s471-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s471-l00-51169cb6/meta/run-cy8ei_zc/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s471-l00-51169cb6/meta/run-cy8ei_zc/backend/candidate-status.json) | s16 | s8 | 349,458 | 263,212 | 86,246 | 32.7667% |
| 7 | [tsvc/tsvc-s152-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s152-l00-b083be54/meta/run-94ggxvkr/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s152-l00-b083be54/meta/run-94ggxvkr/backend/candidate-status.json) | s16 | s8 | 333,909 | 255,070 | 78,839 | 30.9088% |
| 8 | [tsvc/tsvc-s255-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s255-l00-0ec3afcf/meta/run-mqd4biov/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s255-l00-0ec3afcf/meta/run-mqd4biov/backend/candidate-status.json) | s16 | s8 | 268,225 | 208,980 | 59,245 | 28.3496% |
| 9 | [polybench/polybench-jacobi-2d-imper-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-jacobi-2d-imper-l00-0f779552/meta/run-us4uj462/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-jacobi-2d-imper-l00-0f779552/meta/run-us4uj462/backend/candidate-status.json) | s8 | s4 | 15,596 | 12,411 | 3,185 | 25.6627% |
| 10 | [polybench/p421-jacobi-1d-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-jacobi-1d-l00-9ab66748/meta/run-1jp3899_/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-jacobi-1d-l00-9ab66748/meta/run-1jp3899_/backend/candidate-status.json) | s8 | s2 | 25,498 | 20,336 | 5,162 | 25.3836% |
| 11 | [tsvc/tsvc-s1281-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1281-l00-a26e8495/meta/run-fncz8b2s/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1281-l00-a26e8495/meta/run-fncz8b2s/backend/candidate-status.json) | s16 | s8 | 393,157 | 313,722 | 79,435 | 25.3202% |
| 12 | [lcals/first-diff](.cache/wrong-predictions-20261021/spill/artifacts/lcals_first-diff-1e964f79/meta/run-l9zgwwij/kernel.cpp) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/lcals_first-diff-1e964f79/meta/run-l9zgwwij/backend/candidate-status.json) | s8 | s4 | 1,606 | 1,322 | 284 | 21.4826% |
| 13 | [tsvc/tsvc-s331-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s331-l00-910994c5/meta/run-woz71fup/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s331-l00-910994c5/meta/run-woz71fup/backend/candidate-status.json) | s16 | s8 | 64,160 | 52,949 | 11,211 | 21.1732% |
| 14 | [tsvc/tsvc-s1251-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1251-l00-cc7e7448/meta/run-fe35tt80/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1251-l00-cc7e7448/meta/run-fe35tt80/backend/candidate-status.json) | s16 | s8 | 380,187 | 313,966 | 66,221 | 21.0918% |
| 15 | [polybench/p32-atax-l02](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-atax-l02-5a3cb64a/meta/run-yjbz39en/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-atax-l02-5a3cb64a/meta/run-yjbz39en/backend/candidate-status.json) | s8 | s2 | 23,984 | 19,813 | 4,171 | 21.0518% |
| 16 | [rajaperf/dot](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_dot-e736b8f0/meta/run-e1f0zwwc/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_dot-e736b8f0/meta/run-e1f0zwwc/backend/candidate-status.json) | s8 | s2 | 6,324 | 5,232 | 1,092 | 20.8716% |
| 17 | [tsvc/tsvc-s293-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s293-l00-7a431fd2/meta/run-klh0nd9k/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s293-l00-7a431fd2/meta/run-klh0nd9k/backend/candidate-status.json) | s16 | s8 | 57,167 | 47,911 | 9,256 | 19.3192% |
| 18 | [rajaperf/init3](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_init3-95a32e1a/meta/run-_a0979tk/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_init3-95a32e1a/meta/run-_a0979tk/backend/candidate-status.json) | s8 | s4 | 17,207 | 14,424 | 2,783 | 19.2942% |
| 19 | [tsvc/tsvc-s233-l01](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s233-l01-6756cfda/meta/run-wfoj9ukb/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s233-l01-6756cfda/meta/run-wfoj9ukb/backend/candidate-status.json) | s16 | s2 | 14,016 | 11,906 | 2,110 | 17.7222% |
| 20 | [polybench/p421-atax-l01](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-atax-l01-fb8f6463/meta/run-rye4n0ta/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-atax-l01-fb8f6463/meta/run-rye4n0ta/backend/candidate-status.json) | s8 | s4 | 12,476 | 10,599 | 1,877 | 17.7092% |
| 21 | [polybench/p32-mvt-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-mvt-l00-a2db5bae/meta/run-he1ycyv_/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-mvt-l00-a2db5bae/meta/run-he1ycyv_/backend/candidate-status.json) | s8 | s2 | 23,787 | 20,246 | 3,541 | 17.4899% |
| 22 | [lcals/energy-calc-l03](.cache/wrong-predictions-20261021/spill/artifacts/lcals_energy-calc-l03-5a111bb6/meta/run-xwivyynf/kernel.cpp) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/lcals_energy-calc-l03-5a111bb6/meta/run-xwivyynf/backend/candidate-status.json) | s8 | s4 | 1,647 | 1,409 | 238 | 16.8914% |
| 23 | [tsvc/tsvc-s3251-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s3251-l00-66539c1d/meta/run-ee5vy7ga/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s3251-l00-66539c1d/meta/run-ee5vy7ga/backend/candidate-status.json) | s16 | s8 | 414,743 | 358,654 | 56,089 | 15.6387% |
| 24 | [lcals/pressure-calc-l01](.cache/wrong-predictions-20261021/spill/artifacts/lcals_pressure-calc-l01-aa0a9cb1/meta/run-1n7l50un/kernel.cpp) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/lcals_pressure-calc-l01-aa0a9cb1/meta/run-1n7l50un/backend/candidate-status.json) | s8 | s2 | 2,993 | 2,610 | 383 | 14.6743% |
| 25 | [polybench/p32-atax-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-atax-l00-671335a6/meta/run-3p_u09o4/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-atax-l00-671335a6/meta/run-3p_u09o4/backend/candidate-status.json) | s8 | s1 | 14,462 | 12,626 | 1,836 | 14.5414% |
| 26 | [polybench/p32-bicg-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-bicg-l00-68d57011/meta/run-k4j62mds/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-bicg-l00-68d57011/meta/run-k4j62mds/backend/candidate-status.json) | s8 | s1 | 14,462 | 12,626 | 1,836 | 14.5414% |
| 27 | [tsvc/tsvc-s176-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s176-l00-a186d0cf/meta/run-ycrutrzk/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s176-l00-a186d0cf/meta/run-ycrutrzk/backend/candidate-status.json) | s16 | s4 | 49,181 | 42,984 | 6,197 | 14.4170% |
| 28 | [rajaperf/gen-lin-recur-reverse](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_gen-lin-recur-reverse-52b65c3b/meta/run-h4cg6u1c/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_gen-lin-recur-reverse-52b65c3b/meta/run-h4cg6u1c/backend/candidate-status.json) | s8 | s4 | 14,459 | 12,650 | 1,809 | 14.3004% |
| 29 | [polybench/polybench-fdtd-2d-l03](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-fdtd-2d-l03-b8f160c0/meta/run-n4ycir6d/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-fdtd-2d-l03-b8f160c0/meta/run-n4ycir6d/backend/candidate-status.json) | s8 | s2 | 16,776 | 14,694 | 2,082 | 14.1690% |
| 30 | [rajaperf/pi-reduce](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_pi-reduce-76f86157/meta/run-_i0oh96e/kernel.cpp) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_pi-reduce-76f86157/meta/run-_i0oh96e/backend/candidate-status.json) | s8 | s4 | 8,374 | 7,368 | 1,006 | 13.6536% |
| 31 | [tsvc/tsvc-s171-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s171-l00-21a03b56/meta/run-8ycjetq3/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s171-l00-21a03b56/meta/run-8ycjetq3/backend/candidate-status.json) | s16 | s4 | 112,967 | 100,680 | 12,287 | 12.2040% |
| 32 | [tsvc/tsvc-s172-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s172-l00-c3a4cfce/meta/run-bhlj5g51/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s172-l00-c3a4cfce/meta/run-bhlj5g51/backend/candidate-status.json) | s16 | s4 | 112,967 | 100,680 | 12,287 | 12.2040% |
| 33 | [tsvc/tsvc-s119-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s119-l00-7c5e355c/meta/run-1xv6r1l1/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s119-l00-7c5e355c/meta/run-1xv6r1l1/backend/candidate-status.json) | s16 | s8 | 1,068 | 960 | 108 | 11.2500% |
| 34 | [tsvc/tsvc-s273-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s273-l00-99d6486e/meta/run-4uv6q55r/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s273-l00-99d6486e/meta/run-4uv6q55r/backend/candidate-status.json) | s8 | s4 | 438,463 | 395,308 | 43,155 | 10.9168% |
| 35 | [rajaperf/gen-lin-recur-forward](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_gen-lin-recur-forward-2d89df0b/meta/run-688o7436/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_gen-lin-recur-forward-2d89df0b/meta/run-688o7436/backend/candidate-status.json) | s8 | s4 | 13,744 | 12,425 | 1,319 | 10.6157% |
| 36 | [polybench/polybench-correlation-l02](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-correlation-l02-a2134135/meta/run-jnob0_uq/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-correlation-l02-a2134135/meta/run-jnob0_uq/backend/candidate-status.json) | s8 | s4 | 11,011 | 9,967 | 1,044 | 10.4746% |
| 37 | [tsvc/tsvc-s151-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s151-l00-5e5365d8/meta/run-6n8pnnew/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s151-l00-5e5365d8/meta/run-6n8pnnew/backend/candidate-status.json) | s16 | s8 | 115,304 | 104,679 | 10,625 | 10.1501% |
| 38 | [tsvc/tsvc-s1119-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1119-l00-4f9ad8fa/meta/run-audhod81/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1119-l00-4f9ad8fa/meta/run-audhod81/backend/candidate-status.json) | s16 | s4 | 1,106 | 1,025 | 81 | 7.9024% |
| 39 | [tsvc/tsvc-s351-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s351-l00-be55ca3d/meta/run-4iyoywax/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s351-l00-be55ca3d/meta/run-4iyoywax/backend/candidate-status.json) | s16 | s4 | 440,573 | 409,430 | 31,143 | 7.6064% |
| 40 | [polybench/polybench-correlation-l03](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-correlation-l03-127b3fe5/meta/run-z25x225w/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-correlation-l03-127b3fe5/meta/run-z25x225w/backend/candidate-status.json) | s8 | s1 | 18,122 | 16,986 | 1,136 | 6.6879% |
| 41 | [rajaperf/reduce-sum](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_reduce-sum-c7209cc1/meta/run-cwbw4vqc/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_reduce-sum-c7209cc1/meta/run-cwbw4vqc/backend/candidate-status.json) | s8 | s4 | 3,257 | 3,057 | 200 | 6.5424% |
| 42 | [rajaperf/muladdsub](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_muladdsub-350a953b/meta/run-y6e5jwar/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_muladdsub-350a953b/meta/run-y6e5jwar/backend/candidate-status.json) | s8 | s4 | 15,641 | 14,689 | 952 | 6.4810% |
| 43 | [polybench/polybench-adi-l01](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-adi-l01-a1be4de9/meta/run-kgxzmdf7/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-adi-l01-a1be4de9/meta/run-kgxzmdf7/backend/candidate-status.json) | s2 | s1 | 184,490 | 174,093 | 10,397 | 5.9721% |
| 44 | [tsvc/tsvc-s114-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s114-l00-9cee7768/meta/run-dg9lqr7n/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s114-l00-9cee7768/meta/run-dg9lqr7n/backend/candidate-status.json) | s16 | s2 | 5,728 | 5,416 | 312 | 5.7607% |
| 45 | [rajaperf/first-diff](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_first-diff-62f6f81e/meta/run-vqodfs58/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_first-diff-62f6f81e/meta/run-vqodfs58/backend/candidate-status.json) | s8 | s4 | 9,510 | 9,019 | 491 | 5.4441% |
| 46 | [polybench/polybench-gramschmidt-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-gramschmidt-l00-67be4a8d/meta/run-sayakldl/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-gramschmidt-l00-67be4a8d/meta/run-sayakldl/backend/candidate-status.json) | s8 | s4 | 20,877 | 19,876 | 1,001 | 5.0362% |
| 47 | [polybench/polybench-mvt-l01](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-mvt-l01-7194602f/meta/run-nt__3zti/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-mvt-l01-7194602f/meta/run-nt__3zti/backend/candidate-status.json) | s8 | s1 | 113,179 | 108,235 | 4,944 | 4.5678% |
| 48 | [polybench/polybench-gemver-l01](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-gemver-l01-025f9229/meta/run-b4vpbkal/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-gemver-l01-025f9229/meta/run-b4vpbkal/backend/candidate-status.json) | s8 | s1 | 113,510 | 108,564 | 4,946 | 4.5558% |
| 49 | [tsvc/tsvc-s1351-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1351-l00-02a90d44/meta/run-7fer6d9y/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1351-l00-02a90d44/meta/run-7fer6d9y/backend/candidate-status.json) | s16 | s8 | 132,676 | 127,480 | 5,196 | 4.0759% |
| 50 | [tsvc/tsvc-s423-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s423-l00-8e6be173/meta/run-eugvq3mb/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s423-l00-8e6be173/meta/run-eugvq3mb/backend/candidate-status.json) | s16 | s8 | 111,099 | 107,055 | 4,044 | 3.7775% |
| 51 | [lcals/energy-calc-l02](.cache/wrong-predictions-20261021/spill/artifacts/lcals_energy-calc-l02-53eb21ea/meta/run-to0m6u_m/kernel.cpp) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/lcals_energy-calc-l02-53eb21ea/meta/run-to0m6u_m/backend/candidate-status.json) | s8 | s4 | 3,388 | 3,275 | 113 | 3.4504% |
| 52 | [tsvc/tsvc-s1232-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1232-l00-e402d643/meta/run-z42brtul/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1232-l00-e402d643/meta/run-z42brtul/backend/candidate-status.json) | s2 | s16 | 19,152 | 18,581 | 571 | 3.0730% |
| 53 | [tsvc/tsvc-s173-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s173-l00-48d51ecc/meta/run-_b3in5ge/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s173-l00-48d51ecc/meta/run-_b3in5ge/backend/candidate-status.json) | s16 | s4 | 59,268 | 57,554 | 1,714 | 2.9781% |
| 54 | [tsvc/tsvc-s174-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s174-l00-bd9fa068/meta/run-m44sl5fs/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s174-l00-bd9fa068/meta/run-m44sl5fs/backend/candidate-status.json) | s16 | s4 | 59,268 | 57,554 | 1,714 | 2.9781% |
| 55 | [polybench/polybench-symm-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-symm-l00-248585b3/meta/run-0xxx4sno/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-symm-l00-248585b3/meta/run-0xxx4sno/backend/candidate-status.json) | s2 | s1 | 183,103 | 177,811 | 5,292 | 2.9762% |
| 56 | [polybench/p32-jacobi-1d-imper-l01](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-jacobi-1d-imper-l01-37dcc1ba/meta/run-ccf0_x40/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-jacobi-1d-imper-l01-37dcc1ba/meta/run-ccf0_x40/backend/candidate-status.json) | s8 | s4 | 53,732 | 52,199 | 1,533 | 2.9368% |
| 57 | [polybench/polybench-2mm-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-2mm-l00-9cf36e64/meta/run-t_nto01i/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-2mm-l00-9cf36e64/meta/run-t_nto01i/backend/candidate-status.json) | s8 | s1 | 69,316 | 67,402 | 1,914 | 2.8397% |
| 58 | [polybench/p32-gemm-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-gemm-l00-ac3f2df9/meta/run-q0tfpgzy/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-gemm-l00-ac3f2df9/meta/run-q0tfpgzy/backend/candidate-status.json) | s8 | s2 | 69,281 | 67,394 | 1,887 | 2.8000% |
| 59 | [polybench/polybench-3mm-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-3mm-l00-8dbcfe1b/meta/run-axabopjq/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-3mm-l00-8dbcfe1b/meta/run-axabopjq/backend/candidate-status.json) | s8 | s1 | 69,206 | 67,392 | 1,814 | 2.6917% |
| 60 | [polybench/polybench-3mm-l01](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-3mm-l01-e1456f5d/meta/run-kz0fyh4a/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-3mm-l01-e1456f5d/meta/run-kz0fyh4a/backend/candidate-status.json) | s8 | s1 | 69,206 | 67,392 | 1,814 | 2.6917% |
| 61 | [tsvc/tsvc-s4113-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s4113-l00-25a1b22a/meta/run-7k8lbcel/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s4113-l00-25a1b22a/meta/run-7k8lbcel/backend/candidate-status.json) | s16 | s1 | 1,050,125 | 1,023,601 | 26,524 | 2.5912% |
| 62 | [lcals/init3](.cache/wrong-predictions-20261021/spill/artifacts/lcals_init3-3d272b8a/meta/run-ir0fxqgp/kernel.cpp) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/lcals_init3-3d272b8a/meta/run-ir0fxqgp/backend/candidate-status.json) | s8 | s2 | 2,784 | 2,714 | 70 | 2.5792% |
| 63 | [polybench/polybench-2mm-l01](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-2mm-l01-1406980f/meta/run-ebfuxxmn/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-2mm-l01-1406980f/meta/run-ebfuxxmn/backend/candidate-status.json) | s8 | s1 | 69,002 | 67,332 | 1,670 | 2.4802% |
| 64 | [polybench/polybench-3mm-l02](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-3mm-l02-f0259f1f/meta/run-t0017fy7/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-3mm-l02-f0259f1f/meta/run-t0017fy7/backend/candidate-status.json) | s8 | s1 | 69,002 | 67,332 | 1,670 | 2.4802% |
| 65 | [polybench/polybench-adi-l04](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-adi-l04-8b33d052/meta/run-wik4ea6q/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-adi-l04-8b33d052/meta/run-wik4ea6q/backend/candidate-status.json) | s8 | s2 | 8,350 | 8,164 | 186 | 2.2783% |
| 66 | [lcals/muladdsub](.cache/wrong-predictions-20261021/spill/artifacts/lcals_muladdsub-977367b6/meta/run-wdf1e1pf/kernel.cpp) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/lcals_muladdsub-977367b6/meta/run-wdf1e1pf/backend/candidate-status.json) | s8 | s2 | 2,767 | 2,708 | 59 | 2.1787% |
| 67 | [tsvc/tsvc-s2233-l01](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2233-l01-47053e9d/meta/run-ahrdqm1f/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2233-l01-47053e9d/meta/run-ahrdqm1f/backend/candidate-status.json) | s16 | s8 | 989 | 968 | 21 | 2.1694% |
| 68 | [polybench/polybench-doitgen-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-doitgen-l00-7a07cca4/meta/run-dlap1nw9/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-doitgen-l00-7a07cca4/meta/run-dlap1nw9/backend/candidate-status.json) | s8 | s1 | 2,756 | 2,698 | 58 | 2.1497% |
| 69 | [polybench/p32-gemver-l03](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-gemver-l03-ca7ea0a4/meta/run-xa43mf0k/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-gemver-l03-ca7ea0a4/meta/run-xa43mf0k/backend/candidate-status.json) | s8 | s4 | 22,288 | 21,846 | 442 | 2.0233% |
| 70 | [tsvc/tsvc-s274-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s274-l00-5dd5fc6d/meta/run-zvd8kqeo/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s274-l00-5dd5fc6d/meta/run-zvd8kqeo/backend/candidate-status.json) | s16 | s4 | 353,893 | 347,016 | 6,877 | 1.9818% |
| 71 | [tsvc/tsvc-s4121-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s4121-l00-6c622614/meta/run-55eepmta/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s4121-l00-6c622614/meta/run-55eepmta/backend/candidate-status.json) | s16 | s8 | 169,209 | 165,945 | 3,264 | 1.9669% |
| 72 | [tsvc/tsvc-s271-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s271-l00-2d3fed60/meta/run-usrybqop/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s271-l00-2d3fed60/meta/run-usrybqop/backend/candidate-status.json) | s16 | s8 | 169,175 | 165,991 | 3,184 | 1.9182% |
| 73 | [polybench/p32-gemver-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-gemver-l00-4fc51a44/meta/run-i_eaoyz4/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-gemver-l00-4fc51a44/meta/run-i_eaoyz4/backend/candidate-status.json) | s8 | s4 | 33,249 | 32,691 | 558 | 1.7069% |
| 74 | [polybench/polybench-gramschmidt-l03](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-gramschmidt-l03-49576383/meta/run-36xutvpu/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-gramschmidt-l03-49576383/meta/run-36xutvpu/backend/candidate-status.json) | s2 | s1 | 51,101 | 50,257 | 844 | 1.6794% |
| 75 | [tsvc/tsvc-s2711-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2711-l00-49cc1527/meta/run-xn1fbqi2/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2711-l00-49cc1527/meta/run-xn1fbqi2/backend/candidate-status.json) | s16 | s8 | 168,586 | 165,815 | 2,771 | 1.6711% |
| 76 | [polybench/p32-bicg-l01](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-bicg-l01-e0d83bc0/meta/run-35vtr4gx/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-bicg-l01-e0d83bc0/meta/run-35vtr4gx/backend/candidate-status.json) | s8 | s4 | 33,214 | 32,675 | 539 | 1.6496% |
| 77 | [tsvc/tsvc-s2712-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2712-l00-b9b14b9b/meta/run-asjt_246/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2712-l00-b9b14b9b/meta/run-asjt_246/backend/candidate-status.json) | s16 | s8 | 170,319 | 167,562 | 2,757 | 1.6454% |
| 78 | [rajaperf/eos](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_eos-a5c99505/meta/run-khyudd1f/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_eos-a5c99505/meta/run-khyudd1f/backend/candidate-status.json) | s4 | s2 | 24,716 | 24,325 | 391 | 1.6074% |
| 79 | [lcals/energy-calc-l00](.cache/wrong-predictions-20261021/spill/artifacts/lcals_energy-calc-l00-578547e0/meta/run-9d0saiir/kernel.cpp) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/lcals_energy-calc-l00-578547e0/meta/run-9d0saiir/backend/candidate-status.json) | s8 | s4 | 2,993 | 2,952 | 41 | 1.3889% |
| 80 | [rajaperf/triad](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_triad-74b1a1d1/meta/run-qr2c8q1x/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_triad-74b1a1d1/meta/run-qr2c8q1x/backend/candidate-status.json) | s8 | s4 | 6,735 | 6,646 | 89 | 1.3392% |
| 81 | [polybench/p421-gemm-l01](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-gemm-l01-192dbd1e/meta/run-ujbyhc8o/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-gemm-l01-192dbd1e/meta/run-ujbyhc8o/backend/candidate-status.json) | s8 | s4 | 7,189 | 7,100 | 89 | 1.2535% |
| 82 | [tsvc/tsvc-s1421-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1421-l00-bbe52dfd/meta/run-grhnc5df/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1421-l00-bbe52dfd/meta/run-grhnc5df/backend/candidate-status.json) | s16 | s8 | 57,945 | 57,269 | 676 | 1.1804% |
| 83 | [rajaperf/first-sum](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_first-sum-7312297a/meta/run-8113yili/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_first-sum-7312297a/meta/run-8113yili/backend/candidate-status.json) | s8 | s4 | 5,609 | 5,545 | 64 | 1.1542% |
| 84 | [tsvc/tsvc-s118-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s118-l00-fc4312b6/meta/run-i73dfmty/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s118-l00-fc4312b6/meta/run-i73dfmty/backend/candidate-status.json) | s16 | s1 | 6,139 | 6,069 | 70 | 1.1534% |
| 85 | [tsvc/tsvc-s2102-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2102-l00-71c9b926/meta/run-0wyfvv02/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2102-l00-71c9b926/meta/run-0wyfvv02/backend/candidate-status.json) | s16 | s1 | 5,580 | 5,517 | 63 | 1.1419% |
| 86 | [hpcc/stream-copy](.cache/wrong-predictions-20261021/spill/artifacts/hpcc_stream-copy-ad6615d9/meta/run-8ron5al_/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/hpcc_stream-copy-ad6615d9/meta/run-8ron5al_/backend/candidate-status.json) | s8 | s4 | 5,007 | 4,960 | 47 | 0.9476% |
| 87 | [polybench/polybench-correlation-l01](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-correlation-l01-226a26ff/meta/run-hiokhgsc/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-correlation-l01-226a26ff/meta/run-hiokhgsc/backend/candidate-status.json) | s8 | s4 | 13,852 | 13,743 | 109 | 0.7931% |
| 88 | [tsvc/tsvc-s443-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s443-l00-f507db71/meta/run-8fv9vhkx/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s443-l00-f507db71/meta/run-8fv9vhkx/backend/candidate-status.json) | s16 | s8 | 229,501 | 227,775 | 1,726 | 0.7578% |
| 89 | [rajaperf/add](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_add-0d156cf5/meta/run-8snmt6yq/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_add-0d156cf5/meta/run-8snmt6yq/backend/candidate-status.json) | s8 | s4 | 7,469 | 7,418 | 51 | 0.6875% |
| 90 | [tsvc/tsvc-s491-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s491-l00-10776da5/meta/run-z8p5heeh/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s491-l00-10776da5/meta/run-z8p5heeh/backend/candidate-status.json) | s16 | s4 | 633,661 | 629,679 | 3,982 | 0.6324% |
| 91 | [tsvc/tsvc-s4116-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s4116-l00-80467e9e/meta/run-bnbmdzfc/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s4116-l00-80467e9e/meta/run-bnbmdzfc/backend/candidate-status.json) | s16 | s8 | 2,443 | 2,431 | 12 | 0.4936% |
| 92 | [polybench/polybench-fdtd-2d-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-fdtd-2d-l00-c5d9d238/meta/run-0dh_v8j8/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-fdtd-2d-l00-c5d9d238/meta/run-0dh_v8j8/backend/candidate-status.json) | s8 | s2 | 3,512 | 3,499 | 13 | 0.3715% |
| 93 | [polybench/polybench-durbin-l02](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-durbin-l02-de927056/meta/run-ik6biogm/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-durbin-l02-de927056/meta/run-ik6biogm/backend/candidate-status.json) | s8 | s1 | 100,501 | 100,133 | 368 | 0.3675% |
| 94 | [tsvc/tsvc-s424-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s424-l00-db233916/meta/run-7a3v7ohk/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s424-l00-db233916/meta/run-7a3v7ohk/backend/candidate-status.json) | s16 | s4 | 120,235 | 119,906 | 329 | 0.2744% |
| 95 | [polybench/polybench-covariance-l02](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-covariance-l02-be853ecc/meta/run-8jb2kbpw/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-covariance-l02-be853ecc/meta/run-8jb2kbpw/backend/candidate-status.json) | s8 | s4 | 13,753 | 13,734 | 19 | 0.1383% |
| 96 | [rajaperf/trap-int](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_trap-int-0734d10c/meta/run-rykk3iuk/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_trap-int-0734d10c/meta/run-rykk3iuk/backend/candidate-status.json) | s8 | s4 | 15,158 | 15,143 | 15 | 0.0991% |
| 97 | [polybench/polybench-correlation-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-correlation-l00-4f2fc9b1/meta/run-3ofen3kw/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-correlation-l00-4f2fc9b1/meta/run-3ofen3kw/backend/candidate-status.json) | s8 | s4 | 13,773 | 13,767 | 6 | 0.0436% |
| 98 | [polybench/polybench-covariance-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-covariance-l00-fe2a359d/meta/run-lluf3t8g/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-covariance-l00-fe2a359d/meta/run-lluf3t8g/backend/candidate-status.json) | s8 | s4 | 13,773 | 13,767 | 6 | 0.0436% |
| 99 | [polybench/polybench-gramschmidt-l02](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-gramschmidt-l02-87e132e9/meta/run-twdwu_wf/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-gramschmidt-l02-87e132e9/meta/run-twdwu_wf/backend/candidate-status.json) | s8 | s2 | 41,509 | 41,504 | 5 | 0.0120% |
| 100 | [polybench/p421-floyd-warshall-full](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-floyd-warshall-full-e582b111/meta/run-bghg9_3i/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-floyd-warshall-full-e582b111/meta/run-bghg9_3i/backend/candidate-status.json) | s16 | s8 | 847,706 | 847,655 | 51 | 0.0060% |
| 101 | [tsvc/tsvc-s251-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s251-l00-4ce5a866/meta/run-__b6hg4k/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s251-l00-4ce5a866/meta/run-__b6hg4k/backend/candidate-status.json) | s16 | s8 | 194,988 | 194,978 | 10 | 0.0051% |

## 평가 제외 전체

제외 14개는 해결된 오예측으로 세지 않는다. 이번 replay에서 compile을 수행하지 않았으며 원본 입력 수집의 compile failure는 0개다.

| Benchmark | 상태 | 사유 |
| --- | --- | --- |
| [lcals/fir-inner](.cache/wrong-predictions-20261021/spill/artifacts/lcals_fir-inner-04446895/meta/run-x81_0n7v/kernel.cpp) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/lcals_fir-inner-04446895/meta/run-x81_0n7v/backend/candidate-status.json) | `backend-observation-unavailable` | selected_kernel:0:1:s8: cannot prove original-iteration mapping after IR optimization; selected_kernel:0:1:s16: cannot prove original-iteration mapping after IR optimization |
| [lcals/fir-outer](.cache/wrong-predictions-20261021/spill/artifacts/lcals_fir-outer-16dfa90e/meta/run-s9dsslxx/kernel.cpp) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/lcals_fir-outer-16dfa90e/meta/run-s9dsslxx/backend/candidate-status.json) | `backend-observation-unavailable` | selected_kernel:0:1:s8: cannot prove original-iteration mapping after IR optimization; selected_kernel:0:1:s16: cannot prove original-iteration mapping after IR optimization |
| [polybench/p32-adi-full](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-adi-full-2fd7f411/meta/run-3z0h7ivd/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-adi-full-2fd7f411/meta/run-3z0h7ivd/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/p32-fdtd-2d-full](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-fdtd-2d-full-85f4b50e/meta/run-7wcb50rk/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-fdtd-2d-full-85f4b50e/meta/run-7wcb50rk/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/p32-jacobi-1d-imper-full](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-jacobi-1d-imper-full-e61c1c36/meta/run-xmb6ooup/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-jacobi-1d-imper-full-e61c1c36/meta/run-xmb6ooup/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/p32-jacobi-2d-imper-full](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-jacobi-2d-imper-full-67087142/meta/run-9daavlo7/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-jacobi-2d-imper-full-67087142/meta/run-9daavlo7/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/p421-fdtd-2d-full](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-fdtd-2d-full-3b80f0fa/meta/run-kdhk20ez/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-fdtd-2d-full-3b80f0fa/meta/run-kdhk20ez/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/p421-heat-3d-full](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-heat-3d-full-422ad5f5/meta/run-btv90s2b/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-heat-3d-full-422ad5f5/meta/run-btv90s2b/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/p421-jacobi-1d-full](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-jacobi-1d-full-cb6eb4ac/meta/run-xo91si8t/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-jacobi-1d-full-cb6eb4ac/meta/run-xo91si8t/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/p421-jacobi-1d-outer](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-jacobi-1d-outer-c96619a9/meta/run-ml8p1pol/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-jacobi-1d-outer-c96619a9/meta/run-ml8p1pol/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/p421-jacobi-2d-full](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-jacobi-2d-full-ab8ba81c/meta/run-n8rahf5e/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-jacobi-2d-full-ab8ba81c/meta/run-n8rahf5e/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/polybench-reg_detect-l02](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-reg_detect-l02-526fd6c3/meta/run-ex6p2unp/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-reg_detect-l02-526fd6c3/meta/run-ex6p2unp/backend/candidate-status.json) | `backend-observation-unavailable` | selected_kernel:0:1:s4: cannot prove original-iteration mapping after IR optimization; selected_kernel:0:1:s8: cannot prove original-iteration mapping after IR optimization; selected_kernel:0:1:s16: cannot prove original-iteration mapping after IR optimization |
| [tsvc/tsvc-s31111-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s31111-l00-48dde2b5/meta/run-cg2iasrg/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s31111-l00-48dde2b5/meta/run-cg2iasrg/backend/candidate-status.json) | `backend-observation-unavailable` | selected_kernel:0:1:s2: cannot prove original-iteration mapping after IR optimization; selected_kernel:0:1:s4: cannot prove original-iteration mapping after IR optimization |
| [tsvc/tsvc-s332-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s332-l00-c4d65a47/meta/run-8apgresi/kernel.c) · [입력 후보](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s332-l00-c4d65a47/meta/run-8apgresi/backend/candidate-status.json) | `backend-observation-unavailable` | scalable s1/s2/s4/s8/s16: candidate is not an innermost single-latch-exit loop (원본 status에는 현재 scope에서 제거된 fixed 후보의 오류도 함께 기록됨) |

## 검증·재현

- 현재 코드로 calibrated profile을 replay하고 cached 계산과 일반 계산의 939개 후보 비용 및 선택이 일치함을 evaluator가 검증했다.
- 현재 extractor로 analytics/MIR에서 939개 후보 facts를 다시 만들고 canonical JSON으로 일치를 확인했다. 주소 tuple/list의 직렬화 차이는 동일한 값으로 비교했다.
- 203개 ID·DB 소스·901개 측정값·평가 VF·정오답·유리수 regret·정렬·원인별 표를 검증했다. 입력 hash 1,143개와 현재 평가 소스 hash를 확인했다.
- 상세 corpus는 기존 multiline switch 정규화본을 사용한다. 측정값과 비용 기록을 수정하지 않았다.

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate-window-cost \
  --features .cache/scalable-unit-half-segment3-20261021/results.json \
  --baseline .cache/wrong-predictions-20261021/spill/summary.json \
  --corpus .cache/stridedload-reeval-20261021/corpus/summary-normalized.json \
  --strided .cache/scalable-strided-comparison-20261021/results.json \
  --previous .cache/vf-scaling-verification-20261021/results.json \
  --parameters utils/vplan-tools/memory-window-calibrated.json \
  --output-dir <new-empty-output-dir>
```

원본 생성 보조 스크립트: [분석](.cache/wrong-predictions-memcost-20261022/analyze.py), [facts 재검증](.cache/wrong-predictions-memcost-20261022/verify-facts.py), [문서 생성](.cache/wrong-predictions-memcost-20261022/write-documents.py). 문서 생성 스크립트는 GOAL.md도 다시 쓰므로 수동 편집 후에는 덮어쓰지 않도록 주의한다. `.cache/`는 Git에서 추적하지 않는다. 다른 환경에서 재현하려면 DB와 참조한 관측·corpus·features를 함께 옮기고 절대경로를 맞춰야 한다.
