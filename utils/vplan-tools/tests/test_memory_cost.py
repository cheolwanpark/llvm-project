"""Invariants of exploratory memory arithmetic and conservative attribution."""
import copy
from fractions import Fraction as F
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cost_model import MAX_COST, backend_cost
from memory_cost import Parameters, apply_memory_cost, memory_terms, request_cost
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
                                         unknown_stride_weight='2', locality_bytes=8,
                                         segment_overhead='5/4', segment_strided_overhead='3/2',
                                         unit_request_scale='1/8', nonunit_request_scale='8',
                                         indexed_overhead={'numerator': 2, 'denominator': 1}))
        self.assertEqual(Parameters.from_mapping(asdict(p)), p)
        for kwargs in [dict(alpha=-1), dict(distance_scale=0), dict(threshold=-1), dict(locality_bytes=0),
                       dict(segment_overhead=0), dict(segment_strided_overhead=F(1, 2)),
                       dict(indexed_overhead=-1), dict(unit_request_scale=0),
                       dict(unit_request_scale=2), dict(nonunit_request_scale=F(1, 2))]:
            with self.assertRaises(ValueError):
                Parameters(**kwargs)

    def test_overhead_prices_only_target_loads_without_mutating_facts(self):
        p = Parameters(segment_overhead=2, segment_strided_overhead=3, indexed_overhead=4)
        for kind, scale in [('scalar', 1), ('unit', 1), ('strided', 1),
                            ('segment', 2), ('segment-strided', 3), ('indexed', 4)]:
            r = access(0, 0) | dict(kind=kind)
            before = copy.deepcopy(r)
            self.assertEqual(request_cost(r, p), 8 * scale)
            self.assertEqual(request_cost(r | dict(load=False), p), 8)
            self.assertEqual(r, before)

    def test_unit_discount_and_nonunit_scale_preserve_store_requests(self):
        p = Parameters(unit_request_scale=F(1, 8), nonunit_request_scale=8, segment_overhead=3)
        for kind, expected in [('unit', 1), ('scalar', 64), ('strided', 64),
                               ('segment', 192), ('segment-strided', 64), ('indexed', 64)]:
            r = access(0, 0) | dict(kind=kind)
            self.assertEqual(request_cost(r, p), expected)
            self.assertEqual(request_cost(r | dict(load=False), p), 8)

    def test_half_unit_requests_remove_m8_pair_threshold_penalty(self):
        f = facts([access(0, 0) | dict(kind='unit'), access(1, 1) | dict(kind='unit')])
        self.assertGreater(memory_terms(f, load_scope='all')['distance'], 0)
        for scale in (F(1, 2), F(1, 4), F(1, 8)):
            terms = memory_terms(f, Parameters(unit_request_scale=scale), load_scope='all')
            self.assertEqual(terms['distance'], 0)
            self.assertEqual(terms['service'], 16 * scale)

    def test_relative_scale_equivalence_requires_threshold_and_alpha_conversion(self):
        f = facts([access(0, 0) | dict(kind='unit'),
                   access(1, 1, stride=None) | dict(kind='indexed'),
                   access(2, 2, vl=20, stride=20) | dict(kind='segment', fields=5)])
        discount = memory_terms(f, Parameters(unit_request_scale=F(1, 8), segment_overhead=3),
                                load_scope='all', include_address=False)
        inflate = memory_terms(f, Parameters(nonunit_request_scale=8, segment_overhead=3),
                               load_scope='all', include_address=False)
        converted = memory_terms(f, Parameters(nonunit_request_scale=8, segment_overhead=3,
                                               threshold=64, alpha=F(1, 16)),
                                 load_scope='all', include_address=False)
        self.assertGreater(inflate['distance'], discount['distance'])
        for key in ('distance', 'stride_adjustment'):
            self.assertEqual(converted[key], discount[key])

    def test_overhead_applies_before_pair_threshold_and_quarter_rounding(self):
        # One segment request and seven ordinary requests are below the old
        # pair threshold. A fractional overhead must survive until final pricing.
        f = facts([access(0, 0, vl=1) | dict(kind='segment', fields=1),
                   access(1, 1, vl=7)])
        before = copy.deepcopy(f)
        control = memory_terms(f, load_scope='all')
        changed = memory_terms(f, Parameters(segment_overhead=F(3, 2)), load_scope='all')
        self.assertEqual(control['distance'], 0)
        self.assertEqual(changed['pairs'][0]['raw'], F(1, 4))
        self.assertEqual(changed['service'], F(17, 2))
        self.assertEqual(f, before)
        # Multipliers are exact rationals, not rounded request counts.
        f['iteration_ratio'] = 3
        scaled = memory_terms(f, Parameters(segment_overhead=F(3, 2)), load_scope='all')
        self.assertEqual(scaled['distance'], changed['distance'] / 3)

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

    def test_all_loads_pair_in_instruction_order_and_exclude_stores(self):
        records = [access(n, n, vl=12) | dict(kind=kind)
                   for n, kind in enumerate(('unit', 'segment', 'indexed', 'scalar', 'strided'))]
        records.append(access(5, 5, load=False))
        f = facts(records)
        self.assertEqual(len(memory_terms(f)['pairs']), 1)
        terms = memory_terms(f, load_scope='all')
        self.assertEqual([(p['source'], p['destination']) for p in terms['pairs']],
                         [(0, 1), (1, 2), (2, 3), (3, 4), (4, 0)])
        self.assertGreater(terms['distance'], 0)
        f['iteration_ratio'] = 2
        self.assertEqual(memory_terms(f, load_scope='all')['distance'], terms['distance'] / 2)

    def test_segment_fields_contribute_to_shared_line_footprint(self):
        # Field 0 lies in the preceding line for every alignment; field 1
        # reaches the store's line for some alignments.
        records = [access(0, 0, vl=1, stride=8) | dict(kind='segment', fields=2),
                   access(1, 1, vl=1, stride=4, load=False, offset=67)]
        p = Parameters(threshold=0)
        terms = memory_terms(facts(records), p, load_scope='all')
        self.assertGreater(terms['address'], 0)
        records[0]['fields'] = 1
        self.assertEqual(memory_terms(facts(records), p, load_scope='all')['address'], 0)

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
    def extract(self, instructions, **kwargs):
        instructions = copy.deepcopy(instructions)
        for ins in instructions:
            for op in ins['Operands']:
                op.setdefault('Bank', 'vector' if op['Vector'] else 'other')
        obs = analytics(instructions, vf=4, Width=4)
        mir = 'body: |\n  bb.0.body:\n' + ''.join('    ' + i['Opcode'] + '\n' for i in instructions)
        return extract_memory(candidate(width=4), obs, mir, **kwargs)

    def test_segment_tuple_without_vector_flag_is_not_scalar(self):
        ins = instruction(Opcode='PseudoVLSEG5E32_V_M1', Base='VLSEG5E32_V',
                          Load=True, Spill=False, Group8=8,
                          Operands=[operand(Vector=False, Def=True)])
        legacy = self.extract([ins])['records'][0]
        self.assertEqual(legacy['kind'], 'scalar')
        f = self.extract([ins], load_scope='all')
        r = f['records'][0]
        self.assertEqual((r['kind'], r['vl'], r['fields'], r['requests'], r['stride']),
                         ('segment', 4, 5, 20, 20))
        self.assertGreater(memory_terms(f, load_scope='all')['distance'], 0)

    def test_strided_segment_uses_eew_and_scalar_stride_register(self):
        setup = instruction(Opcode='ADDI', Base='', Spill=False,
                            Operands=[operand(Bank='gpr', Name='X1', Def=True),
                                      operand(Bank='gpr', Name='X0', Use=True)], Immediates=[24])
        ins = instruction(Opcode='PseudoVLSSEG3E32_V_M2', Base='VLSSEG3E32_V',
                          Load=True, Spill=False, Group8=16, SEW=64,
                          Operands=[operand(Bank='gpr', Name='X2', Use=True),
                                    operand(Bank='gpr', Name='X1', Use=True)])
        r = self.extract([setup, ins], load_scope='all')['records'][0]
        self.assertEqual((r['kind'], r['vl'], r['fields'], r['requests'], r['stride']),
                         ('segment-strided', 8, 3, 24, 24))

    def test_indexed_uses_data_sew_not_index_eew(self):
        ins = instruction(Opcode='PseudoVLUXEI64_V_M4_M2', Base='VLUXEI64_V',
                          Load=True, Spill=False, Group8=16, SEW=32,
                          IndexSEW=64, IndexGroup8=32)
        r = self.extract([ins], load_scope='all')['records'][0]
        self.assertEqual((r['kind'], r['vl'], r['eew'], r['requests']), ('indexed', 8, 32, 8))
        self.assertIsNone(r['stride'])
        self.assertIsNone(r['address'])
        ins.update(Opcode='PseudoVLUXSEG2EI64_V_M2', Base='VLUXSEG2EI64_V')
        r = self.extract([ins], load_scope='all')['records'][0]
        self.assertEqual((r['vl'], r['fields'], r['requests']), (8, 2, 16))

    def test_unit_scalar_and_spill_coverage(self):
        instructions = [
            instruction(Opcode='VL8RE32_V', Base='', Load=True, Spill=False),
            instruction(Opcode='PseudoVLE32_V_M8', Base='VLE32_V', Load=True, Spill=False, Group8=64),
            instruction(Opcode='LD', Base='', Load=True, Spill=False, Bytes=8, Operands=[]),
            instruction(Opcode='VL8RE32_V', Base='', Load=True, Spill=True),
        ]
        f = self.extract(instructions, load_scope='all')
        self.assertEqual([r['requests'] for r in f['records']], [8, 8, 1])
        self.assertEqual([r['stride'] for r in f['records']], [1, 4, 0])
        self.assertEqual(len(memory_terms(f, load_scope='all')['pairs']), 3)

    def test_unknown_vector_tuple_rejects_instead_of_scalar_fallback(self):
        ins = instruction(Opcode='PseudoUnknown', Base='VUNKNOWN_V', Load=True, Spill=False,
                          Operands=[operand(Vector=False)])
        with self.assertRaisesRegex(ValueError, 'unsupported vector memory'):
            self.extract([ins], load_scope='all')

    def test_only_memory_hook_is_subtracted_not_address_or_separate_shuffle(self):
        c=candidate(); c['middle_end']['vector_region']=40
        p=detail(c,'WIDEN load', [('getMemoryOpCost',3),('getAddressComputationCost',2),('getShuffleCost',1)])
        self.assertEqual(llvm_memory_cost(c,p)['quarters'],12)
        self.assertEqual(llvm_memory_cost(c,p,removal_scope='recipes')['quarters'],24)
        with self.assertRaisesRegex(ValueError,'non-additive'):
            llvm_memory_cost(c,detail(c,'load',[('getMemoryOpCost',3)],contribution=6))
        with self.assertRaisesRegex(ValueError,'non-additive'):
            llvm_memory_cost(c,detail(c,'load',[('getMemoryOpCost',3)],contribution=6), removal_scope='recipes')

    def test_ssa_name_is_not_a_memory_opcode(self):
        c=candidate(); c['middle_end']['vector_region']=40
        p=detail(c,'WIDEN ir<%spec.store.select> = select ir<%load.x>', [('getCmpSelInstrCost',1)])
        self.assertEqual(llvm_memory_cost(c,p)['quarters'],0)
        with self.assertRaisesRegex(ValueError,'unattributed'):
            llvm_memory_cost(c,detail(c,'WIDEN load',[('opaque',1)]))

    def test_whole_memory_recipe_preserves_separate_shuffle(self):
        c=candidate(); c['middle_end']['vector_region']=80
        p=detail(c,'WIDEN load', [('getMemoryOpCost',3),('getAddressComputationCost',2)])
        plan=p['reports'][0]['plans'][0]
        separate=detail(c,'WIDEN shuffle', [('getShuffleCost',7)])['reports'][0]['plans'][0]
        recipe=separate['evaluations'][0]['events'][0] | {'id':2}
        plan['graph']['recipes'].append(dict(id=2,payload='WIDEN shuffle'))
        plan['evaluations'][0]['events'].append(recipe)
        self.assertEqual(llvm_memory_cost(c,p,removal_scope='recipes')['quarters'],20)
        self.assertEqual(llvm_memory_cost(c,p)['quarters'],12)

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
