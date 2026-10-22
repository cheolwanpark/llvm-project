# Fixed hardware evidence

Rules target XiangShan Kunminghu v2 **MinimalConfig**, revision
[`e7bab53e66dfb3c4a1d11cf9519b0396f8576cae`](https://github.com/OpenXiangShan/XiangShan/commit/e7bab53e66dfb3c4a1d11cf9519b0396f8576cae).
These are static decode workloads, **not execution chunks or processor cycles**.
Runtime VL, masks, alignment, memory-system behavior and scheduling can change
execution service without changing decode counts. The initial model learns the
effect of fixed work; it does not assert a cycle equality.

## Sources and ownership

All links below refer to that exact revision:

- [Configs.scala](https://github.com/OpenXiangShan/XiangShan/blob/e7bab53e66dfb3c4a1d11cf9519b0396f8576cae/src/main/scala/top/Configs.scala):
  `MinimalConfig` alters `BaseConfig`/`XSCoreParameters`, including ROB/queue sizes
  and registers. It does not replace the vector scheduler execution-unit mapping.
- [Parameters.scala](https://github.com/OpenXiangShan/XiangShan/blob/e7bab53e66dfb3c4a1d11cf9519b0396f8576cae/src/main/scala/xiangshan/Parameters.scala):
  `XSCoreParameters` sets VLEN=128, ELEN=64; `vfSchdParams` and `memSchdParams`
  define the inherited execution units and FU memberships.
- [VecDecoder.scala](https://github.com/OpenXiangShan/XiangShan/blob/e7bab53e66dfb3c4a1d11cf9519b0396f8576cae/src/main/scala/xiangshan/backend/decode/VecDecoder.scala):
  exact opcode → FU/split mappings; constructor defaults matter (e.g. OPIVI uses
  VEC_VXV, so immediate integer forms also introduce a move).
- [UopInfoGen.scala](https://github.com/OpenXiangShan/XiangShan/blob/e7bab53e66dfb3c4a1d11cf9519b0396f8576cae/src/main/scala/xiangshan/backend/decode/UopInfoGen.scala):
  `lmul`, `numOfUop*` and `numOfUop` branches define the formulas below.
- [DecodeUnitComp.scala](https://github.com/OpenXiangShan/XiangShan/blob/e7bab53e66dfb3c4a1d11cf9519b0396f8576cae/src/main/scala/xiangshan/backend/decode/DecodeUnitComp.scala):
  VEC_VXV/VFV, wide/scalar/slide/gather and memory branches assign the additional
  moves to I2V/F2V. They must not be charged as vector arithmetic work.
- [VSplit.scala](https://github.com/OpenXiangShan/XiangShan/blob/e7bab53e66dfb3c4a1d11cf9519b0396f8576cae/src/main/scala/xiangshan/mem/vector/VSplit.scala):
  `s0_emul`, whole-register/mask overrides, segment field count and dynamic
  splitting distinguish decode work from memory execution splitting.

`hardware.py` owns the fixed work/resource calculations. C++ only observes
pseudo-table encodings, register units and MIR operand facts. `opcodes.json`
contains 405 literal decoder records with original line numbers, source revision
and SHA-256. It includes scalar FP records for traceability; unverified scalar
FU decompositions are not silently treated as vector operations. Memory records
use separately reviewed form rules.

To reproduce the map, download the pinned `VecDecoder.scala`, then run:

```sh
python rules/extract.py /path/to/VecDecoder.scala > /tmp/opcodes.json
cmp rules/opcodes.json /tmp/opcodes.json
```

The extractor rejects a different input SHA. It does not fetch a branch head.
Source fingerprints used in the review:

| File | SHA-256 |
| --- | --- |
| Configs.scala | `52f1a7847cea7ccf759d863141700d3c5fa51986c555c5ec381d3e0a7c20bcb8` |
| Parameters.scala | `63781a89fa54333909045768aa6a8c5f20cf225c109751d46f7f050c0e1e4617` |
| VecDecoder.scala | `3eec0be04f5e3a375e57fea33b101a43d46184bcefbfec163b7942efdabf9aa6` |
| UopInfoGen.scala | `2d36d43ae188f63113cfe7498ec3261e26faac5f618f131dce686601ed3c25f4` |
| DecodeUnitComp.scala | `19e27757079fea650eaefdbae9ae0aab11fe88ed3a3cdbd6eeac294bcf7bafdf` |
| VSplit.scala | `417ccd9e62eceabf96e72592028e04d99569dd9cd61d9b7b2f02e00041cc44d6` |

## Split formulas

Let L be architectural LMUL and D=max(1,L) in the RTL's integer decode domain.
Fractional LMUL does not receive a fractional uop. Illegal LMUL/SEW combinations
at VLEN 128 and wide/segment register groups exceeding 8 are rejected.

| Split branch | Decode work | Distinct extra move work |
| --- | --- | --- |
| VEC_VVV, VVM, EXT2/4/8, VRED, M0X | D | 0 |
| VEC_VXV, VFV, VXM, VFM | D+1 | 1 I2V/F2V |
| VEC_0XV | 2 | 1 I2V/F2V |
| VEC_VVW, WVW, WVV | 2L for L≥1, otherwise 1 | 0 |
| VEC_VXW, WXW, WXV, VFW, WFW | previous wide work +1 | 1 I2V/F2V |
| VEC_VWW | 2D | 0 |
| VEC_SLIDE1UP / FSLIDE1UP | D+1 | 1 I2V/F2V |
| VEC_SLIDE1DOWN / FSLIDE1DOWN | 2D | 1 I2V/F2V |
| VEC_SLIDEUP / SLIDEDOWN | table(L)+1: 2,4,11,37 for L=1,2,4,8 | 1 I2V |
| VEC_RGATHER | D² | 0 |
| VEC_RGATHER_VX (includes VI) | D²+1 | 1 I2V |
| VEC_RGATHEREI16 | D²; doubled for SEW=8 and L≠8 | 0 |
| VEC_COMPRESS | 1,4,13,43 for D=1,2,4,8 | 0 |
| VEC_MVV | 2D−1 | 0 |
| VEC_MVNR | encoded register count 1/2/4/8 | 0 |
| VEC_VFRED | addTime + three-bit foldTime, minimum 1 | 0 |
| VEC_VFREDOSUM | max(1,128/SEW × L) | 0 |
| VEC_US_LDST | max(1,data EMUL) × fields +1 | 1 I2V |
| VEC_S_LDST | max(1,data EMUL) × fields +2 | 2 I2V |
| VEC_I_LDST | max(max(1,L) × fields, max(1,index EMUL)) +1 | 1 I2V |
| VEC_US_LDST, whole-register branch | register count +1 | 1 I2V |

Wide branches require L≤4. FP reduction SEW is 16/32/64. `VFRED` foldTime uses
`min(log2(L),0) - foldLastVlmul`, in the RTL's three-bit encoding; legal lane
geometry is checked first. Ordered reductions use the static VLMAX domain from
the pinned RTL, not an inferred runtime reduction length.

For non-indexed LLVM memory pseudos, the encoded LMUL represents **data EMUL**;
the ISA opcode supplies EEW and field count. The actual VTYPE LMUL/SEW can remain
unknown and is displayed as such. Indexed memory uses the pseudo-table data LMUL,
SEW operand, and independently observed index EMUL/EEW; their ISA ratio must agree.
Whole-register moves/transfers use encoded counts and physical-group verification.

## Execution-resource evidence and class choices

| RTL FU | Inherited execution units | Shared basic class |
| --- | --- | --- |
| vialuF | VFEX0, VFEX2 | integer |
| vimac | VFEX0 | multiply |
| vfma | VFEX0, VFEX2 | fp_multiply |
| vfalu | VFEX1, VFEX3 | fp_alu |
| vfcvt | VFEX1 | convert |
| vipu | VFEX1 | mask |
| vppu | VFEX0 | permute |
| vfdiv, vidiv | VFEX4 | divide |
| I2V | BJU2 | move |
| F2V | FEX0 | move |
| vector load/store | VLSU0, VLSU1 | memory |

Ports describe overlap **feasibility**, not throughput. Python constructs a pair
of distinct units before awarding ILP; class differences alone do not establish
that. Extra move and primary vector work remain distinct components even where
coefficients are shared. Sharing basic classes, the minimum/geometric pair work
and additive/union effects are explicit initial modeling choices, not RTL claims.

Ordinary scalar instructions anchor one decode effect; scalar execution overlap
is unknown. Scalar memory follows the ordinary memory work/class path. Scalar
pseudos with unverified expansion are rejected. Scalar register COPY and the
one-instruction branch/return pseudos have explicit support.

Unsupported forms are reported, not assigned an invented LMUL curve. Initially
these include indexed segments without an independently observed index geometry,
mask/fault-first memory, unrecognized pseudos/FUs and illegal/missing geometry.
Runtime memory aliasing, partial register effects, unknown VL and post-observation
scheduling remain visible coverage limitations. Unknown VL does not invalidate a
verified **static decode** formula; it does prevent claiming a runtime execution
chunk count. Unit tests check fractional/integer and exception/memory boundaries.
