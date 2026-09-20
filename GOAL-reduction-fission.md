# GOAL: 독립 reduction loop와 최소 contribution을 보장하는 Fission 구현

이 문서를 구현 에이전트의 작업 지시로 사용한다. 작업 디렉터리는 `llvm-project`다. 아래 문제를 소스와 artifact에서 재확인한 뒤 구현하고, 명시한 검사를 수행하여 결과를 보고하라. 분석이나 계획 제시에서 끝내지 않는다.

## 1. 사용자 요구와 완료 목표

다음 세 조건을 동시에 만족시킨다.

1. 기본 변환은 **Reduction → Map + Reduction**이다. 원본 iteration의 accumulator-independent 계산을 Map으로 이동하고, Map 전체가 완료된 다음 reduction을 실행한다.
2. **원본 accumulator마다 독립 reduction loop 하나를 강제**한다. 해당 loop에서 vector accumulation을 수행하고, 출구에서 horizontal collapse를 완료한 뒤 다음 accumulator의 loop를 실행한다. 이 독립성으로 각 reducer에 **largest legal LMUL**을 사용할 수 있게 한다. IC는 1이다.
3. **accumulator마다 전달하는 contribution과 buffer를 최소화**한다. 이상적인 형태는 iteration당 scalar contribution 하나, 즉 `contribution_k[i]` 하나다. 가능한 한 update를 정규화해 한 stream으로 전달한다. 안전한 기존 stream 또는 invariant를 재사용하면 owned scratch는 0개일 수 있다.

Largest legal LMUL을 낮추거나 accumulator들을 grouping/fusion/interleave해서 문제를 회피하지 않는다. Map VF는 별도 축으로 유지한다. 같은 contribution의 storage 공유는 가능하지만 reduction loop는 accumulator별로 독립이어야 한다.

여기서 “변수 하나”는 iteration당 contribution 하나를 뜻한다. Full-trip Map 뒤에 reduction을 수행하는 설계에서는 임의의 계산 결과를 보관하는 데 일반적으로 `N × sizeof(contribution)`이 필요하다. 전체 N개 값을 scalar 하나로 줄이는 partial reduction/tiling은 이번 목표와 다르다.

목표 형태의 예:

```cpp
// Original, assuming reassociation is legal:
for (i = 0; i < N; ++i) {
  acc0 = (acc0 + p0(i)) + p1(i);
  acc1 = (acc1 + q0(i)) + q1(i);
}

// Map: no accumulator-dependent computation.
for (i = 0; i < N; ++i) {
  c0[i] = p0(i) + p1(i);
  c1[i] = q0(i) + q1(i);
}

// Each loop uses its largest legal reduction LMUL, IC=1.
for (i = 0; i < N; ++i)
  acc0 = acc0 + c0[i];
// Complete acc0's horizontal collapse here.

for (i = 0; i < N; ++i)
  acc1 = acc1 + c1[i];
// Complete acc1's horizontal collapse here.
```

## 2. 리포지터리 상태와 기존 자료

- 분석한 브랜치: `reduction-fission`.
- 분석 기준 commit: `000d853e209a8ab64b7b10dbc1333cfb46f9e501`.
- 작업 시작 시 실제 branch, HEAD, working-tree diff와 적용되는 AGENTS.md를 확인한다. 다른 작업자의 변경을 덮어쓰지 않는다.
- 이전 대화에서 작성했던 **loop 보존 prototype의 소스 수정 3개와 신규 regression test는 사용자 요청으로 되돌렸다.** 그대로 구현돼 있다고 가정하지 않는다.
- Local build 경로는 `build-fission`이다. 작업 전 소스와 바이너리를 다시 동기화하여 이전 prototype 바이너리를 baseline으로 오인하지 않는다.
- Benchmark와 보관된 자료는 sibling repository의 `../code-lab/microbench/suite-vf-fission-sweep/`에 있다. 아래에서는 이 경로를 `SUITE`라 부른다. 이 문서의 shell 예제는 별도 환경변수 설정을 요구하지 않는다.

주요 자료:

- `SUITE/manifest.json`
- `SUITE/generated/<case>/<normal|fission>/scalable-vf<N>/`
- `SUITE/results/summary.sqlite`
- `SUITE/OVERHEAD-ANALYSIS.md`
- `SUITE/FISSION-DESIGN-REVIEW.md`
- `SUITE/VECTORIZER-LOOP-PRESERVATION.md`
- `SUITE/results/diagnostics/overhead-analysis/`

