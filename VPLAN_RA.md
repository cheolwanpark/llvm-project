# Compiler observation and replay contract

The compiler implements **protocol 4**. The local Python cost model owns all
hardware rules and score calculations. C++ observes MIR, exposes middle-end TTI
costs and materializes explicitly selected VPlans. There is no backend scoring
formula or coefficient table in LLVM. Python uses one shared port-demand model with a hardcoded machine datasheet.

`-vplan-pipeline=prepare` stops O2/O3 immediately before loop vectorization and
marks a checkpoint. `resume` validates that checkpoint and optimization level.
The driver recursively extracts `selected_kernel` and its callees while preserving
constant initializers. Preparation and checksum functions are excluded.

A discovery invocation with `-vplan-candidates-output=FILE` and a run digest
records original loop identity, deterministic candidate IDs, VF, estimated width,
scalar-tail policy, exact and upper-bound trip counts, scalar iteration TTI cost,
and configuration TTI unit/source/scope. Candidates remain discoverable even when
middle-end costs are unavailable. The manifest does not carry old register-pressure
or spill-price breakdowns.

`-vplan-probe-candidate=ID` requests a materialized vector candidate, IC=1 and no
separate vector epilogue. The driver checks regenerated candidates and actual
probe selection. `-vplan-analytics-output=FILE -stop-after=riscv-vplan-analytics`
saves passive **post-frame-lowering** facts and a complete MIR artifact. The observer
runs after frame-index elimination, generic copy expansion and RISC-V post-RA
expansion/load-store optimization, before the second scheduler. Segment spills
and stack-address calculations are therefore ordinary observed instructions.
Later scheduling and final RVV pseudo expansion remain outside this stage.

`mir-local-observation-v2` records:

- Run, candidate, function, compiler version, target triple/CPU/features and VLEN.
- Verified original scalar iteration width, VF scalability and trip-count context.
- Block successors and body/setup/exit/tail-or-other-loop membership, plus ordered
  body instruction IDs. Exit instructions following a taken backedge stay outside
  the circular order. Only innermost single-block loops are scoreable initially.
- MIR text, exact base/pseudo opcode correspondence, configuration/meta flags,
  encoded LMUL, SEW, proven active VL and signed byte stride (null when unknown),
  and load/store flags. VL is recovered from configuration definitions, not the
  removed pseudo AVL operand. Physical reaching definitions and dominance prove
  scalar constants; a small backward CSR lookup handles VL across blocks.
  Memory pseudo LMUL is data EMUL; physical group size is separately preserved.
- Every original operand position, including non-registers; physical register
  units, def/use, implicit, tied, undef, dead/kill, subregister and clobber facts.
- Memory direction, size/scalability, offset, alignment, underlying IR operand,
  fixed stack-slot identity, spill-slot metadata, volatility/atomicity and alias
  metadata availability. Missing memory facts remain unknown.
- Register-unit reaching definitions at distances zero and one, including carried
  values. These are diagnostic facts; the scorer does not model scheduling.
  Missing liveness, calls, subregisters and regmasks disable constant proofs.
  Unknown VL/masks/addresses receive explicit upper bounds in Python.

The observer returns `false`, preserves all analyses and performs no MIR rewrite.
Analysis-enabled assembly is checked against ordinary assembly. Multi-block layout
order never supplies a supported circular path. Raw dependencies do not claim
complete memory independence. Python does not perform alias analysis.

For final compilation the driver writes `-vplan-selection-input=FILE`, containing
protocol/run identity, the complete original loop/candidate context and one explicit
choice per loop. LLVM validates that context, consumes every choice, and checks
emission, IC and epilogue settings. The driver checks the **final manifest** against
the selected candidates and requires a nonempty final artifact. Scalar fallback
is explicit when no scalable candidate is supported.

```sh
utils/vplan-meta-compile --clang build-local/bin/clang \
  --input kernel.c --work-dir /tmp/local-compile --output /tmp/kernel.o \
  --extract-function selected_kernel -- \
  --target=riscv64-unknown-elf -march=rv64gcv -mcpu=xiangshan-kunminghu \
  -mrvv-vector-bits=128 -O3 -fno-unroll-loops -fno-slp-vectorize \
  -mllvm -scalable-vectorization=always -mllvm -force-vector-interleave=1 \
  -mllvm -enable-epilogue-vectorization=false
```

`--analytics-only --stop-after-ra` collects facts without scoring.
`--emit obj|asm|llvm` selects the final artifact. Driver inputs and scoring/replay
need no database or measured cycles. See the [tools guide](utils/vplan-tools/README.md)
for port-demand analysis, selection intervals and regret evaluation.
