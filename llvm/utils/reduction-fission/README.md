# Reduction fission validation

`audit.py` uses LLVM `print<loops>` output, prunes constant branch edges, traces
vector accumulator SSA values to their horizontal collapses, checks inter-loop
CFG ordering, and checks the resulting RISC-V machine boundaries and pre-RA
vector uses. It does not use the benchmark suite's SCC transform verifier.

Run the dependency-free CFG negative tests with:

```sh
python3 llvm/utils/reduction-fission/audit.py --self-test build-fission/bin/opt
```

A full campaign audit accepts the output directory of the recorded campaign
runner. Machine parsing and optimization-record decoding currently use pinned
helpers from the sibling `code-lab/microbench/tools` tree:

```sh
python3 llvm/utils/reduction-fission/audit.py /path/to/campaign
```

Conditional scalar special-value restoration can make a machine horizontal
collapse conditional when its value is unused (for example an initial NaN).
The audit records that separately. Numeric collapses must precede subsequent
reducers; dead vector data must not be carried into them.

`rvv/` contains the executable scalar-reference versus transformed-code checks.
The kernel objects use the recorded XiangShan backend profile and machine
verification on both sides of the known VL-optimizer skip. QEMU execution uses
VLEN 128, 256 and 512. These are correctness checks, not RTL performance results.

## Reproduce the source campaign

The default artifact root is `build-fission/experiments/reduction-fission-goal`;
set `FISSION_ARTIFACT_ROOT` to use another directory. The sibling suite supplies
its manifest, source fixtures, exact recorded compiler flags and target helpers.
Copy the target headers from its pinned builder image into `headers/picolibc`
and `headers/builder` under the artifact root. `source-campaign.py` reruns all
345 discovery inputs and builds the union of original attempts and newly
discovered candidates. It never publishes into the sibling suite.

```sh
export FISSION_ARTIFACT_ROOT="$PWD/build-fission/experiments/reduction-fission-goal"
python3 llvm/utils/reduction-fission/source-campaign.py full-source-final
python3 llvm/utils/reduction-fission/audit.py "$FISSION_ARTIFACT_ROOT/full-source-final"
python3 llvm/utils/reduction-fission/after-ra.py "$FISSION_ARTIFACT_ROOT/full-source-final"
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
  python3 llvm/utils/reduction-fission/build-controls.py
python3 llvm/utils/reduction-fission/compare-controls.py full-source-final
```

Control compilers use an isolated source/header overlay and copied static
archive; live source and build objects are not replaced. `baseline` restores the
three modified translation units and their headers from the tested baseline
commit `000d853e209a8ab64b7b10dbc1333cfb46f9e501`.
`preservation-only` adds just the VPlan loop-boundary preservation change.
Commands, source/header hashes and executable hashes accompany each build.

## Reproduce RVV execution

Generate into a separate absolute output directory. The test driver derives
scalar references directly from the same LLVM fixtures and renames their
symbols, so both versions can be linked into one executable.

```sh
python3 llvm/utils/reduction-fission/rvv/build.py /absolute/output/rvv
# Create this disposable container once; reuse it for subsequent checks.
docker run -d --name reduction-fission-rvv --platform linux/amd64 \
  -v /absolute/output/rvv:/work ubuntu:24.04 sleep infinity
docker exec reduction-fission-rvv sh -c \
  'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends qemu-user gcc-riscv64-linux-gnu libc6-dev-riscv64-cross'
python3 llvm/utils/reduction-fission/rvv/run.py /absolute/output/rvv
```

The harness includes protected-page inputs, allocation canaries, ownership
checks, and bit-exact skipped-path initializer checks. Its finite arithmetic
uses exact dyadic inputs; it does not assert a particular reassociation rounding
order on arbitrary non-exact FP inputs. The prescribed backend workaround is
applied to code generation, while QEMU executes the raw ISA extraction sequence.
The campaign separately retains both raw and XiangShan-patched assembly.
