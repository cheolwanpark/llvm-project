"""Lower-bound proofs and bounded whole-loop retries through the opt pipeline."""
import json
from fractions import Fraction as Q
from pathlib import Path
import subprocess
import sys

opt, source, prefix, pressure, basic = sys.argv[1:]
root = Path(prefix)
root.mkdir(parents=True, exist_ok=True)
base = [opt, '-mtriple=riscv64', '-mcpu=xiangshan-kunminghu', '-mattr=+v',
        '-codegen-opt-level=3', '-passes=loop-vectorize',
        '-force-vector-interleave=1', '-riscv-v-register-bit-width-lmul=8',
        '-enable-epilogue-vectorization=false', '-verify-each',
        '-verify-machineinstrs']


def run(name, flags=(), src=source):
    path = root / (name + '.jsonl')
    path.unlink(missing_ok=True)
    overrides = {f.split('=')[0] for f in flags}
    cmd = [f for f in base if f.split('=')[0] not in overrides]
    result = subprocess.run(cmd + list(flags) + [src, '-S', '-o', '-',
                            '-vplan-backend-jsonl=' + str(path)],
                            text=True, capture_output=True, timeout=120)
    (root / (name + '.stderr')).write_text(result.stderr)
    assert result.returncode == 0, (cmd, flags, result.stderr)
    rows = [json.loads(s) for s in path.read_text().splitlines()] if path.exists() else []
    return result.stdout, rows, result.stderr


def exact(row, key):
    return Q(row[key + '_quarters_numerator'], row[key + '_quarters_denominator'])


