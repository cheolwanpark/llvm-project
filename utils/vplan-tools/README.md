# MIR port-demand research tools

The default model is `mir-port-aware-v1`: a traceable Kunminghu v2 MinimalConfig
baseline, not a fitted cycle predictor. It consumes protocol-4
`mir-local-observation-v2` observations at `post-frame-lowering`, VLEN=128.

## Model

`hardware_model.py` defines reusable frozen dataclasses for ports, uop classes,
instruction expansion rules, arithmetic expressions and evidence.
`kunminghu_v2.py` is the single target datasheet: opcode records, split expressions,
geometry conventions, class-to-EXU mappings, capacities, source hashes and assumptions.
There are no runtime hardware downloads or fitted class weights.

For each body, instruction expansion produces class counts `u[c]`. A class with
several possible ports contributes equally to each, regardless of existing load:

```text
d[p] = sum(u[c] / len(possible_ports[c]) for c executable on p)
x[p] = d[p] / capacity[p]
body_cost = aggregate(x)
score = body_scale * body_iterations * body_cost + existing_additions
```

Ports are RTL execution units (e.g. VFEX0), so different functional units within
one EXU share demand. Scalar stores produce separate required address/data issue
tasks; these are not alternative ports. Decode counts and issued demand counts
are reported separately. Vector segment memory uses VLSU0. Scalar/vector memory,
spill/reload and their I2V transfers are included as uop work. The old memory
request R term and class weights have been removed.

All capacities currently default explicitly to **1 uop/cycle**. An EXU input's
peak acceptance width does not establish a sustainable rate for all its FUs.
FU latency is not converted to throughput. Unreviewed opcode/class mappings use
one UNKNOWN demand unless a reviewed split provides the count. Invalid known
geometry and invalid observations are errors, not fallbacks. Reports identify
all capacity assumptions and each instruction fallback. Vector COPY uses a
whole-register-move approximation and reports that assumption if encountered.

The default is `max`, body scale 1. The only alternative is `sum`.
Both use the fixed port set, including UNKNOWN; zero-demand ports contribute zero.
All-zero inputs return zero. Both functions are positively homogeneous.
These functions do not model dependency chains, dynamic issue balancing,
nonpipelined FU occupancy, cache behavior, replay or shared writeback contention.

Iteration/configuration/scalar-tail accounting is unchanged: exact scalar-tail
loops use floor(T/W) bodies and T%W scalar iterations; folded tails use ceil(T/W).
Unknown exact counts use body/W, configuration/W, no guessed scalar remainder or
setup amortization. Configuration units come from the middle-end TTI query;
scalar tail costs come from CM.expectedCost(f1). Neither is tunable in the new
boundary analysis. Body-outside setup/final-reduction instructions remain excluded.

## Commands

From this directory, `uv sync --locked` installs the Python 3.12 environment.
Compiler tools build automatically; `--build-dir ../../build-local --skip-build`
reuses this checkout's build. The DB is opened read-only, with precedence
`--db PATH` > nonempty `VPLAN_DB` > checkout `search-dataset.sqlite`.

```sh
uv run python collect --output /tmp/population.json
uv run python evaluate --output-dir /tmp/port-max
uv run python print-vplans --benchmark hpcc/stream-add --artifacts-dir /tmp/one --replay
uv run python score-mir --bundle .cache/local-observations/KEY/bundle.json --output /tmp/scores.json

# Explicit settings are forwarded through reporting, selection and replay.
uv run python evaluate --aggregation sum --body-scale 3/2 --output-dir /tmp/port-sum-scaled

# No recompilation/DB access; preserve the source evaluation's cohort and measurements.
uv run python rescore-evaluation --evaluation /tmp/port-max --aggregation sum --output-dir /tmp/port-sum
uv run python analyze-boundaries --evaluation /tmp/port-sum --term body_scale --output-dir /tmp/port-sum-boundaries
```

Every report contains class counts, instruction contributions, raw and normalized
port demand, bottleneck ports, body cost and fixed additions. Nonlinear aggregate
costs are not presented as sums of per-instruction costs. Scores use exact affine
arithmetic on persisted numeric features, with smaller VF then candidate ID as
the tie-break. Body features are stored as floating-point values.
Model identity includes datasheet/implementation digests and aggregation settings.

`evaluate` uses stored measured cycles only after selection. It reports mean,
median, p95, worst regret, exact top-1 accuracy, rank metrics and exclusions.
Regret is cycles(selected)/min(cycles(eligible VFs))-1. All discovered candidates
must have supported observations and all discovered VFs must have measurements;
failed alternatives cannot silently improve the population. Comparison with LLVM
uses matching benchmark **and VF** populations. Every eligible default selection
is replayed unless `--ranking-only` is specified. Rescored alternatives explicitly
report ranking-only status.

Raw caches validate compiler/driver/collector identity and MIR/raw JSON checksums.
Old observation stages require recollection. Aggregation changes need only
rescoring. Full raw MIR and replay artifacts remain outside committed summaries.

## Selection interval analysis

For a fixed datasheet and aggregation, each candidate is an affine
line in body scale b>=0: `S(b)=b*body_feature+fixed_additions`. `analyze-boundaries`
intersects exact rational inequalities, retaining endpoint ties and isolated
points. This is exact for the saved numeric features.

The reference is each aggregation's saved selection (normally b=1). Outputs
include unchanged-VF intervals, all changes, interval widths, regret distributions,
and every benchmark's contribution to mean regret. The diagnostic tolerance is
**per benchmark** `regret(new) <= regret(reference)+0.15`, not a mean-regret cutoff.
Both its full intersection and individual violations are reported. No fraction
of cases is designated an acceptance threshold. Broad intervals only describe
body-vs-fixed-additions stability; they do not validate port-mapping flexibility.

## Tests and evidence

```sh
uv run python -B -m unittest discover -s tests -v
VPLAN_CLANG="$PWD/../../build-local/bin/clang" uv run python -B -m unittest discover -s tests -v
python rules/extract.py /path/to/flat-pinned-rtl-files
```

See [rules/README.md](rules/README.md) for the pinned sources. Historical result
folders describe older models and are not comparisons for this branch.
The [port-aware baseline results](results/port-aware-v1/README.md) include the
189-benchmark evaluation, exact intervals and rescorable artifacts.
