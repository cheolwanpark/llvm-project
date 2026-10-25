from dataclasses import replace
from fractions import Fraction as Q
import unittest

from cost_model import Settings, identity, rescore, score_observation, score_value
from hardware_model import (Evidence, Machine, Port, ServiceClass, ResourceUse, Uop, Timing,
                            TimingGroup, InstructionExpansion, accumulate_port_demands,
                            aggregate_demand, expansion_report, number)
from kunminghu_v2 import MACHINE, SOURCE_HASHES, VECTOR_OPCODES, expand_instruction
from model_errors import ToolError
from observations import validate_observation
from fixtures import edge, instruction, memory, observation, reg


def work(base, **kwargs):
    expansion = expand_instruction(instruction(0, base, **kwargs))
    summary = accumulate_port_demands([expansion], MACHINE)
    return expansion_report(expansion) | dict(
        class_demands={k: number(v) for k, v in summary.class_demands},
        port_demands={k: str(v) for k, v in summary.port_demands if v},
        assumptions=list(expansion.assumptions))


def synthetic_expansion(*uses):
    groups = tuple(TimingGroup(str(i), r.demand_key, Timing(1, 1, True, Evidence('test')))
                   for i, r in enumerate(uses))
    uop = Uop(0, 0, 'test', 'assumed', (), uses, tuple(g.id for g in groups), ())
    return InstructionExpansion(0, 'test', (uop,), None, groups)