기존 문서의 “수정했다”, “18 tests passed” 등은 **되돌린 prototype의 과거 실험 기록**이다. 새 구현의 완료 증거로 그대로 사용하지 않는다. 이전 분석에서 제안한 reduction grouping, 작은 VF 선택, 광범위한 backend 경계 장치보다 이 문서의 요구사항과 Vectorizer 내부 수정 우선 원칙이 우선한다.

현재 manifest와 결과 DB 내부 manifest는 image/measurement identity가 다르다. 이전 조사에서 ELF 해시는 같았지만, 서로 다른 identity의 측정치를 새 build에 재사용하지 않는다. 기존 cycles는 과거 관측치로만 다룬다.

## 3. 반드시 읽을 LLVM 소스와 현재 결함

### A. 분리는 있으나 contribution 정규화는 없다

읽을 곳:

- `llvm/lib/Transforms/Vectorize/ReductionFission.h`: `Reduction`, `Slice`, `Inputs`.
- `llvm/lib/Transforms/Vectorize/ReductionFission.cpp`: `analyze()`, `execute()`.

현재 구현은 accumulator PHI의 users를 따라 dependent slice를 만들고, slice 밖에서 들어오는 각 operand를 `R.Inputs`에 넣는다. Map에서는 input마다 buffer에 저장하고 reduction에서는 원래 dependent slice를 clone한다.

이 때문에 `(acc + p0) + p1`이 `acc + (p0+p1)`로 정규화되지 않는다. p0/p1 각각 buffer가 생긴다. `mlas-sgemm-8acc`는 accumulator 8개에 buffer 16개를 생성한다.

추가 낭비:

- 원래 branch condition을 각 reduction의 input에 추가하여 predicate stream과 원래 CFG를 replay한다. 모든 predicate가 각 reduction에 필요한지 최소화하지 않는다.
- input이 비어 있으면 Map에 실질적인 stream을 만들기 위해 constant/invariant까지 materialize한다.
- stream reuse는 single-block이면서 **원래 Map에 StoreInst가 있을 때만** 시도한다. 순수 read-only sum/min/max는 안전한 입력도 scratch로 복사할 수 있다.
- VF legality를 정규화 전 slice/input 타입으로 검사한다. Map으로 이동 가능한 중간 타입이 reducer의 최대 VF를 제한할 수 있다.

### B. 독립 loop는 생성되지만 Vectorizer 안에서 경계가 사라진다

읽을 곳:

- `ReductionFission.cpp`: `setGeneratedHints()`, `getReductionVFChoices()`, reduction별 loop 생성.
- `LoopVectorize.cpp`: `LoopVectorizationPlanner::executePlan()`, forced Fission 선택/실행, reduction VF plan probing, transaction commit.
- `VPlanTransforms.cpp`: `optimizeForVFAndUF()`, `simplifyBranchConditionForVFAndUF()`, `simplifyKnownEVL()`.

현재 scalar 분리는 accumulator별 loop를 만든다. 최대 legal VF부터 각 reducer의 실제 VPlan을 검사하고 IC1을 지정하며, in-loop horizontal reduction과 작은 vector epilogue도 제한한다. 이 정책들은 유지한다.

문제는 short reduction이다. `mlas-sgemm-8acc`는 trip count 31, reduction VF16, minimum vscale=2다. VPlan이 한 번만 실행된다고 증명하여 latch를 `br i1 true, label %exit, label %body`로 바꾼다. 이후 SimplifyCFG가 backedge를 없애고 여러 reduction block을 합친다. 같은 scheduling region에 큰 벡터들이 살아 있게 되면서 spill이 생긴다.

기존 315개 ready Fission variant 중 46개 variant / 9개 context에서 constant-exit reduction을 확인했다. 이는 전체 46개가 동일한 spill을 보인다는 뜻은 아니다. 감사 기록은 `results/diagnostics/overhead-analysis/loop-boundary-audit.json`에 있다.

### C. 검증이 실행 불가능한 backedge와 최종 loop 소실을 놓친다

참고할 sibling 소스:

