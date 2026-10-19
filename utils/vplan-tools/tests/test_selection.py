"""Selection metrics, checkout policy isolation and spill observation coverage."""
import copy
import json
from pathlib import Path
import runpy
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from model_errors import ToolError
from selection import load_policy, select_loops, PolicyBase
from selection_evaluation import selection_row, summarize_rows, evaluate_main
from spill_observations import project_spills, iteration_ratio
import vplan_tools as vt
from test_calibration import analytics, instruction, operand


def spill(bank='vector', group=1, **kwargs):
    return instruction('spill', Spill=True, SpillSlotAccess=True, Stack=True,
        Store=True, Bytes=group * 8, ScalableBytes=bank == 'vector',
        Operands=[operand(Bank=bank, Vector=bank == 'vector')], **kwargs)


class ProjectionTests(unittest.TestCase):
    candidate = {'estimated_width': 4}

    def test_bank_direction_group_and_region(self):
        ins = [spill('gpr'), spill('fpr')] + [spill(group=g) for g in (1, 2, 4, 8)]
        ins += [spill(group=2) | {'Store': False, 'Load': True}, spill() | {'Block': 9}]
        counts = project_spills(self.candidate, analytics(ins, vf=4))
        self.assertEqual([r['spills'] for r in counts], [1] * 6)
        self.assertEqual([r['reloads'] for r in counts], [0, 0, 0, 1, 0, 0])

    def test_incomplete_coverage_is_not_zero(self):
        for changes, reason in (({'Spill': False}, 'unrecognized-spill-access'),
                                ({'Stack': False}, 'unrecognized-spill-access'),
                                ({'Bytes': 24}, 'unrecognized-spill-group'),
                                ({'ScalableBytes': False}, 'unrecognized-spill-register'),
                                ({'Load': True}, 'unrecognized-spill-access')):
            with self.subTest(changes=changes), self.assertRaisesRegex(ToolError, reason):
                project_spills(self.candidate, analytics([spill() | changes], vf=4))
        ordinary = spill() | {'Spill': False, 'SpillSlotAccess': False}
        self.assertTrue(all(not r['spills'] for r in project_spills(self.candidate, analytics([ordinary], vf=4))))

    def test_mapping_failure_is_distinct_from_spill_fallback(self):
        self.assertEqual(iteration_ratio(self.candidate, analytics(vf=4, Width=12)), 3)
        for a in (analytics(vf=4, Width=6), analytics(vf=4, Error='lost-loop')):
            with self.assertRaises(ToolError):
                project_spills(self.candidate, a)


