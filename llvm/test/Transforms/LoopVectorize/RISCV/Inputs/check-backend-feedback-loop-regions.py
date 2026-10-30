# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
"""Region probe reduction must preserve complete, ordered candidate reports."""
import json
from pathlib import Path
import subprocess
import sys

opt, temporary = sys.argv[1:]
root = Path(temporary)
root.mkdir(parents=True, exist_ok=True)
common = [opt, '-codegen-opt-level=2', '-mtriple=riscv64',
          '-mcpu=xiangshan-kunminghu', '-mattr=+v',
          '-riscv-v-register-bit-width-lmul=8', '-disable-loop-unrolling',
          '-passes=loop-vectorize', '-verify-each', '-verify-machineinstrs']
force = ['-scalable-vectorization=always', '-force-vector-interleave=1',
         '-enable-epilogue-vectorization=false', '-vplan-backend-force-all']


def body(tag, count, reduction=False):
    lines = [tag + '.entry:', f' br label %{tag}.loop', tag + '.loop:',
             f' %{tag}.i = phi i64 [ 0, %{tag}.entry ], [ %{tag}.next, %{tag}.loop ]']
    if reduction:
        for j in range(count):
            lines.append(f' %{tag}.sum{j} = phi double [ 0.0, %{tag}.entry ], '
                         f'[ %{tag}.r{j}, %{tag}.loop ]')
    for j in range(count):
        lines += [f' %{tag}.idx{j} = add i64 %{tag}.i, {j*1024}',
                  f' %{tag}.p{j} = getelementptr double, ptr %a, i64 %{tag}.idx{j}',
                  f' %{tag}.v{j} = load double, ptr %{tag}.p{j}, align 8']
    for j in range(count):
        if reduction:
            lines.append(f' %{tag}.r{j} = fadd fast double %{tag}.sum{j}, %{tag}.v{j}')
        else:
            lines += [f' %{tag}.m{j} = fmul fast double %{tag}.v{j}, %{tag}.v{(j+1)%count}',
                      f' %{tag}.r{j} = fadd fast double %{tag}.m{j}, %{tag}.v{(j+count//2)%count}',
                      f' %{tag}.d{j} = getelementptr double, ptr %out, i64 %{tag}.idx{j}',
                      f' store double %{tag}.r{j}, ptr %{tag}.d{j}, align 8']
    lines += [f' %{tag}.next = add nuw i64 %{tag}.i, 1',
              f' %{tag}.done = icmp eq i64 %{tag}.next, %n',
              f' br i1 %{tag}.done, label %{tag}.exit, label %{tag}.loop',
              tag + '.exit:']
    if reduction:
        for j in range(count):
            lines += [f' %{tag}.d{j} = getelementptr double, ptr %out, i64 {j}',
                      f' store double %{tag}.r{j}, ptr %{tag}.d{j}, align 8']
    return '\n'.join(lines + [' ret void']) + '\n'


def source(left=12, right=24, reduction=False):
    return ('define void @maps(ptr noalias %a, ptr noalias %out, i64 %n, '
            'i1 %choose) vscale_range(2,2) {\nentry:\n'
            ' br i1 %choose, label %left.entry, label %right.entry\n'
            + body('left', left, reduction) + body('right', right, reduction) + '}\n')


def run(name, path, enabled, flags=force, threads=1, master=True, trace=True):
    feedback = root / (name + '.jsonl')
    feedback.unlink(missing_ok=True)
    output = root / (name + '.ll')
    args = common + flags + [str(path), '-S', '-o', str(output),
            f'-vplan-backend-probe-threads={threads}', '-vplan-backend-jsonl=' + str(feedback)]
    if enabled is not None:
        args.append('-vplan-backend-prune-cfg=' + str(enabled).lower())
    if master:
        args.append('-vplan-backend')
    if trace:
        args.append('-vplan-backend-pruning-trace')
    result = subprocess.run(args, capture_output=True, text=True, timeout=120)
    (root / (name + '.stderr')).write_text(result.stderr)
    assert result.returncode == 0, (args, result.stderr)
    rows = [json.loads(s) for s in feedback.read_text().splitlines()] if feedback.exists() else []
    traces = [json.loads(s.split(': ', 1)[1]) for s in result.stderr.splitlines()
              if s.startswith('VPLAN-BACKEND-PRUNING: ')]
    diagnostics = ''.join(s for s in result.stderr.splitlines(keepends=True)
                          if not s.startswith('VPLAN-BACKEND-PRUNING: '))
    return output.read_text(), rows, traces, diagnostics


