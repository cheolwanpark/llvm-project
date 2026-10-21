# Strided-load 비용 추가 후 오예측 재평가

전체 117개 중 **99개 평가 가능**, **48개 정답**, **51개 오예측**, **18개 제외**다. 정확도는 **48.4848%**, 평균 regret은 **5.1916%**다. SpillCost 대비 신규 제외·fallback·regret 회귀는 모두 0개다.

본문의 주 결과는 `backend-memory-interaction-v2`, `residual / stride`와 [명시적 튜닝 프로파일](utils/vplan-tools/memory-cost-tuned.json)을 사용한다. 코드 기본 계수의 결과도 별도로 비교한다. 컴파일 기본 정책은 여전히 SpillCost이며, 이번 평가는 저장된 후보와 기존 DB cycles를 이용한 offline replay다. 새 컴파일이나 실행 시간 측정은 하지 않았다.

## 입력과 비용

- Spill baseline: [summary.json](.cache/memory-burst-spill-B/summary.json). LLVM의 추정 spill 항을 post-RA 관측 spill/reload 비용으로 교체한 비용이다.
- 상세 비용 corpus: [summary.json](.cache/backend-spill-detail-corpus-final/summary.json).
- DB SHA-256: `6793f637b8e48e5795f2c167419bd38c399cccb029cd3ae39a1aed1a1703a8d8`.
- Probe compiler SHA-256: `9c455960b6753d54beac15fa564c458a1bcc73ef4caa445ffb805fab96096ff9`.
- [현재 tuned 결과](.cache/memory-interaction-v2-tuned-20261021/results.json)에 전체 후보 점수, pair별 항, unknown 정보, 입력·소스 hash와 기존 probe provenance가 있다. [default 결과](.cache/memory-interaction-v2-default-20261021/results.json)도 보존했다.

기존 LLVM memory 비용은 유지하고, non-spill strided load만 본문 명령 순서로 연결해 다음 load와 pair를 만든다. 마지막 load는 다음 iteration의 첫 load와 연결하며, 하나뿐이면 자기 자신과 wrap pair를 만든다.

```text
w(stride) = 1                              if unknown
            0                              if reverse-contiguous
            min(1, L / max(1, abs(stride))) otherwise
P = sum(alpha * H/(H+gap) * max(0, q_i+q_j-K)
        * min(w(stride_i), w(stride_j))) / iteration_ratio
Qeffective = add_sat(Qspill_baseline, saturate(floor(4*P)))
```

`gap`은 사이의 non-meta 명령 개수이며 실제 issue cycle이 아니다. `q`는 VLEN/EMUL/element width로 구한 추정 활성 element 수다. stride와 L은 byte 단위다. P는 모델 단위이며 마지막에 quarter-unit으로 한 번 내림한다. scalar 비교, tail 처리, observed spill 비용, 후보 순서와 tie 정책은 유지한다. v2에서는 finite-iteration 보정 f와 직접 RAW gate z를 제거했다. 별도 load/store address 실험 항은 이 주 결과에 포함하지 않는다.

| 계수 | 코드 기본값 | 주 결과의 tuned 값 |
| --- | ---: | ---: |
| alpha | 0.5 | 0.5 |
| K | 8 | 8 |
| H | 4 | 8 |
| L | 16 bytes | 8 bytes |

## 동일 집합 비교

| 모델 | 평가 수 | 정답 | 오예측 | 평균 regret | P95 | 최대 regret |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| SpillCost | 99 | 46 | 53 | 6.2521% | 23.8601% | 55.0636% |
| Strided default | 99 | 48 | 51 | 5.2482% | 21.5083% | 44.2052% |
| Strided tuned | 99 | 48 | 51 | 5.1916% | 21.5083% | 44.2052% |

세 모델의 평가 집합은 같은 99개다. 앞선 [SpillCost 보고서](wrong-predictions-spillcost.md)의 LLVM 대비 공통 집합 98개 수치와는 모집단이 다르다.

## SpillCost 대비 선택 변화

| Benchmark | Spill VF → 새 VF | Spill regret | 새 regret |
| --- | --- | ---: | ---: |
| tsvc/tsvc-s111-l00 | s16 → s2 | 55.0636% | 0.0000% |
| tsvc/tsvc-s128-l00 | s16 → s2 | 44.3187% | 0.0000% |
| lcals/band-lin-eq-outer | s4 → s2 | 14.3377% | 8.7336% |

