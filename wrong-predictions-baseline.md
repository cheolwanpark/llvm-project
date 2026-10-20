# LLVM middle-end model: wrong predictions

평가일: 2026-10-20 (Asia/Seoul). 현재 체크아웃의 고정 `llvm-middle-end` 모델로 `search-dataset.sqlite` 전체를 다시 평가했다. 요청의 DB 이름은 확인 후 실제 파일명인 `search-dataset.sqlite`로 적용했다.

전체 **117개** 중 **100개**를 평가했고, **59개가 오예측**, **41개가 정답**이다. Top-1 정확도는 **41.00%**이며, 평가 제외는 **17개**, 컴파일 실패는 **0개**다.

일반 LLVM middle-end와 비교 가능한 **103개 모두 VF와 전체 선택이 일치**했다. 비교 불가능한 14개는 일치율 분모에서 제외했다. 아래 오예측 59개도 모두 일반 LLVM과 같은 선택을 했다.

## 판정 및 정렬 기준

- 평가 단위는 benchmark ID 하나이며, `tuning`/`validation`이라는 기존 split 이름과 관계없이 전체를 평가했다. 학습이나 파라미터 조정은 하지 않았다.
- 최적 VF는 **현재 컴파일러가 생성한 scalable 후보 중 측정 cycles가 최소인 VF**다. DB에만 있고 현재 후보 집합에는 없는 VF는 제외했다.
- 오예측은 모델 선택 VF가 최적 VF와 다른 경우다. 측정 cycles 동률은 evaluator와 동일하게 작은 VF를 정답으로 택한다. 이번 오예측에는 regret이 0인 동률 사례가 없다.
- `regret = (모델 선택 VF의 측정 cycles / 최적 VF의 측정 cycles) - 1`. 표는 regret을 백분율로 표시하며, 반올림 전 정확한 비율 내림차순, 동률이면 benchmark ID 오름차순이다.
- `sN`은 scalable VF 계수이며 `s1`도 벡터다. Scalar `f1`이나 LMUL 값으로 해석하지 않는다. 실행 조건은 RISC-V, VLEN=128, IC=1, vector epilogue 없음이다.
- cycles는 DB에 저장된 workload 전체 측정값이다. 정규화한 단일 반복 비용이나 모델 cost 단위가 아니다. 새 실행 측정은 하지 않았다.

평가 가능 100개 전체의 평균 regret은 **7.3184%**, 중앙값은 **2.0987%**, P95는 **24.8170%**다. 오예측 59개만의 평균 regret은 **12.4041%**다.

## 오예측 전체 — regret 내림차순

Benchmark 링크는 해당 DB에서 추출한 소스, cost 링크는 현재 모델의 후보별 cost 및 breakdown이다. `초과 cycles = 선택 cycles − 최적 cycles`다.

