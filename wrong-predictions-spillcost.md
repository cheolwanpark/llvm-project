# SpillCost 오예측 평가

평가일: 2026-10-21 (Asia/Seoul). 현재 `search-dataset.sqlite` 전체 203개 benchmark, 901개 측정을 사용했다. 기존 split 표시는 필터로 사용하지 않았다.

전체 **203개** 중 **188개 평가 가능**, **81개 정답**, **107개 오예측**, **15개 제외**다. 정확도 **43.0851%**, 평균 regret **7.2806%**, P95 **32.8053%**, 최대 regret **167.2611%**다. 입력 수집의 컴파일 실패는 **0개**다.

## 모델과 입력

- DB SHA-256: `3d5e09ed2346be109a887192c36422073a4a6650b0f38cc29765d72ad063ff37`.
- Probe compiler SHA-256: `9c455960b6753d54beac15fa564c458a1bcc73ef4caa445ffb805fab96096ff9`. 세 모델에서 같은 compiler를 사용했다.
- 타깃은 XiangShan v2, RISC-V VLEN=128, IC=1, vector epilogue 없음이다. DB의 소스와 컴파일 옵션으로 비용을 수집했다. 새 runtime 측정이나 계수 fitting은 하지 않았다.
- 모델은 `llvm-backend-spill-v1`이다. `8de5b413361acd1ab259e1ca5c20affaffe75d12`의 도구 소스를 별도 경로에 복원해 평가했다.
- LLVM의 spill 추정 항을 post-RA 관측 spill/reload 수 × TTI 단가로 교체한다. 검증된 iteration ratio로 정규화하고 quarter-unit 포화 연산을 적용한다. 비용은 모델 단위이며 실측 cycles가 아니다.
- 합법적인 후보 하나라도 필요한 backend 관측을 얻지 못하면 benchmark 전체를 제외한다. 나머지 scalar·tail·후보 순서·동률 정책은 유지한다.
- [평가 JSON](.cache/wrong-predictions-20261021/spill/summary.json), [실행 소스 hash](.cache/wrong-predictions-20261021/spill-source/source-provenance.json).

```text
Qraw = Σ group × (observed_spills × TTI_spill_unit + observed_reloads × TTI_reload_unit)
Qbackend = saturate(trunc(Qraw / iteration_ratio))
Qeffective = add_sat(add_sat(Qprecomputed, Qvector_region), Qbackend)
```

## 판정 기준

- 최적 VF는 각 evaluator가 정한 compiler scalable 후보 중 DB cycles가 최소인 VF다. DB에만 있는 VF는 제외하며, 후보 측정 누락·fixed/scalar 선택 등은 제외 사유로 보고한다.
- 측정 동률에서는 작은 VF를 정답으로 삼는다. `s1`도 scalable vector이며 scalar `f1`과 다르다.
- `regret = 선택 cycles / 최소 cycles - 1`. 표는 정확한 유리수 regret 내림차순, 동률은 benchmark ID 오름차순이다. cycles는 workload 전체의 DB 측정값이다.

## 같은 데이터셋의 모델 비교

| 집합 / 모델 | 평가 수 | 정답 | 오예측 | 정확도 | 평균 regret | P95 | 최대 regret |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 전체 / Baseline | 191 | 69 | 122 | 36.1257% | 8.9375% | 35.9612% | 167.2611% |
| 전체 / SpillCost | 188 | 81 | 107 | 43.0851% | 7.2806% | 32.8053% | 167.2611% |
| 전체 / Strided tuned | 188 | 83 | 105 | 44.1489% | 6.7520% | 30.0131% | 167.2611% |
| 공통 187개 / Baseline | 187 | 69 | 118 | 36.8984% | 8.8737% | 36.3301% | 167.2611% |
| 공통 187개 / SpillCost | 187 | 81 | 106 | 43.3155% | 7.2077% | 32.8082% | 167.2611% |
| 공통 187개 / Strided tuned | 187 | 83 | 104 | 44.3850% | 6.6763% | 30.1410% | 167.2611% |

공통 187개는 세 모델 모두 평가 가능하고 비교에 사용한 측정 VF 집합·cycles도 같은 항목이다. 전체 지표의 평가 범위는 모델별로 다르므로 개선 판단에는 공통 집합을 함께 본다.

관련 문서: [Baseline](wrong-predictions-baseline.md), [SpillCost](wrong-predictions-spillcost.md), [Strided-load](wrong-predictions-stridedload.md).

## 일반 LLVM과 선택 일치

일반 LLVM direct compile과 비교 가능한 189개 중 VF 일치 164개, VF·IC·epilogue·emission 전체 선택 일치 164개다. 비교 불가능 14개는 일치율 분모에서 제외했다.

| Benchmark | 모델 VF | 일반 LLVM VF | 전체 선택 일치 |
| --- | --- | --- | --- |
| lcals/energy-calc-l01 | s4 | s8 | 아니오 |
| lcals/energy-calc-l02 | s8 | s4 | 아니오 |
| lcals/energy-calc-l04 | s2 | s4 | 아니오 |
| lcals/energy-calc-l05 | s4 | s8 | 아니오 |
| polybench/p32-gesummv-l00 | s4 | s8 | 아니오 |
| polybench/polybench-adi-l03 | s4 | s8 | 아니오 |
| polybench/polybench-fdtd-2d-l03 | s8 | s4 | 아니오 |
| polybench/polybench-symm-l00 | s8 | s4 | 아니오 |
| tsvc/tsvc-s111-l00 | s16 | s8 | 아니오 |
| tsvc/tsvc-s1111-l00 | f16 | s8 | 아니오 |
| tsvc/tsvc-s1232-l00 | s16 | s8 | 아니오 |
| tsvc/tsvc-s124-l00 | s8 | s16 | 아니오 |
| tsvc/tsvc-s1279-l00 | s8 | s16 | 아니오 |
| tsvc/tsvc-s128-l00 | s16 | s8 | 아니오 |
| tsvc/tsvc-s2275-l00 | s16 | s8 | 아니오 |
| tsvc/tsvc-s233-l01 | s16 | s8 | 아니오 |
| tsvc/tsvc-s243-l00 | s8 | s16 | 아니오 |
| tsvc/tsvc-s253-l00 | s8 | s16 | 아니오 |
| tsvc/tsvc-s257-l00 | s16 | s8 | 아니오 |
| tsvc/tsvc-s2710-l00 | s8 | s16 | 아니오 |
| tsvc/tsvc-s272-l00 | s8 | s16 | 아니오 |
| tsvc/tsvc-s273-l00 | s8 | s16 | 아니오 |
| tsvc/tsvc-s276-l00 | s4 | s8 | 아니오 |
| tsvc/tsvc-s4115-l00 | s8 | s16 | 아니오 |
| tsvc/tsvc-s441-l00 | s8 | s16 | 아니오 |

