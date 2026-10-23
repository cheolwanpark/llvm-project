from fractions import Fraction
import unittest

from cost_model import COEFFICIENTS, identity, machine_parameters, score_observation
from unittest.mock import patch
from dependencies import Dependencies, memory_relation
from hardware import BASIC_CLASSES, MAP, can_overlap, split_work, work_for_instruction
from model_errors import ToolError
from observations import validate_observation, iteration_factors
from fixtures import edge, instruction, memory, observation, reg


class HardwareRules(unittest.TestCase):
    def test_hardcoded_scales_cover_all_machine_cost_classes(self):
        self.assertEqual({p[6:] for p in COEFFICIENTS if p.startswith('basic_')}, set(BASIC_CLASSES))
        self.assertTrue(all(value >= 0 for value in COEFFICIENTS.values()))

    def test_pinned_opcode_map(self):
        self.assertGreater(len(MAP['opcodes']), 350)
        self.assertEqual(MAP['opcodes']['VADD_VV']['split'], 'VEC_VVV')
        self.assertEqual(MAP['opcodes']['VADD_VI']['split'], 'VEC_VXV')
        self.assertEqual(MAP['opcodes']['VFWMUL_VV']['split'], 'VEC_VVW')

    def test_fractional_and_integer_groups(self):
        for lmul, expected in [(Fraction(1, 8), 1), (Fraction(1, 4), 1), (Fraction(1, 2), 1), (1, 1), (2, 2), (4, 4), (8, 8)]:
            self.assertEqual(split_work('VEC_VVV', lmul, 8), (expected, 0))
            self.assertEqual(split_work('VEC_VXV', lmul, 8), (expected + 1, 1))

    def test_special_work(self):
        self.assertEqual([split_work('VEC_SLIDEUP', l, 32)[0] for l in (1, 2, 4, 8)], [2, 4, 11, 37])
        self.assertEqual([split_work('VEC_RGATHER', l, 32)[0] for l in (1, 2, 4, 8)], [1, 4, 16, 64])
        self.assertEqual(split_work('VEC_RGATHEREI16', 4, 8), (32, 0))
        self.assertEqual(split_work('VEC_RGATHEREI16', 8, 8), (64, 0))
        self.assertEqual([split_work('VEC_COMPRESS', l, 32)[0] for l in (1, 2, 4, 8)], [1, 4, 13, 43])

    def test_widening_and_narrowing(self):
        self.assertEqual(split_work('VEC_VXW', 4, 32), (9, 1))
        self.assertEqual(split_work('VEC_WVV', Fraction(1, 2), 32), (1, 0))
        self.assertEqual(split_work('VEC_VWW', Fraction(1, 2), 32), (2, 0))
        with self.assertRaises(ToolError): split_work('VEC_VVW', 8, 32)

    def test_reduction(self):
        self.assertEqual(split_work('VEC_VFRED', 1, 32), (3, 0))
        self.assertEqual(split_work('VEC_VFRED', 4, 64), (5, 0))
        self.assertEqual(split_work('VEC_VFREDOSUM', 4, 32), (16, 0))
        self.assertEqual(split_work('VEC_VFREDOSUM', Fraction(1, 2), 64), (1, 0))

    def test_memory_forms(self):
        self.assertEqual(split_work('VEC_US_LDST', 2, 32, eew=64, fields=2), (9, 1))
        self.assertEqual(split_work('VEC_S_LDST', 1, 32, eew=32), (3, 2))
        self.assertEqual(split_work('VEC_I_LDST', 2, 32, eew=32, fields=2, index_emul=8), (9, 1))
        with self.assertRaises(ToolError): split_work('VEC_US_LDST', 4, 32, eew=64, fields=2)
        with self.assertRaises(ToolError): split_work('VEC_I_LDST', 1, 32, eew=32)

    def test_indexed_observed_geometry(self):
        op = instruction(0, 'VLUXEI64_V', load=True, index_emul8=16, index_eew=64)
        work = work_for_instruction(op)
        self.assertEqual(work['decode_uops'], 3)
        self.assertEqual(work['geometry']['index_emul'], '2')
        with self.assertRaises(ToolError): work_for_instruction(op | {'index_emul8': 32})

    def test_unknown_is_not_linear_fallback(self):
        for base in ['VUNKNOWN_VV', 'VLUXEI32_V']:
            with self.assertRaises(ToolError): work_for_instruction(instruction(0, base, load=base.startswith('VL')))

    def test_illegal_geometry(self):
        with self.assertRaises(ToolError): split_work('VEC_VVV', Fraction(1, 8), 64)
        with self.assertRaises(ToolError): split_work('VEC_VVV', 3, 32)

    def test_resource_overlap(self):
        intwork = work_for_instruction(instruction(0))
        fpwork = work_for_instruction(instruction(1, 'VFADD_VV'))
        self.assertTrue(can_overlap(intwork, fpwork))
        # Same class can run on distinct units. Singleton resources cannot.
        self.assertTrue(can_overlap(intwork, intwork))
        mul = work_for_instruction(instruction(0, 'VMUL_VV'))
        self.assertFalse(can_overlap(mul, mul))
        scalar = work_for_instruction(instruction(0, 'ADDI'))
        self.assertIsNone(can_overlap(intwork, scalar))


