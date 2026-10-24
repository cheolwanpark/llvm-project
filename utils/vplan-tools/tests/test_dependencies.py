from copy import deepcopy
import unittest

from dependencies import longest_path, prepare_dependencies
from fixtures import edge, instruction, memory, observation, reg
from cost_model import rescore, score_observation
from hardware_model import Evidence, Timing
from kunminghu_v2 import timing_for_instruction, work_for_instruction
from model_errors import ToolError


def graph(ops, edges=None):
    return prepare_dependencies(observation(ops, edges), vscale=2, max_stack_access_bytes=128)


def memory_edges(g):
    return [e for e in g['dependencies'] if e['kind'] == 'memory-raw']


class DependencyTests(unittest.TestCase):
    def test_stack_raw_is_an_ordinary_graph_edge(self):
        ops = [instruction(0, 'ADD', operands=[reg(0, 1, define=True)]),
               instruction(1, 'SD', operands=[reg(0, 1, use=True)], store=True, memory=[memory(store=True)]),
               instruction(2, 'LD', load=True, memory=[memory()]),
               instruction(3, 'ADD')]
        g = graph(ops, [edge(0, 1), edge(2, 3)])
        self.assertEqual([(e['source'], e['destination'], e['iteration_distance']) for e in memory_edges(g)], [(1, 2, 0)])
        result = longest_path(g, {0: 2, 1: 3, 2: 4, 3: 5})
        self.assertEqual((result['path'], result['cost']), ([0, 1, 2, 3], 14))
        # No raw observation mutation, and repeated preparation is stable.
        a = observation(ops); original = deepcopy(a)
        self.assertEqual(prepare_dependencies(a, vscale=2, max_stack_access_bytes=128), graph(ops))
        self.assertEqual(a, original)

    def test_reaching_store_partial_overwrite_and_distinct_slots(self):
        ops = [instruction(0, 'SD', store=True, memory=[memory(store=True)]),
               instruction(1, 'SW', store=True, memory=[memory(store=True, offset=4, size=4)]),
               instruction(2, 'SD', store=True, memory=[memory(1, store=True)]),
               instruction(3, 'LD', load=True, memory=[memory()])]
        self.assertEqual([(e['source'], e['offset'], e['bytes']) for e in memory_edges(graph(ops))], [(0, 0, 4), (1, 4, 4)])
        ops[1]['memory'][0] = memory(store=True)
        self.assertEqual([e['source'] for e in memory_edges(graph(ops))], [1])

    def test_loop_carried_memory_edges_are_preserved_but_not_in_l_path(self):
        ops = [instruction(0, 'LD', load=True, memory=[memory()]),
               instruction(1, 'SD', store=True, memory=[memory(store=True)])]
        g = graph(ops)
        self.assertEqual([(e['source'], e['destination'], e['iteration_distance']) for e in memory_edges(g)], [(1, 0, 1)])
        self.assertEqual(longest_path(g, {0: 5, 1: 3})['cost'], 5)

    def test_scoring_uses_prepared_store_reload_chain(self):
        ops = [instruction(0, 'ADD', operands=[reg(0, 1, define=True)]),
               instruction(1, 'SD', operands=[reg(0, 1, use=True)], store=True, memory=[memory(store=True)]),
               instruction(2, 'LD', operands=[reg(0, 2, define=True)], load=True, memory=[memory()]),
               instruction(3, 'ADD', operands=[reg(0, 2, use=True)])]
        r = score_observation(observation(ops, [edge(0, 1), edge(2, 3, unit=2)]))
        self.assertEqual(r['dependency_path']['path'], [0, 1, 2, 3])
        self.assertEqual(r['dependency_path']['cost'], 1 + 2 + 3 + 1)
        self.assertEqual(r['window_cost'], 4 * 7 / 48)
        self.assertEqual(r['body_cost'], r['window_cost'])

    def test_incomplete_register_graph_is_not_silently_scored(self):
        a = observation([instruction(0, 'ADD', registers_complete=False)])
        with self.assertRaisesRegex(ToolError, 'complete register'):
            score_observation(a)

    def test_scalable_size_uses_target_vscale_and_byte_overlap(self):
        ops = [instruction(0, 'VS8R_V', store=True, memory=[memory(store=True, size=64, scalable=True)]),
               instruction(1, 'LD', load=True, memory=[memory(offset=120)]),
               instruction(2, 'LD', load=True, memory=[memory(offset=128)])]
        edges = memory_edges(graph(ops))
        self.assertEqual([(e['destination'], e['offset'], e['bytes']) for e in edges], [(1, 120, 8)])

    def test_unknown_and_conditional_stores_do_not_fabricate_edges(self):
        ops = [instruction(0, 'SD', store=True, memory=[memory(store=True)]),
               instruction(1, 'SD', store=True, memory=[memory(store=True, size=None)]),
               instruction(2, 'LD', load=True, memory=[memory()])]
        g = graph(ops)
        self.assertFalse(memory_edges(g))
        self.assertTrue(g['coverage']['unsupported_stack_accesses'])
        with self.assertRaisesRegex(ToolError, 'stack accesses'):
            score_observation(observation(ops))

    def test_diamond_and_config_connector(self):
        ops = [instruction(i) for i in range(5)]
        g = graph(ops, [edge(0, 1), edge(0, 2), edge(1, 3), edge(2, 3), edge(3, 4)])
        # Node 3 is a zero-cost connector; the two arms are not added together.
        r = longest_path(g, {0: 2, 1: 5, 2: 3, 4: 7})
        self.assertEqual((r['cost'], r['path']), (14, [0, 1, 3, 4]))
        g['dependencies'].append(edge(4, 0))
        with self.assertRaisesRegex(ToolError, 'non-forward'):
            longest_path(g, {})