| 순위 | Benchmark / 모델 cost | 선택 VF | 최적 VF | 선택 cycles | 최적 cycles | 초과 cycles | Regret |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | [polybench/p32-gesummv-l00](.cache/wrong-predictions-current/artifacts/polybench_p32-gesummv-l00-dafb28b1/meta/run-ss57f9ye/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/polybench_p32-gesummv-l00-dafb28b1/meta/run-ss57f9ye/backend/candidate-status.json) | s8 | s4 | 55,020 | 32,696 | 22,324 | 68.2775% |
| 2 | [tsvc/tsvc-s111-l00](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s111-l00-90373715/meta/run-bn1har9k/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s111-l00-90373715/meta/run-bn1har9k/backend/candidate-status.json) | s8 | s2 | 373,527 | 248,153 | 125,374 | 50.5229% |
| 3 | [tsvc/tsvc-s1213-l00](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s1213-l00-34954cae/meta/run-035ef2tt/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s1213-l00-34954cae/meta/run-035ef2tt/backend/candidate-status.json) | s16 | s8 | 263,150 | 182,483 | 80,667 | 44.2052% |
| 4 | [tsvc/tsvc-s128-l00](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s128-l00-28527a6c/meta/run-9j83rj7t/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s128-l00-28527a6c/meta/run-9j83rj7t/backend/candidate-status.json) | s8 | s2 | 388,255 | 283,639 | 104,616 | 36.8835% |
| 5 | [lcals/fir-inner](.cache/wrong-predictions-current/artifacts/lcals_fir-inner-04446895/meta/run-vsg2ygoc/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/lcals_fir-inner-04446895/meta/run-vsg2ygoc/backend/candidate-status.json) | s8 | s16 | 329 | 259 | 70 | 27.0270% |
| 6 | [polybench/p421-jacobi-1d-l01](.cache/wrong-predictions-current/artifacts/polybench_p421-jacobi-1d-l01-4aae641c/meta/run-ulpq_ivo/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/polybench_p421-jacobi-1d-l01-4aae641c/meta/run-ulpq_ivo/backend/candidate-status.json) | s8 | s2 | 133,310 | 106,904 | 26,406 | 24.7007% |
| 7 | [polybench/p32-jacobi-1d-imper-l00](.cache/wrong-predictions-current/artifacts/polybench_p32-jacobi-1d-imper-l00-e35be639/meta/run-75rte_ay/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/polybench_p32-jacobi-1d-imper-l00-e35be639/meta/run-75rte_ay/backend/candidate-status.json) | s8 | s2 | 132,591 | 107,049 | 25,542 | 23.8601% |
| 8 | [polybench/p421-jacobi-1d-l00](.cache/wrong-predictions-current/artifacts/polybench_p421-jacobi-1d-l00-9ab66748/meta/run-vwkencpn/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/polybench_p421-jacobi-1d-l00-9ab66748/meta/run-vwkencpn/backend/candidate-status.json) | s8 | s2 | 132,591 | 107,049 | 25,542 | 23.8601% |
| 9 | [rajaperf/dot](.cache/wrong-predictions-current/artifacts/rajaperf_dot-e736b8f0/meta/run-mdl2k9gr/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/rajaperf_dot-e736b8f0/meta/run-mdl2k9gr/backend/candidate-status.json) | s8 | s2 | 6,255 | 5,138 | 1,117 | 21.7400% |
| 10 | [lcals/first-diff](.cache/wrong-predictions-current/artifacts/lcals_first-diff-1e964f79/meta/run-ed9ec5e7/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/lcals_first-diff-1e964f79/meta/run-ed9ec5e7/backend/candidate-status.json) | s8 | s4 | 1,606 | 1,322 | 284 | 21.4826% |
| 11 | [tsvc/tsvc-s116-l00](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s116-l00-abbc6fd5/meta/run-lxdo0i46/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s116-l00-abbc6fd5/meta/run-lxdo0i46/backend/candidate-status.json) | s16 | s8 | 123,524 | 102,133 | 21,391 | 20.9443% |
| 12 | [polybench/p32-gemver-l02](.cache/wrong-predictions-current/artifacts/polybench_p32-gemver-l02-2380c05b/meta/run-2wcg5tqi/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/polybench_p32-gemver-l02-2380c05b/meta/run-2wcg5tqi/backend/candidate-status.json) | s8 | s2 | 23,624 | 19,724 | 3,900 | 19.7729% |
| 13 | [rajaperf/init3](.cache/wrong-predictions-current/artifacts/rajaperf_init3-95a32e1a/meta/run-s7k58_62/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/rajaperf_init3-95a32e1a/meta/run-s7k58_62/backend/candidate-status.json) | s8 | s4 | 17,207 | 14,424 | 2,783 | 19.2942% |
| 14 | [lcals/pressure-calc-l01](.cache/wrong-predictions-current/artifacts/lcals_pressure-calc-l01-aa0a9cb1/meta/run-4g0mh_nw/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/lcals_pressure-calc-l01-aa0a9cb1/meta/run-4g0mh_nw/backend/candidate-status.json) | s8 | s2 | 3,061 | 2,604 | 457 | 17.5499% |
| 15 | [tsvc/tsvc-s124-l00](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s124-l00-cdbb075b/meta/run-ph93cyob/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s124-l00-cdbb075b/meta/run-ph93cyob/backend/candidate-status.json) | s16 | s8 | 303,655 | 260,248 | 43,407 | 16.6791% |
| 16 | [lcals/energy-calc-l01](.cache/wrong-predictions-current/artifacts/lcals_energy-calc-l01-edf5400a/meta/run-xp7tgw1b/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/lcals_energy-calc-l01-edf5400a/meta/run-xp7tgw1b/backend/candidate-status.json) | s8 | s4 | 7,993 | 6,870 | 1,123 | 16.3464% |
| 17 | [rajaperf/pi-reduce](.cache/wrong-predictions-current/artifacts/rajaperf_pi-reduce-76f86157/meta/run-c9tn5kqy/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/rajaperf_pi-reduce-76f86157/meta/run-c9tn5kqy/backend/candidate-status.json) | s8 | s4 | 8,710 | 7,487 | 1,223 | 16.3350% |
| 18 | [rajaperf/gen-lin-recur-reverse](.cache/wrong-predictions-current/artifacts/rajaperf_gen-lin-recur-reverse-52b65c3b/meta/run-8u9uxrot/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/rajaperf_gen-lin-recur-reverse-52b65c3b/meta/run-8u9uxrot/backend/candidate-status.json) | s8 | s4 | 14,480 | 12,609 | 1,871 | 14.8386% |
| 19 | [tsvc/tsvc-s176-l00](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s176-l00-a186d0cf/meta/run-xq7sh5xz/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s176-l00-a186d0cf/meta/run-xq7sh5xz/backend/candidate-status.json) | s16 | s4 | 49,181 | 42,984 | 6,197 | 14.4170% |
| 20 | [lcals/band-lin-eq-outer](.cache/wrong-predictions-current/artifacts/lcals_band-lin-eq-outer-4e64cad2/meta/run-kut_00nx/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/lcals_band-lin-eq-outer-4e64cad2/meta/run-kut_00nx/backend/candidate-status.json) | s4 | s8 | 1,571 | 1,374 | 197 | 14.3377% |
| 21 | [rajaperf/reduce-struct](.cache/wrong-predictions-current/artifacts/rajaperf_reduce-struct-2fb15f36/meta/run-bwgwmgfw/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/rajaperf_reduce-struct-2fb15f36/meta/run-bwgwmgfw/backend/candidate-status.json) | s4 | s2 | 6,809 | 6,019 | 790 | 13.1251% |
| 22 | [polybench/p421-gemm-l01](.cache/wrong-predictions-current/artifacts/polybench_p421-gemm-l01-192dbd1e/meta/run-8v45mzux/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/polybench_p421-gemm-l01-192dbd1e/meta/run-8v45mzux/backend/candidate-status.json) | s8 | s4 | 6,695 | 5,963 | 732 | 12.2757% |
| 23 | [rajaperf/daxpy](.cache/wrong-predictions-current/artifacts/rajaperf_daxpy-3966eff4/meta/run-_kjzcpxm/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/rajaperf_daxpy-3966eff4/meta/run-_kjzcpxm/backend/candidate-status.json) | s8 | s2 | 5,844 | 5,208 | 636 | 12.2120% |
| 24 | [tsvc/tsvc-s171-l00](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s171-l00-21a03b56/meta/run-47_nzh92/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s171-l00-21a03b56/meta/run-47_nzh92/backend/candidate-status.json) | s16 | s4 | 112,967 | 100,680 | 12,287 | 12.2040% |
| 25 | [tsvc/tsvc-s172-l00](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s172-l00-c3a4cfce/meta/run-cguj2h5y/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s172-l00-c3a4cfce/meta/run-cguj2h5y/backend/candidate-status.json) | s16 | s4 | 112,967 | 100,680 | 12,287 | 12.2040% |
| 26 | [tsvc/tsvc-s119-l00](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s119-l00-7c5e355c/meta/run-crhyk8kb/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s119-l00-7c5e355c/meta/run-crhyk8kb/backend/candidate-status.json) | s16 | s8 | 1,068 | 960 | 108 | 11.2500% |
| 27 | [lcals/energy-calc-l05](.cache/wrong-predictions-current/artifacts/lcals_energy-calc-l05-91e76067/meta/run-0ylqmgpj/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/lcals_energy-calc-l05-91e76067/meta/run-0ylqmgpj/backend/candidate-status.json) | s8 | s4 | 7,456 | 6,715 | 741 | 11.0350% |
| 28 | [rajaperf/gen-lin-recur-forward](.cache/wrong-predictions-current/artifacts/rajaperf_gen-lin-recur-forward-2d89df0b/meta/run-xiqw04n7/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/rajaperf_gen-lin-recur-forward-2d89df0b/meta/run-xiqw04n7/backend/candidate-status.json) | s8 | s4 | 13,844 | 12,530 | 1,314 | 10.4868% |
| 29 | [tsvc/tsvc-s114-l00](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s114-l00-9cee7768/meta/run-tzmph590/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s114-l00-9cee7768/meta/run-tzmph590/backend/candidate-status.json) | s16 | s2 | 5,835 | 5,342 | 493 | 9.2288% |
| 30 | [tsvc/tsvc-s118-l00](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s118-l00-fc4312b6/meta/run-5h5rpzui/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s118-l00-fc4312b6/meta/run-5h5rpzui/backend/candidate-status.json) | s16 | s1 | 6,744 | 6,180 | 564 | 9.1262% |
| 31 | [rajaperf/triad](.cache/wrong-predictions-current/artifacts/rajaperf_triad-74b1a1d1/meta/run-fppeojo4/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/rajaperf_triad-74b1a1d1/meta/run-fppeojo4/backend/candidate-status.json) | s8 | s2 | 6,800 | 6,269 | 531 | 8.4703% |
| 32 | [tsvc/tsvc-s1119-l00](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s1119-l00-4f9ad8fa/meta/run-oej1our8/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s1119-l00-4f9ad8fa/meta/run-oej1our8/backend/candidate-status.json) | s16 | s4 | 1,045 | 964 | 81 | 8.4025% |
| 33 | [lcals/energy-calc-l03](.cache/wrong-predictions-current/artifacts/lcals_energy-calc-l03-5a111bb6/meta/run-ek496k8v/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/lcals_energy-calc-l03-5a111bb6/meta/run-ek496k8v/backend/candidate-status.json) | s8 | s4 | 1,527 | 1,418 | 109 | 7.6869% |
| 34 | [rajaperf/reduce-sum](.cache/wrong-predictions-current/artifacts/rajaperf_reduce-sum-c7209cc1/meta/run-ud1uby48/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/rajaperf_reduce-sum-c7209cc1/meta/run-ud1uby48/backend/candidate-status.json) | s8 | s4 | 3,257 | 3,057 | 200 | 6.5424% |
| 35 | [rajaperf/muladdsub](.cache/wrong-predictions-current/artifacts/rajaperf_muladdsub-350a953b/meta/run-hb70192m/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/rajaperf_muladdsub-350a953b/meta/run-hb70192m/backend/candidate-status.json) | s8 | s4 | 15,641 | 14,689 | 952 | 6.4810% |
| 36 | [lcals/fir-outer](.cache/wrong-predictions-current/artifacts/lcals_fir-outer-16dfa90e/meta/run-7xdyy4c7/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/lcals_fir-outer-16dfa90e/meta/run-7xdyy4c7/backend/candidate-status.json) | s8 | s16 | 8,258 | 7,798 | 460 | 5.8989% |
| 37 | [rajaperf/eos](.cache/wrong-predictions-current/artifacts/rajaperf_eos-a5c99505/meta/run-2sg0hbij/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/rajaperf_eos-a5c99505/meta/run-2sg0hbij/backend/candidate-status.json) | s4 | s2 | 21,994 | 20,795 | 1,199 | 5.7658% |
| 38 | [tsvc/tsvc-s1232-l00](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s1232-l00-e402d643/meta/run-vfbhkh_x/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s1232-l00-e402d643/meta/run-vfbhkh_x/backend/candidate-status.json) | s8 | s16 | 19,471 | 18,455 | 1,016 | 5.5053% |
| 39 | [rajaperf/first-diff](.cache/wrong-predictions-current/artifacts/rajaperf_first-diff-62f6f81e/meta/run-79j67but/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/rajaperf_first-diff-62f6f81e/meta/run-79j67but/backend/candidate-status.json) | s8 | s4 | 9,510 | 9,019 | 491 | 5.4441% |
| 40 | [rajaperf/if-quad](.cache/wrong-predictions-current/artifacts/rajaperf_if-quad-183490a8/meta/run-khrda9ub/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/rajaperf_if-quad-183490a8/meta/run-khrda9ub/backend/candidate-status.json) | s4 | s2 | 19,624 | 18,646 | 978 | 5.2451% |
| 41 | [rajaperf/if-quad-builtin](.cache/wrong-predictions-current/artifacts/rajaperf_if-quad-builtin-6c7a4061/meta/run-wm1rle1_/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/rajaperf_if-quad-builtin-6c7a4061/meta/run-wm1rle1_/backend/candidate-status.json) | s4 | s2 | 19,624 | 18,646 | 978 | 5.2451% |
| 42 | [lcals/pressure-calc-l00](.cache/wrong-predictions-current/artifacts/lcals_pressure-calc-l00-eb73f211/meta/run-46r31u7q/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/lcals_pressure-calc-l00-eb73f211/meta/run-46r31u7q/backend/candidate-status.json) | s8 | s4 | 1,009 | 961 | 48 | 4.9948% |
| 43 | [polybench/p32-gemm-l00](.cache/wrong-predictions-current/artifacts/polybench_p32-gemm-l00-ac3f2df9/meta/run-70p9yj4n/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/polybench_p32-gemm-l00-ac3f2df9/meta/run-70p9yj4n/backend/candidate-status.json) | s8 | s1 | 69,305 | 67,207 | 2,098 | 3.1217% |
| 44 | [tsvc/tsvc-s173-l00](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s173-l00-48d51ecc/meta/run-x4f2ljyv/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s173-l00-48d51ecc/meta/run-x4f2ljyv/backend/candidate-status.json) | s16 | s4 | 59,268 | 57,554 | 1,714 | 2.9781% |
| 45 | [tsvc/tsvc-s174-l00](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s174-l00-bd9fa068/meta/run-7thc8ogo/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s174-l00-bd9fa068/meta/run-7thc8ogo/backend/candidate-status.json) | s16 | s4 | 59,268 | 57,554 | 1,714 | 2.9781% |
| 46 | [lcals/init3](.cache/wrong-predictions-current/artifacts/lcals_init3-3d272b8a/meta/run-guctvpk0/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/lcals_init3-3d272b8a/meta/run-guctvpk0/backend/candidate-status.json) | s8 | s2 | 2,784 | 2,714 | 70 | 2.5792% |
| 47 | [polybench/p32-atax-l00](.cache/wrong-predictions-current/artifacts/polybench_p32-atax-l00-671335a6/meta/run-9_28wk_h/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/polybench_p32-atax-l00-671335a6/meta/run-9_28wk_h/backend/candidate-status.json) | s8 | s2 | 13,752 | 13,436 | 316 | 2.3519% |
| 48 | [polybench/p32-bicg-l00](.cache/wrong-predictions-current/artifacts/polybench_p32-bicg-l00-68d57011/meta/run-gvh5jri2/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/polybench_p32-bicg-l00-68d57011/meta/run-gvh5jri2/backend/candidate-status.json) | s8 | s2 | 13,752 | 13,436 | 316 | 2.3519% |
| 49 | [tsvc/tsvc-s132-l00](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s132-l00-f0d6c836/meta/run-r72tnv4o/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/tsvc_tsvc-s132-l00-f0d6c836/meta/run-r72tnv4o/backend/candidate-status.json) | s16 | s8 | 1,024 | 1,002 | 22 | 2.1956% |
| 50 | [lcals/muladdsub](.cache/wrong-predictions-current/artifacts/lcals_muladdsub-977367b6/meta/run-_iih2yki/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/lcals_muladdsub-977367b6/meta/run-_iih2yki/backend/candidate-status.json) | s8 | s2 | 2,767 | 2,708 | 59 | 2.1787% |
| 51 | [polybench/p32-bicg-l01](.cache/wrong-predictions-current/artifacts/polybench_p32-bicg-l01-e0d83bc0/meta/run-udm_f3gl/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/polybench_p32-bicg-l01-e0d83bc0/meta/run-udm_f3gl/backend/candidate-status.json) | s8 | s4 | 40,732 | 39,926 | 806 | 2.0187% |
| 52 | [lcals/inner-prod](.cache/wrong-predictions-current/artifacts/lcals_inner-prod-93100f71/meta/run-uaodr6am/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/lcals_inner-prod-93100f71/meta/run-uaodr6am/backend/candidate-status.json) | s8 | s4 | 1,292 | 1,267 | 25 | 1.9732% |
| 53 | [rajaperf/first-sum](.cache/wrong-predictions-current/artifacts/rajaperf_first-sum-7312297a/meta/run-ju0_sv6z/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/rajaperf_first-sum-7312297a/meta/run-ju0_sv6z/backend/candidate-status.json) | s8 | s4 | 5,609 | 5,545 | 64 | 1.1542% |
| 54 | [hpcc/stream-copy](.cache/wrong-predictions-current/artifacts/hpcc_stream-copy-ad6615d9/meta/run-r2krgnwr/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/hpcc_stream-copy-ad6615d9/meta/run-r2krgnwr/backend/candidate-status.json) | s8 | s4 | 5,007 | 4,960 | 47 | 0.9476% |
| 55 | [rajaperf/trap-int](.cache/wrong-predictions-current/artifacts/rajaperf_trap-int-0734d10c/meta/run-1atmzbko/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/rajaperf_trap-int-0734d10c/meta/run-1atmzbko/backend/candidate-status.json) | s8 | s4 | 15,214 | 15,074 | 140 | 0.9288% |
| 56 | [rajaperf/trap-int-builtin](.cache/wrong-predictions-current/artifacts/rajaperf_trap-int-builtin-4f51b51f/meta/run-ql0xcde8/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/rajaperf_trap-int-builtin-4f51b51f/meta/run-ql0xcde8/backend/candidate-status.json) | s8 | s4 | 15,214 | 15,074 | 140 | 0.9288% |
| 57 | [rajaperf/add](.cache/wrong-predictions-current/artifacts/rajaperf_add-0d156cf5/meta/run-2zhvl9b6/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/rajaperf_add-0d156cf5/meta/run-2zhvl9b6/backend/candidate-status.json) | s8 | s4 | 7,469 | 7,418 | 51 | 0.6875% |
| 58 | [lcals/band-lin-eq-inner](.cache/wrong-predictions-current/artifacts/lcals_band-lin-eq-inner-ed39b648/meta/run-efhn4yz0/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/lcals_band-lin-eq-inner-ed39b648/meta/run-efhn4yz0/backend/candidate-status.json) | s4 | s8 | 719 | 715 | 4 | 0.5594% |
| 59 | [polybench/p421-floyd-warshall-full](.cache/wrong-predictions-current/artifacts/polybench_p421-floyd-warshall-full-e582b111/meta/run-eqyr59nu/kernel.c) · [cost](.cache/wrong-predictions-current/artifacts/polybench_p421-floyd-warshall-full-e582b111/meta/run-eqyr59nu/backend/candidate-status.json) | s16 | s8 | 847,706 | 847,655 | 51 | 0.0060% |

