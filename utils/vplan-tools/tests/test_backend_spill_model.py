"""Spill replacement, exact normalization, and shared selection/display costs."""
import copy
import os
import tempfile
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cost_model import MAX_COST, backend_cost, score_candidate
from model_errors import ObservationUnavailable, ToolError
from selection import select_loops
from selection_evaluation import selection_row
from selection_policy import Policy
from analytics_fixtures import analytics, instruction
from test_middle_end_model import candidate, loop
from test_selection import spill, result
import vplan_tools as vt


def observation(c, ins, width=None, trip=0, scalar=2):
    return analytics(ins, vf=int(c['vf'][1:]), scalable=c['vf'][0] == 's',
                     Width=width or c['estimated_width'], MaxTripCount=trip, ScalarCost=scalar)


class BackendCostTests(unittest.TestCase):
    def test_replaces_zero_and_nonzero_estimates_without_mutation(self):
        for estimated in (0, 80):
            c = candidate(cost=32 + estimated)
            c['middle_end'].update(precomputed=4, vector_region=28, estimated_spill=estimated)
            before = copy.deepcopy(c)
            d = backend_cost(c, observation(c, [spill(group=8)]))
            self.assertEqual(d['backend_spill_quarters'], 32)
            self.assertEqual(d['effective_body_quarters'], 64)
            self.assertEqual(c, before)
            self.assertFalse(c['middle_end']['pressure'])

    def test_all_banks_groups_and_asymmetric_directions_and_units(self):
        c = candidate()
        c['middle_end'].update(spill_units=[3, 5, 7], reload_units=[11, 13, 17])
        ins = [spill('gpr'), spill('fpr') | {'Store': False, 'Load': True}]
        ins += [spill(group=g) for g in (1, 2, 4, 8)]
        ins += [spill(group=8) | {'Store': False, 'Load': True}] * 2
        d = backend_cost(c, observation(c, ins))
        self.assertEqual(d['backend_spill_quarters'], 3 + 13 + 15 * 7 + 16 * 17)
        self.assertEqual([b['spills'] for b in d['spill_counts']], [1, 0, 1, 1, 1, 1])

    def test_iteration_ratio_and_single_quarter_truncation(self):
        c = candidate(width=4)
        c['middle_end']['spill_units'] = [1, 1, 1]
        d = backend_cost(c, observation(c, [spill('gpr')] * 5, width=12))
        self.assertEqual(d['backend_spill_exact'], {'numerator': 5, 'denominator': 3})
        self.assertEqual(d['backend_spill_quarters'], 1)
        self.assertEqual(d['effective_body_quarters'], 33)
        self.assertEqual(d['iteration_ratio'], 3)

    def test_outside_meta_and_ordinary_stack_do_not_contribute(self):
        c = candidate()
        a = observation(c, [spill() | {'Block': 9}, spill() | {'Meta': True},
                            spill() | {'Spill': False, 'SpillSlotAccess': False}])
        a['Blocks'].append({'ID': 9, 'Role': 'other-loop-or-tail'})
        self.assertEqual(backend_cost(c, a)['backend_spill_quarters'], 0)

    def test_invalid_units_and_component_saturation(self):
        c = candidate(cost=MAX_COST)
        c['middle_end'].update(precomputed=MAX_COST, vector_region=1, estimated_spill=MAX_COST)
        self.assertEqual(backend_cost(c, observation(c, [spill()]))['effective_body_quarters'], MAX_COST)
        # Reconstruct from components even if the old estimate saturated.
        c['middle_end'].update(precomputed=4, vector_region=8)
        self.assertEqual(backend_cost(c, observation(c, [instruction()]))['effective_body_quarters'], 12)
        c['middle_end']['spill_units'][2] = None
        self.assertIsNone(backend_cost(c, observation(c, [spill()]))['effective_body_quarters'])
        c['middle_end']['spill_units'][2] = MAX_COST
        self.assertEqual(backend_cost(c, observation(c, [spill(group=8)]))['backend_spill_quarters'], MAX_COST)

    def test_unknown_known_and_folded_tail_use_effective_cost(self):
        for trip in (0, 19):
            for tail in (False, True):
                c = candidate(tail=tail)
                s = Policy().evaluate(c, observation(c, [spill(group=4)], trip=trip))
                effective = copy.deepcopy(c)
                effective['middle_end']['original'] = 48
                expected = score_candidate(effective, loop(trip))
                self.assertEqual(s['score_exact'], expected['score_exact'])

    def test_selection_and_display_both_consume_backend_cost(self):
        a, b = candidate('f16', 360, 16), candidate('s4', 184, 8)
        rows = [(a, Policy().evaluate(a, observation(a, [spill(group=8)] * 6, trip=4000, scalar=13))),
                (b, Policy().evaluate(b, observation(b, [instruction()], trip=4000, scalar=13)))]
        choice = select_loops(Policy(), {'loops': [loop(4000, 13)], 'candidates': [a, b]}, [s for c, s in rows])[0]
        self.assertEqual(choice['id'], b['id'])
        self.assertEqual(rows[0][1]['score'], 34500)
        self.assertEqual(rows[1][1]['score'], 23000)

    def test_unsupported_coverage_is_not_zero(self):
        c = candidate()
        for a in (observation(c, []), observation(c, [spill() | {'Spill': False}]),
                  observation(c, [instruction()], width=9),
                  observation(c, [instruction()]) | {'Error': 'conditional body blocks are unsupported'}):
            with self.assertRaises(ObservationUnavailable):
                backend_cost(c, a)

    def test_vlen_checks_all_candidates_including_unselected_fixed(self):
        r = result(candidate_vfs=('f4', 's1', 's2'))
        r.candidate_status['candidates'][0]['vlen'] = 256
        b = vt.Benchmark('test', 'validation', '', [], {}, {1: 100, 2: 200})
        self.assertEqual(selection_row(b, r, 128)['status'], 'vlen-mismatch')

    def test_exclusion_before_replay_has_no_prediction(self):
        r = result()
        del r.final_manifest
        r.driver_result = {'status': 'backend-observation-unavailable', 'reason': 'candidate f4: lost loop',
                           'unavailable_candidates': [{'id': 'f4', 'reason': 'lost loop'}]}
        b = vt.Benchmark('test', 'validation', '', [], {}, {1: 100, 2: 200})
        row = selection_row(b, r, 128)
        self.assertFalse(row['eligible'])
        self.assertIsNone(row['actual_selection'])
        self.assertIsNone(row['selected_vf'])
        self.assertEqual(row['status'], 'backend-observation-unavailable')


