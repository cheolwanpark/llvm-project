"""Fixed decode work, never cycle predictions. Python alone owns these rules."""
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import re

from model_errors import ToolError

REVISION = 'e7bab53e66dfb3c4a1d11cf9519b0396f8576cae'
RULE_VERSION = 'kunminghu-v2-minimal-decode-v1'
RULE_FILE = Path(__file__).parent / 'rules/opcodes.json'
MAP = json.loads(RULE_FILE.read_text())
RULE_DIGEST = hashlib.sha256(RULE_FILE.read_bytes() + Path(__file__).read_bytes()).hexdigest()
ROOT = f'https://github.com/OpenXiangShan/XiangShan/blob/{REVISION}/src/main/scala/'
SPLITS = ROOT + 'xiangshan/backend/decode/UopInfoGen.scala'
DECODE = ROOT + 'xiangshan/backend/decode/DecodeUnitComp.scala'
PORTS = {
    'vialuF': ('VFEX0', 'VFEX2'), 'vimac': ('VFEX0',), 'vfma': ('VFEX0', 'VFEX2'),
    'vfalu': ('VFEX1', 'VFEX3'), 'vfcvt': ('VFEX1',), 'vipu': ('VFEX1',),
    'vppu': ('VFEX0',), 'vfdiv': ('VFEX4',), 'vidiv': ('VFEX4',),
    'i2v': ('BJU2',), 'f2v': ('FEX0',), 'memory': ('VLSU0', 'VLSU1'),
    # Scalar ALU assignment is deliberately unknown at this stage.
    'scalar': (), 'scalar_memory': (),
}
CLASSES = {'vialuF': 'integer', 'vimac': 'multiply', 'vfma': 'fp_multiply',
           'vfalu': 'fp_alu', 'vfcvt': 'convert', 'vipu': 'mask', 'vppu': 'permute',
           'vfdiv': 'divide', 'vidiv': 'divide', 'i2v': 'move', 'f2v': 'move',
           'memory': 'memory', 'scalar_memory': 'memory', 'scalar': 'scalar'}
BASIC_CLASSES = tuple(sorted(set(CLASSES.values())))


