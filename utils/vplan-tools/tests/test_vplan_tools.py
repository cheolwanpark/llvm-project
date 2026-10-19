"""Run from this uv project: uv run python -B -m unittest discover -s tests -v."""

from fractions import Fraction
import io
import os
import runpy
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import vplan_tools as vt


def benchmark(cycles=(10, 20, 30, 40)):
    return vt.Benchmark("example", "validation", "void selected_kernel(void) {}",
                        ["-O2"], {}, {2 ** i: c for i, c in enumerate(cycles)})


def database(path):
    with sqlite3.connect(path) as db:
        db.executescript("""
            CREATE TABLE dataset(id, target, measurement_compiler, measurement_protocol_json);
            INSERT INTO dataset VALUES(1, 'xiangshan', 'revision', '{}');
            CREATE TABLE benchmarks(id, split, source, compile_args_json, workload_json);
            INSERT INTO benchmarks VALUES('example', 'validation', 'source', '["-O3"]', '{}');
            INSERT INTO benchmarks VALUES('train', 'tuning', 'source', '["-O3"]', '{}');
            CREATE TABLE measurements(benchmark_id, vf, cycles);
            INSERT INTO measurements VALUES('example', 1, 20), ('example', 2, 30), ('train', 1, 99);
        """)


def report(candidates, *, trip_count=64, function="selected_kernel", version=2):
    """Candidate: (plan, vf spelling, body cost, width, whole-loop score)."""
    lines = [f"VPlan report_version={version} module=kernel invocation=0 function={function} loop=0 header=loop depth=1",
             "  cost_kind=reciprocal_throughput units=model-units opt_for_size=0 tuning_vscale=2",
             "  scalar-baseline cost=10", "  candidates:",
             "    phase | plan | vf | estimated_width | body_cost | score | score_kind | vs_incumbent | vs_scalar | reason"]
    for plan, vf, cost, width, total in candidates:
        score = total if trip_count else f"{cost}/{width}"
        kind = "whole-loop" if trip_count else "cost-per-lane"
        lines.append(f"    main | {plan} | {vf} | {width} | {cost} | {score} | {kind} | yes (plan=0 vf=f1; known-trip-count) | yes (scalar; known-trip-count) | -")
    return "\n".join(lines + ["  outcome=vectorization-emitted", "End VPlan report", ""])


