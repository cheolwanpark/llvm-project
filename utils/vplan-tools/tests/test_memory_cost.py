"""Invariants of exploratory memory arithmetic and conservative attribution."""
import copy
from fractions import Fraction as F
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cost_model import MAX_COST, backend_cost
from memory_cost import Parameters, apply_memory_cost, memory_terms
from memory_observations import _step, extract_memory, llvm_memory_cost
from analytics_fixtures import analytics, instruction, operand
from test_middle_end_model import candidate


def access(i, position, *, stride=8, load=True, obj='a', offset=0, vl=8):
    return dict(id=i, position=position, kind='strided', load=load, stride=stride,
                requests=F(vl), vl=F(vl), eew=32, address=(obj, offset), iteration_delta=64)


def facts(records, **kw):
    return dict(records=records, body_length=10, iteration_ratio=1,
                trip_count=0, width=8, edges=[], **kw)


class MemoryCostTests(unittest.TestCase):
    def test_parameter_profile_round_trip_and_validation(self):
        from dataclasses import asdict
        p = Parameters.from_mapping(dict(alpha='1/4', reverse_weight={'numerator':1,'denominator':2},
                                         unknown_stride_weight='2', locality_bytes=8))
        self.assertEqual(Parameters.from_mapping(asdict(p)), p)
        for kwargs in [dict(alpha=-1), dict(distance_scale=0), dict(threshold=-1), dict(locality_bytes=0)]:
            with self.assertRaises(ValueError):
                Parameters(**kwargs)

    def test_reverse_and_unknown_weights_only_affect_interaction(self):
        f=facts([access(0,0,stride=-4),access(1,1,stride=None),access(2,5,load=False)])
        zero=memory_terms(f)
        tuned=memory_terms(f,Parameters(reverse_weight=F(1,2),unknown_stride_weight=F(1,2)))
        self.assertEqual(zero['service'],tuned['service'])
        self.assertEqual(tuned['distance']+tuned['stride_adjustment'],tuned['distance']/2)
        skipped=memory_terms(f,include_address=False)
        for key in ('service','distance','stride_adjustment'):
            self.assertEqual(skipped[key],zero[key])
        self.assertEqual(skipped['address'],0)

    def test_stride_distinguishes_identical_order_and_load_counts(self):
        dense=memory_terms(facts([access(0,0),access(1,1,obj='b')]))
        sparse=memory_terms(facts([access(0,0,stride=1024),access(1,1,stride=1024,obj='b')]))
        self.assertEqual(dense['distance'],sparse['distance'])
        self.assertEqual(dense['stride_adjustment'],0)
        self.assertEqual(sparse['distance']+sparse['stride_adjustment'],dense['distance']/64)

    def test_address_only_for_comparable_objects_and_iteration_offsets(self):
        rs=[access(0,0),access(1,1,obj='b'),access(2,5,load=False,offset=4)]
        t=memory_terms(facts(rs))
        self.assertGreater(t['address'],0)
        for field,value in [('address',('other',4)),('iteration_delta',32),('address',None)]:
            changed=copy.deepcopy(rs);changed[2][field]=value
            self.assertEqual(memory_terms(facts(changed))['address'],0)

    def test_reverse_retains_service_unknown_retains_distance(self):
        rs=[access(0,0,stride=-4),access(1,1,stride=1024)]
        t=memory_terms(facts(rs))
        self.assertEqual(t['service'],16)
        self.assertEqual(t['distance']+t['stride_adjustment'],0)
        rs[0]['stride']=rs[1]['stride']=None
        t=memory_terms(facts(rs))
        self.assertEqual(t['stride_adjustment'],0)
        self.assertEqual(t['unknown_stride'],[0,1])

    def test_cyclic_pairs_ignore_trip_count_and_dependency_gates(self):
        f=facts([access(0,0),access(1,1)])
        expected=memory_terms(f)
        self.assertGreater(expected['pairs'][-1]['raw'],0)
        for trip_count in (8,16,255):
            f['trip_count']=trip_count
            for edges in ([], [dict(Source=0,Destination=1,Distance=0),
                               dict(Source=1,Destination=0,Distance=1)]):
                f['edges']=edges
                self.assertEqual(memory_terms(f),expected)
        # A single strided load still pairs with itself in the next body.
        f['records']=f['records'][:1]
        f['trip_count']=8
        f['edges']=[dict(Source=0,Destination=0,Distance=1)]
        single=memory_terms(f)
        self.assertEqual(len(single['pairs']),1)
        self.assertTrue(single['pairs'][0]['wrap'])
        self.assertGreater(single['distance'],0)

    def test_terms_normalized_once_and_pairs_bounded_by_load_count(self):
        f=facts([access(0,0),access(1,1),access(2,2)])
        t=memory_terms(f)
        f['iteration_ratio']=3
        u=memory_terms(f)
        for k in ('service','distance','stride_adjustment','address'):
            self.assertEqual(u[k],t[k]/3)
        self.assertEqual(len(t['pairs']),3)

    def test_add_replace_and_residual_use_same_service_and_preserve_spills(self):
        c=candidate(width=4);c['middle_end'].update(precomputed=4,vector_region=28)
        obs=analytics(vf=4,Width=4)
        t=dict(service=F(3,2),distance=F(1,3),stride_adjustment=F(-1,6),address=F(1,5))
        before=copy.deepcopy(c)
        a=apply_memory_cost(c,obs,t,mode='add',stage='address')
        r=apply_memory_cost(c,obs,t,mode='replace',stage='address',llvm_memory_quarters=12)
        x=apply_memory_cost(c,obs,t,mode='residual',stage='address')
        self.assertEqual(a['effective_body_quarters']-r['effective_body_quarters'],12)
        self.assertEqual(a['memory_added_quarters'],int(4*(F(3,2)+F(1,3)-F(1,6)+F(1,5))))
        self.assertEqual(x['memory_added_quarters'],1)
        self.assertEqual(c,before)
        zero=dict.fromkeys(t,F(0))
        self.assertEqual(apply_memory_cost(c,obs,zero,mode='residual',stage='address')['effective_body_quarters'],backend_cost(c,obs)['effective_body_quarters'])
        with self.assertRaises(ValueError):
            apply_memory_cost(c,obs,t,mode='replace',stage='address',llvm_memory_quarters=29)
        c['middle_end']['vector_region']=MAX_COST
        with self.assertRaises(ValueError):
            apply_memory_cost(c,obs,t,mode='replace',stage='address')


