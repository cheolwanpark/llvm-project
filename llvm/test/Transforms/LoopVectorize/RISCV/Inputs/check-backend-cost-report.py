"""Check passive text/JSON reporting against the costs actually used by opt."""
import json
from fractions import Fraction
from pathlib import Path
import re
import subprocess
import sys

opt, source, directory = sys.argv[1:4]
spills = len(sys.argv) > 4
root = Path(directory)
root.mkdir(parents=True, exist_ok=True)
common = [opt, '-codegen-opt-level=2', '-mtriple=riscv64', '-mattr=+v',
          '-mcpu=' + ('generic-rv64' if spills else 'xiangshan-kunminghu'),
          '-scalable-vectorization=always', '-force-vector-interleave=1',
          '-enable-epilogue-vectorization=false', '-disable-loop-unrolling',
          '-riscv-v-register-bit-width-lmul=8', '-passes=loop-vectorize',
          source, '-S', '-o', '-']


def run(name, extra):
    path = root / (name + '.jsonl')
    path.unlink(missing_ok=True)
    result = subprocess.run(common + extra + ['-vplan-backend-jsonl=' + str(path)],
                            capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, (name, result.stderr)
    rows = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    (root / (name + '.stderr')).write_text(result.stderr)
    return result.stdout, result.stderr, rows


native_reports = []
outputs = {}
observations = {}
for scenario, options in [
        ('native', []),
        ('force', ['-vplan-backend', '-vplan-backend-force-all']),
        ('gate', ['-vplan-backend']),
        ('fallback', ['-vplan-backend', '-vplan-backend-force-all',
                      '-riscv-rvv-regalloc=fast'])]:
    reference = None
    for mode, prints in enumerate([[], ['-print-vplans'], ['-print-detailed-vplans'],
                                  ['-print-vplans', '-print-detailed-vplans']]):
        ir, report, rows = run(scenario + str(mode), options + prints)
        if reference is None:
            reference = ir, rows
            assert not report, report
        else:
            assert (ir, rows) == reference, (scenario, mode, 'print changed output or observations')
        if scenario == 'native':
            assert not rows
            native_reports.append(report)
        elif scenario == 'fallback':
            if spills:  # Generic TTI has no specific profile to retry.
                assert ir == outputs['native']
                assert report == native_reports[mode]
                assert any(r['status'] == 'native-fallback' for r in rows)
                assert not any('candidate' in r for r in rows)
            else:
                assert any(r['status'] == 'estimated-fallback' for r in rows)
                candidates = [r for r in rows if 'candidate' in r]
                assert candidates and all(r['model'] == 'tti-v1' for r in candidates)
                for r in candidates:
                    assert r['cost_source'] == 'estimated'
                    assert not r['register_usage_bound']['queried']
                    assert 'observation' not in r
                    assert 'raw_vector_spill_quarters' not in r
                    assert r['body_quarters_denominator'] == 1
                    assert r['body_quarters_numerator'] == r['profile_body_quarters']
                if mode:
                    assert 'model=tti-real-vector-spill-v1' not in report
                    if mode & 2:
                        assert 'B=L=' in report and 'spill_source=estimated' in report
                        assert 'B=L-Ev+Sv=' not in report
            for workers in (2, 4):
                other = run(f'fallback-{mode}-{workers}', options + prints +
                            [f'-vplan-backend-probe-threads={workers}'])
                assert other == (ir, report, rows)
        else:
            assert not any(r['status'] == 'native-fallback' for r in rows), rows
            candidates = [r for r in rows if 'candidate' in r]
            assert candidates
            if mode:
                # Internal clone compilation must not create extra loop reports.
                assert report.count('VPlan report_version=') == native_reports[mode].count('VPlan report_version=')
                sections = re.split(r'(?=VPlan report_version=)', report)[1:]
                for row in candidates:
                    section = next(s for s in sections if
                                   f" function={row['function']} loop={row['loop']} " in s.splitlines()[0])
                    vf = ('s' if row['scalable'] else 'f') + str(row['vf'])
                    if row['status'] == 'pruned':
                        table = next(line for line in section.splitlines()
                                     if line.lstrip().startswith(row['role'] + ' | ')
                                     and f' | {vf} | ' in line)
                        assert 'backend-lower-bound' in table
                        assert not any(line.startswith('  backend-cost ')
                                       and f' vf={vf} ' in line
                                       for line in section.splitlines())
                        continue
                    line = next(line for line in section.splitlines()
                                if line.startswith('  backend-cost ')
                                and f"phase={row['role']} " in line
                                and f' vf={vf} ' in line)
                    body = Fraction(row['body_quarters_numerator'], 4 * row['body_quarters_denominator'])
                    assert Fraction(line.split(' body_cost=')[1]) == body, (line, row)
                    assert f" ic={row['ic']} " in line
                    assert f" queried={int(row['register_usage_bound']['queried'])} " in line
                    table = next(line.split(' | ') for line in section.splitlines()
                                 if line.lstrip().startswith(row['role'] + ' | ')
                                 and f' | {vf} | ' in line)
                    assert Fraction(table[4]) == body
                    if table[6] == 'cost-per-lane':
                        assert Fraction(table[5]) == body / int(table[3])
                if mode & 2:
                    assert 'B=L-Ev+Sv=' in report
                    if any(r['status'] == 'skipped' for r in candidates):
                        assert 'spill_source=gate-skip Sv=0 (not measured)' in report
                    if spills:
                        assert 'vector-spill direction=load' in report
                        assert 'vector-spill direction=store' in report
        outputs[scenario] = ir
    observations[scenario] = reference[1]
    if scenario == 'force':
        timed_ir, timing, timed_rows = run('timed', options + ['-vplan-backend-time'])
        assert (timed_ir, timed_rows) == reference
        assert 'VPLAN-BACKEND-FEEDBACK-TIMING:' in timing
        assert 'late_cleanup' not in timing
    if scenario == 'gate' and not spills:
        assert any(r['status'] == 'skipped' for r in reference[1])

ir, text, rows = run('master-off', ['-vplan-backend-force-all', '-vplan-backend-time'])
assert ir == outputs['native'] and not text and not rows
assert outputs['gate'] == outputs['force']
if spills:
    # Preserve the selection regression formerly covered by the external suite:
    # actual spills change VF even when no XiangShan TTI correction applies.
    assert re.search(r'selected-for-main plan=\d+ vf=s1\n', native_reports[1])
    rows = observations['gate']
    selected = next(r for r in rows if r['status'] == 'selected')
    assert selected['vf'] == 2 and selected['scalable']
    candidates = [r for r in rows if 'candidate' in r and r['status'] != 'pruned']
    assert all(r['tti_profile'] == 'native' for r in candidates)
    assert all(r['native_body_quarters'] == r['profile_body_quarters'] for r in candidates)
    chosen = next(r for r in candidates if r['vf'] == 2)
    assert chosen['raw_vector_spill_quarters'] > 0

help_text = subprocess.run([opt, '--help-hidden'], capture_output=True, text=True, check=True).stdout
removed = ['enable-vplan-backend-feedback', 'print-vplan-backend-feedback',
           'enable-vplan-backend-cost-model', 'vplan-backend-feedback-force-all',
           'vplan-backend-feedback-output', 'time-vplan-backend-feedback',
           'vplan-backend-feedback-late-cleanup', 'vplan-pipeline', 'vplan-ra-run-id',
           'vplan-candidates-output', 'vplan-probe-candidate', 'vplan-selection-input',
           'vplan-analytics-output', 'riscv-vplan-analytics']
for flag in removed:
    assert not re.search(r'^\s+--' + flag + r'(?:[ =]|$)', help_text, re.M), flag
for flag in ['vplan-backend', 'vplan-backend-force-all',
             'vplan-backend-jsonl', 'vplan-backend-time',
             'print-vplans', 'print-detailed-vplans', 'enable-vplan-native-path',
             'vplan-build-outerloop-stress-test', 'vplan-verify-each', 'vplan-print-after-all']:
    assert re.search(r'^\s+--' + flag + r'(?:[ =]|$)', help_text, re.M), flag