def split_work(split, lmul, sew, *, fields=1, eew=None, index_emul=None, whole=None):
    """Return (decode uops, extra scalar moves). RTL encodings floor LMUL at 1.

    No execution chunk or runtime VL estimate is inferred from this count.
    The distinction between decode work and execution cycles is intentional.
    """
    lmul = Fraction(lmul)
    if lmul not in (Fraction(1, 8), Fraction(1, 4), Fraction(1, 2), 1, 2, 4, 8):
        raise ToolError(f'unsupported LMUL {lmul}')
    if sew in (8, 16, 32, 64) and lmul * 128 < sew:
        raise ToolError('LMUL/SEW has no element at VLEN 128')
    l = max(1, int(lmul))
    if split in ('dummy', 'SCA_SIM'): return 1, 0
    if split in ('VEC_VVV', 'VEC_VVM', 'VEC_EXT2', 'VEC_EXT4', 'VEC_EXT8', 'VEC_VRED', 'VEC_M0X'):
        return l, 0
    if split in ('VEC_VXV', 'VEC_VFV', 'VEC_VXM', 'VEC_VFM', 'VEC_SLIDE1UP', 'VEC_FSLIDE1UP'):
        return l + 1, 1
    if split == 'VEC_0XV': return 2, 1
    if split == 'VEC_VWW':
        if lmul > 4: raise ToolError('wide operand EMUL exceeds 8')
        return 2 * l, 0
    if split in ('VEC_VVW', 'VEC_WVW', 'VEC_WVV',
                 'VEC_VXW', 'VEC_WXW', 'VEC_WXV', 'VEC_VFW', 'VEC_WFW'):
        if lmul > 4: raise ToolError('wide operand EMUL exceeds 8')
        vector = 2 * l if lmul >= 1 else 1
        move = int(split in ('VEC_VXW', 'VEC_WXW', 'VEC_WXV', 'VEC_VFW', 'VEC_WFW'))
        return vector + move, move
    if split in ('VEC_SLIDE1DOWN', 'VEC_FSLIDE1DOWN'): return 2 * l, 1
    if split in ('VEC_SLIDEUP', 'VEC_SLIDEDOWN'):
        return {1: 1, 2: 3, 4: 10, 8: 36}[l] + 1, 1
    if split in ('VEC_RGATHER', 'VEC_RGATHER_VX', 'VEC_RGATHEREI16'):
        work = l * l
        if split == 'VEC_RGATHEREI16' and sew == 8 and lmul != 8: work *= 2
        move = int(split == 'VEC_RGATHER_VX')
        return work + move, move
    if split == 'VEC_COMPRESS': return {1: 1, 2: 4, 4: 13, 8: 43}[l], 0
    if split == 'VEC_MVV': return 2 * l - 1, 0
    if split == 'VEC_MVNR':
        if whole not in (1, 2, 4, 8): raise ToolError('unknown whole-register move count')
        return whole, 0
    if split == 'VEC_VFRED':
        if sew not in (16, 32, 64): raise ToolError('invalid FP reduction SEW')
        # foldTime is a three-bit subtraction in the pinned Chisel source.
        fold = (int(min(0, lmul.numerator.bit_length() - lmul.denominator.bit_length()))
                + {16: 3, 32: 2, 64: 1}[sew]) % 8
        return max(1, l + fold), 0
    if split == 'VEC_VFREDOSUM':
        if sew not in (16, 32, 64): raise ToolError('invalid ordered reduction SEW')
        return max(1, int(Fraction(128, sew) * lmul)), 0
    if split in ('VEC_US_LDST', 'VEC_S_LDST', 'VEC_I_LDST'):
        if not 1 <= fields <= 8 or sew not in (8, 16, 32, 64) or eew not in (8, 16, 32, 64):
            raise ToolError('missing memory SEW/EEW/field count')
        emul = lmul * Fraction(eew, sew)
        if not Fraction(1, 8) <= emul <= 8: raise ToolError('memory EMUL out of range')
        if (lmul if split == 'VEC_I_LDST' else emul) * fields > 8:
            raise ToolError('segment register group exceeds 8')
        vector = max(1, int(emul)) * fields
        if split == 'VEC_I_LDST':
            if index_emul is None: raise ToolError('unknown indexed EMUL')
            vector = max(l * fields, max(1, int(index_emul)))
        move = 2 if split == 'VEC_S_LDST' else 1
        return vector + move, move
    raise ToolError(f'unimplemented RTL split {split}')


