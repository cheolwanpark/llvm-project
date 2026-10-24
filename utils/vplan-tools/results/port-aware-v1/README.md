# MIR port-aware baseline — max / sum

이 문서는 이전 `mir-port-aware-v1` 모델의 평가 기록이다. 현재 모델 설명은
[MODEL.md](../../../../MODEL.md)에 있다.

## 동일 population 평가

203개 중 189개 benchmark, 843개 후보 보고서를 평가했다.
max는 **189/189 선택을 최종 compiler replay로 검증**했고, sum은 동일 후보와 기존
측정 cycle을 재사용한 ranking-only 평가다. LLVM도 benchmark와 VF population을 맞췄다.

| 설정 (b=1) | Mean regret | Top-1 | Worst regret |
|---|---:|---:|---:|
| LLVM | 8.998% | 69/189 | 167.261% |
| **max (당시 기본값)** | **7.879%** | **76/189** | **94.504%** |
| sum | 5.106% | 87/189 | 55.064% |

sum은 max 대비 87건의 VF를 바꾸며, 51건 개선과 36건 악화가 함께 발생한다.
상세 지표는 [comparison.csv](comparison.csv)에 있다.

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

## 보존된 검증 자료

당시 compiler integration을 포함한 Python 테스트 38개가 통과했다.
당시 모델 identity, coverage, replay 및 실행 명령은 [validation.json](validation.json),
제외 14건은 [excluded.json](excluded.json)에 있다.

`max-evaluation.tar.gz`는 max summary, LLVM baseline, eligible 후보별 전체 보고서를 포함한다.
원본 MIR 및 replay 파일은 포함하지 않는다. 현재 scorer와 model identity가 다르므로
이 보고서를 현재 도구로 바로 rescore할 수는 없다. Summary의 원본 절대 경로는
provenance용이다.

각 설정 폴더에는 compressed summary, 정확한 boundaries, 분석 JSON 및 CSV가 있다.
분석 helper는 `analysis/`, 산출물 checksum은 `sha256.json`에 보존한다.