- `../code-lab/microbench/tools/isolated_loops/evidence.py`: `graph()`, `loops()`, `distributed_regions()`, `verify_transform()`.
- `../code-lab/microbench/suite-vf-fission-sweep/suite.py`: `compile_variant()`와 offline validation.

`graph()`는 branch condition을 보지 않고 모든 label을 edge로 넣는다. 상수 branch의 실행 불가능한 edge도 SCC에 포함된다. Transform 검증은 LV 직후 `after.ll`을 사용하고, `final.ll`에서는 storage/lifetime은 검사하지만 독립 loop 구조를 다시 검증하지 않는다.

기존 verifier가 통과했다는 것 또는 `ReductionFissionCommitted` remark가 있다는 것만으로 완료를 주장하지 않는다. 이번 LLVM 작업에 필요한 regression/analysis 검증을 LLVM 쪽에서 추가한다. Sibling benchmark verifier의 문제도 명시하고, 이를 고쳤다고 주장하려면 실제 별도 diff와 테스트를 제시한다.

## 4. 구현 방향과 범위

### 우선 Vectorizer 내부에서 독립 loop를 유지한다

실제 O2 pipeline에는 LV 이후에도 InstCombine, SimplifyCFG, VectorCombine, LoopUnroll, SROA, LICM, LoopSink 등의 cleanup이 있다. `llvm/lib/Passes/PassBuilderPipelines.cpp`의 `addVectorPasses()`와 그 호출 이후를 읽고 실제 trace로 확인한다. “LV 이후 최적화가 없다”는 가정은 사용하지 않는다.

하지만 일반 pass/backend를 수정하는 것이 먼저 필요하지는 않다. 되돌린 prototype은 다음 작은 변경으로 현재 캠페인에서 성공했다.

1. `executePlan()`에서 기존 `llvm.loop.reduction.fission.reduction` metadata를 읽는다.
2. Fission reduction인 경우에만 VPlan의 single-iteration branch/region folding과 known-EVL 치환을 건너뛴다.
3. runtime EVL에 따른 induction/remaining count와 종료 조건을 유지한다.
4. Normal과 Map에는 기존 최적화를 적용한다.

이 접근을 우선 검토하고 적절하게 구현하라. 정확한 코드 형태를 그대로 복사해야 하는 요구는 아니다. 현재 pipeline에서 충분하다면 새로운 intrinsic, noinline helper, 일반 CFG pass 예외, backend scheduling barrier를 도입하지 않는다. 일반 pass 또는 backend 수정이 실제로 필요하다면 먼저 최소 재현으로 그 필요성을 입증하고 변경 범위를 설명한다.

단순 `unroll.disable`, IC1, 임의 metadata만 붙이고 확인을 끝내지 않는다. 종료 조건이 이미 상수가 되면 그 표식들은 loop를 보장하지 않는다. 더 작은 VF, 늘어난 데이터 크기, 추가 dummy iteration, 전역 scheduler off로 통과시키지 않는다.

### 정규화된 reduction 계획을 만든다

권장 개념은 `CombineOp + InitialValue + ContributionExpression + StoragePlan`이다. 기존 legality를 유지하면서 read-only 분석 단계에서 정규화 계획을 만들고, 선택된 trial에서만 IR을 변경한다.

- accumulator가 정확히 한 번 포함된 associative update chain에서 iteration-local contribution을 추출한다.
- 같은 accumulator의 여러 contribution을 가능하면 하나로 결합한다. 서로 다른 accumulator를 합치지 않는다.
- reduction에는 가능한 한 `load contribution; combine accumulator`만 남긴다.
- 정규화된 contribution/reducer 타입과 연산으로 largest legal VF를 다시 결정한다.
- 적법한 input/output stream, invariant, 동일 contribution의 storage 공유를 우선 고려한다.
- stored type을 좁히는 것은 range/demanded-bits 및 연산 의미 보존을 증명할 수 있을 때만 수행한다.
- 필요 없는 Map 복사를 줄일 수 있게 degenerate/empty Map 표현을 명확히 한다. 이것이 reduction loop 독립성을 없애는 경로가 되어서는 안 된다.
- full-trip storage의 크기, overflow checks, ownership/lifetime/cleanup, 정적 stack budget 및 필요한 heap fallback을 유지한다.