기본 계수에서는 s111/s128 두 개만 바뀐다. s1232는 s16과 regret 0%를 유지한다. Tuned에서는 band-lin-eq-outer가 추가로 개선되며, 그 외 114개는 SpillCost와 선택이 같다. **bandouter 개선은 현재 unknown-stride 추출에 의존한다. 실제 +40-byte stride를 제공하는 진단에서는 s4로 돌아가므로 하드웨어 병목을 설명했다는 증거로 볼 수 없다.**

## 새 오예측 전체

Regret은 `(선택 cycles / 최소 cycles) - 1`이다. 비교 대상은 기존 evaluator가 정한 후보 범위 내의 측정 VF다. 측정 동률에서는 작은 VF를 정답으로 삼는다. 정렬은 유리수 regret 내림차순, 동률은 benchmark ID 오름차순이다. `spill cost` 링크는 원래 baseline 후보 비용이고, strided 항을 더한 비용은 [현재 results.json](.cache/memory-interaction-v2-tuned-20261021/results.json)의 `runs.residual-stride.rows[].candidates`에 있다.

| 순위 | Benchmark / artifact | 선택 VF | 최적 VF | 선택 cycles | 최소 cycles | 초과 cycles | regret | Spill VF | Spill regret |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | [tsvc/tsvc-s1213-l00](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s1213-l00-34954cae/meta/run-imps1wa3/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s1213-l00-34954cae/meta/run-imps1wa3/backend/candidate-status.json) | s16 | s8 | 263,150 | 182,483 | 80,667 | 44.2052% | s16 | 44.2052% |
| 2 | [polybench/p421-jacobi-1d-l01](.cache/memory-burst-spill-B/artifacts/polybench_p421-jacobi-1d-l01-4aae641c/meta/run-uy200jjj/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/polybench_p421-jacobi-1d-l01-4aae641c/meta/run-uy200jjj/backend/candidate-status.json) | s8 | s2 | 133,310 | 106,904 | 26,406 | 24.7007% | s8 | 24.7007% |
| 3 | [polybench/p32-jacobi-1d-imper-l00](.cache/memory-burst-spill-B/artifacts/polybench_p32-jacobi-1d-imper-l00-e35be639/meta/run-2ysfcjfj/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/polybench_p32-jacobi-1d-imper-l00-e35be639/meta/run-2ysfcjfj/backend/candidate-status.json) | s8 | s2 | 132,591 | 107,049 | 25,542 | 23.8601% | s8 | 23.8601% |
| 4 | [polybench/p421-jacobi-1d-l00](.cache/memory-burst-spill-B/artifacts/polybench_p421-jacobi-1d-l00-9ab66748/meta/run-6vjj3ace/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/polybench_p421-jacobi-1d-l00-9ab66748/meta/run-6vjj3ace/backend/candidate-status.json) | s8 | s2 | 132,591 | 107,049 | 25,542 | 23.8601% | s8 | 23.8601% |
| 5 | [rajaperf/dot](.cache/memory-burst-spill-B/artifacts/rajaperf_dot-e736b8f0/meta/run-j9qtz6k0/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/rajaperf_dot-e736b8f0/meta/run-j9qtz6k0/backend/candidate-status.json) | s8 | s2 | 6,255 | 5,138 | 1,117 | 21.7400% | s8 | 21.7400% |
| 6 | [lcals/first-diff](.cache/memory-burst-spill-B/artifacts/lcals_first-diff-1e964f79/meta/run-itul7040/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/lcals_first-diff-1e964f79/meta/run-itul7040/backend/candidate-status.json) | s8 | s4 | 1,606 | 1,322 | 284 | 21.4826% | s8 | 21.4826% |
| 7 | [tsvc/tsvc-s116-l00](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s116-l00-abbc6fd5/meta/run-x6b_r16p/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s116-l00-abbc6fd5/meta/run-x6b_r16p/backend/candidate-status.json) | s16 | s8 | 123,524 | 102,133 | 21,391 | 20.9443% | s16 | 20.9443% |
| 8 | [tsvc/tsvc-s127-l00](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s127-l00-05409684/meta/run-q50wx7gn/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s127-l00-05409684/meta/run-q50wx7gn/backend/candidate-status.json) | s8 | s16 | 378,206 | 312,810 | 65,396 | 20.9060% | s8 | 20.9060% |
| 9 | [polybench/p32-gemver-l02](.cache/memory-burst-spill-B/artifacts/polybench_p32-gemver-l02-2380c05b/meta/run-085szihd/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/polybench_p32-gemver-l02-2380c05b/meta/run-085szihd/backend/candidate-status.json) | s8 | s2 | 23,624 | 19,724 | 3,900 | 19.7729% | s8 | 19.7729% |
| 10 | [rajaperf/init3](.cache/memory-burst-spill-B/artifacts/rajaperf_init3-95a32e1a/meta/run-hbp4lvp3/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/rajaperf_init3-95a32e1a/meta/run-hbp4lvp3/backend/candidate-status.json) | s8 | s4 | 17,207 | 14,424 | 2,783 | 19.2942% | s8 | 19.2942% |
| 11 | [lcals/pressure-calc-l01](.cache/memory-burst-spill-B/artifacts/lcals_pressure-calc-l01-aa0a9cb1/meta/run-mudwc0s6/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/lcals_pressure-calc-l01-aa0a9cb1/meta/run-mudwc0s6/backend/candidate-status.json) | s8 | s2 | 3,061 | 2,604 | 457 | 17.5499% | s8 | 17.5499% |
| 12 | [rajaperf/int-predict](.cache/memory-burst-spill-B/artifacts/rajaperf_int-predict-f2d1b908/meta/run-pd3m9o96/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/rajaperf_int-predict-f2d1b908/meta/run-pd3m9o96/backend/candidate-status.json) | s4 | s8 | 42,986 | 37,205 | 5,781 | 15.5382% | s4 | 15.5382% |
| 13 | [rajaperf/gen-lin-recur-reverse](.cache/memory-burst-spill-B/artifacts/rajaperf_gen-lin-recur-reverse-52b65c3b/meta/run-in24ubwr/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/rajaperf_gen-lin-recur-reverse-52b65c3b/meta/run-in24ubwr/backend/candidate-status.json) | s8 | s4 | 14,480 | 12,609 | 1,871 | 14.8386% | s8 | 14.8386% |
| 14 | [tsvc/tsvc-s176-l00](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s176-l00-a186d0cf/meta/run-4zf3p_qr/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s176-l00-a186d0cf/meta/run-4zf3p_qr/backend/candidate-status.json) | s16 | s4 | 49,181 | 42,984 | 6,197 | 14.4170% | s16 | 14.4170% |
| 15 | [rajaperf/reduce-struct](.cache/memory-burst-spill-B/artifacts/rajaperf_reduce-struct-2fb15f36/meta/run-u4nw45e2/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/rajaperf_reduce-struct-2fb15f36/meta/run-u4nw45e2/backend/candidate-status.json) | s4 | s2 | 6,809 | 6,019 | 790 | 13.1251% | s4 | 13.1251% |
| 16 | [polybench/p421-gemm-l01](.cache/memory-burst-spill-B/artifacts/polybench_p421-gemm-l01-192dbd1e/meta/run-w3nxvgj4/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/polybench_p421-gemm-l01-192dbd1e/meta/run-w3nxvgj4/backend/candidate-status.json) | s8 | s4 | 6,695 | 5,963 | 732 | 12.2757% | s8 | 12.2757% |
| 17 | [rajaperf/daxpy](.cache/memory-burst-spill-B/artifacts/rajaperf_daxpy-3966eff4/meta/run-qwxdpgf2/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/rajaperf_daxpy-3966eff4/meta/run-qwxdpgf2/backend/candidate-status.json) | s8 | s2 | 5,844 | 5,208 | 636 | 12.2120% | s8 | 12.2120% |
| 18 | [tsvc/tsvc-s171-l00](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s171-l00-21a03b56/meta/run-z78o5c6p/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s171-l00-21a03b56/meta/run-z78o5c6p/backend/candidate-status.json) | s16 | s4 | 112,967 | 100,680 | 12,287 | 12.2040% | s16 | 12.2040% |
| 19 | [tsvc/tsvc-s172-l00](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s172-l00-c3a4cfce/meta/run-6k6o6y2o/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s172-l00-c3a4cfce/meta/run-6k6o6y2o/backend/candidate-status.json) | s16 | s4 | 112,967 | 100,680 | 12,287 | 12.2040% | s16 | 12.2040% |
| 20 | [tsvc/tsvc-s119-l00](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s119-l00-7c5e355c/meta/run-t3egigy8/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s119-l00-7c5e355c/meta/run-t3egigy8/backend/candidate-status.json) | s16 | s8 | 1,068 | 960 | 108 | 11.2500% | s16 | 11.2500% |
| 21 | [rajaperf/gen-lin-recur-forward](.cache/memory-burst-spill-B/artifacts/rajaperf_gen-lin-recur-forward-2d89df0b/meta/run-w_xz8he8/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/rajaperf_gen-lin-recur-forward-2d89df0b/meta/run-w_xz8he8/backend/candidate-status.json) | s8 | s4 | 13,844 | 12,530 | 1,314 | 10.4868% | s8 | 10.4868% |
| 22 | [tsvc/tsvc-s114-l00](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s114-l00-9cee7768/meta/run-wyprhstl/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s114-l00-9cee7768/meta/run-wyprhstl/backend/candidate-status.json) | s16 | s2 | 5,835 | 5,342 | 493 | 9.2288% | s16 | 9.2288% |
| 23 | [tsvc/tsvc-s118-l00](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s118-l00-fc4312b6/meta/run-c05nrq9m/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s118-l00-fc4312b6/meta/run-c05nrq9m/backend/candidate-status.json) | s16 | s1 | 6,744 | 6,180 | 564 | 9.1262% | s16 | 9.1262% |
| 24 | [lcals/band-lin-eq-outer](.cache/memory-burst-spill-B/artifacts/lcals_band-lin-eq-outer-4e64cad2/meta/run-70b_texx/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/lcals_band-lin-eq-outer-4e64cad2/meta/run-70b_texx/backend/candidate-status.json) | s2 | s8 | 1,494 | 1,374 | 120 | 8.7336% | s4 | 14.3377% |
| 25 | [rajaperf/triad](.cache/memory-burst-spill-B/artifacts/rajaperf_triad-74b1a1d1/meta/run-5qq588jl/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/rajaperf_triad-74b1a1d1/meta/run-5qq588jl/backend/candidate-status.json) | s8 | s2 | 6,800 | 6,269 | 531 | 8.4703% | s8 | 8.4703% |
| 26 | [tsvc/tsvc-s1119-l00](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s1119-l00-4f9ad8fa/meta/run-czadg819/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s1119-l00-4f9ad8fa/meta/run-czadg819/backend/candidate-status.json) | s16 | s4 | 1,045 | 964 | 81 | 8.4025% | s16 | 8.4025% |
| 27 | [lcals/energy-calc-l03](.cache/memory-burst-spill-B/artifacts/lcals_energy-calc-l03-5a111bb6/meta/run-13_tddq2/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/lcals_energy-calc-l03-5a111bb6/meta/run-13_tddq2/backend/candidate-status.json) | s8 | s4 | 1,527 | 1,418 | 109 | 7.6869% | s8 | 7.6869% |
| 28 | [lcals/energy-calc-l04](.cache/memory-burst-spill-B/artifacts/lcals_energy-calc-l04-9d0673bd/meta/run-y2xrosrb/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/lcals_energy-calc-l04-9d0673bd/meta/run-y2xrosrb/backend/candidate-status.json) | s2 | s4 | 11,820 | 11,017 | 803 | 7.2887% | s2 | 7.2887% |
| 29 | [rajaperf/reduce-sum](.cache/memory-burst-spill-B/artifacts/rajaperf_reduce-sum-c7209cc1/meta/run-3te3mv2b/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/rajaperf_reduce-sum-c7209cc1/meta/run-3te3mv2b/backend/candidate-status.json) | s8 | s4 | 3,257 | 3,057 | 200 | 6.5424% | s8 | 6.5424% |
| 30 | [rajaperf/muladdsub](.cache/memory-burst-spill-B/artifacts/rajaperf_muladdsub-350a953b/meta/run-zhv2junx/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/rajaperf_muladdsub-350a953b/meta/run-zhv2junx/backend/candidate-status.json) | s8 | s4 | 15,641 | 14,689 | 952 | 6.4810% | s8 | 6.4810% |
| 31 | [rajaperf/eos](.cache/memory-burst-spill-B/artifacts/rajaperf_eos-a5c99505/meta/run-zvdimrnc/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/rajaperf_eos-a5c99505/meta/run-zvdimrnc/backend/candidate-status.json) | s4 | s2 | 21,994 | 20,795 | 1,199 | 5.7658% | s4 | 5.7658% |
| 32 | [rajaperf/first-diff](.cache/memory-burst-spill-B/artifacts/rajaperf_first-diff-62f6f81e/meta/run-ctn6i18e/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/rajaperf_first-diff-62f6f81e/meta/run-ctn6i18e/backend/candidate-status.json) | s8 | s4 | 9,510 | 9,019 | 491 | 5.4441% | s8 | 5.4441% |
| 33 | [rajaperf/if-quad](.cache/memory-burst-spill-B/artifacts/rajaperf_if-quad-183490a8/meta/run-ettxgzkv/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/rajaperf_if-quad-183490a8/meta/run-ettxgzkv/backend/candidate-status.json) | s4 | s2 | 19,624 | 18,646 | 978 | 5.2451% | s4 | 5.2451% |
| 34 | [rajaperf/if-quad-builtin](.cache/memory-burst-spill-B/artifacts/rajaperf_if-quad-builtin-6c7a4061/meta/run-zjx_v3gs/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/rajaperf_if-quad-builtin-6c7a4061/meta/run-zjx_v3gs/backend/candidate-status.json) | s4 | s2 | 19,624 | 18,646 | 978 | 5.2451% | s4 | 5.2451% |
| 35 | [lcals/pressure-calc-l00](.cache/memory-burst-spill-B/artifacts/lcals_pressure-calc-l00-eb73f211/meta/run-kbq4lzeh/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/lcals_pressure-calc-l00-eb73f211/meta/run-kbq4lzeh/backend/candidate-status.json) | s8 | s4 | 1,009 | 961 | 48 | 4.9948% | s8 | 4.9948% |
| 36 | [polybench/p32-gemm-l00](.cache/memory-burst-spill-B/artifacts/polybench_p32-gemm-l00-ac3f2df9/meta/run-vxlbm_z_/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/polybench_p32-gemm-l00-ac3f2df9/meta/run-vxlbm_z_/backend/candidate-status.json) | s8 | s1 | 69,305 | 67,207 | 2,098 | 3.1217% | s8 | 3.1217% |
| 37 | [tsvc/tsvc-s173-l00](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s173-l00-48d51ecc/meta/run-j7ze536r/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s173-l00-48d51ecc/meta/run-j7ze536r/backend/candidate-status.json) | s16 | s4 | 59,268 | 57,554 | 1,714 | 2.9781% | s16 | 2.9781% |
| 38 | [tsvc/tsvc-s174-l00](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s174-l00-bd9fa068/meta/run-ikb0e4qg/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s174-l00-bd9fa068/meta/run-ikb0e4qg/backend/candidate-status.json) | s16 | s4 | 59,268 | 57,554 | 1,714 | 2.9781% | s16 | 2.9781% |
| 39 | [lcals/init3](.cache/memory-burst-spill-B/artifacts/lcals_init3-3d272b8a/meta/run-9dngpses/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/lcals_init3-3d272b8a/meta/run-9dngpses/backend/candidate-status.json) | s8 | s2 | 2,784 | 2,714 | 70 | 2.5792% | s8 | 2.5792% |
| 40 | [polybench/p32-atax-l00](.cache/memory-burst-spill-B/artifacts/polybench_p32-atax-l00-671335a6/meta/run-wcmhu84b/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/polybench_p32-atax-l00-671335a6/meta/run-wcmhu84b/backend/candidate-status.json) | s8 | s2 | 13,752 | 13,436 | 316 | 2.3519% | s8 | 2.3519% |
| 41 | [polybench/p32-bicg-l00](.cache/memory-burst-spill-B/artifacts/polybench_p32-bicg-l00-68d57011/meta/run-v8vkjtd1/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/polybench_p32-bicg-l00-68d57011/meta/run-v8vkjtd1/backend/candidate-status.json) | s8 | s2 | 13,752 | 13,436 | 316 | 2.3519% | s8 | 2.3519% |
| 42 | [tsvc/tsvc-s132-l00](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s132-l00-f0d6c836/meta/run-042smvkx/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s132-l00-f0d6c836/meta/run-042smvkx/backend/candidate-status.json) | s16 | s8 | 1,024 | 1,002 | 22 | 2.1956% | s16 | 2.1956% |
| 43 | [lcals/muladdsub](.cache/memory-burst-spill-B/artifacts/lcals_muladdsub-977367b6/meta/run-7ymm7ft5/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/lcals_muladdsub-977367b6/meta/run-7ymm7ft5/backend/candidate-status.json) | s8 | s2 | 2,767 | 2,708 | 59 | 2.1787% | s8 | 2.1787% |
| 44 | [polybench/p32-bicg-l01](.cache/memory-burst-spill-B/artifacts/polybench_p32-bicg-l01-e0d83bc0/meta/run-43m8autg/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/polybench_p32-bicg-l01-e0d83bc0/meta/run-43m8autg/backend/candidate-status.json) | s8 | s4 | 40,732 | 39,926 | 806 | 2.0187% | s8 | 2.0187% |
| 45 | [lcals/inner-prod](.cache/memory-burst-spill-B/artifacts/lcals_inner-prod-93100f71/meta/run-hvwpeiey/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/lcals_inner-prod-93100f71/meta/run-hvwpeiey/backend/candidate-status.json) | s8 | s4 | 1,292 | 1,267 | 25 | 1.9732% | s8 | 1.9732% |
| 46 | [rajaperf/first-sum](.cache/memory-burst-spill-B/artifacts/rajaperf_first-sum-7312297a/meta/run-4o4999sb/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/rajaperf_first-sum-7312297a/meta/run-4o4999sb/backend/candidate-status.json) | s8 | s4 | 5,609 | 5,545 | 64 | 1.1542% | s8 | 1.1542% |
| 47 | [hpcc/stream-copy](.cache/memory-burst-spill-B/artifacts/hpcc_stream-copy-ad6615d9/meta/run-rn54p9kf/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/hpcc_stream-copy-ad6615d9/meta/run-rn54p9kf/backend/candidate-status.json) | s8 | s4 | 5,007 | 4,960 | 47 | 0.9476% | s8 | 0.9476% |
| 48 | [rajaperf/add](.cache/memory-burst-spill-B/artifacts/rajaperf_add-0d156cf5/meta/run-1vqumnpp/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/rajaperf_add-0d156cf5/meta/run-1vqumnpp/backend/candidate-status.json) | s8 | s4 | 7,469 | 7,418 | 51 | 0.6875% | s8 | 0.6875% |
| 49 | [lcals/band-lin-eq-inner](.cache/memory-burst-spill-B/artifacts/lcals_band-lin-eq-inner-ed39b648/meta/run-68lapu4d/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/lcals_band-lin-eq-inner-ed39b648/meta/run-68lapu4d/backend/candidate-status.json) | s4 | s8 | 719 | 715 | 4 | 0.5594% | s4 | 0.5594% |
| 50 | [lcals/energy-calc-l02](.cache/memory-burst-spill-B/artifacts/lcals_energy-calc-l02-53eb21ea/meta/run-korabrs3/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/lcals_energy-calc-l02-53eb21ea/meta/run-korabrs3/backend/candidate-status.json) | s8 | s4 | 3,286 | 3,274 | 12 | 0.3665% | s8 | 0.3665% |
| 51 | [polybench/p421-floyd-warshall-full](.cache/memory-burst-spill-B/artifacts/polybench_p421-floyd-warshall-full-e582b111/meta/run-3ceeity0/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/polybench_p421-floyd-warshall-full-e582b111/meta/run-3ceeity0/backend/candidate-status.json) | s16 | s8 | 847,706 | 847,655 | 51 | 0.0060% | s16 | 0.0060% |

