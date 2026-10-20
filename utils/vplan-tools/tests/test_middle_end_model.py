"""LLVM arithmetic and selection semantics; measurements never enter the model."""
import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cost_model import MAX_COST, more_profitable, multiply, score_candidate
from selection import select_loops
from selection_policy import Policy
from model_errors import ToolError
from fixed_evaluation import compare


def candidate(vf="s4", cost=32, width=8, tail=True):
    return {"id": "kernel:0:0:" + vf, "function": "kernel", "loop": 0,
            "vf": vf, "estimated_width": width, "scalar_tail": tail,
            "middle_end": {"original": cost, "precomputed": 0, "vector_region": cost,
                           "estimated_spill": 0, "cost_scale": 4, "pressure": False,
                           "spill_units": [4, 4, 4], "reload_units": [4, 4, 4]}}


def loop(trip=0, scalar=2):
    return {"function": "kernel", "loop": 0, "max_trip_count": trip,
            "exact_trip_count": trip, "scalar_cost": scalar}


def choose(candidates, context=None):
    context = context or loop()
    statuses = [Policy().evaluate_middle_end(c, context) for c in candidates]
    return select_loops(Policy(), {"loops": [context], "candidates": candidates}, statuses)[0]


class CostTests(unittest.TestCase):
    def test_scores_keep_quarters_and_estimated_width(self):
        score = score_candidate(candidate(cost=7), loop())
        self.assertEqual(score["score_exact"], {"numerator": 7, "denominator": 32})
        self.assertEqual(score_candidate(candidate(), loop(19))["score"], 22)
        self.assertEqual(score_candidate(candidate(tail=False), loop(19))["score"], 24)

    def test_scalar_can_win_and_scalable_tie_is_profitable(self):
        self.assertTrue(choose([candidate(cost=68)])["scalar"])
        self.assertFalse(choose([candidate(cost=64)])["scalar"])
        self.assertTrue(choose([candidate("f8", cost=64)])["scalar"])

    def test_fixed_vectors_are_not_filtered_and_scalable_wins_ties(self):
        a, b = candidate("f8", cost=16), candidate()
        self.assertEqual(choose([a, b])["id"], a["id"])
        a["middle_end"]["original"] = 32
        self.assertEqual(choose([a, b])["id"], b["id"])
        self.assertEqual(choose([b, a])["id"], b["id"])

    def test_ties_preserve_compiler_order_within_scalable_candidates(self):
        a, b = candidate("s8", cost=64, width=16), candidate()
        self.assertEqual(choose([a, b])["id"], a["id"])
        self.assertEqual(choose([b, a])["id"], b["id"])

    def test_known_trip_count_can_reverse_per_lane_ranking(self):
        a, b = candidate("s8", cost=36, width=16), candidate()
        self.assertTrue(more_profitable(a, b, loop()))
        self.assertFalse(more_profitable(a, b, loop(8)))

    def test_comparison_uses_new_candidates_tail_policy_for_both_sides(self):
        a, b = candidate(cost=40, width=8, tail=False), candidate("s8", cost=60, width=16)
        self.assertTrue(more_profitable(a, b, loop(8)))
        # Independent scores rank b ahead of a in this example, but LLVM's
        # pairwise comparison applies a's folded-tail policy to both sides.
        a = candidate(cost=80, width=8, tail=False)
        b = candidate("s8", cost=100, width=16)
        self.assertGreater(score_candidate(a, loop(8))["score"],
                           score_candidate(b, loop(8))["score"])
        self.assertTrue(more_profitable(a, b, loop(8)))

    def test_invalid_cost_and_invalid_scalar_tail_are_explicit(self):
        self.assertEqual(score_candidate(candidate(cost=None), loop())["status"], "unsupported")
        self.assertEqual(score_candidate(candidate(), loop(8, None))["status"], "unsupported")
        self.assertEqual(score_candidate(candidate(tail=False), loop(8, None))["status"], "scored")
        self.assertFalse(choose([candidate()], loop(scalar=None))["scalar"])

    def test_float_rounding_does_not_choose_winner(self):
        a = candidate("s8", cost=2**54 + 1, width=8)
        b = candidate(cost=2**54, width=8)
        self.assertTrue(more_profitable(b, a, loop()))

    def test_instruction_cost_intermediate_saturation(self):
        self.assertEqual(multiply(7, 3), 21)
        self.assertEqual(multiply(MAX_COST // 4 + 1, 1), MAX_COST)
        self.assertIsNone(multiply(None, 0))

    def test_model_does_not_require_backend_or_weights(self):
        self.assertFalse(Policy.requires_backend)
        self.assertFalse(Policy.supports_fit)
        with self.assertRaises(ToolError):
            Policy("weights.json")

    def test_no_epilogue_spellings_compare_equally(self):
        row = {"actual_selection": {"main_vf": "s4", "ic": 1, "epilogue_vf": "f0", "emitted": True}}
        baseline = copy.deepcopy(row)
        baseline["actual_selection"]["epilogue_vf"] = "not-evaluated"
        self.assertTrue(compare(row, baseline)["same_decision"])


if __name__ == "__main__":
    unittest.main()
