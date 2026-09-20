# Reduction fission — completed implementation and audit

Full objective: `GOAL-reduction-fission.md`. The final report is
`REPORT-reduction-fission.md`; it contains the requirement matrix, representative
before/after table, exact scope and remaining environmental limitations.

## Authoritative evidence

- `build-fission/experiments/reduction-fission-goal/full-source-final/`: 345 C
  discovery contexts, 1,463 variant requests. 325 committed Fission variants over
  72 contexts pass final IR/CFG, machine-boundary and virtual-liveness audits.
  All 420 data reducers use LMUL8 and IC1. Four NPB checksum Fission requests are
  explicitly rejected; four Normal requests remain scalar, matching baseline.
- All 1,134 Normal final IR outputs are byte-identical to isolated baseline builds
  (`control-comparisons-full-source-final/normal.json`).
- SGEMM8 baseline/preservation-only/integrated: reducer loops 0/8/8, buffers
  16/16/8, vector spill/reloads 54/0/0; raw instruction statements 515/304/235.
- `full-source-final/summary.csv` and per-variant records retain all cases, source
  identities, commands, remarks, before/after/final IR, raw/patched assembly,
  object files and machine-verified MIR before VL optimization and after RA.
- `completion/audit.json` verifies current binary hashes against campaign and
  numerical evidence, all component widths/IC, loop/collapse/ownership invariants,
  and no early reducer vector loads.
- `rvv/results.json`: 51,231 scalar-reference/transformed comparisons passed on
  QEMU RVV 8.2.2 at VLEN128/256/512, including guarded allocation/input bounds,
  exact skipped-path NaN bits, signed zero, IEEE subnormals, integer overflow,
  signed/unsigned widening, shared reducers and trip-count boundaries.
- `completion/lit.log`: 116/116 regression tests passed.
- Source/binaries synchronized (`ninja`: no work); `git diff --check` passes.

## Deliverables and limits

Implementation changes are confined to the Vectorizer; tests/docs/tools are
included. `llvm/utils/reduction-fission/` provides reproduction and audit tools.
`completion/implementation.patch` includes tracked changes plus new tests/tools.
No published sibling artifacts or measured
cycles were replaced. The sibling SCC verifier remains unchanged and its
limitations are documented. No RTL/hardware speedup is claimed.

The temporary RVV container is stopped, not deleted; use
`docker start reduction-fission-rvv` to reuse it. Artifacts stay on the host.
All compilation/test sessions have completed. Previous turns were progress;
there is no blocker or pending external job.