모든 recurrence가 단일 scalar contribution으로 정규화되는 것은 아니다. 불가능한 경우 명확한 사유를 남기고 합법적인 다중-input fallback 또는 명시적 rejection을 사용한다. 의미를 바꾸거나 case를 숨겨 buffer 1개 목표를 맞추지 않는다.

### 수치/제어 의미를 보존한다

- FP의 `reassoc`를 `fast`로 승격하지 않는다. `nsz`, NaN/Inf, signed zero와 contraction 의미를 지킨다.
- `llvm.fmuladd`의 허용된 의미를 확인하여 product를 Map으로 옮길 수 있는 경우와, mandatory fused rounding인 `llvm.fma`를 구분한다.
- ordered/strict reduction을 강제로 unordered reduction으로 바꾸지 않는다.
- conditional update는 원래 실행되는 경로에서만 contribution을 계산한다. false 경로의 identity는 해당 combine/FP 의미에서 안전할 때만 사용한다. 원래 조건부인 invalid load/division 등을 무조건 실행하지 않는다.
- 초기 accumulator 값은 정확히 한 번 반영한다. N=0의 원래 결과를 보존한다.
- 정수 재결합 시 기존 `nsw/nuw`를 새 중간 연산에 맹목적으로 복사하지 않는다. Overflow/poison 의미를 증명하거나 적절히 flags를 재계산한다.
- 다른 accumulator, Map control/memory, observable intermediate value에 대한 기존 legality 제한과 transaction rollback을 보존한다.

## 5. 실제 검사 대상

각 case에서 `before.ll`, LV 직후 `after.ll`, `final.ll`, `remarks.yaml/json`, `command.json`, `xiangshan.raw.s`, `xiangshan.s`를 연결하여 검사한다. 패치된 target assembly와 순수 backend assembly의 차이를 분리한다.

| 대상 | 반드시 확인할 내용 |
|---|---|
| `mlas-sgemm-8acc`, Map VF2 | N=31에서도 독립 reduction 8개, VF16/m8, component별 collapse. 정규화로 buffer 16→8을 목표로 한다. 원래 reduction 간 live range 중첩에 의한 vector spill을 없앤다. |
| `mlas-sgemm-4acc` | 짧은 다중 accumulator loop 보존과 두 contribution의 단일화. |
| `mlas-q4-minmax` | 짧은 독립 min/max loop 두 개, 정확한 identity와 FP 의미, storage 공유와 loop 분리를 구분. |
| `lcals-fir`, `mlas-linear-query`, `mlas-linear-retrieval`, `npb-ep-bin-sum` | 짧은 단일 reduction도 접어서 없애지 않음. 단일/다중 case의 정책 일관성. |
| `tsvc-s311-l00`, 필요 시 s314/s316 | 읽기 전용 입력의 불필요한 copy와 16KiB scratch 제거 가능성. 재사용 후에도 reduction 경계와 초기값 보존. |
| `tsvc-s319-l00` | 이미 존재하는 output stream 재사용을 유지하고 새 buffer를 불필요하게 만들지 않음. 같은 accumulator의 여러 contribution 정규화와 storage 비용을 함께 평가. |
| `rajaperf-reduce-struct` | 6개 accumulator를 6개 loop로 유지. x/y storage를 공유할 수 있어도 reducer를 grouping하지 않음. |
| `rodinia-srad-row`, `mlas-rmsnorm-copy-sumsq` | product contribution과 buffer lifetime/개수. Map+Reduction 요구를 유지하면서 합법적인 정규화 수행. FMA 보존을 명분으로 accumulator들을 다시 섞지 않음. |
| `mlas-globalavg-signed/unsigned`, `mlas-qgemm-*` | signed/unsigned와 widening, contribution type, target legality. 실패 case를 성공 측정으로 간주하지 않음. |
| 전체 ready Fission 315 variants / 70 contexts | source별 요청 Map VF, reducer 개수, final loop 구조, largest legal reduction VF, storage 개수/bytes, compile/rejection 상태 전수 확인. |
| 대응 Normal variants 및 non-Fission fixture | 기존 VF/최적화 정책에 영향이 없는지 확인. 일반 short-loop folding은 계속 허용되어야 함. |

315/70은 기준 캠페인의 수치다. 새 정규화가 지원 범위나 최대 legal VF를 합법적으로 바꾸면 원인과 before/after를 보고한다. Case를 누락하거나 실패를 조용히 제외하여 기존 개수에 맞추지 않는다.

