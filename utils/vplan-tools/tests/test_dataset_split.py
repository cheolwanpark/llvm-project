"""Safety and reproducibility checks for the standalone dataset partition tool."""

from collections import Counter
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest


TOOLS = Path(__file__).resolve().parents[1]
SCRIPT = TOOLS / "split-dataset"


class DatasetSplitTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="vplan-split-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.database = self.root / "dataset.sqlite"
        self.manifest_path = self.root / "split.json"
        self.manifest = {
            "schema_version": 1,
            "expected_counts": {
                "benchmarks": {"total": 4, "tuning": 2, "validation": 2},
                "measurements": {"total": 16, "tuning": 7, "validation": 9},
            },
            "families": {
                "train-family": {"split": "tuning", "reason": "Related source variants."},
                "holdout-family": {"split": "validation", "reason": "Independent family."},
            },
            "benchmarks": [],
        }
        with sqlite3.connect(self.database) as db:
            db.executescript("""
                CREATE TABLE dataset (
                    id INTEGER PRIMARY KEY, target TEXT,
                    measurement_compiler TEXT, measurement_protocol_json TEXT);
                CREATE TABLE benchmarks (
                    id TEXT PRIMARY KEY, split TEXT NOT NULL,
                    source TEXT NOT NULL, compile_args_json TEXT NOT NULL,
                    workload_json TEXT NOT NULL);
                CREATE TABLE measurements (
                    benchmark_id TEXT REFERENCES benchmarks(id),
                    vf INTEGER, cycles INTEGER, PRIMARY KEY (benchmark_id, vf));
                INSERT INTO dataset VALUES (1, 'target', 'compiler', '{"vlen_bits":128}');
            """)
            for index, (benchmark_id, measured) in enumerate(zip("abcd", (4, 3, 4, 5))):
                source = f"void selected_kernel(void) {{ /* {benchmark_id} */ }}\n"
                split = "tuning" if index < 2 else "validation"
                self.manifest["benchmarks"].append({
                    "id": benchmark_id,
                    "family": "train-family" if index < 2 else "holdout-family",
                    "source_sha256": hashlib.sha256(source.encode()).hexdigest(),
                    "split": split,
                })
                db.execute("INSERT INTO benchmarks VALUES (?, 'validation', ?, ?, ?)",
                           (benchmark_id, source, '["-x","c","-O3"]', '{"seed":0}'))
                db.executemany("INSERT INTO measurements VALUES (?, ?, ?)",
                               [(benchmark_id, 2 ** i, 100 + index + i)
                                for i in range(measured)])
        self.write_manifest()

    def write_manifest(self):
        self.manifest_path.write_text(json.dumps(self.manifest), encoding="utf-8")

    def run_tool(self, *args):
        return subprocess.run(
            [sys.executable, "-B", str(SCRIPT), "--db", str(self.database),
             "--manifest", str(self.manifest_path), *args],
            cwd=self.root, capture_output=True, text=True, timeout=10)

    def snapshot(self):
        with sqlite3.connect(self.database) as db:
            return {
                table: db.execute(f"SELECT * FROM {table} ORDER BY 1, 2").fetchall()
                for table in ("dataset", "benchmarks", "measurements")
            }

    def assert_all_validation(self):
        self.assertEqual({row[1] for row in self.snapshot()["benchmarks"]}, {"validation"})

    def test_apply_changes_only_split_and_is_idempotent(self):
        before = self.snapshot()
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2 labels changed", result.stdout)
        after = self.snapshot()
        self.assertEqual(after["dataset"], before["dataset"])
        self.assertEqual(after["measurements"], before["measurements"])
        for old, new in zip(before["benchmarks"], after["benchmarks"]):
            self.assertEqual(old[:1] + old[2:], new[:1] + new[2:])
        self.assertEqual([row[1] for row in after["benchmarks"]],
                         ["tuning", "tuning", "validation", "validation"])
        again = self.run_tool()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("0 labels changed", again.stdout)
        checked = self.run_tool("--check")
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertEqual(self.snapshot(), after)

    def test_check_reports_wrong_labels_without_writing(self):
        before = self.database.read_bytes()
        result = self.run_tool("--check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("split labels differ for 2", result.stderr)
        self.assertEqual(self.database.read_bytes(), before)

    def test_changed_source_refuses_all_updates(self):
        with sqlite3.connect(self.database) as db:
            db.execute("UPDATE benchmarks SET source = source || 'changed' WHERE id = 'b'")
        before = self.snapshot()
        result = self.run_tool()
        self.assertEqual(result.returncode, 1)
        self.assertIn("source hash mismatch: b", result.stderr)
        self.assertEqual(self.snapshot(), before)

    def test_unexpected_and_missing_ids_refuse_all_updates(self):
        with sqlite3.connect(self.database) as db:
            db.execute("UPDATE benchmarks SET id = 'unexpected' WHERE id = 'b'")
        before = self.snapshot()
        result = self.run_tool()
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing=['b']", result.stderr)
        self.assertIn("unexpected=['unexpected']", result.stderr)
        self.assertEqual(self.snapshot(), before)

    def test_missing_measurements_refuse_all_updates(self):
        with sqlite3.connect(self.database) as db:
            db.execute("DELETE FROM measurements WHERE benchmark_id = 'b' AND vf = 1")
        before = self.snapshot()
        result = self.run_tool()
        self.assertEqual(result.returncode, 1)
        self.assertIn("measurement counts differ", result.stderr)
        self.assertEqual(self.snapshot(), before)

    def test_manifest_cannot_split_a_family(self):
        self.manifest["benchmarks"][0]["split"] = "validation"
        self.write_manifest()
        result = self.run_tool()
        self.assertEqual(result.returncode, 1)
        self.assertIn("family split mismatch", result.stderr)
        self.assert_all_validation()

    def test_duplicate_manifest_ids_are_rejected(self):
        self.manifest["benchmarks"][1]["id"] = "a"
        self.write_manifest()
        result = self.run_tool()
        self.assertEqual(result.returncode, 1)
        self.assertIn("duplicate benchmark id", result.stderr)
        self.assert_all_validation()

    def test_trigger_changes_to_measurements_roll_back_entire_transaction(self):
        with sqlite3.connect(self.database) as db:
            db.executescript("""
                CREATE TRIGGER corrupt AFTER UPDATE OF split ON benchmarks
                BEGIN UPDATE measurements SET cycles = cycles + 1; END;
            """)
        before = self.snapshot()
        result = self.run_tool()
        self.assertEqual(result.returncode, 1)
        self.assertIn("changed beyond split labels", result.stderr)
        self.assertEqual(self.snapshot(), before)

    def test_later_update_failure_rolls_back_earlier_labels(self):
        with sqlite3.connect(self.database) as db:
            db.executescript("""
                CREATE TRIGGER reject_b BEFORE UPDATE OF split ON benchmarks
                WHEN NEW.id = 'b'
                BEGIN SELECT RAISE(ABORT, 'blocked second update'); END;
            """)
        before = self.snapshot()
        result = self.run_tool()
        self.assertEqual(result.returncode, 1)
        self.assertIn("blocked second update", result.stderr)
        self.assertEqual(self.snapshot(), before)

    def test_missing_database_is_not_created(self):
        self.database.unlink()
        result = self.run_tool()
        self.assertEqual(result.returncode, 1)
        self.assertIn("database does not exist", result.stderr)
        self.assertFalse(self.database.exists())


class AuditedManifestTests(unittest.TestCase):
    def test_checked_in_manifest_freezes_a_complete_family_partition(self):
        manifest = json.loads((TOOLS / "dataset-split.json").read_text(encoding="utf-8"))
        entries = manifest["benchmarks"]
        self.assertEqual(len(entries), 205)
        self.assertEqual(len({entry["id"] for entry in entries}), 205)
        self.assertEqual(Counter(entry["split"] for entry in entries),
                         {"tuning": 31, "validation": 174})
        self.assertEqual(manifest["expected_counts"]["measurements"],
                         {"total": 859, "tuning": 136, "validation": 723})
        self.assertEqual(len({entry["family"] for entry in entries if entry["split"] == "tuning"}), 11)
        for entry in entries:
            family = manifest["families"][entry["family"]]
            self.assertEqual(entry["split"], family["split"])
            self.assertTrue(family["reason"])
            self.assertRegex(entry["source_sha256"], r"^[0-9a-f]{64}$")


if __name__ == "__main__":
    unittest.main()
