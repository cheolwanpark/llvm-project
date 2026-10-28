"""Exercise the ablation controls on real in-process probes, without timings."""
import itertools
import json
from fractions import Fraction as Q
from pathlib import Path
import subprocess
import sys

opt, source, prefix, pressure = sys.argv[1:]
base = [opt, '-codegen-opt-level=2', '-mtriple=riscv64',
        '-mcpu=xiangshan-kunminghu', '-mattr=+v',
        '-scalable-vectorization=always', '-force-vector-interleave=1',
        '-riscv-v-register-bit-width-lmul=8', '-enable-epilogue-vectorization=false',
        '-disable-loop-unrolling', '-passes=loop-vectorize', '-verify-machineinstrs']


def run(name, flags=(), src=source, cpu=None):
    report = Path(prefix + '.' + name + '.jsonl')
    report.unlink(missing_ok=True)
    overridden = {f.split('=', 1)[0] for f in flags}
    command = [f for f in base if f.split('=', 1)[0] not in overridden]
    command += ['-vplan-backend-jsonl=' + str(report)] + list(flags)
    if cpu:
        command = [x for x in command if not x.startswith('-mcpu=')]
        command += ['-mcpu=' + cpu]
    p = subprocess.run(command + [src, '-S', '-o', '-'], capture_output=True,
                       text=True, timeout=120)
    assert p.returncode == 0, (command, p.stderr)
    rows = [json.loads(line) for line in report.read_text().splitlines()] if report.exists() else []
    return p.stdout, rows, p.stderr


def exact(row, key):
    return Q(row[key + '_quarters_numerator'], row[key + '_quarters_denominator'])


def candidates(rows):
    assert not any(r['status'] == 'native-fallback' for r in rows), rows
    result = [r for r in rows if 'candidate' in r]
    assert result and any(r['status'] == 'selected' for r in rows), rows
    return result


def verify(rows, mir, estimated, default):
    for r in candidates(rows):
        body = exact(r, 'body')
        if mir:
            assert r['status'] == 'collected'
            o = r['observation']
            assert o['stage'] == 'post-frame-lowering'
            assert o['schema'] == 'mir-body-observation-v1'
            assert o['body'] and len(o['body']) == len(r['mir_costs'])
            assert r['mir_model'] == 'rtl-service-sum-v1'
            assert r['tti_profile'] == 'xiangshan-v2-128'
            demand = spill = Q(0)
            for op, cost in zip(o['body'], r['mir_costs']):
                c = sum((Q(d['numerator'], d['denominator']) for d in cost['demands']), Q(0))
                demand += c
                if op['spill_slot']:
                    spill += c
            scale = Q(4 * r['tti_width'], o['iteration_width'])
            assert exact(r, 'mir_body') == demand * scale
            assert exact(r, 'mir_spill') == spill * scale
            expected = demand * scale
            if estimated:
                expected += r['estimated_total_spill_quarters'] - spill * scale
            assert body == expected, r
        elif estimated:
            assert r['status'] == 'skipped' and 'observation' not in r
            assert r['reason'] == 'estimated-spill-no-probe'
            assert body == r['profile_body_quarters']
        else:
            expected = r['profile_body_quarters'] - r['estimated_vector_spill_quarters']
            expected += Q(r['normalized_vector_spill_quarters_numerator'],
                          r['normalized_vector_spill_quarters_denominator'])
            assert body == expected
            if 'observation' in r:
                assert r['observation']['stage'] == 'post-stack-slot-coloring'
        if not mir and default:
            assert r['profile_body_quarters'] == r['native_body_quarters']
            assert r['tti_profile'] != 'xiangshan-v2-128'


native, _, _ = run('native')
results = {}
for mir, estimated, default in itertools.product((False, True), repeat=3):
    flags = [flag for enabled, flag in zip((mir, estimated, default),
             ('-use-mir', '-use-estimated-spill', '-use-default-tti')) if enabled]
    off, off_rows, _ = run('off-' + str(len(results)), flags)
    assert off == native and not off_rows
    ir, rows, _ = run('on-' + str(len(results)), ['-vplan-backend'] + flags)
    verify(rows, mir, estimated, default)
    results[mir, estimated, default] = ir, rows

