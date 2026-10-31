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


def candidates(rows, require_selection=True):
    assert not any(r['status'] == 'native-fallback' for r in rows), rows
    result = [r for r in rows if 'candidate' in r and r.get('role') != 'scalar-baseline']
    assert result, rows
    if require_selection:
        assert any(r['status'] == 'selected' for r in rows), rows
    return result


def verify_mir(row, estimated):
    assert row['status'] == 'collected'
    observation = row['observation']
    assert observation['stage'] == 'post-frame-lowering'
    assert observation['schema'] == 'mir-body-observation-v1'
    assert observation['body'] and len(observation['body']) == len(row['mir_costs'])
    assert row['mir_model'] == 'xiangshan-direct-v1'
    demand = spill = Q(0)
    for op, cost in zip(observation['body'], row['mir_costs']):
        c = Q(cost['numerator'], cost['denominator'])
        demand += c
        if op['spill_slot']:
            spill += c
    scale = Q(4 * row['tti_width'], observation['iteration_width'])
    assert exact(row, 'mir_body') == demand * scale
    assert exact(row, 'mir_spill') == spill * scale
    expected = demand * scale
    if estimated:
        expected += row['estimated_total_spill_quarters'] - spill * scale
    assert exact(row, 'body') == expected, row
    assert row['unknown_instruction_count'] == sum(c['unknown'] for c in row['mir_costs'])


def verify(rows, mir, estimated, default, require_selection=True):
    vectors = candidates(rows, require_selection)
    scalars = [r for r in rows if r.get('role') == 'scalar-baseline']
    baselines = {(r['function'], r['loop']): r for r in scalars}
    if mir:
        loops = {(r['function'], r['loop']) for r in vectors}
        assert len(scalars) == len(loops) and set(baselines) == loops
        for row in scalars:
            assert row['vf'] == row['ic'] == row['tti_width'] == 1
            assert not row['scalable']
            assert row['candidate'].endswith(':scalar-baseline')
            assert row['observation']['observation_role'] == 'scalar-baseline'
            verify_mir(row, estimated)
    else:
        assert not scalars
    for r in vectors:
        body = exact(r, 'body')
        if mir:
            verify_mir(r, estimated)
            scalar = baselines[r['function'], r['loop']]
            assert exact(r, 'scalar') == exact(scalar, 'body')
            assert r['scalar_cost_source'] == ('mir-estimated-spill' if estimated else 'mir')
            assert r['scalar_profile'] == scalar['mir_model']
            assert r['tti_profile'] == ('native' if default else 'xiangshan-v2-128')
        else:
            assert r['scalar_cost_source'] == 'tti'
            assert r['scalar_profile'] == ('native' if default else 'xiangshan-v2-128')
            if estimated:
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
        if default:
            assert r['profile_body_quarters'] == r['native_body_quarters']
            assert r['tti_profile'] != 'xiangshan-v2-128'


def pure_mir_facts(rows):
    return [(r['candidate'], exact(r, 'body'), exact(r, 'mir_body'),
             exact(r, 'mir_spill'), r['observation'])
            for r in rows if 'candidate' in r]


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
assert results[True, False, False][0] == results[True, False, True][0]
assert pure_mir_facts(results[True, False, False][1]) == pure_mir_facts(results[True, False, True][1])

for estimated in (False, True):
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

# Real scalar pressure uses the original VF=1 plan, independently of the
# observed scalar spill-slot instructions. One vector VF keeps this focused.
scalar_pressure = Path(prefix + '.scalar-pressure.ll')
count = 40
lines = ['define void @scalar_pressure(ptr noalias %a, ptr noalias %out, i64 %n) vscale_range(2,2) {',
         'entry: br label %loop', 'loop:',
         '  %iv = phi i64 [0, %entry], [%next, %loop]']
for i in range(count):
    lines += [f'  %s{i} = phi double [0.0, %entry], [%r{i}, %loop]']
