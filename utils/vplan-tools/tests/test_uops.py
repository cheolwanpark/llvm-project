from copy import deepcopy
from dataclasses import replace
from fractions import Fraction as Q
import io
import json
from contextlib import redirect_stdout
import unittest

from cost_model import Settings, identity, rescore, score_observation, settings_flags
from fixtures import instruction, observation, reg
from hardware_model import (accumulate_port_demands, aggregate_demand, expansion_report,
                            instruction_latency)
from kunminghu_v2 import MACHINE, expand_instruction
from model_errors import ToolError
from selection import Policy
from vplan_tools import print_report


class UopExpansionTests(unittest.TestCase):
    def expand(self, opcode, **kwargs):
        return expand_instruction(instruction(7, opcode, **kwargs))

    def test_arithmetic_topology_and_stable_identity(self):
        for opcode, lmul, sew, primary, transfer in (
            ('VADD_VV', 4, 32, 4, 0), ('VADD_VX', 4, 32, 4, 1),
            ('VFWMUL_VV', 4, 32, 8, 0), ('VFWMUL_VV', Q(1, 2), 32, 1, 0),
            ('VSLIDEUP_VX', 4, 32, 10, 1), ('VRGATHER_VV', 4, 32, 16, 0),
            ('VCOMPRESS_VM', 8, 32, 43, 0), ('VFREDUSUM_VS', 1, 32, 3, 0),
            ('VFREDOSUM_VS', 4, 32, 16, 0), ('VRGATHEREI16_VV', 4, 8, 32, 0)):
            with self.subTest(opcode=opcode, lmul=lmul):
                e = self.expand(opcode, lmul8=int(lmul * 8), sew=sew)
                self.assertEqual(e.verified_decode_uops, primary + transfer)
                self.assertEqual([(u.mir_id, u.ordinal) for u in e.uops],
                                 [(7, n) for n in range(primary + transfer)])
                self.assertEqual(sum(u.kind == 'transfer' for u in e.uops), transfer)
                self.assertTrue(all(u.origin == 'rtl-derived' for u in e.uops))
                self.assertTrue(all(r.work_units == 1 for u in e.uops for r in u.resource_uses))
                if transfer:
                    self.assertEqual(e.uops[0].kind, 'transfer')

    def test_memory_decode_counts_are_not_flow_counts(self):
        cases = [
            ('VLSE32_V', dict(load=True), 1, 2, 4),
            ('VLSE32_V', dict(load=True, lmul8=32), 4, 2, 16),
            ('VLSEG2E32_V', dict(load=True, lmul8=16), 4, 1, 16),
            ('VLSSEG2E32_V', dict(load=True, lmul8=4), 2, 2, 4),
            ('VSSE32_V', dict(store=True, lmul8=4), 1, 2, 2),
            ('VLE32_V', dict(load=True, lmul8=4), 1, 1, 1),
            ('VLUXEI64_V', dict(load=True, index_eew=64, index_emul8=16), 2, 1, 4),
            ('VLOXEI64_V', dict(load=True, index_eew=64, index_emul8=16), 2, 1, 4),
            ('VL4RE64_V', dict(load=True, operands=[reg(0, 1) | {'group8': 32}]), 4, 1, 4),
        ]
        for name, kw, count, transfers, flows in cases:
            with self.subTest(name=name, kw=kw):
                e = self.expand(name, **kw)
                self.assertEqual(e.verified_decode_uops, count + transfers)
                memory = [u for u in e.uops if u.kind == 'vector-memory']
                self.assertEqual(len(memory), count)
                self.assertEqual(sum(r.work_units for u in memory for r in u.resource_uses), flows)
                self.assertTrue(all(u.resource_uses[0].work_units == Q(flows, count) for u in memory))
                self.assertTrue(memory[0].resource_uses[0].evidence[0].assumed)
                summary = accumulate_port_demands([e], MACHINE)
                self.assertEqual(sum(v for _, v in summary.port_demands), sum(u.demand for u in e.uops))

    def test_store_two_required_resources_and_parallel_timing(self):
        e = self.expand('SD', store=True)
        self.assertEqual(e.verified_decode_uops, 1)
        self.assertEqual([r.demand_key for r in e.uops[0].resource_uses], ['sta', 'std'])
        summary = accumulate_port_demands([e], MACHINE)
        self.assertEqual({p: v for p, v in summary.port_demands if v},
                         dict(STA0=Q(1, 2), STA1=Q(1, 2), STD0=Q(1, 2), STD1=Q(1, 2)))
        self.assertEqual(aggregate_demand(summary, 'sum'), 2)
        self.assertEqual(instruction_latency(e)['latency'], 2)

    def test_memory_geometry_does_not_claim_a_vtype_lmul_or_sew(self):
        e = self.expand('VLE32_V', load=True, lmul8=16, sew=64)
        self.assertEqual(dict(e.uops[0].geometry), dict(data_emul=2, eew=32, fields=1))
        e = self.expand('VLUXEI64_V', load=True, sew=32, index_eew=64, index_emul8=16)
        self.assertEqual(dict(e.uops[0].geometry),
                         dict(data_emul=1, eew=32, fields=1, index_emul=2, index_eew=64))

    def test_work_assignment_and_timing_independent_of_demand_rate(self):
        op = instruction(0, 'VLSE32_V', load=True, lmul8=32)
        original = expand_instruction(op)
        altered = replace(MACHINE, classes=tuple(replace(c, demand_per_unit=Q(7, 3))
                    if c.name == 'vload_element' else c for c in MACHINE.classes))
        changed = expand_instruction(op, altered)
        self.assertEqual(instruction_latency(original), instruction_latency(changed))
        self.assertEqual(original.verified_decode_uops, changed.verified_decode_uops)
        self.assertEqual([r.work_units for u in original.uops for r in u.resource_uses],
                         [r.work_units for u in changed.uops for r in u.resource_uses])
        self.assertEqual(dict(accumulate_port_demands([changed], altered).class_demands),
                         {'i2v': 2, 'vload_element': Q(112, 3)})

    def test_unverified_pseudos_and_unknowns_are_explicit(self):
        for name, kw, origin in [('UNKNOWN', {}, 'fallback'), ('PseudoRET', {'pseudo': True}, 'assumed'),
            ('COPY', {'vector': True, 'operands': [reg(0, 1) | {'group8': 32}]}, 'assumed')]:
            e = self.expand(name, **kw)
            self.assertIsNone(e.verified_decode_uops)
            self.assertTrue(all(u.origin == origin for u in e.uops))
        for kw in (dict(meta=True), dict(configuration=True)):
            with self.assertRaises(ToolError):
                self.expand('VADD_VV', **kw)