assert results[False, True, True][0] == native

for estimated in (False, True):
    assert results[True, estimated, False] == results[True, estimated, True]
    assert any(r['register_usage_bound']['would_skip'] for r in candidates(results[True, estimated, False][1]))

# The two TTI-only controls do not require even a usable backend allocator.
for default in (False, True):
    flags = ['-vplan-backend', '-use-estimated-spill', '-vplan-backend-force-all',
             '-riscv-rvv-regalloc=fast']
    if default:
        flags += ['-use-default-tti']
    _, rows, _ = run('estimated-fast-' + str(default), flags)
    verify(rows, False, True, default)

# Parallel transport, native IC normalization, and real spill subtraction.
for estimated in (False, True):
    flags = ['-vplan-backend', '-use-mir'] + (['-use-estimated-spill'] if estimated else [])
    serial, rows, _ = run('pressure-' + str(estimated), flags, pressure)
    verify(rows, True, estimated, False)
    assert any(op['spill_slot'] for r in candidates(rows) for op in r['observation']['body'])
    parallel, parallel_rows, _ = run('parallel-' + str(estimated),
        flags + ['-vplan-backend-probe-threads=2'], pressure)
    assert serial == parallel and rows == parallel_rows

_, rows, _ = run('ic4', ['-vplan-backend', '-use-mir', '-force-vector-interleave=4'])
verify(rows, True, False, False)
assert all(r['ic'] == 4 for r in candidates(rows))

# RISC-V opts out of automatic epilogues. Preserve its forced-epilogue
# policy: main probes include the forced epilogue, whose cost comparison is
# bypassed by native policy rather than manufacturing another body query.
epilogue, rows, _ = run('epilogue', ['-vplan-backend', '-use-mir',
    '-enable-epilogue-vectorization=true', '-scalable-vectorization=off',
    '-force-vector-width=8', '-force-vector-interleave=4',
    '-epilogue-vectorization-force-VF=2'])
verify(rows, True, False, False)
assert any(r['vector_epilogue'] for r in candidates(rows))
assert 'vec.epilog' in epilogue

# Native fallback must also discard attempted detailed backend cost reports.
for name, extra, cpu in [('fast', ['-riscv-rvv-regalloc=fast'], None),
                          ('limited', ['-stop-before=prologepilog'], None),
                          ('unsupported', [], 'generic-rv64')]:
    baseline, _, _ = run(name + '-baseline', cpu=cpu)
    out, rows, stderr = run(name, ['-vplan-backend', '-use-mir',
                                  '-print-detailed-vplans', '-use-default-tti=true'] + extra, cpu=cpu)
    assert out == baseline
    assert any(r['status'] == 'native-fallback' for r in rows), rows
    assert 'backend-cost phase=' not in stderr

# Passive reporting does not alter selection, and captures MIR text on demand.
printed, rows, stderr = run('detail', ['-vplan-backend', '-use-mir', '-print-detailed-vplans'])
assert printed == results[True, False, False][0]
assert 'mir-op ' in stderr and 'stage=post-frame-lowering' in stderr
assert all('mir' in op for r in candidates(rows) for op in r['observation']['body'])

# The supported profile is exact VLEN=128, not every XiangShan vector length.
wide_source = Path(prefix + '.vlen256.ll')
wide_source.write_text(Path(source).read_text().replace('vscale_range(2,2)', 'vscale_range(4,4)'))
wide_native, _, _ = run('vlen256-native', src=str(wide_source))
wide_ir, wide_rows, _ = run('vlen256', ['-vplan-backend', '-use-mir'], src=str(wide_source))
assert wide_ir == wide_native
assert any(r['status'] == 'native-fallback' and r['reason'].endswith('target has no MIR service model')
           for r in wide_rows)
