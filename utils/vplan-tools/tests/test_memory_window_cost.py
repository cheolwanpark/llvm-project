"""Cyclic maximum windows, independent costs/demands, and one-body accounting."""
import copy
from dataclasses import replace
from fractions import Fraction as F
from pathlib import Path
import sys
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from memory_window_cost import Parameters, window_terms, replace_memory_cost, stride_factor, operation_value
from test_memory_cost import access, facts
from test_middle_end_model import candidate
from analytics_fixtures import analytics


def body(records, n=8, width=8, ratio=1):
    f=facts([r|dict(opcode='LOAD' if r['load'] else 'STORE') for r in records])
    f.update(body_length=n,width=width,iteration_ratio=ratio)
    return f


class MemoryWindowTests(unittest.TestCase):
    def test_wrap_window_wins_and_service_is_not_doubled(self):
        f=body([access(0,0,vl=4),access(1,7,vl=4)])
        t=window_terms(f,Parameters(window_size=2))
        self.assertEqual((t['peak_start'],t['peak_demand'],t['wraps']),(7,8,True))
        self.assertEqual((t['service'],t['capacity'],t['interaction']),(8,2,6))
        self.assertEqual(t['windows_scanned'],8)

    def test_multiple_peaks_use_maximum_not_sum(self):
        f=body([access(0,0,vl=4),access(1,4,vl=4)])
        t=window_terms(f,Parameters(window_size=2))
        self.assertEqual((t['peak_demand'],t['interaction']),(4,2))

    def test_cost_and_demand_are_independent_with_opcode_overrides(self):
        f=body([access(0,0,vl=8)])
        p=Parameters(window_size=2)
        original=window_terms(f,p)
        cost=window_terms(f,replace(p,service_opcode_costs={'LOAD':3}))
        demand=window_terms(f,replace(p,demand_opcode_counts={'LOAD':1}))
        self.assertEqual(cost['service'],3)
        self.assertEqual(cost['interaction'],original['interaction'])
        self.assertEqual(demand['service'],original['service'])
        self.assertEqual(demand['interaction'],0)

    def test_vf_changes_window_capacity_without_changing_service(self):
        f=body([access(0,0,vl=8)])
        p=Parameters(window_size=2)
        narrow=window_terms(f,p);wide=window_terms(f|dict(width=16),p)
        self.assertEqual((narrow['capacity'],wide['capacity']),(2,4))
        self.assertEqual(narrow['service'],wide['service'])

    def test_large_window_is_capped_to_one_period_and_stores_count(self):
        f=body([access(0,0,vl=4),access(1,7,vl=4,load=False)])
        t=window_terms(f,Parameters(window_size=99,throughput=F(1,2)))
        self.assertEqual((t['window_slots'],t['peak_demand'],t['interaction']),(8,8,8))
        self.assertEqual(t['service'],8)

    def test_ratio_applies_once_and_empty_body_memory_has_zero_cost(self):
        f=body([access(0,0,vl=8)],ratio=2)
        t=window_terms(f,Parameters(window_size=2))
        self.assertEqual((t['service'],t['interaction']),(4,3))
        empty=window_terms(body([]))
        self.assertEqual((empty['service'],empty['interaction']),(0,0))

    def test_replacement_rounds_service_and_interaction_together(self):
        c=candidate(width=4);obs=analytics(vf=4,Width=4)
        before=copy.deepcopy(c)
        terms=dict(service=F(1,6),interaction=F(1,6))
        r=replace_memory_cost(c,obs,terms,12)
        self.assertEqual(r['memory_added_quarters'],1)
        self.assertEqual(r['memory_removed_quarters'],12)
        self.assertEqual(c,before)

    def test_service_scale_leaves_demand_and_interaction_unchanged(self):
        f=body([access(0,0,vl=8)])
        p=Parameters(window_size=2)
        before=window_terms(f,p)
        after=window_terms(f,replace(p,service_scale=F(1,4)))
        self.assertEqual(after['service'],before['service']/4)
        self.assertEqual(after['unscaled_service'],before['service'])
        for key in ('interaction','peak_demand','capacity','excess_demand'):
            self.assertEqual(after[key],before[key])
        zero=window_terms(f,replace(p,service_scale=F(0)))
        self.assertEqual((zero['service'],zero['interaction']),(0,before['interaction']))

    def test_zero_correction_with_no_removal_preserves_backend_baseline(self):
        from cost_model import backend_cost
        c=candidate(width=4);obs=analytics(vf=4,Width=4)
        baseline=backend_cost(c,obs)['effective_body_quarters']
        terms=dict(service=F(0),interaction=F(0))
        for removed in (0,4,12):
            result=replace_memory_cost(c,obs,terms,removed)
            self.assertEqual(result['effective_body_quarters'],baseline-removed)

    def test_validation_and_profile_round_trip(self):
        from dataclasses import asdict
        p=Parameters(service_costs={'indexed:load':'3/4'},throughput='1/2')
        self.assertEqual(Parameters.from_mapping(asdict(p)),p)
        for kwargs in [dict(window_size=0),dict(throughput=0),dict(reference_width=-1),
                       dict(demand_weights={'unknown':1}),dict(service_costs={'unit':-1}),
                       dict(stride_interval_bytes=0),dict(stride_service_strength=-1),
                       dict(stride_demand_strength='5/4'),dict(service_scale=-1),
                       dict(llvm_memory_removal='unknown')]:
            with self.assertRaises(ValueError):Parameters(**kwargs)

    def test_stride_unknown_zero_reverse_and_other_kinds(self):
        r=dict(kind='strided',stride=1024)
        self.assertEqual(stride_factor(r,F(8),F(1)),F(1,128))
        self.assertEqual(stride_factor(r|dict(stride=-1024),F(8),F(1)),F(1,128))
        self.assertEqual(stride_factor(r,F(8),F(1,2)),F(129,256))
        for stride in (None,0,4,8,-8):
            self.assertEqual(stride_factor(r|dict(stride=stride),F(8),F(1)),1)
        for kind in ('unit','segment','segment-strided','indexed','scalar'):
            self.assertEqual(stride_factor(r|dict(kind=kind),F(8),F(1)),1)
        self.assertEqual(stride_factor(r,F(8),F(0)),1)

    def test_stride_cost_and_demand_can_be_enabled_independently(self):
        f=body([access(0,0,vl=8)|dict(stride=1024)])
        p=Parameters(window_size=2)
        before=window_terms(f,p)
        cost=window_terms(f,replace(p,stride_service_strength=F(1)))
        demand=window_terms(f,replace(p,stride_demand_strength=F(1)))
        self.assertEqual((cost['service'],cost['interaction']),(F(1,16),before['interaction']))
        self.assertEqual((demand['service'],demand['interaction']),(before['service'],0))
        unknown=body([access(0,0,vl=8)|dict(stride=None)])
        self.assertEqual(window_terms(unknown,p),window_terms(unknown,replace(p,stride_service_strength=F(1),stride_demand_strength=F(1))))
        self.assertEqual(demand['stride_known'],1)

    def test_opcode_override_is_absolute_even_with_stride_adjustment(self):
        r=body([access(0,0,vl=8)|dict(stride=1024)])['records'][0]
        self.assertEqual(operation_value(r,{}, {'LOAD':F(3)},F(8),F(1)),3)


if __name__=='__main__':unittest.main()
