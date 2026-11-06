# Generic RISC-V MIR Info 비용 매핑 상세

## 1. 상태·범위·근거

`RISCVGenericMIRInfo`의 현행 명령 가격 명세다. XiangShan/Saturn/K1 모두
native `RISCVTTIImpl`과 이 공통 MIR 서비스를 사용하며, 실제 ISA·VLEN·DLEN·tuning을 유지한다.
가격은 reciprocal-throughput 선택 heuristic이며 측정된 cycle이나 IR 총비용의 재현이 아니다.

[관측·선택·fallback 계약](../BACKEND_FEEDBACK.md)과 [단위·정규화](rule.md)는
각 문서가 소유한다. 이 문서는 명령별 가격과 그 근거를 정의한다.
구현은 [가격 서비스](../llvm/lib/Target/RISCV/RISCVGenericMIRInfo.cpp),
[명시적 opcode 매핑](../llvm/lib/Target/RISCV/RISCVGenericMIRRules.inc),
[collector](../llvm/lib/Target/RISCV/RISCVVPlanMIR.cpp)에 있다.
검증 범위와 명령은 [README](../README.md#build-and-verification)를 따른다.
전체 ISA의 exhaustive 실행 검증이나 성능 보정을 의미하지 않는다.

기준 소스는 이 checkout의 `6e6cf039e3676069dd03ac25c095ef8eaaf6fc0d`다.
아래에서 native는 CPU별 CostSheet override 없이 `RISCVTTIImpl`과 그 BaseT가
계산하는 가격을 뜻한다. CPU를 generic CPU로 바꾸지 않는다.

| 출처 ID | 소스와 관련 함수 |
|---|---|
| T-op | [RISCVTargetTransformInfo.cpp](../llvm/lib/Target/RISCV/RISCVTargetTransformInfo.cpp): `getRISCVInstructionCost` |
| T-arith | 같은 파일: `getArithmeticInstrCost` |
| T-cast | 같은 파일: `getCastInstrCost` |
| T-intrin | 같은 파일: `getIntrinsicInstrCost`, `getPartialReductionCost` |
| T-cmp | 같은 파일: `getCmpSelInstrCost` |
| T-mem | 같은 파일: `getMemoryOpCost`, `getMaskedMemoryOpCost`, `getMemIntrinsicInstrCost` |
| T-irreg | 같은 파일: `getStridedMemoryOpCost`, `getGatherScatterOpCost`, `getInterleavedMemoryOpCost` |
| T-vl | 같은 파일: `getVScaleForTuning`, `getEstimatedVLFor` |
| L | [RISCVISelLowering.cpp](../llvm/lib/Target/RISCV/RISCVISelLowering.cpp): `getLMULCost`, `getVRGatherVVCost`, `getVRGatherVICost`, `getVSlideVICost`, `getVSlideVXCost` |
| B | [BasicTTIImpl.h](../llvm/include/llvm/CodeGen/BasicTTIImpl.h): arithmetic/cast/intrinsic/compare/memory 비용의 legal 단일 연산 경로 |
| S | [RISCVSubtarget.h](../llvm/lib/Target/RISCV/RISCVSubtarget.h): `getDLenFactor`, segment/gather tuning |
| O | [RISCVVPlanSpill.cpp](../llvm/lib/Target/RISCV/RISCVVPlanSpill.cpp), [RISCVVPlanMIR.cpp](../llvm/lib/Target/RISCV/RISCVVPlanMIR.cpp): 관측 범위와 facts |

표의 가격 규칙 이름은 의미별 분류이며, JSON의 `rule` 값과 일대일 대응하지 않는다.
표의 **직접**은 native의 분리 가능한 명령 가격을 가져온다는 뜻이다. **유사**는
명시한 native 연산을 기준으로 같은 스케일을 적용하는 MIR 정책이다. **정책**은
IR 문맥에 따라 값이 달라 직접 결정할 수 없지만 MIR 의미로 결정한 항목이다.
유사·정책은 하드웨어 측정값이나 upstream이 보장하는 명령별 가격이 아니다.
`getRISCVInstructionCost`의 default만 통과했다는 이유로 지원 완료로 보지 않는다.

## 2. 공통 가격 함수와 geometry

### 2.1 단위와 서비스

- 모든 가격은 `TCK_RecipThroughput`의 native heuristic 단위다. Cycle/latency가 아니다.
- `B = TCC_Basic = 1`, `E = TCC_Expensive = 4`.
- 서비스 생성 시 실제 subtarget의 XLEN, ISA, nominal VLEN, DLEN factor,
  gather model, optimized-segment 조건을 보존한다. 타깃별 sheet는 사용하지 않는다.
- Native LMUL/gather helper와 segment 조건을 snapshot한다. 매 명령에 가상의 IR을
  만들거나 전체 IR 질의를 역산하지 않는다.
- 실제 한 명령의 가격을 합산한다. Legalization 배수, 예상 constant materialization,
  promotion, 예상 mask 생성, 예상 spill, 예상 split shuffle은 다시 더하지 않는다.

### 2.2 기호

| 기호 | 정의 |
|---|---|
| `V` | `getRealMinVLen()`에 대응하는 nominal VLEN(bits) |
| `D` | `getDLenFactor()`; 기준 소스에서는 1 또는 2. 임의의 CPU별 배율이 아니다. |
| `s, d` | 명령의 기준 SEW(bits), data LMUL. Fractional 값도 정확한 유리수로 보존한다. |
| `e, m` | memory EEW와 field 하나의 data EMUL, `m=d×e/s` |
| `ei, mi` | indexed memory의 index EEW와 EMUL, `mi=d×ei/s` |
| `g` | whole-register 명령의 physical group: 1, 2, 4, 8 |
| `F` | segment field 수 |
| `N` | nominal 원소 수. 일반 연산은 `V×d/s`, memory는 `V×m/e` |

명령별 base type은 관측된 실제 vector group에 대응하는 scalable MVT로 표현한다.
원래 fixed IR vector의 lane 수로 다시 legalization하지 않는다. RVV 최소 block 64bit
표현이 가능한 geometry에서 해당 타입의 최소 lane 수는 `64×d/s`다.
SEW·LMUL의 유효 조합, field group, index/data 원소 수 일치, ISA 지원을 검증한다.
물리 register 하나를 쓴다는 사실만으로 fractional LMUL을 1로 바꾸지 않는다.

`C(d)`는 L의 **scalable** `getLMULCost`와 동일하게 정의한다.

```text
integer d ∈ {1,2,4,8}: C(d) = d × D
fractional d = 1/q:    C(d) = (q ≤ D ? D/q : 1), q ∈ {2,4,8}
```

기준 소스의 D에서는 `max(1,d×D)`와 같지만, 구현은 native helper의 동작을 따른다.
예: D=2이면 C(mf4)=1, C(mf2)=1, C(m1)=2, C(m2)=4.
Native fixed-MVT helper의 `ceil(type bits/(V/D))` 경로를 실제 RVV 명령에
중복 적용하지 않는다. 관측 명령은 그 명령의 group geometry로 계산한다.

### 2.3 원소 수 정책

초기 revision은 **nominal capacity를 일관되게 사용**한다. `N=V×d/s`이며
실제 runtime VL, mask density, 실행 확률을 추측하지 않는다. Fixed IR의 작은 lane 수나
AVL immediate를 보았다는 이유만으로 N을 줄이지 않는다. T-vl의 scalable estimate와
대응하고 `count_source=nominal-capacity`를 기록한다.
증명된 유효 VL을 활용하는 별도 revision은 이번 명세에 포함하지 않는다.

N은 양의 정수여야 한다. Elementwise 가격은 VL=0 가능성이나 all-false mask 때문에
0으로 만들지 않는다. Reduction의 N=1에 대한 native 명시적 0은 아래 예외다.

## 3. Scalar 명령

아래 규칙은 실제 ISA에 존재하고 해당 subtarget에서 지원되는 명령에만 적용한다.
W 형식은 실제 32bit 연산으로 기록하되 RV64에서 가격을 절반으로 줄이지 않는다.
Compressed encoding은 같은 의미의 일반 명령 가격이며 code-size 할인은 없다.

| 가격 규칙 / 명령군·예 | 가격 | 대응·조건 |
|---|---:|---|
| S-ALU: ADD/SUB, AND/OR/XOR, shift(SLLI.UW 포함), SLT/SLTU, immediate/W 형식 | B | 직접: B의 legal 정수 arithmetic/compare |
| S-CZERO: CZERO.EQZ/NEZ | B | 유사: 단일 조건부 값 선택. Compare+select 두 명령으로 중복 계산하지 않음 |
| S-MUL: MUL/MULW/MULH/MULHU/MULHSU | B | MUL은 직접, high-half는 유사: native 정수 multiply 기본 가격. Latency 배율 없음 |
| S-CLMUL: CLMUL/CLMULH/CLMULR | B | CLMUL은 B의 legal `Intrinsic::clmul` 경로 직접, H/R은 유사. Zbc/Zbkc 등 실제 ISA 지원 필요 |
| S-DIV: DIV/DIVU/REM/REMU 및 W | E | 직접: T-arith의 i32/i64 div/rem table. 실제 명령이 남았으면 power-of-two IR 간소화 미적용 |
| S-BIT: ANDN/ORN/XNOR, MIN/MAX, CLZ/CTZ/CPOP, rotate, REV8, byte/bit extract/set/clear/invert | B | 직접 또는 유사: legal 정수 intrinsic/논리·shift 기본 가격. 단일 명령일 때만 적용 |
| S-ADDR: LUI/AUIPC, SH1ADD/SH2ADD/SH3ADD와 .UW, ADD.UW | B | 유사: 기본 주소/정수 ALU. 결합된 shift+add를 두 번 계산하지 않음 |
| S-EXT: 실제 SEXT/ZEXT 명령, ADDIW 등 확장용 명령 | B | 정책: native free cast는 제거될 때의 비용. 남은 ALU는 S-ALU |
| S-MOVE: scalar register copy, FMV.X/FMV.*.X 및 FP move | B | 유사: register transfer. COPY는 expansion을 확인한 후 적용 |
| S-FP: FADD/FSUB/FMUL/FDIV H/S/D | 2B | 직접: B의 legal FP arithmetic. 실제 precision만 사용 |
| S-FMA: FMADD/FMSUB/FNMADD/FNMSUB | B | FMA 직접: B의 legal intrinsic, 다른 부호 형식은 유사. MUL+ADD로 분해하지 않음 |
| S-SQRT: FSQRT | B | 직접: B의 legal sqrt intrinsic; scalar FDIV의 2와 구별 |
| S-FCVT: FCVT FP↔integer, FP precision 변환, FCVTMOD | B | 직접: B의 legal 단일 cast. libcall/promotion 전체 비용은 미적용 |
| S-FROUND: FROUND/FROUNDNX | B | 유사: legal 단일 FP 변환/rounding. IR rounding 전체 sequence 추정은 적용하지 않음 |
| S-FLI: FLI.H/S/D/Q | B | 유사: 단일 immediate materialization/move. ISA가 지원하는 형식만 적용하며 memory load 추가 없음 |
| S-FCMP: FEQ/FLT/FLE, FLTQ/FLEQ 및 직접 비교 형식 | B | 직접: B의 legal SETCC 가격. IR 복합 predicate의 sequence 수는 미적용 |
| S-FMINMAX: FMIN/FMAX/FMINM/FMAXM | B | 직접: legal min/max intrinsic 기본 가격 |
| S-FSIGN: FSGNJ/FSGNJN/FSGNJX, FCLASS | B | 유사: sign/bit 조작과 FP 비교 기본 가격. FNEG IR arithmetic의 2를 일반 sign 명령에 확장하지 않음 |
| S-MEM: integer/FP load/store | B | 직접: T-mem/B의 legal 단일 memory. sign/zero extension 포함. 주소는 별도 |
| S-BR: 조건 branch, JAL/JALR의 control-transfer 부분 | B | 정책: 실제 제어 명령당 B. IR predicted branch=0 미적용 |
| S-TRAP: ECALL/EBREAK/UNIMP 및 해당 compressed 형식 | B | 유사: 명시적 trap/control transfer 한 번. OS/trap handler 내부 실행 시간은 모델 범위 밖 |
| S-MOP: Zimop MOP.R/MOP.RR 기본 형식 | B | 유사: GPR 결과 생성형 기본 명령. Vendor custom과 구별하며 다른 확장이 재정의한 명령은 그 실제 의미로 분류 |

S-BIT는 일반 scalar bit 조작을 가리킨다. CLMUL은 S-CLMUL로 별도 정의하며,
암호화 round는 §10.2의 별도 규칙으로 계산한다. Misalignment로 이미 여러 명령으로 분해되었다면
각 명령만 합산한다. 실제 단일 misaligned 접근에 native가 별도 가격을 분리하지 못하는
경우 B는 일반 접근과 같은 스케일이라는 유사 정책이며 지연을 예측하지 않는다.

부호 주입은 FP 숫자 산술과 구별한다. FNEG 문맥에서는 native arithmetic이 2를,
fabs/copysign 또는 bit 조작 문맥에서는 다른 값을 줄 수 있다. MIR에서는 원래 IR
ancestry 없이 같은 sign 명령에 같은 B를 부여한다. 이것은 문맥 의존성을 해소하는
명시적 정책이며 모든 IR FNEG 가격을 복제했다는 뜻이 아니다.

## 4. Vector 계산·mask·변환

`vv/vx/vi/vf` 형식은 특별 규칙이 없으면 같은 가격이다. Scalar operand 준비와
broadcast가 실제 별도 명령이면 그 명령을 추가한다. Masked/unmasked, tail/mask
undisturbed 정책은 동일 가격이며 필요한 merge/copy가 남으면 별도로 더한다.

| 가격 규칙 / 명령군 | 가격 | 출처·정책 |
|---|---:|---|
| V-INT: VADD/VSUB/VRSUB, 논리, shift, VMUL/VMULH*, VMIN/VMAX | C(d) | 직접: T-arith/T-intrin/T-op의 정수 기본 가격 |
| V-CARRY: VADC/VSBC/VMADC/VMSBC의 유효 operand 형식 | C(d) | 유사: add/sub 또는 carry 비교. Mask 결과도 입력 data geometry를 사용하며 mask 논리 B로 낮추지 않음 |
| V-IDIV: VDIV[U]/VREM[U], vv/vx | E×C(d) | signed vv 직접: T-op. unsigned/vx는 T-arith가 signed 대표 opcode를 쓰는 동일 연산군으로 확장 |
| V-ICMP: VMSEQ/VMSNE/VMSLT[U]/VMSLE[U]/VMSGT[U] | C(d) | 직접: T-cmp, **비교 data** geometry 사용. 결과 mask 타입으로 가격화하지 않음 |
| V-MERGE: VMERGE/VFMERGE | C(d) | 직접/유사: T-cmp의 VMERGE 가격. mask 생성은 별도 |
| V-IMAC: VMACC/VMADD/VNMSAC/VNMSUB | C(d) | 유사: 정수 multiply 기본 명령. FMA와 같은 fused-one-operation 정책 |
| V-SAT: VSADD[U]/VSSUB[U] | C(d) | 직접: T-intrin saturating arithmetic |
| V-FIXED: VAADD[U]/VASUB[U], VSMUL, VSSRL/VSSRA, VNCLIP[U] | C(d) | 유사: 각각 정수 add/mul/shift 및 narrow shift 기본 가격. saturation/rounding에 임의 배율 없음 |
| V-BIT: VANDN, VROL/VROR, VBREV/VBREV8/VREV8, VCLZ/VCTZ/VCPOP.V | C(d) | count는 T-intrin 직접, 나머지는 논리/shift 유사. VCPOP.M과 구별 |
| V-FP: VFADD/VFSUB/VFRSUB/VFMUL/VFDIV/VFRDIV | 2×C(d) | 직접: T-arith의 opcode 가격 × FP 배율 2 |
| V-FMA: VFMACC/VFMADD/VFMSAC/VFMSUB 및 음수 부호 변형 | C(d) | 직접/유사: T-intrin의 VFMADD. 2C(d)로 올리지 않음 |
| V-SQRT: VFSQRT | C(d) | 직접: T-intrin. promotion conversion이 관측되면 각각 계산 |
| V-ESTIMATE: VFREC7/VFRSQRT7 | C(d) | 유사: 단일 FP estimate 변환, VFSQRT와 같은 helper 기본 스케일. 정확한 FDIV 전체 비용이나 software refinement를 추가하지 않음 |
| V-FCMP: VMFEQ/VMFNE/VMFLT/VMFLE/VMFGT/VMFGE | C(d) | 직접/유사: T-cmp의 단일 FP compare. IR 복합 predicate의 추가 compare/mask는 실제 존재할 때만 |
| V-FMINMAX: VFMIN/VFMAX | C(d) | 유사: T-op의 기본 FP min/max 명령 가격. 일반 FP arithmetic 배율을 적용하지 않음 |
| V-FSIGN: VFSGNJ/VFSGNJN/VFSGNJX, VFCLASS | C(d) | 정책/유사: T-intrin fabs의 sign helper 및 논리/분류. Scalar sign 정책과 동일 이유로 FNEG 문맥의 2C는 미적용 |
| V-CVT: 동일 폭 VFCVT*, RTZ 형식 | C(d) | 직접: T-cast. FP 산술 배율 없음 |
| V-BCAST: VMV.V.V/VMV.V.X/VMV.V.I, VFMV.V.F | C(d) | 직접/유사: T-op/T-intrin. Whole-register move와 구별 |
| V-TRANSFER: VMV.X.S/VMV.S.X/VFMV.F.S/VFMV.S.F | B | 직접: T-op의 고정 scalar transfer |
| M-LOGIC: VMAND/VMANDN/VMOR/VMXOR/VMNAND | B | 직접: T-op. mask SEW=1을 data C(d)에 넣지 않음 |
| M-LOGIC-EXT: VMORN/VMNOR/VMXNOR, mask copy/clear/set alias | B | 유사: 위 mask 논리. alias expansion 하나만 계산 |
| M-SCALAR: VCPOP.M/VFIRST.M | B | 직접: T-op; N 또는 LMUL을 곱하지 않음 |
| M-PREFIX: VMSBF/VMSIF/VMSOF | B | 유사: VFIRST.M + mask 논리의 고정 스케일. 실제 한 mask instruction으로 취급 |
| V-INDEX: VID, VIOTA | C(d) | VID는 T-intrin/T-op 직접, VIOTA는 동일 data 결과 생성 스케일 유사. 입력 mask group이 아닌 출력 data group 사용 |

### 4.1 Widening/narrowing: 실행 geometry와 가격 geometry

실행 geometry는 widening의 narrow source, narrowing의 narrow destination이다.
그러나 **가격에 넣는 group은 명령군별 native 대응 타입**으로 결정한다.

| 명령군 | 실행 기준 | 가격 | 근거 |
|---|---|---:|---|
| VWADD/VWSUB/VWMUL/VWSLL, widening 정수 MAC | narrow `s,d`, wide result `2s,2d` | C(2d) | 유사: native 정수 결과 타입 스케일. Fused MAC도 한 명령 |
| VFWADD/VFWSUB/VFWMUL, .W 형식 | narrow `s,d` | 2×C(2d) | 유사: wide-result FP arithmetic 가격 |
| VFWMACC 계열 | narrow `s,d` | C(2d) | 유사: wide-result FMA 가격 |
| VSEXT/VZEXT.VF2/VF4/VF8 | destination `s,d`, source `s/k,d/k` | C(d) | 직접: T-cast가 DstLT로 가격화 |
| VFWCVT (FP↔FP/FP↔int), BF16 widening | narrow `s,d` | C(2d) | T-cast의 일반 widening은 destination 타입을 사용. BF16도 같은 결과 폭 정책 |
| VFNCVT (FP↔FP/FP↔int), BF16 narrowing | narrow destination `s,d` | C(d) | 직접/유사: T-cast의 narrow destination |
| VNSRL/VNSRA, VNCLIP[U] | narrow destination `s,d`, wide source `2s,2d` | C(d) | VNSRL 직접: T-cast. 나머지는 narrow shift 유사 |

T-intrin의 promoted sqrt sequence는 VFWCVT를 narrow `ConvType`으로 가격화하는
경로도 있다. 같은 opcode가 T-cast에서는 wide destination 가격을 받는다.
이 명세는 **변환 자체의 T-cast destination 규칙**을 선택한다. Sqrt sequence 추정 총액에
맞춰 변환을 할인하지 않는다. Widening 산술은 직접 IR 단일 opcode 대응이 없는
경우에도 위 결과 폭 규칙으로 확정한다. 이러한 유사 규칙은 native IR 변경이 아니다.

## 5. Gather·slide·reduction

`G(d)`는 L의 `getVRGatherVVCost`를 그대로 사용한다.

```text
c = C(d)
기본 gather model: G(d) = c²
NLog2N model:      G(d) = c×floor(log2(c))  (floor(log2(c)) > 0)
                  G(d) = c²               (그 외)
```

| 가격 규칙 / 명령 | 가격 | 근거·조건 |
|---|---:|---|
| P-GATHER-VV: VRGATHER.VV | G(d) | 직접: L. Data group 기준 |
| P-GATHER-EI16: VRGATHEREI16.VV | G(d) | 유사: 같은 data gather. index EMUL=`d×16/s` 검증, 별도 index 배율 없음 |
| P-GATHER-S: VRGATHER.VI/VX | C(d) | VI 직접, VX 유사: L의 동일 scalar-index 설명 |
| P-SLIDE: VSLIDEUP/VSLIDEDOWN VI/VX | C(d) | 직접: 현 native slide helper와 같은 group 규칙 |
| P-SLIDE1: VSLIDE1UP/DOWN, VFSLIDE1UP/DOWN | C(d) | T-op 기본 가격/유사. Scalar transfer B를 추가하지 않음 |
| P-COMPRESS: VCOMPRESS | C(d) | 유사: data permutation의 기본 linear group 가격. 압축률 추정 없음 |
| R-TREE: VRED{SUM,AND,OR,XOR,MIN,MAX,MINU,MAXU}, VFRED{USUM,MIN,MAX} | ceil(log2(N)) | 직접: T-op. N은 reduction 입력 data 원소 수 |
| R-ORDER: VFREDOSUM | N | 직접: T-op. FP arithmetic 배율 2 없음 |
| R-WIDE: VWREDSUM[U], VFWREDUSUM | ceil(log2(N)) | 유사: narrow input의 tree reduction; 결과 group 배율을 추가하지 않음 |
| R-WIDE-ORDER: VFWREDOSUM | N | 유사: ordered reduction의 narrow input 원소 수 |
| R-DOT4: VDOT4A, VDOT4AU, VDOT4ASU, VDOT4AUS의 유효 VV/VX 형식 | C(d) | VDOT4A.VV는 T-intrin `getPartialReductionCost` 직접. 나머지는 같은 packed dot의 부호/operand 변형으로 유사 확장. d는 accumulator/result group |

Native tree reduction은 N=1이면 0이다. 따라서 `max(1,ceil(log2(N)))`로 바꾸지 않는다.
이 0은 명시된 native 규칙의 결과이며 unknown/failure의 대체값이 아니다.
초기값 삽입, 결과 scalar extract, split combine은 실제 관측 명령으로 각각 계산한다.
Ordered 여부는 fast-math 추측이 아니라 실제 opcode로 결정한다.

## 6. Memory·whole-register·spill

주소 계산, index vector 생성, stride 생성, constant-pool 주소 생성은 별도 명령이다.
일반 접근과 spill 접근은 같은 opcode/geometry이면 같은 가격이다.
Spill-slot 분류는 S에 포함할지 결정하며 가격을 할인하거나 가산하지 않는다.

| 가격 규칙 / 명령군 | 가격 | 근거·조건 |
|---|---:|---|
| MEM-UNIT: VLE/VSE | C(m) | 직접: T-mem의 legal vector access. EEW 기반 data EMUL 사용 |
| MEM-MASKED: masked VLE/VSE | C(m) | 직접: T-mem masked 경로. mask density 할인 없음 |
| MEM-FOF: VLE*FF | C(m) | 직접/유사: T-intrin memory의 `vp_load_ff`가 ordinary load 가격 사용. VL read 명령은 별도 |
| MEM-STRIDE: VLSE/VSSE | N×B | 직접: T-irreg. zero/unit stride여도 실제 strided opcode의 nominal 정책 |
| MEM-INDEX: VLUXEI/VLOXEI/VSUXEI/VSOXEI | N×B | gather/scatter 직접, ordered 형식 유사. mi와 m을 각각 검증. index 크기를 N에 다시 곱하지 않음 |
| MEM-SEG: VLSEG/VSSEG, F fields | F×N×B | 직접: T-irreg의 비최적화 segment 정책. N은 **field당** lane 수 |
| MEM-SEG-OPT: optimized unit-stride segment | Cwide(F×m)+F×C(m) | 유사 대응: T-irreg의 wide memory + field별 shuffle. 아래 조건 적용 |
| MEM-SEG-STRIDE: VLSSEG/VSSSEG | F×N×B | 유사: field당 strided 접근. unit-stride optimized flag 미적용 |
| MEM-SEG-INDEX: VLUXSEG/VLOXSEG/VSUXSEG/VSOXSEG | F×N×B | 유사: field당 indexed 접근. index 준비 중복 없음 |
| MEM-SEG-FOF: VLSEG*FF | ordinary unit-stride segment 가격 | 유사: FOF load의 ordinary-access 정책을 segment로 확장 |
| MEM-MASK: VLM/VSM | max(1,ceil(ceil(Nmask/8)/(V/(8D)))) | 유사: packed mask byte 접근을 ordinary memory의 datapath 스케일로 계산 |
| REG-MOVE: VMV1R/2R/4R/8R | C(g) | 유사: 실제 full data group copy; LMUL 또는 VL과 무관 |
| MEM-WHOLE: VL1/2/4/8RE*, VS1/2/4/8R | C(g) | 유사: full register group의 ordinary memory. load EEW와 관계없이 g registers의 bytes 이동 |

`MEM-SEG-OPT`는 실제 subtarget의 `hasOptimizedSegmentLoadStore(F)`와 native의
legal segment 조건(타입·alignment·address space)이 성립할 때 적용한다.
`Cwide(t)=max(1,ceil(t×D))`는 t group 분량을 한 nominal wide 접근으로 보는
MIR 정책이다. 합법적인 power-of-two group 조각별 C를 합산한 식이 아니다.
예를 들어 t=3/4,D=1이면 Cwide=1이지만 C(1/2)+C(1/4)=2다.
Native의 wide-memory + field shuffle 구조와 datapath 스케일을 따르되,
가상 IR wide type의 legalization/split 총비용을 직접 재현한다고 주장하지 않는다.
실제 관측 명령이 여러 개라면 각 명령에 이 규칙을 적용한다.
필요 facts가 없으면 최적화 유무를 임의 결정하지 말고 geometry/facts 오류로 반환한다.

`Nmask`는 mask의 nominal bit 수다. packed byte 크기와 capacity를 보존하며
mask SEW=1을 일반 data MVT에 전달하지 않는다. Nmask≤V인 유효 mask geometry에서
기준 D=1이면 B이며, D=2이면 mask byte 크기에 따라 B 또는 2B다. Byte 수에서 다시 LMUL 비용을 곱하지 않는다.

실제 scalar spill/reload는 S-MEM, vector spill/reload는 대응 memory 규칙이다.
Whole-register group 2는 `C(2)`이고 group 1 두 번은 `2×C(1)`이다.
Fractional data access와 whole-register access는 같은 physical register를 써도
다른 규칙을 사용한다. Tuple spill이 여러 접근으로 확장되면 각 접근을 한 번씩만 더한다.
혼합 scalar/vector slot의 주소 명령을 spill access 가격으로 흡수하지 않는다.

## 7. Configuration·copy·pseudo·control

| 가격 규칙 / 항목 | 가격·처리 | 근거 |
|---|---|---|
| CFG-VSET: VSETVLI/VSETIVLI/VSETVL | C(1)=D | VSETVLI 직접: T-intrin이 `nxv1i64`로 T-op을 호출. 다른 형식은 유사. 설정하려는 LMUL을 곱하지 않음 |
| CFG-CSR: CSRRW/CSRRS/CSRRC 및 immediate 형식, CSR read/write alias | B | 정책: 실제 CSR 접근 한 명령당 가장 싼 basic cost. CSR 종류·privilege·read/write 결합에 추가 배율 없음 |
| RA-COPY | 확인된 expansion의 합 | GPR/FP move=B, vector element copy=C(d), whole copy=C(g). Regclass만 보고 expansion을 가정하지 않음 |
| RVV pseudo | base opcode 규칙 | pseudo table에서 **한 실행 명령**임이 확인되고 geometry/operand 의미가 보존되는 경우 |
| 여러 명령으로 확장되는 pseudo | 현재 facts로 확정되는 expansion의 가격 합 | 추가 수집이 필요하면 아래 PSEUDO-NOMINAL 적용. 이미 관측한 expansion과 중복 계산 금지 |
| PSEUDO-NOMINAL: 추가 정보가 필요한 pseudo | 실질적 계산 있음: B=1, 없음: 0 | §7.3의 근사. Expansion 입력을 추가 수집하지 않음 |
| STATE-HINT-IGNORE: cache 관리·prefetch·wait/hint | 0 | §10.3의 무시 정책. 실제 memory 접근·계산과 구별 |
| Branch pseudo/long branch | 실제 또는 증명된 expansion의 S-BR/S-ADDR 합 | IR branch 비용 및 branch 확률 미적용 |
| CALL: 일반 call/libcall | call transfer 한 건당 native `getCallInstrCost`, 현재 10 | 내부 실행은 IR TTI의 opaque-call 정책. 같은 transfer의 S-BR=B를 중복 가산하지 않음 |
| CUSTOM-IGNORE: vendor custom instruction | 0 | 제외. 등록된 vendor/custom 명령군으로 식별해야 하며, 모든 unknown opcode의 기본값으로 사용하지 않음 |
| Metadata/pseudo probe/return/frame setup·destroy | 기존 observer 범위에서 제외 | O의 `isBodyInstruction` 계약. 가격 0으로 지원 처리하는 것이 아님 |

### 7.1 Call/libcall: IR TTI 정책 적용

callee 내부를 따로 분석하거나 실측 가격을 만들지 않는다.
기준 소스에서 RISCVTTIImpl이 상속하는 B의 `getCallInstrCost`는 10을 반환한다.
이 **call 전체의 opaque 추정치**를 call transfer 가격으로 사용한다. 여기에 별도의
callee 비용 10 또는 branch 비용 B를 다시 붙이지 않는다. Direct/indirect/libcall 모두
실제 call이 된 상태에서는 이 경로를 사용한다. Tail call이 관측 범위에 들어오면 동일하다.

실제 AUIPC 등 주소 생성, 인자 move, spill/reload는 관측된 명령으로 별도 합산한다.
따라서 JALR call은 10, AUIPC+JALR expansion은 1+10이다. PseudoCALL 자체와
그 expansion을 동시에 계산하지 않는다. 이는 IR/MIR 총액 일치를 요구하지 않는 기존 원칙과 같다.

`getIntrinsicInstrCost`에는 libcall fallback `SingleCallCost=10` 외에 ctpop 등의
예외 추정도 있다. 이는 **원래 intrinsic의 lowering 예측**이며 실제 call의 명령 가격으로
복사하지 않는다. 실제 call에는 `getCallInstrCost`를 적용하고, 하드웨어 FSQRT/FMA 등이
남았으면 기존 단일 명령 규칙을 적용한다. Call facts는 call 여부와 expansion의 transfer를
식별해야 하며, 외부 함수 이름만으로 함수별 가격표를 만들지 않는다.

### 7.2 Atomic·fence·CSR: 합산 모델의 명시적 근사

경쟁·재시도·직렬화 지연 모델을 추가하지 않는다. Atomic은
동등한 기본 memory/ALU 연산의 합, fence는 의도적인 비용 0, CSR 접근은 B로 정한다.

| 가격 규칙 / 실제 명령 | 비용 | 의미상 대응 |
|---|---:|---|
| AT-LR: LR.W/D | B | load 한 번. Reservation 설정 추가 비용 없음 |
| AT-SC: SC.W/D | B | store 한 번. 성공 여부·retry 확률을 곱하지 않음 |
| AT-SWAP: AMOSWAP | 2B | load+store; 기존 값 반환에 별도 copy 추가 없음 |
| AT-RMW: AMOADD/AND/OR/XOR/MIN/MAX/MINU/MAXU | 3B | load+해당 ALU+store |
| AT-CAS: AMOCAS | 3kB | load+compare+store의 k개 XLEN 조각. W/D/Q의 실제 폭 w에 대해 k=ceil(w/XLEN) |
| SYNC-FENCE: FENCE/FENCE.TSO/FENCE.I 및 명시적 주소변환 invalidation fence | 0 | Synchronization 비용 무시 정책. 미지원 기본값 0과 구별 |
| CFG-CSR: 실제 CSR read/write/read-modify-write | B | read와 write가 결합되어도 한 명령이면 B |

일반 AMO/LR/SC는 해당 XLEN에서 지원되는 W/D 형식에 적용한다. CAS의 wide 형식은
비교 대상과 memory 폭을 함께 스케일한다. acquire/release bit에 추가 배율은 없다.
LR/SC loop로 lowering되면 LR, SC, ALU, branch를 각각 기존 static block sum으로
합산하고 CAS 가격을 다시 붙이지 않는다. Retry 횟수는 추정하지 않는다.
Fence는 보고에 `policy-ignored`로 남겨 unknown과 구별한다. PAUSE는 의미상
wait/hint로 분류하며 §10.3의 STATE-HINT-IGNORE에 따라 동일하게 0이다.

### 7.3 추가 정보가 필요한 pseudo의 0/1 정책

현재 수집 경로의 owned facts와 이미 보유한 subtarget 정보로 expansion을 확정할 수
있으면 기존 명령별 합을 사용한다. **그 밖의 operand·주변 명령·최종 layout 등을 추가로
수집해야 한다면 그 정보에 따른 비용은 계산하지 않고 pseudo 한 개를 0 또는 1로 평가한다.**
추가 probe, parsing, layout 추정, expansion 입력 수집을 요구하지 않는다.
이 정책은 RVV pseudo도 포함한다. 현재 Opcode/BaseOpcode, SEW/LMUL 등의 facts와
정적 TableGen 매핑으로 EEW/field 수/index geometry 등을 도출할 수 있으면 정상 가격을
계산한다. 그러나 새 동적 operand/MMO 정보 수집이 꼭 필요하면 계산형 RVV pseudo도
1로 처리한다. 이는 일반 memory/LMUL 식을 모든 pseudo에 무조건 적용한다는 뜻이 아니다.
현재 facts가 이미 모순되거나 불가능한 geometry를 나타내면 수집 부족이 아닌 오류다.
Inline asm은 별도로 승인한 IR TTI 가격을 전달해야 하므로 이 0/1 정책의 예외다.

- `PSEUDO-NOMINAL-COMPUTE=1`: 산술·논리·비교·주소 계산·값 이동·load/store·호출 등
  실제 값을 계산하거나 전달하는 작업을 포함하는 pseudo. Atomic, conditional ALU/copy,
  KCFI check 등이 해당한다. 명령 수·LMUL·폭에 따른 추가 배율은 없다.
- `PSEUDO-NOMINAL-NOCOMPUTE=0`: metadata, no-code 선언, NOP/padding/alignment,
  hint·상태 관리만 담당하는 pseudo. Metadata 등 기존 observer 제외 대상은 계속 제외한다.
- 세부 operand에 따라 계산 유무가 달라지지만 현재 facts로 그 구분도 안 되는 **알려진**
  pseudo군은 계산을 포함할 수 있는 군이면 1로 분류한다. 예를 들어 PATCHPOINT/STATEPOINT는
  호출을 포함할 수 있어 1이다. 이는 실제 call 관측을 주장하는 것이 아닌 nominal 분류다.
- 전혀 의미를 모르는 opcode를 자동으로 계산형 1로 만들지 않는다. Opcode/descriptor와
  알려진 pseudo 의미로 위 두 분류를 정한다. Custom 명령은 별도의 0 정책이 우선한다.

PSEUDO-NOMINAL은 **해당 pseudo 전체의 대체 비용**이다. 추정 expansion 일부나 CALL=10을
다시 더하지 않는다. 예를 들어 추가 layout 정보가 필요한 PseudoCALLLpadAlign 전체는 1,
현재 facts로 고정 expansion이 확인되는 PseudoCALL은 기존 AUIPC+CALL=11이다.
관측에 별도 나타난 인자 준비·주소 계산 등의 명령은 기존 규칙대로 합산한다.
이 차이는 추가 수집을 하지 않는다는 정책에 따른 명시적 근사다.

COPY/PHI도 현재 facts로 실제 expansion을 알면 해당 가격을 사용하고, 추가 정보가
필요하면 값 전달 작업으로 1이다. No-code IMPLICIT_DEF는 0이다. 기존 observer가
제외하는 명령을 이 규칙으로 다시 포함하지 않는다. 일반 stack address 계산은
frame flag에 의해 제외되지 않는 한 기존 S-ADDR/S-ALU를 사용한다.
보고에는 `pseudo-nominal-compute`/`pseudo-nominal-no-compute`를 기록하며,
unknown 기본값이나 정확한 expansion 가격으로 표시하지 않는다.

## 8. Facts·구현 경계·composition

가격화에는 다음 정보를 owned facts와 정적인 opcode/subtarget 매핑으로 마련한다.
문자열 prefix 또는 XiangShan whitelist를 분류의 근거로 사용하지 않으며,
기본 opcode/descriptor, RVV pseudo table과 operand 의미를 사용한다.

- Base opcode, 명령군, ISA/형식/precision, pseudo expansion kind와 expansion 증거.
- 실행 SEW/LMUL, 별도의 price geometry 역할(source/destination/data/mask/whole).
- EEW, field 수, data/index EMUL, ordered/FOF/masked 여부, physical group.
- Scalar/vector spill-slot 여부와 방향. 필요 size/alignment/address space.
- Mask bit capacity 및 reduction 입력 capacity. `nominal-capacity` 출처.
- Configuration 종류, copy의 현재 source/destination 정보와 확정 가능한 expansion.
  CSR identity는 모두 B인 현 정책에서는 가격 필수가 아닌 선택적 진단 정보다.
- Call/inline asm/custom 구분. Pseudo는 현재 수집된 expansion 입력만 사용하며,
  target/patch bytes/상수/주변 명령 등의 추가 수집이 필요하면 §7.3의 0/1 정책 적용.
- Crypto/dot의 element/accumulator group, matrix 명령의 결과 tile geometry와 누산 단계 수.

분류 우선순위는 기존 observer 제외 → 명시적 custom/cache·hint 무시 및 inline asm 정책
→ 현재 facts로 확정되는 pseudo expansion 또는 PSEUDO-NOMINAL → 실제 opcode 가격이다. Custom/inline asm을 일반 CALL 또는 unknown default로
중복 처리하지 않는다.

가격 service는 `{cost, rule-id, evidence-kind, price-geometry, count-source}` 또는
명시적 오류를 반환한다. 현 보고는 `rule`, `evidence`, `price_group8`, `count_source`와
유리수 numerator/denominator를 담는다. Snapshot revision은
`generic-mirinfo-native-v1`이며 기존 `generic-v1`과 구별한다.

MIR body `R`와 spill 부분합 `S`에는 같은 명령 가격을 사용한다. 주소 계산은 body에
남긴다. `R-S+Et`의 Et는 native TTI spill hook으로 계산하며 scalar baseline에도 대칭적으로 적용한다.
정확한 폭 정규화와 모델별 loop 제외·whole-loop fallback은
[가격 단위](rule.md)와 [backend 계약](../BACKEND_FEEDBACK.md)을 따른다.
미지원/누락/모순을 정상 비용 0 또는 1로 바꾸지 않는다. §7.3의 알려진 pseudo와 명시적
무시 정책은 이 실패 경로와 구별하며, 유효한 다른 loop 및 독립 spill 관측은 보존한다.

## 9. 계산 예시

다음은 식의 예시이며 컴파일 실험·추가 테스트·정확도 검증 결과가 아니다.

| 조건/실제 명령 | 새 명세의 비용 | 확인하는 구분 |
|---|---:|---|
| D=2, d=mf2, VADD | 1 | Fractional LMUL과 DLEN |
| D=2, d=m2, VFADD / VFMACC / VFSQRT | 8 / 4 / 4 | FP 산술과 intrinsic 가격 차이 |
| D=2, VSETVLI e32,m8 | 2 | 설정 대상 m8이 아닌 native config 기준 m1 |
| D=1, V=128, d=m1, s=32, VFREDUSUM / VFREDOSUM | 2 / 4 | N=4의 tree/ordered 차이 |
| D=1, V=64, d=m1, s=64, VREDSUM | 0 | N=1 native 명시적 가격 |
| D=2, narrow d=m1, VFWCVT / VFNCVT | 4 / 2 | Wide destination와 narrow destination |
| D=2, d=m4, VRGATHER.VV, 기본 / NLog2N | 64 / 24 | C=8, tuning별 식 |
| V=128, s=32, d=m1, indexed memory | 4 | index EEW와 무관하게 N=4 |
| D=1, V=128, e=32, m=m1, F=2 segment | 기본 8 / optimized 4 | F×N와 Cwide(2)+2C(1) |
| D=2, vector whole reload g=2 | 4 | Spill 여부와 관계없는 C(g) |

## 10. 특수 명령 정책

### 10.1 Inline asm·pseudo·custom instruction

[TargetTransformInfoImpl.h](../llvm/include/llvm/Analysis/TargetTransformInfoImpl.h)의
일반 `getInstructionCost`에 맞춰 inline asm은 **ASM-OPAQUE=B×(IR argument 수+1)**로 계산한다.
빈 asm도 인자가 없으면 1이다. IR call의 원래 인자 수를 private probe lowering의
metadata로 운반하고 collector가 owned fact로 복사한다. MIR constraint/implicit register 수로
대체하거나 asm 문자열을 파싱하지 않는다. INLINEASM/INLINEASM_BR에는 §7.3의 pseudo 0/1을 적용하지 않는다.

이 기준은 LV의 `getVectorCallCost` → `getCallInstrCost=10`과 다른 질의다.
일반 call은 §7.1을 따른다. `getInlineAsmLength`나 MC parser는 throughput 가격의 근거로 쓰지 않는다.

**명시적으로 등록된 vendor/custom 명령은 비용 0**이며 `policy-ignored`로 보고한다.
Inline asm 내부의 `.insn`은 별도 파싱 없이 ASM-OPAQUE를 따른다. 낯선 표준 명령이나
일반 pseudo를 custom으로 취급하지 않는다.

MIR observer는
[RISCVTargetMachine.cpp](../llvm/lib/Target/RISCV/RISCVTargetMachine.cpp)의
`addPreSched2`에서 실행되고, 일반/atomic pseudo expansion은 이후 `addPreEmitPass2`에 있다.
그러므로 이 stage에서 pseudo가 남는 것 자체는 정상이다.

| 실제 pseudo | LLVM이 아는 확장 | 추가 정보와 이를 수집하지 않을 때의 가격 |
|---|---|---|
| `PseudoCALL`, `PseudoLLA` | AUIPC+JALR, AUIPC+ADDI | 이미 지원 가능한 고정 expansion. 불명확한 pseudo의 사례가 아님 |
| `PseudoAtomicLoadAdd32/64`, `PseudoCmpXchg32/64`, masked atomic pseudo | LR/SC와 ALU/compare/branch sequence | ordering, masked operand 및 extension 조건. [Atomic expander](../llvm/lib/Target/RISCV/RISCVExpandAtomicPseudoInsts.cpp)에 규칙이 있으나 추가 수집이 필요하면 전체 1 |
| `PseudoCCADD`, `PseudoCCMOVGPR` 등 | 조건 분기+연산 또는 지원되는 조건부 연산 | operand와 subtarget에 따른 경로. [Pseudo expander](../llvm/lib/Target/RISCV/RISCVExpandPseudoInsts.cpp)의 `expandCCOp` 참조. 추가 수집이 필요하면 전체 1 |
| `PATCHPOINT` | 호출 주소 materialization+call+NOP padding 또는 padding만 | target 종류/주소 값, patch byte 수, 압축 가능 여부. 추가 수집 없이 전체 1 |
| `STATEPOINT` | patch bytes가 있으면 NOP, 없으면 target 종류에 맞는 call | patch bytes와 target의 global/immediate/register 구분. 추가 수집 없이 전체 1 |
| `STACKMAP` | 뒤따르는 명령으로 shadow를 채우고 모자란 부분에 NOP | shadow bytes, 주변 명령, 압축 단위. observer가 포함하는 경우에도 no-compute 0 |
| `PseudoCALLLpadAlign`, `PseudoCALLIndirectLpadAlign` | call+LPAD와 필요 alignment padding | Zca/relax 설정, 최종 출력 위치에 따른 padding. 추가 layout 수집 없이 계산형 pseudo 전체 1 |
| `KCFI_CHECK` | type hash load/materialization+compare/check sequence | hash 상수, register, patchable prefix 등. 추가 수집 없이 비교/검사 작업 전체 1 |

후반 항목의 근거는 [RISCVAsmPrinter.cpp](../llvm/lib/Target/RISCV/RISCVAsmPrinter.cpp)의
`LowerPATCHPOINT`, `LowerSTATEPOINT`, `LowerSTACKMAP`, `emitLpadAlignedCall`, `LowerKCFI_CHECK`다.
Observer가 제외하는 metadata 등을 이 표 때문에 관측 범위에 추가하지 않는다.

### 10.2 Crypto·dot/matrix

Native에 독립적인 명령 throughput 가격이 없는 crypto는 아래 유사 연산 규칙을 쓴다.
Target intrinsic의 존재 자체가 전용 가격 분기의 근거는 아니다.
Scalar CLMUL은 §3, packed VDOT4 계열은 §5를 따른다.

| 가격 규칙 / 명령군 | 가격 | 기준과 근거 |
|---|---:|---|
| V-CLMUL: VCLMUL/VCLMULH VV/VX | C(d) | 정수 vector multiply와 같은 group 스케일. XOR 부분곱을 소프트웨어 sequence로 다시 펼치지 않음 |
| S-CRYPTO: AES32*, AES64*, SHA256*, SHA512*, SM3P0/P1, SM4ED/KS | B | 단일 scalar fused 정수 변환으로 간주. native 정수 MUL/bit 연산과 fused MAC의 기본 스케일. Software round의 모든 shift/XOR 개수를 가산하지 않음 |
| V-CRYPTO: VAES*, VSHA2*, VSM3*, VSM4*, VGHSH/VGMUL의 이 checkout 정의 형식 | C(d) | 단일 fused vector 정수 변환의 group 스케일. d는 실제 data/result group. Crypto block/round 개수를 추가 배율로 곱하지 않음 |
| DOT-ANALOG: 그 외 의미가 확인된 표준 packed integer/FP dot 명령 | C(dacc) | 한 packed dot을 fused operation으로 취급. Integer MAC 및 FP FMA와 같은 결과 group 스케일 |
| MATRIX-ANALOG: 의미가 확인된 표준 tile multiply-accumulate | K×Ctile | 아래 정의에 따라 vector FMA/MAC sequence의 합으로 대응 |

Crypto 비용 B/C(d)는 **값싼 fused 정수 연산으로 보는 명시적 초기 heuristic**이다.
암호화의 내부 gate 수·software instruction 수·pipeline latency를 뜻하지 않는다.
이 스케일은 MUL/FMA도 내부 작업량에 비례해 풀어 계산하지 않는 기존 native 철학에 맞춘다.
Scalar SHA512의 RV32 half-word 명령들도 각 실제 명령당 B이며, 전체 64bit 연산을
구현하는 여러 명령이 남으면 그 개수만큼 합산한다.

Vector crypto는 opcode별 합법적인 SEW, element-group 크기, data group 조건을
검증한다. `.vs`의 scalar block operand를 준비하는 별도 명령은 관측될 때 계산한다.
Mask/round 수나 runtime VL을 추측해 C(d)를 할인하지 않는다. 새 이름을 단순 prefix로
받아들이지 말고 [Zk 정의](../llvm/lib/Target/RISCV/RISCVInstrInfoZk.td)와
[Zvk 정의](../llvm/lib/Target/RISCV/RISCVInstrInfoZvk.td)의 해당 opcode군에 매핑한다.

Matrix 규칙에서 `K`는 실제 명령이 수행하는 dot의 누산 단계 수, `Ctile`은 output tile의
각 row를 합법적인 accumulator vector group들로 나누었을 때의 `Σ C(dacc_chunk)`다.
작은 조각도 C의 최소 비용을 적용하며, FP multiply-accumulate는 FP FMA 규칙을 쓴다.
예를 들어 결과 row 하나가 m2이고 두 row, K=4, D=1이면 `4×(2+2)=16`이다.
분리된 tile load/store는 실제 접근 규칙으로 따로 계산한다. 이미 packed dot 직접 가격이
있는 명령에 이 K 배율을 다시 붙이지 않는다. 이 checkout의 Zvvm geometry와 λ 근사는 §11을 따른다.
Vendor custom matrix에도 §10.1의 custom 무시 정책을 적용한다.

[CPU 정의](../llvm/lib/Target/RISCV/RISCVProcessors.td)의 Kunminghu에는 Zbc/Zkn/Zks가
포함된다. Scalar CLMUL/crypto를 대상과 무관하다고 제외하지 않는다. Saturn tune 이름은
ISA를 결정하지 않으며 [README](../README.md)의 rv64gcv에는 crypto/dot 확장이 없다.
실제 확장을 활성화한 경우에도 이제 위 가격 규칙을 사용한다. ISA 미지원과 가격 미정을
구별한다. 이 판단은 checkout의 기능 정의에 관한 것이며 하드웨어 성능 보증이 아니다.

### 10.3 Cache 관리·prefetch·wait/hint: 비용 0

| 구분 | 실제 명령 예시 | 등장하는 상황·가격이 다른 이유 |
|---|---|---|
| Cache 관리 | `cbo.clean`, `cbo.flush`, `cbo.inval` | DMA buffer 동기화 등에서 cache block을 write-back/invalidate. Scalar store 한 번과 같은 작업이 아님 |
| Block zero | `cbo.zero` | 메모리 초기화에서 cache block 하나를 0으로 만듦. 실제 데이터를 쓰지만 이번 memory 상태변경 무시 정책에 포함하여 0 |
| Prefetch | `prefetch.r/w/i` | 향후 읽기/쓰기/실행할 주소를 미리 가져오라는 hint. Builtin/intrinsic 또는 inline asm에서 발생 가능. 실제 load 결과를 생성하지 않음 |
| Spin hint | `pause` | Busy-wait loop에서 실행 자원 사용을 줄이라는 hint. 고정 실행 시간을 의미하지 않음 |
| Wait | `wfi`, `wrs.nto`, `wrs.sto` | OS/firmware의 interrupt 대기 또는 reservation 관련 대기. 실제 시간은 외부 사건에 의존 |

근거는 [Zicbo](../llvm/lib/Target/RISCV/RISCVInstrInfoZicbo.td),
[기본 ISA](../llvm/lib/Target/RISCV/RISCVInstrInfo.td),
[Za](../llvm/lib/Target/RISCV/RISCVInstrInfoZa.td) 정의다.
표의 모든 명령은 CBO.ZERO를 포함해 **STATE-HINT-IGNORE=0**이며 `policy-ignored`로 보고한다.
Cache 상태·대기 시간을 추정하지 않는 정책으로, 실제 실행 시간이 0이라는 뜻은 아니다.
별도 주소 계산은 기존 비용을 유지하며 일반 load/store·atomic·CSR로 이 정책을 확장하지 않는다.

## 11. Zvvm matrix

현 checkout의 `RISCVInstrInfoZvvm.td`에 정의된 integer/FP 및 microscaling
MAC과 tile load/store, transpose load/store도 가격화 대상이다. IR intrinsic과
RVV pseudo lowering은 현재 없으므로 이 지원이 새로운 IR lowering을 제공하지는 않는다.
Inline asm 내부는 계속 ASM-OPAQUE 규칙을 적용한다.

Geometry 근거는 [RISC-V IME draft, revision 6effbcae](https://github.com/riscv/integrated-matrix-extension/blob/6effbcae3204e5a8a9c9d15ff53959918144870c/src/integrated-matrix.adoc)다.
`L=VLEN/SEW`, output tile은 `M×M`, `M=L/λ`, `K=λ×W×LMUL`이다.
W는 opcode의 1/2/4/8 widening 배수이며 LMUL은 1/2/4/8만 허용한다.
λ는 1..64의 2의 거듭제곱이고 `EMUL_C=L/λ²`가 1/2/4/8/16이어야 한다.
SEW는 accumulator 폭이다. MAC은 `K×M×C(1/λ)`로 계산하고 작은 row도
최소 한 native vector 연산 비용을 가진다. Microscaling의 내부 연산은 별도 가산하지 않는다.

구현 선택 λ가 확인되지 않으면 합법적인 λ별 가격 범위의
최솟값·최댓값 산술평균을 정확한 유리수로 사용한다. 이는 실제 λ 관측이 아니라
`lambda-cost-midrange` 근사다. Tile load/store와 transpose 접근은 모두
`VLEN×LMUL/SEW`이며, 명시적인 tile λ immediate는 검증하되 가격 배율을 추가하지 않는다.
Collector는 reaching immediate VTYPE의 SEW/LMUL이 일치할 때만 사용하며,
동적·충돌·누락된 설정을 physical register 크기로 추정하지 않는다.
