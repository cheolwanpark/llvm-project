# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
"""Behavioral checks shared by the four backend-feedback lit entry points."""
from fractions import Fraction
import json
from pathlib import Path
import subprocess
import sys

suite, opt, source, temporary = sys.argv[1:]
source, root = Path(source), Path(temporary)
root.mkdir(parents=True, exist_ok=True)
commands = []
base = [opt, '-mtriple=riscv64', '-mcpu=xiangshan-kunminghu', '-mattr=+v',
        '-codegen-opt-level=2', '-passes=loop-vectorize', '-vplan-backend',
        '-scalable-vectorization=always', '-force-vector-interleave=1',
        '-enable-epilogue-vectorization=false', '-riscv-v-register-bit-width-lmul=8',
        '-disable-loop-unrolling', '-verify-each', '-verify-machineinstrs']


def run(name, flags=(), src=source, diagnostic=True, user_probes=False):
    report = root / (name + '.jsonl')
    report.unlink(missing_ok=True)
    overrides = {f.split('=')[0] for f in flags}
    command = [f for f in base if f.split('=')[0] not in overrides] + list(flags)
    if diagnostic:
        command += ['-vplan-backend-jsonl=' + str(report)]
    command += [str(src), '-S', '-o', '-']
    commands.append(command)
    (root / 'commands.json').write_text(json.dumps(commands, indent=2))
    result = subprocess.run(command, text=True, capture_output=True, timeout=120)
    (root / (name + '.stderr')).write_text(result.stderr)
    (root / (name + '.ll')).write_text(result.stdout)
    assert result.returncode == 0, (name, result.stderr)
    if not user_probes:
        assert 'llvm.pseudoprobe' not in result.stdout, 'private markers escaped'
    rows = [json.loads(line) for line in report.read_text().splitlines()] if report.exists() else []
    return result.stdout, rows, result.stderr


def exact(row, field):
    return Fraction(row[field + '_quarters_numerator'],
                    row[field + '_quarters_denominator'])


def candidates(rows):
    return [r for r in rows if 'body_quarters_numerator' in r]


def decisions(rows):
    return [r for r in rows if r['status'] == 'selected']


def costs(rows):
    return [(r['candidate'], r['model'], exact(r, 'body')) for r in candidates(rows)]


def pressure():
    # Keep twelve independent values live through a ring of products. This is
    # synthetic pressure, not a copy of a benchmark source or its expected cost.
    lines = ['define void @pressure(ptr noalias %a, ptr noalias %b, i64 %n) vscale_range(2,2) {',
             'entry: br label %loop', 'loop:',
             '%i = phi i64 [0, %entry], [%next, %loop]']
    for i in range(12):
        lines += [f'%j{i} = add i64 %i, {i * 1024}',
                  f'%p{i} = getelementptr double, ptr %a, i64 %j{i}',
                  f'%v{i} = load double, ptr %p{i}']
    for i in range(12):
        lines += [f'%m{i} = fmul fast double %v{i}, %v{(i + 1) % 12}',
                  f'%r{i} = fadd fast double %m{i}, %v{(i + 6) % 12}',
                  f'%q{i} = getelementptr double, ptr %b, i64 %j{i}',
                  f'store double %r{i}, ptr %q{i}']
    lines += ['%next = add nuw i64 %i, 1', '%done = icmp eq i64 %next, %n',
              'br i1 %done, label %exit, label %loop', 'exit: ret void', '}']
    path = root / 'pressure-input.ll'
    path.write_text('\n'.join(lines))
    return path


def check_formula(row, mir, estimated):
    if mir:
        obs = row['observation']['mir_observation']
        assert obs['status'] == 'succeeded' and obs['stage'] == 'post-frame-lowering'
        body = sum(Fraction(c['numerator'], c['denominator']) for c in row['mir_costs'])
        spill = sum(Fraction(c['numerator'], c['denominator'])
                    for op, c in zip(obs['body'], row['mir_costs']) if op['spill_slot'])
        scale = Fraction(4 * row['tti_width'], obs['iteration_width'])
        assert exact(row, 'mir_body') == body * scale
        assert exact(row, 'mir_spill') == spill * scale
        expected = body * scale
        if estimated:
            expected += row['estimated_total_spill_quarters'] - spill * scale
    else:
        expected = row['profile_body_quarters']
        if not estimated:
            expected -= row['estimated_vector_spill_quarters']
            expected += exact(row, 'normalized_vector_spill')
        else:
            assert 'observation' not in row
    assert exact(row, 'body') == expected, row


