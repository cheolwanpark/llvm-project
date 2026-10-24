"""Bounded memory demand, not a cache simulator or a cycle prediction.

LLVM owns value proofs. This module only enumerates at most VLEN*8/8 bytes
and 16 possible base phases. Unknown masks/addresses use all-active/disjoint
bounds; no inter-instruction reuse or memory independence is assumed.
"""
from fractions import Fraction
from functools import lru_cache
import re

from model_errors import ToolError


def touched(start, size, unit):
    return range(start // unit, (start + size - 1) // unit + 1)


@lru_cache(maxsize=4096)
def address_work(lanes, size, fields, stride, alignment, contiguous):
    """Upper bounds over the possible base residues, with exact offset sets."""
    count = lanes * fields
    if not count:
        return 0, 0
    if stride is None:
        # Independent unknown addresses may each cross a boundary. Even a
        # known base alignment cannot constrain arbitrary vector indices.
        return count * (1 + (size > 1)), count
    offsets = [(i * stride + f * size) % (1 << 64) for i in range(lanes) for f in range(fields)]
    # A unit/whole-register access is issued as consecutive 16-byte chunks.
    chunks = ([(i, min(16, count * size - i)) for i in range(0, count * size, 16)]
              if contiguous else [(o, size) for o in offsets])
    requests = 0
    for phase in range(0, 16, min(alignment, 16)):
        requests = max(requests, sum(len(touched(phase + o, n, 16)) for o, n in chunks))
    return requests, len(set(offsets))


def memory_work(op, hardware, vlen):
    if not (op['load'] or op['store']):
        return None
    g = hardware['geometry']
    masked = op['masked']
    fields, exact, contiguous = 1, True, False
    reasons = []
    if not op['vector']:
        widths = {'LB': 1, 'LBU': 1, 'SB': 1, 'LH': 2, 'LHU': 2, 'SH': 2,
                  'LW': 4, 'LWU': 4, 'SW': 4, 'FLW': 4, 'FSW': 4,
                  'LD': 8, 'SD': 8, 'FLD': 8, 'FSD': 8}
        size = widths.get(op['base_opcode'])
        if size is None:
            raise ToolError('unverified scalar memory width: ' + op['base_opcode'])
        lanes, stride = 1, size
    elif 'whole_registers' in g:
        load = re.fullmatch(r'VL[1248]RE(8|16|32|64)_V', op['base_opcode'])
        size = int(load[1]) // 8 if load else 1
        lanes, stride, contiguous = g['whole_registers'] * vlen // 8 // size, size, True
    else:
        size, fields = g['eew'] // 8, g['fields']
        capacity = Fraction(vlen, g['eew']) * Fraction(g['data_emul'])
        if capacity.denominator != 1 or capacity < 1:
            raise ToolError('nonintegral memory lane capacity')
        maximum = int(capacity)
        vl = op['vl']
        if vl is not None and vl > maximum:
            raise ToolError('observed VL exceeds memory geometry')
        lanes = maximum if vl is None else vl
        exact = vl is not None and not masked
        if vl is None:
            reasons.append('VL unknown: VLMAX bound')
        if masked:
            reasons.append('mask unknown: all-active bound')
        split = hardware['split']
        stride = (None if split == 'VEC_I_LDST' else
                  op['stride'] if split == 'VEC_S_LDST' else fields * size)
        contiguous = split == 'VEC_US_LDST' and fields == 1
        if stride is None:
            reasons.append('addresses unknown: disjoint boundary-crossing bound')
    alignment = min((m['alignment'] for m in op['memory']), default=1)
    requests, distinct = address_work(lanes, size, fields, stride, alignment, contiguous)
    if alignment < 16:
        reasons.append('base phase unknown: maximum over allowed alignments')
    spill = any(m.get('spill_slot', False) for m in op['memory'])
    kind = 'reload' if spill and op['load'] else 'spill' if spill else 'memory'
    return dict(category=kind, bytes=lanes * fields * size,
                bytes_kind='exact' if exact else 'upper-bound', lanes=lanes,
                fields=fields, element_bytes=size, stride=stride, alignment=alignment,
                distinct_addresses=distinct,
                distinct_kind='exact' if exact and stride is not None else 'upper-bound',
                requests=requests, requests_kind='upper-bound',
                scope='per-body-execution', policy='conservative-demand; not cache misses or cycles',
                reasons=reasons)


def category(op, memory):
    if memory:
        return memory['category']
    name = op['base_opcode']
    operands = op['operands']
    scalar_copy = (name == 'ADDI' and len(operands) >= 3 and
                   operands[2].get('kind') == 'immediate' and operands[2]['value'] == 0)
    scalar_copy |= (name.startswith('FSGNJ_') and len(operands) >= 3 and
                    operands[1].get('kind') == operands[2].get('kind') == 'register' and
                    operands[1]['register'] == operands[2]['register'])
    if scalar_copy or name == 'COPY' or re.fullmatch(r'VMV[1248]R_V', name) or name.startswith(('VMV_', 'VFMV_', 'FMV_')):
        return 'copy'
    if name.startswith(('VFMACC', 'VFMADD', 'VFMSAC', 'VFMSUB', 'VFNMAC', 'VFNMAD',
                        'VFNMSA', 'VFNMSU', 'VFWMACC', 'VFWMSAC', 'VFWNMAC', 'VFWNMSA',
                        'FMADD', 'FMSUB', 'FNMADD', 'FNMSUB')):
        return 'fma'
    return 'vector' if op['vector'] else 'scalar'