class HardwareRules(unittest.TestCase):
    def test_vector_split_and_scalar_operand_transfer(self):
        for lmul, count in [(Q(1, 8), 1), (Q(1, 4), 1), (Q(1, 2), 1), (1, 1), (2, 2), (4, 4), (8, 8)]:
            self.assertEqual(work('VADD_VV', lmul8=int(lmul * 8), sew=8)['class_demands'], {'vialuF': count})
            self.assertEqual(work('VADD_VX', lmul8=int(lmul * 8), sew=8)['class_demands'], {'vialuF': count, 'i2v': 1})
        self.assertEqual(work('VFMUL_VF', lmul8=16)['class_demands'], {'vfma': 2, 'f2v': 1})
        self.assertEqual(work('VADD_VI')['class_demands'], {'vialuF': 1, 'i2v': 1})

    def test_nonlinear_splits_and_reductions(self):
        for opcode, expected in [('VSLIDEUP_VX', [2, 4, 11, 37]),
                                 ('VRGATHER_VV', [1, 4, 16, 64]),
                                 ('VCOMPRESS_VM', [1, 4, 13, 43])]:
            self.assertEqual([sum(work(opcode, lmul8=l * 8)['class_demands'].values()) for l in (1, 2, 4, 8)], expected)
        self.assertEqual(work('VFWMUL_VV', lmul8=32)['class_demands'], {'vfma': 8})
        self.assertEqual(work('VFWMUL_VV', lmul8=4)['class_demands']['vfma'], 1)
        self.assertEqual(sum(work('VFREDUSUM_VS')['class_demands'].values()), 3)
        self.assertEqual(sum(work('VFREDOSUM_VS', lmul8=32)['class_demands'].values()), 16)
        self.assertEqual(sum(work('VRGATHEREI16_VV', lmul8=32, sew=8)['class_demands'].values()), 32)

    def test_scalar_resources_and_store_required_tasks(self):
        for opcode, cls, expected in [('ADDI', 'alu', ['ALU0', 'ALU1', 'ALU2', 'ALU3']),
                                     ('MUL', 'mul', ['ALU0', 'ALU1']),
                                     ('BNE', 'brh', ['BJU0', 'BJU1', 'BJU2']),
                                     ('FADD_D', 'falu', ['FEX0', 'FEX2', 'FEX4']),
                                     ('FMV_D_X', 'i2v', ['BJU2'])]:
            r = work(opcode)
            self.assertEqual(r['class_demands'], {cls: 1})
            self.assertEqual(r['uops'][0]['resource_uses'][0]['possible_ports'], expected)
        r = work('SD', store=True)
        self.assertEqual(r['class_demands'], {'sta': 1, 'std': 1})
        self.assertNotIn('decode_uops', r)
        self.assertNotIn('issued_demands', r)
        self.assertEqual(work('LD', load=True)['uops'][0]['resource_uses'][0]['possible_ports'], ['LDU0', 'LDU1', 'LDU2'])

    def test_memory_service_work_and_index_geometry(self):
        r = work('VLE32_V', load=True, lmul8=64, vl=1)
        self.assertEqual(r['class_demands'], {'vload128': 8, 'i2v': 1})
        self.assertEqual(r, work('VLE32_V', load=True, lmul8=64, vl=0, masked=True, stride=128))
        r = work('VLSEG2E32_V', load=True, lmul8=16)
        self.assertEqual(r['class_demands'], {'vsegload': 128, 'i2v': 1})
        self.assertEqual(r['uops'][1]['resource_uses'][0]['possible_ports'], ['VLSU0'])
        self.assertEqual(work('VLSE32_V', load=True)['class_demands'], {'vload_element': 4, 'i2v': 2})
        self.assertEqual(work('VLUXEI64_V', load=True, index_emul8=16, index_eew=64)['class_demands'], {'vload_element': 4, 'i2v': 1})
        with self.assertRaises(ToolError): work('VLUXEI64_V', load=True, index_emul8=32, index_eew=64)

    def test_llvm_predicate_geometry_is_not_illegal_vtype(self):
        for opcode in ('VMAND_MM', 'VMANDN_MM', 'VMOR_MM'):
            self.assertEqual(work(opcode, lmul8=1, sew=1)['class_demands'], {'vialuF': 1})
        with self.assertRaises(ToolError): work('VADD_VV', lmul8=1, sew=1)

    def test_whole_transfers_and_spills(self):
        operand = reg(0, 1, define=True) | {'group8': 32}
        r = work('VL4RE64_V', operands=[operand], load=True, memory=[memory(scalable=True)])
        self.assertEqual(r['class_demands'], {'vload128': 4, 'i2v': 1})
        self.assertEqual(work('VMV4R_V', operands=[operand])['class_demands'], {'vppu': 4})
        r = score_observation(observation([instruction(0, 'LD', load=True, memory=[memory()])]))
        self.assertTrue(r['ops'][0]['spill_slot'])
        self.assertEqual(Q(r['demand_cost']), Q(1, 3))
        self.assertEqual(Q(r['body_cost']), Q(1, 3))
        self.assertEqual(set(r['features']), {'body_scale', 'fixed_additions'})

    def test_unknown_explicit_but_illegal_geometry_rejected(self):
        r = work('UNREVIEWED')
        self.assertEqual(r['class_demands'], {'unknown': 1})
        self.assertEqual(r['port_demands'], {'UNKNOWN': '1'})
        self.assertTrue(r['assumptions'])
        for kwargs in [dict(lmul8=1, sew=64), dict(lmul8=24), dict(lmul8=None)]:
            with self.assertRaises(ToolError): work('VADD_VV', **kwargs)
        with self.assertRaises(ToolError): work('VFWMUL_VV', lmul8=64)
        with self.assertRaises(ToolError): work('VLSEG2E32_V', lmul8=64, load=True)

    def test_equal_shares_shared_ports_and_capacity(self):
        e = Evidence('test')
        m = Machine('test', 'r', 128, 64, (Port('p', Q(2), e), Port('q', Q(1), e)),
                    (ServiceClass('a', ('p', 'q'), e), ServiceClass('b', ('p',), e)))
        expansion = synthetic_expansion(
            ResourceUse('a', ('p', 'q'), Q(6), 'operation', Q(1), 'assumed', (e,)),
            ResourceUse('b', ('p',), Q(4), 'operation', Q(1), 'assumed', (e,)))
        summary = accumulate_port_demands([expansion], m)
        self.assertEqual(dict(summary.port_demands), {'p': 7, 'q': 3})
        self.assertEqual(dict(summary.normalized_port_demands), {'p': Q(7, 2), 'q': 3})
        self.assertEqual(sum(v for _, v in summary.port_demands), 10)
        self.assertEqual(aggregate_demand(summary, 'max'), Q(7, 2))
        self.assertEqual(aggregate_demand(summary, 'sum'), Q(13, 2))
        with self.assertRaises(ToolError): replace(m, ports=(Port('p', Q(0), e),))

    def test_datasheet_identity_and_assumptions(self):
        self.assertGreater(len(VECTOR_OPCODES), 300)
        self.assertIn('Scheduler.scala', SOURCE_HASHES)
        self.assertEqual(identity()['model'], 'mir-uop-demand-v1')
        self.assertNotEqual(identity(), identity(Settings(body_scale='2')))
        self.assertTrue(all(p.evidence.assumed and p.capacity == 1 for p in MACHINE.ports))

    def test_service_demand_preserves_fractions_and_validates_rates(self):
        op = instruction(0, 'VADD_VV', lmul8=32)
        m = replace(MACHINE, classes=tuple(replace(c, demand_per_unit=Q(3, 2))
                    if c.name == 'vialuF' else c for c in MACHINE.classes))
        expansion = expand_instruction(op, m)
        summary = accumulate_port_demands([expansion], m)
        self.assertEqual(dict(summary.class_demands), {'vialuF': 6})
        self.assertEqual(expansion.uops[0].demand, Q(3, 2))
        for rate in (0, -1):
            with self.assertRaises(ToolError):
                expand_instruction(op, replace(m, classes=tuple(replace(c, demand_per_unit=rate)
                    if c.name == 'vialuF' else c for c in m.classes)))

    def test_pipeline_depth_does_not_inflate_demand(self):
        # Integer add and FP multiply have different result latencies, but II=1.
        for name, cls in [('VADD_VV', 'vialuF'), ('VFMUL_VV', 'vfma')]:
            self.assertEqual(work(name, lmul8=8)['class_demands'], {cls: 1})
            self.assertEqual(work(name, lmul8=32)['class_demands'], {cls: 4})
        for name in ('VMV_V_X', 'VMV_V_I'):
            self.assertEqual(work(name, lmul8=16)['class_demands'], {'vialuF': 2, 'i2v': 1})

    def test_iterative_service_and_dependency_timing_are_distinct(self):
        r = score_observation(observation([instruction(i, 'VFDIV_VV', sew=64) for i in range(2)]))
        self.assertEqual(r['class_demands'], {'vfdiv': 30})
        self.assertEqual(r['demand_cost'], 30)
        self.assertEqual(r['dependency_path']['cost'], 14)  # independent instructions
        self.assertEqual(work('VFDIV_VV', sew=64, lmul8=16)['class_demands'], {'vfdiv': 30})
        self.assertEqual(work('FDIV_D')['class_demands'], {'fdiv': 14})
        self.assertEqual(work('VFSQRT_V', sew=64)['class_demands'], {'vfsqrt': 17})
        self.assertEqual(work('DIVW')['class_demands'], {'div': 15})

    def test_memory_element_work_does_not_double_count_register_groups(self):
        for m, elements in [(Q(1, 2), 2), (1, 4), (2, 8), (4, 16)]:
            kw = dict(lmul8=int(m * 8), sew=32)
            self.assertEqual(work('VLSE32_V', load=True, **kw)['class_demands'],
                             {'vload_element': elements, 'i2v': 2})
            self.assertEqual(work('VSSE32_V', store=True, **kw)['class_demands'],
                             {'vstore_element': elements, 'i2v': 2})
            self.assertEqual(work('VSE32_V', store=True, **kw)['class_demands'],
                             {'vstore128': max(1, m), 'i2v': 1})
        # Increasing index EEW adds index registers, not extra data accesses.
        for width, emul8 in [(16, 4), (32, 8), (64, 16)]:
            self.assertEqual(work(f'VLUXEI{width}_V', load=True, index_eew=width, index_emul8=emul8)['class_demands'],
                             {'vload_element': 4, 'i2v': 1})
        ordered = work('VLOXEI32_V', load=True, index_emul8=8, index_eew=32)
        self.assertEqual(ordered['class_demands'], {'vload_ordered': 16, 'i2v': 1})

    def test_stale_count_reports_cannot_be_relabelled_as_service_reports(self):
        current = score_observation(observation())
        old = dict(current)
        del old['demand_schema']
        with self.assertRaisesRegex(ToolError, 'raw MIR'):
            rescore(old)
        old = dict(current, identity=dict(current['identity'], datasheet_digest='old'))
        with self.assertRaisesRegex(ToolError, 'raw MIR'):
            rescore(old)


