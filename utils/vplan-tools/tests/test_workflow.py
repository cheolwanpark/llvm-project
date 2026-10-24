from dataclasses import replace
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch
from cost_model import Settings
from evaluation import dataset_fingerprint
from evaluation import compare, evaluate, summarize_rows
from model_errors import ToolError
from selection import Policy, select_loops
import vplan_tools as vt


def example(id_='a'):
    b = vt.Benchmark(id_, 'validation', 'source', ['-O3'], {}, {1: 20, 2: 10})
    a = dict(body_scale=2., fixed_additions=1.)
    c = dict(body_scale=1., fixed_additions=4.)
    return dict(benchmark=b, candidates={1: [dict(features=a, candidate='a')], 2: [dict(features=c, candidate='b')]}, coverage=[], reason=None)


class EvaluationTests(unittest.TestCase):
    def test_metrics_regret_and_pooled_quantile(self):
        row = evaluate(example())
        self.assertEqual(row['selected_vf'], 1)
        self.assertEqual(row['top1_regret'], 1.)
        summary = summarize_rows([row, dict(row, id='b', top1_regret=0.)])
        self.assertEqual(summary['top1_regret']['mean'], .5)
        self.assertEqual(summary['top1_regret']['p95'], .95)
        self.assertEqual(summary['top1_regret']['worst'], 1.)
        self.assertEqual(summary['worst_cases'][0], dict(id='a', selected_vf=1, oracle_vf=2, regret=1.))

    def test_empty_metrics_have_no_fabricated_results(self):
        summary = summarize_rows([])
        self.assertIsNone(summary['top1']['exact'])
        self.assertIsNone(summary['top1_regret']['mean'])
        self.assertIsNone(summary['top1_regret']['worst'])
        self.assertEqual(summary['worst_cases'], [])

    def test_measurements_do_not_change_fixed_selection(self):
        e = example(); before = evaluate(e)
        e['benchmark'].measured = {1: 1, 2: 1000000}
        after = evaluate(e)
        self.assertEqual(before['scores'], after['scores'])
        self.assertEqual(before['selected_vf'], after['selected_vf'])
        self.assertNotEqual(before['top1_regret'], after['top1_regret'])

    def test_multi_plan_minimum(self):
        e = example(); best = dict(body_scale=.1, fixed_additions=0.)
        e['candidates'][2].append(dict(features=best, candidate='better'))
        self.assertEqual(evaluate(e)['selected_vf'], 2)

    def test_failed_candidates_not_dropped(self):
        e = example(); e['reason'] = 'candidate s2 failed'
        row = evaluate(e)
        self.assertFalse(row['eligible'])
        self.assertEqual(row['reason'], e['reason'])

    def test_matching_baseline_population(self):
        row = evaluate(example())
        self.assertEqual(compare([row], [row])['matched_population'], ['a'])
        self.assertEqual(compare([row], [dict(row, evaluated_vfs=[1, 2, 4])])['matched_population'], [])
        with self.assertRaises(ToolError): compare([row], [dict(row, id='other')])

    def test_selection_scalable_only_and_status_identity(self):
        p = object.__new__(Policy)
        rows = [(dict(id='fixed', vf='f8'), dict(status='scored', score=-10, score_exact='-10')),
                (dict(id='scalable', vf='s1'), dict(status='scored', score=2, score_exact='2'))]
        self.assertEqual(p.choose(rows)['id'], 'scalable')
        with self.assertRaises(ToolError): select_loops(p, dict(candidates=[dict(id='a')], loops=[]), [dict(id='b')])