## Baseline 대비 변화

공통 평가 가능 187개에서 regret 개선 18개, 악화 6개, 동일 163개다.

| Benchmark | Baseline VF → 현재 VF | Baseline regret | 현재 regret |
| --- | --- | ---: | ---: |
| tsvc/tsvc-s253-l00 | s16 → s8 | 67.4358% | 0.0000% |
| tsvc/tsvc-s2710-l00 | s16 → s8 | 57.9153% | 0.0000% |
| tsvc/tsvc-s276-l00 | s8 → s4 | 44.0496% | 0.0000% |
| tsvc/tsvc-s243-l00 | s16 → s8 | 39.9875% | 0.0000% |
| tsvc/tsvc-s272-l00 | s16 → s8 | 37.4092% | 0.0000% |
| tsvc/tsvc-s1279-l00 | s16 → s8 | 28.4675% | 0.0000% |
| polybench/p32-gesummv-l00 | s8 → s4 | 22.4170% | 0.0000% |
| tsvc/tsvc-s124-l00 | s16 → s8 | 16.6791% | 0.0000% |
| polybench/polybench-fdtd-2d-l03 | s4 → s8 | 28.3585% | 14.1690% |
| tsvc/tsvc-s441-l00 | s16 → s8 | 7.5977% | 0.0000% |
| lcals/energy-calc-l01 | s8 → s4 | 7.2642% | 0.0000% |
| polybench/polybench-adi-l03 | s8 → s4 | 7.1756% | 0.0000% |
| tsvc/tsvc-s4115-l00 | s16 → s8 | 6.4329% | 0.0000% |
| tsvc/tsvc-s233-l01 | s8 → s16 | 22.3921% | 17.7222% |
| lcals/energy-calc-l05 | s8 → s4 | 4.5519% | 0.0000% |
| tsvc/tsvc-s257-l00 | s8 → s16 | 20.0016% | 15.9915% |
| tsvc/tsvc-s1232-l00 | s8 → s16 | 3.7834% | 0.0000% |
| tsvc/tsvc-s2275-l00 | s8 → s16 | 7.8736% | 5.2797% |
| tsvc/tsvc-s273-l00 | s16 → s8 | 9.2495% | 10.9168% |
| lcals/energy-calc-l02 | s4 → s8 | 0.0000% | 3.4504% |
| tsvc/tsvc-s111-l00 | s8 → s16 | 50.5229% | 55.0636% |
| tsvc/tsvc-s128-l00 | s8 → s16 | 36.8835% | 44.3187% |
| polybench/polybench-symm-l00 | s4 → s8 | 19.8199% | 33.5058% |
| lcals/energy-calc-l04 | s4 → s2 | 0.0000% | 34.3167% |

신규 제외 4개: `lcals/fir-inner`, `lcals/fir-outer`, `polybench/polybench-reg_detect-l02`, `tsvc/tsvc-s332-l00`.

신규 평가 가능 1개: `tsvc/tsvc-s127-l00`.

## 오예측 전체

Benchmark는 DB에서 추출한 소스에 연결된다. 후보 비용 링크는 원본 후보별 cost와 관측을 제공한다.

