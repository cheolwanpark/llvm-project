"""CV isolation, complete OOF accounting and independent fitting/replay."""
import copy
import io
import json
from pathlib import Path
import runpy
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import calibration as cal
import cross_validation as cv
import vplan_tools as vt
import llvm_baseline as baseline
from selection import load_policy
from test_calibration import analytics
from test_selection import result as replay_result
from test_llvm_baseline import emitted


class FoldTests(unittest.TestCase):
    def test_membership_is_balanced_reproducible_and_input_order_independent(self):
        ids = [f"kernel-{i}" for i in range(243)]
        folds = cv.make_folds(ids, 0)
        self.assertEqual(folds, cv.make_folds(reversed(ids), 0))
        self.assertNotEqual(folds, cv.make_folds(ids, 1))
        self.assertEqual(list(map(len, folds)), [49, 49, 49, 48, 48])
        self.assertEqual(sorted(i for fold in folds for i in fold), sorted(ids))
        for i, fold in enumerate(folds):
            for other in folds[i + 1:]:
                self.assertFalse(set(fold) & set(other))

    def test_invalid_populations(self):
        for ids in ([], list("abcd"), list("abcdee")):
            with self.assertRaises(vt.ToolError):
                cv.make_folds(ids, 0)

    def test_pooling_recomputes_quantiles_and_uses_benchmark_denominators(self):
        def row(i, regret):
            return dict(id=str(i), eligible=True, top1_regret=regret,
                        top1_correct=regret == 0, compile_failed=False, status="scored")
        a = [row(0, 0)]
        b = [row(i, 1) for i in range(1, 5)]
        sa, sb = [cv.summarize(rows, [], "selection") for rows in (a, b)]
        pooled = cv.summarize(a + b, [], "selection")
        macro = cv.fold_statistics([dict(metrics=sa), dict(metrics=sb)])
        self.assertEqual(pooled["top1"]["exact"], .2)
        self.assertEqual(macro["top1.exact"]["mean"], .5)
        self.assertEqual(pooled["top1_regret"]["median"], 1)
        self.assertEqual(pooled["top1_regret"]["p95"], 1)
        self.assertEqual(macro["top1_regret.p95"]["mean"], .5)


class CVTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="vplan-cv-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.db = self.root / "dataset.sqlite"
        with sqlite3.connect(self.db) as con:
            con.executescript("""
                CREATE TABLE dataset(id INTEGER, target TEXT, measurement_compiler TEXT,
                                     measurement_protocol_json TEXT);
                CREATE TABLE benchmarks(id TEXT PRIMARY KEY, split TEXT, source TEXT,
                                        compile_args_json TEXT, workload_json TEXT);
                CREATE TABLE measurements(benchmark_id TEXT, vf INTEGER, cycles INTEGER);
                INSERT INTO dataset VALUES(1, 'test', 'test-clang', '{"vlen_bits":128}');
            """)
            for i in range(11):
                name = "tsvc/tsvc-s000-l00" if i == 2 else f"kernel-{i:02d}"
                con.execute("INSERT INTO benchmarks VALUES(?,?,?,?,?)",
                            (name, "tuning" if i < 3 else "validation", name, '[]', '{}'))
                con.executemany("INSERT INTO measurements VALUES(?,?,?)",
                                [(name, 1, 100), (name, 2, 60), (name, 64, 1)])
        vectors = [analytics(vf=v, scalable=True) for v in (1, 2)]
        self.bundle = dict(key="key", run_id="run", rows=[
            dict(candidate=dict(id=a["Candidate"], function=a["Function"], loop=0, vf=f"s{a['VF']}"),
                 analytics=a) for a in vectors])
        self.collect_calls, self.replay_calls = [], []

    def collect(self, benchmark, *args):
        self.collect_calls.append((benchmark.id, benchmark.kind, dict(benchmark.measured)))
        return copy.deepcopy(self.bundle)

    def replay(self, clang, benchmark, *args, **kwargs):
        self.replay_calls.append((benchmark.id, kwargs["weights"]))
        result = replay_result(candidate_vfs=("s1", "s2"))
        result.candidate_status["policy"] = load_policy(weights_path=kwargs["weights"]).identity
        return result

    def run_cv(self, name, mode="ranking", collect=None, replay=None, objective="weighted-pairwise"):
        out = self.root / name
        with patch.object(vt, "ensure_compiler", return_value=Path("/fake/clang")), \
             patch.object(cal, "collector_identity", return_value={"compiler": "test"}), \
             patch.object(cal, "collect", side_effect=collect or self.collect), \
             patch.object(vt, "compile_report", side_effect=replay or self.replay), \
             patch("sys.stdout", new_callable=io.StringIO), patch("sys.stderr", new_callable=io.StringIO):
            with patch("sys.argv", ["evaluate", "--db", str(self.db), "--output-dir", str(out),
                                   "--metric-mode", mode, "--objective", objective,
                                   "--starts", "2", "--steps", "4"]), self.assertRaises(SystemExit) as exit_:
                runpy.run_path(str(vt.TOOLS / "evaluate"), run_name="__main__")
        return exit_.exception.code, json.loads((out / "summary.json").read_text()), out

    def test_each_new_objective_supports_ranking_and_selection(self):
        before = self.db.read_bytes()
        for objective in ("log-cycle-regression", "soft-regret"):
            for mode in ("ranking", "selection"):
                with self.subTest(objective=objective, mode=mode), patch.object(cal, "fit", wraps=cal.fit) as fit:
                    code, summary, out = self.run_cv(objective + "-" + mode, mode=mode, objective=objective)
                    self.assertEqual(code, 0)
                    self.assertEqual(fit.call_count, 5)
                    self.assertTrue(summary["complete"] and summary["successful"])
                    self.assertEqual(summary["settings"]["objective"], objective)
                    self.assertEqual(len(summary["benchmarks"]), 11)
                    self.assertEqual(summary["metrics"]["scored"], 11)
                    for fold in summary["folds"]:
                        directory = out / f"fold-{fold['fold']}"
                        weights = json.loads((directory / "weights.json").read_text())
                        evaluated = json.loads((directory / "evaluation.json").read_text())
                        self.assertEqual(weights["settings"]["objective"], objective)
                        self.assertEqual(evaluated["weights_sha256"], cal.digest_file(directory / "weights.json"))
                    self.assertEqual(self.db.read_bytes(), before)

    def test_new_objective_weights_ignore_held_out_measurements(self):
        for objective in ("log-cycle-regression", "soft-regret"):
            _, first, out = self.run_cv(objective + "-first", objective=objective)
            held_out = first["folds"][0]["held_out_ids"]
            before = json.loads((out / "fold-0/weights.json").read_text())
            with sqlite3.connect(self.db) as con:
                con.executemany("UPDATE measurements SET cycles=cycles+137 WHERE benchmark_id=? AND vf=2",
                                [(i,) for i in held_out])
            _, _, out2 = self.run_cv(objective + "-second", objective=objective)
            after = json.loads((out2 / "fold-0/weights.json").read_text())
            self.assertEqual(before["multipliers"], after["multipliers"])
            self.assertEqual(before["fitting"], after["fitting"])

    def test_real_fit_and_ranking_cover_every_id_once_without_modifying_db(self):
        before = self.db.read_bytes()
        code, summary, out = self.run_cv("ranking")
        self.assertEqual(code, 0)
        self.assertTrue(summary["complete"] and summary["successful"])
        self.assertEqual(summary["metrics"]["scored"], 11)
        self.assertEqual(len({r["id"] for r in summary["benchmarks"]}), 11)
        self.assertEqual(self.db.read_bytes(), before)
        for fold in summary["folds"]:
            weights = json.loads((out / f"fold-{fold['fold']}" / "weights.json").read_text())
            self.assertEqual(weights["tuning_ids"], fold["train_ids"])
            self.assertFalse(set(fold["train_ids"]) & set(fold["held_out_ids"]))
            self.assertEqual(weights["settings"]["seed"], 0)
            self.assertEqual(weights["fitting"]["benchmarks"], len(fold["train_ids"]))
        for row in summary["benchmarks"]:
            self.assertEqual(row["split"], "held-out")
            self.assertEqual(row["ignored_measured_cycles"], {"64": 1})

    def test_held_out_measurements_do_not_affect_that_folds_weights(self):
        _, first, out = self.run_cv("first")
        held_out = first["folds"][0]["held_out_ids"]
        before = json.loads((out / "fold-0/weights.json").read_text())
        with sqlite3.connect(self.db) as con:
            con.executemany("UPDATE measurements SET cycles=200 WHERE benchmark_id=? AND vf=2",
                            [(i,) for i in held_out])
        _, _, out2 = self.run_cv("second")
        after = json.loads((out2 / "fold-0/weights.json").read_text())
        self.assertEqual(before["multipliers"], after["multipliers"])
        self.assertEqual(before["fitting"], after["fitting"])
        self.assertEqual(before["tuning_fingerprint"], after["tuning_fingerprint"])
        self.assertNotEqual(before["cv"]["dataset_fingerprint"], after["cv"]["dataset_fingerprint"])

    def test_selection_replays_with_the_correct_fold_weights(self):
        code, summary, out = self.run_cv("selection", mode="selection")
        self.assertEqual(code, 0)
        self.assertEqual(len(self.replay_calls), 11)
        for benchmark_id, weights in self.replay_calls:
            row = next(r for r in summary["benchmarks"] if r["id"] == benchmark_id)
            self.assertEqual(weights, out / f"fold-{row['fold']}" / "weights.json")
        self.assertEqual(summary["metrics"]["top1"]["exact"], 1.)

    def test_exclusions_do_not_repartition_and_compile_failures_fail_the_run(self):
        def replay(clang, benchmark, *args, **kwargs):
            result = self.replay(clang, benchmark, *args, **kwargs)
            if benchmark.id == "kernel-00":
                result.returncode, result.stderr = 1, "compiler failed"
            return result
        code, summary, _ = self.run_cv("failure", mode="selection", replay=replay)
        self.assertEqual(code, 1)
        self.assertTrue(summary["complete"])
        self.assertFalse(summary["successful"])
        self.assertEqual(summary["metrics"]["compile_failed"], 1)
        self.assertEqual(summary["metrics"]["scored"], 10)
        self.assertEqual([f["held_out_ids"] for f in summary["folds"]],
                         cv.make_folds([r["id"] for r in summary["benchmarks"]], 0))

    def test_no_trainable_data_produces_incomplete_failed_report(self):
        def collect(*args):
            raise vt.ToolError("unsupported analytics")
        code, summary, _ = self.run_cv("empty", collect=collect)
        self.assertEqual(code, 1)
        self.assertFalse(summary["complete"] or summary["successful"])
        self.assertEqual(len(summary["folds"]), 5)
        self.assertTrue(all("no eligible benchmarks" in f["error"] for f in summary["folds"]))
        self.assertEqual(summary["metrics"]["total"], 0)

    def test_mismatched_fold_weights_are_rejected(self):
        _, summary, out = self.run_cv("weights")
        benchmarks, metadata = vt.load_database(self.db)
        fold = summary["folds"][0]
        path = out / "fold-0/weights.json"
        artifact = json.loads(path.read_text())
        held_out = [b for b in benchmarks if b.id in fold["held_out_ids"]]
        wrong_context = artifact["cv"] | {"fold": 1}
        with self.assertRaisesRegex(vt.ToolError, "do not belong"):
            cv.validate_fold_weights(path, metadata, {"compiler": "test"}, fold["train_ids"], held_out, wrong_context)
        with self.assertRaisesRegex(vt.ToolError, "IDs used to fit"):
            cv.validate_fold_weights(path, metadata, {"compiler": "test"}, fold["train_ids"], benchmarks, artifact["cv"])

    def test_existing_results_are_not_overwritten(self):
        self.run_cv("existing")
        with self.assertRaisesRegex(vt.ToolError, "never overwritten"):
            cv.main(["--db", str(self.db), "--output-dir", str(self.root / "existing")])

    def test_split_labels_do_not_affect_population_folds_or_weights(self):
        _, first, out = self.run_cv("before-labels")
        with sqlite3.connect(self.db) as con:
            con.execute("UPDATE benchmarks SET split = CASE split "
                        "WHEN 'tuning' THEN 'validation' ELSE 'tuning' END")
        before = self.db.read_bytes()
        _, second, out2 = self.run_cv("after-labels")
        self.assertEqual(self.db.read_bytes(), before)
        self.assertEqual(first["dataset_fingerprint"], second["dataset_fingerprint"])
        self.assertEqual((out / "folds.json").read_bytes(), (out2 / "folds.json").read_bytes())
        for i in range(cv.FOLDS):
            self.assertEqual((out / f"fold-{i}/weights.json").read_bytes(),
                             (out2 / f"fold-{i}/weights.json").read_bytes())
        for a, b in zip(first["benchmarks"], second["benchmarks"], strict=True):
            self.assertNotEqual(a.pop("source_split"), b.pop("source_split"))
            self.assertEqual(a, b)

    def test_baseline_uses_the_same_full_population_including_tsvc(self):
        from types import SimpleNamespace
        _, summary, _ = self.run_cv("population")
        before = self.db.read_bytes()
        with patch.object(vt, "ensure_compiler", return_value=Path("/fake/clang")), \
             patch.object(baseline.subprocess, "run", return_value=SimpleNamespace(stdout="test clang")), \
             patch.object(vt, "compile_report", return_value=SimpleNamespace(returncode=0, stderr=emitted())) as compile_, \
             patch("sys.stdout", new_callable=io.StringIO), patch("sys.stderr", new_callable=io.StringIO):
            self.assertEqual(baseline.main(["--db", str(self.db)]), 0)
        ids = [call.args[1].id for call in compile_.call_args_list]
        self.assertEqual(ids, [r["id"] for r in summary["benchmarks"]])
        self.assertEqual(len(ids), len(set(ids)))
        self.assertIn("tsvc/tsvc-s000-l00", ids)
        self.assertEqual(self.db.read_bytes(), before)


class CLITests(unittest.TestCase):
    def test_requires_output_directory_and_rejects_old_evaluation_options(self):
        invalid = [[], *(["--output-dir", "unused", *option] for option in (
            ["--benchmark", "tsvc/tsvc-s000-l00"], ["--weights", "weights.json"],
            ["--json-output", "results.json"], ["--exclude-reasons"],
            ["--compiler-mode", "direct"], ["--split", "validation"]))]
        for argv in invalid:
            with self.subTest(argv=argv), patch.object(vt, "load_database") as load, \
                 patch.object(vt, "ensure_compiler") as build, patch("sys.stderr", new_callable=io.StringIO):
                with self.assertRaises(SystemExit) as exit_:
                    cv.main(argv)
                self.assertEqual(exit_.exception.code, 2)
                load.assert_not_called()
                build.assert_not_called()


if __name__ == "__main__":
    unittest.main()