## 6. 단계별 검사와 통과 기준

### 6.1 분석 및 정규화

- contribution 식이 accumulator에 의존하지 않는지 검사한다.
- 원본 accumulator ↔ 생성 reduction component를 1:1로 매핑한다.
- 각 component의 combine, initial value, FP/integer 조건과 storage 선택 사유를 확인한다.
- `fast (acc+p0)+p1`, 정수 chain, conditional update, invariant 및 stream reuse에 대해 성공/거부 테스트를 만든다.
- SGEMM처럼 가능한 사례에서는 실제 buffer 개수와 총 byte 수 감소를 검사한다. alloca를 하나로 합친 뒤 내부에 두 값씩 저장하는 것은 contribution 단일화로 세지 않는다.

### 6.2 전체 IR pipeline 이후

- LV 직후뿐 아니라 실제 O2 cleanup 후 `final.ll`을 검사한다.
- LLVM LoopInfo/CFG 분석을 사용하고, 상수 branch의 실행 불가능한 edge를 독립 loop의 근거로 삼지 않는다.
- nonempty transformed execution에서 accumulator마다 독립 loop와 vector accumulator가 하나씩 있는지 확인한다.
- short loop에서도 상수 종료 분기로 접힌 single-block을 성공한 loop로 세지 않는다.
- reduction k의 vector accumulation과 horizontal collapse가 다음 reduction k+1과 분리되어 있는지 검사한다. `vector.reduce` 호출 개수만 세지 않는다.
- Largest legal VF/LMUL과 IC1을 확인한다. 단순히 모든 component를 같은 VF로 맞추지 않는다.
- Scalar tail이 필요한 lowering은 main vector reduction의 독립성을 유지하며 그 component 내부의 tail로 구분한다.
- N=0은 reduction을 실행하지 않고 초기값을 반환할 수 있어야 한다. 원본 loop가 LV 이전에 합법적으로 제거된 case는 이를 기록하고 “Fission loop 보존 성공”으로 세지 않는다.

### 6.3 Backend / register allocation 이후

- 실제 target CPU/features와 backend policy로 lowering하고 `-verify-machineinstrs`를 유지한다.
- machine CFG와 assembly의 component별 loop header/backedge, horizontal reduction 위치를 확인한다.
- component 간 vector live range 중첩 및 reduction 입력의 조기 load/spill을 확인한다.
- SGEMM Map VF2의 독립 reduction은 m8을 유지하면서 기존 54개 folded vector spill/reload 문제를 해소해야 한다. 정규화까지 수행한 결과도 따로 비교한다.
- Map 자체의 register pressure, scalar GPR/FPR spills, target extraction workaround를 reduction 간 vector spill과 구분한다. 모든 case의 모든 spill이 무조건 0이어야 한다는 부정확한 기준을 적용하지 않는다.
- 정적 명령 수 감소를 runtime cycle 감소율로 바꾸어 주장하지 않는다.

### 6.4 Regression / 수치 의미

기존 `llvm/test/Transforms/LoopVectorize/RISCV/reduction-fission-*.ll` 및 상위 디렉터리의 Fission tests를 읽고 유지한다. 특히 pressure, control, fp-semantics, streams, stack, rollback/transaction, generated-hints 테스트를 확인한다.

추가할 축:

- accumulator 1/4/8개, 같은 입력 공유와 서로 다른 입력.
- N=0/1, VLMAX보다 작음/같음/큼, 여러 vector iteration, runtime N. 실제 타깃의 VLEN과 타입으로 경계를 정의한다.
- 지원되는 여러 VLEN, f32/f64, 정수 signed/unsigned 및 widening.
- short-loop full O2 + llc까지 이어지는 회귀 테스트.
- 일반 Normal short loop는 계속 folding되는 negative control.
- FP signed zero/허용 범위의 NaN, strict/ordered rejection, conditional invalid address, 초기값, tail.
- 정수 overflow/poison, buffer bounds, allocation overflow/lifetime, zero-trip.

정규화는 수치 의미를 바꾸는 위험이 있으므로 IR 모양 검사만으로 끝내지 않는다. 실행 가능한 reference/변환 결과 비교를 추가하고, RVV 실행 환경이 있으면 target-side 수치 검증도 수행한다. 어떤 runner/입력/타입을 검사했는지 기록한다. target 실행을 못 했으면 그 범위는 검증하지 못했다고 명시한다. 기존 RTL 캠페인의 cycles 또는 host scalar 검증을 새 RVV code의 runtime 검증으로 대신하지 않는다.

