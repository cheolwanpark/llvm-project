"""Fixed spill-reject policy, independent of middle-end/backend cost scores."""
import unittest
from pathlib import Path

from model_errors import ToolError
from selection_policy import Policy
from test_calibration import analytics
from test_selection import spill


def candidate(vf=4, id=None):
    return dict(id=id or f'kernel:0:0:s{vf}', vf=f's{vf}', estimated_width=vf,
                middle_end={'original': None})


class RejectTests(unittest.TestCase):
    def test_vector_spills_and_reloads_reject_every_group(self):
        for group in (1, 2, 4, 8):
            for load in (False, True):
                i = spill(group=group) | {'Load': load, 'Store': not load}
                status = Policy().evaluate(candidate(), analytics([i], vf=4))
                self.assertEqual(status['status'], 'rejected')
                self.assertNotIn('score', status)

    def test_scalar_banks_and_invalid_middle_cost_do_not_reject(self):
        status = Policy().evaluate(candidate(), analytics([spill('gpr'), spill('fpr')], vf=4, ScalarCost=None))
        self.assertEqual(status['status'], 'accepted')
        self.assertNotIn('score', status)

    def test_maximum_nonmonotonic_and_stable_ties(self):
        rows = [(candidate(8, 'first'), {'status': 'accepted'}),
                (candidate(2), {'status': 'rejected'}),
                (candidate(4), {'status': 'accepted'}),
                (candidate(8, 'last'), {'status': 'accepted'})]
        self.assertEqual(Policy().choose(rows)['id'], 'first')
        self.assertIsNone(Policy().choose([(candidate(), {'status': 'unsupported'})]))
        self.assertIsNone(Policy().choose([]))

    def test_fixed_width_is_rejected_but_scalable_one_is_vector(self):
        self.assertEqual(Policy().evaluate(candidate() | {'vf': 'f4'}, {})['status'], 'rejected')
        self.assertEqual(Policy().evaluate(candidate(1), analytics([], vf=1))['status'], 'accepted')

    def test_incomplete_and_unproven_observations_never_mean_zero(self):
        for a in (analytics([spill() | {'Spill': False}], vf=4),
                  analytics([], vf=4, Width=6), analytics([], vf=4, Error='unproven')):
            with self.assertRaises(ToolError):
                Policy().evaluate(candidate(), a)

    def test_no_weights_or_ranking(self):
        self.assertFalse(Policy().supports_fit)
        self.assertFalse(Policy().supports_ranking)
        with self.assertRaisesRegex(ToolError, 'fixed ablation'):
            Policy(Path('missing.json'))


if __name__ == '__main__':
    unittest.main()
