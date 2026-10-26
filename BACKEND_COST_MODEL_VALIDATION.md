# In-process VF 비용 선택 검증 — 2026-10-26

기준 revision은 `de1dc1e703cda4f8392b184b26a77fdcfa3a1692`이며,
`/work/llvm-baware-integration`에서 기준 compiler를 먼저 빌드했다.
구현과 모든 빌드는 이 워크트리에서 수행했다. 참조 워크트리를 수정하거나
그 compiler를 사용하지 않았다. 실행 산출물은 `.cache/backend-cost-20261026/`에 있다.

## 빌드 identity

| Compiler | 기준 SHA-256 | 구현 SHA-256 |
|---|---|---|
| clang | `b6971ca1b45161013bd667e796e5b9a19cefc9b183356c05f24a215bb8c995f7` | `e3aff7264feeab8bec7ccd4609c1060266e90549f83a31eebff2c0f923fbc45b` |
| opt | `cc3f3ca2c6a65d83b2da45cd4cc1e75ce54ebe783bafdab87ebbbca574a75bc1` | `2dd63311fb8233f64d2d8fd5485beef6195355f15a0ba933f86f85e352f62821` |
| llc | `362e83ffe758de24497873785dd447d96a2b5282e134f2f78e59d0210a223e36` | `de860df6e849e1b848bea75c82041c36c0796bb6ce2fd3278e7850c7dc031ba6` |

`baseline-flags.txt`, `baseline-sha256`, `final-sha256`, `validation-commands.txt`에
명령과 identity를 보관했다. `baseline-bin/`에는 기준 실행 파일이 있다.
`build-shape-check.log` 및 후속 `build-noop.log`로 compiler 빌드 완료를 확인했다.
후속 unit-test fixture 수정은 compiler 실행 파일을 변경하지 않았다.

## 회귀 테스트

| 검증 | 결과 |
|---|---:|
| VectorizeTests | 81/81 |
| VPlanRATests | 1/1 |
| RISCVTests | 28/28 (새 XiangShan 테스트 5개 포함) |
| Python unit/compiler integration | 85/85 |
| RISC-V LoopVectorize 및 CodeGen/vplan-ra lit | 149/149 |
| `run_backend.py` | 37/37 regression files |

새 feedback lit도 별도 실행했다. `run_backend.py`의 파일 수를 전체 lit 수로
간주하지 않았다. 기존 `VPlanRATest.cpp` fixture가 version 3을 쓰고 있어 현재
transport가 요구하는 version 4로 수정했다. 외부 transport 구현/버전은 변경하지 않았다.

다음을 검증했다.

- XiangShan opcode 보정, uniform transfer, memory 경로, whole-register group
  1/2/4/8, 다른 tuning CPU 및 VLEN, scope 밖/latency native 비용, 중첩 scope 복원.
- 정확한 분수 비교, overflow, IC gate 경계, vector estimated spill 분리 및
  scalar spill 보존, body/setup 구분, spill MMO 없는 접근 제외, 불완전 관측 실패.
- 같은 큰 segment slot을 참조하는 group-2 store 두 개를 각 명령의 접근 크기로
  계산하는 단위 테스트. 실제 spill 비용에 slot 전체 크기를 반복 적용하지 않음.
- Scalable 기본 IC=1, fixed-width 자동 IC=2, CLI IC=2/4, metadata IC=2,
  forced main VF=8·IC=4·epilogue VF=2의 실제 probe/최종 IR 생성.
- 일반 epilogue 비교는 테스트용 TTI가 epilogue를 허용하도록 설정하고 **실제
  in-process provider**를 사용했다. Main IC=2와 epilogue IC=1을 따로 관측하며
  mapping과 역할을 검증했다. Epilogue 관측 실패를 주입한 최종 IR은 native와
  정확히 같았다. Production RISC-V TTI의 epilogue 선호는 변경하지 않았다.
- Master 없는 기존 진단 옵션은 provider를 호출하지 않음. 외부 RA discovery와
  master를 함께 지정해도 in-process 질의를 중첩하지 않음.

## 실제 spill이 VF 선택을 바꾸는 사례