class ReportTests(unittest.TestCase):
    def test_known_trip_count_uses_comparison_not_raw_body_cost(self):
        parsed = vt.parse_report(report([(0, "s2", 10, 4, 160), (1, "s4", 15, 8, 120)]))
        self.assertEqual(parsed, {2: 160, 4: 120})

    def test_unknown_trip_count_and_scalable_one(self):
        parsed = vt.parse_report(report([(0, "s1", 5, 2, 0), (1, "f1", 1, 1, 0)], trip_count=0))
        self.assertEqual(parsed, {1: Fraction(5, 2)})

    def test_multiple_plans_for_same_vf_choose_minimum(self):
        self.assertEqual(vt.parse_report(report([(0, "s2", 9, 4, 145), (1, "s2", 8, 4, 129)])), {2: 129})

    def test_epilogue_and_unavailable_scores_are_not_predictions(self):
        text = report([(0, "s2", 4, 4, 64)])
        for invalid in (text.replace("    main |", "    epilogue |"),
                        text.replace("| 64 | whole-loop", "| not-evaluated | not-evaluated"),
                        text.replace("| 4 | 64 |", "| not-evaluated | 64 |"),
                        text.replace("whole-loop", "code-size")):
            with self.subTest(text=invalid), self.assertRaisesRegex(vt.ReportError, "no usable"):
                vt.parse_report(invalid)

    def test_fractional_body_cost_and_whole_loop_score(self):
        self.assertEqual(vt.parse_report(report([(0, "s2", "1.5", 4, 0)], trip_count=0)),
                         {2: Fraction(3, 8)})
        self.assertEqual(vt.parse_report(report([(0, "s2", "1.5", 4, "24.25")])),
                         {2: Fraction(97, 4)})

    def test_invalid_candidate_is_ignored(self):
        text = report([(0, "s2", "Invalid", 4, "Invalid"), (1, "s4", 8, 8, 64)])
        self.assertEqual(vt.parse_report(text), {4: 64})

    def test_compiler_subset_keeps_unavailable_candidates_for_coverage(self):
        text = report([(0, "s2", "Invalid", 4, "Invalid"), (1, "s4", 8, 8, 64)])
        candidate_vfs = set()
        scores = vt.parse_report(text, candidate_vfs)
        self.assertEqual(candidate_vfs, {2, 4})
        result = vt.score_benchmark(vt.restrict_measurements(benchmark(), candidate_vfs), scores)
        self.assertFalse(result.eligible)
        self.assertIn('s2', result.reason)

    def test_direct_compiler_subset_ignores_db_extras_but_requires_coverage(self):
        candidate_vfs = set()
        scores = vt.parse_report(report([(0, 's2', 4, 4, 64), (1, 's4', 8, 8, 128)]), candidate_vfs)
        b = benchmark((1, 100, 200, 1))
        result = vt.score_benchmark(vt.restrict_measurements(b, candidate_vfs), scores)
        self.assertEqual(result.top1_regret, 0)
        self.assertEqual(result.benchmark.ignored_measured, {1: 1, 8: 1})
        with self.assertRaisesRegex(vt.ToolError, 'missing measurements.*s4'):
            vt.restrict_measurements(benchmark((100, 200)), candidate_vfs)

    def test_report_boundaries_and_unrelated_functions(self):
        unrelated = report([(0, "s2", 100, 4, 1600)], function="other")
        text = "warning: diagnostics\n" + unrelated + report([(0, "s2", 4, 4, 64)]) + "remark: end\n"
        self.assertEqual(vt.parse_report(text), {2: 64})

    def test_rejects_truncation_version_ambiguity_and_wrong_cost_kind(self):
        text = report([(0, "s2", 4, 4, 64)])
        for invalid in (text.replace("End VPlan report", ""), text + text,
                        text.replace("report_version=2", "report_version=1"),
                        text.replace("reciprocal_throughput", "code_size")):
            with self.subTest(text=invalid[:60]), self.assertRaises(vt.ReportError):
                vt.parse_report(invalid)

    def test_detailed_evaluations_do_not_override_summary_scores(self):
        text = report([(0, "s2", 4, 4, 64)])
        details = ("  details:\n  plan=0\n"
                   "    evaluation=0 plan=0 vf=s2 phase=outside-loop-profitability\n"
                   "      candidate_cost=1 status=evaluated\n")
        self.assertEqual(vt.parse_report(text.replace("End VPlan report", details + "End VPlan report")),
                         {2: 64})

    def test_malformed_candidate_rows_and_scores_are_rejected(self):
        text = report([(0, "s2", 4, 4, 64)])
        for invalid in (text.replace("| s2 |", "| s2"),
                        *(text.replace("| 64 |", f"| {score} |")
                          for score in ("bad", "1/0", "1/", "1/2/3"))):
            with self.subTest(text=invalid), self.assertRaisesRegex(vt.ReportError, "malformed candidate"):
                vt.parse_report(invalid)


