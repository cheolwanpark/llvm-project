import itertools
import unittest
from unittest.mock import patch

from cost_model import COEFFICIENTS, score_observation
from fixtures import instruction, memory, observation, reg
from hardware import work_for_instruction
from memory_work import address_work, memory_work, category
from model_errors import ToolError
from observations import validate_observation


def demand(op):
    return memory_work(op, work_for_instruction(op), 128)


class MemoryWorkTests(unittest.TestCase):
    def test_lowered_copy_classification(self):
        op = instruction(0, 'ADDI', operands=[reg(0, 1, define=True), reg(1, 2, use=True),
                                             dict(index=2, kind='immediate', value=0)])
        self.assertEqual(category(op, None), 'copy')
        op['operands'][2]['value'] = 1
        self.assertEqual(category(op, None), 'scalar')

    def test_scalar_and_whole_spill_bytes(self):
        for name, size in [('LB', 1), ('LW', 4), ('LD', 8)]:
            m = demand(instruction(0, name, load=True, memory=[memory(size=size)]))
            self.assertEqual((m['bytes'], m['category'], m['bytes_kind']), (size, 'reload', 'exact'))
        for count in (1, 2, 4, 8):
            operand = reg(0, 1, define=True) | {'group8': 8 * count}
            for eew in (8, 16, 32, 64):
                m = demand(instruction(0, f'VL{count}RE{eew}_V', load=True, operands=[operand],
                                       memory=[memory(size=8 * count, scalable=True)]))
                self.assertEqual(m['bytes'], 16 * count)
                self.assertEqual(m['distinct_addresses'], 128 * count // eew)
                self.assertEqual(m['bytes_kind'], 'exact')

    def test_vl_bounds_and_invalid_geometry(self):
        op = instruction(0, 'VLE32_V', load=True)
        self.assertEqual(demand(op)['bytes'], 16)
        self.assertEqual(demand(op)['bytes_kind'], 'upper-bound')
        self.assertEqual(demand(op | {'vl': 1})['bytes'], 4)
        self.assertEqual(demand(op | {'vl': 1})['bytes_kind'], 'exact')
        self.assertEqual(demand(op | {'vl': 1, 'masked': True})['bytes_kind'], 'upper-bound')
        for key in ('bytes', 'requests', 'distinct_addresses'):
            self.assertEqual(demand(op | {'vl': 0})[key], 0)
        with self.assertRaises(ToolError): demand(op | {'vl': 5})
        with self.assertRaises(ToolError): demand(instruction(0, 'UNKNOWN_LOAD', load=True))

    def test_stride_and_segment_overlap(self):
        op = instruction(0, 'VLSSEG2E32_V', load=True, vl=4)
        repeated = demand(op | {'stride': 0})
        overlap = demand(op | {'stride': 4})
        reverse = demand(op | {'stride': -4})
        self.assertEqual(repeated['distinct_addresses'], 2)
        self.assertEqual(overlap['distinct_addresses'], 5)
        self.assertEqual(reverse['distinct_addresses'], 5)
        self.assertEqual(repeated['bytes'], 32)  # Logical demand, not unique bytes.
        self.assertEqual(demand(op | {'stride': 256})['distinct_addresses'], 8)
        self.assertEqual(demand(op)['distinct_kind'], 'upper-bound')

    def test_index_geometry_and_unknown_addresses(self):
        op = instruction(0, 'VLUXEI64_V', load=True, vl=4, index_emul8=16, index_eew=64)
        m = demand(op)
        self.assertEqual(m['bytes'], 16)  # Data EEW=32, index EEW=64.
        self.assertEqual(m['requests'], 8)
        self.assertEqual(m['distinct_addresses'], 4)

    def test_request_chunks_and_alignment(self):
        self.assertEqual(address_work(8, 4, 1, 4, 16, True), (2, 8))
        self.assertEqual(address_work(8, 4, 1, 4, 64, True), (2, 8))
        self.assertEqual(address_work(8, 4, 1, 4, 8, True), (4, 8))

    def test_exhaustive_address_and_mask_upper_bounds(self):
        # Independent byte-set reference, including every subset of active lanes.
        for size, fields, stride, alignment in itertools.product((1, 4, 8), (1, 2), (-8, 0, 4, 64), (1, 8, 64)):
            requests, distinct = address_work(3, size, fields, stride, alignment, False)
            unknown_r, unknown_d = address_work(3, size, fields, None, alignment, False)
            for bits in range(8):
                offsets = [i * stride + f * size for i in range(3) if bits & (1 << i) for f in range(fields)]
                for base in range(0, 64, alignment):
                    actual_r = sum(len({(base + o + b) // 16 for b in range(size)}) for o in offsets)
                    self.assertLessEqual(actual_r, requests)
                    self.assertLessEqual(len(set(offsets)), distinct)
                    self.assertLessEqual(actual_r, unknown_r)
                    self.assertLessEqual(len(set(offsets)), unknown_d)

    def test_rv64_address_wrap(self):
        self.assertEqual(address_work(4, 4, 1, -(1 << 63), 64, False)[1], 2)

    def test_schema_rejects_invalid_stride_and_alignment(self):
        a = observation([instruction(0, stride=1 << 63)])
        with self.assertRaises(ToolError): validate_observation(a)
        a = observation([instruction(0, memory=[memory() | {'alignment': 3}])])
        with self.assertRaises(ToolError): validate_observation(a)

    def test_cost_reconciliation_and_middle_end_unchanged(self):
        ops = [instruction(0, 'VLSE32_V', load=True, vl=4, stride=256, memory=[memory()]),
               instruction(1, 'VFMACC_VV'), instruction(2, 'VSETVLI', configuration=True)]
        a = observation(ops, exact_trip_count=18, max_trip_count=18)
        with patch.dict(COEFFICIENTS, memory_requests=0.):
            zero = score_observation(a)
        with patch.dict(COEFFICIENTS, memory_requests=2.):
            result = score_observation(a)
        self.assertEqual(zero['basic'], result['basic'])
        self.assertEqual(zero['middle_end'], result['middle_end'])
        self.assertEqual(zero['middle_end_cost'], result['middle_end_cost'])
        self.assertGreater(result['body_cost'], zero['body_cost'])
        self.assertEqual(result['body_breakdown']['reload']['instructions'], 1)
        self.assertEqual(result['body_breakdown']['fma']['instructions'], 1)
        self.assertEqual(result['body_cost'], sum(g['cost'] for g in result['body_breakdown'].values()))
        self.assertEqual(result['body_cost'], sum(o['cost'] for o in result['ops']))
        self.assertEqual(result['score'], result['body_cost'] * result['body_iterations'] + result['middle_end_cost'])

    def test_requests_replace_decode_without_floor(self):
        # VL=1 makes R=1 despite decode work D=8; no residual or 3D floor.
        op = instruction(0, 'VLE32_V', load=True, lmul8=64, vl=1,
                         memory=[memory() | {'alignment': 16}])
        r = score_observation(observation([op]))
        self.assertNotIn('basic_memory', r['features'])
        self.assertEqual(r['body_features']['memory_requests'], 1.)
        self.assertEqual(r['body_cost'], 4.)  # 2R + existing move cost 2.
        r = score_observation(observation([op | {'vl': 0}]))
        self.assertEqual(r['body_cost'], 2.)


if __name__ == '__main__':
    unittest.main()