class DynamicDependencies(unittest.TestCase):
    def chain(self):
        ops = [instruction(0, operands=[reg(0, 1, define=True)]),
               instruction(1, operands=[reg(0, 1, use=True), reg(1, 2, define=True)]),
               instruction(2, operands=[reg(0, 2, use=True)])]
        return observation(ops, [edge(0, 1), edge(1, 2, unit=2)])

    def test_transitive(self):
        d = Dependencies(self.chain())
        self.assertTrue(d.relation((0, 0), (2, 0))['raw'])
        self.assertEqual(d.relation((0, 0), (2, 1))['independence'], 'independent')

    def test_loop_carried_multiple_iterations(self):
        a = self.chain()
        a['instructions'][0]['operands'].append(reg(1, 2, use=True))
        a['dependencies'].append(edge(1, 0, unit=2, distance=1, operand=1))
        d = Dependencies(a)
        self.assertTrue(d.relation((0, 0), (0, 4))['raw'])
        self.assertTrue(d.relation((2, -3), (0, 0))['raw'] is False)

    def test_unknown_registers(self):
        a = observation(); a['instructions'][0]['registers_complete'] = False
        self.assertEqual(Dependencies(a).relation((0, 0), (1, 0))['independence'], 'unknown')

    def test_memory_alias(self):
        store = instruction(0, 'SD', store=True, memory=[memory(store=True)])
        load = instruction(1, 'LD', load=True, memory=[memory()])
        self.assertEqual(memory_relation(store, load), 'dependent')
        load['memory'][0]['stack_slot'] = 1
        self.assertEqual(memory_relation(store, load), 'independent')
        load['memory'][0]['stack_slot'] = None
        self.assertEqual(memory_relation(store, load), 'unknown')

    def test_memory_unknown_propagates_through_registers(self):
        ops = [instruction(0, 'SD', store=True, memory=[memory(None, store=True)]),
               instruction(1, 'LD', load=True, memory=[memory(None)], operands=[reg(0, 1, define=True)]),
               instruction(2, operands=[reg(0, 1, use=True)])]
        self.assertEqual(Dependencies(observation(ops, [edge(1, 2)])).relation((0, 0), (2, 0))['independence'], 'unknown')

    def test_stack_waw_is_not_raw(self):
        ops = [instruction(0, 'SD', store=True, memory=[memory(store=True)]),
               instruction(1, 'SD', store=True, memory=[memory(store=True)])]
        relation = Dependencies(observation(ops)).relation((0, 0), (1, 0))
        self.assertFalse(relation['raw'])
        self.assertEqual(relation['independence'], 'dependent')

    def test_stack_raw(self):
        ops = [instruction(0, 'SD', store=True, memory=[memory(store=True)]),
               instruction(1, 'LD', load=True, memory=[memory()])]
        self.assertTrue(Dependencies(observation(ops)).relation((0, 0), (1, 0))['raw'])

    def test_war_waw_never_prove_independence(self):
        a = observation([instruction(0, operands=[reg(0, 1, define=True)]), instruction(1, operands=[reg(0, 1, define=True)])])
        self.assertEqual(Dependencies(a).relation((0, 0), (1, 0))['independence'], 'unknown')


