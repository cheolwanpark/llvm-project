"""Fixed evaluation population, measurement isolation and CLI behavior."""
import contextlib
import io
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import fixed_evaluation as evaluation
import vplan_tools as vt
from selection import load_policy
from test_selection import result as replay_result
from test_vplan_tools import database


class EvaluationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.db = self.root / "dataset.sqlite"
        database(self.db)
        self.calls = []

    def compile(self, clang, benchmark, *args, **kwargs):
        self.calls.append(benchmark.id)
        result = replay_result(vf="s2", candidate_vfs=("s1", "s2"))
        result.candidate_status["policy"] = load_policy().identity
        return result

    def run_evaluation(self, name="out", extra=()):
        out = self.root / name
        with patch.object(vt, "ensure_compiler", return_value=Path("/fake/clang")), \
                patch.object(vt, "compile_report", side_effect=self.compile), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = evaluation.main(["--db", str(self.db), "--output-dir", str(out), *extra])
        return code, json.loads((out / "summary.json").read_text())

    def test_all_split_labels_evaluated_once_without_fitting(self):
        before = self.db.read_bytes()
        code, report = self.run_evaluation()
        self.assertEqual(code, 0)
        self.assertEqual(self.calls, ["example", "train"])
        self.assertEqual(len(report["benchmarks"]), 2)
        self.assertTrue(report["complete"])
        self.assertTrue(report["successful"])
        self.assertEqual(self.db.read_bytes(), before)
        self.assertEqual(sorted(p.name for p in (self.root / "out").iterdir()), ["summary.json"])
        self.assertNotIn("torch", sys.modules)

    def test_exact_filter_and_missing_id(self):
        self.run_evaluation(extra=("--benchmark", "train"))
        self.assertEqual(self.calls, ["train"])
        with self.assertRaisesRegex(vt.ToolError, "no matching"):
            evaluation.main(["--db", str(self.db), "--benchmark", "absent",
                             "--output-dir", str(self.root / "absent")])
        self.assertFalse((self.root / "absent").exists())

    def test_cycle_changes_affect_metrics_not_observed_choice(self):
        _, first = self.run_evaluation("first", ("--benchmark", "example"))
        with sqlite3.connect(self.db) as db:
            db.execute("UPDATE measurements SET cycles=1000 WHERE benchmark_id='example' AND vf=1")
        _, second = self.run_evaluation("second", ("--benchmark", "example"))
        a, b = first["benchmarks"][0], second["benchmarks"][0]
        self.assertEqual(a["actual_selection"], b["actual_selection"])
        self.assertNotEqual(a["top1_correct"], b["top1_correct"])

    def test_fitting_options_rejected(self):
        for option in (["--weights", "old.json"], ["--steps", "10"], ["--fit-seed", "0"]):
            with self.subTest(option=option), contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(SystemExit) as error:
                evaluation.main(["--output-dir", str(self.root / "out"), *option])
            self.assertEqual(error.exception.code, 2)

    def test_failure_report_complete_and_nonzero_exit(self):
        with patch.object(self, "compile", side_effect=vt.ToolError("compiler failed")):
            code, report = self.run_evaluation()
        self.assertEqual(code, 1)
        self.assertTrue(report["complete"])
        self.assertFalse(report["successful"])
        self.assertEqual(report["metrics"]["compile_failed"], 2)

    def test_existing_results_are_not_overwritten(self):
        (self.root / "out").mkdir()
        sentinel = self.root / "out/sentinel"
        sentinel.write_text("keep")
        with self.assertRaisesRegex(vt.ToolError, "new or empty"):
            self.run_evaluation()
        self.assertEqual(sentinel.read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
