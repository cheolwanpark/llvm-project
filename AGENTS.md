# Working in this LLVM fork

## Scope and source of truth

This fork adds in-process VPlan VF selection. Preserve upstream LLVM options and
behavior. README owns usage/build/test commands; BACKEND_FEEDBACK.md owns module,
probe, selection, fallback and reporting contracts. costsheet/rule.md owns units
and conversion; costsheet/generic_mirinfo.md owns current MIR instruction prices,
revisions and assumptions. Target sheets retain historical tuning evidence.
Update these documents instead of adding overlapping reports. Keep historical
measurements distinct from the current compiler and describe artifact availability
accurately.

## Tests and builds

- Follow existing conventions and test observable behavior. Keep tests minimal;
  avoid redundant coverage, unnecessary mocks and implementation snapshots.
- Never add or modify tests without prior approval. Explain proposed checks and
  wait for explicit permission unless that scope is already approved.
- Run the smallest relevant existing checks. Do not run the full suite unless
  explicitly requested, or repeat passed checks without a change/failure reason.
- Reuse `.cache/build`, its Release/assertions/tests-enabled configuration
  (`clang;lld`, `X86;RISCV`) and `cmake --build .cache/build --target <affected>
  --parallel 2`. Current tools are under `.cache/build/bin`.
- Preserve `.cache/compiler-build -> build`. Existing cache reconfiguration uses
  that alias; configure `.cache/build` directly only for a fresh cache.
- Build affected tools/test targets before checking. Available verification targets
  include clang, clang-resource-headers, llc, opt, FileCheck, split-file, not,
  count, llvm-readobj, VectorizeTests, RISCVTests and IRTests. Use focused gtest
  filters and individual lit entry points. Include
  `PassManager.*:LegacyPassManager.*` only for relevant pass-manager changes.
- Opt-only probes distinguish feedback from final object codegen. For relevant
  allocation changes include `llvm/test/CodeGen/RISCV/rvv/stack-slot-coloring.mir`.

## Backend invariants

Keep MIRInfo/Pricing, Probing and Gate/Pruning responsibilities separate. LV
coordinates whole-loop attempts and adopts/discards their costs, selections and
provisional reports together. Preserve the Vectorize→analysis callback→Passes→
TargetMachine dependency direction.

All executed probes use one post-frame-lowering observer and the same full CFG.
Collect scalar/vector spill-slot facts and optional MIR body facts with independent
slot statuses, scope and widths. Failure, not collected, not requested and
successfully observed zero are distinct. Preserve body exclusions.

Preserve master/CPU/exact-VLEN selection and native IC/probe/final-codegen policy.
The four compositions are `L`, `L-Et+Ot`, `R-S+Et`, `R-S+Ot`. Observed spills use
the configured aggregate TTI hook with homogeneous class/direction/physical-group
units; scalar g=1. Pressure-gate skipping is disabled; preserve bound analysis.
Use `L-Et` pruning and exact rational scalar/body/tail costs.

All supported RISC-V settings use Generic MIRInfo and native RISCVTTIImpl,
retaining actual ISA, VLEN, DLEN and native tuning. CPU-specific CostSheet and
TTI overrides and the use-default-tti option are removed. Four comparisons remain:
LLVM baseline, LLVM with observed total spill, MIR with native estimated spill,
and MIR with observed spill. Former target tuning is retained under costsheet/.
TTI observed adds original-loop observed spill to its configured scalar IR cost.
MIR and TTI observed share one original-loop VF1/IC1 probe per attempt. MIR uses
the corresponding spill substitution for scalar and vector bodies. Preserve exact
scalar rational ranking and tails.

Follow [whole-loop fallback](BACKEND_FEEDBACK.md#probe와-fallback), retaining the
requested TTI/spill policy and independently valid observations. Raw reuse
requires candidate, geometry and materialization context matches, including CFG,
mapping and normalization policy. Recompute pruning per model. Never turn failure
into zero spill, add post-frame retries or introduce benchmark-specific exceptions.
Reports are passive; native fallback discards attempted backend cost reports.

## Experiments and protected data

Preserve compiler caches, `.cache/post-frame-reference` when present and other
retained experiments. Put new outputs in a distinct `.cache/` directory. Never
commit build products, databases or measurements, or force-add ignored caches.
The reference directory is currently absent; do not claim verification or
reconstruct an old baseline by running the current compiler.

When reference data is available, read its top-level README and use the portable
manifest and `reference.py`; nested historical scripts/absolute paths are
provenance only. Verification command:

```sh
python3 -B .cache/post-frame-reference/reference.py verify
```

Use stored post-frame results, not a rerun baseline compiler.
Match source bytes, language, effective flags, candidate identity,
VF, IC, role, width and preceding-loop context. Separate timing and observation
compiler identities. Compare executable/allocated sections and normalized
relocations when debug paths or compiler strings differ.

Full requested dataset measurements run in a subagent; the main agent independently
checks raw counts, successes and averages. Full TSVC coverage/accuracy evaluations
use the same delegated execution and independent audit. Execute one compiler at
a time, alternate OFF/ON for three repetitions, use blocking waits and a
300-second command timeout. Preserve IC1, disabled vector epilogues, LMUL8 and
the default gate for reference comparisons. Distinguish force-all diagnostics
from ordinary selection and report scalar/vector/configuration/loop denominators
separately. Keep diagnostics separate from ordinary timings; exclude setup,
building and hashing from timers. Historical timing ratios are not simultaneous
controlled speedups. Do not rerun full datasets for documentation edits.
