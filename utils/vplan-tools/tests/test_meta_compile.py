"""Driver protocol tests; set VPLAN_CLANG to enable compiler integration tests."""
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
from selection import load_policy, select_loops
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
        for option in ('vplan-selection-input=x', 'vplan-analytics-output=x',
                       'force-vector-width=4', 'stop-after=riscv-vplan-analytics'):
            with self.assertRaises(API['MetaCompileError']):
                API['validate_flags'](['-mllvm', '-' + option])


@unittest.skipUnless(CLANG, 'set VPLAN_CLANG to the built clang for integration tests')
class MetaCompilerTests(unittest.TestCase):
    def compile(self, root, flags, source=SOURCE, emit="obj", extra=()):
        src = root / 'kernel.c'
        src.write_text(source)
        command = [os.sys.executable, str(DRIVER), '--clang', CLANG,
                   '--input', str(src), '--work-dir', str(root / 'work'),
                   '--output', str(root / 'kernel.o'), '--emit', emit, *extra, '--detail', '--',
                   '--target=riscv64-unknown-elf', '-march=rv64gcv',
                   '-mcpu=xiangshan-kunminghu', '-ffreestanding', *flags]
        return subprocess.run(command, capture_output=True, text=True, timeout=120)

    def check_result(self, root, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        work = root / 'work'
        self.assertGreater((root / 'kernel.o').stat().st_size, 0)
        manifest = json.loads((work / 'candidates.json').read_text())
        selection = json.loads((work / 'selection.json').read_text())
        statuses = json.loads((work / 'candidate-status.json').read_text())['candidates']
        final = json.loads((work / 'final.manifest.json').read_text())
        self.assertEqual(manifest['version'], 3)
        self.assertTrue(all(c['vf'] != 'f1' for c in manifest['candidates']))
        self.assertEqual(final['selections'], selection['selections'])
        self.assertGreater(len(manifest['candidates']), 1)
        self.assertFalse(any('body_cost' in c for c in manifest['candidates']))
        self.assertEqual(final['selections'], select_loops(load_policy(), manifest, statuses))
        for candidate in manifest['candidates']:
            middle = candidate['middle_end']
            self.assertEqual(middle['cost_scale'], 4)
            self.assertEqual(len(middle['spill_units']), 3)
            if middle['original'] is not None:
                self.assertEqual(middle['original'], min(2**63 - 1,
                    middle['precomputed'] + middle['vector_region'] + middle['estimated_spill']))
        for selection in final['selections']:
            self.assertEqual(selection['ic'], 1)
            self.assertEqual(selection['epilogue_vf'], 'f0')
        self.assertFalse(list(work.glob('*.analytics.json')))
        self.assertTrue(list(work.glob('check-*.manifest.json')))
        for path in work.glob('*.analytics.json'):
            raw = json.loads(path.read_text())
            self.assertEqual(raw['Error'], '')
            self.assertGreater(raw['Width'], 0)
            for forbidden in ('work8', 'resource_demand', 'latency'):
                self.assertNotIn(forbidden, path.read_text())
        self.assertIn('VPlan report_version=', result.stderr)

    def test_o2_and_o3_full_pipeline(self):
        for level, emit in ((l, e) for l in ('-O2', '-O3') for e in ('llvm', 'asm', 'obj')):
            with self.subTest(level=level), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                self.check_result(root, self.compile(root, [level], emit=emit))
                commands = json.loads((root / 'work' / 'commands.json').read_text())
                self.assertTrue(all(level in command['argv'] for command in commands))

    def test_scalar_tail_and_fixed_trip_count(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            source = SOURCE.replace('i < n', 'i < 19')
            result = self.compile(root, ['-O3', '-fno-unroll-loops', '-mllvm',
                                         '-tail-folding-policy=dont-fold-tail'], source)
            self.check_result(root, result)
            manifest = json.loads((root / 'work/candidates.json').read_text())
            self.assertTrue(any(c['scalar_tail'] and int(c['vf'][1:]) > 1 for c in manifest['candidates']))

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

    def test_fixed_model_rejects_weights_before_compilation(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            result = self.compile(root, ['-O3'], extra=['--weights', str(root / 'old-weights.json')])
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('fixed ablation', result.stderr)
            self.assertFalse((root / 'work').exists())

    def test_check_failure_is_not_silently_replaced(self):
        from unittest.mock import patch
        Driver, Error = API['Driver'], API['MetaCompileError']
        original = Driver.run
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            src = root / 'kernel.c'
            src.write_text(SOURCE)
            driver = Driver(Path(CLANG), src, root / 'work',
                ['-O3', '--target=riscv64-unknown-elf', '-march=rv64gcv',
                 '-mcpu=xiangshan-kunminghu', '-ffreestanding'])
            def run(instance, label, command, **kw):
                if label.startswith('check-'):
                    raise Error('injected compiler failure')
                return original(instance, label, command, **kw)
            with patch.object(Driver, 'run', run), self.assertRaisesRegex(Error, 'injected'):
                driver.compile(root / 'out.o', 'obj', False, False)
            self.assertFalse((root / 'work/final.manifest.json').exists())

    def test_stale_duplicate_configuration_and_changed_set_are_errors(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            self.check_result(root, self.compile(root, ['-O3']))
            work = root / 'work'
            original = json.loads((work / 'selection.json').read_text())
            command = json.loads((work / 'commands.json').read_text())[-1]['argv']
            mutations = [lambda s: s.update(run_id='stale'),
                         lambda s: s['selections'].append(s['selections'][0].copy()),
                         lambda s: s['selections'][0].update(ic=2),
                         lambda s: s['selections'][0].update(id='missing:0:0:s4'),
                         lambda s: s['candidates'].pop(),
                         lambda s: s['loops'][0].update(scalar_cost=999)]
            for mutate in mutations:
                value = json.loads(json.dumps(original))
                mutate(value)
                (work / 'selection.json').write_text(json.dumps(value))
                result = subprocess.run(command, capture_output=True, text=True, timeout=30)
                self.assertNotEqual(result.returncode, 0, result.stderr)

    def test_successful_probe_with_corrupt_identity_is_fatal(self):
        from unittest.mock import patch
        from model_errors import ToolError
        Driver = API['Driver']
        original = Driver.run
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            src = root / 'kernel.c'
            src.write_text(SOURCE)
            driver = Driver(Path(CLANG), src, root / 'work',
                ['-O3', '--target=riscv64-unknown-elf', '-march=rv64gcv', '-mcpu=xiangshan-kunminghu'])
            def run(instance, label, command, **kw):
                result = original(instance, label, command, **kw)
                if label.startswith('check-'):
                    path = instance.work / (label + '.manifest.json')
                    value = json.loads(path.read_text()); value['run_id'] = 'wrong'
                    path.write_text(json.dumps(value))
                return result
            with patch.object(Driver, 'run', run), self.assertRaisesRegex(ToolError, 'mismatch'):
                driver.compile(None, 'obj', True, False)

    def test_unknown_trip_and_masked_or_evl_folding(self):
        for style in ('data-without-lane-mask', 'data-with-evl'):
            with self.subTest(style=style), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                source = SOURCE.replace('unsigned', 'unsigned long')
                result = self.compile(root, ['-O3', '-mllvm', '-force-tail-folding-style=' + style], source)
                self.check_result(root, result)
                work = root / 'work'
                manifest = json.loads((work / 'candidates.json').read_text())
                trip = manifest['loops'][0]['max_trip_count']
                self.assertEqual(trip, 0)
                statuses = json.loads((work / 'candidate-status.json').read_text())['candidates']
                for row, status in zip(manifest['candidates'], statuses):
                    if status['status'] != 'scored':
                        continue
                    self.assertFalse(row['scalar_tail'])
                    width = row['estimated_width']
                    factor = (trip + width - 1) // width if trip else 1 / width
                    self.assertEqual(status['score'], status['breakdown']['body'] * factor)

    def test_two_loops_in_one_function_and_no_vector_candidates(self):
        source = '''void add(float *restrict a, float *restrict b, unsigned n) {
          for (unsigned i=0; i<n; ++i) a[i] += 1;
          for (unsigned i=0; i<n; ++i) b[i] *= 3;
        }'''
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            result = self.compile(root, ['-O3'], source)
            self.assertEqual(result.returncode, 0, result.stderr)
            choices = json.loads((root / 'work/selection.json').read_text())['selections']
            self.assertEqual(len(choices), 2)
            self.assertTrue(all(not c['scalar'] for c in choices))
            final = json.loads((root / 'work/final.manifest.json').read_text())
            self.assertEqual(final['selections'], choices)
        source = 'void add(volatile float *a, unsigned n) { for (unsigned i=0; i<n; ++i) a[i] += 1; }'
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            result = self.compile(root, ['-O2'], source)
            self.assertEqual(result.returncode, 0, result.stderr)
            selection = json.loads((root / 'work/selection.json').read_text())
            self.assertEqual(selection['candidates'], [])
            self.assertTrue(selection['selections'][0]['scalar'])
            self.assertFalse(list((root / 'work').glob('probe-*.analytics.json')))