## 평가 제외 전체

아래 사례는 최적 VF 대비 regret을 확정할 수 없어 오예측 목록과 정확도 분모에 넣지 않았다. 다중 루프는 하나의 VF로 축약하지 않았고, 고정 VF 선택에는 해당 측정값이 없다.

| Benchmark | 상태 | 제외 사유 |
| --- | --- | --- |
| `polybench/p32-adi-full` | `ambiguous-loops` | expected one selected_kernel loop |
| `polybench/p32-fdtd-2d-full` | `ambiguous-loops` | expected one selected_kernel loop |
| `polybench/p32-jacobi-1d-imper-full` | `ambiguous-loops` | expected one selected_kernel loop |
| `polybench/p32-jacobi-2d-imper-full` | `ambiguous-loops` | expected one selected_kernel loop |
| `polybench/p421-fdtd-2d-full` | `ambiguous-loops` | expected one selected_kernel loop |
| `polybench/p421-heat-3d-full` | `ambiguous-loops` | expected one selected_kernel loop |
| `polybench/p421-jacobi-1d-full` | `ambiguous-loops` | expected one selected_kernel loop |
| `polybench/p421-jacobi-1d-outer` | `ambiguous-loops` | expected one selected_kernel loop |
| `polybench/p421-jacobi-2d-full` | `ambiguous-loops` | expected one selected_kernel loop |
| `rajaperf/planckian` | `missing-measurements` | missing measurements for compiler VF(s): s1 |
| `tsvc/tsvc-s1111-l00` | `unmeasured-vf` | no measurement for f32 |
| `tsvc/tsvc-s1113-l00` | `ambiguous-loops` | expected one selected_kernel loop |
| `tsvc/tsvc-s1161-l00` | `ambiguous-loops` | expected one selected_kernel loop |
| `tsvc/tsvc-s127-l00` | `unmeasured-vf` | no measurement for f32 |
| `tsvc/tsvc-s161-l00` | `ambiguous-loops` | expected one selected_kernel loop |
| `tsvc/tsvc-s212-l00` | `ambiguous-loops` | expected one selected_kernel loop |
| `tsvc/tsvc-s221-l00` | `ambiguous-loops` | expected one selected_kernel loop |