def pipeline():
    forced = ['-force-vector-width=4', '-vplan-backend-force-all']
    _, zero, _ = run('zero', forced)
    observed = [r['observation'] for r in candidates(zero)]
    assert observed
    for obs in observed:
        assert obs['spill_observation']['status'] == 'succeeded'
        assert obs['spill_observation']['spills'] == []
        assert obs['mir_observation']['status'] == 'not_requested'
    path = pressure()
    # Each algebraic mode once; default-TTI is an orthogonal policy boundary.
    for label, mir, estimated, default in [('real', False, False, False),
                                         ('estimated', False, True, False),
                                         ('mir', True, False, False),
                                         ('mir-estimated', True, True, False),
                                         ('mir-native-estimate', True, True, True)]:
        flags = forced + [f'-use-mir={str(mir).lower()}',
                          f'-use-estimated-spill={str(estimated).lower()}',
                          f'-use-default-tti={str(default).lower()}']
        _, rows, _ = run(label, flags, path)
        scored = candidates(rows)
        assert scored and not any('fallback' in r['status'] for r in rows), rows
        for row in scored:
            check_formula(row, mir, estimated)
            assert row['tti_profile'] == ('native' if default else 'xiangshan-v2-128')
        if mir:
            scalar = [r for r in scored if r.get('role') == 'scalar-baseline']
            assert len(scalar) == 1 and scalar[0]['tti_width'] == 1
            vectors = [r for r in scored if r.get('role') != 'scalar-baseline']
            assert all(exact(r, 'scalar') == exact(scalar[0], 'body') for r in vectors)
            assert all(r['mir_model'] == 'xiangshan-direct-v1' for r in scored)
            assert all(r['observation']['spill_observation']['status'] == 'succeeded'
                       for r in scored)
        elif not estimated:
            assert any(r['observation']['spill_observation']['spills'] for r in scored)
    # MIR collection is still valid when the earlier spill observer cannot run.
    _, rows, _ = run('spill-unavailable', forced + ['-use-mir', '-disable-ssc'])
    for row in candidates(rows):
        obs = row['observation']
        assert obs['spill_observation']['status'] == 'failed'
        assert obs['mir_observation']['status'] == 'succeeded'
    assert candidates(rows) and not any('fallback' in r['status'] for r in rows)


def selection():
    forced = ['-force-vector-width=4', '-vplan-backend-force-all']
    native, rows, _ = run('native', ['-vplan-backend=false'])
    off, disabled, text = run('master-off', ['-vplan-backend=false', '-use-mir',
                              '-use-estimated-spill', '-vplan-backend-time'])
    assert off == native and not rows and not disabled and not text
    for label, flags, expected in [
            ('mir-real', ['-use-mir'], ['mir-v1', 'llvm-real-vector-spill-v1', 'llvm-v1']),
            ('mir-est', ['-use-mir', '-use-estimated-spill'], ['mir-me-spill-v1', 'llvm-v1']),
            ('real', [], ['llvm-real-vector-spill-v1', 'llvm-v1'])]:
        _, rows, report = run(label, forced + flags + ['-use-default-tti',
                            '-riscv-rvv-regalloc=fast', '-print-detailed-vplans'])
        fallback = next(r for r in rows if r['status'] == 'estimated-fallback')
        assert [a['model'] for a in fallback['attempts']] == expected
        assert all(a['use_default_tti'] for a in fallback['attempts'])
        assert not any(r.get('role') == 'scalar-baseline' for r in rows)
        assert all(r['model'] == 'llvm-v1' for r in candidates(rows))
        assert 'backend-scalar source=mir' not in report
    # An externally restricted pipeline is uncollected, never observed zero.
    _, rows, _ = run('late-unavailable', forced + ['-use-mir', '-use-default-tti',
                                                '-stop-before=prologepilog'])
    fallback = next(r for r in rows if r['status'] == 'estimated-fallback')
    obs = fallback['attempts'][0]['observations'][0]
    assert obs['spill_observation']['status'] == 'not_collected'
    assert obs['mir_observation']['status'] == 'not_collected'
    # Report requests may enrich text, but never change prices, selection or IR.
    flags = forced + ['-use-mir']
    silent, _, _ = run('silent', flags, diagnostic=False)
    logged, rows, _ = run('logged', flags)
    printed, detailed, report = run('printed', flags + ['-print-vplans', '-print-detailed-vplans'])
    assert silent == logged == printed
    assert costs(rows) == costs(detailed) and decisions(rows) == decisions(detailed)
    assert report.count('VPlan report_version=') == 1
    assert 'mir-op ' in report
    # Preserve native IC and forced vector epilogue policy.
    ir, rows, _ = run('epilogue', ['-scalable-vectorization=off', '-force-vector-width=8',
        '-force-vector-interleave=4', '-enable-epilogue-vectorization=true',
        '-epilogue-vectorization-force-VF=2', '-vplan-backend-force-all'])
    assert 'vec.epilog' in ir and any(r['ic'] == 4 for r in candidates(rows))
    assert any(r['epilogue_vf'] == 2 for r in decisions(rows))


