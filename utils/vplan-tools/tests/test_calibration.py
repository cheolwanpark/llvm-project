"""Analytical equations, loss semantics, optimization, and cache isolation."""
import copy
import io
import json
import math
from pathlib import Path
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import calibration as cal
from cost_model import CostModel, DTYPE, MODEL_VERSION, PARAMETERS, P
import vplan_tools as vt


def operand(**kwargs):
    return dict.fromkeys(("Vector", "Def", "Implicit", "Dead", "EarlyClobber",
                          "SubReg", "Undef", "Tied"), False) | kwargs


def instruction(category="scalar", **kwargs):
    return {"ID": 0, "Block": 0, "Opcode": "test", "Base": "VADD_VV",
        "Category": category, "SEW": 32, "Group8": 8, "Bytes": 0,
        "Operands": [operand(Vector=True, Def=True), operand(Vector=True)],
        **dict.fromkeys(("Meta", "Barrier", "ConfigUnused", "ScalableBytes", "SameCopy",
                        "Masked", "Load", "Store", "Stack"), False), "Predicate": 0, **kwargs}


def analytics(instructions=None, vf=1, scalable=False, **kwargs):
    ins = instructions if instructions is not None else [instruction()]
    return {"Version": 2, "Stage": "post-ra-cleanup", "Error": "", "RunID": "run",
        "Function": "selected_kernel", "CPU": "xiangshan-kunminghu", "VLen": 128,
        "Width": vf, "VF": vf, "ScalableVF": scalable, "MaxTripCount": 0,
        "ScalarTail": False, "Candidate": f"selected_kernel:0:0:{'s' if scalable else 'f'}{vf}",
        "DependencyCoverage": "single-block-distance-0-1", "Blocks": [{"ID": 0, "Role": "body"}],
        "Instructions": [i | {"ID": n} for n, i in enumerate(ins)], "Edges": [], **kwargs}


def edge(src, dst, distance=0):
    return {"Source": src, "Destination": dst, "OperandIndex": 1, "Distance": distance, "WholeValue": True}


