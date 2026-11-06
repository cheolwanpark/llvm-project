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
        assert 'llvm.pseudoprobe' not in result.stdout, 'unexpected instrumentation'
    rows = [json.loads(line) for line in report.read_text().splitlines()] if report.exists() else []
    return result.stdout, rows, result.stderr


def exact(row, field):
    return Fraction(row[field + '_quarters_numerator'],
                    row[field + '_quarters_denominator'])


def candidates(rows):
    return [r for r in rows if 'body_quarters_numerator' in r]


def decisions(rows):
    return [r for r in rows if r['status'] == 'selected']


def failures(rows):
    return [r for r in rows if r['status'] == 'backend-failures']


def fell_back(rows):
    return any(r['requested_model'] != r['effective_model'] for r in decisions(rows))


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
        assert row['observation']['observation_schema'] == 'backedge-loop-observations-v5'
        assert obs['schema'] == 'mir-body-observation-v6'
        assert obs['mapping_kind'] == 'backedge-loops'
        assert 'iteration_width' not in obs and 'body' not in obs
        loops = {loop['id']: loop for loop in obs['loops']}
        assert row['mir_loops'] and len(loops) == len(obs['loops'])
        body = spill = Fraction(0)
        for prices in row['mir_loops']:
            loop = loops[prices['id']]
            raw_body = sum(Fraction(c['numerator'], c['denominator'])
                           for c in prices['instructions'])
            raw_spill = sum(Fraction(c['numerator'], c['denominator'])
                            for op, c in zip(loop['body'], prices['instructions'])
                            if op['spill_slot'])
            scale = Fraction(4 * row['tti_width'],
                             loop['iteration_width'] * len(row['mir_loops']))
            assert exact(prices, 'body') == raw_body * scale
            assert exact(prices, 'spill') == raw_spill * scale
            body += raw_body * scale
            spill += raw_spill * scale
        assert exact(row, 'mir_body') == body
        assert exact(row, 'mir_spill') == spill
        expected = body - spill + (row['estimated_total_spill_quarters'] if estimated else exact(row, 'normalized_spill'))
    else:
        expected = row['profile_body_quarters']
        if not estimated:
            if row.get('role') != 'scalar-baseline':
                expected -= row['estimated_total_spill_quarters']
            expected += exact(row, 'normalized_spill')
        else:
            assert 'observation' not in row
    if not estimated:
        loops = row['observation']['spill_observation']['loops']
        prices = row.get('mir_loops' if mir else 'spill_loops', loops)
        ids = {p['id'] for p in prices}
        loops = [loop for loop in loops if loop['id'] in ids]
        # Native RISC-V charges g per access, including D=2 and scalar bodies.
        observed = sum(Fraction(4 * row['tti_width'] *
                                sum(a['register_group'] for a in loop['spills']),
                                loop['iteration_width'] * len(loops))
                       for loop in loops)
        assert exact(row, 'normalized_spill') == observed
    assert exact(row, 'body') == expected, row


def pipeline():
    forced = ['-force-vector-width=4', '-vplan-backend-force-all']
    _, zero, _ = run('zero', forced)
    observed = [r['observation'] for r in candidates(zero)]
    assert observed
    for obs in observed:
        assert obs['observation_schema'] == 'backedge-loop-observations-v5'
        assert obs['spill_observation']['schema'] == 'register-spill-v6'
        assert obs['spill_observation']['status'] == 'succeeded'
        assert all(not loop['spills'] for loop in obs['spill_observation']['loops'])
        assert obs['mir_observation']['status'] == 'not_requested'
    path = pressure()
    # Four observable cost compositions, all using native TTI.
    for label, mir, estimated in [('real', False, False),
                                  ('estimated', False, True),
                                  ('mir', True, False),
                                  ('mir-estimated', True, True)]:
        flags = forced + [f'-use-mir={str(mir).lower()}',
                          f'-use-estimated-spill={str(estimated).lower()}']
        _, rows, _ = run(label, flags, path)
        scored = candidates(rows)
        assert scored and not fell_back(rows), rows
        for row in scored:
            check_formula(row, mir, estimated)
            assert row['tti_profile'] == 'native'
        if mir or not estimated:
            scalar = [r for r in scored if r.get('role') == 'scalar-baseline']
            assert len(scalar) == 1 and scalar[0]['tti_width'] == 1
            vectors = [r for r in scored if r.get('role') != 'scalar-baseline']
            assert all(exact(r, 'scalar') == exact(scalar[0], 'body') for r in vectors)
            if mir:
                assert all(r['mir_model'] == 'riscv-generic-mirinfo-v1' for r in scored)
            assert all(r['observation']['spill_observation']['status'] == 'succeeded'
                       for r in scored)
        elif not estimated:
            assert any(loop['spills'] for r in scored
                       for loop in r['observation']['spill_observation']['loops'])
    # Saturn uses the same generic services with its own native geometry.
    saturn = root / 'saturn-input.ll'
    saturn.write_text(path.read_text().replace(
        'vscale_range(2,2)',
        'vscale_range(4,4) "tune-cpu"="saturn-shuttle-v256d128"'))
    _, rows, _ = run('saturn', forced + ['-use-mir', '-mcpu=generic-rv64',
                                       '-mattr=+v,+d,+f'], saturn)
    scored = candidates(rows)
    assert scored and not fell_back(rows), rows
    for row in scored:
        assert row['tti_profile'] == 'native'
        assert row['mir_model'] == 'riscv-generic-mirinfo-v1'
        check_formula(row, True, False)
    # MIR estimated remains valid when the independent spill slot is unavailable.
    _, rows, _ = run('spill-unavailable', forced + ['-use-mir', '-use-estimated-spill', '-disable-ssc'])
    for row in candidates(rows):
        obs = row['observation']
        assert obs['spill_observation']['status'] == 'failed'
        assert obs['mir_observation']['status'] == 'succeeded'
    assert candidates(rows) and not fell_back(rows)
    # A failed independent spill slot is reported even though MIR succeeds.
    ledger, = failures(rows)
    assert ledger['requested_model'] == ledger['effective_model'] == 'mir-me-spill-v2'
    assert ledger['attempts'][0]['status'] == 'succeeded'
    assert any(g['id'] == 'availability' for g in ledger['attempts'][0]['failures'])


