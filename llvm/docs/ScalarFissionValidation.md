# Scalar fission validation — 2026-10-19

A subsequent [ten-target audit](ScalarFissionTargetAudit.md) found redundant
scratch streams and excess stack allocation despite passing semantic checks.
The validation below does not establish absence of unnecessary overhead.

The independent scalar fission implementation replaces the VPlan fission path.
Validation used the final, uncommitted implementation on base revision
`6dd07ebb9f134f8c0fe647d91a7086ce4b2f71c8`. Compiler sources were frozen before
these runs. [The machine-readable report](ScalarFissionValidation.json) records
the changed compiler source hashes, deleted files, compiler binary hashes,
runner hashes, artifact hashes and every corpus target's result. Its compiler
source digest is
`85949c4d9032fc4ffa87c3686453f69db5fff023d63d1ed3862304cfeef03e61`.

The Release build has assertions enabled and RISCV, AArch64 and X86 targets.
`clang`, `opt`, `llc` and `VectorizeTests` were rebuilt; a final Ninja dry run
reported no work. The execution checker, sweeps and corpus runner used the same
`opt` binary, and their recorded hashes were checked against the final binaries.
These results do not inherit passes from historical validation.

## Correctness and regression results

| Check | Result |
| --- | --- |
| Complete LoopVectorize directory, ScalarFission directory, active legacy checker tests | 1,359 passed; 101 unsupported; zero failures |
| Remaining Vectorize unit tests | 66 passed |
| Original/transformed host execution and independent oracles | 26,316 comparisons passed |
| Frozen-IR fixed VF sweep execution | 468 additional comparisons passed across nine pairs |
| Frozen-IR RVV sweep | 16 pairs available and machine-verified; not executed |
| Deliberately excessive scalable VF | `s1024/s1` unavailable; compiler and codegen succeeded |
| Pinned corpus | 117 sources, 585 optimization/codegen configurations; zero failures |
| Python syntax and patch whitespace | Passed |

After final obsolete-file cleanup, the remaining LoopVectorize and ScalarFission
tests were rerun: **1,352 passed, 101 unsupported, zero failures**. The seven-test
decrease is removal of tests for the retired checker APIs. The semantic execution
checker was rerun and passed all **26,316 comparisons**. The compatibility command's
help matches the new checker, Python syntax and whitespace checks pass, and Ninja
reports no compiler work. Cleanup results and artifact hashes are recorded in
the JSON's `final_cleanup` field; compiler binaries are unchanged.

The host checker uses capacities 1, 3 and 64 and both FP policies. It covers
zero/partial/multiple chunks, dynamic and data-dependent termination, distinct
consumer conditions, producer state and live-outs, retained nested loops,
read-only and memory-effect helpers, equal/shifted/disjoint aliases, seeds,
integer arithmetic and extrema, signed zero and nonfinite FP inputs. It checks
coupled state, compensated FP updates and state-dependent FMA. Original and
transformed functions are compiled by the same final `llc`; separate Python
oracles check the expected results and observable memory. Ordinary host LV is
also exercised, with an explicit numerical tolerance when FP reassociation is
allowed. No blanket bit-identity claim is made for reassociated FP.

The nested-loop execution fixture combines retained inner loops, an opaque
memory-effect helper and an outer runtime count without a static bound. Its
helper effects make call count and order observable. Negative fixtures cover
unsupported call effects, lifetime operations, raw input relay through casts,
select/PHI/freeze and identities, and unsafe aliases. Positive fixtures exercise
stable direct reads, computed-boundary fallback, shared computations with private
suffixes and reuse of a proven existing result buffer. Analysis verifiers and
repeated fission/LV runs check CFG, analysis invalidation and stage provenance.