| 순위 | Benchmark / 후보 비용 | 선택 VF | 최적 VF | 선택 cycles | 최소 cycles | 초과 cycles | regret |
| ---: | --- | --- | --- | ---: | ---: | ---: | ---: |
| 1 | [tsvc/tsvc-s351-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s351-l00-be55ca3d/meta/run-4iyoywax/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s351-l00-be55ca3d/meta/run-4iyoywax/backend/candidate-status.json) | s2 | s4 | 1,094,247 | 409,430 | 684,817 | 167.2611% |
| 2 | [tsvc/tsvc-s353-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s353-l00-3fc028fb/meta/run-w5f9a5g9/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s353-l00-3fc028fb/meta/run-w5f9a5g9/backend/candidate-status.json) | s2 | s16 | 1,548,929 | 817,807 | 731,122 | 89.4003% |
| 3 | [tsvc/tsvc-s111-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s111-l00-90373715/meta/run-or3hk3i9/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s111-l00-90373715/meta/run-or3hk3i9/backend/candidate-status.json) | s16 | s2 | 384,795 | 248,153 | 136,642 | 55.0636% |
| 4 | [tsvc/tsvc-s128-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s128-l00-28527a6c/meta/run-qcw7ivd0/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s128-l00-28527a6c/meta/run-qcw7ivd0/backend/candidate-status.json) | s16 | s2 | 409,344 | 283,639 | 125,705 | 44.3187% |
| 5 | [tsvc/tsvc-s2244-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2244-l00-d85baaea/meta/run-ufpdy3jz/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2244-l00-d85baaea/meta/run-ufpdy3jz/backend/candidate-status.json) | s16 | s8 | 254,429 | 182,149 | 72,280 | 39.6818% |
| 6 | [polybench/p32-jacobi-1d-imper-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-jacobi-1d-imper-l00-e35be639/meta/run-8htg62fp/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-jacobi-1d-imper-l00-e35be639/meta/run-8htg62fp/backend/candidate-status.json) | s8 | s4 | 134,361 | 99,498 | 34,863 | 35.0389% |
| 7 | [lcals/energy-calc-l04](.cache/wrong-predictions-20261021/spill/artifacts/lcals_energy-calc-l04-9d0673bd/meta/run-45p0f2qz/kernel.cpp) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/lcals_energy-calc-l04-9d0673bd/meta/run-45p0f2qz/backend/candidate-status.json) | s2 | s4 | 12,157 | 9,051 | 3,106 | 34.3167% |
| 8 | [polybench/polybench-symm-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-symm-l00-248585b3/meta/run-0xxx4sno/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-symm-l00-248585b3/meta/run-0xxx4sno/backend/candidate-status.json) | s8 | s1 | 237,388 | 177,811 | 59,577 | 33.5058% |
| 9 | [polybench/p421-jacobi-1d-l01](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-jacobi-1d-l01-4aae641c/meta/run-0sr1oy5c/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-jacobi-1d-l01-4aae641c/meta/run-0sr1oy5c/backend/candidate-status.json) | s8 | s4 | 25,107 | 18,891 | 6,216 | 32.9046% |
| 10 | [tsvc/tsvc-s252-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s252-l00-87217f91/meta/run-4honkdjw/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s252-l00-87217f91/meta/run-4honkdjw/backend/candidate-status.json) | s16 | s4 | 212,418 | 159,922 | 52,496 | 32.8260% |
| 11 | [tsvc/tsvc-s471-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s471-l00-51169cb6/meta/run-cy8ei_zc/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s471-l00-51169cb6/meta/run-cy8ei_zc/backend/candidate-status.json) | s16 | s8 | 349,458 | 263,212 | 86,246 | 32.7667% |
| 12 | [tsvc/tsvc-s152-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s152-l00-b083be54/meta/run-94ggxvkr/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s152-l00-b083be54/meta/run-94ggxvkr/backend/candidate-status.json) | s16 | s8 | 333,909 | 255,070 | 78,839 | 30.9088% |
| 13 | [tsvc/tsvc-s255-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s255-l00-0ec3afcf/meta/run-mqd4biov/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s255-l00-0ec3afcf/meta/run-mqd4biov/backend/candidate-status.json) | s16 | s8 | 268,225 | 208,980 | 59,245 | 28.3496% |
| 14 | [polybench/polybench-jacobi-2d-imper-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-jacobi-2d-imper-l00-0f779552/meta/run-us4uj462/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-jacobi-2d-imper-l00-0f779552/meta/run-us4uj462/backend/candidate-status.json) | s8 | s4 | 15,596 | 12,411 | 3,185 | 25.6627% |
| 15 | [polybench/p421-jacobi-1d-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-jacobi-1d-l00-9ab66748/meta/run-1jp3899_/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-jacobi-1d-l00-9ab66748/meta/run-1jp3899_/backend/candidate-status.json) | s8 | s2 | 25,498 | 20,336 | 5,162 | 25.3836% |
| 16 | [tsvc/tsvc-s1281-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1281-l00-a26e8495/meta/run-fncz8b2s/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1281-l00-a26e8495/meta/run-fncz8b2s/backend/candidate-status.json) | s16 | s8 | 393,157 | 313,722 | 79,435 | 25.3202% |
| 17 | [tsvc/tsvc-s2101-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2101-l00-5bf538b9/meta/run-rxezzsgz/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2101-l00-5bf538b9/meta/run-rxezzsgz/backend/candidate-status.json) | s8 | s2 | 13,293 | 10,683 | 2,610 | 24.4313% |
| 18 | [lcals/first-diff](.cache/wrong-predictions-20261021/spill/artifacts/lcals_first-diff-1e964f79/meta/run-l9zgwwij/kernel.cpp) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/lcals_first-diff-1e964f79/meta/run-l9zgwwij/backend/candidate-status.json) | s8 | s4 | 1,606 | 1,322 | 284 | 21.4826% |
| 19 | [polybench/polybench-adi-l01](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-adi-l01-a1be4de9/meta/run-kgxzmdf7/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-adi-l01-a1be4de9/meta/run-kgxzmdf7/backend/candidate-status.json) | s8 | s1 | 211,014 | 174,093 | 36,921 | 21.2076% |
| 20 | [tsvc/tsvc-s331-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s331-l00-910994c5/meta/run-woz71fup/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s331-l00-910994c5/meta/run-woz71fup/backend/candidate-status.json) | s16 | s8 | 64,160 | 52,949 | 11,211 | 21.1732% |
| 21 | [tsvc/tsvc-s1251-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1251-l00-cc7e7448/meta/run-fe35tt80/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1251-l00-cc7e7448/meta/run-fe35tt80/backend/candidate-status.json) | s16 | s8 | 380,187 | 313,966 | 66,221 | 21.0918% |
| 22 | [polybench/p32-atax-l02](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-atax-l02-5a3cb64a/meta/run-yjbz39en/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-atax-l02-5a3cb64a/meta/run-yjbz39en/backend/candidate-status.json) | s8 | s2 | 23,984 | 19,813 | 4,171 | 21.0518% |
| 23 | [tsvc/tsvc-s127-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s127-l00-05409684/meta/run-qnz24auh/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s127-l00-05409684/meta/run-qnz24auh/backend/candidate-status.json) | s8 | s16 | 378,206 | 312,810 | 65,396 | 20.9060% |
| 24 | [rajaperf/dot](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_dot-e736b8f0/meta/run-e1f0zwwc/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_dot-e736b8f0/meta/run-e1f0zwwc/backend/candidate-status.json) | s8 | s2 | 6,324 | 5,232 | 1,092 | 20.8716% |
| 25 | [tsvc/tsvc-s293-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s293-l00-7a431fd2/meta/run-klh0nd9k/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s293-l00-7a431fd2/meta/run-klh0nd9k/backend/candidate-status.json) | s16 | s8 | 57,167 | 47,911 | 9,256 | 19.3192% |
| 26 | [rajaperf/init3](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_init3-95a32e1a/meta/run-_a0979tk/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_init3-95a32e1a/meta/run-_a0979tk/backend/candidate-status.json) | s8 | s4 | 17,207 | 14,424 | 2,783 | 19.2942% |
| 27 | [tsvc/tsvc-s233-l01](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s233-l01-6756cfda/meta/run-wfoj9ukb/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s233-l01-6756cfda/meta/run-wfoj9ukb/backend/candidate-status.json) | s16 | s2 | 14,016 | 11,906 | 2,110 | 17.7222% |
| 28 | [polybench/p421-atax-l01](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-atax-l01-fb8f6463/meta/run-rye4n0ta/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-atax-l01-fb8f6463/meta/run-rye4n0ta/backend/candidate-status.json) | s8 | s4 | 12,476 | 10,599 | 1,877 | 17.7092% |
| 29 | [polybench/p32-mvt-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-mvt-l00-a2db5bae/meta/run-he1ycyv_/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-mvt-l00-a2db5bae/meta/run-he1ycyv_/backend/candidate-status.json) | s8 | s2 | 23,787 | 20,246 | 3,541 | 17.4899% |
| 30 | [lcals/energy-calc-l03](.cache/wrong-predictions-20261021/spill/artifacts/lcals_energy-calc-l03-5a111bb6/meta/run-xwivyynf/kernel.cpp) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/lcals_energy-calc-l03-5a111bb6/meta/run-xwivyynf/backend/candidate-status.json) | s8 | s4 | 1,647 | 1,409 | 238 | 16.8914% |
| 31 | [tsvc/tsvc-s257-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s257-l00-9897e012/meta/run-6wg35ene/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s257-l00-9897e012/meta/run-6wg35ene/backend/candidate-status.json) | s16 | s2 | 14,144 | 12,194 | 1,950 | 15.9915% |
| 32 | [tsvc/tsvc-s3251-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s3251-l00-66539c1d/meta/run-ee5vy7ga/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s3251-l00-66539c1d/meta/run-ee5vy7ga/backend/candidate-status.json) | s16 | s8 | 414,743 | 358,654 | 56,089 | 15.6387% |
| 33 | [lcals/pressure-calc-l01](.cache/wrong-predictions-20261021/spill/artifacts/lcals_pressure-calc-l01-aa0a9cb1/meta/run-1n7l50un/kernel.cpp) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/lcals_pressure-calc-l01-aa0a9cb1/meta/run-1n7l50un/backend/candidate-status.json) | s8 | s2 | 2,993 | 2,610 | 383 | 14.6743% |
| 34 | [polybench/p32-atax-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-atax-l00-671335a6/meta/run-3p_u09o4/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-atax-l00-671335a6/meta/run-3p_u09o4/backend/candidate-status.json) | s8 | s1 | 14,462 | 12,626 | 1,836 | 14.5414% |
| 35 | [polybench/p32-bicg-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-bicg-l00-68d57011/meta/run-k4j62mds/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-bicg-l00-68d57011/meta/run-k4j62mds/backend/candidate-status.json) | s8 | s1 | 14,462 | 12,626 | 1,836 | 14.5414% |
| 36 | [tsvc/tsvc-s176-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s176-l00-a186d0cf/meta/run-ycrutrzk/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s176-l00-a186d0cf/meta/run-ycrutrzk/backend/candidate-status.json) | s16 | s4 | 49,181 | 42,984 | 6,197 | 14.4170% |
| 37 | [rajaperf/gen-lin-recur-reverse](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_gen-lin-recur-reverse-52b65c3b/meta/run-h4cg6u1c/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_gen-lin-recur-reverse-52b65c3b/meta/run-h4cg6u1c/backend/candidate-status.json) | s8 | s4 | 14,459 | 12,650 | 1,809 | 14.3004% |
| 38 | [polybench/polybench-fdtd-2d-l03](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-fdtd-2d-l03-b8f160c0/meta/run-n4ycir6d/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-fdtd-2d-l03-b8f160c0/meta/run-n4ycir6d/backend/candidate-status.json) | s8 | s2 | 16,776 | 14,694 | 2,082 | 14.1690% |
| 39 | [rajaperf/pi-reduce](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_pi-reduce-76f86157/meta/run-_i0oh96e/kernel.cpp) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_pi-reduce-76f86157/meta/run-_i0oh96e/backend/candidate-status.json) | s8 | s4 | 8,374 | 7,368 | 1,006 | 13.6536% |
| 40 | [tsvc/tsvc-s171-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s171-l00-21a03b56/meta/run-8ycjetq3/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s171-l00-21a03b56/meta/run-8ycjetq3/backend/candidate-status.json) | s16 | s4 | 112,967 | 100,680 | 12,287 | 12.2040% |
| 41 | [tsvc/tsvc-s172-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s172-l00-c3a4cfce/meta/run-bhlj5g51/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s172-l00-c3a4cfce/meta/run-bhlj5g51/backend/candidate-status.json) | s16 | s4 | 112,967 | 100,680 | 12,287 | 12.2040% |
| 42 | [tsvc/tsvc-s119-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s119-l00-7c5e355c/meta/run-1xv6r1l1/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s119-l00-7c5e355c/meta/run-1xv6r1l1/backend/candidate-status.json) | s16 | s8 | 1,068 | 960 | 108 | 11.2500% |
| 43 | [tsvc/tsvc-s273-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s273-l00-99d6486e/meta/run-4uv6q55r/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s273-l00-99d6486e/meta/run-4uv6q55r/backend/candidate-status.json) | s8 | s4 | 438,463 | 395,308 | 43,155 | 10.9168% |
| 44 | [rajaperf/gen-lin-recur-forward](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_gen-lin-recur-forward-2d89df0b/meta/run-688o7436/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_gen-lin-recur-forward-2d89df0b/meta/run-688o7436/backend/candidate-status.json) | s8 | s4 | 13,744 | 12,425 | 1,319 | 10.6157% |
| 45 | [polybench/polybench-correlation-l02](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-correlation-l02-a2134135/meta/run-jnob0_uq/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-correlation-l02-a2134135/meta/run-jnob0_uq/backend/candidate-status.json) | s8 | s4 | 11,011 | 9,967 | 1,044 | 10.4746% |
| 46 | [tsvc/tsvc-s151-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s151-l00-5e5365d8/meta/run-6n8pnnew/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s151-l00-5e5365d8/meta/run-6n8pnnew/backend/candidate-status.json) | s16 | s8 | 115,304 | 104,679 | 10,625 | 10.1501% |
| 47 | [tsvc/tsvc-s1119-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1119-l00-4f9ad8fa/meta/run-audhod81/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1119-l00-4f9ad8fa/meta/run-audhod81/backend/candidate-status.json) | s16 | s4 | 1,106 | 1,025 | 81 | 7.9024% |
| 48 | [polybench/polybench-gramschmidt-l03](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-gramschmidt-l03-49576383/meta/run-36xutvpu/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-gramschmidt-l03-49576383/meta/run-36xutvpu/backend/candidate-status.json) | s8 | s1 | 53,685 | 50,257 | 3,428 | 6.8209% |
| 49 | [polybench/polybench-correlation-l03](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-correlation-l03-127b3fe5/meta/run-z25x225w/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-correlation-l03-127b3fe5/meta/run-z25x225w/backend/candidate-status.json) | s8 | s1 | 18,122 | 16,986 | 1,136 | 6.6879% |
| 50 | [rajaperf/reduce-sum](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_reduce-sum-c7209cc1/meta/run-cwbw4vqc/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_reduce-sum-c7209cc1/meta/run-cwbw4vqc/backend/candidate-status.json) | s8 | s4 | 3,257 | 3,057 | 200 | 6.5424% |
| 51 | [rajaperf/muladdsub](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_muladdsub-350a953b/meta/run-y6e5jwar/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_muladdsub-350a953b/meta/run-y6e5jwar/backend/candidate-status.json) | s8 | s4 | 15,641 | 14,689 | 952 | 6.4810% |
| 52 | [tsvc/tsvc-s114-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s114-l00-9cee7768/meta/run-dg9lqr7n/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s114-l00-9cee7768/meta/run-dg9lqr7n/backend/candidate-status.json) | s16 | s2 | 5,728 | 5,416 | 312 | 5.7607% |
| 53 | [rajaperf/first-diff](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_first-diff-62f6f81e/meta/run-vqodfs58/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_first-diff-62f6f81e/meta/run-vqodfs58/backend/candidate-status.json) | s8 | s4 | 9,510 | 9,019 | 491 | 5.4441% |
| 54 | [tsvc/tsvc-s2275-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2275-l00-18913cc7/meta/run-w4_0m73f/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2275-l00-18913cc7/meta/run-w4_0m73f/backend/candidate-status.json) | s16 | s2 | 21,755 | 20,664 | 1,091 | 5.2797% |
| 55 | [polybench/polybench-gramschmidt-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-gramschmidt-l00-67be4a8d/meta/run-sayakldl/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-gramschmidt-l00-67be4a8d/meta/run-sayakldl/backend/candidate-status.json) | s8 | s4 | 20,877 | 19,876 | 1,001 | 5.0362% |
| 56 | [polybench/polybench-mvt-l01](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-mvt-l01-7194602f/meta/run-nt__3zti/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-mvt-l01-7194602f/meta/run-nt__3zti/backend/candidate-status.json) | s8 | s1 | 113,179 | 108,235 | 4,944 | 4.5678% |
| 57 | [polybench/polybench-gemver-l01](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-gemver-l01-025f9229/meta/run-b4vpbkal/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-gemver-l01-025f9229/meta/run-b4vpbkal/backend/candidate-status.json) | s8 | s1 | 113,510 | 108,564 | 4,946 | 4.5558% |
| 58 | [tsvc/tsvc-s1351-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1351-l00-02a90d44/meta/run-7fer6d9y/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1351-l00-02a90d44/meta/run-7fer6d9y/backend/candidate-status.json) | s16 | s8 | 132,676 | 127,480 | 5,196 | 4.0759% |
| 59 | [tsvc/tsvc-s423-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s423-l00-8e6be173/meta/run-eugvq3mb/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s423-l00-8e6be173/meta/run-eugvq3mb/backend/candidate-status.json) | s16 | s8 | 111,099 | 107,055 | 4,044 | 3.7775% |
| 60 | [lcals/energy-calc-l02](.cache/wrong-predictions-20261021/spill/artifacts/lcals_energy-calc-l02-53eb21ea/meta/run-to0m6u_m/kernel.cpp) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/lcals_energy-calc-l02-53eb21ea/meta/run-to0m6u_m/backend/candidate-status.json) | s8 | s4 | 3,388 | 3,275 | 113 | 3.4504% |
| 61 | [tsvc/tsvc-s173-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s173-l00-48d51ecc/meta/run-_b3in5ge/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s173-l00-48d51ecc/meta/run-_b3in5ge/backend/candidate-status.json) | s16 | s4 | 59,268 | 57,554 | 1,714 | 2.9781% |
| 62 | [tsvc/tsvc-s174-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s174-l00-bd9fa068/meta/run-m44sl5fs/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s174-l00-bd9fa068/meta/run-m44sl5fs/backend/candidate-status.json) | s16 | s4 | 59,268 | 57,554 | 1,714 | 2.9781% |
| 63 | [polybench/p32-jacobi-1d-imper-l01](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-jacobi-1d-imper-l01-37dcc1ba/meta/run-ccf0_x40/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-jacobi-1d-imper-l01-37dcc1ba/meta/run-ccf0_x40/backend/candidate-status.json) | s8 | s4 | 53,732 | 52,199 | 1,533 | 2.9368% |
| 64 | [polybench/polybench-2mm-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-2mm-l00-9cf36e64/meta/run-t_nto01i/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-2mm-l00-9cf36e64/meta/run-t_nto01i/backend/candidate-status.json) | s8 | s1 | 69,316 | 67,402 | 1,914 | 2.8397% |
| 65 | [polybench/p32-gemm-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-gemm-l00-ac3f2df9/meta/run-q0tfpgzy/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-gemm-l00-ac3f2df9/meta/run-q0tfpgzy/backend/candidate-status.json) | s8 | s2 | 69,281 | 67,394 | 1,887 | 2.8000% |
| 66 | [polybench/polybench-3mm-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-3mm-l00-8dbcfe1b/meta/run-axabopjq/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-3mm-l00-8dbcfe1b/meta/run-axabopjq/backend/candidate-status.json) | s8 | s1 | 69,206 | 67,392 | 1,814 | 2.6917% |
| 67 | [polybench/polybench-3mm-l01](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-3mm-l01-e1456f5d/meta/run-kz0fyh4a/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-3mm-l01-e1456f5d/meta/run-kz0fyh4a/backend/candidate-status.json) | s8 | s1 | 69,206 | 67,392 | 1,814 | 2.6917% |
| 68 | [tsvc/tsvc-s4113-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s4113-l00-25a1b22a/meta/run-7k8lbcel/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s4113-l00-25a1b22a/meta/run-7k8lbcel/backend/candidate-status.json) | s16 | s1 | 1,050,125 | 1,023,601 | 26,524 | 2.5912% |
| 69 | [lcals/init3](.cache/wrong-predictions-20261021/spill/artifacts/lcals_init3-3d272b8a/meta/run-ir0fxqgp/kernel.cpp) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/lcals_init3-3d272b8a/meta/run-ir0fxqgp/backend/candidate-status.json) | s8 | s2 | 2,784 | 2,714 | 70 | 2.5792% |
| 70 | [polybench/polybench-2mm-l01](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-2mm-l01-1406980f/meta/run-ebfuxxmn/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-2mm-l01-1406980f/meta/run-ebfuxxmn/backend/candidate-status.json) | s8 | s1 | 69,002 | 67,332 | 1,670 | 2.4802% |
| 71 | [polybench/polybench-3mm-l02](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-3mm-l02-f0259f1f/meta/run-t0017fy7/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-3mm-l02-f0259f1f/meta/run-t0017fy7/backend/candidate-status.json) | s8 | s1 | 69,002 | 67,332 | 1,670 | 2.4802% |
| 72 | [polybench/polybench-adi-l04](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-adi-l04-8b33d052/meta/run-wik4ea6q/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-adi-l04-8b33d052/meta/run-wik4ea6q/backend/candidate-status.json) | s8 | s2 | 8,350 | 8,164 | 186 | 2.2783% |
| 73 | [lcals/muladdsub](.cache/wrong-predictions-20261021/spill/artifacts/lcals_muladdsub-977367b6/meta/run-wdf1e1pf/kernel.cpp) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/lcals_muladdsub-977367b6/meta/run-wdf1e1pf/backend/candidate-status.json) | s8 | s2 | 2,767 | 2,708 | 59 | 2.1787% |
| 74 | [tsvc/tsvc-s2233-l01](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2233-l01-47053e9d/meta/run-ahrdqm1f/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2233-l01-47053e9d/meta/run-ahrdqm1f/backend/candidate-status.json) | s16 | s8 | 989 | 968 | 21 | 2.1694% |
| 75 | [polybench/polybench-doitgen-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-doitgen-l00-7a07cca4/meta/run-dlap1nw9/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-doitgen-l00-7a07cca4/meta/run-dlap1nw9/backend/candidate-status.json) | s8 | s1 | 2,756 | 2,698 | 58 | 2.1497% |
| 76 | [polybench/p32-gemver-l03](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-gemver-l03-ca7ea0a4/meta/run-xa43mf0k/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-gemver-l03-ca7ea0a4/meta/run-xa43mf0k/backend/candidate-status.json) | s8 | s4 | 22,288 | 21,846 | 442 | 2.0233% |
| 77 | [tsvc/tsvc-s274-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s274-l00-5dd5fc6d/meta/run-zvd8kqeo/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s274-l00-5dd5fc6d/meta/run-zvd8kqeo/backend/candidate-status.json) | s16 | s4 | 353,893 | 347,016 | 6,877 | 1.9818% |
| 78 | [tsvc/tsvc-s4121-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s4121-l00-6c622614/meta/run-55eepmta/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s4121-l00-6c622614/meta/run-55eepmta/backend/candidate-status.json) | s16 | s8 | 169,209 | 165,945 | 3,264 | 1.9669% |
| 79 | [tsvc/tsvc-s271-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s271-l00-2d3fed60/meta/run-usrybqop/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s271-l00-2d3fed60/meta/run-usrybqop/backend/candidate-status.json) | s16 | s8 | 169,175 | 165,991 | 3,184 | 1.9182% |
| 80 | [polybench/p32-gemver-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-gemver-l00-4fc51a44/meta/run-i_eaoyz4/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-gemver-l00-4fc51a44/meta/run-i_eaoyz4/backend/candidate-status.json) | s8 | s4 | 33,249 | 32,691 | 558 | 1.7069% |
| 81 | [tsvc/tsvc-s2711-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2711-l00-49cc1527/meta/run-xn1fbqi2/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2711-l00-49cc1527/meta/run-xn1fbqi2/backend/candidate-status.json) | s16 | s8 | 168,586 | 165,815 | 2,771 | 1.6711% |
| 82 | [polybench/p32-bicg-l01](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-bicg-l01-e0d83bc0/meta/run-35vtr4gx/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-bicg-l01-e0d83bc0/meta/run-35vtr4gx/backend/candidate-status.json) | s8 | s4 | 33,214 | 32,675 | 539 | 1.6496% |
| 83 | [tsvc/tsvc-s2712-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2712-l00-b9b14b9b/meta/run-asjt_246/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2712-l00-b9b14b9b/meta/run-asjt_246/backend/candidate-status.json) | s16 | s8 | 170,319 | 167,562 | 2,757 | 1.6454% |
| 84 | [rajaperf/eos](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_eos-a5c99505/meta/run-khyudd1f/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_eos-a5c99505/meta/run-khyudd1f/backend/candidate-status.json) | s4 | s2 | 24,716 | 24,325 | 391 | 1.6074% |
| 85 | [lcals/energy-calc-l00](.cache/wrong-predictions-20261021/spill/artifacts/lcals_energy-calc-l00-578547e0/meta/run-9d0saiir/kernel.cpp) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/lcals_energy-calc-l00-578547e0/meta/run-9d0saiir/backend/candidate-status.json) | s8 | s4 | 2,993 | 2,952 | 41 | 1.3889% |
| 86 | [rajaperf/triad](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_triad-74b1a1d1/meta/run-qr2c8q1x/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_triad-74b1a1d1/meta/run-qr2c8q1x/backend/candidate-status.json) | s8 | s4 | 6,735 | 6,646 | 89 | 1.3392% |
| 87 | [polybench/p421-gemm-l01](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-gemm-l01-192dbd1e/meta/run-ujbyhc8o/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-gemm-l01-192dbd1e/meta/run-ujbyhc8o/backend/candidate-status.json) | s8 | s4 | 7,189 | 7,100 | 89 | 1.2535% |
| 88 | [tsvc/tsvc-s1421-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1421-l00-bbe52dfd/meta/run-grhnc5df/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1421-l00-bbe52dfd/meta/run-grhnc5df/backend/candidate-status.json) | s16 | s8 | 57,945 | 57,269 | 676 | 1.1804% |
| 89 | [rajaperf/first-sum](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_first-sum-7312297a/meta/run-8113yili/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_first-sum-7312297a/meta/run-8113yili/backend/candidate-status.json) | s8 | s4 | 5,609 | 5,545 | 64 | 1.1542% |
| 90 | [tsvc/tsvc-s118-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s118-l00-fc4312b6/meta/run-i73dfmty/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s118-l00-fc4312b6/meta/run-i73dfmty/backend/candidate-status.json) | s16 | s1 | 6,139 | 6,069 | 70 | 1.1534% |
| 91 | [tsvc/tsvc-s2102-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2102-l00-71c9b926/meta/run-0wyfvv02/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s2102-l00-71c9b926/meta/run-0wyfvv02/backend/candidate-status.json) | s16 | s1 | 5,580 | 5,517 | 63 | 1.1419% |
| 92 | [hpcc/stream-copy](.cache/wrong-predictions-20261021/spill/artifacts/hpcc_stream-copy-ad6615d9/meta/run-8ron5al_/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/hpcc_stream-copy-ad6615d9/meta/run-8ron5al_/backend/candidate-status.json) | s8 | s4 | 5,007 | 4,960 | 47 | 0.9476% |
| 93 | [polybench/polybench-correlation-l01](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-correlation-l01-226a26ff/meta/run-hiokhgsc/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-correlation-l01-226a26ff/meta/run-hiokhgsc/backend/candidate-status.json) | s8 | s4 | 13,852 | 13,743 | 109 | 0.7931% |
| 94 | [tsvc/tsvc-s443-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s443-l00-f507db71/meta/run-8fv9vhkx/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s443-l00-f507db71/meta/run-8fv9vhkx/backend/candidate-status.json) | s16 | s8 | 229,501 | 227,775 | 1,726 | 0.7578% |
| 95 | [rajaperf/add](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_add-0d156cf5/meta/run-8snmt6yq/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_add-0d156cf5/meta/run-8snmt6yq/backend/candidate-status.json) | s8 | s4 | 7,469 | 7,418 | 51 | 0.6875% |
| 96 | [tsvc/tsvc-s491-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s491-l00-10776da5/meta/run-z8p5heeh/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s491-l00-10776da5/meta/run-z8p5heeh/backend/candidate-status.json) | s16 | s4 | 633,661 | 629,679 | 3,982 | 0.6324% |
| 97 | [tsvc/tsvc-s4116-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s4116-l00-80467e9e/meta/run-bnbmdzfc/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s4116-l00-80467e9e/meta/run-bnbmdzfc/backend/candidate-status.json) | s16 | s8 | 2,443 | 2,431 | 12 | 0.4936% |
| 98 | [polybench/polybench-fdtd-2d-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-fdtd-2d-l00-c5d9d238/meta/run-0dh_v8j8/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-fdtd-2d-l00-c5d9d238/meta/run-0dh_v8j8/backend/candidate-status.json) | s8 | s2 | 3,512 | 3,499 | 13 | 0.3715% |
| 99 | [polybench/polybench-durbin-l02](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-durbin-l02-de927056/meta/run-ik6biogm/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-durbin-l02-de927056/meta/run-ik6biogm/backend/candidate-status.json) | s8 | s1 | 100,501 | 100,133 | 368 | 0.3675% |
| 100 | [tsvc/tsvc-s424-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s424-l00-db233916/meta/run-7a3v7ohk/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s424-l00-db233916/meta/run-7a3v7ohk/backend/candidate-status.json) | s16 | s4 | 120,235 | 119,906 | 329 | 0.2744% |
| 101 | [polybench/polybench-covariance-l02](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-covariance-l02-be853ecc/meta/run-8jb2kbpw/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-covariance-l02-be853ecc/meta/run-8jb2kbpw/backend/candidate-status.json) | s8 | s4 | 13,753 | 13,734 | 19 | 0.1383% |
| 102 | [rajaperf/trap-int](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_trap-int-0734d10c/meta/run-rykk3iuk/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/rajaperf_trap-int-0734d10c/meta/run-rykk3iuk/backend/candidate-status.json) | s8 | s4 | 15,158 | 15,143 | 15 | 0.0991% |
| 103 | [polybench/polybench-correlation-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-correlation-l00-4f2fc9b1/meta/run-3ofen3kw/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-correlation-l00-4f2fc9b1/meta/run-3ofen3kw/backend/candidate-status.json) | s8 | s4 | 13,773 | 13,767 | 6 | 0.0436% |
| 104 | [polybench/polybench-covariance-l00](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-covariance-l00-fe2a359d/meta/run-lluf3t8g/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-covariance-l00-fe2a359d/meta/run-lluf3t8g/backend/candidate-status.json) | s8 | s4 | 13,773 | 13,767 | 6 | 0.0436% |
| 105 | [polybench/polybench-gramschmidt-l02](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-gramschmidt-l02-87e132e9/meta/run-twdwu_wf/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-gramschmidt-l02-87e132e9/meta/run-twdwu_wf/backend/candidate-status.json) | s8 | s2 | 41,509 | 41,504 | 5 | 0.0120% |
| 106 | [polybench/p421-floyd-warshall-full](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-floyd-warshall-full-e582b111/meta/run-bghg9_3i/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-floyd-warshall-full-e582b111/meta/run-bghg9_3i/backend/candidate-status.json) | s16 | s8 | 847,706 | 847,655 | 51 | 0.0060% |
| 107 | [tsvc/tsvc-s251-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s251-l00-4ce5a866/meta/run-__b6hg4k/kernel.c) · [후보 비용](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s251-l00-4ce5a866/meta/run-__b6hg4k/backend/candidate-status.json) | s16 | s8 | 194,988 | 194,978 | 10 | 0.0051% |