def cost_value(n):
    return dict(state='valid',numerator=n,denominator=1)


def detail(c,payload,leaves,contribution=None):
    value=sum(v for _,v in leaves)
    ev=dict(vf=c['vf'],phase='main-selection',events=[dict(kind='recipe',id=1,scope='vector-region',events=[
        *[dict(kind='term',fields=dict(term=k,result=cost_value(v),coverage='tti-leaf')) for k,v in leaves],
        dict(kind='cost',fields=dict(cost=cost_value(value),contribution=cost_value(value if contribution is None else contribution)))])])
    return dict(reports=[dict(header=dict(function=c['function'],loop=c['loop']),plans=[dict(
        id=int(c['id'].rsplit(':',2)[1]),graph=dict(recipes=[dict(id=1,payload=payload)]),evaluations=[ev])])])


class MemoryAttributionTests(unittest.TestCase):
    def test_only_memory_hook_is_subtracted_not_address_or_separate_shuffle(self):
        c=candidate(); c['middle_end']['vector_region']=40
        p=detail(c,'WIDEN load', [('getMemoryOpCost',3),('getAddressComputationCost',2),('getShuffleCost',1)])
        self.assertEqual(llvm_memory_cost(c,p)['quarters'],12)
        with self.assertRaisesRegex(ValueError,'non-additive'):
            llvm_memory_cost(c,detail(c,'load',[('getMemoryOpCost',3)],contribution=6))

    def test_ssa_name_is_not_a_memory_opcode(self):
        c=candidate(); c['middle_end']['vector_region']=40
        p=detail(c,'WIDEN ir<%spec.store.select> = select ir<%load.x>', [('getCmpSelInstrCost',1)])
        self.assertEqual(llvm_memory_cost(c,p)['quarters'],0)
        with self.assertRaisesRegex(ValueError,'unattributed'):
            llvm_memory_cost(c,detail(c,'WIDEN load',[('opaque',1)]))

    def test_symbolic_register_clobber_and_negative_stride(self):
        use=lambda name:operand(Bank='gpr',Name=name,Use=True)
        define=lambda name:operand(Bank='gpr',Name=name,Def=True)
        regs={'X0':(None,0)}
        i=instruction(Opcode='ADDI',Operands=[define('X1'),use('X0')],Immediates=[-4])
        _step(i,'ADDI',regs)
        self.assertEqual(regs['X1'],(None,-4))
        _step(i|dict(Opcode='UNKNOWN'),'UNKNOWN',regs)
        self.assertIsNone(regs['X1'])
        regs['X2']=('a',0)
        _step(i|dict(Barrier=True),'CALL',regs)
        self.assertEqual(regs,{'X0':(None,0)})

    def test_emul_uses_eew_not_sew_and_mir_mismatch_rejects(self):
        c=candidate(width=4)
        ins=instruction(Opcode='PseudoVLSE32_V_M2',Base='VLSE32_V',Load=True,Group8=16,SEW=64,Spill=False,
                        Operands=[operand(Bank='vector',Vector=True,Def=True)])
        obs=analytics([ins],vf=4,Width=4)
        mir='body: |\n  bb.0.body:\n    PseudoVLSE32_V_M2\n'
        f=extract_memory(c,obs,mir)
        self.assertEqual(f['records'][0]['requests'],8)
        self.assertIsNone(f['records'][0]['stride'])
        with self.assertRaisesRegex(ValueError,'mismatch'):
            extract_memory(c,obs,mir.replace('PseudoVLSE32_V_M2','BAD'))


if __name__=='__main__':
    unittest.main()
