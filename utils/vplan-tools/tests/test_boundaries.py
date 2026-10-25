from fractions import Fraction as Q
import json
from pathlib import Path
import subprocess
import sys
import unittest

import vplan_tools as vt


path = Path(__file__).resolve().parents[1] / 'analyze-boundaries'
ns = {'__name__': 'boundary_test', '__file__': str(path)}
exec(compile(path.read_text(), str(path), 'exec'), ns)
region, contains = ns['region'], ns['contains']


class BoundaryTests(unittest.TestCase):
    def test_crossing_and_smaller_vf_owns_tie(self):
        lines = [(2, 'a', Q(3), Q(0)), (4, 'b', Q(0), Q(2))]
        a, b = [region(lines, line) for line in lines]
        self.assertEqual(a, dict(lower=Q(3, 2), upper=None, lower_closed=True, upper_closed=False))
        self.assertEqual(b, dict(lower=Q(0), upper=Q(3, 2), lower_closed=True, upper_closed=False))

    def test_third_line_can_make_pairwise_crossing_irrelevant(self):
        lines = [(2, 'a', Q(3), Q(0)), (4, 'b', Q(0), Q(2)), (8, 'c', Q(1), Q(0))]
        self.assertIsNone(region(lines, lines[0]))
        self.assertEqual(region(lines, lines[1])['upper'], Q(1, 2))

    def test_isolated_tie_and_parallel_dominated_lines(self):
        lines = [(1, 'point', Q(1), Q(1)), (2, 'left', Q(0), Q(2)),
                 (4, 'right', Q(2), Q(0)), (8, 'dominated', Q(3), Q(0))]
        self.assertEqual(region(lines, lines[0]),
                         dict(lower=Q(1), upper=Q(1), lower_closed=True, upper_closed=True))
        self.assertIsNone(region(lines, lines[3]))
        for x in (Q(0), Q(1, 2), Q(1), Q(3, 2), Q(1000000)):
            expected = min(lines, key=lambda line: (line[2] + line[3] * x, line[:2]))
            actual = [line for line in lines if (r := region(lines, line)) and contains(r, x)]
            self.assertEqual(actual, [expected])

    def test_constant_tie_prefers_candidate_id_within_vf(self):
        lines = [(2, 'b', Q(1), Q(0)), (2, 'a', Q(1), Q(0))]
        self.assertIsNone(region(lines, lines[0]))
        self.assertTrue(contains(region(lines, lines[1]), Q(0)))

    def test_arbitrary_term_and_fixed_override_keep_saved_baseline(self):
        cases = [dict(id='test', baseline_vf=2, baseline_cycles=20,
                      oracle_vf=4, oracle_cycles=10, cycles={2: 20, 4: 10}, candidates=[
                          dict(vf=2, candidate='a', features=dict(work=1, traffic=1)),
                          dict(vf=4, candidate='b', features=dict(work=0, traffic=4))])]
        result = ns['analyze'](cases, 'work', dict(work=1, traffic=1))
        keep = result['preserve_all']
        self.assertEqual(len(keep), 1)
        self.assertEqual((keep[0]['lower'], keep[0]['upper'], keep[0]['upper_closed']), (0, 3, True))
        changed = ns['analyze'](cases, 'work', dict(work=1, traffic=0))
        self.assertEqual(changed['preserve_all'][0]['upper'], 0)
        self.assertEqual(changed['cases'][0]['baseline_vf'], 2)
        self.assertEqual(changed['best'][0]['lower'], 0)
        self.assertFalse(changed['best'][0]['lower_closed'])

    def test_per_case_15pp_is_not_relative_runtime_or_mean_threshold(self):
        cases = [dict(id='test', baseline_vf=2, baseline_cycles=120,
                      oracle_vf=4, oracle_cycles=100, cycles={2: 120, 4: 100, 8: 136}, candidates=[
                          dict(vf=2, candidate='a', features=dict(body_scale=1, fixed_additions=2)),
                          dict(vf=4, candidate='b', features=dict(body_scale=2, fixed_additions=0)),
                          dict(vf=8, candidate='c', features=dict(body_scale=0, fixed_additions=5))])]
        result = ns['analyze'](cases, 'body_scale', dict(body_scale=1, fixed_additions=1))
        bad = next(s for s in result['cases'][0]['segments'] if s['vf'] == 8)
        # 136/120-1 is only 13.33%, but regret increases by 16 percentage points.
        self.assertEqual(bad['regret_delta'], Q(16, 100))
        self.assertFalse(bad['within_15pp'])
        self.assertTrue(result['within_15pp_all'])
        self.assertEqual(result['global_regions'][-1]['metrics']['within_15pp'], 0)
        self.assertEqual(result['global_regions'][-1]['mean_contributions'][0]['regret'], Q(36, 100))

    def test_interval_width_zero_infinite_and_isolated(self):
        f = ns['interval_width']
        self.assertEqual(f(dict(lower=Q(1), upper=Q(4)))['octaves'], 2)
        self.assertEqual(f(dict(lower=Q(1), upper=Q(1)))['kind'], 'isolated-point')
        self.assertEqual(f(dict(lower=Q(0), upper=Q(4)))['kind'], 'touches-zero')
        self.assertEqual(f(dict(lower=Q(1), upper=None))['kind'], 'unbounded-above')

    def test_cli_uses_saved_terms_and_validates_overrides(self):
        with vt.temporary_directory() as td:
            root = Path(td)
            source = dict(model='custom', machine_parameters=dict(coefficients=dict(work=1, traffic=1)))
            summary = dict(complete=True, successful=True, identity=source, dataset_fingerprint='test', rows=[
                dict(id='case', eligible=True, evaluated_vfs=[2, 4], selected_vf=2,
                     measured_cycles={'2': 20, '4': 10})])
            reports = [dict(identity=source, vf='s2', candidate='a', features=dict(work=1, traffic=1)),
                       dict(identity=source, vf='s4', candidate='b', features=dict(work=0, traffic=4))]
            (root / 'summary.json').write_text(json.dumps(summary))
            (root / 'reports').mkdir()
            (root / 'reports' / (vt.report_name('case') + '.json')).write_text(json.dumps(reports))
            command = [sys.executable, '-B', str(path), '--evaluation', str(root),
                       '--output-dir', str(root / 'output')]
            result = subprocess.run(command + ['--term', 'work', '--set', 'traffic=3/2'],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            output = json.loads((root / 'output' / 'boundaries.json').read_text())
            self.assertEqual(output['identity'], source)
            self.assertEqual(output['axes'][0]['fixed'], {'traffic': '3/2'})
            self.assertEqual(output['axes'][0]['preserve_all'][0]['upper'], '9/2')
            for args in (['--term', 'missing'], ['--term', 'work', '--set', 'traffic=nan'],
                         ['--term', 'work', '--set', 'traffic=1/0'],
                         ['--term', 'work', '--set', 'work=2']):
                with self.subTest(args=args):
                    result = subprocess.run(command + args, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 2)
                    self.assertIn('error:', result.stderr)


if __name__ == '__main__':
    unittest.main()