## 전체 제외 목록

| Benchmark / 후보 상태 | 상태 | 사유 |
| --- | --- | --- |
| [lcals/fir-inner](.cache/wrong-predictions-20261021/spill/artifacts/lcals_fir-inner-04446895/meta/run-x81_0n7v/kernel.cpp) · [후보 상태](.cache/wrong-predictions-20261021/spill/artifacts/lcals_fir-inner-04446895/meta/run-x81_0n7v/backend/candidate-status.json) | `backend-observation-unavailable` | selected_kernel:0:1:s8: cannot prove original-iteration mapping after IR optimization; selected_kernel:0:1:s16: cannot prove original-iteration mapping after IR optimization |
| [lcals/fir-outer](.cache/wrong-predictions-20261021/spill/artifacts/lcals_fir-outer-16dfa90e/meta/run-s9dsslxx/kernel.cpp) · [후보 상태](.cache/wrong-predictions-20261021/spill/artifacts/lcals_fir-outer-16dfa90e/meta/run-s9dsslxx/backend/candidate-status.json) | `backend-observation-unavailable` | selected_kernel:0:1:s8: cannot prove original-iteration mapping after IR optimization; selected_kernel:0:1:s16: cannot prove original-iteration mapping after IR optimization |
| [polybench/p32-adi-full](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-adi-full-2fd7f411/meta/run-3z0h7ivd/kernel.c) · [후보 상태](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-adi-full-2fd7f411/meta/run-3z0h7ivd/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/p32-fdtd-2d-full](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-fdtd-2d-full-85f4b50e/meta/run-7wcb50rk/kernel.c) · [후보 상태](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-fdtd-2d-full-85f4b50e/meta/run-7wcb50rk/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/p32-jacobi-1d-imper-full](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-jacobi-1d-imper-full-e61c1c36/meta/run-xmb6ooup/kernel.c) · [후보 상태](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-jacobi-1d-imper-full-e61c1c36/meta/run-xmb6ooup/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/p32-jacobi-2d-imper-full](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-jacobi-2d-imper-full-67087142/meta/run-9daavlo7/kernel.c) · [후보 상태](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p32-jacobi-2d-imper-full-67087142/meta/run-9daavlo7/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/p421-fdtd-2d-full](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-fdtd-2d-full-3b80f0fa/meta/run-kdhk20ez/kernel.c) · [후보 상태](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-fdtd-2d-full-3b80f0fa/meta/run-kdhk20ez/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/p421-heat-3d-full](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-heat-3d-full-422ad5f5/meta/run-btv90s2b/kernel.c) · [후보 상태](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-heat-3d-full-422ad5f5/meta/run-btv90s2b/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/p421-jacobi-1d-full](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-jacobi-1d-full-cb6eb4ac/meta/run-xo91si8t/kernel.c) · [후보 상태](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-jacobi-1d-full-cb6eb4ac/meta/run-xo91si8t/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/p421-jacobi-1d-outer](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-jacobi-1d-outer-c96619a9/meta/run-ml8p1pol/kernel.c) · [후보 상태](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-jacobi-1d-outer-c96619a9/meta/run-ml8p1pol/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/p421-jacobi-2d-full](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-jacobi-2d-full-ab8ba81c/meta/run-n8rahf5e/kernel.c) · [후보 상태](.cache/wrong-predictions-20261021/spill/artifacts/polybench_p421-jacobi-2d-full-ab8ba81c/meta/run-n8rahf5e/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/polybench-reg_detect-l02](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-reg_detect-l02-526fd6c3/meta/run-ex6p2unp/kernel.c) · [후보 상태](.cache/wrong-predictions-20261021/spill/artifacts/polybench_polybench-reg_detect-l02-526fd6c3/meta/run-ex6p2unp/backend/candidate-status.json) | `backend-observation-unavailable` | selected_kernel:0:1:s4: cannot prove original-iteration mapping after IR optimization; selected_kernel:0:1:s8: cannot prove original-iteration mapping after IR optimization; selected_kernel:0:1:s16: cannot prove original-iteration mapping after IR optimization |
| [tsvc/tsvc-s1111-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1111-l00-ad05c621/meta/run-d27bp0hv/kernel.c) · [후보 상태](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s1111-l00-ad05c621/meta/run-d27bp0hv/backend/candidate-status.json) | `unmeasured-vf` | no measurement for f16 |
| [tsvc/tsvc-s31111-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s31111-l00-48dde2b5/meta/run-cg2iasrg/kernel.c) · [후보 상태](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s31111-l00-48dde2b5/meta/run-cg2iasrg/backend/candidate-status.json) | `backend-observation-unavailable` | selected_kernel:0:1:s2: cannot prove original-iteration mapping after IR optimization; selected_kernel:0:1:s4: cannot prove original-iteration mapping after IR optimization |
| [tsvc/tsvc-s332-l00](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s332-l00-c4d65a47/meta/run-8apgresi/kernel.c) · [후보 상태](.cache/wrong-predictions-20261021/spill/artifacts/tsvc_tsvc-s332-l00-c4d65a47/meta/run-8apgresi/backend/candidate-status.json) | `backend-observation-unavailable` | selected_kernel:0:1:f2: candidate is not an innermost single-latch-exit loop; selected_kernel:0:1:f4: candidate is not an innermost single-latch-exit loop; selected_kernel:0:1:f8: candidate is not an innermost single-latch-exit loop; selected_kernel:0:1:f16: candidate is not an innermost single-latch-exit loop; selected_kernel:0:1:f32: candidate is not an innermost single-latch-exit loop; selected_kernel:0:2:s1: candidate is not an innermost single-latch-exit loop; selected_kernel:0:2:s2: candidate is not an innermost single-latch-exit loop; selected_kernel:0:2:s4: candidate is not an innermost single-latch-exit loop; selected_kernel:0:2:s8: candidate is not an innermost single-latch-exit loop; selected_kernel:0:2:s16: candidate is not an innermost single-latch-exit loop |