def selection():
    forced = ['-force-vector-width=4', '-vplan-backend-force-all']
    native, rows, _ = run('native', ['-vplan-backend=false'])
    off, disabled, text = run('master-off', ['-vplan-backend=false', '-use-mir',
                              '-use-estimated-spill', '-vplan-backend-time'])
    assert off == native and not rows and not disabled and not text
    # An externally restricted pipeline makes every required probe unavailable.
    for label, flags, expected in [
            ('mir-real', ['-use-mir'], ['mir-v2', 'llvm-real-spill-v2', 'llvm-v1']),
            ('mir-est', ['-use-mir', '-use-estimated-spill'], ['mir-me-spill-v2', 'llvm-v1']),
            ('real', [], ['llvm-real-spill-v2', 'llvm-v1'])]:
        _, rows, report = run(label, forced + flags + [
                            '-stop-before=prologepilog', '-print-detailed-vplans'])
        fallback, = failures(rows)
        assert fallback['schema'] == 'vplan-backend-failures-v1'
        assert fallback['requested_model'] == expected[0]
        assert fallback['effective_model'] == 'llvm-v1' and fell_back(rows)
        assert [a['model'] for a in fallback['attempts']] == expected
        assert [a['status'] for a in fallback['attempts']] == (
            ['failed'] * (len(expected) - 1) + ['succeeded'])
        assert not any(r.get('role') == 'scalar-baseline' for r in rows)
        assert all(r['model'] == 'llvm-v1' for r in candidates(rows))
        assert 'backend-scalar source=mir' not in report
        if label == 'mir-real':
            # Unavailable slots are uncollected, never observed zero.
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
             '-vplan-backend-force-all']
    for trips in (64, 16):
        path = root / f'trips-{trips}.ll'
        path.write_text(source.read_text().replace('%next, 64', f'%next, {trips}'))
        _, rows, _ = run(f'{trips}-mapped', flags, path)
        # Required finite regions must reject observation, preserving the
        # existing whole-loop fallback rather than inventing a zero body.
        attempts = [attempt for row in rows for attempt in row.get('attempts', [])]
        observed = [obs['spill_observation'] for attempt in attempts
                    for obs in attempt.get('observations', [])]
        assert observed, rows
        assert any(o['status'] == 'failed' for o in observed), rows
        assert any(group['id'] in ('availability', 'tracking')
                   for row in failures(rows) for attempt in row['attempts']
                   for group in attempt['failures']), rows
        assert fell_back(rows), rows
    # Upstream instrumentation remains independent of body membership.
    path = root / 'instrumented-input.ll'
    text = (source.parent / 'backend-pipeline.ll').read_text()
    text = text.replace('  %p = getelementptr',
        '  call void @llvm.pseudoprobe(i64 7, i64 1, i32 0, i64 -1)\n  %p = getelementptr')
    text += '\ndeclare void @llvm.pseudoprobe(i64, i64, i32, i64)\n'
    path.write_text(text)
    ir, rows, _ = run('instrumented', ['-scalable-vectorization=off', '-force-vector-width=4',
                      '-vplan-backend-force-all'], path, user_probes=True)
    observed = [r['observation']['spill_observation'] for r in candidates(rows)]
    assert observed and all(o['status'] == 'succeeded' for o in observed)
    assert all(o['mapping_kind'] == 'backedge-loops' for o in observed)
    assert all('i64 7, i64 1' in line for line in ir.splitlines()
               if 'call void @llvm.pseudoprobe' in line)


def execution():
    off_ir, all_rows, _ = run('all', ['-vplan-backend-force-all'])
    ir, rows, _ = run('gate', [])
    assert ir == off_ir
    assert any(r['status'] == 'collected' for r in rows)
    assert any(r['status'] == 'pruned' for r in rows)
    assert not fell_back(rows)
    assert any(r.get('register_usage_bound', {}).get('would_skip') and
               r['register_usage_bound']['queried'] and
               not r['register_usage_bound']['enabled'] for r in rows)
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
    assert traces and all(not t['applied'] for t in traces)
    _, rows, trace = run('mir-cfg', flags + ['-use-mir'], path)
    traces = [json.loads(line.split(': ', 1)[1]) for line in trace.splitlines()
              if line.startswith('VPLAN-BACKEND-PRUNING: ')]
    assert traces and all(not t['applied'] for t in traces)


{'pipeline': pipeline, 'selection': selection, 'scopes': scopes, 'execution': execution}[suite]()
print(f'{suite}: {len(commands)} compiler invocations')