## 입력 및 재현

- 체크아웃 commit: `020efcd18350561115cd34abb1d507d4f7e3d7c3`.
- 모델: `llvm-middle-end-v1`; policy SHA-256: `2a7f596d7fb099fe48789076d0d38e0780ff0a821050a5ff530bfa4d2d3933f9`.
- `cost_model.py` SHA-256: `9fc2806774b21999fe704b5c145f6d43a78c307b1fe928a454348630fc4baf7b`.
- DB SHA-256: `6793f637b8e48e5795f2c167419bd38c399cccb029cd3ae39a1aed1a1703a8d8`.
- 측정 target: `xiangshan-v2/MinimalConfig@e7bab53e66dfb3c4a1d11cf9519b0396f8576cae`.
- 평가 compiler: `clang version 23.1.3 (https://github.com/cheolwanpark/llvm-project.git 9d0ab6c42aa515a07eaac633ff50260004f16465)`.
- 기존 `../llvm-cost-model/build-vplan-tools` 빌드를 사용했다. 빌드에 기록된 revision과 현재 HEAD의 `llvm/`, `clang/` 소스 차이가 없음을 확인했다.
- 전체 평가 결과: [summary.json](.cache/wrong-predictions-current/summary.json). 소스·후보 cost·선택·최종 replay manifest는 [artifacts](.cache/wrong-predictions-current/artifacts/)에 보존했다. `.cache/`는 Git 추적 대상이 아니므로 문서를 다른 곳으로 옮길 때 링크 자료도 함께 보존해야 한다.

