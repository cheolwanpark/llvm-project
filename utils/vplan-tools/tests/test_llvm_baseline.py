"""Ordinary LLVM final-selection parsing and measurement population tests."""
from pathlib import Path
import io
import sqlite3
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import llvm_baseline as baseline
import vplan_tools as vt
from test_vplan_tools import database, report


def emitted(vf='s2', outcome='vectorization-emitted', ic='1', epilogue='not-evaluated'):
    text = report([(0, 's1', 1, 2, 1), (1, 's2', 2, 4, 2)])
    final = (f'  selected-for-main plan=1 vf={vf}\n'
             f'  selected-for-epilogue plan=none vf={epilogue}\n'
             f'  selected_interleave_count={ic}\n'
             f'  outcome={outcome}')
    return text.replace('  outcome=vectorization-emitted', final)


class LLVMSelectionTests(unittest.TestCase):
    def setUp(self):
        self.benchmark = vt.Benchmark('kernel', 'validation', '', [], {}, {1: 100, 2: 150, 32: 1, 64: 2})

    def row(self, text, code=0):
        return baseline.selection_row(self.benchmark, SimpleNamespace(returncode=code, stderr=text))

    def test_final_selection_not_cost_argmin_and_db_extras_ignored(self):
        row = self.row(emitted())
        self.assertTrue(row['eligible'])
        self.assertEqual(row['selected_vf'], 2)
        self.assertFalse(row['top1_correct'])
        self.assertEqual(row['top1_regret'], .5)
        self.assertEqual(row['measured_cycles'], {'1': 100, '2': 150})
        self.assertEqual(row['ignored_measured_cycles'], {'32': 1, '64': 2})
        self.assertEqual(row['evaluated_vfs'], [1, 2])

    def test_late_rejection_and_fixed_scalar_selections_are_not_scored(self):
        for text, status in ((emitted(outcome='vectorization-rejected'), 'not-vectorized'),
                             (emitted(vf='not-evaluated', outcome='no-plan'), 'not-vectorized'),
                             (emitted(vf='f2'), 'unmeasured-vf'),
                             (emitted(vf='f1'), 'scalar-selection'),
                             (emitted(ic='2'), 'measurement-context-mismatch'),
                             (emitted(epilogue='s1'), 'measurement-context-mismatch')):
            with self.subTest(text=text):
                row = self.row(text)
                self.assertEqual(row['status'], status)
                self.assertIsNone(row['top1_regret'])

    def test_missing_unselected_measurement_excludes(self):
        del self.benchmark.measured[1]
        row = self.row(emitted())
        self.assertEqual(row['status'], 'missing-measurements')
        self.assertIn('s1', row['reason'])

    def test_unavailable_candidate_cost_does_not_hide_required_measurement(self):
        text = emitted().replace('| 1 | 1 | whole-loop', '| Invalid | Invalid | whole-loop')
        self.assertTrue(self.row(text)['eligible'])
        del self.benchmark.measured[1]
        self.assertEqual(self.row(text)['status'], 'missing-measurements')

    def test_shortcut_selection_requires_its_measurement(self):
        self.assertEqual(self.row(emitted(vf='s4'))['status'], 'missing-measurements')

    def test_reports_and_compilation_failures_remain_explicit(self):
        for text, status in (('', 'no-report'), (emitted() * 2, 'ambiguous-loops'),
                             (emitted().replace('End VPlan report', ''), 'invalid-report'),
                             (emitted().replace('  selected_interleave_count=1\n', ''), 'invalid-report'),
                             (emitted().replace('report_version=2', 'report_version=9'), 'invalid-report')):
            with self.subTest(status=status):
                self.assertEqual(self.row(text)['status'], status)
        self.assertTrue(self.row('compiler error', code=1)['compile_failed'])

class BaselineCLITests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='vplan-baseline-test-')
        self.addCleanup(temporary.cleanup)
        self.db = Path(temporary.name) / 'dataset.sqlite'
        database(self.db)

    def test_exact_id_can_select_former_tuning_data(self):
        with patch.object(vt, 'ensure_compiler', return_value=Path('/fake/clang')), \
             patch.object(baseline.subprocess, 'run', return_value=SimpleNamespace(stdout='test clang')), \
             patch.object(vt, 'compile_report', return_value=SimpleNamespace(returncode=0, stderr=emitted())) as compile_, \
             patch('sys.stdout', new_callable=io.StringIO), patch('sys.stderr', new_callable=io.StringIO):
            # The tiny fixture has only one VF for this ID, so it is attempted
            # and explicitly excluded instead of being hidden by a split filter.
            self.assertEqual(baseline.main(['--db', str(self.db), '--benchmark', 'train']), 1)
        compile_.assert_called_once()
        self.assertEqual(compile_.call_args.args[1].id, 'train')

    def test_absent_id_and_empty_population_fail_before_build(self):
        with patch.object(vt, 'ensure_compiler') as build:
            with self.assertRaisesRegex(vt.ToolError, 'unknown benchmark: absent'):
                baseline.main(['--db', str(self.db), '--benchmark', 'absent'])
            with sqlite3.connect(self.db) as con:
                con.execute('DELETE FROM measurements')
                con.execute('DELETE FROM benchmarks')
            with self.assertRaisesRegex(vt.ToolError, 'database contains no benchmarks'):
                baseline.main(['--db', str(self.db)])
            build.assert_not_called()

    def test_compile_failure_does_not_skip_remaining_ids(self):
        results = [SimpleNamespace(returncode=1, stderr='compiler failure'),
                   SimpleNamespace(returncode=0, stderr=emitted())]
        with patch.object(vt, 'ensure_compiler', return_value=Path('/fake/clang')) as build, \
             patch.object(baseline.subprocess, 'run', return_value=SimpleNamespace(stdout='test clang')), \
             patch.object(vt, 'compile_report', side_effect=results) as compile_, \
             patch('sys.stdout', new_callable=io.StringIO) as output, \
             patch('sys.stderr', new_callable=io.StringIO):
            self.assertEqual(baseline.main(['--db', str(self.db)]), 1)
        build.assert_called_once()
        self.assertEqual([call.args[1].id for call in compile_.call_args_list], ['example', 'train'])
        self.assertIn('total=2', output.getvalue())
        self.assertIn('compile_failed=1', output.getvalue())


if __name__ == '__main__':
    unittest.main()