# A scalar prefix and vector reduction share an enclosing cycle.
shared_cycle = """define void @pressure(ptr noalias %a, ptr noalias %out, i64 %n) vscale_range(2,2) {
entry:
  br label %outer
outer:
  %oi = phi i64 [ 0, %entry ], [ %on, %exit ]
  br label %prefix
prefix:
  %pi = phi i64 [ 0, %outer ], [ %pn, %prefix ]
  %d0 = phi i8 [ 1, %outer ], [ %dn0, %prefix ]
  %d1 = phi i8 [ 2, %outer ], [ %dn1, %prefix ]
  %d2 = phi i8 [ 3, %outer ], [ %dn2, %prefix ]
  %d3 = phi i8 [ 4, %outer ], [ %dn3, %prefix ]
  %dn0 = xor i8 %d0, %d1
  %dn1 = xor i8 %d1, %d2
  %dn2 = xor i8 %d2, %d3
  %dn3 = xor i8 %d3, %d0
  %pn = add nuw i64 %pi, 1
  %pd = icmp eq i64 %pn, %n
  br i1 %pd, label %preheader, label %prefix
preheader:
  br label %loop
loop:
  %iv = phi i64 [ 0, %preheader ], [ %next, %loop ]
  %s0 = phi double [ 0.0, %preheader ], [ %r0, %loop ]
  %s1 = phi double [ 0.0, %preheader ], [ %r1, %loop ]
  %s2 = phi double [ 0.0, %preheader ], [ %r2, %loop ]
  %s3 = phi double [ 0.0, %preheader ], [ %r3, %loop ]
  %s4 = phi double [ 0.0, %preheader ], [ %r4, %loop ]
  %s5 = phi double [ 0.0, %preheader ], [ %r5, %loop ]
  %s6 = phi double [ 0.0, %preheader ], [ %r6, %loop ]
  %s7 = phi double [ 0.0, %preheader ], [ %r7, %loop ]
  %s8 = phi double [ 0.0, %preheader ], [ %r8, %loop ]
  %s9 = phi double [ 0.0, %preheader ], [ %r9, %loop ]
  %s10 = phi double [ 0.0, %preheader ], [ %r10, %loop ]
  %s11 = phi double [ 0.0, %preheader ], [ %r11, %loop ]
  %j0 = add i64 %iv, 0
  %p0 = getelementptr double, ptr %a, i64 %j0
  %v0 = load double, ptr %p0, align 8
  %r0 = fadd fast double %s0, %v0
  %j1 = add i64 %iv, 1024
  %p1 = getelementptr double, ptr %a, i64 %j1
  %v1 = load double, ptr %p1, align 8
  %r1 = fadd fast double %s1, %v1
  %j2 = add i64 %iv, 2048
  %p2 = getelementptr double, ptr %a, i64 %j2
  %v2 = load double, ptr %p2, align 8
  %r2 = fadd fast double %s2, %v2
  %j3 = add i64 %iv, 3072
  %p3 = getelementptr double, ptr %a, i64 %j3
  %v3 = load double, ptr %p3, align 8
  %r3 = fadd fast double %s3, %v3
  %j4 = add i64 %iv, 4096
  %p4 = getelementptr double, ptr %a, i64 %j4
  %v4 = load double, ptr %p4, align 8
  %r4 = fadd fast double %s4, %v4
  %j5 = add i64 %iv, 5120
  %p5 = getelementptr double, ptr %a, i64 %j5
  %v5 = load double, ptr %p5, align 8
  %r5 = fadd fast double %s5, %v5
  %j6 = add i64 %iv, 6144
  %p6 = getelementptr double, ptr %a, i64 %j6
  %v6 = load double, ptr %p6, align 8
  %r6 = fadd fast double %s6, %v6
  %j7 = add i64 %iv, 7168
  %p7 = getelementptr double, ptr %a, i64 %j7
  %v7 = load double, ptr %p7, align 8
  %r7 = fadd fast double %s7, %v7
  %j8 = add i64 %iv, 8192
  %p8 = getelementptr double, ptr %a, i64 %j8
  %v8 = load double, ptr %p8, align 8
  %r8 = fadd fast double %s8, %v8
  %j9 = add i64 %iv, 9216
  %p9 = getelementptr double, ptr %a, i64 %j9
  %v9 = load double, ptr %p9, align 8
  %r9 = fadd fast double %s9, %v9
  %j10 = add i64 %iv, 10240
  %p10 = getelementptr double, ptr %a, i64 %j10
  %v10 = load double, ptr %p10, align 8
  %r10 = fadd fast double %s10, %v10
  %j11 = add i64 %iv, 11264
  %p11 = getelementptr double, ptr %a, i64 %j11
  %v11 = load double, ptr %p11, align 8
  %r11 = fadd fast double %s11, %v11
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %dst0 = getelementptr double, ptr %out, i64 0
  store double %r0, ptr %dst0, align 8
  %dst1 = getelementptr double, ptr %out, i64 1
  store double %r1, ptr %dst1, align 8
  %dst2 = getelementptr double, ptr %out, i64 2
  store double %r2, ptr %dst2, align 8
  %dst3 = getelementptr double, ptr %out, i64 3
  store double %r3, ptr %dst3, align 8
  %dst4 = getelementptr double, ptr %out, i64 4
  store double %r4, ptr %dst4, align 8
  %dst5 = getelementptr double, ptr %out, i64 5
  store double %r5, ptr %dst5, align 8
  %dst6 = getelementptr double, ptr %out, i64 6
  store double %r6, ptr %dst6, align 8
  %dst7 = getelementptr double, ptr %out, i64 7
  store double %r7, ptr %dst7, align 8
  %dst8 = getelementptr double, ptr %out, i64 8
  store double %r8, ptr %dst8, align 8
  %dst9 = getelementptr double, ptr %out, i64 9
  store double %r9, ptr %dst9, align 8
  %dst10 = getelementptr double, ptr %out, i64 10
  store double %r10, ptr %dst10, align 8
  %dst11 = getelementptr double, ptr %out, i64 11
  store double %r11, ptr %dst11, align 8
  %on = add nuw i64 %oi, 1
  %od = icmp eq i64 %on, 16
  br i1 %od, label %return, label %outer
return:
  ret void
}
"""

