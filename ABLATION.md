# Ablation 모델의 범위와 해석

이 문서는 현재 모델 간 차이, 기존 LLVM에서 유지한 정책과 이 fork의 선택,
비교 결과의 해석 범위를 설명한다. 옵션·실행·sweep은
[README](README.md#bodyspill-ablations), 정확한 비용 수식·관측 시점·gate·fallback은
[BACKEND_FEEDBACK](BACKEND_FEEDBACK.md#bodyspill-ablation과-mir-info), 가격과 단위 변환은
[CostSheet 규칙](costsheet/rule.md)이 소유한다.

## 1. Scalar loop와 scalar spill의 구분

- **Scalar 기준 루프**는 vectorization 전 원본 루프의 VF1 기준이다.
- **Scalar spill**은 GPR/FPR 등 scalar register의 spill/reload다. Vectorized loop
  안에도 주소·인덱스·scalar 연산 때문에 scalar spill이 있을 수 있다.
- MIR 수식의 `R_vector/S_vector/Et_vector`와 `R_scalar/S_scalar/Et_scalar`에서
  아래첨자는 **어느 루프 body인가**를 뜻한다. Vector body의 `S_vector`도 그 body
  안의 scalar·vector spill-slot load/store를 모두 포함한다.

## 2. 기존 LLVM 정책과 fork의 선택

| 항목 | 기존 LLVM loop vectorizer에서 유지한 정책 | 이 fork에서 추가한 동작 |
|---|---|---|
| 원본 scalar 기준 | `expectedCost(VF1)`로 IR 명령 비용을 합산하며 별도 register-pressure spill 항을 더하지 않음 | TTI 모드에서는 configured default/tuned TTI로 같은 기준을 계산 |
| Vector 후보의 추정 spill | Register-pressure 정책이 활성화되면 class별 초과 사용량을 계산하며 scalar·vector class 모두 포함 | 같은 추정 정책을 유지하고 설정된 TTI의 aggregate hook으로 가격화 |
| 실제 vector spill feedback | 이 fork의 in-process probe 및 대체 경로는 없음 | TTI 후보 비용에서 추정 vector spill만 빼고 관측 vector spill을 더함 |
| MIR body와 scalar 기준 | 이 fork의 MIR 관측·가격화 경로는 없음 | 원본 scalar 기준과 vector 후보의 machine body를 관측하고 같은 MIR sheet로 가격화 |

따라서 **원본 scalar 기준에 별도 추정 spill을 더하지 않는 것은 기존 LLVM 정책의
유지**이고, **TTI 후보에서 실제 vector spill만 교체하는 것은 이 fork의 선택**이다.
LLVM이 vectorized loop 안의 scalar spill 추정을 원래 배제하는 것은 아니다.

## 3. 현재 모드별 비용 범위

| 모드 계열 | Vector 후보의 연산 비용 | Vector 후보 안의 spill 비용 | 원본 scalar 기준 |
|---|---|---|---|
| TTI estimated | 선택한 default/tuned TTI | 정책에 따라 scalar·vector 추정 spill 포함 | 같은 TTI의 scalar IR 비용, 별도 pressure spill 항 없음 |
| TTI observed vector spill | 선택한 default/tuned TTI | 추정 scalar spill 유지, 추정 vector spill만 관측값으로 교체 | 같은 TTI의 scalar IR 비용, 별도 pressure spill 항 없음 |
| MIR observed | 관측된 전체 machine body의 MIR sheet 가격 | Body 안의 scalar·vector spill-slot 접근 포함 | 원본 scalar machine body의 같은 sheet 가격, 관측 spill 포함 |
| MIR estimated spill | MIR body에서 관측 spill 비용을 제거한 가격 | Scalar·vector 관측 spill 비용을 설정된 TTI의 전체 추정 spill로 교체 | Scalar body에도 같은 대체 적용 |

TTI observed는 전체 spill의 실측 모델이 아니라 **기존 TTI 비용에 실제 RVV vector
spill feedback을 적용하는 모델**이다. 별도 scalar probe를 만들지 않으며, vector
후보 안의 scalar 추정 spill과 scalar 기준 비용을 기존 정책대로 유지한다.
관측값은 하드웨어 timing이 아니라 backend 접근을 수집하여 TTI로 가격화한 값이다.

TTI의 추정 spill은 기존 register-pressure 정책이 해당 VF에 추가한 만큼만 포함한다.
정책이 꺼져 있으면 그 항은 0이다. Observed 모드도 vector-pressure gate나 하한
pruning으로 probe를 생략할 수 있다. Gate의 `Sv=0`은 scalar spill 부재나 실제 zero
spill의 관측을 뜻하지 않는다. 수집 범위와 gate는 모두 vector spill을 대상으로 한다.

## 4. Default/tuned TTI가 바꾸는 범위

TTI 모드에서 `use-default-tti=false`는 지원 CPU와 정확한 VLEN에서 tuned TTI를
vector 후보뿐 아니라 **원본 scalar 기준의 IR 연산 가격에도 적용**한다.
`use-default-tti=true`는 양쪽 모두 native RISC-V TTI를 사용한다. Tuned adapter가
지원하지 않는 연산은 native TTI로 내려간다. Scalar 연산 가격을 tuned로 계산하는
것과 scalar 기준에 별도 추정 spill 항을 추가하는 것은 다른 변경이며, 후자는 하지 않는다.

MIR sheet는 CPU/VLEN으로 별도 선택한다. MIR estimated 모드에서 이 flag는 scalar와
vector 양쪽 추정 spill 항의 TTI를 선택한다. 성공한 pure-MIR 비용과 선택은 flag에
독립적이다. 실패 시에도 요청한 TTI 설정을 유지하며, 재선택 순서는
[backend fallback 계약](BACKEND_FEEDBACK.md#probe와-fallback)을 따른다.
Native IC 계산, probe 최적화와 최종 codegen에는 tuned 비교 scope를 전달하지 않는다.

## 5. 모델 비교에서 말할 수 있는 것

| 비교 | 해석 |
|---|---|
| TTI estimated ↔ TTI observed vector spill | 같은 TTI 가격과 scalar 기준에서 vector spill 추정 항을 관측 기반 항으로 교체한 효과. Gate·pruning·fallback 적용 여부를 함께 확인해야 함 |
| Default TTI ↔ tuned TTI | Vector 후보와 원본 scalar 기준 양쪽의 지원 연산 가격 및 spill 가격 출처를 바꾼 효과. Vector 가격만 바꾼 실험이 아님 |
| MIR observed ↔ MIR estimated spill | 같은 후보의 성공한 관측에서 scalar·vector spill 비용을 TTI 추정으로 대체한 효과. 원본 scalar 기준에도 대체가 적용됨 |
| TTI ↔ MIR | 연산 표현, scalar 기준과 spill 반영 범위가 함께 달라지는 전체 모델 비교. 순수한 연산 비용 추정 정확도 또는 동일 범위 spill 출처만의 차이로 해석할 수 없음 |

현재 구성은 upstream scalar 기준을 유지하는 TTI feedback 모델과 전체 machine
body를 관측하는 MIR 모델을 비교한다. 모든 모드가 동일한 spill 범위를 갖는 완전한
직교 실험으로 취급하지 않는다. 전체 spill 관측이나 scalar 기준의 pressure spill을
TTI에 추가하려면 각각 대체 범위와 기준 정책을 바꾸는 별도 설계 변경이다.

## 6. Sweep 이름과 실제 적용 모델

`gen-cost-model-sweep.sh`의 여섯 variant와 옵션 대응은 README를 따른다.
`llvm` variant도 master가 켜진 native-TTI estimated 모드이며, master OFF인 native
선택 경로와 동일한 이름이 아니다. `llvm-real-spill`과 `tti-real-spill`은 **vector
spill만 관측하여 대체**한다.

요청 모델과 실제 적용 모델은 구분해야 한다. MIR 또는 real-spill 요청이 성공적으로
ELF를 만들었어도 required probe 실패로 TTI real/estimated retry나 native fallback을
사용했을 수 있다. 빌드 성공이나 ELF 이름만으로 관측 모델 적용을 판단하지 않는다.
모델의 선택 결과를 해석할 때는 해당 실행의 feedback/fallback 진단과 compiler
identity를 확인한다. 새 binary는 기존 sweep 결과를 갱신하지 않으므로 비교 실행은
새 출력 디렉터리와 그 manifest의 tool hash로 식별한다.