저장소 루트에서 실행한 명령:

```sh
uv run --project utils/vplan-tools python utils/vplan-tools/evaluate \
  --db search-dataset.sqlite \
  --output-dir .cache/wrong-predictions-current \
  --artifacts-dir .cache/wrong-predictions-current/artifacts \
  --skip-build --build-dir ../llvm-cost-model/build-vplan-tools \
  --compare-baseline
```

재실행 시 `--output-dir`는 새 경로나 빈 디렉터리를 지정한다. 결과의 `benchmarks`에서 `eligible == true && top1_correct == false`인 항목을 추리고, 위 regret 식으로 정렬하면 같은 목록을 재생성할 수 있다.

현재 모델은 LLVM의 middle-end 비용 및 선택 비교를 재현하지만 모든 힌트·후보 필터·루프 외부 수익성 정책을 구현하지는 않는다. 여기의 LLVM 일치는 이번 DB에 대한 실측 비교 결과이며, 모든 입력에 대한 동일성을 뜻하지 않는다.

## 1위 원인 분석: `polybench/p32-gesummv-l00`

**가장 강한 원인 증거는 backend scheduling/레지스터 할당 이후 생기는 spill을 middle-end가 예측하지 못한다는 점이다.** LLVM은 `s8`의 vector register peak를 32, spill cost를 0으로 계산한다. 실제 생성 코드에서는 매 vector iteration마다 **spill 3회 + reload 3회**, 추가로 벡터 그룹 copy 2회가 발생한다. 최적 측정 VF인 `s4`에는 이 spill/reload가 없다.

