from copy import deepcopy
import unittest

from feedback_gate_validation import audit_pair
from fixtures import instruction, memory, observation, reg
from model_errors import ToolError


def pair(obs=None):
    obs = obs or observation()
    bound = dict(known=True, peak_bound=2, max_register_group=1, has_mask=False,
                 usage_bound=2, budget=32, reason='below-register-budget',
                 would_skip=True, force_all=False)
    gated = dict(candidate=obs['candidate'], status='skipped', register_usage_bound=bound)
    oracle = deepcopy(gated)
    oracle.update(status='collected', observation=obs)
    oracle['register_usage_bound']['force_all'] = True
    return [gated], [oracle]


class FeedbackGateValidationTests(unittest.TestCase):
    def test_verified_skip(self):
        result = audit_pair(*pair())
        self.assertEqual(result['counts']['skipped_verified'], 1)
        self.assertEqual(result['counts']['gated_queries'], 0)
        self.assertEqual(result['counts']['skipped_with_vector_spills'], 0)

    def test_unavailable_is_not_spill_free(self):
        gated, oracle = pair()
        oracle[0].update(status='unavailable')
        del oracle[0]['observation']
        result = audit_pair(gated, oracle)
        self.assertEqual(result['counts']['skipped_unverified'], 1)
        self.assertNotIn('skipped_verified', result['counts'])

    def test_vector_and_scalar_spills_are_separate(self):
        for vector in (True, False):
            operand = reg(0, 8, use=True)
            operand['group8'] = 8 if vector else 0
            op = instruction(0, 'VS1R_V' if vector else 'SD', store=True,
                             operands=[operand], memory=[memory(store=True)])
            result = audit_pair(*pair(observation([op])))
            self.assertEqual(result['counts']['skipped_with_vector_spills'], int(vector))
            self.assertEqual(result['counts'][f'body_{"vector" if vector else "scalar"}_store'], 1)

    def test_outside_spill_is_reported_not_a_body_failure(self):
        operand = reg(0, 8, use=True)
        operand['group8'] = 8
        obs = observation()
        obs['blocks'].append(dict(id=1, role='setup', successors=[]))
        obs['instructions'].append(instruction(2, 'VS1R_V', role='setup', block=1,
                                               store=True, operands=[operand],
                                               memory=[memory(store=True)]))
        result = audit_pair(*pair(obs))
        self.assertEqual(result['counts']['outside_vector_store'], 1)
        self.assertEqual(result['counts']['skipped_with_vector_spills'], 0)

    def test_missing_duplicate_or_changed_decision_is_rejected(self):
        gated, oracle = pair()
        with self.assertRaises(ToolError): audit_pair(gated, [])
        with self.assertRaises(ToolError): audit_pair(gated * 2, oracle)
        oracle[0]['register_usage_bound']['peak_bound'] = 3
        with self.assertRaises(ToolError): audit_pair(gated, oracle)

    def test_incomplete_observation_is_not_spill_free(self):
        result = audit_pair(*pair(observation(error='cannot map loop')))
        self.assertEqual(result['counts']['skipped_unverified'], 1)

    def test_eliminated_loop_requires_whole_function_spill_check(self):
        for vector_spill in (False, True):
            operand = reg(0, 8, use=True)
            operand['group8'] = 8
            op = instruction(0, 'VS1R_V', role='outside', store=True,
                             operands=[operand], memory=[memory(store=True)] if vector_spill else [])
            obs = observation([op], error='original scalar iteration mapping is unproven',
                              header=-1, body_order=[], iteration_mapping=False,
                              blocks=[dict(id=0, role='outside', successors=[])])
            result = audit_pair(*pair(obs))
            self.assertEqual(result['counts']['skipped_eliminated_loop_verified'], 1)
            self.assertEqual(result['counts']['skipped_with_vector_spills'], int(vector_spill))
            # A self-loop or any other unknown shape must remain unverified.
            obs['blocks'][0]['successors'] = [0]
            result = audit_pair(*pair(obs))
            self.assertEqual(result['counts']['skipped_unverified'], 1)

    def test_truncated_population_requires_matching_loop_fallback(self):
        gated, _ = pair()
        gated[0].update(function='kernel', loop=3)
        with self.assertRaises(ToolError):
            audit_pair(gated, [], fallback_loops={('kernel', 4)})
        result = audit_pair(gated, [], fallback_loops={('kernel', 3)})
        self.assertEqual(result['counts']['not_evaluated_after_loop_fallback'], 1)
        self.assertEqual(result['candidates'][0]['verification'], 'loop-fallback-not-evaluated')
        self.assertNotIn('skipped_verified', result['counts'])

    def test_exact_fractional_cost_comparison(self):
        gated, oracle = pair()
        gated[0].update(body_quarters_numerator=1, body_quarters_denominator=8)
        oracle[0].update(body_quarters_numerator=2, body_quarters_denominator=16)
        self.assertEqual(audit_pair(gated, oracle)['counts']['costs_equal'], 1)
        oracle[0]['body_quarters_denominator'] = 17
        with self.assertRaises(ToolError):
            audit_pair(gated, oracle)
