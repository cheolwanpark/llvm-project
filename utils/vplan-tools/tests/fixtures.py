from observations import SCHEMA


def reg(index, unit, *, define=False, use=False):
    return dict(index=index, kind='register', text=f'r{unit}', register=unit, name=f'R{unit}', units=[unit],
                group8=0, physical=True, **{'def': define}, use=use, implicit=False, undef=False,
                dead=False, kill=False, early_clobber=False, tied=False, subregister=0, internal_read=False)


def instruction(id_, base='VADD_VV', **kwargs):
    return dict(id=id_, block=0, role='body', mir=f'{base} op{id_}', opcode=base, base_opcode=base, pseudo=False,
                vector=base.startswith('V'), meta=False, configuration=False, registers_complete=True,
                load=False, store=False, lmul8=8, sew=32, vl=None, stride=None, index_emul8=None, index_eew=None, masked=False, operands=[], memory=[]) | kwargs


def memory(slot=0, *, store=False, offset=0, size=8, scalable=False):
    return dict(load=not store, store=store, volatile=False, atomic=False, offset=offset, bytes=size,
                scalable=scalable, alignment=8, base='', stack_slot=slot, alias_scope=False, noalias=False, spill_slot=True)


def observation(ops=None, edges=None, **kwargs):
    ops = ops or [instruction(0), instruction(1, 'VFADD_VV')]
    return dict(schema=SCHEMA, run_id='test', candidate='selected_kernel:0:0:s2', function='selected_kernel',
                stage='post-frame-lowering', compiler='test compiler', target_triple='riscv64-unknown-elf',
                cpu='xiangshan-kunminghu', features='+v', vlen=128, vf=2, scalable=True, iteration_width=4,
                iteration_mapping=True, max_trip_count=16, exact_trip_count=16, scalar_tail=True, error='', header=0,
                register_coverage='physical-register-units-distance-0-1', memory_coverage='facts-only',
                blocks=[dict(id=0, role='body', successors=[0])], body_order=[o['id'] for o in ops],
                instructions=ops, dependencies=edges or [], scalar_cost=3.,
                middle_end=dict(configuration_unit_quarters=4, configuration_source='TTI.getIntrinsicInstrCost(riscv_vsetvlimax)',
                                configuration_scope='per-observed-MIR-configuration', unit='TTI-reciprocal-throughput-quarter')) | kwargs


def edge(source, destination, unit=1, distance=0, operand=0):
    return dict(source=source, destination=destination, operand_index=operand, unit=unit,
                iteration_distance=distance, kind='register-raw')