## 남은 strided-load 사례

실제 strided load가 하나라도 있는 후보를 가진 평가 가능 benchmark는 9개다. 그중 남은 오예측은 다음 5개다. `strided` 집계에는 store-only인 s127도 포함되므로 load 사례와 구분한다.

| Benchmark | 선택 VF | 최적 VF | regret |
| --- | --- | --- | ---: |
| tsvc/tsvc-s114-l00 | s16 | s2 | 9.2288% |
| tsvc/tsvc-s118-l00 | s16 | s1 | 9.1262% |
| lcals/band-lin-eq-outer | s2 | s8 | 8.7336% |
| polybench/p32-gemm-l00 | s8 | s1 | 3.1217% |
| lcals/band-lin-eq-inner | s4 | s8 | 0.5594% |

- s114와 s1115는 sparse load가 있어도 넓은 VF 선호가 반대다. 같은 계수를 키우면 s114 개선과 s1115 악화가 동시에 발생한다.
- s118의 최적 s1은 기존 모델에서 이미 scalar보다 비싸다. 양의 페널티만 더하는 방식으로 s1을 선택할 수 없다.
- bandouter의 최적 s8은 짧은 trip count를 반영한 기존 비용에서 s4보다 비싸고, 현재 페널티도 s8을 더 유리하게 만들지 못한다.
- s127은 strided store만 있어 이 load-pair 항이 0이다. s8 선택, 최적 s16, regret 20.9060%는 그대로 남는다.