class ModelTests(unittest.TestCase):
    def body(self, a, weights=None):
        return float(CostModel([a]).bodies(torch.ones(P, dtype=DTYPE) if weights is None else weights)[0, 0])

    def test_scalar_configuration_and_additive_spill(self):
        a = analytics([instruction(), instruction("config"), instruction("spill", Bytes=64)])
        self.assertEqual(self.body(a), .5 + 1 + 2)
        a["Instructions"][1]["ConfigUnused"] = True
        self.assertEqual(self.body(a), 1.5 + 2)

    def test_resource_max_is_not_addition_and_gradient_switches(self):
        a = analytics([instruction("unit", Load=True, Base="VLE32_V"), instruction("integer")])
        model = CostModel([a])
        w = torch.ones(P, dtype=DTYPE, requires_grad=True)
        value = model.bodies(w).sum(); value.backward()
        self.assertEqual(float(value), 1.)
        self.assertEqual(float(w.grad[0]), 0.)
        self.assertEqual(float(w.grad[5]), 1.)
        w2 = torch.ones(P, dtype=DTYPE); w2[0] = 4; w2.requires_grad_()
        model.bodies(w2).sum().backward()
        self.assertEqual(float(w2.grad[0]), .5)
        self.assertEqual(float(w2.grad[5]), 0.)

    def test_load_use_and_recurrence_share_fp_latency(self):
        a = analytics([instruction("unit", Load=True, Base="VLE32_V"),
                       instruction("fp", Base="VFADD_VV")], Edges=[edge(0, 1)])
        self.assertEqual(self.body(a), 7.)
        w = torch.ones(P, dtype=DTYPE); w[13] = 2
        self.assertEqual(self.body(a, w), 10.)
        r = analytics([instruction("fp", Base="VFADD_VV")], Edges=[edge(0, 0, 1)])
        self.assertEqual(self.body(r), 3.)
        self.assertEqual(self.body(r, w), 6.)

    def test_dependency_join_and_chunks(self):
        a = analytics([instruction("unit", Load=True, Base="VLE32_V", Group8=16),
                       instruction("fp", Base="VFADD_VV", Group8=16),
                       instruction("fused", Base="VFMACC_VV", Group8=16)],
                      Edges=[edge(0, 1), edge(0, 2), edge(1, 2)])
        self.assertEqual(self.body(a), 13.)  # 4 + 3 + 5 + one chunk
        w = torch.ones(P, dtype=DTYPE); w[17] = 2
        self.assertEqual(self.body(a, w), 14.)
        a["DependencyCoverage"] = "block-local"
        self.assertEqual(self.body(a), 8.)  # FP+fused service, no invented latency

    def test_mask_predicate_sharing_and_parallel_memory(self):
        ins = [instruction("unit", Load=True, Masked=True, Group8=16, Predicate=7),
               instruction("unit", Store=True, Masked=True, Group8=16, Predicate=7)]
        # total64, shared floor56, extra predicate=(96+96+32)/64=3.5
        self.assertEqual(self.body(analytics(ins)), 59.5 / 16)
        ins[1]["Predicate"] = 8
        self.assertEqual(self.body(analytics(ins)), 60 / 16)

    def test_scalar_tail_folded_tail_and_unknown_trip(self):
        scalar = analytics(Width=2, MaxTripCount=11)
        vector = analytics([instruction("integer")], vf=4, scalable=True,
                           Width=4, MaxTripCount=11, ScalarTail=True)
        model = CostModel([scalar, vector])
        self.assertEqual(model.scores(torch.ones(P, dtype=DTYPE), [0, 0])[0].tolist(), [2.75, 2.75])
        vector["ScalarTail"] = False
        self.assertEqual(CostModel([scalar, vector]).scores(torch.ones(P, dtype=DTYPE), [0, 0])[0, 1], 3.)
        scalar["MaxTripCount"] = vector["MaxTripCount"] = 0
        self.assertEqual(CostModel([scalar, vector]).scores(torch.ones(P, dtype=DTYPE), [0, 0])[0, 1], .25)

    def test_invalid_observations_and_scalar_context(self):
        for a in (analytics(Error="unsupported"), analytics(CPU="other"),
                  analytics([instruction("unknown")]), analytics([instruction("integer", Group8=3)])):
            with self.assertRaises(vt.ToolError):
                CostModel([a])
        a, b = analytics(), analytics(vf=2, scalable=True, RunID="different")
        with self.assertRaisesRegex(vt.ToolError, "scalar analytics context"):
            CostModel([a, b]).scores(torch.ones(P, dtype=DTYPE), [0, 0])


