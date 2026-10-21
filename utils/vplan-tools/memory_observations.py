"""Conservative, offline memory facts from saved post-RA analytics and MIR.

No benchmark names or measured cycles enter this module. Unknown provenance is
explicit. The small symbolic interpreter supports straight-line integer address
construction, not general MIR execution or control-flow analysis.
"""
from fractions import Fraction as F
import re

from spill_observations import iteration_ratio
from vplan_report import rational


def _walk(nodes):
    for n in nodes:
        yield n
        yield from _walk(n.get('events', []))
        yield from _walk(n.get('children', []))


def llvm_memory_cost(candidate, parsed):
    """Exact additive vector-region memory-hook subtotal, in quarter units.

Interleaved hooks include their opaque shuffle/lowering costs; removing the hook
removes those too. Address computation and separately reported shuffles remain.
Reject non-additive/weighted/opaque memory recipes instead of guessing.
"""
    variants = []
    for report in parsed['reports']:
        if (report['header']['function'], int(report['header']['loop'])) != (candidate['function'], candidate['loop']):
            continue
        for plan in report['plans']:
            if int(candidate['id'].rsplit(':', 2)[1]) != plan['id']:
                continue
            graph = {g['id']: g['payload'] for g in plan['graph']['recipes']}
            for ev in plan['evaluations']:
                if ev['vf'] != candidate['vf'] or ev['phase'] not in ('main-selection', 'candidate-validation'):
                    continue
                subtotal, evidence = F(0), []
                for rec in ev['events']:
                    if rec['kind'] != 'recipe' or rec['scope'] != 'vector-region':
                        continue
                    nodes = list(_walk(rec['events']))
                    leaves = [n['fields'] for n in nodes if n['kind'] == 'term' and n['fields'].get('coverage') == 'tti-leaf']
                    mem = [n for n in leaves if n['term'] in ('getMemoryOpCost', 'getMemIntrinsicInstrCost', 'getInterleavedMemoryOpCost')]
                    final = next(n['fields'] for n in rec['events'] if n['kind'] == 'cost')
                    cost, contribution = rational(final['cost']), rational(final['contribution'])
                    if not mem:
                        # SSA names such as %spec.store.select are not opcodes.
                        payload = re.sub(r'ir<[^>]*>', '', graph[rec['id']].split('!dbg')[0]).lower()
                        memory_recipe = any(n['kind'] == 'memory' or
                                            (n['kind'] == 'operation' and n['fields'].get('opcode') in ('load', 'store'))
                                            for n in nodes)
                        if cost != 0 and (memory_recipe or re.search(r'\b(load|store|interleave)\b', payload)):
                            raise ValueError('unattributed memory recipe R' + str(rec['id']))
                        continue
                    values = [rational(n['result']) for n in leaves]
                    if isinstance(cost, str) or any(isinstance(v, str) for v in values) or cost != contribution or sum(values) != cost:
                        raise ValueError('non-additive memory recipe R' + str(rec['id']))
                    for n in mem:
                        value = rational(n['result'])
                        subtotal += value
                        evidence.append(dict(recipe=rec['id'], hook=n['term'], cost=value))
                q = subtotal * 4
                if q.denominator != 1 or not 0 <= q <= candidate['middle_end']['vector_region']:
                    raise ValueError('invalid memory subtotal')
                variants.append((int(q), evidence))
    if not variants or any(v != variants[0] for v in variants):
        raise ValueError('missing or inconsistent memory cost evaluations')
    return dict(quarters=variants[0][0], evidence=variants[0][1])


def _mir_lines(observation, mir):
    match = re.search(r'^body:\s*\|\s*\n', mir, re.M)
    if not match:
        raise ValueError('missing machine body')
    lines = {}
    block = None
    for line in mir[match.end():].splitlines():
        b = re.match(r'  bb\.(\d+)', line)
        if b:
            block = int(b[1])
        elif line.startswith('    ') and not line.strip().startswith(('successors:', 'liveins:')):
            lines.setdefault(block, []).append(line)
    offsets, result = {}, {}
    for ins in observation['Instructions']:
        block = ins['Block']
        seq = lines.get(block, [])
        start = offsets.get(block, 0)
        for n in range(start, len(seq)):
            if re.search(r'\b' + re.escape(ins['Opcode']) + r'\b', seq[n]):
                result[ins['ID']] = seq[n]
                offsets[block] = n + 1
                break
        else:
            raise ValueError('MIR/analytics instruction mismatch: ' + str(ins['ID']))
    return result


def _add(a, b):
    if a is None or b is None or (a[0] is not None and b[0] is not None):
        return None
    return (a[0] or b[0], a[1] + b[1])