`test_backend_cost_model.py`는 `generic-rv64`, VLEN=128, IC=1에서 12개 독립
FP reduction을 컴파일한다. XiangShan 보정은 적용되지 않는다.

| Scalable VF | Native body (quarters) | Estimated vector spill | Actual vector spill | Hybrid body |
|---|---:|---:|---:|---:|
| 1 | 300 | 0 | 0 | 300 |
| 2 | 620 | 128 | 64 | 556 |
| 4 | 1388 | 512 | 416 | 1292 |
| 8 | 2924 | 1280 | 1408 | 3052 |

Native는 `vscale×1`, 새 모델은 `vscale×2`를 선택한다. 선택된 후보에도 실제
vector spill이 있다. 실제 spill 항을 빼고 `L−Ev`만 비교하면 VF=8이 이기므로,
단순히 진단 필드를 출력하거나 XiangShan 보정만으로 발생한 선택 변경이 아니다.

## Flag OFF 불변성

DB `/work/mir-port-aware-goal/search-dataset.sqlite`의 203개 입력을 같은 source
경로와 동일한 정규화 compile flags로 기준/수정 compiler에서 직접 컴파일했다.

| 모드 | LLVM IR | Assembly | 전체 stderr/선택 remark |
|---|---:|---:|---:|
| Master OFF | 203/203 byte-identical | 203/203 byte-identical | 203/203 동일 |
| 기존 enable/print/force-all/timing만 지정 | 203/203 byte-identical | 203/203 byte-identical | 203/203 동일 |

`off-dataset/`, `off-dataset.json`, `off-options-dataset.json`에 결과와 명령이 있다.
실행 파일 symlink를 resolve하면서 `clang`/`clang-23` 경고 접두사가 달라진 초기
비교는 실행 이름을 동일하게 맞춰 재실행했다. IR/assembly 자체는 초기 비교에서도
모두 동일했다. 별도 lit에서는 master 없는 output 옵션이 파일을 생성하지 않고,
print/timing stderr도 비어 있는 것을 확인했다.

## Gate/force-all 데이터셋 대조

DB SHA-256:
`3d5e09ed2346be109a887192c36422073a4a6650b0f38cc29765d72ad063ff37`.
다른 `/work/llvm-cost-model/dataset.sqlite` population은 이 수치에 포함하지 않았다.
기존 검증 도구의 prepare/extract/resume 방식으로 동일 checkpoint에서 비교했다.

최종 산출물은 `gate-verified/summary.json`과 입력별 `audit.json`, `commands.json`,
관측 JSONL, LLVM IR, assembly, object다. Late cleanup OFF/ON 모두 203개 입력의
compilation이 완료됐고 두 모드의 아래 집계는 같았다.

| 항목 (모드당) | Gate | Force-all |
|---|---:|---:|
| 후보 비용 준비 행 | 1,517 | 1,512 |
| 실제 provider 호출 | 804 | 1,512 |
| 계산 성공 행 (fallback에서 폐기된 행도 포함) | 1,513 | 1,507 |
| 새 모델 선택 진단 행 (scalar 결정 포함) | 215 | 214 |
| Native fallback loop | 4 | 5 |

Gate에서 후보 비용 준비를 시도한 원본 loop는 218개다. 선택 진단에는 후보가 없는
scalar-only 결정도 포함되므로 후보 loop 수와 선택/fallback 행의 합은 다를 수 있다.
Gate 선택 진단 215개 중 201개는 변환을 생성했고 14개는 생성하지 않았다.
실제 질의 감소는 **46.83%**다. 실패 시 즉시 준비를 중단하므로 두 모드의 후보 행 수는
같지 않을 수 있다. 호출 수는 timing 로그와 대조했다.

- 양쪽 모두 계산 가능한 **1,507개 후보의 정확 비용이 모두 같았다**.
- **203/203 입력의 최종 VF·IC·epilogue/outcome과 assembly가 같았다**.
- 선택 형상의 **203/203 final LLVM IR을 verifier로 검증**하고, **203/203 object를
  생성**했다. IR과 assembly compilation의 최종 선택도 모두 같았다.
