from dataclasses import replace
from fractions import Fraction as Q
import unittest

from cost_model import Settings, demand_cost, identity, rescore, score_observation, score_value
from hardware_model import Demand, Evidence, InstructionRule, Machine, Port, ResolvedInstruction, UopClass
from kunminghu_v2 import MACHINE, SOURCE_HASHES, VECTOR_OPCODES, work_for_instruction
from model_errors import ToolError
from observations import validate_observation
from fixtures import edge, instruction, memory, observation, reg


def work(base, **kwargs): return work_for_instruction(instruction(0, base, **kwargs))


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
            self.assertEqual([work(opcode, lmul8=l * 8)['decode_uops'] for l in (1, 2, 4, 8)], expected)
        self.assertEqual(work('VFWMUL_VV', lmul8=32)['class_demands'], {'vfma': 8})
        self.assertEqual(work('VFWMUL_VV', lmul8=4)['decode_uops'], 1)
        self.assertEqual(work('VFREDUSUM_VS')['decode_uops'], 3)
        self.assertEqual(work('VFREDOSUM_VS', lmul8=32)['decode_uops'], 16)
        self.assertEqual(work('VRGATHEREI16_VV', lmul8=32, sew=8)['decode_uops'], 32)

    def test_scalar_resources_and_store_required_tasks(self):
        for opcode, cls, expected in [('ADDI', 'alu', ['ALU0', 'ALU1', 'ALU2', 'ALU3']),
                                     ('MUL', 'mul', ['ALU0', 'ALU1']),
                                     ('BNE', 'brh', ['BJU0', 'BJU1', 'BJU2']),
                                     ('FADD_D', 'falu', ['FEX0', 'FEX2', 'FEX4']),
                                     ('FDIV_D', 'fDivSqrt', ['FEX1', 'FEX3']),
                                     ('FMV_D_X', 'i2v', ['BJU2'])]:
            r = work(opcode)
            self.assertEqual(r['class_demands'], {cls: 1})
            self.assertEqual(r['components'][0]['possible_ports'], expected)
        r = work('SD', store=True)
        self.assertEqual(r['class_demands'], {'sta': 1, 'std': 1})
        self.assertEqual((r['decode_uops'], r['issued_demands']), (1, 2))
        self.assertEqual(work('LD', load=True)['components'][0]['possible_ports'], ['LDU0', 'LDU1', 'LDU2'])

    def test_memory_decode_segment_and_index_geometry(self):
        r = work('VLE32_V', load=True, lmul8=64, vl=1)
        self.assertEqual(r['class_demands'], {'vldu': 8, 'i2v': 1})
        self.assertEqual(r, work('VLE32_V', load=True, lmul8=64, vl=0, masked=True, stride=128))
        r = work('VLSEG2E32_V', load=True, lmul8=16)
        self.assertEqual(r['class_demands'], {'vsegldu': 4, 'i2v': 1})
        self.assertEqual(r['components'][0]['possible_ports'], ['VLSU0'])
        self.assertEqual(work('VLSE32_V', load=True)['class_demands'], {'vldu': 1, 'i2v': 2})
        self.assertEqual(work('VLUXEI64_V', load=True, index_emul8=16, index_eew=64)['class_demands'], {'vldu': 2, 'i2v': 1})
        with self.assertRaises(ToolError): work('VLUXEI64_V', load=True, index_emul8=32, index_eew=64)

    def test_llvm_predicate_geometry_is_not_illegal_vtype(self):
        for opcode in ('VMAND_MM', 'VMANDN_MM', 'VMOR_MM'):
            self.assertEqual(work(opcode, lmul8=1, sew=1)['class_demands'], {'vialuF': 1})
        with self.assertRaises(ToolError): work('VADD_VV', lmul8=1, sew=1)

    def test_whole_transfers_and_spills(self):
        operand = reg(0, 1, define=True) | {'group8': 32}
        r = work('VL4RE64_V', operands=[operand], load=True, memory=[memory(scalable=True)])
        self.assertEqual(r['class_demands'], {'vldu': 4, 'i2v': 1})
        self.assertEqual(work('VMV4R_V', operands=[operand])['class_demands'], {'vppu': 4})
        r = score_observation(observation([instruction(0, 'LD', load=True, memory=[memory()])]))
        self.assertTrue(r['ops'][0]['spill_slot'])
        self.assertEqual(r['demand_cost'], 1 / 3)
        self.assertEqual(r['body_cost'], 1 / 3)
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
                    (UopClass('a', ('p', 'q'), e), UopClass('b', ('p',), e)))
        raw, normalized = m.distribute({'a': 6, 'b': 4})
        self.assertEqual(raw, {'p': 7, 'q': 3})
        self.assertEqual(normalized, {'p': Q(7, 2), 'q': 3})
        self.assertEqual(sum(raw.values()), 10)
        r = m.expand(ResolvedInstruction(InstructionRule('test', (Demand('a', 3), Demand('b', 1)), e)))
        self.assertEqual(r['port_demands'], {'p': '5/2', 'q': '3/2'})
        with self.assertRaises(ToolError): replace(m, ports=(Port('p', Q(0), e),))

    def test_datasheet_identity_and_assumptions(self):
        self.assertGreater(len(VECTOR_OPCODES), 300)
        self.assertIn('Scheduler.scala', SOURCE_HASHES)
        self.assertEqual(identity()['model'], 'mir-port-window-v3')
        self.assertNotEqual(identity(), identity(Settings(body_scale='2')))
        self.assertTrue(all(p.evidence.assumed and p.capacity == 1 for p in MACHINE.ports))


class DemandTests(unittest.TestCase):
    def test_zero_and_positive_homogeneity(self):
        self.assertEqual(demand_cost(dict(a=0, b=0)), 0)
        v = demand_cost(dict(a=1, b=3, c=0))
        for k in (Q(1, 8), 2, 1000000):
            self.assertAlmostEqual(demand_cost(dict(a=k, b=3*k, c=0)) / float(k), v)
        self.assertEqual(demand_cost(dict(a=3, b=4)), 4)

    def test_invalid_settings_and_demands(self):
        for scale in ('-1', 'nan'):
            with self.assertRaises(ToolError): Settings(body_scale=scale)
        for value in (-1, float('nan'), float('inf')):
            with self.assertRaises((ToolError, ValueError, OverflowError)):
                demand_cost(dict(a=value))


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
        self.assertAlmostEqual(r['score'], 4 * r['body_cost'] + 11)
        other = rescore(r, Settings(body_scale='7/3'))
        self.assertEqual(other['middle_end'], r['middle_end'])
        self.assertEqual(Q(other['score_exact']), score_value(other['features'], Settings(body_scale='7/3')))
        folded = score_observation(a | {'scalar_tail': False})
        self.assertEqual(folded['body_iterations'], 5)
        self.assertEqual(folded['middle_end_cost'], 6)
        steady = score_observation(a | {'exact_trip_count': 0})
        self.assertEqual(steady['score'], (steady['body_cost'] + 1) / 4)
        self.assertTrue(steady['middle_end']['unknown_setup_amortization'])
        self.assertIsNone(steady['scalar_remainder'])

    def test_vf_no_extra_multiplier_and_upper_bound_not_trip_count(self):
        r = score_observation(observation())
        self.assertEqual(score_observation(observation(vf=16))['score'], r['score'])
        steady = score_observation(observation(exact_trip_count=0, max_trip_count=19))
        self.assertEqual(steady['score'], steady['body_cost'] / 4)
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