class MetricTests(unittest.TestCase):
    def score(self, costs, cycles=(10, 20, 30, 40)):
        return vt.score_benchmark(benchmark(cycles), dict(zip((1, 2, 4, 8), map(Fraction, costs))))

    def test_perfect_and_reversed(self):
        perfect = vt.aggregate([self.score((1, 2, 3, 4))])
        reversed_ = vt.aggregate([self.score((4, 3, 2, 1))])
        self.assertEqual(perfect["correlations"], [1.0])
        self.assertEqual(perfect["regrets"], [0.0])
        self.assertEqual(reversed_["correlations"], [-1.0])
        self.assertEqual(reversed_["regrets"], [3.0])
        self.assertEqual(reversed_["topk"][2]["overlap"], 0)

    def test_overlap_is_unordered_and_partial_credit_is_distinct_from_exact(self):
        swapped = vt.aggregate([self.score((2, 1, 3, 4))])
        self.assertEqual(swapped["topk"][2], {"n": 1, "overlap": 1, "exact": 1})
        partial = vt.aggregate([self.score((1, 3, 2, 4))])
        self.assertEqual(partial["topk"][2], {"n": 1, "overlap": 0.5, "exact": 0})

    def test_strict_count_thresholds_and_per_metric_denominators(self):
        results = [self.score((1, 2, 3, 4), tuple(range(1, n + 1))) for n in (1, 2, 3, 4)]
        metric = vt.aggregate(results)
        self.assertEqual([metric["topk"][k]["n"] for k in (1, 2)], [3, 2])
        self.assertEqual(metric["scored"], 3)

    def test_missing_prediction_excludes_whole_benchmark(self):
        result = vt.score_benchmark(benchmark(), {1: Fraction(1), 2: Fraction(2), 4: Fraction(3)})
        self.assertFalse(result.eligible)
        self.assertIn("s8", result.reason)
        self.assertEqual(vt.aggregate([result])["topk"][1]["n"], 0)

    def test_extra_unmeasured_predictions_do_not_affect_metrics(self):
        result = self.score((1, 2, 3, 4), (10, 20))
        self.assertEqual(set(result.scores), {1, 2})

    def test_ties_smaller_vf_and_average_rank_spearman(self):
        metric = vt.aggregate([self.score((1, 1, 1, 1))])
        self.assertEqual(metric["topk"][1]["overlap"], 1)
        self.assertEqual(metric["predicted_ties"], 1)
        self.assertEqual(metric["correlations"], [])
        self.assertAlmostEqual(vt.spearman([1, 1, 2], [1, 2, 3]), 3 ** 0.5 / 2)
        self.assertIsNone(vt.spearman([1, 2], [3, 3]))

    def test_zero_cycle_regret_is_undefined_but_ranking_is_valid(self):
        metric = vt.aggregate([self.score((1, 2), (0, 10))])
        self.assertEqual(metric["regrets"], [])
        self.assertEqual(metric["correlations"], [1])

    def test_summary_na_and_denominators(self):
        with patch("sys.stdout", new_callable=io.StringIO) as output:
            vt.print_summary("Test", [self.score((1, 2), (10, 20))])
        self.assertIn("Top-2 overlap                 N/A        0", output.getvalue())
        self.assertIn("total=1 measured=1 scored=1 excluded=0", output.getvalue())

    def test_worst_regrets_orders_and_limits_to_ten(self):
        results = []
        for index in range(12):
            result = self.score((2, 1), (100, 100 + index))
            result.benchmark.id = f"bench-{index:02d}"
            results.append(result)
        with patch("sys.stdout", new_callable=io.StringIO) as output:
            vt.print_worst_regrets(results)
        rows = [line.split() for line in output.getvalue().splitlines() if line.strip().startswith("bench-")]
        self.assertEqual(rows, [[f"bench-{index:02d}", f"{index:.2f}%"] for index in range(11, 1, -1)])

    def test_worst_regrets_ties_exclusions_and_fewer_than_ten(self):
        first, second = self.score((1, 2), (10, 20)), self.score((1, 2), (10, 20))
        first.benchmark.id, second.benchmark.id = "alpha", "beta"
        excluded = vt.Result(benchmark(), reason="missing prediction")
        undefined = self.score((1, 2), (0, 10))
        with patch("sys.stdout", new_callable=io.StringIO) as output:
            vt.print_worst_regrets([second, excluded, undefined, first])
        rows = output.getvalue().splitlines()[3:]
        self.assertEqual([line.split() for line in rows], [["alpha", "0.00%"], ["beta", "0.00%"]])
        with patch("sys.stdout", new_callable=io.StringIO) as output:
            vt.print_worst_regrets([excluded, undefined])
        self.assertIn("N/A (no benchmarks with defined regret)", output.getvalue())