normal = source()
shared = normal.replace(' ret void', ' br label %common.exit')
shared = shared[:shared.rindex('}')] + 'common.exit:\n ret void\n}\n'
prefix = (' %pv = load <16 x double>, ptr %a, align 8\n'
          ' %pm = fmul <16 x double> %pv, %pv\n'
          ' store <16 x double> %pm, ptr %out, align 8\n')
# A vector operation in the surrounding cycle must also veto pruning even
# when the selected loop has no vector live-out.
cyclic = shared.replace('entry:\n',
    'entry:\n br label %outer\nouter:\n'
    ' %oi = phi i64 [ 0, %entry ], [ %on, %common.exit ]\n' + prefix, 1)
cyclic = cyclic.replace(' ret void',
    ' %on = add i64 %oi, 1\n %od = icmp eq i64 %on, 16\n'
    ' br i1 %od, label %return, label %outer\nreturn:\n ret void')
variants = {
    'maps': (normal, True),
    'shared-cycle': (shared_cycle, False),
    'cyclic-vector-context': (cyclic, False),
    'shared-exit': (shared, True),
    'scalar-phi-consumer': (shared.replace('common.exit:\n',
        'common.exit:\n %last = phi i64 [ %left.next, %left.exit ], '
        '[ %right.next, %right.exit ]\n store i64 %last, ptr %out\n'), True),
    'nonvoid-return': (shared.replace('define void @maps', 'define i64 @maps')
                      .replace(' ret void', ' ret i64 %n'), True),
    'alias-guard': (normal.replace('ptr noalias', 'ptr'), True),
    'call-consumer': (normal.replace(' ret void', ' call void @consume(ptr %out)\n ret void')
                      + 'declare void @consume(ptr)\n', True),
    'independent-vector-prefix': (normal.replace('entry:\n', 'entry:\n' + prefix, 1), True),
    'independent-vector-suffix': (shared.replace('common.exit:\n', 'common.exit:\n' + prefix), True),
    'vector-live-through': (shared.replace('entry:\n',
        'entry:\n %through = load <16 x double>, ptr %a, align 8\n', 1)
        .replace('common.exit:\n', 'common.exit:\n store <16 x double> %through, ptr %out\n'), False),
    'vector-argument': (normal.replace('i1 %choose)', 'i1 %choose, <16 x double> %through)')
                       .replace(' ret void', ' store <16 x double> %through, ptr %out\n ret void'), False),
    # Exit-store merging can change reduction live ranges and spills.
    'reduction-live-out': (source(2, 7, reduction=True), False),
}
for kind in ['constant', 'argument', 'unknown', 'ambiguous']:
    text = normal.replace('define void @maps', 'define i64 @maps').replace(
        'i1 %choose)', 'i1 %choose, i1 %fail, i1 %maybe)')
    text = text.replace('entry:\n br i1',
        'entry:\n br i1 %fail, label %error, label %dispatch\n'
        'error:\n br label %done\ndispatch:\n br i1', 1)
    text = text.replace(' ret void', ' br label %done')
    left = right = '1'
    if kind == 'argument':
        left = right = '%n'
    if kind == 'unknown':
        right = '%right.next'
    text = text[:text.rindex('}')] + ('done:\n %result = phi i64 [ 0, %error ], '
        f'[ {left}, %left.exit ], [ {right}, %right.exit ]\n ret i64 %result\n}}\n')
    if kind == 'ambiguous':
        text = text.replace('right.exit:\n br label %done',
            'right.exit:\n br i1 %maybe, label %done, label %error')
    variants['return-phi-' + kind] = text, True