class DemandTests(unittest.TestCase):
    def test_zero_and_positive_homogeneity(self):
        self.assertEqual(aggregate_demand(accumulate_port_demands([], MACHINE), 'max'), 0)
        for k in (Q(1, 8), 2, 1000000):
            expansion = synthetic_expansion(ResourceUse('test', ('ALU0',), Q(3),
                'operation', k, 'assumed', (Evidence('test'),)))
            summary = accumulate_port_demands([expansion], MACHINE)
            self.assertEqual(aggregate_demand(summary, 'max'), 3 * k)

    def test_invalid_settings_and_demands(self):
        for scale in ('-1', 'nan'):
            with self.assertRaises(ToolError): Settings(body_scale=scale)
        for value in (-1, float('nan'), float('inf')):
            with self.assertRaises((ToolError, ValueError, OverflowError)):
                ResourceUse('test', ('ALU0',), Q(value), 'operation', Q(1), 'assumed', ())


class LocalModel(unittest.TestCase):
    def test_unchanged_iteration_configuration_tail(self):
        ops = [instruction(0), instruction(1, 'VSETVLI', configuration=True),
               instruction(2, 'VSETVLI', configuration=True, block=1, role='setup')]
        a = observation(ops, exact_trip_count=18, max_trip_count=18, body_order=[0, 1],
                        blocks=[dict(id=0, role='body', successors=[0]), dict(id=1, role='setup', successors=[0])])
        r = score_observation(a, Settings())
        self.assertEqual(r['middle_end']['unscaled_additions'], dict(configuration=4., scalar_tail=6., setup_configuration=1.))
        self.assertEqual(r['body_iterations'], 4)
        self.assertEqual(r['scalar_remainder'], 2)
        self.assertEqual(r['middle_end_cost'], 11)
        self.assertAlmostEqual(r['score'], float(4 * Q(r['body_cost']) + 11))
        other = rescore(r, Settings(body_scale='7/3'))
        self.assertEqual(other['middle_end'], r['middle_end'])
        self.assertEqual(Q(other['score_exact']), score_value(other['features'], Settings(body_scale='7/3')))
        folded = score_observation(a | {'scalar_tail': False})
        self.assertEqual(folded['body_iterations'], 5)
        self.assertEqual(folded['middle_end_cost'], 6)
        steady = score_observation(a | {'exact_trip_count': 0})
        self.assertEqual(steady['score'], float((Q(steady['body_cost']) + 1) / 4))
        self.assertTrue(steady['middle_end']['unknown_setup_amortization'])
        self.assertIsNone(steady['scalar_remainder'])

    def test_vf_no_extra_multiplier_and_upper_bound_not_trip_count(self):
        r = score_observation(observation())
        self.assertEqual(score_observation(observation(vf=16))['score'], r['score'])
        steady = score_observation(observation(exact_trip_count=0, max_trip_count=19))
        self.assertEqual(steady['score'], float(Q(steady['body_cost']) / 4))
        with self.assertRaises(ToolError): score_observation(observation(exact_trip_count=17, max_trip_count=17, scalar_cost=None))
        a = observation([instruction(0), instruction(1, 'VSETVLI', configuration=True)])
        a['middle_end']['configuration_unit_quarters'] = None
        with self.assertRaises(ToolError): score_observation(a)

    def test_observation_validation_and_coverage(self):
        a = observation([instruction(0, operands=[reg(0, 1, define=True)]),
                         instruction(1, operands=[reg(0, 1, use=True)])], [edge(0, 1)])
        self.assertEqual(validate_observation(a)['dependencies'], [edge(0, 1)])
        a['dependencies'][0]['unit'] = 2
        with self.assertRaises(ToolError): score_observation(a)
        a = observation(); a['blocks'].append(dict(id=1, role='body', successors=[0]))
        with self.assertRaises(ToolError): score_observation(a)
        a = observation(); a['iteration_mapping'] = False
        with self.assertRaises(ToolError): score_observation(a)
        r = score_observation(observation([instruction(0, 'UNKNOWN')]))
        self.assertEqual(r['coverage']['unknown_ops'], [0])


if __name__ == '__main__': unittest.main()