class DatabaseTests(unittest.TestCase):
    def test_dataset_partition_and_read_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "dataset.sqlite"
            database(path)
            before = path.read_bytes()
            rows, metadata = vt.load_database(path, split="validation")
            self.assertEqual([r.id for r in rows], ["example"])
            self.assertEqual(rows[0].measured, {1: 20, 2: 30})
            self.assertEqual(metadata["target"], "xiangshan")
            self.assertEqual(vt.load_database(path, split="tuning")[0][0].id, "train")
            self.assertEqual(vt.load_database(path, split="validation", benchmark_id="train")[0], [])
            self.assertEqual(path.read_bytes(), before)

    def test_other_partition_payload_is_not_read_or_parsed(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "dataset.sqlite"
            database(path)
            with sqlite3.connect(path) as db:
                db.execute("UPDATE benchmarks SET compile_args_json='bad' WHERE split='tuning'")
                db.execute("UPDATE measurements SET cycles=-1 WHERE benchmark_id='train'")
            self.assertEqual(len(vt.load_database(path, split="validation")[0]), 1)
            with self.assertRaises(vt.ToolError):
                vt.load_database(path, split="tuning")

    def test_old_schema_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "old.sqlite"
            with sqlite3.connect(path) as db:
                db.execute("CREATE TABLE summary_metadata(compiler_revision, target_platform)")
            with self.assertRaisesRegex(vt.ToolError, "dataset"):
                vt.load_database(path)

    def test_missing_benchmark_column_is_an_actionable_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "dataset.sqlite"
            database(path)
            with sqlite3.connect(path) as db:
                db.execute("ALTER TABLE benchmarks DROP COLUMN workload_json")
            with self.assertRaisesRegex(vt.ToolError, "workload_json"):
                vt.load_database(path)

    def test_missing_database_is_not_created(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "absent.sqlite"
            with self.assertRaisesRegex(vt.ToolError, "does not exist"):
                vt.load_database(path)
            self.assertFalse(path.exists())


class CompilationTests(unittest.TestCase):
    def test_flags_preserve_target_and_interleave_but_remove_forced_width(self):
        raw = ["--target=riscv64-unknown-elf", "-O2", "-mllvm", "-force-vector-width=4",
               "-mllvm", "-force-vector-interleave=1", "-I", "/container/include",
               "-idirafter", "/container/libc", "-mllvm", "-enable-interleaved-mem-accesses=false"]
        flags = vt.normalized_flags(raw)
        self.assertEqual(flags, ["--target=riscv64-unknown-elf", "-O2", "-mllvm",
                                 "-force-vector-interleave=1", "-mllvm", "-enable-interleaved-mem-accesses=false"])

    def test_recorded_language_is_moved_to_source_suffix(self):
        b = benchmark()
        b.compile_args = ['-x', 'c++', '-std=gnu++20', '-O3']
        self.assertEqual(vt.source_name(b), 'kernel.cpp')
        self.assertNotIn('-x', vt.benchmark_flags(b))
        self.assertIn('-std=gnu++20', vt.benchmark_flags(b))
        self.assertIn('-riscv-v-register-bit-width-lmul=8', vt.benchmark_flags(b))
        with self.assertRaises(vt.ToolError):
            vt.normalized_flags(['-x', 'ir'])

    def test_compile_uses_provided_compiler_and_detail_and_cleans_source(self):
        observed = []
        def run(command, **kwargs):
            if '-disable-llvm-passes' in command:
                source = Path(command[command.index('-c') + 1])
                self.assertEqual(source.read_text(), benchmark().source)
                observed.append(source)
            elif command[0].endswith('llvm-extract'):
                self.assertIn('--recursive', command)
                self.assertIn('selected_kernel', command)
            else:
                self.assertEqual(command[0], "/custom/build/bin/clang")
                self.assertIn("--print-vplans", command)
                self.assertIn("--print-detailed-vplans", command)
            return subprocess.CompletedProcess(command, 0, "", "report")
        with patch("subprocess.run", side_effect=run):
            vt.compile_report(Path("/custom/build/bin/clang"), benchmark(), True, 120, compiler_mode="direct")
        self.assertFalse(observed[0].exists())

    def test_timeout_is_actionable(self):
        with patch("subprocess.run", side_effect=subprocess.TimeoutExpired("clang", 1)):
            with self.assertRaisesRegex(vt.ToolError, "timed out"):
                vt.compile_report(Path("/clang"), benchmark(), False, 1, compiler_mode="direct")


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.source = Path(self.temporary.name) / "llvm source"
        (self.source / "llvm").mkdir(parents=True)
        (self.source / "llvm/CMakeLists.txt").touch()
        (self.source / "clang").mkdir()
        self.build = self.source / "build-vplan-tools"
        self.help = subprocess.CompletedProcess([], 0, "--print-vplans\n--print-detailed-vplans", "")

    def cache(self, home=None, capability="LLVM_ENABLE_ASSERTIONS:BOOL=ON"):
        self.build.mkdir()
        (self.build / "CMakeCache.txt").write_text(
            f"CMAKE_HOME_DIRECTORY:INTERNAL={home or self.source / 'llvm'}\n{capability}\n"
            "LLVM_ENABLE_PROJECTS:STRING=clang\nLLVM_TARGETS_TO_BUILD:STRING=RISCV\n")

    def test_fresh_build_configures_and_builds_clang_once(self):
        with patch.object(vt, "run_build") as build, patch("subprocess.run", return_value=self.help):
            path = vt.ensure_compiler(self.source, None, 3)
        self.assertEqual(build.call_count, 2)
        self.assertIn("-DLLVM_ENABLE_ASSERTIONS=ON", build.call_args_list[0].args[0])
        self.assertEqual(build.call_args_list[1].args[0][-2:], ["--parallel", "3"])
        self.assertEqual(path, (self.build / "bin/clang").resolve())

    def test_existing_build_refreshes_configuration_before_checking_dependencies(self):
        self.cache()
        with patch.object(vt, "run_build") as build, patch("subprocess.run", return_value=self.help):
            vt.ensure_compiler(self.source, self.build, 2)
            vt.ensure_compiler(self.source, self.build, 2)
        self.assertEqual(build.call_count, 4)
        for offset in (0, 2):
            self.assertEqual(build.call_args_list[offset].args[0],
                             ["cmake", "-S", str((self.source / "llvm").resolve()),
                              "-B", str(self.build.resolve())])
            self.assertEqual(build.call_args_list[offset + 1].args[0][1], "--build")

    @unittest.skipUnless(shutil.which("cmake") and shutil.which("ninja"), "requires CMake and Ninja")
    def test_reuses_build_after_git_metadata_moves(self):
        # A tiny real CMake/Ninja project reproduces LLVM's configure-time VCS
        # dependency without building LLVM as part of the regression test.
        (self.source / "llvm/CMakeLists.txt").write_text('''
cmake_minimum_required(VERSION 3.20)
project(VCSDependency NONE)
set(LLVM_ENABLE_ASSERTIONS ON CACHE BOOL "")
set(LLVM_ENABLE_PROJECTS clang CACHE STRING "")
set(LLVM_TARGETS_TO_BUILD RISCV CACHE STRING "")
if(IS_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../.git")
  set(git_dir "${CMAKE_CURRENT_SOURCE_DIR}/../.git")
else()
  set(git_dir "${CMAKE_CURRENT_SOURCE_DIR}/../git-metadata")
endif()
add_custom_command(OUTPUT "${CMAKE_BINARY_DIR}/VCSRevision.h"
  COMMAND "${CMAKE_COMMAND}" -E copy "${git_dir}/logs/HEAD" "${CMAKE_BINARY_DIR}/VCSRevision.h"
  DEPENDS "${git_dir}/logs/HEAD")
add_custom_target(clang DEPENDS "${CMAKE_BINARY_DIR}/VCSRevision.h")
add_custom_target(clang-resource-headers)
add_custom_target(llvm-extract)
''')
        git_dir = self.source / ".git"
        (git_dir / "logs").mkdir(parents=True)
        (git_dir / "logs/HEAD").write_text("revision\n")
        real_run = subprocess.run
        real_run(["cmake", "-S", str(self.source / "llvm"), "-B", str(self.build), "-G", "Ninja"],
                 check=True, capture_output=True, text=True)
        git_dir.rename(self.source / "git-metadata")
        git_dir.write_text("gitdir: git-metadata\n")
        stale = real_run(["cmake", "--build", str(self.build), "--target", "clang"],
                         capture_output=True, text=True)
        self.assertNotEqual(stale.returncode, 0)
        self.assertIn(".git/logs/HEAD", stale.stderr)

        def actual_build(command):
            real_run(command, check=True, capture_output=True, text=True)

        with patch.object(vt, "run_build", side_effect=actual_build), \
                patch("subprocess.run", return_value=self.help):
            vt.ensure_compiler(self.source, self.build, 2)
            header = self.build / "VCSRevision.h"
            self.assertEqual(header.read_text(), "revision\n")
            rebuilt = header.stat().st_mtime_ns
            vt.ensure_compiler(self.source, self.build, 2)
            self.assertEqual(header.stat().st_mtime_ns, rebuilt)

    def test_wrong_source_and_missing_dump_support_are_rejected(self):
        self.cache(home="/different/llvm")
        with self.assertRaisesRegex(vt.ToolError, "another source"):
            vt.ensure_compiler(self.source, self.build, 2)
        (self.build / "CMakeCache.txt").unlink()
        (self.build / ".vplan-tools.lock").unlink()
        self.build.rmdir()
        self.cache(capability="LLVM_ENABLE_ASSERTIONS:BOOL=OFF")
        with self.assertRaisesRegex(vt.ToolError, "build needs"):
            vt.ensure_compiler(self.source, self.build, 2)

    def test_missing_reporting_flags_are_rejected_after_build(self):
        self.cache()
        with patch.object(vt, "run_build"), patch("subprocess.run", return_value=subprocess.CompletedProcess([], 0, "", "")):
            with self.assertRaisesRegex(vt.ToolError, "reporting flags"):
                vt.ensure_compiler(self.source, self.build, 2)


class CLITests(unittest.TestCase):
    def test_unknown_benchmark_fails_before_build(self):
        with patch.object(vt, "load_database", return_value=([benchmark()], {})), \
                patch.object(vt, "ensure_compiler") as build:
            with self.assertRaisesRegex(vt.ToolError, "unknown benchmark"):
                vt.print_vplans_main(["--llvm-path", "/llvm", "--benchmark", "absent"])
            build.assert_not_called()

    def test_evaluation_builds_once_and_continues_after_compile_failure(self):
        rows = [benchmark(), benchmark(), benchmark()]
        rows[0].id, rows[1].id, rows[2].id = "first", "failed", "last"
        text = report([(0, "s1", 4, 2, 128), (1, "s2", 4, 4, 64),
                       (2, "s4", 4, 8, 32), (3, "s8", 4, 16, 16)])
        successful = subprocess.CompletedProcess([], 0, "", text)
        failed = subprocess.CompletedProcess([], 1, "", "error: compiler failure")
        metadata = {"target": "xiangshan", "measurement_compiler": "original"}
        with patch.object(vt, "load_database", return_value=(rows, metadata)), \
                patch.object(vt, "ensure_compiler", return_value=Path("/custom/clang")) as build, \
                patch.object(vt, "compile_report", side_effect=[successful, failed, successful]) as compile_, \
                patch("subprocess.run", return_value=subprocess.CompletedProcess([], 0, "clang version test", "")), \
                patch("sys.stdout", new_callable=io.StringIO) as output, \
                patch("sys.stderr", new_callable=io.StringIO):
            self.assertEqual(vt.evaluate_main(["--compiler-mode", "direct", "--llvm-path", "/llvm"]), 1)
        build.assert_called_once()
        self.assertEqual(compile_.call_count, 3)
        self.assertIn("total=3 measured=3 scored=2 excluded=1 compile_failed=1", output.getvalue())
        self.assertNotIn("Excluded benchmarks:", output.getvalue())
        self.assertNotIn("failed: measured_vfs=4; compilation failed", output.getvalue())

    def test_exclusion_details_require_flag(self):
        metadata = {"target": "xiangshan", "measurement_compiler": "original"}
        for flags in ([], ["--exclude-reasons"]):
            with self.subTest(flags=flags), \
                    patch.object(vt, "load_database", return_value=([benchmark()], metadata)), \
                    patch.object(vt, "ensure_compiler", return_value=Path("/custom/clang")), \
                    patch.object(vt, "compile_report", return_value=subprocess.CompletedProcess([], 0, "", "")), \
                    patch("subprocess.run", return_value=subprocess.CompletedProcess([], 0, "clang version test", "")), \
                    patch("sys.stdout", new_callable=io.StringIO) as output, \
                    patch("sys.stderr", new_callable=io.StringIO):
                self.assertEqual(vt.evaluate_main(["--compiler-mode", "direct", "--llvm-path", "/llvm", *flags]), 1)
            self.assertIn("total=1 measured=1 scored=0 excluded=1", output.getvalue())
            self.assertEqual("Excluded benchmarks:" in output.getvalue(), bool(flags))
            self.assertEqual("example: measured_vfs=4; no VPlan report" in output.getvalue(), bool(flags))

    def test_evaluation_selects_only_one_benchmark(self):
        rows = [benchmark(), benchmark()]
        rows[0].id, rows[1].id = "first", "selected"
        text = report([(0, "s1", 4, 2, 128), (1, "s2", 4, 4, 64),
                       (2, "s4", 4, 8, 32), (3, "s8", 4, 16, 16)])
        metadata = {"target": "xiangshan", "measurement_compiler": "original"}
        with patch.object(vt, "load_database", return_value=(rows, metadata)), \
                patch.object(vt, "ensure_compiler", return_value=Path("/custom/clang")), \
                patch.object(vt, "compile_report", return_value=subprocess.CompletedProcess([], 0, "", text)) as compile_, \
                patch("subprocess.run", return_value=subprocess.CompletedProcess([], 0, "clang version test", "")), \
                patch("sys.stdout", new_callable=io.StringIO) as output, \
                patch("sys.stderr", new_callable=io.StringIO):
            self.assertEqual(vt.evaluate_main(["--compiler-mode", "direct", "--llvm-path", "/llvm", "--benchmark", "selected"]), 0)
        compile_.assert_called_once_with(Path("/custom/clang"), rows[1], False, 120,
                                             compiler_mode="direct",
                                             meta_script=Path("/llvm/utils/vplan-meta-compile"),
                                             artifacts_dir=None)
        self.assertIn("Benchmark: selected", output.getvalue())
        self.assertIn("total=1 measured=1 scored=1 excluded=0", output.getvalue())
        self.assertIn("Worst top-1 regrets (top 10):", output.getvalue())
        self.assertRegex(output.getvalue(), r"selected\s+300\.00%")

    def test_evaluation_unknown_benchmark_fails_before_build(self):
        with patch.object(vt, "load_database", return_value=([benchmark()], {})), \
                patch.object(vt, "ensure_compiler") as build:
            with self.assertRaisesRegex(vt.ToolError, "unknown benchmark: absent"):
                vt.evaluate_main(["--compiler-mode", "direct", "--llvm-path", "/llvm", "--benchmark", "absent"])
            build.assert_not_called()

    def test_evaluation_rejects_multiple_benchmarks(self):
        for args in (["--benchmark", "first", "second"],
                     ["--benchmark", "first", "--benchmark", "second"]):
            with self.subTest(args=args), patch("sys.stderr", new_callable=io.StringIO), \
                    patch.object(vt, "load_database") as load:
                with self.assertRaises(SystemExit) as exc:
                    vt.evaluate_main(["--compiler-mode", "direct", "--llvm-path", "/llvm", *args])
                self.assertEqual(exc.exception.code, 2)
                load.assert_not_called()

    def test_required_flags(self):
        with patch("sys.stderr", new_callable=io.StringIO), \
                patch.object(vt, "load_database") as load:
            with self.assertRaises(SystemExit) as exc:
                vt.print_vplans_main([])
            self.assertEqual(exc.exception.code, 2)
            load.assert_not_called()


class StandaloneTests(unittest.TestCase):
    def test_defaults_and_database_precedence(self):
        with patch.dict(os.environ, {}, clear=True):
            args = vt.argument_parser("test").parse_args([])
            self.assertEqual(args.llvm_path, vt.TOOLS.parents[1])
            self.assertEqual(args.db, vt.TOOLS.parents[1] / "dataset.sqlite")
            self.assertEqual((args.jobs, args.timeout, args.compiler_mode), (2, 120, "meta"))
        for value in ("", "relative database.sqlite", "~/database with spaces.sqlite"):
            with self.subTest(value=value), patch.dict(os.environ, {"VPLAN_DB": value}):
                args = vt.argument_parser("test").parse_args(["--llvm-path", "~/other llvm"])
                self.assertEqual(args.db, vt.resolved_path(value) if value else vt.DEFAULT_DB)
                self.assertEqual(args.llvm_path, vt.resolved_path("~/other llvm"))
                explicit = vt.argument_parser("test").parse_args(["--db", "explicit database.sqlite"])
                self.assertEqual(explicit.db, Path("explicit database.sqlite").resolve())
        # Environment selection is refreshed for each CLI parse, not at import.
        with patch.dict(os.environ, {"VPLAN_DB": "changed.sqlite"}):
            self.assertEqual(vt.argument_parser("test").parse_args([]).db,
                             Path("changed.sqlite").resolve())

    def test_path_expansion_and_foreign_cwd(self):
        with tempfile.TemporaryDirectory(prefix="vplan paths ") as temporary:
            old = Path.cwd()
            try:
                os.chdir(temporary)
                with patch.dict(os.environ, {"VPLAN_DB": ""}):
                    args = vt.argument_parser("test").parse_args([])
                    self.assertEqual(args.db, vt.DEFAULT_DB)
                    self.assertEqual(args.llvm_path, vt.DEFAULT_LLVM)
                    args = vt.argument_parser("test").parse_args([
                        "--db", "relative database.sqlite", "--build-dir", "~/build directory"])
                    self.assertEqual(args.db, Path(temporary).resolve() / "relative database.sqlite")
                    self.assertEqual(args.build_dir, Path.home() / "build directory")
            finally:
                os.chdir(old)

    def test_bad_databases_fail_before_build_without_creation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            invalid = root / "invalid.sqlite"
            invalid.write_text("not sqlite")
            wrong = root / "wrong.sqlite"
            with sqlite3.connect(wrong) as db:
                db.execute("CREATE TABLE dataset(id)")
            for path in (root / "missing.sqlite", invalid, wrong):
                before = path.read_bytes() if path.exists() else None
                for main, flags in ((vt.evaluate_main, []),
                                    (vt.print_vplans_main, ["--benchmark", "example"])):
                    with self.subTest(path=path, main=main.__name__), \
                            patch.object(vt, "ensure_compiler") as build:
                        with self.assertRaises(vt.ToolError):
                            main(["--db", str(path), *flags])
                        build.assert_not_called()
                self.assertEqual(path.read_bytes() if path.exists() else None, before)

    def test_database_connection_is_enforced_read_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "database with spaces.sqlite"
            sqlite3.connect(path).close()
            connect = sqlite3.connect
            def read_only(uri, **kwargs):
                self.assertTrue(uri.endswith("?mode=ro"))
                self.assertTrue(kwargs["uri"])
                db = connect(uri, **kwargs)
                with self.assertRaisesRegex(sqlite3.OperationalError, "readonly"):
                    db.execute("CREATE TABLE forbidden(id)")
                return db
            with patch.object(vt.sqlite3, "connect", side_effect=read_only):
                with self.assertRaises(vt.ToolError):
                    vt.load_database(path)

    def test_print_alias_forwards_same_final_report(self):
        outputs = []
        for name in ("print-vplans", "print-vplan"):
            with patch.object(vt, "load_database", return_value=([benchmark()], {})), \
                    patch.object(vt, "ensure_compiler", return_value=Path("/build/clang")), \
                    patch.object(vt, "compile_report", return_value=subprocess.CompletedProcess(
                        [], 0, "driver output", "VPlan report_version=2\nfinal report\n")) as compile_, \
                    patch("sys.argv", [name, "--compiler-mode", "direct", "--benchmark", "example", "--detail"]), \
                    patch("sys.stdout", new_callable=io.StringIO) as output:
                with self.assertRaises(SystemExit) as exit_:
                    runpy.run_path(str(vt.TOOLS / name), run_name="__main__")
                self.assertEqual(exit_.exception.code, 0)
                self.assertEqual(compile_.call_args.args[2:4], (True, 120))
                outputs.append(output.getvalue())
        self.assertEqual(outputs, ["VPlan report_version=2\nfinal report\n"] * 2)

    def test_isolated_commands_need_no_research_or_campaign_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tool_dir = root / "utils/vplan-tools"
            tool_dir.mkdir(parents=True)
            for name in ("vplan_tools.py", "model_errors.py", "calibration.py", "cost_model.py", "observations.py",
                         "selection.py", "selection_policy.py", "selection_evaluation.py", "spill_observations.py",
                         "evaluate", "print-vplans", "print-vplan"):
                shutil.copy2(vt.TOOLS / name, tool_dir / name)
            env = dict(os.environ, VPLAN_DB="", PYTHONDONTWRITEBYTECODE="1")
            for name in ("evaluate", "print-vplans", "print-vplan"):
                command = [sys.executable, "-I", "-B", "-c",
                           "import runpy,sys; sys.path.insert(0,sys.argv[1]); "
                           "sys.argv=sys.argv[2:]; runpy.run_path(sys.argv[0],run_name='__main__')",
                           str(tool_dir), str(tool_dir / name)]
                help_ = subprocess.run([*command, "--help"], cwd=root, env=env,
                                       capture_output=True, text=True)
                self.assertEqual(help_.returncode, 0, help_.stderr)
                self.assertIn("--db", help_.stdout)
                self.assertNotIn("--run", help_.stdout)
                flags = [] if name == "evaluate" else ["--benchmark", "example"]
                missing = subprocess.run([*command, *flags], cwd=root, env=env,
                                         capture_output=True, text=True)
                self.assertEqual(missing.returncode, 1)
                self.assertIn(str(root / "dataset.sqlite"), missing.stderr)
                self.assertNotIn("Traceback", missing.stderr)
            self.assertFalse((root / "dataset.sqlite").exists())
            self.assertFalse((root / "build-vplan-tools").exists())


if __name__ == "__main__":
    unittest.main()