이 진단은 현재 compiler의 일반 LLVM pipeline에서 `--print-detailed-vplans`를 출력하고, `s4`/`s8`를 각각 강제해 IR·레지스터 할당 전후 MIR·최종 assembly를 비교한 결과다. 자동 선택 assembly와 강제 `s8` assembly의 함수 명령열도 동일함을 확인했다. 별도로 VPlan의 post-RA analytics에서도 같은 spill을 확인했다.

### LLVM은 왜 `s8`을 선택하는가

커널은 4,000개 double에 대해 두 개의 독립적인 누산을 수행한다. `x[j]`는 양쪽 곱셈에서 공유된다. `FP_CONTRACT OFF`가 지정되어 있고, 실제 생성 코드도 FMA 대신 곱셈과 덧셈을 따로 수행한다.

```c
for (int j = 0; j < 4000; j++) {
    tmp0 = A[j] * x[j] + tmp0;
    y0   = B[j] * x[j] + y0;
}
```

[LLVM 상세 출력](.cache/gesummv-analysis/llvm-detail.txt)의 주요 수치는 다음과 같다. 이 double 커널의 VLEN=128 조건에서는 `s4`가 LMUL=4, `s8`이 LMUL=8에 해당한다.

| 항목 | s4 | s8 |
| --- | ---: | ---: |
| 실제 vector width | 8 doubles | 16 doubles |
| Vector iteration 수 | 500 | 250 |
| Load 3개의 모델 비용 | 3 × 4 = 12 | 3 × 8 = 24 |
| fmul 2개 + fadd 2개의 모델 비용 | 4 × 8 = 32 | 4 × 16 = 64 |
| Induction + loop-control 비용 | 2 | 2 |
| 예측 body cost | 46 | 90 |
| 예측 whole-loop score | 23,000 | **22,500** |
| 예측 vector register peak / 한도 | 16 / 32 | 32 / 32 |
| 예측 spill cost | 0 | 0 |
| 실제 생성 코드의 iteration당 spill / reload | 0 / 0 | **3 / 3** |
| DB 측정 cycles | **32,696** | 55,020 |