All 87 surviving legacy IR fixtures retain their original non-comment,
nonblank instruction text. Their RUN lines now check the standalone scalar
pass, repeated-pass verification and RVV machine verification. The old split-file
bounds fixture's four modules have active tests. Final cleanup removed the
duplicate split-file input, seven obsolete wrapper tests, 23 archived structural
checker tests, seven remaining tests of historical checker APIs and their unused
inputs. Inactive historical commands and FileCheck directives were removed from
the 87 fixtures; their original versions remain in Git history. The old 9,853-line
Python checker is now a command-line compatibility wrapper, and its 4,844-line C
harness is removed. VPlan-only unit tests were removed with the structures they
tested. The [migration inventory](../test/Transforms/ScalarFission/Inputs/legacy-migration.json)
records fixture classifications, selected functions and current rejection
diagnostics, including intentional memory-policy changes. Old success counts are
not treated as evidence that a forbidden input snapshot should remain legal.

## Placement and pinned corpus

The corpus manifest SHA-256 is
`b60b4ce8c4f3f69b6dcd56e5cb0a8c2f2bfddaf30c5d0682c6f2213f4f1a2c3d`.
Each source's pinned hash was checked. The runner compiled each source once to
raw frontend IR, then independently ran ordinary O3/LV, Early with each FP policy,
and Late with each FP policy. Early was never followed by Late. Target attribution
uses function and source location; helper and inner-loop remarks remain separate.
Full pass-manager logs, remarks, commands, generated IR and assembly are saved.

| Pipeline | Selected | Rejected | No fission decision | Sum of optimizer wall seconds | Maximum optimizer RSS, bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| Ordinary LV baseline | 0 | 0 | 117 | 195.77 | 56,147,968 |
| Early, ordered | 7 | 110 | 0 | 203.13 | 56,279,040 |
| Early, reassociation enabled | 7 | 110 | 0 | 220.06 | 56,197,120 |
| Late, ordered | 10 | 107 | 0 | 193.51 | 56,229,888 |
| Late, reassociation enabled | 10 | 107 | 0 | 194.27 | 56,295,424 |

These are one-run process measurements with four corpus jobs in parallel and
pass logging enabled. They provide a compile-resource baseline, not a statistically
significant speed comparison. Historical compiler resource measurements were not
rerun; historical coverage is compared using the preserved validation record.

Late remains the default: it passes the semantic and memory-policy tests, all
corpus configurations verify and generate code, it retains the seven historical
target successes and adds three, and Early shows no resource or coverage advantage
in this run. This is a conservative placement decision, not a runtime profitability
claim. Branch/PHI versus select, InstCombine and header-tested loop normalization
have permanent regression tests. The actual pass-order test confirms Late follows
full unrolling and precedes LV, while Early precedes full unrolling.

The seven retained targets are the two DUCC `map2alm` ring pairs, dlib numerical
LM, the two Nek5000 `drgtrq` targets, and the two PySCF VV10 Hessian targets. The
three additions are Vina `non-cache-deriv` and the two SHTools paired-degree
gradient/gravity targets. Exact IDs are in the JSON report.

Required real-source areas were inspected with these outcomes:

| Area and real candidate | Outcome and remaining limitation |
| --- | --- |
| Runtime counts and producer recurrences: DUCC ring pairs, SHTools paired degrees | Late selected; original runtime continuation and producer state remain supported without a trip-count ceiling |
| Helper-heavy producer code: Vina and dlib | Late selected; source helper presence alone is not evidence of an opaque call surviving inlining. Retained opaque calls are separately execution-tested |
| Nested source computations: Nek5000 face/row, PySCF six-trial grid | Selected Late, rejected Early as `no-closed-state`; preprocessing and unrolling can expose the boundary, so these successes alone do not prove retained-inner-loop support |
| WRF `t000147-wrf-qr-acr-qs-nested` | Both placements reject `no-closed-state`; arbitrary state feedback remains unsupported |
| APBS `t000153-ibforce-npbe-traversal` | Both reject `unsupported-iteration-boundary`; arbitrary traversal exits remain unsupported |
| XSBench `t000003-xsbench-nuclide-fuel` | Late rejects `forbidden-load-relay`; coverage is not recovered by snapshotting input loads |

