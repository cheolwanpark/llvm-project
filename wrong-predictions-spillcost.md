# Backend spill 교체 후 오예측 재평가

전체 117개 중 **99개 평가 가능**, **46개 정답**, **53개 오예측**, **18개 제외**, **0개 컴파일 실패**다. 정확도는 **46.4646%**, 평균 regret은 **6.2521%**다.

고정 LLVM 비용에서 spill/reload 항만 post-RA 관측 기반으로 교체했다. 학습·계수 fitting·새 런타임 측정 없이 기존 DB cycles를 사용했다. backend 비용은 TTI 모델 단위이며 실측 cycles가 아니다.

## 입력과 비용

- DB SHA-256: `6793f637b8e48e5795f2c167419bd38c399cccb029cd3ae39a1aed1a1703a8d8`.
- HEAD: `020efcd18350561115cd34abb1d507d4f7e3d7c3`. 실행 당시 working tree 및 관련 Python/driver 파일별 SHA-256은 [summary.json](.cache/wrong-predictions-updated-final/summary.json)의 `provenance`에 있다.
- 모델: `llvm-backend-spill` / `llvm-backend-spill-v1`. 정책 구현 SHA-256: `91dcaed85a97a73a761942440dfe2a1a219e43724d67bf30784b9ac2d698d3f7`. 비용·spill projection·observation·selection 구현 hash도 policy identity에 포함한다.
- compiler SHA-256: `9c455960b6753d54beac15fa564c458a1bcc73ef4caa445ffb805fab96096ff9`. `clang version 23.1.3 (https://github.com/cheolwanpark/llvm-project.git 9d0ab6c42aa515a07eaac633ff50260004f16465)`.
- 공유 `build-vplan-tools` symlink의 기존 compiler를 `--skip-build`로 사용했다. LLVM C++ 소스와 공유 빌드는 변경하지 않았다.
- 모든 비용은 정수 quarter-unit이다. bank 순서는 GPR/FPR/vector이며 vector group은 1/2/4/8이다.

```text
Qraw = Σ group × (observed_spills × TTI_spill_unit + observed_reloads × TTI_reload_unit)
r = backend_iteration_width / candidate.estimated_width  (검증된 양의 정수)
Qbackend = saturate(trunc_toward_zero(Qraw / r))
Qeffective = add_sat(add_sat(Qprecomputed, Qvector_region), Qbackend)
C = Qeffective / 4
unknown T: C/W; scalar tail: C*floor(T/W)+S*(T%W); folded tail: C*ceil(T/W)
```

`original`과 `estimated_spill`은 manifest에 그대로 보존한다. 파생 비용은 candidate-status의 breakdown에만 기록한다. 선택은 기존 compiler 순서·pairwise 비교·incoming tail 정책·scalable 동률 규칙을 유지한다. 합법적인 후보의 관측이 하나라도 부족하면 benchmark 전체를 제외하며, 후보를 제거해 정답 모집단을 줄이지 않는다.

## 전체 및 공통 집합 비교

| 집합 / 모델 | 평가 수 | 정답 수 | 정확도 | 평균 regret | 중앙값 | P95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 이전 전체 | 100 | 41 | 41.0000% | 7.3184% | 2.0987% | 24.8170% |
| 새 모델 전체 | 99 | 46 | 46.4646% | 6.2521% | 0.6875% | 23.8601% |
| 공통 / 이전 | 98 | 41 | 41.8367% | 7.1318% | 1.9959% | 23.9862% |
| 공통 / 새 모델 | 98 | 46 | 46.9388% | 6.1026% | 0.6235% | 23.8601% |

Coverage: 이전 100/117 (85.4701%), 새 모델 99/117 (84.6154%). 공통 집합 98개에서 regret 개선 8개, 악화 5개, 동일 85개다.

일반 LLVM 비교: 101개 비교 가능, VF/전체 선택 일치 85/85개. ordinary LLVM과 다른 선택은 모델 변경의 결과다. 이전 모델 결과는 [보존된 baseline](.cache/wrong-predictions-current/summary.json)을 사용했다.

## 새 오예측 전체

Regret은 `(선택 cycles / 최소 cycles) - 1`이다. 정렬·비교는 정수/유리수로 수행하고 표시할 때만 반올림했다. 동률은 ID 오름차순이다. 측정 cycles 동률의 정답은 기존 evaluator처럼 작은 VF다. source는 DB 소스, cost는 후보별 원본/파생 비용 및 관측 링크다.

