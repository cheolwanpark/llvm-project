from copy import deepcopy
import unittest

from feedback_comparison import compare_observations
from fixtures import instruction, observation


class FeedbackComparisonTests(unittest.TestCase):
    def test_transport_identity_is_explicitly_excluded(self):
        backend = observation()
        middle = deepcopy(backend)
        middle.update(candidate='different-invocation', run_id='', feedback_pipeline='vector-suffix-O3')
        result = compare_observations(middle, backend)
        self.assertTrue(result['equal'])
        self.assertTrue(result['scores_equal'])
        self.assertEqual(result['ignored_fields']['candidate']['backend'], backend['candidate'])

    def test_same_score_does_not_hide_different_fallback_code(self):
        backend = observation()
        backend['blocks'].append(dict(id=1, role='tail-or-other-loop', successors=[]))
        backend['instructions'].append(instruction(2, 'ADDI', block=1, role='tail-or-other-loop'))
        middle = deepcopy(backend)
        middle['instructions'][-1]['mir'] = '$x12 = ADDI $x11, 8'
        result = compare_observations(middle, backend)
        self.assertFalse(result['equal'])
        self.assertTrue(result['scores_equal'])
        self.assertTrue(result['instruction_regions']['body']['equal'])
        self.assertFalse(result['instruction_regions']['tail-or-other-loop']['equal'])
        self.assertEqual([d['path'] for d in result['differences']], ['$.instructions[2].mir'])