for i in range(count):
    lines += [f'  %j{i} = add i64 %iv, {i * 1024}',
              f'  %p{i} = getelementptr double, ptr %a, i64 %j{i}',
              f'  %v{i} = load double, ptr %p{i}, align 8',
              f'  %r{i} = fadd fast double %s{i}, %v{i}']
lines += ['  %next = add nuw i64 %iv, 1',
          '  %done = icmp eq i64 %next, %n',
          '  br i1 %done, label %exit, label %loop', 'exit:']
for i in range(count):
    lines += [f'  %dst{i} = getelementptr double, ptr %out, i64 {i}',
              f'  store double %r{i}, ptr %dst{i}, align 8']
lines += ['  ret void', '}']
scalar_pressure.write_text('\n'.join(lines) + '\n')
pressure_flags = ['-vplan-backend', '-use-mir', '-use-estimated-spill',
                  '-force-vector-width=2']
pressure_scalars = []
for default in (False, True):
    _, rows, _ = run('scalar-pressure-' + str(default), pressure_flags +
        ['-vectorizer-consider-reg-pressure=true',
         '-use-default-tti=' + str(default).lower()], str(scalar_pressure))
    verify(rows, True, True, default, require_selection=False)
    scalar = next(r for r in rows if r.get('role') == 'scalar-baseline')
    assert scalar['estimated_total_spill_quarters'] > 0, scalar
    assert exact(scalar, 'mir_spill') > 0, scalar
    pressure_scalars.append(scalar)
# Both register-usage analyses are native; only (n,n) pricing changes. XS scalar
# stores cost 2, loads cost 1, compared with native cost 1 in each direction.
assert pressure_scalars[0]['estimated_total_spill_quarters'] * 2 == pressure_scalars[1]['estimated_total_spill_quarters'] * 3
assert exact(pressure_scalars[0], 'mir_spill') == exact(pressure_scalars[1], 'mir_spill')
assert exact(pressure_scalars[0], 'mir_body') == exact(pressure_scalars[1], 'mir_body')

_, rows, _ = run('scalar-pressure-disabled', pressure_flags +
                ['-vectorizer-consider-reg-pressure=false'], str(scalar_pressure))
verify(rows, True, True, False, require_selection=False)
scalar = next(r for r in rows if r.get('role') == 'scalar-baseline')
assert exact(scalar, 'mir_spill') > 0 and scalar['estimated_total_spill_quarters'] == 0
assert exact(scalar, 'body') == exact(scalar, 'mir_body') - exact(scalar, 'mir_spill')

# Scheduling may reduce real liveness below the IR-order estimate: put all
# loads before an addition chain and allow the native machine scheduler to
# interleave them. No observed spill counts enter the estimate.
scalar_scheduled = Path(prefix + '.scalar-scheduled.ll')
lines = ['define void @scalar_scheduled(ptr noalias %a, ptr noalias %out, i64 %n) vscale_range(2,2) {',
         'entry: br label %loop', 'loop:',
         '  %iv = phi i64 [0, %entry], [%next, %loop]']
for i in range(count):
    lines += [f'  %j{i} = add i64 %iv, {i * 3}',
              f'  %p{i} = getelementptr double, ptr %a, i64 %j{i}',
              f'  %v{i} = load double, ptr %p{i}, align 8']
for i in range(1, count):
    previous = '%v0' if i == 1 else f'%s{i - 1}'
    lines += [f'  %s{i} = fadd fast double {previous}, %v{i}']
lines += ['  %dst = getelementptr double, ptr %out, i64 %iv',
          f'  store double %s{count - 1}, ptr %dst, align 8',
          '  %next = add nuw i64 %iv, 1',
          '  %done = icmp eq i64 %next, %n',
          '  br i1 %done, label %exit, label %loop',
          'exit: ret void', '}']
scalar_scheduled.write_text('\n'.join(lines) + '\n')
_, rows, _ = run('scalar-scheduled', pressure_flags +
                ['-vectorizer-consider-reg-pressure=true'], str(scalar_scheduled))