| 순위 | Benchmark / artifact | 선택 VF | 최적 VF | 선택 cycles | 최소 cycles | 초과 cycles | regret | 이전 VF | 이전 regret |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | [tsvc/tsvc-s111-l00](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s111-l00-90373715/meta/run-pc37xnyh/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s111-l00-90373715/meta/run-pc37xnyh/backend/candidate-status.json) | s16 | s2 | 384,795 | 248,153 | 136,642 | 55.0636% | s8 | 50.5229% |
| 2 | [tsvc/tsvc-s128-l00](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s128-l00-28527a6c/meta/run-8rs1tnwj/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s128-l00-28527a6c/meta/run-8rs1tnwj/backend/candidate-status.json) | s16 | s2 | 409,344 | 283,639 | 125,705 | 44.3187% | s8 | 36.8835% |
| 3 | [tsvc/tsvc-s1213-l00](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s1213-l00-34954cae/meta/run-l2pcg0nh/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s1213-l00-34954cae/meta/run-l2pcg0nh/backend/candidate-status.json) | s16 | s8 | 263,150 | 182,483 | 80,667 | 44.2052% | s16 | 44.2052% |
| 4 | [polybench/p421-jacobi-1d-l01](.cache/wrong-predictions-updated-final/artifacts/polybench_p421-jacobi-1d-l01-4aae641c/meta/run-8h09apy7/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/polybench_p421-jacobi-1d-l01-4aae641c/meta/run-8h09apy7/backend/candidate-status.json) | s8 | s2 | 133,310 | 106,904 | 26,406 | 24.7007% | s8 | 24.7007% |
| 5 | [polybench/p32-jacobi-1d-imper-l00](.cache/wrong-predictions-updated-final/artifacts/polybench_p32-jacobi-1d-imper-l00-e35be639/meta/run-x6mb1amw/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/polybench_p32-jacobi-1d-imper-l00-e35be639/meta/run-x6mb1amw/backend/candidate-status.json) | s8 | s2 | 132,591 | 107,049 | 25,542 | 23.8601% | s8 | 23.8601% |
| 6 | [polybench/p421-jacobi-1d-l00](.cache/wrong-predictions-updated-final/artifacts/polybench_p421-jacobi-1d-l00-9ab66748/meta/run-1pwwm6j0/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/polybench_p421-jacobi-1d-l00-9ab66748/meta/run-1pwwm6j0/backend/candidate-status.json) | s8 | s2 | 132,591 | 107,049 | 25,542 | 23.8601% | s8 | 23.8601% |
| 7 | [rajaperf/dot](.cache/wrong-predictions-updated-final/artifacts/rajaperf_dot-e736b8f0/meta/run-v5h9zeo7/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/rajaperf_dot-e736b8f0/meta/run-v5h9zeo7/backend/candidate-status.json) | s8 | s2 | 6,255 | 5,138 | 1,117 | 21.7400% | s8 | 21.7400% |
| 8 | [lcals/first-diff](.cache/wrong-predictions-updated-final/artifacts/lcals_first-diff-1e964f79/meta/run-55gnqcg3/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/lcals_first-diff-1e964f79/meta/run-55gnqcg3/backend/candidate-status.json) | s8 | s4 | 1,606 | 1,322 | 284 | 21.4826% | s8 | 21.4826% |
| 9 | [tsvc/tsvc-s116-l00](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s116-l00-abbc6fd5/meta/run-chvve69f/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s116-l00-abbc6fd5/meta/run-chvve69f/backend/candidate-status.json) | s16 | s8 | 123,524 | 102,133 | 21,391 | 20.9443% | s16 | 20.9443% |
| 10 | [tsvc/tsvc-s127-l00](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s127-l00-05409684/meta/run-6kpvioyn/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s127-l00-05409684/meta/run-6kpvioyn/backend/candidate-status.json) | s8 | s16 | 378,206 | 312,810 | 65,396 | 20.9060% | f32 | 평가 제외 |
| 11 | [polybench/p32-gemver-l02](.cache/wrong-predictions-updated-final/artifacts/polybench_p32-gemver-l02-2380c05b/meta/run-nlbxwq8m/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/polybench_p32-gemver-l02-2380c05b/meta/run-nlbxwq8m/backend/candidate-status.json) | s8 | s2 | 23,624 | 19,724 | 3,900 | 19.7729% | s8 | 19.7729% |
| 12 | [rajaperf/init3](.cache/wrong-predictions-updated-final/artifacts/rajaperf_init3-95a32e1a/meta/run-7gbgu8ea/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/rajaperf_init3-95a32e1a/meta/run-7gbgu8ea/backend/candidate-status.json) | s8 | s4 | 17,207 | 14,424 | 2,783 | 19.2942% | s8 | 19.2942% |
| 13 | [lcals/pressure-calc-l01](.cache/wrong-predictions-updated-final/artifacts/lcals_pressure-calc-l01-aa0a9cb1/meta/run-gi6hwy6x/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/lcals_pressure-calc-l01-aa0a9cb1/meta/run-gi6hwy6x/backend/candidate-status.json) | s8 | s2 | 3,061 | 2,604 | 457 | 17.5499% | s8 | 17.5499% |
| 14 | [rajaperf/int-predict](.cache/wrong-predictions-updated-final/artifacts/rajaperf_int-predict-f2d1b908/meta/run-xi6fg4hf/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/rajaperf_int-predict-f2d1b908/meta/run-xi6fg4hf/backend/candidate-status.json) | s4 | s8 | 42,986 | 37,205 | 5,781 | 15.5382% | s8 | 0.0000% |
| 15 | [rajaperf/gen-lin-recur-reverse](.cache/wrong-predictions-updated-final/artifacts/rajaperf_gen-lin-recur-reverse-52b65c3b/meta/run-mua39tfi/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/rajaperf_gen-lin-recur-reverse-52b65c3b/meta/run-mua39tfi/backend/candidate-status.json) | s8 | s4 | 14,480 | 12,609 | 1,871 | 14.8386% | s8 | 14.8386% |
| 16 | [tsvc/tsvc-s176-l00](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s176-l00-a186d0cf/meta/run-ek2zi6mi/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s176-l00-a186d0cf/meta/run-ek2zi6mi/backend/candidate-status.json) | s16 | s4 | 49,181 | 42,984 | 6,197 | 14.4170% | s16 | 14.4170% |
| 17 | [lcals/band-lin-eq-outer](.cache/wrong-predictions-updated-final/artifacts/lcals_band-lin-eq-outer-4e64cad2/meta/run-_9asl6rg/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/lcals_band-lin-eq-outer-4e64cad2/meta/run-_9asl6rg/backend/candidate-status.json) | s4 | s8 | 1,571 | 1,374 | 197 | 14.3377% | s4 | 14.3377% |
| 18 | [rajaperf/reduce-struct](.cache/wrong-predictions-updated-final/artifacts/rajaperf_reduce-struct-2fb15f36/meta/run-4zgskywr/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/rajaperf_reduce-struct-2fb15f36/meta/run-4zgskywr/backend/candidate-status.json) | s4 | s2 | 6,809 | 6,019 | 790 | 13.1251% | s4 | 13.1251% |
| 19 | [polybench/p421-gemm-l01](.cache/wrong-predictions-updated-final/artifacts/polybench_p421-gemm-l01-192dbd1e/meta/run-8q_3m6j0/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/polybench_p421-gemm-l01-192dbd1e/meta/run-8q_3m6j0/backend/candidate-status.json) | s8 | s4 | 6,695 | 5,963 | 732 | 12.2757% | s8 | 12.2757% |
| 20 | [rajaperf/daxpy](.cache/wrong-predictions-updated-final/artifacts/rajaperf_daxpy-3966eff4/meta/run-n5qmb_2w/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/rajaperf_daxpy-3966eff4/meta/run-n5qmb_2w/backend/candidate-status.json) | s8 | s2 | 5,844 | 5,208 | 636 | 12.2120% | s8 | 12.2120% |
| 21 | [tsvc/tsvc-s171-l00](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s171-l00-21a03b56/meta/run-tyf2vv1x/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s171-l00-21a03b56/meta/run-tyf2vv1x/backend/candidate-status.json) | s16 | s4 | 112,967 | 100,680 | 12,287 | 12.2040% | s16 | 12.2040% |
| 22 | [tsvc/tsvc-s172-l00](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s172-l00-c3a4cfce/meta/run-0h0zorf0/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s172-l00-c3a4cfce/meta/run-0h0zorf0/backend/candidate-status.json) | s16 | s4 | 112,967 | 100,680 | 12,287 | 12.2040% | s16 | 12.2040% |
| 23 | [tsvc/tsvc-s119-l00](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s119-l00-7c5e355c/meta/run-1lez7jvu/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s119-l00-7c5e355c/meta/run-1lez7jvu/backend/candidate-status.json) | s16 | s8 | 1,068 | 960 | 108 | 11.2500% | s16 | 11.2500% |
| 24 | [rajaperf/gen-lin-recur-forward](.cache/wrong-predictions-updated-final/artifacts/rajaperf_gen-lin-recur-forward-2d89df0b/meta/run-qij4mrbq/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/rajaperf_gen-lin-recur-forward-2d89df0b/meta/run-qij4mrbq/backend/candidate-status.json) | s8 | s4 | 13,844 | 12,530 | 1,314 | 10.4868% | s8 | 10.4868% |
| 25 | [tsvc/tsvc-s114-l00](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s114-l00-9cee7768/meta/run-vligdwn7/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s114-l00-9cee7768/meta/run-vligdwn7/backend/candidate-status.json) | s16 | s2 | 5,835 | 5,342 | 493 | 9.2288% | s16 | 9.2288% |
| 26 | [tsvc/tsvc-s118-l00](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s118-l00-fc4312b6/meta/run-a_flkmee/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s118-l00-fc4312b6/meta/run-a_flkmee/backend/candidate-status.json) | s16 | s1 | 6,744 | 6,180 | 564 | 9.1262% | s16 | 9.1262% |
| 27 | [rajaperf/triad](.cache/wrong-predictions-updated-final/artifacts/rajaperf_triad-74b1a1d1/meta/run-o8ynx5au/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/rajaperf_triad-74b1a1d1/meta/run-o8ynx5au/backend/candidate-status.json) | s8 | s2 | 6,800 | 6,269 | 531 | 8.4703% | s8 | 8.4703% |
| 28 | [tsvc/tsvc-s1119-l00](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s1119-l00-4f9ad8fa/meta/run-z15hq2a7/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s1119-l00-4f9ad8fa/meta/run-z15hq2a7/backend/candidate-status.json) | s16 | s4 | 1,045 | 964 | 81 | 8.4025% | s16 | 8.4025% |
| 29 | [lcals/energy-calc-l03](.cache/wrong-predictions-updated-final/artifacts/lcals_energy-calc-l03-5a111bb6/meta/run-ybnsvyx9/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/lcals_energy-calc-l03-5a111bb6/meta/run-ybnsvyx9/backend/candidate-status.json) | s8 | s4 | 1,527 | 1,418 | 109 | 7.6869% | s8 | 7.6869% |
| 30 | [lcals/energy-calc-l04](.cache/wrong-predictions-updated-final/artifacts/lcals_energy-calc-l04-9d0673bd/meta/run-8na8cjct/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/lcals_energy-calc-l04-9d0673bd/meta/run-8na8cjct/backend/candidate-status.json) | s2 | s4 | 11,820 | 11,017 | 803 | 7.2887% | s4 | 0.0000% |
| 31 | [rajaperf/reduce-sum](.cache/wrong-predictions-updated-final/artifacts/rajaperf_reduce-sum-c7209cc1/meta/run-avse435z/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/rajaperf_reduce-sum-c7209cc1/meta/run-avse435z/backend/candidate-status.json) | s8 | s4 | 3,257 | 3,057 | 200 | 6.5424% | s8 | 6.5424% |
| 32 | [rajaperf/muladdsub](.cache/wrong-predictions-updated-final/artifacts/rajaperf_muladdsub-350a953b/meta/run-5yho198q/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/rajaperf_muladdsub-350a953b/meta/run-5yho198q/backend/candidate-status.json) | s8 | s4 | 15,641 | 14,689 | 952 | 6.4810% | s8 | 6.4810% |
| 33 | [rajaperf/eos](.cache/wrong-predictions-updated-final/artifacts/rajaperf_eos-a5c99505/meta/run-78rydsgt/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/rajaperf_eos-a5c99505/meta/run-78rydsgt/backend/candidate-status.json) | s4 | s2 | 21,994 | 20,795 | 1,199 | 5.7658% | s4 | 5.7658% |
| 34 | [rajaperf/first-diff](.cache/wrong-predictions-updated-final/artifacts/rajaperf_first-diff-62f6f81e/meta/run-k128zcp3/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/rajaperf_first-diff-62f6f81e/meta/run-k128zcp3/backend/candidate-status.json) | s8 | s4 | 9,510 | 9,019 | 491 | 5.4441% | s8 | 5.4441% |
| 35 | [rajaperf/if-quad](.cache/wrong-predictions-updated-final/artifacts/rajaperf_if-quad-183490a8/meta/run-u9l269sc/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/rajaperf_if-quad-183490a8/meta/run-u9l269sc/backend/candidate-status.json) | s4 | s2 | 19,624 | 18,646 | 978 | 5.2451% | s4 | 5.2451% |
| 36 | [rajaperf/if-quad-builtin](.cache/wrong-predictions-updated-final/artifacts/rajaperf_if-quad-builtin-6c7a4061/meta/run-vcorn5p6/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/rajaperf_if-quad-builtin-6c7a4061/meta/run-vcorn5p6/backend/candidate-status.json) | s4 | s2 | 19,624 | 18,646 | 978 | 5.2451% | s4 | 5.2451% |
| 37 | [lcals/pressure-calc-l00](.cache/wrong-predictions-updated-final/artifacts/lcals_pressure-calc-l00-eb73f211/meta/run-vtkt3x46/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/lcals_pressure-calc-l00-eb73f211/meta/run-vtkt3x46/backend/candidate-status.json) | s8 | s4 | 1,009 | 961 | 48 | 4.9948% | s8 | 4.9948% |
| 38 | [polybench/p32-gemm-l00](.cache/wrong-predictions-updated-final/artifacts/polybench_p32-gemm-l00-ac3f2df9/meta/run-22k3ml3b/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/polybench_p32-gemm-l00-ac3f2df9/meta/run-22k3ml3b/backend/candidate-status.json) | s8 | s1 | 69,305 | 67,207 | 2,098 | 3.1217% | s8 | 3.1217% |
| 39 | [tsvc/tsvc-s173-l00](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s173-l00-48d51ecc/meta/run-30iul76v/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s173-l00-48d51ecc/meta/run-30iul76v/backend/candidate-status.json) | s16 | s4 | 59,268 | 57,554 | 1,714 | 2.9781% | s16 | 2.9781% |
| 40 | [tsvc/tsvc-s174-l00](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s174-l00-bd9fa068/meta/run-z_grq3x8/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s174-l00-bd9fa068/meta/run-z_grq3x8/backend/candidate-status.json) | s16 | s4 | 59,268 | 57,554 | 1,714 | 2.9781% | s16 | 2.9781% |
| 41 | [lcals/init3](.cache/wrong-predictions-updated-final/artifacts/lcals_init3-3d272b8a/meta/run-a37xti9u/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/lcals_init3-3d272b8a/meta/run-a37xti9u/backend/candidate-status.json) | s8 | s2 | 2,784 | 2,714 | 70 | 2.5792% | s8 | 2.5792% |
| 42 | [polybench/p32-atax-l00](.cache/wrong-predictions-updated-final/artifacts/polybench_p32-atax-l00-671335a6/meta/run-3ybm7pls/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/polybench_p32-atax-l00-671335a6/meta/run-3ybm7pls/backend/candidate-status.json) | s8 | s2 | 13,752 | 13,436 | 316 | 2.3519% | s8 | 2.3519% |
| 43 | [polybench/p32-bicg-l00](.cache/wrong-predictions-updated-final/artifacts/polybench_p32-bicg-l00-68d57011/meta/run-sylv_akx/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/polybench_p32-bicg-l00-68d57011/meta/run-sylv_akx/backend/candidate-status.json) | s8 | s2 | 13,752 | 13,436 | 316 | 2.3519% | s8 | 2.3519% |
| 44 | [tsvc/tsvc-s132-l00](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s132-l00-f0d6c836/meta/run-rvpq8vv5/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s132-l00-f0d6c836/meta/run-rvpq8vv5/backend/candidate-status.json) | s16 | s8 | 1,024 | 1,002 | 22 | 2.1956% | s16 | 2.1956% |
| 45 | [lcals/muladdsub](.cache/wrong-predictions-updated-final/artifacts/lcals_muladdsub-977367b6/meta/run-t0ppjiys/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/lcals_muladdsub-977367b6/meta/run-t0ppjiys/backend/candidate-status.json) | s8 | s2 | 2,767 | 2,708 | 59 | 2.1787% | s8 | 2.1787% |
| 46 | [polybench/p32-bicg-l01](.cache/wrong-predictions-updated-final/artifacts/polybench_p32-bicg-l01-e0d83bc0/meta/run-_2r536k_/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/polybench_p32-bicg-l01-e0d83bc0/meta/run-_2r536k_/backend/candidate-status.json) | s8 | s4 | 40,732 | 39,926 | 806 | 2.0187% | s8 | 2.0187% |
| 47 | [lcals/inner-prod](.cache/wrong-predictions-updated-final/artifacts/lcals_inner-prod-93100f71/meta/run-v47x00g5/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/lcals_inner-prod-93100f71/meta/run-v47x00g5/backend/candidate-status.json) | s8 | s4 | 1,292 | 1,267 | 25 | 1.9732% | s8 | 1.9732% |
| 48 | [rajaperf/first-sum](.cache/wrong-predictions-updated-final/artifacts/rajaperf_first-sum-7312297a/meta/run-auwnys76/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/rajaperf_first-sum-7312297a/meta/run-auwnys76/backend/candidate-status.json) | s8 | s4 | 5,609 | 5,545 | 64 | 1.1542% | s8 | 1.1542% |
| 49 | [hpcc/stream-copy](.cache/wrong-predictions-updated-final/artifacts/hpcc_stream-copy-ad6615d9/meta/run-i07tg9zl/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/hpcc_stream-copy-ad6615d9/meta/run-i07tg9zl/backend/candidate-status.json) | s8 | s4 | 5,007 | 4,960 | 47 | 0.9476% | s8 | 0.9476% |
| 50 | [rajaperf/add](.cache/wrong-predictions-updated-final/artifacts/rajaperf_add-0d156cf5/meta/run-0v5pjagr/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/rajaperf_add-0d156cf5/meta/run-0v5pjagr/backend/candidate-status.json) | s8 | s4 | 7,469 | 7,418 | 51 | 0.6875% | s8 | 0.6875% |
| 51 | [lcals/band-lin-eq-inner](.cache/wrong-predictions-updated-final/artifacts/lcals_band-lin-eq-inner-ed39b648/meta/run-wa66zj1f/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/lcals_band-lin-eq-inner-ed39b648/meta/run-wa66zj1f/backend/candidate-status.json) | s4 | s8 | 719 | 715 | 4 | 0.5594% | s4 | 0.5594% |
| 52 | [lcals/energy-calc-l02](.cache/wrong-predictions-updated-final/artifacts/lcals_energy-calc-l02-53eb21ea/meta/run-jegnlldt/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/lcals_energy-calc-l02-53eb21ea/meta/run-jegnlldt/backend/candidate-status.json) | s8 | s4 | 3,286 | 3,274 | 12 | 0.3665% | s4 | 0.0000% |
| 53 | [polybench/p421-floyd-warshall-full](.cache/wrong-predictions-updated-final/artifacts/polybench_p421-floyd-warshall-full-e582b111/meta/run-2fo_2fxz/kernel.c) · [cost](.cache/wrong-predictions-updated-final/artifacts/polybench_p421-floyd-warshall-full-e582b111/meta/run-2fo_2fxz/backend/candidate-status.json) | s16 | s8 | 847,706 | 847,655 | 51 | 0.0060% | s16 | 0.0060% |

