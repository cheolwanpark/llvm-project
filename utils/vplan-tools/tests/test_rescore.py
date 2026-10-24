from fractions import Fraction as Q
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from cost_model import Settings, identity, rescore, score_observation
from evaluation import evaluate, summarize_rows
from fixtures import instruction, observation
import vplan_tools as vt


class RescoreTests(unittest.TestCase):
    def test_saved_evaluation_rescore_and_body_only_boundary_contract(self):
        reports = [score_observation(observation([instruction(0, 'VADD_VV', lmul8=vf * 8)],
                    vf=vf, iteration_width=vf * 2, candidate=f'c{vf}')) for vf in (1, 2)]
        b = vt.Benchmark('test', 'validation', '', [], {}, {1: 100, 2: 90})
        row = evaluate(dict(benchmark=b, candidates={v: [r] for v, r in zip((1, 2), reports)}, reason=None, coverage=[]))
        summary = dict(schema='mir-port-aware-evaluation-v1', complete=True, successful=True,
                       identity=identity(), rows=[row], metrics=summarize_rows([row]),
                       compiler_context={}, dataset_fingerprint='fixture', metadata={}, baseline_required=True)
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); original = root / 'source'; target = root / 'target'
            vt.write_json(original / 'summary.json', summary)
            vt.write_json(original / 'baseline.json', dict(rows=[row]))
            vt.write_json(original / 'reports' / (vt.report_name('test') + '.json'), reports)
            command = [sys.executable, '-B', str(vt.TOOLS / 'rescore-evaluation'), '--evaluation', str(original),
                       '--output-dir', str(target), '--body-scale', '3/2']
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            saved = json.loads((target / 'summary.json').read_text())
            self.assertEqual(saved['identity'], identity(Settings(body_scale='3/2')))
            self.assertEqual(saved['rows'][0]['evaluated_vfs'], [1, 2])
            self.assertFalse(saved['rows'][0]['replay_verified'])
            expected = [rescore(r, Settings(body_scale='3/2')) for r in reports]
            self.assertEqual(saved['rows'][0]['exact_scores'],
                             {str(v): r['score_exact'] for v, r in zip((1, 2), expected)})
            command = [sys.executable, '-B', str(vt.TOOLS / 'analyze-boundaries'), '--evaluation', str(target),
                       '--output-dir', str(root / 'analysis'), '--term', 'body_scale']
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            a = json.loads((root / 'analysis/boundaries.json').read_text())
            for case in a['axes'][0]['cases']:
                for segment in case['segments']:
                    lo, hi = Q(segment['lower']), Q(segment['upper']) if segment['upper'] is not None else None
                    x = lo if hi == lo else (lo + hi) / 2 if hi is not None else lo + 1
                    selected = min(expected, key=lambda r: (
                        Q(r['features']['body_scale']) * x + Q(r['features']['fixed_additions']), int(r['vf'][1:]), r['candidate']))
                    self.assertEqual(segment['vf'], int(selected['vf'][1:]))
            for args in (['--set', 'fixed_additions=2'], ['--term', 'fixed_additions']):
                result = subprocess.run(command + args, capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertIn('remain fixed', result.stderr)


if __name__ == '__main__': unittest.main()
