"""Preserve TTI spill replacement semantics within the common v3 selector."""
import unittest
from pathlib import Path

from model_errors import ToolError
from selection_policy import Policy, MAX_COST, price_spills
from test_calibration import analytics
from test_selection import spill


def candidate(**middle):
    return dict(id='kernel:0:0:s4', vf='s4', estimated_width=4, middle_end=dict(
        cost_scale=4, pressure=True, precomputed=8, vector_region=16,
        estimated_spill=40, original=64, spill_units=[4, 8, 12], reload_units=[8, 12, 16]) | middle)


class SpillCostTests(unittest.TestCase):
    def evaluate(self, c=None, a=None, unit=None):
        return Policy(spill_count_unit=unit).evaluate(
            c or candidate(), a or analytics([], vf=4))['breakdown']

    def test_zero_replaces_estimate_before_adding(self):
        b = self.evaluate()
        self.assertEqual((b['source'], b['effective_spill_q'], b['candidate_cost_q']), ('post-ra', 0, 24))
        self.assertEqual(b['score'], 1.5)

    def test_instruction_register_groups_and_unroll_normalization(self):
        a = analytics([spill(group=2)], vf=4, Width=8)
        first, second = self.evaluate(a=a), self.evaluate(a=a, unit='register')
        self.assertEqual(first['effective_spill_q'], 6)
        self.assertEqual(second['effective_spill_q'], 12)
        self.assertEqual(first['score'], 1.875)
        self.assertEqual(second['score'], 2.25)

    def test_round_once_after_accumulating_and_saturate(self):
        a = analytics([spill()] * 3, vf=4, Width=12)
        b = self.evaluate(candidate(spill_units=[1, 1, 1]), a)
        self.assertEqual((b['observed_spill_q'], b['effective_spill_q']), (3, 1))
        saturated = self.evaluate(candidate(precomputed=MAX_COST - 4, vector_region=3, original=MAX_COST))
        self.assertEqual(saturated['candidate_cost_q'], MAX_COST - 1)
        counts = [dict(kind='vector', registers=8, spills=2, reloads=1)]
        total, normalized = price_spills(counts,
            {'spill_units': [0, 0, MAX_COST], 'reload_units': [0, 0, MAX_COST]}, 2, 'register')
        self.assertEqual((total, normalized), (MAX_COST, MAX_COST // 2))

    def test_incomplete_spill_and_needed_tti_unit_use_estimate(self):
        incomplete = analytics([spill() | {'Spill': False}], vf=4)
        for c, a, reason in ((candidate(), incomplete, 'unrecognized-spill-access'),
                (candidate(spill_units=[4, 8, None]), analytics([spill()], vf=4), 'unsupported-tti-unit')):
            b = self.evaluate(c, a)
            self.assertEqual((b['source'], b['fallback_reason'], b['effective_spill_q']), ('heuristic', reason, 40))
            self.assertEqual(b['candidate_cost_q'], 64)
        b = self.evaluate(candidate(spill_units=[None] * 3, reload_units=[None] * 3))
        self.assertEqual(b['effective_spill_q'], 0)

    def test_disabled_pressure_and_invalid_cost(self):
        b = self.evaluate(candidate(pressure=False, estimated_spill=0, original=24), analytics([spill()] * 100, vf=4))
        self.assertEqual((b['source'], b['candidate_cost_q']), ('disabled', 24))
        with self.assertRaisesRegex(ToolError, 'invalid-middle-end'):
            self.evaluate(candidate(original=None))

    def test_unproven_width_is_excluded_not_estimated(self):
        for a in (analytics([], vf=4, Width=6), analytics([], vf=4, Error='unproven')):
            with self.assertRaises(ToolError):
                self.evaluate(a=a)

    def test_common_tail_cost_and_no_scalar_profitability_gate(self):
        a = analytics([], vf=4, ScalarTail=True, MaxTripCount=11, ExactTripCount=11, ScalarCost=.5)
        self.assertEqual(self.evaluate(a=a)['score'], 13.5)
        a['ScalarCost'] = None
        with self.assertRaisesRegex(ToolError, 'scalar cost'):
            self.evaluate(a=a)
        a.update(MaxTripCount=8, ExactTripCount=8)
        self.assertEqual(self.evaluate(a=a)['score'], 12)
        # Large TTI costs remain eligible vectors: no comparison with scalar.
        b = self.evaluate(candidate(precomputed=4000, original=4056), analytics([], vf=4, ScalarCost=0))
        self.assertGreater(b['score'], 100)

    def test_weights_are_unsupported(self):
        with self.assertRaisesRegex(ToolError, 'fixed ablation'):
            Policy(Path('missing.json'))


if __name__ == '__main__':
    unittest.main()