## f/z 및 stride 가중치 제거 비교

동일 tuned 계수로 v1의 각 항을 제거한 실험에서 f/z만 제거하면 117개 모두 VF가 같았다. 이 결과를 v2에 반영했다. 관측 load 쌍 106개에는 z가 차단하는 직접 RAW 사례가 0개여서 z의 일반적 필요성은 검증하지 못했다.

| 제거한 항 | 평균 regret | 정답 |
| --- | ---: | ---: |
| 없음 | 5.1916% | 48/99 |
| f/z | 5.1916% | 48/99 |
| stride + f/z | 5.4230% | 46/99 |

stride 가중치까지 제거하면 s1115 0→20.2705%, bandinner 0.5594→4.8951%, s1232 0→1.4088%로 악화된다. gemm은 3.1217→0.0089%로 개선된다. [ablation 결과](.cache/memory-ablation-20261021/report.md)는 당시 v1의 역사적 기록이다.

## 기존 memory 비용 유지 / 교체 비교

주 결과인 residual은 `spill baseline + interaction`이다. add는 여기에 backend request-service 항을 더하고, replace는 기존 additive LLVM memory hook 비용을 먼저 뺀다. 아래는 tuned 계수와 stride stage 결과다.

| 모드 | 평가 수 | 평균 regret | 같은 집합의 SpillCost 평균 | 신규 제외 |
| --- | ---: | ---: | ---: | ---: |
| residual | 99 | 5.1916% | 6.2521% | 0 |
| add | 93 | 5.5732% | 5.5868% | 6 |
| replace | 96 | 5.3539% | 5.4122% | 3 |

