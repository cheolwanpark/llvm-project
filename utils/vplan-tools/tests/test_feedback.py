"""Direct compiler feedback: Python is only an offline contract consumer here."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest

from cost_model import score_observation
from feedback_comparison import compare_collection, read_feedback
from observations import validate_observation
import vplan_tools as vt

CLANG = os.environ.get('VPLAN_CLANG')


@unittest.skipUnless(CLANG, 'set VPLAN_CLANG to run compiler integration')
class BackendFeedbackIntegration(unittest.TestCase):
    def check_feedback(self, source, extra_flags=(), comparison_check=None):
        with vt.temporary_directory() as td:
            p = Path(td)
            src = p / 'kernel.c'
            src.write_text(source)
            flags = [str(Path(CLANG).resolve()), '--target=riscv64-unknown-elf',
                     '-march=rv64gcv', '-mcpu=xiangshan-kunminghu',
                     '-mrvv-vector-bits=128', '-O3', '-fno-unroll-loops',
                     '-fno-slp-vectorize', '-mllvm', '-scalable-vectorization=always',
                     '-mllvm', '-force-vector-interleave=1', '-mllvm',
                     '-enable-epilogue-vectorization=false', '-mllvm',
                     '-riscv-v-register-bit-width-lmul=8', *extra_flags]
            for name, extra in [
                ('base', []),
                ('feedback', ['-mllvm', '-enable-vplan-backend-cost-model',
                              '-mllvm', '-vplan-backend-feedback-force-all',
                              '-mllvm', '-print-vplan-backend-feedback', '-mllvm',
                              '-vplan-backend-feedback-output=' + str(p / 'facts.jsonl')]),
                ('memory', ['-mllvm', '-enable-vplan-backend-cost-model',
                            '-mllvm', '-vplan-backend-feedback-force-all']),
            ]:
                result = subprocess.run(flags + extra + ['-S', str(src), '-o', str(p / (name + '.s'))],
                                        capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stderr)
                (p / (name + '.stderr')).write_text(result.stderr)
            self.assertEqual((p / 'feedback.s').read_bytes(), (p / 'memory.s').read_bytes())
            rows = read_feedback(p / 'facts.jsonl')
            self.assertEqual(read_feedback(p / 'feedback.stderr'), rows)
            self.assertGreaterEqual(len({r['vf'] for r in rows if r['scalable']}), 3)
            self.assertEqual(len({r['candidate'] for r in rows}), len(rows))
            for row in rows:
                self.assertEqual(row['status'], 'collected', row)
                observation = validate_observation(row['observation'])
                self.assertEqual(observation['candidate'], row['candidate'])
                self.assertEqual(observation['feedback_pipeline'], 'vector-suffix-O3')
                self.assertEqual(observation['error'], '')
                report = score_observation(observation)
                self.assertEqual(report['candidate'], row['candidate'])
                self.assertEqual(report['iteration_width'], observation['iteration_width'])
            root = Path(__file__).resolve().parents[3]
            result = subprocess.run(
                [sys.executable, str(root / 'utils/vplan-meta-compile'), '--clang', flags[0],
                 '--input', str(src), '--work-dir', str(p / 'backend'), '--analytics-only',
                 '--stop-after-ra', '--', *flags[1:]],
                capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stderr)
            comparison = compare_collection(p / 'feedback.stderr', p / 'backend')
            if comparison_check is None:
                self.assertTrue(comparison['all_equal'], comparison)
            else:
                comparison_check(comparison)
            self.assertEqual(comparison['compared'], len(rows))
            self.assertTrue(all(r['scores_equal'] for r in comparison['candidates']))
            # Missing output must not silently shrink the compared population.
            (p / 'missing.jsonl').write_text('\n'.join(json.dumps(r) for r in rows[1:]))
            missing = compare_collection(p / 'missing.jsonl', p / 'backend')
            self.assertFalse(missing['all_equal'])
            self.assertFalse(missing['population_equal'])
            self.assertEqual(missing['unavailable_or_missing'], 1)
            (p / 'empty.jsonl').write_text('')
            empty = compare_collection(p / 'empty.jsonl', p / 'backend')
            self.assertFalse(empty['all_equal'])
            self.assertFalse(empty['population_equal'])
            self.assertEqual(empty['middle_end_candidates'], 0)
            self.assertEqual(empty['unavailable_or_missing'], len(rows))
            self.assertTrue(all(r['status'] == 'missing-candidate'
                                and r['missing'] == 'middle_end'
                                for r in empty['candidates']))
            return rows

    def test_direct_clang_feedback_preserves_observation_contract(self):
        self.check_feedback('void kernel(double *restrict a, const double *restrict b) {'
                            'for (int i=0; i<1024; ++i) a[i] = b[i] + 1.; }')

    def test_alias_fallback_matches_backend_with_preserved_clone_use_order(self):
        def check_alias(comparison):
            # Full comparison still reports IR name differences. This regression
            # checks that cloning no longer changes the actual fallback code:
            # operands, scheduling, memory facts and dependencies must match.
            self.assertTrue(comparison['population_equal'])
            self.assertEqual(comparison['unavailable_or_missing'], 0)
            for candidate in comparison['candidates']:
                for diff in candidate['differences']:
                    self.assertRegex(diff['path'],
                                     r'^\$\.instructions\[\d+\]\.(mir|memory\[\d+\]\.base)$')
                    self.assertNotEqual(diff['middle_end'], diff['backend'])
                    # Only the numeric suffix of the same LSR IR value may
                    # differ. Machine register numbers are compared verbatim.
                    self.assertEqual(
                        re.sub(r'(%(?:ir\.)?lsr\.iv)\d*\b', r'\1', diff['middle_end']),
                        re.sub(r'(%(?:ir\.)?lsr\.iv)\d*\b', r'\1', diff['backend']))

        rows = self.check_feedback(
            'void kernel(double *a, const double *b, unsigned n) {'
            'for (unsigned i=0; i<n; ++i) a[i] = b[i] + 1.; }', ['-ffast-math'],
            comparison_check=check_alias)
        self.assertTrue(any(op['role'] == 'tail-or-other-loop' for row in rows
                            for op in row['observation']['instructions']))

    def test_post_frame_lowering_spills(self):
        source = ('void kernel(double *restrict o, const double *restrict a) {'
                  + ''.join(f'double s{i}=0;' for i in range(12))
                  + 'for(int i=0;i<1024;++i){'
                  + ''.join(f's{j}+=a[i+{j*1024}];' for j in range(12)) + '}'
                  + ''.join(f'o[{i}]=s{i};' for i in range(12)) + '}')
        rows = self.check_feedback(source, ['-ffast-math'])
        self.assertTrue(any(m.get('spill_slot') for r in rows
                            for op in r['observation']['instructions'] for m in op['memory']))