# The later runtime-check profitability test may decline emission. Every
# successful candidate score still has to use this exact scalar baseline.
verify(rows, True, True, False, require_selection=False)
scalar = next(r for r in rows if r.get('role') == 'scalar-baseline')
assert scalar['estimated_total_spill_quarters'] > 0, scalar
assert exact(scalar, 'mir_spill') == 0, scalar
assert exact(scalar, 'body') == exact(scalar, 'mir_body') + scalar['estimated_total_spill_quarters']

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
                          ('limited', ['-stop-before=prologepilog'], None)]:
    baseline, _, _ = run(name + '-baseline', cpu=cpu)
    out, rows, stderr = run(name, ['-vplan-backend', '-use-mir',
                                  '-print-detailed-vplans', '-use-default-tti=true'] + extra, cpu=cpu)
    assert out == baseline
    assert any(r['status'] == 'native-fallback' for r in rows), rows
    assert 'backend-cost phase=' not in stderr
    assert 'backend-scalar source=mir' not in stderr
    assert not any(r.get('role') == 'scalar-baseline' for r in rows)

# Other RVV CPUs use an executable generic sheet, independent of default TTI.
_, generic_rows, _ = run('generic', ['-vplan-backend', '-use-mir'], cpu='generic-rv64')
assert all(r['mir_model'] == 'riscv-generic-direct-v1' for r in candidates(generic_rows))

# Passive reporting does not alter selection, and captures MIR text on demand.
printed, rows, stderr = run('detail', ['-vplan-backend', '-use-mir', '-print-detailed-vplans'])
assert printed == results[True, False, False][0]
assert 'mir-op ' in stderr and 'stage=post-frame-lowering' in stderr
assert all('mir' in op for r in candidates(rows) for op in r['observation']['body'])
scalar_rows = [r for r in rows if r.get('role') == 'scalar-baseline']
scalar_lines = [s for s in stderr.splitlines() if s.startswith('  backend-scalar source=')]
assert len(scalar_lines) == len(scalar_rows)
for row, line in zip(scalar_rows, scalar_lines):
    assert 'source=mir ' in line and f"profile={row['mir_model']} " in line
    assert f"revision={row['mir_revision']} " in line
    assert f"Wobs={row['observation']['iteration_width']} " in line
    assert Q(line.split(' cost=')[1].split()[0]) * 4 == exact(row, 'body')
    assert f"unknown_instruction_count={row['unknown_instruction_count']}" in line
assert stderr.count('    scalar-mir-op ') == sum(len(r['mir_costs']) for r in scalar_rows)


# The supported profile is exact VLEN=128, not every XiangShan vector length.
wide_source = Path(prefix + '.vlen256.ll')
wide_source.write_text(Path(source).read_text().replace('vscale_range(2,2)', 'vscale_range(4,4)'))
wide_native, _, _ = run('vlen256-native', src=str(wide_source))
wide_ir, wide_rows, _ = run('vlen256', ['-vplan-backend', '-use-mir'], src=str(wide_source))
assert candidates(wide_rows)
assert all(r['mir_model'] == 'riscv-generic-direct-v1' for r in candidates(wide_rows))

# CFG reduction is never applied to either MIR body model, regardless of option.
for estimated in (False, True):
    flags = ['-vplan-backend', '-use-mir', '-vplan-backend-pruning-trace']
    if estimated:
        flags.append('-use-estimated-spill')
    enabled, enabled_rows, text = run('mir-cfg-on-' + str(estimated), flags, pressure)
    disabled, disabled_rows, _ = run('mir-cfg-off-' + str(estimated),
        flags + ['-vplan-backend-prune-cfg=false'], pressure)
    assert enabled == disabled and enabled_rows == disabled_rows
    traces = [json.loads(line.split(': ', 1)[1]) for line in text.splitlines()
              if line.startswith('VPLAN-BACKEND-PRUNING: ')]
    assert traces and all(not r['applied'] and r['reason'] == 'mir-observation' for r in traces)
