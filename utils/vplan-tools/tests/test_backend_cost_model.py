"""Selection regressions for the in-process vector-only spill model."""
import json
from fractions import Fraction
import os
from pathlib import Path
import subprocess
import unittest

from feedback_comparison import read_feedback
import vplan_tools as vt

CLANG = os.environ.get('VPLAN_CLANG')


@unittest.skipUnless(CLANG, 'set VPLAN_CLANG to run compiler integration')
class BackendCostModelIntegration(unittest.TestCase):
    def compile(self, root, source, mode, extra=(), cpu='xiangshan-kunminghu'):
        src = root / 'kernel.c'
        src.write_text(source)
        cmd = [str(Path(CLANG).resolve()), '--target=riscv64-unknown-elf',
               '-march=rv64gcv', '-mcpu=' + cpu, '-mrvv-vector-bits=128',
               '-O3', '-ffast-math', '-fno-slp-vectorize', '-Rpass=loop-vectorize',
               '-mllvm', '-riscv-v-register-bit-width-lmul=8', *extra]
        if mode != 'native':
            cmd += ['-mllvm', '-enable-vplan-backend-cost-model',
                    '-mllvm', '-vplan-backend-feedback-force-all',
                    '-mllvm', '-vplan-backend-feedback-output=' + str(root / (mode + '.jsonl'))]
        result = subprocess.run(cmd + ['-S', '-emit-llvm', str(src), '-o', str(root / (mode + '.ll'))],
                                capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr)
        records = [] if mode == 'native' else [json.loads(s) for s in (root / (mode + '.jsonl')).read_text().splitlines()]
        return result.stderr, records, (root / (mode + '.ll')).read_text()

    def test_real_spills_change_vf_with_native_tti(self):
        # No XiangShan corrections: this selection change must come from the
        # estimated/actual vector spill substitution. The chosen VF spills too.
        source = ('void kernel(double *restrict o, const double *restrict a, unsigned n) {'
                  + ''.join(f'double s{i}=0;' for i in range(12))
                  + 'for(unsigned i=0;i<n;++i){'
                  + ''.join(f's{j}+=a[i+{j*1024}];' for j in range(12)) + '}'
                  + ''.join(f'o[{i}]=s{i};' for i in range(12)) + '}')
        flags = ['-fno-unroll-loops', '-mllvm', '-scalable-vectorization=always',
                 '-mllvm', '-force-vector-interleave=1', '-mllvm', '-enable-epilogue-vectorization=false']
        with vt.temporary_directory() as td:
            root = Path(td)
            native, _, _ = self.compile(root, source, 'native', flags, 'generic-rv64')
            hybrid, records, _ = self.compile(root, source, 'hybrid', flags, 'generic-rv64')
            self.assertIn('vectorization width: vscale x 1,', native)
            self.assertIn('vectorization width: vscale x 2,', hybrid)
            rows = read_feedback(root / 'hybrid.jsonl')
            self.assertTrue(all(r['tti_profile'] == 'native' for r in rows))
            self.assertTrue(all(r['native_body_quarters'] == r['profile_body_quarters'] for r in rows))
            selected = next(r for r in records if r['status'] == 'selected')
            row = next(r for r in rows if r['vf'] == selected['vf'] and r['scalable'] == selected['scalable'])
            # Without observed spills the widest VF would win. Actual body
            # spills reverse that ordering, independently of XiangShan tuning.
            without_spills = min(rows, key=lambda r: Fraction(
                r['profile_body_quarters'] - r['estimated_vector_spill_quarters'], r['tti_width']))
            self.assertEqual(without_spills['vf'], 8)
            self.assertGreater(row['raw_vector_spill_quarters'], 0)
            self.assertGreater(row['estimated_vector_spill_quarters'], row['raw_vector_spill_quarters'])
            self.assertEqual(row['body_quarters_numerator'] / row['body_quarters_denominator'],
                             row['profile_body_quarters'] - row['estimated_vector_spill_quarters'] + row['raw_vector_spill_quarters'])

    def test_native_automatic_ic_and_forced_epilogue(self):
        source = 'float kernel(float *a, unsigned n) {float s=0; for(unsigned i=0;i<n;++i)s+=a[i]; return s;}'
        with vt.temporary_directory() as td:
            root = Path(td)
            flags = ['-mllvm', '-scalable-vectorization=off']
            native, _, _ = self.compile(root, source, 'native', flags)
            hybrid, records, _ = self.compile(root, source, 'auto', flags)
            self.assertIn('interleaved count: 2', native)
            self.assertIn('interleaved count: 2', hybrid)
            rows = read_feedback(root / 'auto.jsonl')
            self.assertTrue(all(r['ic'] == 2 for r in rows))
            self.assertTrue(all(r['observation']['iteration_width'] >= r['tti_width'] * 2 for r in rows))
            self.assertTrue(all(r['register_usage_bound'].get('usage_bound', 0) ==
                                r['register_usage_bound'].get('usage_before_ic', 0) * 2 for r in rows))
            _, scalable, _ = self.compile(root, source, 'scalable', ['-mllvm', '-scalable-vectorization=always'])
            self.assertTrue(all(r['ic'] == 1 for r in scalable if 'candidate' in r))
            source = 'void kernel(float *restrict a, float *restrict b, unsigned n) {for(unsigned i=0;i<n;++i)a[i]=b[i]+1;}'
            flags += ['-mllvm', '-force-vector-width=8', '-mllvm', '-force-vector-interleave=4',
                      '-mllvm', '-epilogue-vectorization-force-VF=2']
            _, records, ir = self.compile(root, source, 'forced', flags)
            selection = next(r for r in records if r['status'] == 'selected')
            self.assertEqual((selection['vf'], selection['ic'], selection['epilogue_vf']), (8, 4, 2))
            self.assertIn('vec.epilog', ir)
            for row in read_feedback(root / 'forced.jsonl'):
                self.assertEqual(row['ic'], 4)
                self.assertTrue(row['observation']['iteration_mapping'])
                ids = [op['id'] for op in row['observation']['instructions'] if op['role'] == 'body']
                self.assertEqual(ids, row['observation']['body_order'])

            # Metadata hints must reach the same probe/final shape as CLI hints.
            source = ("void kernel(float *restrict a, float *restrict b, unsigned n) {\n"
                      "#pragma clang loop vectorize_width(8) interleave_count(2)\n"
                      "for(unsigned i=0;i<n;++i)a[i]=b[i]+1;}")
            _, metadata, _ = self.compile(root, source, 'metadata', ['-mllvm', '-scalable-vectorization=off'])
            selected = next(r for r in metadata if r['status'] == 'selected')
            self.assertEqual((selected['vf'], selected['ic']), (8, 2))