## 판정 변화

- 이전 오예측 해결 (8개): `lcals/energy-calc-l01`, `lcals/energy-calc-l05`, `polybench/p32-gesummv-l00`, `rajaperf/pi-reduce`, `rajaperf/trap-int`, `rajaperf/trap-int-builtin`, `tsvc/tsvc-s1232-l00`, `tsvc/tsvc-s124-l00`.
- 새 오예측 (3개): `lcals/energy-calc-l02`, `lcals/energy-calc-l04`, `rajaperf/int-predict`.
- 새 평가 제외 (2개): `lcals/fir-inner`, `lcals/fir-outer`.
- 새 평가 가능 (1개): `tsvc/tsvc-s127-l00`.

평가 제외로 바뀐 항목은 오예측 해결에 포함하지 않았다.

## 전체 제외 목록

| Benchmark | 상태 | 구체적 사유 / artifact |
| --- | --- | --- |
| [lcals/fir-inner](.cache/wrong-predictions-updated-final/artifacts/lcals_fir-inner-04446895/meta/run-x2omc9t8/kernel.c) | `backend-observation-unavailable` | selected_kernel:0:1:s8: cannot prove original-iteration mapping after IR optimization; selected_kernel:0:1:s16: cannot prove original-iteration mapping after IR optimization · [status](.cache/wrong-predictions-updated-final/artifacts/lcals_fir-inner-04446895/meta/run-x2omc9t8/backend/candidate-status.json) [selected_kernel:0:1:s8 analytics](.cache/wrong-predictions-updated-final/artifacts/lcals_fir-inner-04446895/meta/run-x2omc9t8/backend/probe-0003.analytics.json); [selected_kernel:0:1:s8 compiler log](.cache/wrong-predictions-updated-final/artifacts/lcals_fir-inner-04446895/meta/run-x2omc9t8/backend/probe-0003.stderr); [selected_kernel:0:1:s16 analytics](.cache/wrong-predictions-updated-final/artifacts/lcals_fir-inner-04446895/meta/run-x2omc9t8/backend/probe-0004.analytics.json); [selected_kernel:0:1:s16 compiler log](.cache/wrong-predictions-updated-final/artifacts/lcals_fir-inner-04446895/meta/run-x2omc9t8/backend/probe-0004.stderr) |
| [lcals/fir-outer](.cache/wrong-predictions-updated-final/artifacts/lcals_fir-outer-16dfa90e/meta/run-81_j4on5/kernel.c) | `backend-observation-unavailable` | selected_kernel:0:1:s8: cannot prove original-iteration mapping after IR optimization; selected_kernel:0:1:s16: cannot prove original-iteration mapping after IR optimization · [status](.cache/wrong-predictions-updated-final/artifacts/lcals_fir-outer-16dfa90e/meta/run-81_j4on5/backend/candidate-status.json) [selected_kernel:0:1:s8 analytics](.cache/wrong-predictions-updated-final/artifacts/lcals_fir-outer-16dfa90e/meta/run-81_j4on5/backend/probe-0003.analytics.json); [selected_kernel:0:1:s8 compiler log](.cache/wrong-predictions-updated-final/artifacts/lcals_fir-outer-16dfa90e/meta/run-81_j4on5/backend/probe-0003.stderr); [selected_kernel:0:1:s16 analytics](.cache/wrong-predictions-updated-final/artifacts/lcals_fir-outer-16dfa90e/meta/run-81_j4on5/backend/probe-0004.analytics.json); [selected_kernel:0:1:s16 compiler log](.cache/wrong-predictions-updated-final/artifacts/lcals_fir-outer-16dfa90e/meta/run-81_j4on5/backend/probe-0004.stderr) |
| [polybench/p32-adi-full](.cache/wrong-predictions-updated-final/artifacts/polybench_p32-adi-full-2fd7f411/meta/run-gmx4ha2m/kernel.c) | `ambiguous-loops` | expected one selected_kernel loop · [status](.cache/wrong-predictions-updated-final/artifacts/polybench_p32-adi-full-2fd7f411/meta/run-gmx4ha2m/backend/candidate-status.json)  |
| [polybench/p32-fdtd-2d-full](.cache/wrong-predictions-updated-final/artifacts/polybench_p32-fdtd-2d-full-85f4b50e/meta/run-0qf6h_v9/kernel.c) | `ambiguous-loops` | expected one selected_kernel loop · [status](.cache/wrong-predictions-updated-final/artifacts/polybench_p32-fdtd-2d-full-85f4b50e/meta/run-0qf6h_v9/backend/candidate-status.json)  |
| [polybench/p32-jacobi-1d-imper-full](.cache/wrong-predictions-updated-final/artifacts/polybench_p32-jacobi-1d-imper-full-e61c1c36/meta/run-b5kbguu1/kernel.c) | `ambiguous-loops` | expected one selected_kernel loop · [status](.cache/wrong-predictions-updated-final/artifacts/polybench_p32-jacobi-1d-imper-full-e61c1c36/meta/run-b5kbguu1/backend/candidate-status.json)  |
| [polybench/p32-jacobi-2d-imper-full](.cache/wrong-predictions-updated-final/artifacts/polybench_p32-jacobi-2d-imper-full-67087142/meta/run-33pfs9o_/kernel.c) | `ambiguous-loops` | expected one selected_kernel loop · [status](.cache/wrong-predictions-updated-final/artifacts/polybench_p32-jacobi-2d-imper-full-67087142/meta/run-33pfs9o_/backend/candidate-status.json)  |
| [polybench/p421-fdtd-2d-full](.cache/wrong-predictions-updated-final/artifacts/polybench_p421-fdtd-2d-full-3b80f0fa/meta/run-l_btu3x5/kernel.c) | `ambiguous-loops` | expected one selected_kernel loop · [status](.cache/wrong-predictions-updated-final/artifacts/polybench_p421-fdtd-2d-full-3b80f0fa/meta/run-l_btu3x5/backend/candidate-status.json)  |
| [polybench/p421-heat-3d-full](.cache/wrong-predictions-updated-final/artifacts/polybench_p421-heat-3d-full-422ad5f5/meta/run-igkkq97j/kernel.c) | `ambiguous-loops` | expected one selected_kernel loop · [status](.cache/wrong-predictions-updated-final/artifacts/polybench_p421-heat-3d-full-422ad5f5/meta/run-igkkq97j/backend/candidate-status.json)  |
| [polybench/p421-jacobi-1d-full](.cache/wrong-predictions-updated-final/artifacts/polybench_p421-jacobi-1d-full-cb6eb4ac/meta/run-mkd26_f8/kernel.c) | `ambiguous-loops` | expected one selected_kernel loop · [status](.cache/wrong-predictions-updated-final/artifacts/polybench_p421-jacobi-1d-full-cb6eb4ac/meta/run-mkd26_f8/backend/candidate-status.json)  |
| [polybench/p421-jacobi-1d-outer](.cache/wrong-predictions-updated-final/artifacts/polybench_p421-jacobi-1d-outer-c96619a9/meta/run-sh4o6hv1/kernel.c) | `ambiguous-loops` | expected one selected_kernel loop · [status](.cache/wrong-predictions-updated-final/artifacts/polybench_p421-jacobi-1d-outer-c96619a9/meta/run-sh4o6hv1/backend/candidate-status.json)  |
| [polybench/p421-jacobi-2d-full](.cache/wrong-predictions-updated-final/artifacts/polybench_p421-jacobi-2d-full-ab8ba81c/meta/run-w3_i71wd/kernel.c) | `ambiguous-loops` | expected one selected_kernel loop · [status](.cache/wrong-predictions-updated-final/artifacts/polybench_p421-jacobi-2d-full-ab8ba81c/meta/run-w3_i71wd/backend/candidate-status.json)  |
| [rajaperf/planckian](.cache/wrong-predictions-updated-final/artifacts/rajaperf_planckian-4f26d45c/meta/run-ktp8xps5/kernel.c) | `missing-measurements` | missing measurements for compiler VF(s): s1 · [status](.cache/wrong-predictions-updated-final/artifacts/rajaperf_planckian-4f26d45c/meta/run-ktp8xps5/backend/candidate-status.json)  |
| [tsvc/tsvc-s1111-l00](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s1111-l00-ad05c621/meta/run-jomzs__7/kernel.c) | `unmeasured-vf` | no measurement for f16 · [status](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s1111-l00-ad05c621/meta/run-jomzs__7/backend/candidate-status.json)  |
| [tsvc/tsvc-s1113-l00](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s1113-l00-2ef597be/meta/run-a3ii5717/kernel.c) | `ambiguous-loops` | expected one selected_kernel loop · [status](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s1113-l00-2ef597be/meta/run-a3ii5717/backend/candidate-status.json)  |
| [tsvc/tsvc-s1161-l00](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s1161-l00-8319d9b6/meta/run-3va0h3i7/kernel.c) | `ambiguous-loops` | expected one selected_kernel loop · [status](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s1161-l00-8319d9b6/meta/run-3va0h3i7/backend/candidate-status.json)  |
| [tsvc/tsvc-s161-l00](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s161-l00-55898968/meta/run-73r8uvsf/kernel.c) | `ambiguous-loops` | expected one selected_kernel loop · [status](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s161-l00-55898968/meta/run-73r8uvsf/backend/candidate-status.json)  |
| [tsvc/tsvc-s212-l00](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s212-l00-6534addd/meta/run-fzxg523k/kernel.c) | `ambiguous-loops` | expected one selected_kernel loop · [status](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s212-l00-6534addd/meta/run-fzxg523k/backend/candidate-status.json)  |
| [tsvc/tsvc-s221-l00](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s221-l00-1c34c305/meta/run-pii4bmvs/kernel.c) | `ambiguous-loops` | expected one selected_kernel loop · [status](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s221-l00-1c34c305/meta/run-pii4bmvs/backend/candidate-status.json)  |

