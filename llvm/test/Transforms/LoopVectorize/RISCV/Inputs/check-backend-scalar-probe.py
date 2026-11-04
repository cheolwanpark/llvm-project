# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
"""Scalar MIR probe identity, native suffix, and context."""
import json
from fractions import Fraction as Q
from pathlib import Path
import subprocess
import sys

opt, source, prefix = sys.argv[1:]
base = [opt, '-codegen-opt-level=2', '-mtriple=riscv64',
        '-mcpu=xiangshan-kunminghu', '-mattr=+v',
        '-scalable-vectorization=always', '-force-vector-interleave=4',
        '-riscv-v-register-bit-width-lmul=8', '-enable-epilogue-vectorization=false',
        '-passes=loop-vectorize', '-verify-each', '-verify-machineinstrs']


def run(name, extra=(), src=source):
    report = Path(prefix + '.' + name + '.jsonl')
    report.unlink(missing_ok=True)
    p = subprocess.run(base + ['-vplan-backend-jsonl=' + str(report)] + list(extra)
                       + [str(src), '-S', '-o', '-'], capture_output=True,
                       text=True, timeout=120)
    assert p.returncode == 0, (extra, p.stderr)
    rows = [json.loads(line) for line in report.read_text().splitlines()] if report.exists() else []
    return p.stdout, rows, p.stderr


def exact(row, key):
    return Q(row[key + '_quarters_numerator'], row[key + '_quarters_denominator'])


def scalar(rows):
    assert not any('fallback' in r['status'] for r in rows), rows
    scalars = [r for r in rows if r.get('role') == 'scalar-baseline']
    assert len(scalars) == 1, rows
    r = scalars[0]
    assert r['candidate'].endswith(':scalar-baseline')
    assert r['vf'] == r['ic'] == r['tti_width'] == 1 and not r['scalable']
    assert r['status'] == 'collected'
    o = r['observation']
    assert o['observation_role'] == 'scalar-baseline'
    assert o['vf'] == o['ic'] == 1 and not o['scalable']
    assert o['stage'] == 'post-frame-lowering' and o['iteration_mapping']
    # The explicitly requested suffix unroll normalizes back to VF=1 exactly.
    assert o['iteration_width'] == 4, o
    assert len(o['body']) == len(r['mir_costs'])
    assert not any(op['vector'] for op in o['body'])
    demand = sum((Q(c['numerator'], c['denominator']) for c in r['mir_costs']), Q(0))
    spill = sum((Q(c['numerator'], c['denominator']) for op, c in
                 zip(o['body'], r['mir_costs']) if op['spill_slot']), Q(0))
    scale = Q(4, o['iteration_width'])
    assert exact(r, 'mir_body') == demand * scale
    assert exact(r, 'mir_spill') == spill * scale
    expected = demand * scale
    if r['use_estimated_spill']:
        expected += r['estimated_total_spill_quarters'] - spill * scale
    assert exact(r, 'body') == expected
    vectors = [v for v in rows if v.get('role') in ('main', 'epilogue')]
    assert vectors and all(v['ic'] == 4 for v in vectors if v['role'] == 'main')
    return r, vectors


flags = ['-vplan-backend', '-use-mir']
reference = None
for default in (False, True):
    ir, rows, _ = run('default-' + str(default), flags +
                      ['-use-default-tti=' + str(default).lower()])
    r, vectors = scalar(rows)
    facts = (ir, exact(r, 'body'), r['observation'],
             [(v['candidate'], exact(v, 'mir_body'), exact(v, 'mir_spill')) for v in vectors])
    if reference is None:
        reference = facts
    assert facts == reference

# Reporting remains passive. Dumped private IR proves prefix and selected loop
# remain in the same complete function before and after the native suffix.
ir, rows, text = run('dump', flags + ['-vplan-backend-pruning-dump-ir'])
assert ir == reference[0]
r, _ = scalar(rows)
start = 'VPLAN-BACKEND-PRUNING-IR: ' + r['candidate'] + ' '
for stage in ('before', 'after', 'suffix'):
    body = text.split(start + stage + '\n', 1)[1].split('VPLAN-BACKEND-PRUNING-IR-END', 1)[0]
    assert 'define void @context(' in body and 'load volatile i64' in body
    assert 'store volatile i64' in body and 'prefix:' in body
    assert 'vplan.backend.role"="scalar-baseline' in body

for default in (False, True):
    _, rows, _ = run('estimated-' + str(default), flags + ['-use-estimated-spill',
                      '-use-default-tti=' + str(default).lower()])
    scalar(rows)

# The native suffix fully unrolls this runtime remainder, leaving a unique
# main loop whose induction witness proves four original scalar iterations.
remainder = Path(prefix + '.remainder.ll')
remainder.write_text(Path(source).read_text().replace('%next, %bound', '%next, %n'))
_, rows, _ = run('runtime-remainder', flags, remainder)
scalar(rows)