for feasible in [False, True]:
    guard = (' %shifted = add i64 %depth, -8\n'
             ' %rotated = call i64 @llvm.fshl.i64(i64 %shifted, i64 %shifted, i64 63)\n'
             ' switch i64 %rotated, label %right.entry [ i64 1, label %guard ]\n'
             'guard:\n %positive = icmp sgt i64 %depth, 0\n')
    guard += (' br i1 %positive, label %left.entry, label %right.entry\n' if feasible else
              ' br i1 %positive, label %right.entry, label %left.entry\n')
    text = normal.replace('i1 %choose)', 'i1 %choose, i64 %depth)').replace(
        ' br i1 %choose, label %left.entry, label %right.entry\n', guard)
    variants['switch-' + str(feasible)] = (text + 'declare i64 @llvm.fshl.i64(i64, i64, i64)\n', True)

paths, results = {}, {}
for name, (text, applies) in variants.items():
    path = root / (name + '-input.ll')
    path.write_text(text)
    paths[name] = path
    off = run(name + '-off', path, False)
    on = run(name + '-on', path, True)
    assert off[:2] == on[:2], (name, 'output or complete candidate stream changed')
    assert off[1] and off[2], name
    assert all(not t['applied'] for t in off[2]), name
    assert any(t['applied'] for t in on[2]) == applies, name
    if applies:
        assert any(b['suffix'] < a['suffix'] for a, b in zip(off[2], on[2])), name
        assert any(r['status'] == 'collected' and r['observation']['spills'] for r in on[1]), name
    results[name] = off, on

