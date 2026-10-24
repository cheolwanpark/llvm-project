# Kunminghu v2 evidence

The machine datasheet is [kunminghu_v2.py](../kunminghu_v2.py). Its frozen records
refer to XiangShan revision `e7bab53e66dfb3c4a1d11cf9519b0396f8576cae`,
MinimalConfig, VLEN 128, ELEN 64. All target-specific values live in that one file.

Evidence responsibilities:

- `Configs.scala`: MinimalConfig limits; it inherits EXU membership.
- `Parameters.scala`: EXU names and functional-unit memberships.
- `VecDecoder.scala` and `DecodeUnit.scala`: vector and scalar opcode/FU mapping.
- `UopInfoGen.scala`: LMUL/SEW-dependent decode uop counts, including nonlinear
  slide/gather/compress and reductions.
- `DecodeUnitComp.scala`: I2V/F2V versus primary vector components, and temporary
  register consumers. Decode counts are not latency predictions.
- `NewDispatch.scala` and `Scheduler.scala`: segment memory is restricted to
  VLSU0; scalar store address and data are separate required issue tasks.
- `ExeUnit.scala`: execution interface context. A one-input interface is only a
  peak admission limit; all sustainable capacities remain explicit defaults of 1.

`SOURCE_HASHES` records the locally verified files. To independently check the
literal opcode records, place those exact files in one directory and run:

```sh
python rules/extract.py /path/to/flat-rtl-directory
```

The verifier rejects changed source hashes and checks scalar and vector literals
against the single datasheet. It does not fetch sources or generate a second
runtime mapping. Expansion formulas have independent representative tests.

Missing class/port mappings use UNKNOWN; missing count uses one. These assumptions
are visible at instruction level. Illegal known geometry remains an error.
Additional limitations include instruction-level COPY materialization assumptions,
unmodeled zero-register/move elimination, dynamic FU service rates, shared
writeback, issue competition and dependency scheduling. Scalarized and spill
instructions use their observed opcode mappings without another penalty.