if __name__ == '__main__':
    unittest.main()

@unittest.skipUnless(os.environ.get('VPLAN_CLANG'), 'set VPLAN_CLANG for compiler regression')
class GesummvRegression(unittest.TestCase):
    def test_exact_costs_original_detail_and_final_s4_materialization(self):
        from vplan_report import parse_reports, validate_manifest_costs
        root = Path(__file__).resolve().parents[3]
        benchmarks, _ = vt.load_database(root / 'search-dataset.sqlite', benchmark_id='polybench/p32-gesummv-l00')
        with tempfile.TemporaryDirectory() as td:
            r = vt.compile_report(Path(os.environ['VPLAN_CLANG']), benchmarks[0], True, 120,
                meta_script=root / 'utils/vplan-meta-compile', artifacts_dir=Path(td))
            self.assertEqual(r.returncode, 0, r.stderr[-3000:])
            self.assertEqual(r.final_manifest['candidates'], r.manifest['candidates'])
            selected_id = r.final_manifest['selections'][0]['id']
            self.assertTrue(selected_id.endswith(':s4'))
            statuses = {s['id'].rsplit(':', 1)[1]: s for s in r.candidate_status['candidates']}
            for vf, body, spill_cost, score, count in [('s4', 46, 0, 23000, 0),
                    ('s8', 138, 48, 34500, 3), ('f16', 138, 48, 34500, 3)]:
                s = statuses[vf]; d = s['breakdown']
                self.assertEqual(d['estimated_spill'], 0)
                self.assertEqual(d['body'], body)
                self.assertEqual(d['backend_spill_quarters'], spill_cost * 4)
                self.assertEqual(s['score'], score)
                bucket = d['spill_counts'][-1]
                self.assertEqual((bucket['spills'], bucket['reloads']), (count, count))
            row = selection_row(benchmarks[0], r, 128)
            self.assertTrue(row['eligible'])
            self.assertEqual(row['top1_regret'], 0)
            discovery = r.artifact_root / 'backend/discover.stderr'
            parsed = parse_reports(discovery.read_text(), stage='discover')
            self.assertEqual(validate_manifest_costs(parsed, r.manifest), len(r.manifest['candidates']))
            for log in (r.artifact_root / 'backend').glob('probe-*.stderr'):
                parse_reports(log.read_text(), stage=log.stem)