class DatabaseTests(unittest.TestCase):
    def make_db(self, root):
        p = Path(root) / 'db.sqlite'
        with sqlite3.connect(p) as c:
            c.executescript('''CREATE TABLE dataset(id INTEGER, target TEXT, measurement_compiler TEXT, measurement_protocol_json TEXT);
            CREATE TABLE benchmarks(id TEXT, split TEXT, source TEXT, compile_args_json TEXT, workload_json TEXT);
            CREATE TABLE measurements(benchmark_id TEXT, vf INTEGER, cycles INTEGER);''')
            c.execute('INSERT INTO dataset VALUES(1,?,?,?)', ('target', 'compiler', '{}'))
            c.execute('INSERT INTO benchmarks VALUES(?,?,?,?,?)', ('a', 'any-historical-label', 'source', '["-O3"]', '{}'))
            c.executemany('INSERT INTO measurements VALUES(?,?,?)', [('a', 1, 10), ('a', 2, 12)])
        return p

    def test_read_only_and_scalable_one(self):
        with tempfile.TemporaryDirectory() as td:
            p = self.make_db(td); before = p.read_bytes()
            benchmarks, metadata = vt.load_database(p)
            self.assertEqual(benchmarks[0].measured[1], 10)
            self.assertEqual(benchmarks[0].kind, 'any-historical-label')
            self.assertEqual(before, p.read_bytes())
            self.assertFalse(list(Path(td).glob('*-journal')))

    def test_missing_db_not_created(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / 'missing'
            with self.assertRaises(ToolError): vt.load_database(p)
            self.assertFalse(p.exists())

    def test_default_root_and_environment_precedence(self):
        self.assertEqual(vt.DEFAULT_DB, Path(__file__).resolve().parents[3] / 'search-dataset.sqlite')
        with patch.dict(os.environ, {'VPLAN_DB': '/tmp/custom.sqlite'}):
            args = vt.argument_parser('test').parse_args([])
            self.assertEqual(args.db, Path('/tmp/custom.sqlite'))
            args = vt.argument_parser('test').parse_args(['--db', '/tmp/explicit.sqlite'])
            self.assertEqual(args.db, Path('/tmp/explicit.sqlite'))

    def test_measurement_population_not_vf_cutoff(self):
        b = vt.Benchmark('a', 'validation', 'source', [], {}, {1: 10, 16: 20, 32: 30})
        restricted = vt.restrict_measurements(b, {1, 32})
        self.assertEqual(restricted.measured, {1: 10, 32: 30})
        self.assertEqual(restricted.ignored_measured, {16: 20})
        with self.assertRaises(ToolError): vt.restrict_measurements(b, {1, 8})

    def test_dataset_fingerprint_ignores_split(self):
        b = example()['benchmark']; first = dataset_fingerprint([b], {})
        self.assertEqual(first, dataset_fingerprint([replace(b, kind='other')], {}))
        self.assertNotEqual(first, dataset_fingerprint([replace(b, source='different')], {}))
        self.assertNotEqual(first, dataset_fingerprint([replace(b, measured={1: 12, 2: 13})], {}))


class CacheContractTests(unittest.TestCase):
    def test_bound_cost_raw_json_and_mir_are_checked_together(self):
        import json
        from copy import deepcopy
        from collection import CACHE_SCHEMA, digest_file, validate_bundle
        from fixtures import observation
        a = observation()
        loop = dict(function=a['function'], loop=0, scalar_cost=a['scalar_cost'], max_trip_count=16, exact_trip_count=16)
        candidate = dict(id=a['candidate'], function=a['function'], loop=0, vf='s2', estimated_width=4,
                         probeable=True, scalar_tail=True, middle_end=a['middle_end'])
        manifest = dict(version=4, run_id='test', loops=[loop], candidates=[candidate], selections=[], failures=[])
        with tempfile.TemporaryDirectory() as td:
            mir = Path(td) / 'probe-0000.mir'; mir.write_text('complete MIR artifact')
            raw = dict(a); raw.pop('middle_end'); raw.pop('scalar_cost')
            raw_path = mir.with_suffix('.analytics.json'); raw_path.write_text(json.dumps(raw))
            bundle = dict(schema=CACHE_SCHEMA, key='key', compiler_context={}, manifest=manifest,
                          rows=[dict(candidate=candidate, observation=a, mir=str(mir), mir_sha256=digest_file(mir))])
            validate_bundle(bundle, {}, 'key')
            corrupted = deepcopy(bundle); corrupted['rows'][0]['observation']['scalar_cost'] = 1000
            with self.assertRaises(ToolError): validate_bundle(corrupted, {}, 'key')
            bad_raw = deepcopy(raw); bad_raw['instructions'][0]['mir'] = 'changed MIR text'
            raw_path.write_text(json.dumps(bad_raw))
            with self.assertRaises(ToolError): validate_bundle(bundle, {}, 'key')
            raw_path.write_text(json.dumps(raw)); mir.write_text('changed artifact')
            with self.assertRaises(ToolError): validate_bundle(bundle, {}, 'key')