def _step(ins, raw, regs):
    if ins['Barrier']:
        regs.clear()
        regs['X0'] = (None, 0)
        return
    uses = [o for o in ins['Operands'] if o.get('Use') and not o['Implicit'] and not o['Undef'] and o['Bank'] == 'gpr']
    defs = [o for o in ins['Operands'] if o['Def'] and o['Bank'] == 'gpr']
    args = [regs.get(o['Name']) for o in uses]
    imm = ins.get('Immediates', [])
    op, value = ins['Opcode'], None
    if op == 'AUIPC' and 'riscv-pcrel-hi' in raw:
        sym = re.search(r'@([\w.$]+)(?:\s*\+\s*(-?\d+))?', raw)
        if sym:
            value = ('$pcrel:' + sym[1], int(sym[2] or 0))
    elif op == 'LUI' and len(imm) == 1:
        v = (imm[0] << 12) & 0xffffffff
        value = (None, v - (1 << 32) if v & (1 << 31) else v)
    elif op == 'ADDI' and len(args) == 1:
        if 'riscv-pcrel-lo' in raw and args[0] and (args[0][0] or '').startswith('$pcrel:'):
            value = (args[0][0][7:], args[0][1])
        elif len(imm) == 1:
            value = _add(args[0], (None, imm[0]))
    elif op == 'ADD' and len(args) == 2:
        value = _add(*args)
    elif op == 'SLLI' and len(args) == len(imm) == 1 and args[0] and args[0][0] is None:
        value = (None, args[0][1] << imm[0])
    elif op == 'COPY' and len(args) == 1:
        value = args[0]
    for d in defs:
        if d['Name'] != 'X0':
            regs[d['Name']] = value
    regs['X0'] = (None, 0)


def extract_memory(candidate, observation, mir):
    ratio = iteration_ratio(candidate, observation)
    body_ids = {b['ID'] for b in observation['Blocks'] if b['Role'] == 'body'}
    if len(body_ids) != 1:
        raise ValueError('memory model requires one body block')
    raw = _mir_lines(observation, mir)
    body = [i for i in observation['Instructions'] if i['Block'] in body_ids and not i['Meta']]
    entries = {b['ID'] for b in observation['Blocks'] if b['Role'] == 'entry'}
    regs = {'X0': (None, 0)}
    if len(entries) == 1:
        for i in observation['Instructions']:
            if i['Block'] in entries:
                _step(i, raw[i['ID']], regs)
    passes = []
    for iteration in range(2):
        records = []
        for pos, i in enumerate(body):
            if (i['Load'] or i['Store']) and not i['Spill']:
                op = i['Base'] or i['Opcode']
                whole = re.fullmatch(r'VL([1248])RE(?:8|16|32|64)_V|VS([1248])R_V', op)
                ordinary = re.fullmatch(r'V[LS](S?)E(8|16|32|64)_V', op)
                group = F(i['Group8'], 8)
                if whole:
                    kind, eew = 'unit', 8
                    vl = F(int(whole[1] or whole[2]) * observation['VLen'], 8)
                    requests = vl / 16
                elif ordinary and group > 0:
                    kind, eew = ('strided' if ordinary[1] else 'unit'), int(ordinary[2])
                    # Memory register group is EMUL: use EEW, not arithmetic SEW.
                    vl = F(observation['VLen']) * group / eew
                    requests = vl if kind == 'strided' else vl * eew / 128
                elif not any(o['Vector'] for o in i['Operands']):
                    kind, eew, vl, requests = 'scalar', 0, F(1), F(1)
                else:
                    raise ValueError('unsupported vector memory opcode ' + op)
                requests = F(-(-requests.numerator // requests.denominator))
                uses = [o for o in i['Operands'] if o.get('Use') and not o['Implicit'] and o['Bank'] == 'gpr']
                address = regs.get(uses[0]['Name']) if uses else None
                stride = regs.get(uses[1]['Name']) if kind == 'strided' and len(uses) > 1 else None
                if address and (address[0] is None or address[0].startswith('$pcrel:')):
                    address = None
                records.append(dict(id=i['ID'], position=pos, opcode=op, kind=kind, load=i['Load'],
                                    eew=eew, group=group, vl=vl, requests=requests,
                                    masked=i['Masked'], address=address,
                                    stride=stride[1] if stride and stride[0] is None else None))
            _step(i, raw[i['ID']], regs)
        passes.append(records)
    for first, second in zip(*passes, strict=True):
        a, b = first['address'], second['address']
        first['iteration_delta'] = b[1] - a[1] if a and b and a[0] == b[0] else None
        if first['stride'] != second['stride']:
            first['stride'] = None
    return dict(records=passes[0], body_length=len(body), iteration_ratio=ratio,
                trip_count=observation['ExactTripCount'], width=observation['Width'],
                edges=observation['Edges'],
                assumptions=['full-active VL; masks treated as active; no cache state or bank mapping',
                             'straight-line first two iterations; address comparisons require equal iteration deltas'])