모델상 vector 연산 비용은 LMUL에 선형 비례하고, iteration당 고정 비용 2만 더해진다. 따라서 이 커널에서는 `body cost = 11 × LMUL + 2`, `score = 22,000 + 4,000 / LMUL`이 되어 큰 LMUL을 선호한다. `s8`의 예측상 이득은 `s4` 대비 **2.1739%**뿐인데, 실제 측정에서는 **68.2775% 느리다**. 모델 cost는 cycles 단위가 아니므로 절대값끼리 비교하지 않는다.

4,000은 8과 16 모두로 나누어떨어지고, 실제 IR에도 scalar remainder loop가 없다. 따라서 이 비교의 역전은 scalar-tail 비용 차이로 설명되지 않는다.

### 레지스터 압력을 낮게 계산한 지점

[VPlanAnalysis.cpp](llvm/lib/Transforms/Vectorize/VPlanAnalysis.cpp)의 `calculateRegisterUsageForPlan()`은 **VPlan recipe 순서**를 따라 값의 생존 구간을 추정한다. 해당 계획은 대략 다음 순서다.

```text
A load → x load → A*x → tmp 누산 갱신 → B load → B*x → y 누산 갱신
```

이 순서에서는 누산기 2개와 입력/중간값을 합쳐 vector 값 4개 수준으로 계산된다. 그래서 `s8`의 peak는 `4 × 8 = 32`다. 같은 파일의 `VPRegisterUsage::spillCost()`는 `MaxUsers > AvailableRegs`일 때만 spill을 추가하므로, **32 == 32이면 spill cost가 0**이다.

반면 [일반 LLVM의 레지스터 할당 전 MIR](.cache/gesummv-analysis/direct-s8-pre-ra.mir)은 세 load를 먼저 배치한다.

```text
A load → x load → B load → A*x → B*x → tmp 누산 갱신 → y 누산 갱신
```