class RankingTests(unittest.TestCase):
    def test_threshold_inclusive_ties_orientation_and_saturation(self):
        self.assertEqual(cal.make_pairs({1: 100, 2: 101}, .01, 1.25), [])
        self.assertEqual(cal.make_pairs({1: 100, 2: 100}, 0, 1.25), [])
        pairs = cal.make_pairs({1: 200, 2: 100, 4: 102}, .01, 1.25)
        self.assertEqual(pairs[0], (1, 0, 1.))
        self.assertAlmostEqual(pairs[-1][2], math.log(1.02) / math.log(1.25))

    def example(self):
        scalar = analytics()
        a = analytics([instruction("integer")], vf=1, scalable=True)
        b = analytics([instruction("unit", Load=True, Base="VLE32_V")], vf=2, scalable=True)
        bm = vt.Benchmark("test", "tuning", "source", ["-O3"], {}, {1: 100, 2: 150})
        e = cal.Example(bm, [[1], [2]], [1, 2], cal.make_pairs(bm.measured, .01, 1.25))
        return CostModel([scalar, a, b]), [0, 0, 0], [e]

    def test_loss_sign_and_loop_normalization(self):
        model, scalars, examples = self.example()
        loss = cal.RankingLoss(model, scalars, examples, .1, 0)
        logs = torch.zeros((1, P), dtype=DTYPE)
        expected = math.log1p(math.exp(math.log(4) / .1))
        self.assertAlmostEqual(float(loss(logs)), expected)
        two = cal.RankingLoss(model, scalars, examples * 2, .1, 0)
        self.assertAlmostEqual(float(two(logs)), expected)
        logs[0, 5] = math.log(.25); logs[0, 0] = math.log(4)
        self.assertLess(float(loss(logs)), expected)

    def test_fitting_improves_loss_is_repeatable_and_respects_constraints(self):
        model, scalars, examples = self.example()
        args = SimpleNamespace(seed=0, starts=3, steps=80, min_multiplier=.25,
            max_multiplier=4., temperature=.1, regularization=.001, learning_rate=.03)
        with patch("sys.stderr", new_callable=io.StringIO):
            weights, info = cal.fit(model, scalars, examples, args)
            again, second = cal.fit(model, scalars, examples, args)
        self.assertTrue(torch.equal(weights, again))
        self.assertEqual(info, second)
        self.assertLess(info["objective"], info["initial_objective"])
        self.assertTrue(((weights >= .25) & (weights <= 4)).all())
        self.assertTrue(all(weights[i] == 1 for i in range(P) if i not in model.active))
        scores = model.scores(weights, scalars)[0]
        self.assertLess(scores[1], scores[2])

    def test_weights_validation(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "weights.json"
            valid = {"schema_version": 1, "model_version": MODEL_VERSION,
                     "multipliers": dict.fromkeys(PARAMETERS, 1.),
                     "dataset": {}, "compiler_identity": {}, "tuning_ids": ["train"]}
            path.write_text(json.dumps(valid))
            self.assertEqual(cal.load_weights(path)[1].tolist(), [1.] * P)
            for value in (0, -1, float('nan'), True):
                invalid = copy.deepcopy(valid); invalid["multipliers"][PARAMETERS[0]] = value
                path.write_text(json.dumps(invalid))
                with self.assertRaises(vt.ToolError):
                    cal.load_weights(path)

    def test_float_results_are_serializable(self):
        model, scalars, examples = self.example()
        r = cal.results_for(model, scalars, examples, torch.ones(P, dtype=DTYPE))[0]
        data = vt.result_json(r)
        self.assertEqual(data["scores"]["1"], {"value": 1.})
        json.dumps(data, allow_nan=False)


class CollectionTests(unittest.TestCase):
    def test_warm_cache_never_recompiles_and_source_or_tool_change_invalidates(self):
        b = vt.Benchmark("test", "tuning", "source", ["-O3"], {}, {1: 10, 2: 20})
        a = analytics()
        row = {"candidate": {"id": a["Candidate"], "function": "selected_kernel", "loop": 0, "vf": "f1"},
               "analytics": a}
        with tempfile.TemporaryDirectory() as td:
            identity = {"compiler": "one"}
            args = SimpleNamespace(cache_dir=Path(td), artifacts_dir=None, timeout=1, llvm_path=vt.DEFAULT_LLVM)
            key = cal.digest_json({"identity": identity, "source": b.source, "flags": b.compile_args})
            bundle = {"key": key, "identity": identity, "run_id": "run", "rows": [row]}
            vt.write_json(Path(td) / f"{key}.json", bundle)
            with patch.object(vt, "compile_report", side_effect=vt.ToolError("cache miss")) as compile_:
                self.assertEqual(cal.collect(b, Path("/clang"), args, identity), bundle)
                compile_.assert_not_called()
                b.source = "changed"
                with self.assertRaisesRegex(vt.ToolError, "cache miss"):
                    cal.collect(b, Path("/clang"), args, identity)
                b.source = "source"
                with self.assertRaisesRegex(vt.ToolError, "cache miss"):
                    cal.collect(b, Path("/clang"), args, {"compiler": "two"})

    def test_wrong_partition_rejected_before_build(self):
        with patch.object(vt, "load_database", return_value=([], {})) as load, \
                patch.object(vt, "ensure_compiler") as build:
            args = SimpleNamespace(compiler_mode="meta", db=Path("db"), benchmark="validation-only")
            with self.assertRaises(vt.ToolError):
                cal.initialize(args, "tuning")
            load.assert_called_once_with(Path("db"), split="tuning", benchmark_id="validation-only")
            build.assert_not_called()


if __name__ == "__main__":
    unittest.main()