## gesummv 회귀와 가장 큰 regret

`polybench/p32-gesummv-l00`: 이전 s8 / regret 68.2775% → 새 s4 / regret 0.0000%. [후보별 비용 및 관측](.cache/wrong-predictions-updated-final/artifacts/polybench_p32-gesummv-l00-dafb28b1/meta/run-juln8130/backend/candidate-status.json)과 같은 디렉터리의 final.manifest.json에서 s4 materialization을 확인했다.

| VF | 기존 body | LLVM spill 추정 | m8 spill/reload | 새 spill 비용 | effective body | whole-loop score |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| f16 | 90 | 0 | 3/3 | 48 | 138 | 34500 |
| s4 | 46 | 0 | 0/0 | 0 | 46 | 23000 |
| s8 | 90 | 0 | 3/3 | 48 | 138 | 34500 |

새 모델에서 가장 큰 regret은 [tsvc/tsvc-s111-l00](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s111-l00-90373715/meta/run-pc37xnyh/kernel.c): s16 선택, 최적 s2, regret 55.0636%. [모든 fixed/scalable 후보 비용](.cache/wrong-predictions-updated-final/artifacts/tsvc_tsvc-s111-l00-90373715/meta/run-pc37xnyh/backend/candidate-status.json)에 원본 LLVM 비용, 실제 spill/reload bank/group, TTI 단가와 effective cost가 있다.