- Native 대비 50개 입력, 55개 loop의 VF가 달라졌다. IC 및 epilogue 변화는 0개다.
  이 DB의 기존 flags가 IC=1·vector epilogue 없음이므로 IC/epilogue 지원 검증은
  위 별도 integration/unit test와 구분한다. 변환 생성 여부는 13개 loop에서 달라졌다.

Clone도 일반 optimization remark를 출력하므로, 최종 선택 대조에는 `print-vplans`의
실제 main-selection 기록을 사용했다. Selection을 우회하는 clone materialization
보고서는 제외한다. 초기 단순 remark 개수 비교는 clone 수 차이를 잘못 집계했으며
최종 결과에는 사용하지 않았다.

### 검증 불가와 fallback을 성공으로 바꾸지 않은 항목

Gate가 생략한 후보는 총 713개다. 양쪽에 공통으로 있는 생략 후보 709개 중
708개에서 vector spill이 없음을 확인했다. 이 중 1개는 loop가 완전히 제거되어
함수 전체의 spill을 검사한 감사 결과다. **Compiler 비용 adapter는 이 경우에도
unproven loop mapping을 정상 비용으로 받아들이지 않는다.**

공통 생략 후보 **1개는 관측 불가**다. 또한 fallback 이후 중단 시점 차이로
**5개 후보 행은 상대 모드에서 평가하지 않았다** (이 중 4개는 gate에서 생략).
이들을 spill 0이나 비용 일치로 세지 않았다. 따라서 엄격한 gate 감사 도구는
`passed=false`, exit code 1을 유지한다. **전체 데이터셋 gate 증명이 통과했다고
보고하지 않는다.** 관측 가능한 비용/최종 출력 대조와 관측 불가 항목을 구분한다.

| 입력 | Fallback 모드 | 이유 |
|---|---|---|
| lcals/fir-inner | 양쪽 | loop/iteration mapping 불명확 |
| lcals/fir-outer | 양쪽 | loop/iteration mapping 불명확 |
| tsvc/tsvc-s332-l00 | 양쪽 | loop/iteration mapping 불명확 |
| polybench/p32-adi-full (loop 0) | 양쪽 | candidate materialization 실패 |
| polybench/polybench-reg_detect-l02 | force-all | loop/iteration mapping 불명확 |

미관측 생략 후보는 p32-adi-full의 첫 후보다. 해당 loop는 gate 경로도 나중 후보의
실패로 전체 native 복귀했다. Reg_detect의 gate 경로와 force-all fallback도 최종
선택/assembly는 같았다. 비용 계산 성공 행이 있더라도 이후 필요한 후보가 실패하면
그 loop의 hybrid 상태는 폐기된다.

## 재현 및 해석 범위

빌드와 테스트 명령은 [BACKEND_FEEDBACK.md](BACKEND_FEEDBACK.md)에 있다.
최종 감사 실행:

```sh
python3 -B utils/vplan-tools/check-backend-feedback-gate \
  --clang .cache/compiler-build/bin/clang \
  --db /work/mir-port-aware-goal/search-dataset.sqlite \
  --output-dir .cache/backend-cost-20261026/gate-verified --jobs 2
```

재실행에는 새로운 output directory를 사용한다. 이 도구는 LLVM `print-vplans`
보고서를 제공하는 assertions/debug-report-enabled compiler가 필요하다.
IR 생성 검증용 추가 compilation의 질의는 위 gate/force-all 측정 호출 수에 합치지 않는다.

초기 개발 중 결과(`gate-initial`, `gate-audit-updated`, `gate-final`, `gate-final2`, `gate-complete`)는
최종 집계가 아니다. 특히 재링크 중 실행 파일에 접근한 초기 재실행은 버렸다.
최종 감사는 compiler 빌드 완료 및 no-work 확인 후 수행했다.

RTL cycle 측정이나 성능 향상 검증은 수행하지 않았다. 관측은 post-frame-lowering,
최종 scheduling/RVV pseudo expansion 이전이며 임의의 전체 LTO·사용자 추가 pass를
재현하지 않는다. 구현·단위 테스트·compiler 출력 대조를 구분하며, 관측 MIR과
최종 machine instruction 전체의 동일성을 주장하지 않는다.