## 7. 빌드와 실험 운영

이 host의 로컬 빌드에는 다음 형태를 사용할 수 있다. 실제 경로/설정은 먼저 확인한다.

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
  /opt/homebrew/bin/ninja -C build-fission -j 6 opt clang llc

python3 build-fission/bin/llvm-lit -sv \
  llvm/test/Transforms/LoopVectorize/RISCV/reduction-fission-*.ll \
  llvm/test/Transforms/LoopVectorize/reduction-fission-*.ll
```

- `command.json`에서 정확한 target flags, common flags, requested VF, lowering commands를 가져온다. 임의의 generic target으로 바꾼 결과만으로 완료하지 않는다.
- Local Clang에 보관된 `before.ll`을 `-x ir -O2`로 재입력하고 `-Xclang -fdebug-pass-manager`로 trace를 얻는 방식은 pipeline 회귀 확인에 유용하다. 이는 C frontend와 harness를 포함한 full source regeneration과 구분해서 보고한다.
- 기준 compiler revision에는 RISC-V VL Optimizer 문제 때문에 `-stop-before=riscv-vl-optimizer` / `-start-after=riscv-vl-optimizer`를 사용하는 검증된 backend policy가 있다. 두 단계 모두 machine verification을 유지한다. 이 정책을 조용히 바꾸어 결과를 비교하지 않는다.
- 게시된 `generated/`, manifest, 결과 DB를 실험 출력으로 덮어쓰지 않는다. 새 실험 디렉터리에 commands, revision/diff, IR, MIR/assembly, hash와 검사 결과를 보관한다.
- 이전 결과와 새 결과의 compiler/image/measurement identity를 분리한다. compile-only 결과를 RTL speedup으로 제시하지 않는다.

## 8. 되돌린 prototype의 참고 증거

다음은 재현 가능성을 보여주는 과거 관측치이며 새 구현의 검사를 대체하지 않는다.

- Vectorizer 내부의 branch folding/known-EVL 제한만으로 SGEMM에서 final reduction loops **0→8**, VF16/m8 유지, folded vector spill/reload **54→0**, 정적 명령어 **515→304**.
- 보관된 315개 Fission variant의 scalar IR을 Clang O2로 재최적화했을 때 final reduction 개수/VF 유지, constant-exit reduction 0개.
- 이전 신규 short-loop test와 기존 Fission tests를 합해 18개가 통과했지만, 신규 테스트는 현재 삭제된 상태다. 새 구현에 맞춰 테스트를 다시 작성한다.
- 별도 contribution 정규화 probe에서 SGEMM buffer **16→8**, payload **1,984→992 bytes**. 이는 loop 보존 수정과 별개의 실험이었다. 두 결과가 새 통합 구현에서도 동시에 성립하는지 확인해야 한다.
- 이전 probe에는 RTL cycle 재측정과 RVV 수치 검증이 없었다.

## 9. 최종 산출물과 완료 판정

최종 보고에 다음을 포함한다.

1. LLVM 구현 diff와 regression tests. 변경이 Vectorizer 안에 한정됐는지, 범위를 넓혔다면 재현 근거.
2. 세 사용자 요구사항 각각의 구현 방식과 충족 여부.
3. 대표 case와 전체 캠페인의 before/after 표: Map VF, reduction 개수/최종 loops, reducer VF/LMUL, contribution/buffer 개수·bytes, vector spill 위치/개수, compile/rejection 상태.
4. 실제 사용한 build/pipeline/target 명령, 테스트 결과, 수행한 수치 검증 및 수행하지 못한 범위.
5. 안전하게 1-contribution으로 정규화하지 못한 경우의 정확한 이유와 fallback/rejection 정책.

**완료 기준은 Map + accumulator별 독립 reduction loop + 가능한 최소 contribution storage + largest legal LMUL을 동시에 충족하고, 이를 최종 IR/codegen 및 의미 검증으로 뒷받침하는 것이다.** Transform commit remark, 작은 VF에서의 spill 감소, 일부 case의 성능 개선만으로 완료 처리하지 않는다.