def verify_pruned(rows):
    for r in rows:
        if r['status'] != 'pruned':
            continue
        assert 'body_quarters_numerator' not in r
        assert 'normalized_vector_spill_quarters_numerator' not in r
        if not r['queried']:
            assert 'observation' not in r
        scalar, tc = exact(r, 'scalar'), r['max_trip_count']

        def score(body, width):
            if not tc:
                return body / width
            if r['scalar_tail']:
                return body * (tc // width) + scalar * (tc % width)
            return body * ((tc + width - 1) // width)

        assert score(exact(r, 'basis'), r['basis_width']) < score(
            exact(r, 'lower_bound'), r['tti_width']), r


def used(rows):
    # Speculative observations and attempt counts can differ across capacities.
    return sorted((r['candidate'], r['model'], str(exact(r, 'body')))
                  for r in rows if 'body_quarters_numerator' in r), [
        r for r in rows if r['status'] == 'selected']


reference = None
for workers in (1, 2, 4):
    for report in ('', '-print-vplans', '-print-detailed-vplans'):
        flags = ['-vplan-backend', f'-vplan-backend-probe-threads={workers}']
        if report:
            flags += [report]
        ir, rows, text = run(f'pruned-{workers}-{report}', flags)
        verify_pruned(rows)
        assert not any('fallback' in r['status'] for r in rows)
        dots = [r for r in rows if r['function'] == 'dot4']
        assert all(r['status'] == 'pruned' and r['pruning_basis'] == 'scalar'
                   for r in dots if 'candidate' in r)
        assert any(r['status'] == 'selected' and r['vf'] == 1 for r in dots)
        gates = [r for r in rows if r['function'] == 'gate']
        assert any(r['status'] == 'skipped' and r['cost_source'] == 'gate' for r in gates)
        assert any(r['status'] == 'pruned' and r['pruning_basis'] != 'scalar' for r in gates)
        assert not any(r.get('queried') for r in rows)
        current = ir, used(rows)
        if reference is None:
            reference = current
        assert current == reference
        if report:
            assert 'backend-pruned candidate=' in text

# Explicit scalar-tail policy leaves epilogues possible. Only scalar can prune,
# so the main-losing vector candidates are still priced and retained.
epilogue_source = root / 'epilogue.ll'
epilogue_source.write_text(Path(source).read_text().replace('%next, 24', '%next, 40'))
_, rows, _ = run('epilogue-possible', ['-vplan-backend',
    '-enable-epilogue-vectorization=true', '-tail-folding-policy=dont-fold-tail',
    '-disable-loop-unrolling'], str(epilogue_source))
verify_pruned(rows)
assert any(r['status'] == 'pruned' and r['pruning_basis'] == 'scalar' for r in rows)
assert all(r['pruning_basis'] == 'scalar' for r in rows if r['status'] == 'pruned')
assert any(r['status'] == 'collected' and r['function'] == 'gate' for r in rows)

# Required failure at the actual mapping boundary: keep unrolling enabled.
estimated_ir, estimated_rows, _ = run('estimated', ['-vplan-backend', '-use-estimated-spill'])
forced_ir, forced_rows, text = run('force', ['-vplan-backend', '-vplan-backend-force-all',
                                          '-print-detailed-vplans'])
assert forced_ir == estimated_ir
fallback = next(r for r in forced_rows if r['function'] == 'dot4' and r['status'] == 'estimated-fallback')
assert 'original scalar iteration mapping is unproven' in fallback['reason']
assert fallback['requested_model'] == 'tti-real-vector-spill-v1'
assert fallback['effective_model'] == 'tti-v1'
assert all(r['model'] == 'tti-v1' for r in forced_rows if r['function'] == 'dot4')
assert 'B=L=' in text
assert any(r['status'] == 'selected' and r['function'] == 'dot4' and r['vf'] == 1
           for r in forced_rows)

# Force-all and forced VF bypass pruning; scalable-always policy is also outside
# the numeric proof's supported scope. The latter may legitimately fall back.
for name, extra in [('vf', ['-force-vector-width=4']),
                    ('scalable', ['-scalable-vectorization=always'])]:
    _, rows, _ = run(name, ['-vplan-backend', '-disable-loop-unrolling'] + extra)
    assert not any(r['status'] == 'pruned' for r in rows)

# Both MIR modes bypass lower-bound pruning and use the raw requested default
# boolean for fallback. Explicit false must behave like an omitted option.
for mir in (False, True):
    for estimated in ((False, True) if mir else (False,)):
        for default in (False, True):
            flags = ['-vplan-backend', f'-use-mir={str(mir).lower()}',
                     f'-use-estimated-spill={str(estimated).lower()}',
                     f'-use-default-tti={str(default).lower()}',
                     '-vplan-backend-force-all', '-riscv-rvv-regalloc=fast',
                     '-print-detailed-vplans']
            ir, rows, text = run(f'fallback-{mir}-{estimated}-{default}', flags, basic)
            expected, _, _ = run(f'expected-{mir}-{estimated}-{default}',
                [] if default else ['-vplan-backend', '-use-estimated-spill'], basic)
            assert ir == expected
            status = 'native-fallback' if default else 'estimated-fallback'
            assert any(r['status'] == status for r in rows)
            assert not any(r['status'] == 'pruned' for r in rows)
            if default:
                assert 'backend-cost phase=' not in text
                assert not any('candidate' in r for r in rows)
            else:
                assert all(r['model'] == 'tti-v1' for r in rows)
                assert all(r['reason'] == 'estimated-spill-no-probe'
                           for r in rows if 'candidate' in r)
                assert ' B=L=' in text and ' B=R=' not in text

# Capability depends on the function's CPU and VLEN, independently of MIRInfo.
for name, flags, src in [('cpu', ['-mcpu=generic-rv64'], basic),
                         ('vlen', [], str(root / 'wide.ll'))]:
    if name == 'vlen':
        Path(src).write_text(Path(basic).read_text().replace('vscale_range(2,2)', 'vscale_range(4,4)'))
    native, _, _ = run(name + '-native', flags, src)
    ir, rows, _ = run(name, flags + ['-vplan-backend', '-use-mir'], src)
    assert ir == native
    assert any(r['status'] == 'native-fallback' for r in rows)
    assert not any(r['status'] == 'estimated-fallback' for r in rows)

# Compare actual probe costs and output across capacities on a spilling loop.
reference = None
for workers in (1, 2, 4):
    ir, rows, _ = run(f'pressure-{workers}', ['-vplan-backend', '-disable-loop-unrolling',
                     f'-vplan-backend-probe-threads={workers}'], pressure)
    assert any(r['status'] == 'collected' for r in rows)
    current = ir, used(rows)
    if reference is None:
        reference = current
    assert current == reference

native, _, _ = run('off-native')
off, rows, text = run('off', ['-use-mir', '-use-estimated-spill', '-vplan-backend-force-all'])
assert off == native and not rows and not text