class ExactScoringTests(unittest.TestCase):
    def test_exact_thirds_and_decimal_tail_input(self):
        a = observation([instruction(0, 'BNE')], exact_trip_count=8, scalar_cost=0.1,
                        iteration_width=3, max_trip_count=8)
        r = score_observation(a)
        self.assertEqual(r['middle_end']['unscaled_additions']['scalar_tail'], '1/5')
        self.assertEqual(r['features'], dict(body_scale='2/3', fixed_additions='1/5'))
        self.assertEqual(r['score_exact'], '13/15')
        a.update(exact_trip_count=0)
        r = score_observation(a)
        self.assertEqual(r['body_iterations'], '1/3')
        self.assertEqual(r['score_exact'], '1/9')

    def test_policies_rescore_and_json_roundtrip(self):
        a = observation([instruction(0, 'MUL'), instruction(1, 'SD', store=True)])
        base = score_observation(a)
        for settings in (Settings(), Settings(window='disabled'),
                         Settings(aggregation='sum', window='disabled', body_scale='7/3')):
            with self.subTest(settings=settings):
                r = score_observation(a, settings)
                self.assertEqual(rescore(json.loads(json.dumps(base)), settings), r)
                self.assertEqual(r['identity'], identity(settings))
                self.assertEqual(r['demand_cost'], r['demand_' + settings.aggregation])
                self.assertEqual(r['window_cost'] is None, settings.window == 'disabled')
                self.assertIn(settings.window, settings_flags(settings))
                with redirect_stdout(io.StringIO()) as stream:
                    print_report(r, detail=True)
                self.assertIn('uops=', stream.getvalue())
        for kw in (dict(aggregation='sum'), dict(window='unknown'), dict(aggregation='unknown')):
            with self.assertRaises(ToolError): Settings(**kw)

    def test_report_redundancies_are_validated(self):
        original = score_observation(observation([instruction(0)]))
        for path in [('ops', 0, 'uops', 0, 'demand'),
                     ('ops', 0, 'uops', 0, 'resource_uses', 0, 'demand'),
                     ('ops', 0, 'uops', 0, 'resource_uses', 0, 'work_units'),
                     ('ops', 0, 'expansion', 'modeled_uop_count'),
                     ('ops', 0, 'timing', 'latency'), ('demand_max',)]:
            bad = deepcopy(original)
            obj = bad
            for key in path[:-1]: obj = obj[key]
            obj[path[-1]] = 99
            with self.subTest(path=path), self.assertRaises(ToolError):
                rescore(bad)

    def test_exact_ranking_and_deterministic_ties(self):
        p = Policy()
        rows = [(dict(id='a', vf='s1'), dict(status='scored', score=1., score_exact='9007199254740993/9007199254740992')),
                (dict(id='b', vf='s2'), dict(status='scored', score=1., score_exact='1'))]
        self.assertEqual(p.choose(rows)['id'], 'b')
        rows[0][1]['score_exact'] = '1'
        self.assertEqual(p.choose(rows)['id'], 'a')
        rows.append((dict(id='0', vf='s1'), rows[0][1]))
        self.assertEqual(p.choose(rows)['id'], '0')


if __name__ == '__main__':
    unittest.main()
