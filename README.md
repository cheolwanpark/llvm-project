# LLVM Reduction Fission

LLVM 23의 Loop Vectorizer에 추가한 실험적 VPlan Reduction Fission입니다.
Reduction 입력 계산(producer)과 누적(accumulator)을 별도 루프로 분리하고,
각 단계의 scalable vectorization factor(VF)를 선택해 레지스터 압박을 줄입니다.
기본값은 비활성화입니다. LLVM 프로젝트 소개는 [LLVM_README.md](LLVM_README.md)를 참고하세요.

## 빌드

CMake 3.20 이상, Ninja, C++ 컴파일러, Python 3가 필요합니다.
저장소 루트에서 실행하면 RISC-V 타깃을 지원하는 Clang과 LLVM 도구를 빌드합니다.

```sh
cmake -G Ninja -S llvm -B build-fission \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_PROJECTS=clang \
  -DLLVM_TARGETS_TO_BUILD=RISCV \
  -DLLVM_ENABLE_ASSERTIONS=ON \
  -DLLVM_INCLUDE_TESTS=ON
ninja -C build-fission clang opt llc FileCheck llvm-config VectorizeTests
```

메모리가 부족하면 Ninja에 `-j2`를 추가하세요.

## 사용법

```sh
build-fission/bin/opt input.ll -S -o output.ll -passes=loop-vectorize \
  -mtriple=riscv64 -mattr=+v,+zvl128b -force-vector-interleave=1 \
  -enable-vplan-reduction-fission
```

Clang에서는 `-mllvm`으로 각 LLVM 옵션을 전달합니다.

```sh
build-fission/bin/clang --target=riscv64 -march=rv64gcv -O3 \
  -S -emit-llvm input.c -o output.ll \
  -mllvm -force-vector-interleave=1 \
  -mllvm -enable-vplan-reduction-fission
```

단일 블록 루프에서 상수 반복 횟수 또는 SCEV로 정확한 실행 횟수와 상수 상한을
증명할 수 있는 경우를 지원합니다. Scratch는 상한으로 할당하고 실제 횟수만큼
접근합니다. 루프 불변 start/step의 정수 induction과 정적으로 독립적인 연속
store도 지원하며, store는 accumulator 단계에서 실행합니다.
Interleave count는 1이어야 하며, VF를 직접 지정하는 `-force-vector-width`는 사용하지 않습니다.
적용 조건을 만족하지 않으면 일반 벡터화를 사용합니다.

단일 FP add로 갱신하는 ordered/in-loop sum을 지원합니다. 기본 경로는 기존 FP
계약을 유지합니다. `-vplan-reduction-fission-allow-fp-reordering`을 함께 지정하면
후보의 FP sum에만 `reassoc`를 추가합니다. `nnan`, `ninf`, `nsz`, `contract`나
producer의 연산 완화는 추가하지 않으며, 실패한 후보는 일반 벡터화에 영향을
주지 않습니다. Strict/constrained FP, accumulator에 의존하는 FMA 분해,
runtime alias versioning, induction live-out은 지원하지 않습니다.

## 추가된 옵션

모두 숨김 옵션이며 `opt --help-hidden`으로 확인할 수 있습니다.

| 옵션 | 기본값 | 설명 |
| --- | --- | --- |
| `-enable-vplan-reduction-fission` | `false` | Reduction Fission 활성화 |
| `-vplan-reduction-fission-allow-fp-reordering` | `false` | Fission 후보의 FP sum에만 재결합 허용 |
| `-vplan-reduction-fission-min-reductions=N` | `4` | 필요한 최소 reduction 개수 |
| `-vplan-reduction-fission-min-chain-depth=N` | `8` | Producer의 최소 의존성 깊이 |
| `-vplan-reduction-fission-min-pressure-percent=N` | `100` | 레지스터 용량 대비 최소 압박 비율(%) |
| `-vplan-reduction-fission-max-scratch-bytes=N` | `65536` | 스택 임시 저장 공간의 최대 크기(바이트) |
| `-vplan-reduction-fission-max-duplicated-recipes=N` | `8` | 단계 사이에 복제할 수 있는 최대 VPlan recipe 수 |
| `-vplan-reduction-fission-max-scalable-vf-multiplier=N` | `8` | 레지스터 폭과 데이터 폭으로 구한 VF 대비 탐색 상한 배수 |
| `-vplan-reduction-fission-combine-add-contributions=true/false` | `true` | 가능한 경우 정수 덧셈 기여분을 합쳐 임시 저장 공간 절약 |
| `-vplan-reduction-fission-force-producer-vf=N` | `0` | Producer의 scalable VF 지정 (`0`: 자동) |
| `-vplan-reduction-fission-force-accumulator-vf=N` | `0` | Accumulator의 scalable VF 지정 (`0`: 자동) |

두 `force-*-vf` 옵션은 양의 2의 거듭제곱으로 함께 지정해야 합니다.
예를 들어 producer에 `4`, accumulator에 `2`를 주면 각각 `vscale × 4`, `vscale × 2`를
요청합니다. 값의 단위는 LMUL이 아니며, 지정한 VF는 탐색 가능한 합법적인 후보여야 합니다.
레지스터 여유 검사만 생략하고 안전성, 임시 저장 공간·복제 예산, 압박 개선 검사는 유지합니다.

위 빌드처럼 assertions를 켜면 `-debug-only=vplan-reduction-fission`으로
선택·거절 사유를 확인할 수 있습니다. 상세 조건과 구현 구조는
[Vectorizers 문서](llvm/docs/Vectorizers.md#experimental-reduction-fission)를 참고하세요.
`-pass-remarks=vplan-reduction-fission`과
`-pass-remarks-missed=vplan-reduction-fission`은 assertions 없이도 선택한 VF,
scratch 크기, reduction 방식과 재정렬 허가 출처 또는 거절 사유를 기록합니다.

## 테스트

```sh
build-fission/unittests/Transforms/Vectorize/VectorizeTests
build-fission/bin/llvm-lit -sv llvm/test/Transforms/LoopVectorize/RISCV/reduction-fission-*.ll
```

RISCV와 host backend(AArch64 또는 X86)를 포함한 빌드에서는 실행 비교도 가능합니다.

```sh
python3 llvm/utils/check-reduction-fission.py --build-dir build-fission \
  --work-dir build-fission/extension-execution
```

이 검사는 scalable IR을 여러 고정 vscale로 특수화해 host에서 실행합니다.
실제 RVV 실행과는 구별하며, RVV machine verifier 검사도 별도로 수행합니다.
정수·ordered FP는 원래 scalar IR과 정확히 비교하고, 재정렬 FP는 NaN/Inf 분류,
signed zero와 cancellation을 고려한 절대 오차 한계를 검사합니다. 실행 옵션,
VF·scratch remark와 결과는 지정한 디렉터리의 `results.json`에 저장합니다.
