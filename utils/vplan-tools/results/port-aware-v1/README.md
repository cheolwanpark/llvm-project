# MIR port-aware baseline — max / sum

`mir-port-aware` 브랜치는 **max와 sum만 지원**한다. 기본값은 **max, body scale b=1**이다.
하드웨어 값을 regret에 맞춰 조정하지 않고, RTL 근거와 가정을 구분하는 baseline이다.

## 수식과 구현

```text
u[c] = sum(expand(MIR instruction, LMUL, SEW, memory geometry)[c])
d[p] = sum(u[c] / |possible_ports[c]| for c with p in possible_ports[c])
x[p] = d[p] / capacity[p]
A_max(x) = max(x[p])
A_sum(x) = sum(x[p])
S(b) = b * body_iterations * A(x) + configuration + setup_configuration + scalar_tail
```

[일반 dataclass](../../hardware_model.py)와 [단일 datasheet](../../kunminghu_v2.py)를 분리했다.
MIR opcode/geometry를 RTL decode split에 연결하고 primary uop과 I2V/F2V를 분리한다.
scalar store는 address/data 두 필수 issue demand로 표현한다. 가능한 EXU에는 수요를
균등 배분하며, 같은 EXU를 사용하는 서로 다른 class의 demand를 합친다.
메모리 명령의 uop은 포함하며 별도 memory request R과 class weight는 없다.
iteration/configuration/setup/scalar-tail 계산 및 계수는 유지한다.

## 동일 population 평가

203개 중 189개 benchmark, 843개 후보 보고서를 평가했다.
max는 **189/189 선택을 최종 compiler replay로 검증**했고, sum은 동일 후보와 기존
측정 cycle을 재사용한 ranking-only 평가다. LLVM도 benchmark와 VF population을 맞췄다.

| 설정 (b=1) | Mean regret | Top-1 | Worst regret |
|---|---:|---:|---:|
| LLVM | 8.998% | 69/189 | 167.261% |
| **max (기본값)** | **7.879%** | **76/189** | **94.504%** |
| sum | 5.106% | 87/189 | 55.064% |

sum은 max 대비 87건의 VF를 바꾸며, 51건 개선과 36건 악화가 함께 발생한다.
기본값은 max로 유지한다. 상세 지표는 [comparison.csv](comparison.csv)에 있다.

## Body-scale 선택 구간

저장된 feature에 대해 `S(b)=b*slope+intercept`의 교차점을 유리수로 계산하고
endpoint tie와 단일 점을 보존한다. feature 자체는 부동소수 값이므로 정확성은
**저장된 feature에 대한 affine 계산**을 뜻한다.

각 설정의 b=1 선택을 그 설정의 기준으로 삼는다. benchmark별
`regret(new)-regret(reference) <= 0.15`는 진단이며 합격 기준이 아니다.

| 설정 | 전체 VF 유지 구간 | 모든 사례의 regret 증가가 15pp 이하인 구간 |
|---|---|---|
| max | 약 `(0.375, 1.5]` | 약 `(0.375, 1.83942)` |
| sum | `[1, ∞)` | `[3/11, ∞)` |

max의 최소 mean regret 구간은 약 `(1.5, 1.83942)`이며 7.561%다.
sum은 `(0.4, 1)`에서 5.094%다. 각각의 개선은 first-diff 한 건의 VF 변경에서 온다.
어떤 b에서도 선택되지 않는 oracle VF가 있으므로 body 배율만으로 구조적인 오류를
고칠 수 없다. 위 소수 endpoint는 반올림했으며 정확한 값과 포함 여부는 JSON/CSV에 보존한다.

| 설정 | 전체 분석 | 명령별 port 설명 | 위반 구간 | VF 유지 구간 | 전역 구간 |
|---|---|---|---|---|---|
| max | [JSON](max/analysis.json.gz) | [JSON](max/explanations.json.gz) | [CSV](max/violations.csv) | [CSV](max/reference_intervals.csv) | [CSV](max/global_regions.csv) |
| sum | [JSON](sum/analysis.json.gz) | [JSON](sum/explanations.json.gz) | [CSV](sum/violations.csv) | [CSV](sum/reference_intervals.csv) | [CSV](sum/global_regions.csv) |

## 가정과 한계

- **27개 물리 EXU와 가상 UNKNOWN의 capacity는 모두 1 uop/cycle 가정**이다.
  RTL 입력 폭을 모든 FU의 지속 처리율로 해석하거나 latency로 throughput을 역산하지 않았다.
- 미확인 class/port는 UNKNOWN, count를 모르면 1을 사용한다. 이번 eligible 후보 843개에는
  UNKNOWN 및 instruction-level fallback이 0건이다. capacity 가정은 여전히 남는다.
- vector COPY는 whole-register move로 근사하고 해당 가정을 보고한다.
  잘못된 알려진 geometry는 fallback으로 숨기지 않고 오류로 처리한다.
- 균등 배분은 동적 scheduling, 의존성, FU 점유, backpressure, shared writeback,
  cache/메모리 지연을 모델링하지 않는다. 점수는 CPU cycle 예측값이 아니다.
- body 밖의 일반 setup/final reduction은 제외한다. 정확한 trip count가 없으면
  scalar tail 및 setup 상각을 추측하지 않는다.

RTL은 `e7bab53e66dfb3c4a1d11cf9519b0396f8576cae`, MinimalConfig, VLEN=128/ELEN=64다.
9개 source hash와 vector 330개/scalar 326개 opcode record를 검증했다.

## 검증과 재현

compiler integration을 포함한 Python 테스트 38개가 통과했다.
현재 모델 identity, coverage, replay 및 실행 명령은 [validation.json](validation.json),
제외 14건은 [excluded.json](excluded.json)에 있다.

`max-evaluation.tar.gz`는 max summary, LLVM baseline, eligible 후보별 전체 보고서를 포함한다.
원본 MIR 및 replay 파일은 포함하지 않는다. summary의 원본 절대 경로는 provenance용이며
압축 해제 후 rescoring에는 필요하지 않다. 저장소 루트에서 새 출력 경로로 실행한다.

```sh
mkdir -p /tmp/port-reproduce
tar -xzf utils/vplan-tools/results/port-aware-v1/max-evaluation.tar.gz -C /tmp/port-reproduce
python3 utils/vplan-tools/rescore-evaluation \
  --evaluation /tmp/port-reproduce/max --aggregation sum --output-dir /tmp/port-reproduce/sum
python3 utils/vplan-tools/analyze-boundaries \
  --evaluation /tmp/port-reproduce/sum --term body_scale --output-dir /tmp/port-reproduce/sum-boundaries
# Compiler replay를 포함해 다시 평가:
python3 utils/vplan-tools/evaluate --build-dir build-local --skip-build --output-dir /tmp/port-fresh
```

각 설정 폴더에는 compressed summary, 정확한 boundaries, 분석 JSON 및 CSV가 있다.
분석 helper는 `analysis/`, 산출물 checksum은 `sha256.json`에 보존한다.
