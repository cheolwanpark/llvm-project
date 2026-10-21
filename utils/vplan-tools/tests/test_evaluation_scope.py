"""Scalable-only evaluations must ignore fixed costs, facts and failures."""
import copy
import json
from pathlib import Path
import runpy
import sys
import tempfile
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
from evaluation_scope import evaluation_policy, scope_prepared
from selection import select_loops
from test_middle_end_model import candidate, loop

REPLAY = runpy.run_path(str(TOOLS / 'evaluate-memory-cost'))


def prep():
    fixed, small, large = candidate('f4', cost=0), candidate('s1', cost=40, width=2), candidate('s4', cost=120)
    candidates = [fixed, small, large]
    statuses = [dict(id=c['id'], status='scored', breakdown=dict(effective_body_quarters=c['middle_end']['original']))
                for c in candidates]
    return dict(manifest=dict(candidates=candidates, loops=[loop(scalar=0)]), statuses=statuses,
                data={}, errors=[], removal_errors=[])


class EvaluationScopeTests(unittest.TestCase):
    def test_fixed_and_scalar_cannot_win_even_when_cheaper(self):
        p = prep()
        # A fixed status with no cost must never be dereferenced.
        p['statuses'][0].pop('breakdown')
        choice = select_loops(evaluation_policy('scalable'), p['manifest'], p['statuses'])[0]
        self.assertEqual(choice['id'], 'kernel:0:0:s4')
        self.assertFalse(choice['scalar'])
        p['statuses'][2]['status'] = 'illegal'
        choice = select_loops(evaluation_policy('scalable'), p['manifest'], p['statuses'])[0]
        self.assertEqual(choice['id'], 'kernel:0:0:s1')

    def test_fixed_errors_and_facts_removed_without_changing_input(self):
        p = prep()
        cid = p['manifest']['candidates'][0]['id']
        p['data'][cid] = {'facts': 'unreadable fixed facts'}
        p['errors'] = p['removal_errors'] = [dict(candidate=cid, reason='unsupported fixed memory')]
        before = copy.deepcopy(p)
        scoped = scope_prepared(p)
        self.assertEqual(len(scoped['manifest']['candidates']), 2)
        self.assertFalse(scoped['data'] or scoped['errors'] or scoped['removal_errors'])
        self.assertEqual(p, before)

    def test_replay_never_prices_fixed_and_preserves_scalar_tail_comparison(self):
        p = prep()
        cid = p['manifest']['candidates'][0]['id']
        p['data'][cid] = {'facts': 'poison'}
        old = dict(id='kernel', status='scored', measured_cycles={'1':100,'4':80})
        with patch.dict(REPLAY['project'].__globals__, apply_memory_cost=lambda *a, **k: self.fail('priced fixed')):
            priced = REPLAY['project'](old,p,mode='replace',stage='stride')
        self.assertEqual(len(priced['candidates']), 2)
        a, b = candidate('s4', cost=32, width=8), candidate('s8', cost=36, width=16)
        rows = [(c, dict(status='scored', breakdown=dict(effective_body_quarters=c['middle_end']['original']))) for c in (a, b)]
        policy = evaluation_policy('scalable')
        self.assertEqual(policy.choose_loop(rows, loop())['vf'], 's8')
        self.assertEqual(policy.choose_loop(rows, loop(trip=8))['vf'], 's4')

    def test_no_scalable_candidate_is_explicit_not_a_fixed_fallback(self):
        p = prep()
        for s in p['statuses'][1:]:
            s['status'] = 'illegal'
        old = dict(id='kernel', status='scored', actual_selection={'main_vf': 'f4'}, measured_cycles={'1': 100, '4': 80})
        row = REPLAY['project'](old, p)
        self.assertEqual(row['status'], 'no-scalable-candidates')
        self.assertIsNone(row['vf'])
        self.assertFalse(row['eligible'])
        self.assertFalse(row['candidates'])

    def test_repricing_is_isolated_and_fallback_preserves_all_costs(self):
        p=prep()
        cid=p['manifest']['candidates'][1]['id']
        p['data'][cid]=dict(observation={},terms={})
        old=dict(id='kernel',status='scored',measured_cycles={'1':100,'4':80})
        before=copy.deepcopy(p)
        with patch.dict(REPLAY['project'].__globals__,
                        apply_memory_cost=lambda *a,**k:dict(effective_body_quarters=0)):
            row=REPLAY['project'](old,p,mode='replace',stage='stride')
        self.assertEqual(row['vf'],'s1')
        self.assertEqual(p,before)
        p['removal_errors']=[dict(candidate=cid,reason='unattributed cost')]
        before=copy.deepcopy(p)
        with patch.dict(REPLAY['project'].__globals__,
                        apply_memory_cost=lambda *a,**k:self.fail('repriced fallback')):
            row=REPLAY['project'](old,p,mode='replace',stage='stride')
        self.assertEqual(row['vf'],'s4')
        self.assertEqual(row['fallback'],p['removal_errors'])
        self.assertEqual(p,before)

    def test_prepare_does_not_read_fixed_analytics_or_validate_fixed_cost(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            backend = root / 'run-test/backend'
            backend.mkdir(parents=True)
            p = prep()
            # Keep a deliberately malformed fixed candidate and one scalable
            # candidate. Fixed analytics and saved all-candidate selection do
            # not exist; a scalable evaluation must not try opening either.
            p['manifest']['candidates'] = p['manifest']['candidates'][:2]
            p['manifest']['candidates'][0].pop('middle_end')
            p['manifest']['run_id'] = 'test'
            statuses = p['statuses'][:2]
            statuses[0]['analytics'] = str(root / 'missing-fixed.json')
            statuses[1]['analytics'] = str(backend / 'scalable.analytics.json')
            (backend / 'candidates.json').write_text(json.dumps(p['manifest']))
            (backend / 'candidate-status.json').write_text(json.dumps(dict(candidates=statuses)))
            (backend / 'scalable.analytics.json').write_text('{}')
            (backend / 'scalable.mir').write_text('test')
            (root / 'detail.json').write_text('{}')
            def validate(parsed, manifest):
                self.assertEqual([c['vf'] for c in manifest['candidates']], ['s1'])
            hooks = dict(validate_manifest_costs=validate, bind_observation=lambda *a: {},
                         backend_cost=lambda *a: dict(effective_body_quarters=40),
                         extract_memory=lambda *a, **k: {}, memory_terms=lambda *a, **k: {},
                         llvm_memory_cost=lambda *a: dict(quarters=0))
            with patch.dict(REPLAY['prepare'].__globals__, hooks):
                result = REPLAY['prepare'](dict(id='kernel', status='scored', artifacts=str(root)),
                                           dict(json=str(root / 'detail.json')), {})
            self.assertEqual(list(result['data']), ['kernel:0:0:s1'])


if __name__ == '__main__':
    unittest.main()
