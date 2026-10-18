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