class LocalModel(unittest.TestCase):
    def test_calibrated_defaults_and_identity(self):
        model = identity()
        self.assertEqual(model['model'], 'mir-basic-calibrated-v1')
        params = model['machine_parameters']
        self.assertEqual((params['forward_window'], params['backward_window']), (0, 0))
        expected = {'basic_' + cls: 1. for cls in BASIC_CLASSES}
        expected.update(basic_memory=3., basic_move=2., contention=.25, raw=.25,
                        ilp=.125, middle_end_scale=1.)
        self.assertEqual(params['coefficients'], expected)
        for window in ('FORWARD_WINDOW', 'BACKWARD_WINDOW'):
            with patch('cost_model.' + window, 4):
                self.assertNotEqual(identity(), model)
                self.assertTrue(score_observation(observation())['pairs'])

    def test_zero_windows_skip_analysis_but_keep_validation_and_coverage(self):
        a = observation()
        a['instructions'][0]['registers_complete'] = False
        with patch('cost_model.Dependencies', side_effect=AssertionError('dependency analysis')), \
             patch('cost_model.can_overlap', side_effect=AssertionError('overlap analysis')):
            r = score_observation(a)
            self.assertEqual(r['pairs'], [])
            self.assertEqual(r['body_cost'], r['basic'])
            self.assertEqual((r['stall'], r['ilp']), (0, 0))
            for features in [r['features'], r['body_features'], *(o['features'] for o in r['ops'])]:
                self.assertEqual([features[k] for k in ('contention', 'raw', 'ilp')], [0, 0, 0])
            for key in ('unknown_dependency', 'unknown_overlap', 'independent', 'dependent'):
                self.assertEqual(r['coverage'][key], 0)
            self.assertEqual(r['coverage']['register'], a['register_coverage'])
            self.assertEqual(r['coverage']['memory'], a['memory_coverage'])
            a['schema'] = 'old'
            with self.assertRaises(ToolError): score_observation(a)

    def test_component_weights_geometry_and_iteration_additions(self):
        # Strided memory at EMUL 1: memory1+move2 => 7;
        # unit memory at EMUL 8: memory8+move1 => 26;
        # FP scalar multiply at LMUL 2: fp_multiply2+move1 => 4.
        ops = [instruction(0, 'VLSE32_V', load=True),
               instruction(1, 'VLE32_V', load=True, lmul8=64, sew=64),
               instruction(2, 'VFMUL_VF', lmul8=16),
               instruction(3, 'VSETVLI', configuration=True),
               instruction(4, 'VSETVLI', configuration=True, block=1, role='setup')]
        a = observation(ops, exact_trip_count=18, max_trip_count=18,
                        body_order=[0, 1, 2, 3],
                        blocks=[dict(id=0, role='body', successors=[0]),
                                dict(id=1, role='setup', successors=[0])])
        r = score_observation(a)
        self.assertEqual([o['basic'] for o in r['ops']], [7, 26, 4])
        self.assertEqual(r['body_features']['basic_memory'], 9)
        self.assertEqual(r['body_features']['basic_move'], 4)
        self.assertEqual(r['body_features']['basic_fp_multiply'], 2)
        self.assertEqual(r['body_cost'], 37)
        self.assertEqual(r['middle_end']['unscaled_additions'],
                         dict(configuration=4., scalar_tail=6., setup_configuration=1.))
        self.assertEqual(r['score'], 4 * 37 + 11)
        # VF has no separate multiplier: verified width controls iterations.
        self.assertEqual(score_observation(a | {'vf': 16})['score'], r['score'])
        folded = score_observation(a | {'scalar_tail': False})
        self.assertEqual(folded['body_iterations'], 5)
        self.assertEqual(folded['score'], 5 * 37 + 6)
        steady = score_observation(a | {'exact_trip_count': 0})
        self.assertEqual(steady['score'], (37 + 1) / 4)
        self.assertTrue(steady['middle_end']['unknown_setup_amortization'])

    def test_op_pair_body_and_final_reconcile(self):
        r = score_observation(observation())
        self.assertAlmostEqual(r['body_cost'], r['basic'] + r['stall'] - r['ilp'])
        self.assertAlmostEqual(sum(p['net'] for p in r['pairs']), r['stall'] - r['ilp'])
        self.assertAlmostEqual(r['score'], r['body_cost'] * r['body_iterations'] + r['middle_end_cost'])
        self.assertEqual(r['coefficients'], COEFFICIENTS)

    def test_configuration_and_tail_added_once(self):
        a = observation([instruction(0), instruction(1, 'VSETVLI', configuration=True)],
                        exact_trip_count=18, max_trip_count=18)
        r = score_observation(a)
        self.assertEqual(r['body_iterations'], 4)
        self.assertEqual(r['scalar_remainder'], 2)
        self.assertEqual(r['middle_end']['unscaled_additions'],
                         dict(configuration=4., scalar_tail=6., setup_configuration=0.))
        self.assertEqual(r['middle_end_cost'], 10. * COEFFICIENTS['middle_end_scale'])

    def test_upper_bound_not_used_as_exact(self):
        a = observation(exact_trip_count=0, max_trip_count=19)
        self.assertEqual(iteration_factors(a), (.25, 0, 'steady-state-per-scalar-iteration'))
        r = score_observation(a)
        self.assertEqual(r['score'], r['body_cost'] / 4)
        self.assertEqual(r['middle_end_cost'], 0)
        self.assertIsNone(r['scalar_remainder'])

    def test_missing_middle_end_cost(self):
        a = observation(exact_trip_count=17, max_trip_count=17, scalar_cost=None)
        with self.assertRaises(ToolError): score_observation(a)
        a = observation([instruction(0), instruction(1, 'VSETVLI', configuration=True)])
        a['middle_end']['configuration_unit_quarters'] = None
        with self.assertRaises(ToolError): score_observation(a)

    def test_spill_not_additive(self):
        r = score_observation(observation([instruction(0, 'LD', load=True, memory=[memory()])]))
        self.assertEqual(r['ops'][0]['hardware']['components'][0]['cost_class'], 'memory')
        self.assertNotIn('spill', r['features'])
        self.assertEqual(r['body_cost'], 3.)

    def test_schema_and_operand_positions(self):
        a = observation(); a['schema'] = 'old'
        with self.assertRaises(ToolError): validate_observation(a)
        a = observation([instruction(0, operands=[reg(1, 1)])])
        with self.assertRaises(ToolError): validate_observation(a)

    def test_multi_block_rejected(self):
        a = observation(); a['blocks'].append(dict(id=1, role='body', successors=[0]))
        with self.assertRaises(ToolError): score_observation(a)

    def test_manual_calibration_changes_report_identity(self):
        before = identity()
        with patch.dict(COEFFICIENTS, raw=COEFFICIENTS['raw'] + .1):
            self.assertNotEqual(identity(), before)
        self.assertEqual(identity(), before)
        snapshot = machine_parameters(); snapshot['coefficients']['raw'] = 99
        self.assertNotEqual(COEFFICIENTS['raw'], 99)