세 번째 load 직후에는 **누산기 2개 + A/x/B 입력 3개 = vector 값 5개**가 동시에 필요하다. 이 순서의 물리 레지스터 수요는 `s4`에서 `5 × 4 = 20`으로 한도 안이지만, `s8`에서는 `5 × 8 = 40`으로 32개 한도를 넘는다. 실제 backend의 명령 순서와 VPlan이 가정한 순서의 차이가 spill 추정을 깨뜨린다. 이것은 모든 스케줄에서 LMUL=8이 반드시 spill된다는 뜻은 아니다.

[s8 최종 assembly](.cache/gesummv-analysis/direct-s8.s)의 vector loop에는 다음 명령이 존재한다. 주석의 spill/reload 표시는 compiler가 출력한 것이다.

```asm
vs8r.v  v8,  (a6)   # Folded Spill: A
vs8r.v  v8,  (a6)   # Folded Spill: B
vl8r.v  v24, (a6)   # Folded Reload: A
vfmul.vv v24, v0, v24
vs8r.v  v24, (a6)   # Folded Spill: A*x
vl8r.v  v8,  (a6)   # Folded Reload: B
...
vl8r.v  v0,  (a6)   # Folded Reload: A*x
```

위 코드는 spill 흐름만 발췌한 것으로, 각 접근 사이의 주소 계산·다른 명령은 생략했다. A와 A*x는 같은 stack slot을 재사용하며, B는 다른 slot을 쓴다. [s4 assembly](.cache/gesummv-analysis/direct-s4.s)에는 vector stack 접근이 없다.

VLEN=128에서 LMUL=8 그룹은 128 bytes이므로, 추가 stack 전송량은 `6 × 128 × 250 = 192,000 bytes`다. 본래 배열 load는 `3 × 4000 × 8 = 96,000 bytes`다. 따라서 명령이 요구하는 vector 메모리 전송량은 spill 때문에 약 3배가 된다. 이는 **논리적 load/store 바이트 수**이며 실제 DRAM traffic을 뜻하지 않는다. 루프마다 발생하는 `vmv8r.v` 두 개와 spill 주소 계산도 추가 부담이다.

### 결론과 수정 방향

이 사례에서 우선 살펴볼 부분은 **VPlan의 순서 기반 register-pressure 추정과 backend schedule의 불일치**다. 현재 구현은 spill 항 자체를 갖고 있지만, 입력 peak가 32로 낮게 잡혀 항이 활성화되지 않는다. LLVM 비용을 재생하는 Python 모델도 같은 입력을 사용하므로 동일하게 틀린다.

수정 후보는 load를 앞당겼을 때의 생존값 중첩을 pressure 추정에 반영하거나, backend에서 register pressure를 고려해 load/연산 순서를 유지하도록 하는 것이다. 레지스터 한도에 임의의 여유분을 빼는 보정은 이 사례를 피할 수 있어도 다른 커널에 대한 타당성은 별도 검증이 필요하다. **이번 작업에서는 cost model이나 backend를 수정하지 않았다.**

확인된 사실은 현재 compiler의 `s8` 코드에만 큰 spill/reload 부담이 생긴다는 것이다. 이것이 측정 역전의 가장 강한 원인 후보지만, DB 측정 compiler revision은 현재 compiler와 다르고 당시 실행 trace 및 바이너리는 DB에 없다. 따라서 22,324 cycles의 차이 전부를 spill에 정량 귀속하거나 현재 바이너리의 성능으로 단정하지 않는다. 정확한 기여도 검증에는 원래 측정 환경에서 재측정이 필요하다.

### 공유 빌드와 분석 재현

현재 체크아웃에 `build-vplan-tools -> ../llvm-cost-model/build-vplan-tools` 심볼릭 링크를 만들었다. 기존 빌드를 그대로 사용했으며 재빌드는 하지 않았다.

```sh
uv run --project utils/vplan-tools python .cache/gesummv-analysis/reproduce.py
```

[재현 스크립트](.cache/gesummv-analysis/reproduce.py)는 DB에서 소스를 읽고 기존 compiler로 상세 출력과 s4/s8 코드를 생성한다. 자동 선택 코드와 s8 코드의 일치, s4의 spill/reload 0회, s8의 spill/reload 각각 3회를 검사한다. 실제 실행 cycles는 새로 측정하지 않는다. [직접 컴파일 명령 목록](.cache/gesummv-analysis/direct-commands.json)도 저장했다.

전체 evaluator에서 이 링크를 사용할 때는 `--skip-build`를 지정한다. 현재 `print-vplans` CLI에는 `--skip-build`가 없고 다른 체크아웃의 CMake cache를 거부하므로, 위 스크립트는 `compile_report()`로 기존 compiler를 직접 호출한다.