add는 기존 memory 비용과 service를 중복 반영하고, replace는 interleaved hook에 포함된 shuffle/lowering 비용까지 제거할 수 있다. 새 fixed/scalar 선택에 측정이 없는 경우 제외로 보고하며 개선으로 세지 않는다. 모드별 상세 제외 목록은 [전체 replay](.cache/memory-interaction-v2-tuned-20261021/report.md)에 있다.

## 전체 제외 목록

주 결과의 18개 제외는 SpillCost와 동일하다. 아래 사유는 저장된 baseline 관측에서 가져왔으며 이번 replay에 새 컴파일 실패는 없다.

| Benchmark / artifact | 상태 | 구체적 사유 |
| --- | --- | --- |
| [lcals/fir-inner](.cache/memory-burst-spill-B/artifacts/lcals_fir-inner-04446895/meta/run-zck9_dt5/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/lcals_fir-inner-04446895/meta/run-zck9_dt5/backend/candidate-status.json) | `backend-observation-unavailable` | selected_kernel:0:1:s8: cannot prove original-iteration mapping after IR optimization; selected_kernel:0:1:s16: cannot prove original-iteration mapping after IR optimization |
| [lcals/fir-outer](.cache/memory-burst-spill-B/artifacts/lcals_fir-outer-16dfa90e/meta/run-uuz32qbf/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/lcals_fir-outer-16dfa90e/meta/run-uuz32qbf/backend/candidate-status.json) | `backend-observation-unavailable` | selected_kernel:0:1:s8: cannot prove original-iteration mapping after IR optimization; selected_kernel:0:1:s16: cannot prove original-iteration mapping after IR optimization |
| [polybench/p32-adi-full](.cache/memory-burst-spill-B/artifacts/polybench_p32-adi-full-2fd7f411/meta/run-q4428bo_/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/polybench_p32-adi-full-2fd7f411/meta/run-q4428bo_/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/p32-fdtd-2d-full](.cache/memory-burst-spill-B/artifacts/polybench_p32-fdtd-2d-full-85f4b50e/meta/run-lktbs6mv/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/polybench_p32-fdtd-2d-full-85f4b50e/meta/run-lktbs6mv/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/p32-jacobi-1d-imper-full](.cache/memory-burst-spill-B/artifacts/polybench_p32-jacobi-1d-imper-full-e61c1c36/meta/run-gcrxwc8g/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/polybench_p32-jacobi-1d-imper-full-e61c1c36/meta/run-gcrxwc8g/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/p32-jacobi-2d-imper-full](.cache/memory-burst-spill-B/artifacts/polybench_p32-jacobi-2d-imper-full-67087142/meta/run-pm5xyjff/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/polybench_p32-jacobi-2d-imper-full-67087142/meta/run-pm5xyjff/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/p421-fdtd-2d-full](.cache/memory-burst-spill-B/artifacts/polybench_p421-fdtd-2d-full-3b80f0fa/meta/run-7d9w2h5p/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/polybench_p421-fdtd-2d-full-3b80f0fa/meta/run-7d9w2h5p/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/p421-heat-3d-full](.cache/memory-burst-spill-B/artifacts/polybench_p421-heat-3d-full-422ad5f5/meta/run-p9yzb6_e/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/polybench_p421-heat-3d-full-422ad5f5/meta/run-p9yzb6_e/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/p421-jacobi-1d-full](.cache/memory-burst-spill-B/artifacts/polybench_p421-jacobi-1d-full-cb6eb4ac/meta/run-8rgukt91/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/polybench_p421-jacobi-1d-full-cb6eb4ac/meta/run-8rgukt91/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/p421-jacobi-1d-outer](.cache/memory-burst-spill-B/artifacts/polybench_p421-jacobi-1d-outer-c96619a9/meta/run-rx7b_i27/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/polybench_p421-jacobi-1d-outer-c96619a9/meta/run-rx7b_i27/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [polybench/p421-jacobi-2d-full](.cache/memory-burst-spill-B/artifacts/polybench_p421-jacobi-2d-full-ab8ba81c/meta/run-ct8y4se5/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/polybench_p421-jacobi-2d-full-ab8ba81c/meta/run-ct8y4se5/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [rajaperf/planckian](.cache/memory-burst-spill-B/artifacts/rajaperf_planckian-4f26d45c/meta/run-y28ovamk/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/rajaperf_planckian-4f26d45c/meta/run-y28ovamk/backend/candidate-status.json) | `missing-measurements` | missing measurements for compiler VF(s): s1 |
| [tsvc/tsvc-s1111-l00](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s1111-l00-ad05c621/meta/run-6lee2ka1/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s1111-l00-ad05c621/meta/run-6lee2ka1/backend/candidate-status.json) | `unmeasured-vf` | no measurement for f16 |
| [tsvc/tsvc-s1113-l00](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s1113-l00-2ef597be/meta/run-7pgyz3he/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s1113-l00-2ef597be/meta/run-7pgyz3he/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [tsvc/tsvc-s1161-l00](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s1161-l00-8319d9b6/meta/run-mrtz2opg/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s1161-l00-8319d9b6/meta/run-mrtz2opg/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [tsvc/tsvc-s161-l00](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s161-l00-55898968/meta/run-nlehdyz5/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s161-l00-55898968/meta/run-nlehdyz5/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [tsvc/tsvc-s212-l00](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s212-l00-6534addd/meta/run-zpu7ly8k/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s212-l00-6534addd/meta/run-zpu7ly8k/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |
| [tsvc/tsvc-s221-l00](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s221-l00-1c34c305/meta/run-gtqnjsgd/kernel.c) · [spill cost](.cache/memory-burst-spill-B/artifacts/tsvc_tsvc-s221-l00-1c34c305/meta/run-gtqnjsgd/backend/candidate-status.json) | `ambiguous-loops` | expected one selected_kernel loop |

## 검증과 한계

- 전체 후보·관측 입력, DB 및 모델 소스 hash를 검증했다. 기본/tuned 각각 baseline 포함 10개 비교 모드에서 f/z 제거 전후 117개 VF·eligibility·regret이 동일하다.
- Python 테스트는 117개 중 102개 통과, compiler 환경을 요구하는 15개 skip이다.
- Tuned 계수는 같은 데이터에서 broad 4,050개와 refine 1,750개를 검색한 **in-sample 결과**다. 독립 데이터 검증을 하지 않았다. [broad](.cache/memory-coefficient-tuning-20261021/report.md), [refine](.cache/memory-coefficient-refine-20261021/report.md), [민감도와 known-stride 진단](.cache/memory-coefficient-refine-20261021/sensitivity.json)에 탐색 기록이 있다.
- MIR 주소 추적은 제한적인 GPR 연산과 첫 두 iteration을 사용한다. 알려지지 않은 stride에는 가중치 1을 적용하므로 정보 누락 자체가 선택에 영향을 준다.
- full-active VL/mask를 가정하며 cache 상태, bank/TLB, 실제 issue 순서와 load completion은 모델링하지 않는다. DB 측정 바이너리와 probe MIR의 동일성은 검증되지 않았다. VF 선택 개선은 하드웨어 병목 원인의 입증과 다르다.

## 재현

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate-memory-cost \
  --output-dir .cache/strided-default-new
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate-memory-cost \
  --memory-parameters utils/vplan-tools/memory-cost-tuned.json \
  --output-dir .cache/strided-tuned-new
uv run --project utils/vplan-tools python -B -m unittest discover \
  -s utils/vplan-tools/tests
```

기본 입력 경로는 위의 spill baseline과 상세 비용 corpus다. 출력 디렉터리는 새 경로 또는 빈 디렉터리여야 한다. `.cache/` artifact는 Git에서 추적하지 않으므로 문서를 이동할 때 입력 manifest·MIR·analytics·측정 DB와 결과 JSON을 함께 보존해야 한다. 구현 개요는 [PATCHES.md](PATCHES.md#stridedmemorycost), 명령 사용법은 [tools guide](utils/vplan-tools/README.md)에 있다.