class PairModel(unittest.TestCase):
    """Compatibility semantics require explicit nonzero windows in every test."""
    def setUp(self):
        for name in ('FORWARD_WINDOW', 'BACKWARD_WINDOW'):
            context = patch('cost_model.' + name, 4)
            context.start()
            self.addCleanup(context.stop)

    def test_multilap_dynamic_identity(self):
        r = score_observation(observation([instruction(0)]))
        self.assertEqual([(p['other'], p['iteration_offset']) for p in r['pairs']],
                         [(0, i) for i in range(1, 5)] +
                         [(0, -i) for i in range(1, 5)])
        self.assertEqual(len(r['ops']), 1)
        self.assertEqual(r['basic'], 1)

    def test_same_class_and_raw_add(self):
        a = observation([instruction(0, operands=[reg(0, 1, define=True)]),
                         instruction(1, operands=[reg(0, 1, use=True)])], [edge(0, 1)])
        pair = score_observation(a)['pairs'][0]
        self.assertEqual(pair['contributions']['contention'], COEFFICIENTS['contention'])
        self.assertEqual(pair['contributions']['raw'], COEFFICIENTS['raw'])
        self.assertEqual(pair['contributions']['ilp'], 0)

    def test_mixed_class_contention_uses_only_shared_moves_and_preserves_raw(self):
        a = observation([instruction(0, 'VLSE32_V', load=True, lmul8=64,
                                     operands=[reg(0, 1, define=True)]),
                         instruction(1, 'VFMUL_VF', lmul8=64,
                                     operands=[reg(0, 1, use=True)])], [edge(0, 1)])
        pair = score_observation(a)['pairs'][0]
        self.assertEqual(pair['shared_classes'], ['move'])
        self.assertEqual(pair['pair_work'], 9)
        self.assertEqual(pair['contention_work'], 1)
        self.assertEqual(pair['features']['contention'], 1)
        self.assertEqual(pair['features']['raw'], 9)
        self.assertEqual(pair['contributions']['contention'], COEFFICIENTS['contention'])
        self.assertEqual(pair['contributions']['raw'], 9 * COEFFICIENTS['raw'])

    def test_classwise_minima_are_symmetric_and_do_not_pool_unmatched_work(self):
        a = observation([instruction(0, 'VLSE32_V', load=True),
                         instruction(1, 'VLE32_V', load=True, lmul8=64)])
        r = score_observation(a)
        # memory1+move2 versus memory8+move1: 1+1, not min(3,9).
        pairs = [p for p in r['pairs'] if p['direction'] == 'forward' and p['distance'] == 1]
        self.assertEqual(len(pairs), 2)
        for pair in pairs:
            self.assertEqual(pair['shared_classes'], ['memory', 'move'])
            self.assertEqual(pair['pair_work'], 3)
            self.assertEqual(pair['contention_work'], 2)
            self.assertEqual(pair['features']['contention'], 2)

    def test_contention_is_invariant_to_same_class_component_partition(self):
        a = observation([instruction(0, 'VLSE32_V', load=True, lmul8=64),
                         instruction(1, 'VLE32_V', load=True, lmul8=64)])
        expected = score_observation(a)
        work = {op['id']: work_for_instruction(op) for op in a['instructions']}
        for item in work.values():
            primary, move = item['components']
            item['components'] = [primary | {'work': 3}, primary | {'work': 5}, move]
        with patch('cost_model.work_for_instruction', side_effect=lambda op: work[op['id']]):
            actual = score_observation(a)
        self.assertEqual(actual['features'], expected['features'])
        self.assertEqual(actual['pairs'], expected['pairs'])
        self.assertEqual(actual['score'], expected['score'])

    def test_shared_component_contention_preserves_full_op_backward_ilp(self):
        a = observation([instruction(0, 'VLSE32_V', load=True, lmul8=64),
                         instruction(1, 'VFMUL_VF', lmul8=64)])
        r = score_observation(a)
        pair = next(p for p in r['pairs'] if p['anchor'] == 0 and
                    p['direction'] == 'backward' and p['distance'] == 1)
        self.assertEqual(pair['dependency']['independence'], 'independent')
        self.assertTrue(pair['overlap'])
        self.assertEqual(pair['pair_work'], 9)
        self.assertEqual(pair['contention_work'], 1)
        self.assertEqual(pair['features']['contention'], 0)
        self.assertEqual(pair['features']['ilp'], -9)
        self.assertEqual(pair['contributions']['ilp'], -9 * COEFFICIENTS['ilp'])

    def test_disjoint_classes_have_zero_contention_work(self):
        r = score_observation(observation())
        pair = r['pairs'][0]
        self.assertEqual(pair['shared_classes'], [])
        self.assertEqual(pair['contention_work'], 0)
        self.assertEqual(pair['features']['contention'], 0)
        self.assertEqual(pair['pair_work'], 1)

    def test_class_difference_alone_not_ilp(self):
        a = observation(); a['instructions'][1]['registers_complete'] = False
        r = score_observation(a)
        self.assertEqual(r['ilp'], 0)
        self.assertGreater(r['coverage']['unknown_dependency'], 0)

    def test_signed_score_remains_visible_after_manual_model_change(self):
        with patch.dict(COEFFICIENTS, ilp=20.):
            r = score_observation(observation())
        self.assertTrue(r['diagnostics']['negative_body'])
        self.assertFalse(r['diagnostics']['bounded'])

    def test_config_excluded_from_body_and_windows(self):
        a = observation([instruction(0), instruction(1, 'VSETVLI', configuration=True), instruction(2)])
        r = score_observation(a)
        self.assertEqual([o['id'] for o in r['ops']], [0, 2])
        self.assertTrue(all(p['anchor'] != 1 and p['other'] != 1 for p in r['pairs']))
        self.assertEqual(r['middle_end']['unscaled_additions']['configuration'], 4.)


if __name__ == '__main__': unittest.main()