def work_for_instruction(op):
    base = op['base_opcode']
    if op['configuration'] or op['meta']: raise ToolError('non-body operation')
    if not op['vector']:
        if op['pseudo'] and base not in ('COPY', 'PseudoBR', 'PseudoRET'):
            raise ToolError(f'unverified scalar pseudo expansion: {base}')
        # Spill/reloads follow exactly the ordinary scalar memory path.
        fu = 'scalar_memory' if op['load'] or op['store'] else 'scalar'
        return dict(rule='scalar-memory' if fu == 'scalar_memory' else 'scalar-instruction',
                    source=ROOT + 'xiangshan/Parameters.scala#L396', split='SCA_SIM',
                    decode_uops=1, components=[component(fu, 1)], geometry={})
    lmul = Fraction(op['lmul8'], 8) if op['lmul8'] else None
    sew = op['sew']
    whole = re.fullmatch(r'(?:VL([1248])RE(8|16|32|64)|VS([1248])R)_V', base)
    copy = re.fullmatch(r'VMV([1248])R_V', base)
    if base == 'COPY' or whole or copy:
        groups = [o['group8'] // 8 for o in op['operands'] if o['kind'] == 'register' and o['group8']]
        count = int((whole[1] or whole[3]) if whole else copy[1]) if whole or copy else (groups[0] if groups else 0)
        if count not in (1, 2, 4, 8) or not groups or any(g != count for g in groups):
            raise ToolError('whole-register transfer grouping unknown')
        if whole:
            total, moves, fu, split = count + 1, 1, 'memory', 'VEC_US_LDST:whole'
        else:
            total, moves, fu, split = count, 0, 'vppu', 'VEC_MVNR'
        geometry = dict(whole_registers=count)
    elif op['load'] or op['store']:
        # LLVM data EMUL comes from the pseudo table; EEW comes from the ISA
        # opcode. Indexed geometry is not guessed from a physical register.
        indexed = re.fullmatch(r'V[LS][UO]XEI(8|16|32|64)_V', base)
        seg = re.fullmatch(r'V[LS](S?)SEG([2-8])E(8|16|32|64)_V', base)
        unit = re.fullmatch(r'V[LS](E|SE)(8|16|32|64)_V', base)
        if not (indexed or seg or unit) or lmul is None:
            raise ToolError(f'unverified memory form/geometry: {base}')
        if indexed:
            index8 = op.get('index_emul8')
            index_eew = op.get('index_eew')
            if not index8 or index_eew != int(indexed[1]) or sew not in (8, 16, 32, 64):
                raise ToolError('missing verified index EMUL/EEW')
            index_emul = Fraction(index8, 8)
            if index_emul != lmul * Fraction(index_eew, sew):
                raise ToolError('index EMUL disagrees with data LMUL and EEW/SEW')
            split = 'VEC_I_LDST'
            total, moves = split_work(split, lmul, sew, eew=sew, index_emul=index_emul)
            geometry = dict(lmul=str(lmul), data_emul=str(lmul), sew=sew, eew=sew,
                            index_emul=str(index_emul), index_eew=index_eew, fields=1, vl=op['vl'])
        else:
            eew = int(seg[3] if seg else unit[2]); fields = int(seg[2]) if seg else 1
            # For LLVM non-indexed pseudos LMUL is data EMUL; actual VTYPE SEW
            # may differ. Decode work uses that data EMUL, not an invented VTYPE.
            strided = bool(seg[1]) if seg else unit[1] == 'SE'
            split = 'VEC_S_LDST' if strided else 'VEC_US_LDST'
            total, moves = split_work(split, lmul, eew, fields=fields, eew=eew)
            geometry = dict(lmul=None, sew=None, data_emul=str(lmul), eew=eew, fields=fields, vl=op['vl'])
        fu = 'memory'
    else:
        row = MAP['opcodes'].get(base)
        if row is None: raise ToolError(f'opcode missing pinned RTL decode mapping: {base}')
        split, fu = row['split'], row['fu']
        if fu not in PORTS: raise ToolError(f'unverified execution resource {fu}')
        if lmul is None or sew is None: raise ToolError(f'missing LMUL/SEW: {base}')
        total, moves = split_work(split, lmul, sew)
        geometry = dict(lmul=str(lmul), sew=sew, vl=op['vl'], masked=op['masked'])
        if split in ('VEC_VVW', 'VEC_WVW', 'VEC_VXW', 'VEC_WXW', 'VEC_VFW', 'VEC_WFW', 'VEC_VWW', 'VEC_WVV', 'VEC_WXV'):
            geometry['wide_emul'] = str(2 * lmul)
    parts = [component(fu, total - moves)]
    if moves:
        # DecodeUnitComp assigns the extra move to F2V for FP scalar forms,
        # I2V for vector memory and integer/immediate forms.
        move_fu = 'f2v' if split in ('VEC_VFV', 'VEC_VFM', 'VEC_VFW', 'VEC_WFW', 'VEC_FSLIDE1UP', 'VEC_FSLIDE1DOWN') or base == 'VFMV_S_F' else 'i2v'
        parts.append(component(move_fu, moves))
    return dict(rule=RULE_VERSION + ':' + split, source=SPLITS, split=split,
                opcode_source=ROOT + MAP['source'] + '#L' + str(MAP['opcodes'].get(base, {}).get('line', 1)),
                decode_uops=total, components=parts, geometry=geometry,
                runtime_policy='static decode work; no execution-cycle or active-VL inference',
                move_source=DECODE if moves else None)


def component(fu, amount):
    return dict(resource=fu, ports=list(PORTS[fu]), cost_class=CLASSES[fu], work=amount)