def scopes():
    flags = ['-codegen-opt-level=3', '-disable-loop-unrolling=false',
             '-scalable-vectorization=off', '-force-vector-width=16',
             '-vplan-backend-force-all', '-use-default-tti']
    for trips in (64, 16):
        path = root / f'trips-{trips}.ll'
        path.write_text(source.read_text().replace('%next, 64', f'%next, {trips}'))
        off, failed, _ = run(f'{trips}-off', flags + ['-vplan-backend-region-probes=false'], path)
        on, recovered, _ = run(f'{trips}-on', flags, path)
        assert off == on
        assert any(r['status'] == 'estimated-fallback' for r in failed)
        observed = [r['observation']['spill_observation'] for r in candidates(recovered)]
        assert len(observed) == 1
        obs = observed[0]
        assert obs['status'] == 'succeeded' and obs['scope'] == 'probe-region'
        assert obs['iteration_width'] == trips
        assert obs['region_probe_count'] == trips // 16
    # User instrumentation vetoes our insertion. Structural observation still
    # works; the veto is not itself a reason to discard a mapped loop.
    path = root / 'instrumented.ll'
    text = (source.parent / 'backend-pipeline.ll').read_text()
    text = text.replace('  %p = getelementptr',
        '  call void @llvm.pseudoprobe(i64 7, i64 1, i32 0, i64 -1)\n  %p = getelementptr')
    text += '\ndeclare void @llvm.pseudoprobe(i64, i64, i32, i64)\n'
    path.write_text(text)
    ir, rows, _ = run('instrumented', ['-scalable-vectorization=off', '-force-vector-width=4',
                      '-vplan-backend-force-all'], path, user_probes=True)
    observed = [r['observation']['spill_observation'] for r in candidates(rows)]
    assert observed and all(o['status'] == 'succeeded' for o in observed)
    assert all(o.get('scope') != 'probe-region' for o in observed)
    assert all('i64 7, i64 1' in line for line in ir.splitlines()
               if 'call void @llvm.pseudoprobe' in line)


def execution():
    off_ir, all_rows, _ = run('all', ['-vplan-backend-force-all'])
    ir, rows, _ = run('gate', ['-disable-ssc'])
    assert ir == off_ir
    assert any(r['status'] == 'skipped' for r in rows)
    assert any(r['status'] == 'pruned' for r in rows)
    assert not any(r.get('queried') for r in rows)
    path = pressure()
    serial, a, _ = run('serial', [], path)
    parallel, b, _ = run('parallel', ['-vplan-backend-probe-threads=2'], path)
    assert serial == parallel and costs(a) == costs(b) and decisions(a) == decisions(b)
    assert any(r['status'] == 'collected' for r in a)
    cfg = root / 'cfg-input.ll'
    body = path.read_text()
    body = body.replace('i64 %n)', 'i64 %n, i1 %choose)')
    loop = body[body.index('loop:'):body.index('exit:')]
    import re
    other = re.sub(r'%([A-Za-z][A-Za-z0-9]*)', r'%other_\1', loop)
    other = re.sub(r'%other_(a|b|n)\b', r'%\1', other)
    other = other.replace('loop:', 'other_loop:')
    cfg.write_text(body.replace('entry: br label %loop',
        'entry: br i1 %choose, label %start, label %other_entry\nstart: br label %loop')
        .replace('[0, %entry]', '[0, %start]')
        .replace('exit: ret void', 'exit: ret void\nother_entry: br label %other_loop\n' + other + 'other_exit: ret void'))
    path = cfg
    flags = ['-force-vector-width=4', '-vplan-backend-force-all', '-vplan-backend-pruning-trace']
    reduced, a, trace = run('cfg-on', flags, path)
    full, b, _ = run('cfg-off', flags + ['-vplan-backend-prune-cfg=false'], path)
    assert reduced == full and costs(a) == costs(b) and decisions(a) == decisions(b)
    traces = [json.loads(line.split(': ', 1)[1]) for line in trace.splitlines()
              if line.startswith('VPLAN-BACKEND-PRUNING: ')]
    assert traces and any(t['applied'] for t in traces)
    _, rows, trace = run('mir-cfg', flags + ['-use-mir'], path)
    traces = [json.loads(line.split(': ', 1)[1]) for line in trace.splitlines()
              if line.startswith('VPLAN-BACKEND-PRUNING: ')]
    assert traces and all(not t['applied'] for t in traces)


{'pipeline': pipeline, 'selection': selection, 'scopes': scopes, 'execution': execution}[suite]()
print(f'{suite}: {len(commands)} compiler invocations')
