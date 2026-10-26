"""Compiler integration for the default pressure gate and force-all oracle."""
import os
from pathlib import Path
import subprocess
import unittest

from feedback_comparison import read_feedback
from feedback_gate_validation import audit_pair, timings
import vplan_tools as vt

CLANG = os.environ.get('VPLAN_CLANG')


@unittest.skipUnless(CLANG, 'set VPLAN_CLANG to run compiler integration')
class FeedbackGateIntegration(unittest.TestCase):
    def test_gate_masks_budget_boundary_and_unsupported_recipe(self):
        source = '''
        void low(double *restrict a, const double *restrict b) {
          for (int i=0;i<1024;++i) a[i]=b[i]+1.;
        }
        void boundary(double *restrict a, const double *restrict b,
                      const double *restrict c, const double *restrict d) {
          for (int i=0;i<1024;++i) a[i]=b[i]+c[i]+d[i];
        }
        void masked(double *restrict a, const double *restrict b,
                    const double *restrict c) {
          for (int i=0;i<1024;++i) if (b[i]>0.) a[i]=b[i]+c[i];
        }
        void reversed(double *restrict a, const double *restrict b) {
          for (int i=0;i<1024;++i) a[i]=b[1023-i];
        }
        '''
        with vt.temporary_directory() as temp:
            root = Path(temp)
            src = root / 'kernels.c'
            src.write_text(source)
            flags = [str(Path(CLANG).resolve()), '--target=riscv64-unknown-elf',
                     '-march=rv64gcv', '-mcpu=xiangshan-kunminghu',
                     '-mrvv-vector-bits=128', '-O3', '-fno-unroll-loops',
                     '-fno-slp-vectorize', '-mllvm', '-scalable-vectorization=always',
                     '-mllvm', '-force-vector-interleave=1', '-mllvm',
                     '-enable-epilogue-vectorization=false', '-mllvm',
                     '-riscv-v-register-bit-width-lmul=8']
            for mode in ('off', 'gate', 'oracle'):
                extra = [] if mode == 'off' else [
                    '-mllvm', '-enable-vplan-backend-feedback',
                    '-mllvm', '-time-vplan-backend-feedback', '-mllvm',
                    '-vplan-backend-feedback-output=' + str(root / (mode + '.jsonl'))]
                if mode == 'oracle':
                    extra += ['-mllvm', '-vplan-backend-feedback-force-all']
                result = subprocess.run(flags + extra + ['-S', str(src), '-o',
                                         str(root / (mode + '.s'))],
                                        capture_output=True, text=True, timeout=120)
                self.assertEqual(result.returncode, 0, result.stderr)
                (root / (mode + '.stderr')).write_text(result.stderr)
            self.assertEqual((root / 'off.s').read_bytes(), (root / 'gate.s').read_bytes())
            self.assertEqual((root / 'off.s').read_bytes(), (root / 'oracle.s').read_bytes())
            gated = read_feedback(root / 'gate.jsonl')
            oracle = read_feedback(root / 'oracle.jsonl')
            audit = audit_pair(gated, oracle)
            self.assertGreater(audit['counts']['skipped_verified'], 0)
            self.assertEqual(audit['counts'].get('skipped_unverified', 0), 0)
            self.assertEqual(audit['counts']['skipped_with_vector_spills'], 0)
            for mode, rows in [('gate', gated), ('oracle', oracle)]:
                calls = timings(root / (mode + '.stderr'))
                expected = [r for r in rows if r['status'] != 'skipped']
                self.assertEqual(len(calls), len(expected))
                self.assertEqual({r['candidate'] for r in calls},
                                 {r['candidate'] for r in expected})
            self.assertTrue(all(r['status'] == 'skipped' for r in gated if r['function'] == 'low'))
            boundary = [r for r in gated if r['function'] == 'boundary' and
                        r['register_usage_bound'].get('usage_bound') == 32]
            diagnostics = [(r['function'], r['vf'], r['register_usage_bound']) for r in gated]
            self.assertTrue(boundary, diagnostics)
            self.assertTrue(all(r['status'] == 'collected' for r in boundary))
            masks = [r['register_usage_bound'] for r in gated if r['function'] == 'masked'
                     and r['register_usage_bound']['known']]
            self.assertTrue(masks, diagnostics)
            for m in masks:
                self.assertTrue(m['has_mask'])
                self.assertEqual(m['usage_bound'], (m['peak_bound'] + 1) * m['max_register_group'])
            unsupported = [r for r in gated if r['function'] == 'reversed']
            self.assertTrue(unsupported)
            self.assertTrue(all(r['status'] == 'collected' and
                                not r['register_usage_bound']['known'] and
                                'recipe' in r['register_usage_bound'] for r in unsupported))