class TimingTests(unittest.TestCase):
    def test_pipeline_fill_and_nonpipelined_interval(self):
        t = Timing(4, 1, True, Evidence('test'))
        self.assertEqual([t.span(n) for n in (0, 1, 3)], [0, 4, 6])
        self.assertEqual(t.span(3, serial=True), 12)
        self.assertEqual(Timing(4, 4, False, Evidence('test')).span(3), 12)

    def timing(self, opcode, **kwargs):
        op = instruction(0, opcode, **kwargs)
        return timing_for_instruction(op, work_for_instruction(op))

    def test_fixed_rtl_latency_is_not_divided_by_pipeline_depth(self):
        r = self.timing('VFMACC_VV', lmul8=32)
        c = r['components'][0]
        self.assertEqual((c['rtl_latency'], c['latency'], c['initiation_interval']), (3, 4, 1))
        self.assertEqual(r['latency'], 7)  # 4 + (4 - 1) * 1
        self.assertEqual(self.timing('VFMACC_VV')['latency'], 4)
        self.assertEqual(self.timing('VFMACC_VF')['latency'], 5)  # F2V prefix

    def test_dependent_splits_have_explicit_conservative_rule(self):
        r = self.timing('VSLIDEUP_VI', lmul8=16)
        self.assertEqual(r['components'][0]['expansion'], 'serial-upper-estimate')
        self.assertEqual(r['latency'], 3 * 3 + 1)
        op = instruction(0, 'VMV2R_V', operands=[reg(0, 1, define=True) | {'group8': 16}])
        self.assertEqual(timing_for_instruction(op, work_for_instruction(op))['latency'], 4)

    def test_precision_dependent_divide_and_sqrt(self):
        for name in ('FDIV_H', 'FDIV_S', 'FDIV_D', 'FSQRT_H', 'FSQRT_S', 'FSQRT_D'):
            r = self.timing(name)['components'][0]
            self.assertFalse(r['pipelined'])
            self.assertEqual(r['initiation_interval'], r['latency'] + 1)
            self.assertTrue(r['evidence']['assumed'])
        self.assertLess(self.timing('FDIV_H')['latency'], self.timing('FDIV_D')['latency'])
        self.assertLess(self.timing('DIVW')['latency'], self.timing('DIV')['latency'])

    def test_dependency_chain_changes_window_cost_but_not_demand(self):
        ops = [instruction(i, 'MUL', operands=[reg(0, 1, define=True, use=True)]) for i in range(18)]
        r = score_observation(observation(ops, [edge(i, i + 1) for i in range(17)]))
        self.assertEqual(r['dependency_path']['cost'], 36)
        self.assertEqual(r['demand_cost'], 9)
        self.assertEqual(r['body_cost'], 13.5)
        independent = score_observation(observation(ops))
        self.assertEqual(independent['demand_cost'], r['demand_cost'])
        self.assertEqual(independent['dependency_path']['cost'], 2)
        self.assertEqual(independent['body_cost'], 9)
        self.assertEqual(rescore(r)['score_exact'], r['score_exact'])
        for field in ('dependency_path', 'body_entries'):
            old = dict(r)
            del old[field]
            with self.assertRaisesRegex(ToolError, 'raw MIR'):
                rescore(old)

    def test_whole_body_footprint_includes_off_path_ops_and_configuration(self):
        ops = [instruction(0, 'MUL'), instruction(1, 'ADD'),
               instruction(2, 'VSETVLI', configuration=True),
               instruction(3, 'DBG_VALUE', meta=True),
               instruction(4, 'VSETVLI', configuration=True, block=1, role='setup')]
        a = observation(ops, body_order=[0, 1, 2, 3], blocks=[
            dict(id=0, role='body', successors=[0]), dict(id=1, role='setup', successors=[0])])
        r = score_observation(a)
        self.assertEqual(r['dependency_path']['path'], [0])
        self.assertEqual(r['body_entries'], 3)
        self.assertEqual(r['window_cost'], 3 * 2 / 48)
        for lmul in (1, 8):
            r = score_observation(observation([instruction(0, 'VFMACC_VV', lmul8=lmul * 8)]))
            self.assertEqual(r['body_entries'], 1)
            self.assertEqual(r['window_cost'], (4 + lmul - 1) / 48)

    def test_body_larger_than_rob_keeps_unclamped_window_cost(self):
        ops = [instruction(i, 'MUL', operands=[reg(0, 1, define=True, use=True)]) for i in range(60)]
        r = score_observation(observation(ops, [edge(i, i + 1) for i in range(59)]))
        self.assertEqual(r['dependency_path']['cost'], 120)
        self.assertEqual(r['window_cost'], 150)
        self.assertEqual(r['body_cost'], 150)


if __name__ == '__main__':
    unittest.main()