def result(vf='s2', scalar=False, candidate_vfs=('s1', 's2', 's4')):
    candidate = dict(id='selected_kernel:0:0:' + vf, vf=vf, function='selected_kernel', loop=0)
    candidates = [candidate | {'id': 'selected_kernel:0:0:' + v, 'vf': v}
                  for v in dict.fromkeys((*candidate_vfs, vf))]
    choice = dict(function='selected_kernel', loop=0, scalar=scalar, ic=1, epilogue_vf='f0')
    if not scalar:
        choice['id'] = candidate['id']
    manifest = dict(version=3, run_id='run', loops=[dict(function='selected_kernel', loop=0)],
                    candidates=candidates, selections=[], failures=[])
    final = manifest | {'selections': [choice]}
    return SimpleNamespace(returncode=0, stderr='', manifest=manifest,
        selection=copy.deepcopy(final), final_manifest=copy.deepcopy(final),
        candidate_status={'candidates': [dict(id=c['id'], status='scored', score=1, vlen=128)
                                         for c in candidates]})


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.benchmark = vt.Benchmark('kernel', 'validation', '', [], {}, {1: 100, 2: 150, 4: 200})

    def test_actual_choice_not_best_measured_prediction(self):
        row = selection_row(self.benchmark, result(), 128)
        self.assertEqual(row['top1_regret'], .5)
        self.assertFalse(row['top1_correct'])
        self.assertNotIn('scores', row)
        self.assertEqual(summarize_rows([row])['coverage'], 1.)

    def test_scalar_unmeasured_fixed_and_vlen_exclusions(self):
        for r, vlen, status in ((result(scalar=True), 128, 'scalar-selection'),
                                (result('s8'), 128, 'missing-measurements'),
                                (result('f2'), 128, 'unmeasured-vf'),
                                (result(), 256, 'vlen-mismatch')):
            row = selection_row(self.benchmark, r, vlen)
            self.assertEqual(row['status'], status)
            self.assertIsNone(row['top1_regret'])

    def test_db_only_vfs_do_not_change_winner_or_regret(self):
        self.benchmark.measured.update({32: 1, 64: 2})
        row = selection_row(self.benchmark, result(), 128)
        self.assertEqual(row['top1_regret'], .5)
        self.assertEqual(row['evaluated_vfs'], [1, 2, 4])
        self.assertEqual(row['measured_cycles'], {'1': 100, '2': 150, '4': 200})
        self.assertEqual(row['ignored_measured_cycles'], {'32': 1, '64': 2})
        self.assertEqual(self.benchmark.measured[32], 1)

    def test_missing_unselected_compiler_vf_still_excludes(self):
        del self.benchmark.measured[4]
        row = selection_row(self.benchmark, result(), 128)
        self.assertEqual(row['status'], 'missing-measurements')
        self.assertIn('s4', row['reason'])

    def test_single_compiler_vf_is_not_a_ranking_population(self):
        row = selection_row(self.benchmark, result(candidate_vfs=('s2',)), 128)
        self.assertEqual(row['status'], 'insufficient-measurements')

    def test_replay_context_corruption_is_fatal(self):
        r = result()
        r.final_manifest['selections'][0]['ic'] = 2
        with self.assertRaisesRegex(ToolError, 'replay mismatch'):
            selection_row(self.benchmark, r)

    def test_multiple_loops_are_not_aggregated(self):
        r = result()
        for m in (r.manifest, r.selection, r.final_manifest):
            m['loops'].append(dict(function='selected_kernel', loop=1))
        self.assertEqual(selection_row(self.benchmark, r)['status'], 'ambiguous-loops')

    def test_policy_loading_uses_target_checkout(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / 'utils/vplan-tools'
            path.mkdir(parents=True)
            (path / 'selection_policy.py').write_text(
                'from selection import PolicyBase\nclass Policy(PolicyBase):\n    name = "test-policy"\n')
            policy = load_policy(Path(td))
            self.assertEqual(policy.name, 'test-policy')
            with self.assertRaisesRegex(ToolError, 'fixed ablation'):
                load_policy(Path(td), Path('nonexistent-weights.json'))
            with patch.object(vt, 'ensure_compiler') as build, patch.object(vt, 'load_database') as db:
                with self.assertRaisesRegex(ToolError, 'fixed ablation'):
                    evaluate_main(['--llvm-path', td, '--weights', 'nonexistent.json'], fitted=True)
                build.assert_not_called()
                db.assert_not_called()

    def test_ties_keep_enumeration_order_and_failed_probes_do_not_win(self):
        class Policy(PolicyBase):
            name = 'test'
        r = result()
        manifest = r.manifest
        manifest['candidates'] = [manifest['candidates'][0] | {'id': str(i)} for i in range(3)]
        statuses = [dict(status='probe-failed'), dict(status='scored', score=3), dict(status='scored', score=3)]
        self.assertEqual(select_loops(Policy(), manifest, statuses)[0]['id'], '1')
        self.assertTrue(select_loops(Policy(), manifest, [dict(status='unsupported')] * 3)[0]['scalar'])

    def test_backend_policy_ignores_fixed_candidates_with_default_or_fitted_weights(self):
        from selection_policy import Policy
        fitted_weights = object()
        with patch('selection_policy.load_weights', return_value=({}, fitted_weights)):
            policies = [Policy(), Policy('weights.json')]
        self.assertIs(policies[1].weights, fitted_weights)
        for policy in policies:
            for fixed_score in (1, 3):
                with self.subTest(fitted=policy.weights is not None, fixed_score=fixed_score):
                    r = result(candidate_vfs=('f8', 's2', 's4'))
                    statuses = [dict(status='scored', score=fixed_score if c['vf'] == 'f8' else 3)
                                for c in r.manifest['candidates']]
                    choice = select_loops(policy, r.manifest, statuses)[0]
                    self.assertEqual(choice['id'], 'selected_kernel:0:0:s2')
                    self.assertEqual([c['vf'] for c in r.manifest['candidates']], ['f8', 's2', 's4'])

    def test_backend_policy_falls_back_when_no_scalable_candidate_is_evaluable(self):
        from selection_policy import Policy
        for candidate_vfs, statuses in (
            (('f8',), [dict(status='scored', score=1)]),
            (('f8', 's2', 's4'), [dict(status='scored', score=1),
                                 dict(status='unsupported'), dict(status='probe-failed')]),
        ):
            with self.subTest(candidate_vfs=candidate_vfs):
                r = result(vf=candidate_vfs[0], candidate_vfs=candidate_vfs)
                choice = select_loops(Policy(), r.manifest, statuses)[0]
                self.assertTrue(choice['scalar'])
                self.assertNotIn('id', choice)
                self.assertEqual(choice['reason'], 'no evaluable scalable vector candidates')


class ComparisonTests(unittest.TestCase):
    def test_comparison_audits_context_and_preserves_exclusions(self):
        api = runpy.run_path(str(vt.TOOLS / 'compare-vf-selection'))
        b = vt.Benchmark('kernel', 'validation', '', [], {}, {1: 100, 2: 150})
        with tempfile.TemporaryDirectory() as td:
            data = {}
            for name in api['NAMES']:
                root = Path(td) / name
                root.mkdir()
                r = result(scalar=name == 'spill-reject', candidate_vfs=('s1', 's2'))
                policy = {'name': name}
                r.candidate_status.update(version=3, run_id='run', policy=policy)
                for filename, value in (('candidates.json', r.manifest), ('selection.json', r.selection),
                        ('final.manifest.json', r.final_manifest), ('candidate-status.json', r.candidate_status)):
                    (root / filename).write_text(json.dumps(value))
                row = selection_row(b, r) | {'artifact': str(root)}
                data[name] = dict(schema_version=3, metric_mode='selection', policy=policy,
                                 metadata={}, benchmarks=[row], metrics={})
            compared = api['compare'](data)
            self.assertEqual(compared['common_ids'], [])
            self.assertEqual(compared['excluded_from_common'][0]['statuses']['spill-reject'], 'scalar-selection')
            changed = copy.deepcopy(data)
            changed['spill-aware']['benchmarks'][0]['measured_cycles']['1'] += 1
            with self.assertRaisesRegex(ToolError, 'measurements'):
                api['compare'](changed)
            path = Path(td) / 'spill-aware/final.manifest.json'
            bad = json.loads(path.read_text())
            bad['selections'][0]['ic'] = 2
            path.write_text(json.dumps(bad))
            with self.assertRaisesRegex(ToolError, 'replay audit'):
                api['compare'](data)


if __name__ == '__main__':
    unittest.main()
