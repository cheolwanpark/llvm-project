"""Driver protocol tests; set VPLAN_CLANG to enable compiler integration tests."""
from fractions import Fraction
import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
DRIVER = ROOT / 'utils' / 'vplan-meta-compile'
API = runpy.run_path(str(DRIVER))
CLANG = os.environ.get('VPLAN_CLANG')
SOURCE = '''void add(float *restrict d, const float *restrict a,
                     const float *restrict b, unsigned n) {
  for (unsigned i = 0; i < n; ++i) d[i] = a[i] + b[i];
}'''


class MetaFlagsTests(unittest.TestCase):
    def test_optimization_level_is_resolved_by_clang(self):
        for flags in (['-O2'], ['-O3'], ['-O1', '-O3'], ['-O3', '-O2']):
            API['validate_flags'](flags)
            self.assertEqual(API['resume_flags'](flags), flags)

    def test_driver_owned_probe_flags_are_rejected(self):
        for option in ('vplan-cost-output=x', 'vplan-analytics-output=x',
                       'force-vector-width=4', 'stop-after=riscv-vplan-cost'):
            with self.assertRaises(API['MetaCompileError']):
                API['validate_flags'](['-mllvm', '-' + option])


@unittest.skipUnless(CLANG, 'set VPLAN_CLANG to the built clang for integration tests')
class MetaCompilerTests(unittest.TestCase):
    def compile(self, root, flags, source=SOURCE):
        src = root / 'kernel.c'
        src.write_text(source)
        command = [os.sys.executable, str(DRIVER), '--clang', CLANG,
                   '--input', str(src), '--work-dir', str(root / 'work'),
                   '--output', str(root / 'kernel.o'), '--detail', '--',
                   '--target=riscv64-unknown-elf', '-march=rv64gcv',
                   '-mcpu=xiangshan-kunminghu', '-ffreestanding', *flags]
        return subprocess.run(command, capture_output=True, text=True, timeout=120)

    def check_result(self, root, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        work = root / 'work'
        self.assertGreater((root / 'kernel.o').stat().st_size, 0)
        manifest = json.loads((work / 'candidates.json').read_text())
        feedback = json.loads((work / 'feedback.json').read_text())
        final = json.loads((work / 'final.manifest.json').read_text())
        self.assertEqual(manifest['version'], 2)
        self.assertGreater(len(manifest['candidates']), 1)
        self.assertFalse(any('body_cost' in c for c in manifest['candidates']))
        costs = {c['id']: c['cost'] for c in feedback['candidates']}
        scores = {key: Fraction(c['score_quarters'], 4 * c['divisor']) for key, c in costs.items()}
        self.assertEqual(scores[final['selections'][0]['id']], min(scores.values()))
        for selection in final['selections']:
            self.assertEqual(selection['ic'], 1)
            self.assertEqual(selection['epilogue_vf'], 'f0')
        for path in work.glob('*.analytics.json'):
            raw = json.loads(path.read_text())
            self.assertEqual(raw['Error'], '')
            self.assertGreater(raw['Width'], 0)
            for forbidden in ('work8', 'resource_demand', 'latency'):
                self.assertNotIn(forbidden, path.read_text())
        self.assertIn('backend-score', result.stderr)

    def test_o2_and_o3_full_pipeline(self):
        for level in ('-O2', '-O3'):
            with self.subTest(level=level), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                self.check_result(root, self.compile(root, [level]))
                commands = json.loads((root / 'work' / 'commands.json').read_text())
                self.assertTrue(all(level in command['argv'] for command in commands))

    def test_scalar_tail_and_fixed_trip_count(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            source = SOURCE.replace('i < n', 'i < 19')
            result = self.compile(root, ['-O3', '-fno-unroll-loops', '-mllvm',
                                         '-tail-folding-policy=dont-fold-tail'], source)
            self.check_result(root, result)
            raw = [json.loads(p.read_text()) for p in (root / 'work').glob('*.analytics.json')]
            self.assertTrue(any(a['ScalarTail'] and a['VF'] > 1 for a in raw))

    def test_unsupported_optimization_level(self):
        with tempfile.TemporaryDirectory() as td:
            result = self.compile(Path(td), ['-O1'])
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('requires non-LTO RISCV64 -O2/-O3', result.stderr)

    def test_extraction_and_raw_analytics_do_not_compute_costs(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            source = SOURCE.replace('void add(', 'void selected_kernel(') + SOURCE
            src = root / 'kernel.c'
            src.write_text(source)
            result = subprocess.run([
                os.sys.executable, str(DRIVER), '--clang', CLANG, '--input', str(src),
                '--work-dir', str(root / 'work'), '--stop-after-ra', '--analytics-only',
                '--extract-function', 'selected_kernel', '--', '-O3',
                '--target=riscv64-unknown-elf', '-march=rv64gcv',
                '-mcpu=xiangshan-kunminghu', '-ffreestanding'],
                capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stderr)
            work = root / 'work'
            manifest = json.loads((work / 'candidates.json').read_text())
            self.assertEqual({r['function'] for r in manifest['candidates']}, {'selected_kernel'})
            self.assertTrue(list(work.glob('*.analytics.json')))
            self.assertFalse(list(work.glob('*.cost.json')))
            self.assertFalse((work / 'feedback.json').exists())
            self.assertFalse((work / 'final.manifest.json').exists())

    def test_continuous_default_model_agrees_with_backend_before_rounding(self):
        from cost_model import CostModel, DTYPE, P
        import torch
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            result = self.compile(root, ['-O3'])
            self.assertEqual(result.returncode, 0, result.stderr)
            for path in (root / 'work').glob('*.analytics.json'):
                raw = json.loads(path.read_text())
                cost = json.loads(path.with_name(path.name.replace('.analytics.', '.cost.')).read_text())['cost']
                body = float(CostModel([raw]).bodies(torch.ones(P, dtype=DTYPE))[0, 0])
                self.assertLessEqual(abs(body - cost['body_quarters'] / 4), .25)