assert any(t['reason'] == 'infeasible-switch-guard' for t in results['switch-False'][1][2])
assert not any(t['reason'] == 'infeasible-switch-guard' for t in results['switch-True'][1][2])
assert {t['reason'] for t in results['vector-live-through'][1][2]} == {'vector-live-through-context'}
assert {t['reason'] for t in results['reduction-live-out'][1][2]} == {'vector-region-live-out'}

assert {t['reason'] for t in results['cyclic-vector-context'][1][2]} == {'cyclic-vector-context'}

assert run('default-on', paths['maps'], None) == results['maps'][1]
assert run('parallel', paths['maps'], True, threads=4) == results['maps'][1]
quiet = run('trace-disabled', paths['maps'], True, trace=False)
assert quiet[:2] == results['maps'][1][:2] and not quiet[2]

for label, extra in [('summary', ['-print-vplans']), ('detailed', ['-print-detailed-vplans']),
                     ('failure', ['-disable-ssc', '-print-detailed-vplans'])]:
    off = run(label + '-off', paths['maps'], False, force + extra)
    on = run(label + '-on', paths['maps'], True, force + extra)
    assert off[:2] == on[:2] and off[3] == on[3], label
    if label == 'failure':
        assert any(r['status'] == 'estimated-fallback' for r in on[1])
        assert all(r['model'] == 'tti-v1' for r in on[1])
        assert 'B=L=' in on[3] and 'B=L-Ev+Sv=' not in on[3]
    else:
        assert on[:3] == results['maps'][1][:3] and 'backend-cost' in on[3]

# Offset stores in the pressure fixture bound safe widths and cap IC at one.
# A single independent store stream exercises actual IC > 1 and epilogues.
interleavepath = root / 'interleave-input.ll'
interleavepath.write_text(source(1, 1))
ic2 = ['-scalable-vectorization=off', '-force-vector-interleave=2',
       '-enable-epilogue-vectorization=false', '-vplan-backend-force-all']
off = run('ic2-off', interleavepath, False, ic2)
on = run('ic2-on', interleavepath, True, ic2)
assert off[:2] == on[:2] and any(t['applied'] for t in on[2])
assert any(r['status'] == 'selected' and r['ic'] == 2 for r in on[1])

epilogue = ['-force-vector-interleave=4', '-scalable-vectorization=off',
            '-epilogue-vectorization-force-VF=2', '-vplan-backend-force-all']
off = run('epilogue-off', interleavepath, False, epilogue)
on = run('epilogue-on', interleavepath, True, epilogue)
assert off[:2] == on[:2]
assert any(r['status'] == 'selected' and r['epilogue_vf'] == 2 for r in on[1])

gatepath = root / 'gate-input.ll'
gatepath.write_text((Path(__file__).resolve().parent.parent /
                     'backend-feedback.ll').read_text())
gateflags = [x for x in force if x != '-vplan-backend-force-all']
off = run('gate-off', gatepath, False, gateflags)
on = run('gate-on', gatepath, True, gateflags)
assert off[:2] == on[:2] and any(r['status'] == 'skipped' for r in on[1])

off = run('master-off', paths['maps'], False, master=False)
on = run('master-on', paths['maps'], True, master=False)
assert off == on and not on[1] and not on[2]

# CFG control does not disable automatic cost-bound pruning.
candidate_source = Path(__file__).resolve().parent.parent / 'backend-feedback-candidate-pruning.ll'
for enabled in (False, True):
    _, rows, _, _ = run('automatic-' + str(enabled), candidate_source, enabled, gateflags)
    assert any(r['status'] == 'pruned' for r in rows)