Late ordered target rejection remarks comprise 58 unsafe-call, 26 no-closed-state,
24 unsupported-iteration-boundary, three unsupported-control, two
unsupported-nested-exit and one forbidden-relay records. These are remark counts,
not unique-target counts: normalized/cloned loops can emit multiple records at a
target location. Conservative whole-object alias proofs and explicit call effect
contracts intentionally leave many targets unsupported. The corpus checks compile
and codegen validity; it does not execute all 117 real workloads.

## Independent vectorization and measurement limits

One frozen `vector-pair.ll` fission result was used for all sweeps; the harness
asserts that only metadata changes. Its SHA-256 is
`47eab981fc88d067bf3fc4d01f8875d388e39c796fb4f026ea64e2d0c91a3bdb`.
FP policy, chunk layout and instruction stream are fixed. Host pairs use
`{1, f2, f4}` on each axis, including scalar/scalar, both mixed directions and
different vector widths. RVV pairs use `{1, s1, s2, s4}` with the same `riscv64,+v`
target settings throughout; `s1` is scalable, not scalar. IC is one. Requested
and actual VF/IC are recorded separately. The impossible request is classified
unavailable after normal LV's fallback rather than counted as forced success.

Corpus codegen uses Xiangshan Kunminghu, RVV vector bits 128 and the pinned
RISC-V sysroot. The separate RVV sweep uses the generic scalable target without
a fixed runtime VLEN. RVV outputs were machine-verified but were not executed on
RVV hardware or an emulator. Runtime performance is **unmeasured**. The sweep
tool's optional external command records benchmark output and wall time when a
target runner is supplied; none was supplied for this report.

Traffic remarks distinguish original access widths, additional original reads,
scratch reads/writes, footprint and reused buffers. These are static instruction
widths and conservative extra-read bounds; conditional/nested multiplicities and
call-internal traffic are not inferred. They are not cache-traffic measurements.

## Reproduction and artifacts

The build and basic commands are in [README](../../README.md). Full local
artifacts are under
`build-fission/scalar-fission-validation/release-validation/`, including `logs`,
`execution/execution.json`, `corpus/result.json`, `sweep-host/result.json`,
`sweep-rvv/result.json`, `sweep-execution/sweep-execution.json` and
`unavailable-vf/result.json`. The versioned JSON preserves the summary, hashes
and per-target outcomes independently of that build directory.

```sh
build-fission/bin/llvm-lit -sv llvm/test/Transforms/LoopVectorize \
  llvm/test/Transforms/ScalarFission
build-fission/unittests/Transforms/Vectorize/VectorizeTests
python3 llvm/utils/check-scalar-fission.py --build-dir build-fission \
  --work-dir build-fission/scalar-fission-validation/release-validation/execution

# Use a Python environment containing PyYAML for the two experiment runners.
python3 llvm/utils/evaluate-scalar-fission.py --build-dir build-fission \
  --corpus /Users/cheolwanpark/Research/search-fission-benchmarks \
  --sysroot /Users/cheolwanpark/Projects/loop-benchmarks/.deps/xpack-riscv-none-elf-15.2.0-1/riscv-none-elf \
  --output build-fission/scalar-fission-validation/release-validation/corpus

build-fission/bin/opt -passes=scalar-fission -S \
  llvm/test/Transforms/ScalarFission/vector-pair.ll -o frozen.ll
python3 llvm/utils/scalar-fission-sweep.py frozen.ll --build-dir build-fission \
  --output sweep-host --producer 1 f2 f4 --consumer 1 f2 f4
python3 llvm/utils/check-scalar-fission.py --build-dir build-fission \
  --sweep-dir sweep-host --work-dir sweep-execution
python3 llvm/utils/scalar-fission-sweep.py frozen.ll --build-dir build-fission \
  --output sweep-rvv --producer 1 s1 s2 s4 --consumer 1 s1 s2 s4 \
  --target-arg=-mtriple=riscv64 --target-arg=-mattr=+v \
  --llc-arg=-mtriple=riscv64 --llc-arg=-mattr=+v
```

The external corpus's source files, historical results and old harness were left
untouched. The new versioned corpus runner understands both old and new remark
names and is the runner used for this comparison.