## 검증과 한계

- DB hash, 전체 benchmark ID, 소스 artifact와 DB 소스의 일치, 측정 cycles, 정오답과 유리수 regret, 문서 내 모든 파일 링크를 검증했다. Baseline·SpillCost는 compiler를 다시 실행하고 meta 선택의 final replay를 검증했다. Strided 선택은 저장된 후보에 대한 offline replay 결과다.
- 모델 비용은 실제 하드웨어 실행 시간을 완전히 설명하지 않는다. probe compiler와 DB 측정 바이너리의 동일성은 검증되지 않았다.

## 재현

출력은 새 경로 또는 빈 디렉터리를 사용한다. 소스 복원은 평가 도구만 별도 경로에 추출하며 현재 작업 트리를 바꾸지 않는다.

```sh
mkdir -p <run>/spill-source
git archive 8de5b4133 utils | tar -x -C <run>/spill-source
uv run --project utils/vplan-tools python <run>/spill-source/utils/vplan-tools/evaluate \
  --db search-dataset.sqlite --llvm-path <run>/spill-source \
  --skip-build --build-dir build-vplan-tools --compare-baseline \
  --output-dir <run>/spill --artifacts-dir <run>/spill/artifacts
```

평가 JSON과 artifact는 `.cache/`에 보존하며 Git에서 추적하지 않는다. 문서를 이동할 때 재현에 필요한 source·manifest·analytics·상세 비용·결과 JSON과 측정 DB도 함께 보존해야 한다.
