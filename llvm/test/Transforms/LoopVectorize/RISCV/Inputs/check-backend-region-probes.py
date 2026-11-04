# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
"""Recover a fully unrolled body, but reject disjoint candidate regions."""
import json
from pathlib import Path
import subprocess
import sys

opt, source, temporary = sys.argv[1:]
root = Path(temporary)
root.mkdir(parents=True, exist_ok=True)


def run(enabled):
    tag = 'on' if enabled else 'off'
    feedback = root / (tag + '.jsonl')
    feedback.unlink(missing_ok=True)
    output = root / (tag + '.ll')
    subprocess.run([
        opt, source, '-S', '-o', str(output), '-passes=loop-vectorize',
        '-codegen-opt-level=3', '-mtriple=riscv64',
        '-mcpu=xiangshan-kunminghu', '-mattr=+v',
        '-force-vector-width=16', '-scalable-vectorization=off',
        '-force-vector-interleave=1', '-enable-epilogue-vectorization=false',
        '-vplan-backend', '-use-default-tti', '-use-estimated-spill=false',
        '-vplan-backend-force-all', '-verify-each', '-verify-machineinstrs',
        '-vplan-backend-region-probes=' + str(enabled).lower(),
        '-vplan-backend-jsonl=' + str(feedback),
    ], check=True, timeout=120)
    rows = [json.loads(line) for line in feedback.read_text().splitlines()]
    return output.read_text(), rows


off_ir, off = run(False)
on_ir, on = run(True)
assert off_ir == on_ir, 'probe markers changed the forced selected output'
assert 'llvm.pseudoprobe' not in on_ir, 'markers escaped the disposable clone'

assert any(row.get('function') == 'unrolled'
           and row.get('status') == 'estimated-fallback' for row in off)
assert not any(row.get('function') == 'unrolled'
               and row.get('status') == 'estimated-fallback' for row in on)

# Successful candidate reports retain the independently collected observation.
observations = [row['observation'] for row in on
                if row.get('function') == 'unrolled'
                and row.get('status') == 'collected']
assert len(observations) == 1, observations
spill = observations[0]['spill_observation']
assert spill['status'] == 'succeeded', spill
assert spill['scope'] == 'probe-region', spill
assert spill['region_granularity'] == 'machine-block', spill
assert spill['iteration_mapping'] and spill['iteration_width'] == 320, spill
assert spill['region_probe_count'] == 20, spill
assert spill['spills'], 'block-anchored observation must include real spills'
assert spill['stage'] == 'post-stack-slot-coloring', spill

failures = [row for row in on if row.get('function') == 'cloned'
            and row.get('status') == 'estimated-fallback']
assert len(failures) == 1, failures
assert 'region probes span multiple machine blocks' in failures[0]['reason'], failures

# Unlike @unrolled, this body has no backedge immediately after vectorization.
assert any(row.get('function') == 'single_iteration'
           and row.get('status') == 'estimated-fallback' for row in off)
assert not any(row.get('function') == 'single_iteration'
               and row.get('status') == 'estimated-fallback' for row in on)
single = [row['observation']['spill_observation'] for row in on
          if row.get('function') == 'single_iteration'
          and row.get('status') == 'collected']
assert len(single) == 1, single
assert single[0]['status'] == 'succeeded', single
assert single[0]['scope'] == 'probe-region', single
assert single[0]['iteration_mapping'], single
assert single[0]['iteration_width'] == 16, single
assert single[0]['region_probe_count'] == 1, single
