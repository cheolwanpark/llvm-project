"""Numerical semantics of the regression and regret objectives."""
import io
import math
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import calibration as cal
from cost_model import DTYPE, P
import vplan_tools as vt
from test_calibration import analytics
import test_calibration as fixtures


class ScoreModel:
    def __init__(self, costs):
        self.costs = torch.tensor(costs, dtype=DTYPE)

    def scores(self, logs_exp):
        return self.costs * logs_exp[:, :len(self.costs)]


def example(cycles, groups=None, name="test"):
    bm = vt.Benchmark(name, "tuning", "", [], {}, dict(enumerate(cycles, 1)))
    return cal.Example(bm, groups or [[i] for i in range(len(cycles))], list(bm.measured), [])


class ObjectiveTests(unittest.TestCase):
    def test_centered_log_mse_matches_hand_calculation_and_is_scale_invariant(self):
        logs = torch.zeros((1, P), dtype=DTYPE)
        for costs, cycles in [([2, 8], [10, 20]), ([20, 80], [10, 20]), ([2, 8], [1000, 2000])]:
            loss = cal.LoopLoss(ScoreModel(costs), [example(cycles)], .1, 0, "log-cycle-regression")
            self.assertAlmostEqual(float(loss(logs)[0]), math.log(2) ** 2 / 4)
        exact = cal.LoopLoss(ScoreModel([2, 4]), [example([10, 20])], .1, 0, "log-cycle-regression")
        self.assertAlmostEqual(float(exact(logs)[0]), 0)

    def test_soft_regret_matches_expectation_and_temperature_limits(self):
        logs = torch.zeros((1, P), dtype=DTYPE)
        measured = example([100, 200])
        # tau=1 gives probabilities 2/3 and 1/3 for costs 1 and 2.
        loss = cal.LoopLoss(ScoreModel([1, 2]), [measured], 1, 0, "soft-regret")
        self.assertAlmostEqual(float(loss(logs)[0]), 1 / 3)
        cold = cal.LoopLoss(ScoreModel([1, 2]), [measured], .001, 0, "soft-regret")
        hot = cal.LoopLoss(ScoreModel([1, 2]), [measured], 1e6, 0, "soft-regret")
        self.assertLess(float(cold(logs)[0]), 1e-100)
        self.assertAlmostEqual(float(hot(logs)[0]), .5, places=6)
        ties = cal.LoopLoss(ScoreModel([1, 2]), [example([100, 100])], .03, 0, "soft-regret")
        self.assertEqual(float(ties(logs)[0]), 0)

    def test_padding_loop_means_and_minimum_plan_per_vf(self):
        examples = [example([10, 20], [[0, 1], [2]]), example([10, 20, 40], [[3], [4], [5]], "other")]
        model = ScoreModel([1, 9, 4, 2, 3, 10])
        logs = torch.zeros((2, P), dtype=DTYPE)
        for objective in ("log-cycle-regression", "soft-regret"):
            together = cal.LoopLoss(model, examples, .3, 0, objective)(logs)
            separate = [cal.LoopLoss(model, [e], .3, 0, objective)(logs) for e in examples]
            torch.testing.assert_close(together, (separate[0] + separate[1]) / 2)

    def test_gradients_batches_regularization_and_extreme_logits(self):
        for objective in ("log-cycle-regression", "soft-regret"):
            loss = cal.LoopLoss(ScoreModel([1, 4]), [example([100, 150])], .03, .001, objective)
            logs = torch.zeros((2, P), dtype=DTYPE, requires_grad=True)
            self.assertTrue(torch.autograd.gradcheck(loss, (logs,)))
            loss(logs)[0].backward()
            self.assertEqual(float(logs.grad[1].abs().sum()), 0)
            self.assertTrue(torch.isfinite(logs.grad).all())
            extremes = torch.zeros((1, P), dtype=DTYPE)
            extremes[0, :2] = torch.tensor([-500., 500.])
            self.assertTrue(torch.isfinite(loss(extremes)).all())
        tied = cal.LoopLoss(ScoreModel([1, 2]), [example([100, 100])], .1, .001, "soft-regret")
        self.assertAlmostEqual(float(tied(torch.ones((1, P), dtype=DTYPE))[0]), .001)

    def test_fit_is_deterministic_and_preserves_bounds_and_inactive_coefficients(self):
        model, examples = fixtures.RankingTests().example()
        args = SimpleNamespace(seed=0, starts=3, steps=80, **cal.FIT_DEFAULTS)
        for objective in ("log-cycle-regression", "soft-regret"):
            args.objective = objective
            with patch("sys.stderr", new_callable=io.StringIO):
                weights, info = cal.fit(model, examples, args)
                repeated, second = cal.fit(model, examples, args)
            torch.testing.assert_close(weights, repeated, rtol=0, atol=0)
            self.assertEqual(info, second)
            self.assertLess(info["objective"], info["initial_objective"])
            self.assertTrue(((weights[:-1] >= .25) & (weights[:-1] <= 4)).all())
            self.assertTrue(all(weights[i] == 1 for i in range(P) if i not in model.active))

    def test_new_objectives_include_near_ties_and_do_not_create_pairs(self):
        observations = [analytics(vf=v, scalable=True) for v in (1, 2)]
        rows = [dict(candidate=dict(id=a["Candidate"], function="selected_kernel", loop=0, vf=f"s{a['VF']}"),
                     analytics=a) for a in observations]
        bundle = dict(key="key", run_id="run", rows=rows)
        bm = vt.Benchmark("test", "tuning", "source", [], {}, {1: 100, 2: 101})
        for objective in cal.FORMULATIONS:
            args = SimpleNamespace(objective=objective, **cal.FIT_DEFAULTS)
            with patch.object(cal, "collect", return_value=bundle), patch("sys.stderr", new_callable=io.StringIO):
                if objective == "weighted-pairwise":
                    with self.assertRaises(vt.ToolError):
                        cal.prepare([bm], None, args, {}, {"measurement_protocol": {}}, True)
                else:
                    _, examples, excluded, _ = cal.prepare([bm], None, args, {}, {"measurement_protocol": {}}, True)
                    self.assertEqual(len(examples), 1)
                    self.assertFalse(examples[0].pairs)
                    self.assertFalse(excluded)


if __name__ == "__main__":
    unittest.main()