| VF | LLVM body | LLVM spill 추정 | backend spill 비용 | effective body | model score | DB cycles |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| s2 | 19 | 0 | 0 | 19 | 76000 | 248,153 |
| s16 | 177 | 32 | 0 | 145 | 72500 | 384,795 |

## Detail parser 검증

gesummv [원본 detail](.cache/backend-spill-detail-corpus-final/polybench_p32-gesummv-l00-dafb28b1/detail.txt) → [parser JSON](.cache/backend-spill-detail-corpus-final/polybench_p32-gesummv-l00-dafb28b1/detail.json) → 원본 manifest 비용 8개 후보의 일치를 검증했다. 보정 후 비용은 별도 derived breakdown으로 확인했다.
현재 checkout의 report_version=2 전체 구조를 지원한다. 117개 benchmark에서 137개 report를 검사했고, 미인식 0개, 오류 0개다. [corpus summary](.cache/backend-spill-detail-corpus-final/summary.json)에 각 원본 detail.txt / parser JSON 경로와 record별 coverage가 있다.
- 실제 gesummv detail, 중첩 계산, 같은 VF의 반복 evaluation, scalar instruction/block weighting, candidate/component 합계와 원본 manifest 대응을 검사했다.
- DB에 없는 size/epilogue/shortcut/Invalid/fractional/forced-cost 경로는 renderer와 기존 AArch64 LLVM 테스트에 근거한 합성 fixture로 검사했다. 공유 빌드에는 opt/AArch64 target이 없어 그 타깃의 compiler 테스트는 실행하지 않았다.
- 전체 알려진 record inventory와 fixture 대응: [coverage 표](utils/vplan-tools/tests/fixtures/README.md). strict 모드는 report 내부 새 record/field와 잘린 경계, 중복 ID, 잘못된 참조 및 accounting 오류를 거부한다. TTI 내부 계산은 추정해 만들지 않는다.

## 재현

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate \
  --db search-dataset.sqlite --output-dir .cache/backend-spill-new-run \
  --artifacts-dir .cache/backend-spill-new-run/artifacts \
  --skip-build --build-dir build-vplan-tools --compare-baseline
uv run --project utils/vplan-tools python utils/vplan-tools/validate-detail-corpus \
  --db search-dataset.sqlite --output-dir .cache/detail-new-run \
  --skip-build --build-dir build-vplan-tools
uv run --project utils/vplan-tools python utils/vplan-tools/write-updated-report \
  --summary .cache/wrong-predictions-updated-final/summary.json \
  --baseline .cache/wrong-predictions-current/summary.json \
  --corpus .cache/backend-spill-detail-corpus-final/summary.json --db search-dataset.sqlite --output wrong-predictions-spillcost.md
```

Artifact는 `.cache/`에 저장되어 Git에서 추적하지 않는다. 문서를 이동할 때 source·analytics·compiler logs·JSON도 함께 보존해야 한다. 기존 `wrong-predictions-baseline.md`, baseline artifact 및 측정 DB는 보존했다.
