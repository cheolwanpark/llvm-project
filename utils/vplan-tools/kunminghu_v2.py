"""Pinned Kunminghu v2 MinimalConfig datasheet. No fitted model weights.

All target-specific tables, expansion expressions and MIR geometry conventions
live here. UNKNOWN is an explicit approximation, not a hidden generic ALU.
"""
from fractions import Fraction as Q
from dataclasses import asdict
import hashlib
from pathlib import Path
import re

from hardware_model import Demand, Evidence, InstructionRule, Machine, Port, ResolvedInstruction, Timing, UopClass, expr as E
from model_errors import ToolError

REVISION = 'e7bab53e66dfb3c4a1d11cf9519b0396f8576cae'
ROOT = f'https://github.com/OpenXiangShan/XiangShan/blob/{REVISION}/src/main/scala/xiangshan/'
PARAMETERS = ROOT + 'Parameters.scala'
SPLITS = ROOT + 'backend/decode/UopInfoGen.scala'
COMPONENTS = ROOT + 'backend/decode/DecodeUnitComp.scala'
SCALAR_DECODE = ROOT + 'backend/decode/DecodeUnit.scala'
VECTOR_DECODE = ROOT + 'backend/decode/VecDecoder.scala'
DISPATCH = ROOT + 'backend/issue/Scheduler.scala#L372'

# Physical execution units, not independent functional units or writeback ports.
# One input per EXU is a peak admission limit, NOT a measured sustainable rate.
# Keep all capacities explicitly assumed until a service-rate model is available.
PORT_NAMES = ('ALU0', 'ALU1', 'ALU2', 'ALU3', 'BJU0', 'BJU1', 'BJU2', 'BJU3',
              'FEX0', 'FEX1', 'FEX2', 'FEX3', 'FEX4',
              'VFEX0', 'VFEX1', 'VFEX2', 'VFEX3', 'VFEX4',
              'STA0', 'STA1', 'LDU0', 'LDU1', 'LDU2', 'VLSU0', 'VLSU1', 'STD0', 'STD1', 'UNKNOWN')
PORTS = tuple(Port(name, Q(1), Evidence(PARAMETERS + '#L396',
    'Default capacity 1 uop/cycle; FU-dependent initiation intervals, backpressure and shared writeback are unmodeled.'
    if name != 'UNKNOWN' else 'Virtual fallback port, capacity 1 uop/cycle.', True)) for name in PORT_NAMES)

# (possible EXUs, Parameters.scala line); different classes can compete on one EXU.
CLASS_PORTS = {
    'alu': (('ALU0', 'ALU1', 'ALU2', 'ALU3'), 399),
    'mul': (('ALU0', 'ALU1'), 399), 'bku': (('ALU0', 'ALU1'), 399),
    'brh': (('BJU0', 'BJU1', 'BJU2'), 400), 'jmp': (('BJU0', 'BJU1', 'BJU2'), 400),
    'div': (('BJU3',), 413), 'csr': (('BJU3',), 413), 'fence': (('BJU3',), 413),
    'i2f': (('BJU2',), 409), 'i2v': (('BJU2',), 409), 'f2v': (('FEX0',), 427),
    'falu': (('FEX0', 'FEX2', 'FEX4'), 427), 'fmac': (('FEX0', 'FEX2', 'FEX4'), 427),
    'fcvt': (('FEX0',), 427), 'fDivSqrt': (('FEX1', 'FEX3'), 428),
    'vialuF': (('VFEX0', 'VFEX2'), 449), 'vimac': (('VFEX0',), 449),
    'vfma': (('VFEX0', 'VFEX2'), 449), 'vfalu': (('VFEX1', 'VFEX3'), 450),
    'vfcvt': (('VFEX1',), 450), 'vipu': (('VFEX1',), 450), 'vppu': (('VFEX0',), 449),
    'vfdiv': (('VFEX4',), 457), 'vidiv': (('VFEX4',), 457),
    'ldu': (('LDU0', 'LDU1', 'LDU2'), 479), 'sta': (('STA0', 'STA1'), 473),
    'std': (('STD0', 'STD1'), 494),
    'vldu': (('VLSU0', 'VLSU1'), 488), 'vstu': (('VLSU0', 'VLSU1'), 488),
    'vsegldu': (('VLSU0',), 488), 'vsegstu': (('VLSU0',), 488),
}
CLASSES = tuple(UopClass(name, ports, Evidence(PARAMETERS + '#L' + str(line)))
                for name, (ports, line) in CLASS_PORTS.items()) + (
    UopClass('unknown', ('UNKNOWN',), Evidence('', 'Unverified class/port uses UNKNOWN.', True)),)
MACHINE = Machine('xiangshan-kunminghu', REVISION, 128, 64, PORTS, CLASSES)
ROB_ENTRIES = 48
ROB_EVIDENCE = Evidence(
    f'https://github.com/OpenXiangShan/XiangShan/blob/{REVISION}/src/main/scala/top/Configs.scala#L91',
    'MinimalConfig RobSize. Rob.scala allocates on firstUop; split uops share an entry. '
    'One non-meta body MIR instruction per ROB entry is the model approximation.')

# LLVM RVV scalable type sizes are expressed at vscale=1 (64 bits).
# This is a target convention, not a generic dependency-analysis constant.
LLVM_VSCALE = MACHINE.vlen // 64
MAX_STACK_ACCESS_BYTES = 8 * MACHINE.vlen // 8

FU_CONFIG = ROOT + 'backend/fu/FuConfig.scala'
EXU_PARAMS = ROOT + 'backend/exu/ExeUnitParams.scala'
YUNSUAN_REVISION = '955921186e34bb8915806582a238181a6dc3435c'
YUNSUAN_ROOT = f'https://github.com/OpenXiangShan/YunSuan/blob/{YUNSUAN_REVISION}/src/main/scala/yunsuan/'

# (FuConfig record, CertainLatency literal). Omitted latency in FuConfig is 0.
# Preserve the literal separately from the result-ready estimate. Vector OG2
# adds one cycle in ExeUnitParams.fuLatencyMap. Combinational scalar FUs use a
# one-cycle consumer boundary rather than zero cost. No cycle measurements fit
# these values; port capacities remain the existing demand-only assumptions.
FIXED_TIMING_ROWS = {
    'alu': ('AluCfg', 0), 'mul': ('MulCfg', 2), 'bku': ('BkuCfg', 2),
    'brh': ('BrhCfg', 0), 'jmp': ('JmpCfg', 0),
    'i2f': ('I2fCfg', 2), 'i2v': ('I2vCfg', 0), 'f2v': ('F2vCfg', 0),
    'falu': ('FaluCfg', 1), 'fmac': ('FmacCfg', 3), 'fcvt': ('FcvtCfg', 2),
    'vialuF': ('VialuCfg', 1), 'vimac': ('VimacCfg', 2),
    'vfma': ('VfmaCfg', 3), 'vfalu': ('VfaluCfg', 1),
    'vfcvt': ('VfcvtCfg', 2), 'vipu': ('VipuCfg', 2), 'vppu': ('VppuCfg', 2),
    'std': ('StdCfg', 0),
}
VECTOR_TIMING_CLASSES = frozenset(('vialuF', 'vimac', 'vfma', 'vfalu', 'vfcvt', 'vipu', 'vppu'))
TIMINGS = {name: Timing(max(1, literal + int(name in VECTOR_TIMING_CLASSES)), 1, True,
    Evidence(FU_CONFIG, 'CertainLatency + vector OG2; scalar minimum one cycle. '
             'Nominal II=1 assumes no backpressure. ' + EXU_PARAMS, True),
    rtl_latency=literal, configuration=config)
    for name, (config, literal) in FIXED_TIMING_ROWS.items()}

# Memory timings are conditional fast paths, NOT finite cache-miss bounds.
# LduCfg has UncertainLatency(3); LoadUnit shares the scalar/vector load pipeline.
# StoreUnit exposes S0/S1. Vector entries add one OG2 cycle. Merge, queue and
# store-forwarding stalls are not predicted. Nominal memory II=1 is an assumption
# even though FuConfig labels these interfaces piped=false/uncertain.
for _name, _config, _latency, _path in (
    ('ldu', 'LduCfg', 3, 'LoadUnit'), ('sta', 'StaCfg', 2, 'StoreUnit'),
    ('vldu', 'VlduCfg', 4, 'LoadUnit'), ('vstu', 'VstuCfg', 3, 'StoreUnit'),
    ('vsegldu', 'VseglduCfg', 4, 'LoadUnit'), ('vsegstu', 'VsegstuCfg', 3, 'StoreUnit')):
    TIMINGS[_name] = Timing(_latency, 1, None,
        Evidence(ROOT + 'mem/pipeline/' + _path + '.scala',
                 'L1-hit/no-replay pipeline proxy; vector OG2 included; '
                 'nominal II=1; segment sequencing and forwarding stalls unmodeled.', True),
        configuration=_config)

# Input-dependent iterative units: nominal conservative no-stall envelopes.
# Integer division: inclusive radix-16 countdown plus pre/post/wrapper states.
# These are estimates from the FSM, not CertainLatency literals or global bounds.
INTEGER_DIV_LATENCIES = {32: 14, 64: 22}
VECTOR_DIV_LATENCIES = {8: 10, 16: 12, 32: 16, 64: 24}
# FP div countdowns 1/3/8 inclusive, up to 3 pre and 1 extra post cycle.
# FP sqrt countdowns 2/5/12 inclusive, up to 2 initialization cycles.
FP_DIV_LATENCIES = {16: 6, 32: 8, 64: 13}
FP_SQRT_LATENCIES = {16: 5, 32: 8, 64: 15}
for _name, _config in (('div', 'DivCfg'), ('vidiv', 'VidivCfg'),
                       ('fDivSqrt', 'FdivCfg'), ('vfdiv', 'VfdivCfg')):
    # Per-op precision/opcode refinements replace this widest-type descriptor.
    TIMINGS[_name] = Timing(24, 25, False,
        Evidence(FU_CONFIG, 'UncertainLatency: replaced by opcode/precision FSM estimate.', True),
        configuration=_config)
for _name, _config in (('csr', 'CsrCfg'), ('fence', 'FenceCfg'), ('unknown', '')):
    TIMINGS[_name] = Timing(1, 1, None,
        Evidence(FU_CONFIG if _config else '',
                 'No finite static timing established; explicit one-cycle fallback, not an RTL latency.', True),
        configuration=_config)
assert set(TIMINGS) == {c.name for c in CLASSES}

# These split families contain dependent temporary/reduction work in
# DecodeUnitComp. Serializing every primary uop is a conservative approximation
# to that internal graph, not a claim that the whole FU is non-pipelined.
SERIAL_TIMING_SPLITS = frozenset(('VEC_SLIDEUP', 'VEC_SLIDEDOWN', 'VEC_SLIDE1DOWN',
    'VEC_FSLIDE1DOWN', 'VEC_RGATHER', 'VEC_RGATHER_VX', 'VEC_RGATHEREI16',
    'VEC_COMPRESS', 'VEC_VRED', 'VEC_VFRED', 'VEC_VFREDOSUM'))


def timing_for_instruction(op, work):
    """Resolve every supported opcode to (L, II) components and MIR latency.

All target-specific precision, expansion and component-ordering decisions live
here. The graph scorer only consumes the resulting instruction latency.
"""
    base = op['base_opcode']
    split = work['rule'].partition(':')[2]
    serial = split in SERIAL_TIMING_SPLITS
    rows = []
    for component in work['components']:
        name, count = component['uop_class'], component['count']
        timing = TIMINGS[name]
        if name in ('div', 'vidiv'):
            width = op['sew'] if name == 'vidiv' else 32 if base.endswith('W') else 64
            latency = (VECTOR_DIV_LATENCIES if name == 'vidiv' else INTEGER_DIV_LATENCIES)[width]
            source = (YUNSUAN_ROOT + 'vector/VectorIdiv/VectorIdiv.scala' if name == 'vidiv'
                      else ROOT + 'backend/fu/SRT16Divider.scala')
            timing = Timing(latency, latency + 1, False, Evidence(source,
                'Conservative width-based FSM estimate; early exits ignored; one restart cycle; '
                'vector wrapper/OG2 included; no external backpressure.', True), configuration=timing.configuration)
        elif name in ('fDivSqrt', 'vfdiv'):
            width = op['sew'] if name == 'vfdiv' else {'H': 16, 'S': 32, 'D': 64}[base.rsplit('_', 1)[-1]]
            sqrt = 'SQRT' in base
            latency = (FP_SQRT_LATENCIES if sqrt else FP_DIV_LATENCIES)[width] + int(name == 'vfdiv')
            source = ('vector/vfsqrt/fpsqrt_vector_r16.scala' if name == 'vfdiv' else 'fpu/fqrt/fpsqrt_r16.scala') if sqrt else (
                'vector/VectorFloatDivider.scala' if name == 'vfdiv' else 'fpu/FloatDivider.scala')
            timing = Timing(latency, latency + 1, False, Evidence(YUNSUAN_ROOT + source,
                'Inclusive precision-dependent countdown plus initialization/post stages; '
                'one restart cycle; no external backpressure; vector OG2 included.', True), configuration=timing.configuration)
        is_primary = name not in ('i2v', 'f2v')
        span = timing.span(count, serial=serial and is_primary)
        rows.append(dict(uop_class=name, count=count, **asdict(timing), completion_cycles=span,
                         expansion='serial-upper-estimate' if serial and is_primary else 'pipeline-span'))
    transfers = sum(r['completion_cycles'] for r in rows if r['uop_class'] in ('i2v', 'f2v'))
    primary = max((r['completion_cycles'] for r in rows if r['uop_class'] not in ('i2v', 'f2v')), default=0)
    # Scalar store address and data issue tasks run in parallel; vector scalar
    # transfers precede the primary work (a conservative whole-op barrier).
    return dict(latency=transfers + primary, components=rows,
                combination='transfer-prefix + max(primary-components)',
                assumptions=['Whole-instruction readiness; no lane streaming or multi-EXU uop striping.',
                    'No bypass-specific operand latencies; not a measured CPU cycle prediction.'] +
                    (['Dependent split uops conservatively serialized; exact internal DAG is not collected.'] if serial else []),
                fallback=any(r['uop_class'] in ('unknown', 'csr', 'fence') for r in rows))

L = E('max', 1, 'lmul')
WIDE = E('if', E('ge', 'lmul', 1), E('mul', 2, 'lmul'), 1)
GATHER = E('mul', L, L)
FOLD = E('mod', E('add', E('min', 'log_lmul', 0), E('lookup', 'sew', ((16, 3), (32, 2), (64, 1)))), 8)

# Split -> (primary count, additional I2V/F2V count). These are decode work.
SPLIT_COUNTS = {
    **dict.fromkeys(('dummy', 'SCA_SIM'), (1, 0)),
    **dict.fromkeys(('VEC_VVV', 'VEC_VVM', 'VEC_EXT2', 'VEC_EXT4', 'VEC_EXT8', 'VEC_VRED', 'VEC_M0X'), (L, 0)),
    **dict.fromkeys(('VEC_VXV', 'VEC_VFV', 'VEC_VXM', 'VEC_VFM', 'VEC_SLIDE1UP', 'VEC_FSLIDE1UP'), (L, 1)),
    'VEC_0XV': (1, 1), 'VEC_VWW': (E('mul', 2, L), 0),
    **dict.fromkeys(('VEC_VVW', 'VEC_WVW', 'VEC_WVV'), (WIDE, 0)),
    **dict.fromkeys(('VEC_VXW', 'VEC_WXW', 'VEC_WXV', 'VEC_VFW', 'VEC_WFW'), (WIDE, 1)),
    **dict.fromkeys(('VEC_SLIDE1DOWN', 'VEC_FSLIDE1DOWN'), (E('sub', E('mul', 2, L), 1), 1)),
    **dict.fromkeys(('VEC_SLIDEUP', 'VEC_SLIDEDOWN'), (E('lookup', L, ((1, 1), (2, 3), (4, 10), (8, 36))), 1)),
    'VEC_RGATHER': (GATHER, 0), 'VEC_RGATHER_VX': (GATHER, 1),
    'VEC_RGATHEREI16': (E('if', E('and', E('eq', 'sew', 8), E('ne', 'lmul', 8)), E('mul', GATHER, 2), GATHER), 0),
    'VEC_COMPRESS': (E('lookup', L, ((1, 1), (2, 4), (4, 13), (8, 43))), 0),
    'VEC_MVV': (E('sub', E('mul', 2, L), 1), 0),
    'VEC_MVNR': (E('mul', 1, 'whole'), 0),
    'VEC_VFRED': (E('max', 1, E('add', L, FOLD)), 0),
    'VEC_VFREDOSUM': (E('max', 1, E('mul', E('div', 128, 'sew'), 'lmul')), 0),
    'VEC_US_LDST': (E('mul', E('max', 1, 'data_emul'), 'fields'), 1),
    'VEC_S_LDST': (E('mul', E('max', 1, 'data_emul'), 'fields'), 2),
    'VEC_I_LDST': (E('max', E('mul', L, 'fields'), E('max', 1, 'index_emul')), 1),
    'WHOLE_MEMORY': (E('mul', 1, 'whole'), 1),
}
FP_MOVES = ('VEC_VFV', 'VEC_VFM', 'VEC_VFW', 'VEC_WFW', 'VEC_FSLIDE1UP', 'VEC_FSLIDE1DOWN')
WIDE_SPLITS = ('VEC_VWW', 'VEC_VVW', 'VEC_WVW', 'VEC_WVV', 'VEC_VXW', 'VEC_WXW', 'VEC_WXV', 'VEC_VFW', 'VEC_WFW')
LMULS = tuple(map(Q, ('1/8', '1/4', '1/2', '1', '2', '4', '8')))


def fallback(base, note):
    return ResolvedInstruction(InstructionRule(base + ':unknown', (Demand('unknown', 1),),
                               Evidence('', note + '; default one uop on UNKNOWN.', True)))


def resolve(op):
    """Interpret LLVM's opcode/geometry facts using this datasheet's ISA conventions."""
    base = op['base_opcode']
    if op['meta'] or op['configuration']: raise ToolError('not an executable body instruction')
    if not op['vector']:
        # These pseudos materialize one jump; arbitrary pseudo expansion is unknown.
        if base in ('PseudoBR', 'PseudoRET'):
            return ResolvedInstruction(InstructionRule(base, (Demand('jmp', 1),),
                Evidence(SCALAR_DECODE, 'One-instruction branch/return lowering.')))
        if op['pseudo'] or base == 'COPY': return fallback(base, 'Unverified scalar pseudo/copy expansion')
        row = SCALAR_OPCODES.get(base)
        if row is None: return fallback(base, 'No reviewed scalar opcode mapping')
        fu, line = row
        source = (VECTOR_DECODE if base in SCALAR_VECTOR_DECODER else SCALAR_DECODE) + '#L' + str(line)
        if fu == 'stu':
            return ResolvedInstruction(InstructionRule(base, (Demand('sta', 1), Demand('std', 1)),
                Evidence(DISPATCH, 'One decoded store is copied to address and data issue queues.'), decode_count=1))
        if fu not in CLASS_PORTS: return fallback(base, f'Unverified scalar FU {fu}')
        return ResolvedInstruction(InstructionRule(base, (Demand(fu, 1),), Evidence(source)))

    whole = re.fullmatch(r'(?:VL([1248])RE(8|16|32|64)|VS([1248])R)_V', base)
    copy = re.fullmatch(r'VMV([1248])R_V', base)
    assumptions = ()
    if base == 'COPY' or whole or copy:
        groups = [o['group8'] // 8 for o in op['operands'] if o['kind'] == 'register' and o['group8']]
        count = int((whole[1] or whole[3]) if whole else copy[1]) if whole or copy else (groups[0] if groups else 0)
        if count not in (1, 2, 4, 8) or not groups or any(g != count for g in groups):
            raise ToolError('whole-register grouping unknown/invalid')
        split, fu = ('WHOLE_MEMORY', 'vldu' if op['load'] else 'vstu') if whole else ('VEC_MVNR', 'vppu')
        geometry = dict(whole=count)
        if base == 'COPY': assumptions = ('Vector COPY modeled as whole-register move; late copy elimination is not modeled.',)
    else:
        if op['lmul8'] is None or not op['lmul8']:
            if base not in VECTOR_OPCODES and not (op['load'] or op['store']): return fallback(base, 'Unknown vector opcode and expansion')
            raise ToolError('missing vector LMUL/EMUL')
        lmul, sew = Q(op['lmul8'], 8), op['sew']
        if lmul not in LMULS: raise ToolError('illegal LMUL/EMUL')
        geometry = dict(lmul=lmul, sew=sew, log_lmul=lmul.numerator.bit_length() - lmul.denominator.bit_length())
        if op['load'] or op['store']:
            indexed = re.fullmatch(r'V[LS][UO]XEI(8|16|32|64)_V', base)
            seg = re.fullmatch(r'V[LS](S?)SEG([2-8])E(8|16|32|64)_V', base)
            unit = re.fullmatch(r'V[LS](E|SE)(8|16|32|64)_V', base)
            if not (indexed or seg or unit): return fallback(base, 'Unverified vector memory form')
            fields = int(seg[2]) if seg else 1
            if indexed:
                if sew not in (8, 16, 32, 64) or not op.get('index_emul8') or op.get('index_eew') != int(indexed[1]):
                    raise ToolError('missing/invalid indexed geometry')
                index_emul = Q(op['index_emul8'], 8)
                if index_emul not in LMULS or index_emul != lmul * Q(op['index_eew'], sew):
                    raise ToolError('indexed EMUL ratio disagrees')
                split, eew = 'VEC_I_LDST', sew
                geometry['index_emul'] = index_emul
            else:
                eew = int(seg[3] if seg else unit[2])
                split = 'VEC_S_LDST' if (bool(seg[1]) if seg else unit[1] == 'SE') else 'VEC_US_LDST'
                # LLVM non-indexed pseudo LMUL is DATA EMUL, not VTYPE LMUL.
                geometry.update(lmul=lmul, sew=eew)
            if lmul * 128 < eew or lmul * fields > 8: raise ToolError('illegal memory register geometry')
            geometry.update(data_emul=lmul, fields=fields, eew=eew)
            fu = ('vseg' if fields > 1 else 'v') + ('ldu' if op['load'] else 'stu')
        else:
            if base not in VECTOR_OPCODES: return fallback(base, 'No reviewed vector opcode mapping')
            fu, split, _ = VECTOR_OPCODES[base]
            # LLVM represents predicate elements with SEW=1; this is not a
            # VTYPE e1. Mask-only dummy/M0X decode counts don't use data SEW.
            mask_geometry = sew == 1 and split in ('dummy', 'VEC_M0X')
            if (not mask_geometry and sew not in (8, 16, 32, 64)) or lmul * 128 < sew:
                raise ToolError('illegal LMUL/SEW')
            if split in WIDE_SPLITS and lmul > 4: raise ToolError('wide operand EMUL exceeds 8')
            if split in ('VEC_VFRED', 'VEC_VFREDOSUM') and sew not in (16, 32, 64): raise ToolError('invalid FP reduction SEW')
    if split not in SPLIT_COUNTS: return fallback(base, 'Unverified split ' + split)
    primary, moves = SPLIT_COUNTS[split]
    parts = [Demand(fu if fu in CLASS_PORTS else 'unknown', primary)]
    if moves: parts.append(Demand('f2v' if split in FP_MOVES or base == 'VFMV_S_F' else 'i2v', moves))
    return ResolvedInstruction(InstructionRule(base + ':' + split, tuple(parts), Evidence(SPLITS)), geometry, assumptions)


def work_for_instruction(op): return MACHINE.expand(resolve(op))

# Literal reviewed records follow: opcode -> FU, split and source line.
VECTOR_OPCODES = {
    'VAADDU_VV': ('vialuF', 'VEC_VVV', 372),
    'VAADDU_VX': ('vialuF', 'VEC_VXV', 446),
    'VAADD_VV': ('vialuF', 'VEC_VVV', 371),
    'VAADD_VX': ('vialuF', 'VEC_VXV', 445),
    'VADC_VIM': ('vialuF', 'VEC_VXV', 329),
    'VADC_VVM': ('vialuF', 'VEC_VVV', 203),
    'VADC_VXM': ('vialuF', 'VEC_VXV', 270),
    'VADD_VI': ('vialuF', 'VEC_VXV', 318),
    'VADD_VV': ('vialuF', 'VEC_VVV', 189),
    'VADD_VX': ('vialuF', 'VEC_VXV', 253),
    'VANDN_VV': ('vialuF', 'VEC_VVV', 246),
    'VANDN_VX': ('vialuF', 'VEC_VXV', 311),
    'VAND_VI': ('vialuF', 'VEC_VXV', 320),
    'VAND_VV': ('vialuF', 'VEC_VVV', 196),
    'VAND_VX': ('vialuF', 'VEC_VXV', 261),
    'VASUBU_VV': ('vialuF', 'VEC_VVV', 374),
    'VASUBU_VX': ('vialuF', 'VEC_VXV', 448),
    'VASUB_VV': ('vialuF', 'VEC_VVV', 373),
    'VASUB_VX': ('vialuF', 'VEC_VXV', 447),
    'VBREV8_V': ('vialuF', 'VEC_VVV', 437),
    'VBREV_V': ('vialuF', 'VEC_VVV', 436),
    'VCLZ_V': ('vialuF', 'VEC_VVV', 439),
    'VCOMPRESS_VM': ('vppu', 'VEC_COMPRESS', 375),
    'VCPOP_M': ('vipu', 'VEC_M0X', 376),
    'VCPOP_V': ('vialuF', 'VEC_VVV', 441),
    'VCTZ_V': ('vialuF', 'VEC_VVV', 440),
    'VDIVU_VV': ('vidiv', 'VEC_VVV', 378),
    'VDIVU_VX': ('vidiv', 'VEC_VXV', 450),
    'VDIV_VV': ('vidiv', 'VEC_VVV', 377),
    'VDIV_VX': ('vidiv', 'VEC_VXV', 449),
    'VFADD_VF': ('vfalu', 'VEC_VFV', 675),
    'VFADD_VV': ('vfalu', 'VEC_VVV', 575),
    'VFCLASS_V': ('vfalu', 'VEC_VVV', 632),
    'VFCVT_F_XU_V': ('vfcvt', 'VEC_VVV', 639),
    'VFCVT_F_X_V': ('vfcvt', 'VEC_VVV', 640),
    'VFCVT_RTZ_XU_F_V': ('vfcvt', 'VEC_VVV', 637),
    'VFCVT_RTZ_X_F_V': ('vfcvt', 'VEC_VVV', 638),
    'VFCVT_XU_F_V': ('vfcvt', 'VEC_VVV', 635),
    'VFCVT_X_F_V': ('vfcvt', 'VEC_VVV', 636),
    'VFDIV_VF': ('vfdiv', 'VEC_VFV', 687),
    'VFDIV_VV': ('vfdiv', 'VEC_VVV', 586),
    'VFIRST_M': ('vipu', 'dummy', 379),
    'VFMACC_VF': ('vfma', 'VEC_VFV', 694),
    'VFMACC_VV': ('vfma', 'VEC_VVV', 592),
    'VFMADD_VF': ('vfma', 'VEC_VFV', 698),
    'VFMADD_VV': ('vfma', 'VEC_VVV', 596),
    'VFMAX_VF': ('vfalu', 'VEC_VFV', 711),
    'VFMAX_VV': ('vfalu', 'VEC_VVV', 618),
    'VFMERGE_VFM': ('vfalu', 'VEC_VFV', 727),
    'VFMIN_VF': ('vfalu', 'VEC_VFV', 710),
    'VFMIN_VV': ('vfalu', 'VEC_VVV', 617),
    'VFMSAC_VF': ('vfma', 'VEC_VFV', 696),
    'VFMSAC_VV': ('vfma', 'VEC_VVV', 594),
    'VFMSUB_VF': ('vfma', 'VEC_VFV', 700),
    'VFMSUB_VV': ('vfma', 'VEC_VVV', 598),
    'VFMUL_VF': ('vfma', 'VEC_VFV', 686),
    'VFMUL_VV': ('vfma', 'VEC_VVV', 585),
    'VFMV_F_S': ('vfalu', 'dummy', 733),
    'VFMV_S_F': ('vfalu', 'VEC_0XV', 734),
    'VFMV_V_F': ('vfalu', 'VEC_VFV', 730),
    'VFNCVT_F_F_W': ('vfcvt', 'VEC_WVV', 659),
    'VFNCVT_F_XU_W': ('vfcvt', 'VEC_WVV', 657),
    'VFNCVT_F_X_W': ('vfcvt', 'VEC_WVV', 658),
    'VFNCVT_ROD_F_F_W': ('vfcvt', 'VEC_WVV', 660),
    'VFNCVT_RTZ_XU_F_W': ('vfcvt', 'VEC_WVV', 655),
    'VFNCVT_RTZ_X_F_W': ('vfcvt', 'VEC_WVV', 656),
    'VFNCVT_XU_F_W': ('vfcvt', 'VEC_WVV', 653),
    'VFNCVT_X_F_W': ('vfcvt', 'VEC_WVV', 654),
    'VFNMACC_VF': ('vfma', 'VEC_VFV', 695),
    'VFNMACC_VV': ('vfma', 'VEC_VVV', 593),
    'VFNMADD_VF': ('vfma', 'VEC_VFV', 699),
    'VFNMADD_VV': ('vfma', 'VEC_VVV', 597),
    'VFNMSAC_VF': ('vfma', 'VEC_VFV', 697),
    'VFNMSAC_VV': ('vfma', 'VEC_VVV', 595),
    'VFNMSUB_VF': ('vfma', 'VEC_VFV', 701),
    'VFNMSUB_VV': ('vfma', 'VEC_VVV', 599),
    'VFRDIV_VF': ('vfdiv', 'VEC_VFV', 688),
    'VFREC7_V': ('vfcvt', 'VEC_VVV', 614),
    'VFREDMAX_VS': ('vfalu', 'VEC_VFRED', 664),
    'VFREDMIN_VS': ('vfalu', 'VEC_VFRED', 665),
    'VFREDOSUM_VS': ('vfalu', 'VEC_VFREDOSUM', 662),
    'VFREDUSUM_VS': ('vfalu', 'VEC_VFRED', 663),
    'VFRSQRT7_V': ('vfcvt', 'VEC_VVV', 611),
    'VFRSUB_VF': ('vfalu', 'VEC_VFV', 677),
    'VFSGNJN_VF': ('vfalu', 'VEC_VFV', 715),
    'VFSGNJN_VV': ('vfalu', 'VEC_VVV', 622),
    'VFSGNJX_VF': ('vfalu', 'VEC_VFV', 716),
    'VFSGNJX_VV': ('vfalu', 'VEC_VVV', 623),
    'VFSGNJ_VF': ('vfalu', 'VEC_VFV', 714),
    'VFSGNJ_VV': ('vfalu', 'VEC_VVV', 621),
    'VFSLIDE1DOWN_VF': ('vppu', 'VEC_FSLIDE1DOWN', 740),
    'VFSLIDE1UP_VF': ('vppu', 'VEC_FSLIDE1UP', 736),
    'VFSQRT_V': ('vfdiv', 'VEC_VVV', 608),
    'VFSUB_VF': ('vfalu', 'VEC_VFV', 676),
    'VFSUB_VV': ('vfalu', 'VEC_VVV', 576),
    'VFWADD_VF': ('vfalu', 'VEC_VFW', 680),
    'VFWADD_VV': ('vfalu', 'VEC_VVW', 579),
    'VFWADD_WF': ('vfalu', 'VEC_WFW', 682),
    'VFWADD_WV': ('vfalu', 'VEC_WVW', 581),
    'VFWCVT_F_F_V': ('vfcvt', 'VEC_VVW', 649),
    'VFWCVT_F_XU_V': ('vfcvt', 'VEC_VVW', 647),
    'VFWCVT_F_X_V': ('vfcvt', 'VEC_VVW', 648),
    'VFWCVT_RTZ_XU_F_V': ('vfcvt', 'VEC_VVW', 645),
    'VFWCVT_RTZ_X_F_V': ('vfcvt', 'VEC_VVW', 646),
    'VFWCVT_XU_F_V': ('vfcvt', 'VEC_VVW', 643),
    'VFWCVT_X_F_V': ('vfcvt', 'VEC_VVW', 644),
    'VFWMACC_VF': ('vfma', 'VEC_VFW', 704),
    'VFWMACC_VV': ('vfma', 'VEC_VVW', 602),
    'VFWMSAC_VF': ('vfma', 'VEC_VFW', 706),
    'VFWMSAC_VV': ('vfma', 'VEC_VVW', 604),
    'VFWMUL_VF': ('vfma', 'VEC_VFW', 691),
    'VFWMUL_VV': ('vfma', 'VEC_VVW', 589),
    'VFWNMACC_VF': ('vfma', 'VEC_VFW', 705),
    'VFWNMACC_VV': ('vfma', 'VEC_VVW', 603),
    'VFWNMSAC_VF': ('vfma', 'VEC_VFW', 707),
    'VFWNMSAC_VV': ('vfma', 'VEC_VVW', 605),
    'VFWREDOSUM_VS': ('vfalu', 'VEC_VFREDOSUM', 668),
    'VFWREDUSUM_VS': ('vfalu', 'VEC_VFREDOSUM', 669),
    'VFWSUB_VF': ('vfalu', 'VEC_VFW', 681),
    'VFWSUB_VV': ('vfalu', 'VEC_VVW', 580),
    'VFWSUB_WF': ('vfalu', 'VEC_WFW', 683),
    'VFWSUB_WV': ('vfalu', 'VEC_WVW', 582),
    'VID_V': ('vipu', 'VEC_MVV', 380),
    'VIOTA_M': ('vipu', 'VEC_MVV', 381),
    'VMACC_VV': ('vimac', 'VEC_VVV', 382),
    'VMACC_VX': ('vimac', 'VEC_VXV', 451),
    'VMADC_VI': ('vialuF', 'VEC_VXM', 332),
    'VMADC_VIM': ('vialuF', 'VEC_VXM', 331),
    'VMADC_VV': ('vialuF', 'VEC_VVM', 206),
    'VMADC_VVM': ('vialuF', 'VEC_VVM', 205),
    'VMADC_VX': ('vialuF', 'VEC_VXM', 273),
    'VMADC_VXM': ('vialuF', 'VEC_VXM', 272),
    'VMADD_VV': ('vimac', 'VEC_VVV', 384),
    'VMADD_VX': ('vimac', 'VEC_VXV', 452),
    'VMANDN_MM': ('vialuF', 'dummy', 386),
    'VMAND_MM': ('vialuF', 'dummy', 385),
    'VMAXU_VV': ('vialuF', 'VEC_VVV', 194),
    'VMAXU_VX': ('vialuF', 'VEC_VXV', 259),
    'VMAX_VV': ('vialuF', 'VEC_VVV', 195),
    'VMAX_VX': ('vialuF', 'VEC_VXV', 260),
    'VMERGE_VIM': ('vialuF', 'VEC_VXV', 333),
    'VMERGE_VVM': ('vialuF', 'VEC_VVV', 211),
    'VMERGE_VXM': ('vialuF', 'VEC_VXV', 277),
    'VMFEQ_VF': ('vfalu', 'VEC_VFM', 719),
    'VMFEQ_VV': ('vfalu', 'VEC_VVM', 626),
    'VMFGE_VF': ('vfalu', 'VEC_VFM', 724),
    'VMFGT_VF': ('vfalu', 'VEC_VFM', 723),
    'VMFLE_VF': ('vfalu', 'VEC_VFM', 722),
    'VMFLE_VV': ('vfalu', 'VEC_VVM', 629),
    'VMFLT_VF': ('vfalu', 'VEC_VFM', 721),
    'VMFLT_VV': ('vfalu', 'VEC_VVM', 628),
    'VMFNE_VF': ('vfalu', 'VEC_VFM', 720),
    'VMFNE_VV': ('vfalu', 'VEC_VVM', 627),
    'VMINU_VV': ('vialuF', 'VEC_VVV', 191),
    'VMINU_VX': ('vialuF', 'VEC_VXV', 256),
    'VMIN_VV': ('vialuF', 'VEC_VVV', 193),
    'VMIN_VX': ('vialuF', 'VEC_VXV', 258),
    'VMNAND_MM': ('vialuF', 'dummy', 387),
    'VMNOR_MM': ('vialuF', 'dummy', 388),
    'VMORN_MM': ('vialuF', 'dummy', 390),
    'VMOR_MM': ('vialuF', 'dummy', 389),
    'VMSBC_VV': ('vialuF', 'VEC_VVM', 209),
    'VMSBC_VVM': ('vialuF', 'VEC_VVM', 210),
    'VMSBC_VX': ('vialuF', 'VEC_VXM', 275),
    'VMSBC_VXM': ('vialuF', 'VEC_VXM', 276),
    'VMSBF_M': ('vipu', 'dummy', 393),
    'VMSEQ_VI': ('vialuF', 'VEC_VXM', 337),
    'VMSEQ_VV': ('vialuF', 'VEC_VVM', 215),
    'VMSEQ_VX': ('vialuF', 'VEC_VXM', 281),
    'VMSGTU_VI': ('vialuF', 'VEC_VXM', 342),
    'VMSGTU_VX': ('vialuF', 'VEC_VXM', 288),
    'VMSGT_VI': ('vialuF', 'VEC_VXM', 343),
    'VMSGT_VX': ('vialuF', 'VEC_VXM', 289),
    'VMSIF_M': ('vipu', 'dummy', 394),
    'VMSLEU_VI': ('vialuF', 'VEC_VXM', 340),
    'VMSLEU_VV': ('vialuF', 'VEC_VVM', 220),
    'VMSLEU_VX': ('vialuF', 'VEC_VXM', 286),
    'VMSLE_VI': ('vialuF', 'VEC_VXM', 341),
    'VMSLE_VV': ('vialuF', 'VEC_VVM', 221),
    'VMSLE_VX': ('vialuF', 'VEC_VXM', 287),
    'VMSLTU_VV': ('vialuF', 'VEC_VVM', 218),
    'VMSLTU_VX': ('vialuF', 'VEC_VXM', 284),
    'VMSLT_VV': ('vialuF', 'VEC_VVM', 219),
    'VMSLT_VX': ('vialuF', 'VEC_VXM', 285),
    'VMSNE_VI': ('vialuF', 'VEC_VXM', 339),
    'VMSNE_VV': ('vialuF', 'VEC_VVM', 217),
    'VMSNE_VX': ('vialuF', 'VEC_VXM', 283),
    'VMSOF_M': ('vipu', 'dummy', 395),
    'VMULHSU_VV': ('vimac', 'VEC_VVV', 398),
    'VMULHSU_VX': ('vimac', 'VEC_VXV', 455),
    'VMULHU_VV': ('vimac', 'VEC_VVV', 399),
    'VMULHU_VX': ('vimac', 'VEC_VXV', 456),
    'VMULH_VV': ('vimac', 'VEC_VVV', 397),
    'VMULH_VX': ('vimac', 'VEC_VXV', 454),
    'VMUL_VV': ('vimac', 'VEC_VVV', 396),
    'VMUL_VX': ('vimac', 'VEC_VXV', 453),
    'VMV1R_V': ('vppu', 'VEC_MVNR', 359),
    'VMV2R_V': ('vppu', 'VEC_MVNR', 361),
    'VMV4R_V': ('vppu', 'VEC_MVNR', 362),
    'VMV8R_V': ('vppu', 'VEC_MVNR', 363),
    'VMV_S_X': ('vialuF', 'VEC_0XV', 457),
    'VMV_V_I': ('vialuF', 'VEC_VXV', 335),
    'VMV_V_V': ('vialuF', 'VEC_VVV', 213),
    'VMV_V_X': ('vialuF', 'VEC_VXV', 279),
    'VMV_X_S': ('vipu', 'dummy', 400),
    'VMXNOR_MM': ('vialuF', 'dummy', 391),
    'VMXOR_MM': ('vialuF', 'dummy', 392),
    'VNCLIPU_WI': ('vialuF', 'VEC_WXV', 356),
    'VNCLIPU_WV': ('vialuF', 'VEC_WVV', 238),
    'VNCLIPU_WX': ('vialuF', 'VEC_WXV', 306),
    'VNCLIP_WI': ('vialuF', 'VEC_WXV', 358),
    'VNCLIP_WV': ('vialuF', 'VEC_WVV', 240),
    'VNCLIP_WX': ('vialuF', 'VEC_WXV', 308),
    'VNMSAC_VV': ('vimac', 'VEC_VVV', 402),
    'VNMSAC_VX': ('vimac', 'VEC_VXV', 458),
    'VNMSUB_VV': ('vimac', 'VEC_VVV', 403),
    'VNMSUB_VX': ('vimac', 'VEC_VXV', 460),
    'VNSRA_WI': ('vialuF', 'VEC_WXV', 349),
    'VNSRA_WV': ('vialuF', 'VEC_WVV', 227),
    'VNSRA_WX': ('vialuF', 'VEC_WXV', 295),
    'VNSRL_WI': ('vialuF', 'VEC_WXV', 348),
    'VNSRL_WV': ('vialuF', 'VEC_WVV', 226),
    'VNSRL_WX': ('vialuF', 'VEC_WXV', 294),
    'VOR_VI': ('vialuF', 'VEC_VXV', 322),
    'VOR_VV': ('vialuF', 'VEC_VVV', 198),
    'VOR_VX': ('vialuF', 'VEC_VXV', 263),
    'VREDAND_VS': ('vipu', 'VEC_VRED', 404),
    'VREDMAXU_VS': ('vipu', 'VEC_VRED', 406),
    'VREDMAX_VS': ('vipu', 'VEC_VRED', 405),
    'VREDMINU_VS': ('vipu', 'VEC_VRED', 408),
    'VREDMIN_VS': ('vipu', 'VEC_VRED', 407),
    'VREDOR_VS': ('vipu', 'VEC_VRED', 409),
    'VREDSUM_VS': ('vipu', 'VEC_VRED', 410),
    'VREDXOR_VS': ('vipu', 'VEC_VRED', 411),
    'VREMU_VV': ('vidiv', 'VEC_VVV', 413),
    'VREMU_VX': ('vidiv', 'VEC_VXV', 462),
    'VREM_VV': ('vidiv', 'VEC_VVV', 412),
    'VREM_VX': ('vidiv', 'VEC_VXV', 461),
    'VREV8_V': ('vialuF', 'VEC_VVV', 438),
    'VRGATHEREI16_VV': ('vppu', 'VEC_RGATHEREI16', 202),
    'VRGATHER_VI': ('vppu', 'VEC_RGATHER_VX', 324),
    'VRGATHER_VV': ('vppu', 'VEC_RGATHER', 200),
    'VRGATHER_VX': ('vppu', 'VEC_RGATHER_VX', 265),
    'VROL_VV': ('vialuF', 'VEC_VVV', 247),
    'VROL_VX': ('vialuF', 'VEC_VXV', 312),
    'VROR_VI': ('vialuF', 'VEC_VXV', 366),
    'VROR_VV': ('vialuF', 'VEC_VVV', 248),
    'VROR_VX': ('vialuF', 'VEC_VXV', 313),
    'VRSUB_VI': ('vialuF', 'VEC_VXV', 319),
    'VRSUB_VX': ('vialuF', 'VEC_VXV', 255),
    'VSADDU_VI': ('vialuF', 'VEC_VXV', 350),
    'VSADDU_VV': ('vialuF', 'VEC_VVV', 228),
    'VSADDU_VX': ('vialuF', 'VEC_VXV', 296),
    'VSADD_VI': ('vialuF', 'VEC_VXV', 352),
    'VSADD_VV': ('vialuF', 'VEC_VVV', 230),
    'VSADD_VX': ('vialuF', 'VEC_VXV', 298),
    'VSBC_VVM': ('vialuF', 'VEC_VVV', 207),
    'VSBC_VXM': ('vialuF', 'VEC_VXV', 274),
    'VSEXT_VF2': ('vialuF', 'VEC_EXT2', 414),
    'VSEXT_VF4': ('vialuF', 'VEC_EXT4', 415),
    'VSEXT_VF8': ('vialuF', 'VEC_EXT8', 416),
    'VSLIDE1DOWN_VX': ('vppu', 'VEC_SLIDE1DOWN', 463),
    'VSLIDE1UP_VX': ('vppu', 'VEC_SLIDE1UP', 465),
    'VSLIDEDOWN_VI': ('vppu', 'VEC_SLIDEDOWN', 328),
    'VSLIDEDOWN_VX': ('vppu', 'VEC_SLIDEDOWN', 269),
    'VSLIDEUP_VI': ('vppu', 'VEC_SLIDEUP', 326),
    'VSLIDEUP_VX': ('vppu', 'VEC_SLIDEUP', 267),
    'VSLL_VI': ('vialuF', 'VEC_VXV', 344),
    'VSLL_VV': ('vialuF', 'VEC_VVV', 222),
    'VSLL_VX': ('vialuF', 'VEC_VXV', 290),
    'VSMUL_VV': ('vimac', 'VEC_VVV', 233),
    'VSMUL_VX': ('vimac', 'VEC_VXV', 301),
    'VSRA_VI': ('vialuF', 'VEC_VXV', 347),
    'VSRA_VV': ('vialuF', 'VEC_VVV', 225),
    'VSRA_VX': ('vialuF', 'VEC_VXV', 293),
    'VSRL_VI': ('vialuF', 'VEC_VXV', 346),
    'VSRL_VV': ('vialuF', 'VEC_VVV', 224),
    'VSRL_VX': ('vialuF', 'VEC_VXV', 292),
    'VSSRA_VI': ('vialuF', 'VEC_VXV', 355),
    'VSSRA_VV': ('vialuF', 'VEC_VVV', 237),
    'VSSRA_VX': ('vialuF', 'VEC_VXV', 305),
    'VSSRL_VI': ('vialuF', 'VEC_VXV', 353),
    'VSSRL_VV': ('vialuF', 'VEC_VVV', 235),
    'VSSRL_VX': ('vialuF', 'VEC_VXV', 303),
    'VSSUBU_VV': ('vialuF', 'VEC_VVV', 231),
    'VSSUBU_VX': ('vialuF', 'VEC_VXV', 299),
    'VSSUB_VV': ('vialuF', 'VEC_VVV', 232),
    'VSSUB_VX': ('vialuF', 'VEC_VXV', 300),
    'VSUB_VV': ('vialuF', 'VEC_VVV', 190),
    'VSUB_VX': ('vialuF', 'VEC_VXV', 254),
    'VWADDU_VV': ('vialuF', 'VEC_VVW', 422),
    'VWADDU_VX': ('vialuF', 'VEC_VXW', 468),
    'VWADDU_WV': ('vialuF', 'VEC_WVW', 423),
    'VWADDU_WX': ('vialuF', 'VEC_WXW', 469),
    'VWADD_VV': ('vialuF', 'VEC_VVW', 420),
    'VWADD_VX': ('vialuF', 'VEC_VXW', 466),
    'VWADD_WV': ('vialuF', 'VEC_WVW', 421),
    'VWADD_WX': ('vialuF', 'VEC_WXW', 467),
    'VWMACCSU_VV': ('vimac', 'VEC_VVW', 425),
    'VWMACCSU_VX': ('vimac', 'VEC_VXW', 473),
    'VWMACCUS_VX': ('vimac', 'VEC_VXW', 475),
    'VWMACCU_VV': ('vimac', 'VEC_VVW', 426),
    'VWMACCU_VX': ('vimac', 'VEC_VXW', 474),
    'VWMACC_VV': ('vimac', 'VEC_VVW', 424),
    'VWMACC_VX': ('vimac', 'VEC_VXW', 472),
    'VWMULSU_VV': ('vimac', 'VEC_VVW', 428),
    'VWMULSU_VX': ('vimac', 'VEC_VXW', 478),
    'VWMULU_VV': ('vimac', 'VEC_VVW', 429),
    'VWMULU_VX': ('vimac', 'VEC_VXW', 480),
    'VWMUL_VV': ('vimac', 'VEC_VVW', 427),
    'VWMUL_VX': ('vimac', 'VEC_VXW', 477),
    'VWREDSUMU_VS': ('vipu', 'VEC_VWW', 241),
    'VWREDSUM_VS': ('vipu', 'VEC_VWW', 243),
    'VWSLL_VI': ('vialuF', 'VEC_VXW', 367),
    'VWSLL_VV': ('vialuF', 'VEC_VVW', 249),
    'VWSLL_VX': ('vialuF', 'VEC_VXW', 314),
    'VWSUBU_VV': ('vialuF', 'VEC_VVW', 432),
    'VWSUBU_VX': ('vialuF', 'VEC_VXW', 483),
    'VWSUBU_WV': ('vialuF', 'VEC_WVW', 433),
    'VWSUBU_WX': ('vialuF', 'VEC_WXW', 484),
    'VWSUB_VV': ('vialuF', 'VEC_VVW', 430),
    'VWSUB_VX': ('vialuF', 'VEC_VXW', 481),
    'VWSUB_WV': ('vialuF', 'VEC_WVW', 431),
    'VWSUB_WX': ('vialuF', 'VEC_WXW', 482),
    'VXOR_VI': ('vialuF', 'VEC_VXV', 323),
    'VXOR_VV': ('vialuF', 'VEC_VVV', 199),
    'VXOR_VX': ('vialuF', 'VEC_VXV', 264),
    'VZEXT_VF2': ('vialuF', 'VEC_EXT2', 417),
    'VZEXT_VF4': ('vialuF', 'VEC_EXT4', 418),
    'VZEXT_VF8': ('vialuF', 'VEC_EXT8', 419),
}

SCALAR_OPCODES = {
    'ADD': ('alu', 154),
    'ADDI': ('alu', 147),
    'ADDIW': ('alu', 172),
    'ADDW': ('alu', 177),
    'ADD_UW': ('alu', 277),
    'AES64DS': ('bku', 355),
    'AES64DSM': ('bku', 356),
    'AES64ES': ('bku', 363),
    'AES64ESM': ('bku', 364),
    'AES64IM': ('bku', 357),
    'AES64KS1I': ('bku', 358),
    'AES64KS2': ('bku', 359),
    'AMOADD_D': ('mou', 248),
    'AMOADD_W': ('mou', 238),
    'AMOAND_D': ('mou', 252),
    'AMOAND_W': ('mou', 241),
    'AMOCAS_D': ('mou', 258),
    'AMOCAS_Q': ('mou', 259),
    'AMOCAS_W': ('mou', 247),
    'AMOMAXU_D': ('mou', 257),
    'AMOMAXU_W': ('mou', 246),
    'AMOMAX_D': ('mou', 256),
    'AMOMAX_W': ('mou', 245),
    'AMOMINU_D': ('mou', 255),
    'AMOMINU_W': ('mou', 244),
    'AMOMIN_D': ('mou', 254),
    'AMOMIN_W': ('mou', 243),
    'AMOOR_D': ('mou', 253),
    'AMOOR_W': ('mou', 242),
    'AMOSWAP_D': ('mou', 251),
    'AMOSWAP_W': ('mou', 240),
    'AMOXOR_D': ('mou', 250),
    'AMOXOR_W': ('mou', 239),
    'AND': ('alu', 158),
    'ANDI': ('alu', 148),
    'ANDN': ('alu', 287),
    'AUIPC': ('jmp', 199),
    'BCLR': ('alu', 326),
    'BCLRI': ('alu', 327),
    'BEQ': ('brh', 203),
    'BEXT': ('alu', 328),
    'BEXTI': ('alu', 329),
    'BGE': ('brh', 205),
    'BGEU': ('brh', 206),
    'BINV': ('alu', 330),
    'BINVI': ('alu', 331),
    'BLT': ('brh', 207),
    'BLTU': ('brh', 208),
    'BNE': ('brh', 204),
    'BREV8': ('alu', 340),
    'BSET': ('alu', 332),
    'BSETI': ('alu', 333),
    'CBO_CLEAN': ('stu', 479),
    'CBO_FLUSH': ('stu', 480),
    'CBO_INVAL': ('stu', 481),
    'CBO_ZERO': ('stu', 478),
    'CLMUL': ('bku', 321),
    'CLMULH': ('bku', 322),
    'CLMULR': ('bku', 323),
    'CLZ': ('bku', 290),
    'CLZW': ('bku', 292),
    'CPOP': ('bku', 295),
    'CPOPW': ('bku', 297),
    'CSRRC': ('csr', 214),
    'CSRRCI': ('csr', 218),
    'CSRRS': ('csr', 213),
    'CSRRSI': ('csr', 217),
    'CSRRW': ('csr', 211),
    'CSRRWI': ('csr', 215),
    'CTZ': ('bku', 293),
    'CTZW': ('bku', 294),
    'CZERO_EQZ': ('alu', 517),
    'CZERO_NEZ': ('alu', 518),
    'DIV': ('div', 190),
    'DIVU': ('div', 192),
    'DIVUW': ('div', 196),
    'DIVW': ('div', 195),
    'DRET': ('csr', 225),
    'EBREAK': ('csr', 219),
    'ECALL': ('csr', 221),
    'FADD_D': ('falu', 490),
    'FADD_H': ('falu', 491),
    'FADD_S': ('falu', 489),
    'FCLASS_D': ('falu', 536),
    'FCLASS_H': ('falu', 537),
    'FCLASS_S': ('falu', 535),
    'FCVTMOD_W_D': ('fcvt', 550),
    'FCVT_D_H': ('fcvt', 525),
    'FCVT_D_L': ('i2f', 416),
    'FCVT_D_LU': ('i2f', 417),
    'FCVT_D_S': ('fcvt', 520),
    'FCVT_D_W': ('i2f', 413),
    'FCVT_D_WU': ('i2f', 415),
    'FCVT_H_D': ('fcvt', 524),
    'FCVT_H_L': ('i2f', 421),
    'FCVT_H_LU': ('i2f', 422),
    'FCVT_H_S': ('fcvt', 522),
    'FCVT_H_W': ('i2f', 418),
    'FCVT_H_WU': ('i2f', 420),
    'FCVT_LU_D': ('fcvt', 518),
    'FCVT_LU_H': ('fcvt', 529),
    'FCVT_LU_S': ('fcvt', 514),
    'FCVT_L_D': ('fcvt', 517),
    'FCVT_L_H': ('fcvt', 528),
    'FCVT_L_S': ('fcvt', 513),
    'FCVT_S_D': ('fcvt', 519),
    'FCVT_S_H': ('fcvt', 523),
    'FCVT_S_L': ('i2f', 411),
    'FCVT_S_LU': ('i2f', 412),
    'FCVT_S_W': ('i2f', 409),
    'FCVT_S_WU': ('i2f', 410),
    'FCVT_WU_D': ('fcvt', 516),
    'FCVT_WU_H': ('fcvt', 527),
    'FCVT_WU_S': ('fcvt', 512),
    'FCVT_W_D': ('fcvt', 515),
    'FCVT_W_H': ('fcvt', 526),
    'FCVT_W_S': ('fcvt', 511),
    'FDIV_D': ('fDivSqrt', 553),
    'FDIV_H': ('fDivSqrt', 554),
    'FDIV_S': ('fDivSqrt', 551),
    'FENCE': ('fence', 230),
    'FENCE_I': ('fence', 229),
    'FEQ_D': ('falu', 498),
    'FEQ_H': ('falu', 501),
    'FEQ_S': ('falu', 495),
    'FLD': ('ldu', 399),
    'FLEQ_D': ('falu', 553),
    'FLEQ_H': ('falu', 551),
    'FLEQ_S': ('falu', 552),
    'FLE_D': ('falu', 500),
    'FLE_H': ('falu', 503),
    'FLE_S': ('falu', 497),
    'FLH': ('ldu', 397),
    'FLI_D': ('f2v', 537),
    'FLI_H': ('f2v', 535),
    'FLI_S': ('f2v', 536),
    'FLTQ_D': ('falu', 556),
    'FLTQ_H': ('falu', 554),
    'FLTQ_S': ('falu', 555),
    'FLT_D': ('falu', 499),
    'FLT_H': ('falu', 502),
    'FLT_S': ('falu', 496),
    'FLW': ('ldu', 398),
    'FMADD_D': ('fmac', 563),
    'FMADD_H': ('fmac', 567),
    'FMADD_S': ('fmac', 558),
    'FMAXM_D': ('falu', 543),
    'FMAXM_H': ('falu', 541),
    'FMAXM_S': ('falu', 542),
    'FMAX_D': ('falu', 507),
    'FMAX_H': ('falu', 509),
    'FMAX_S': ('falu', 506),
    'FMINM_D': ('falu', 540),
    'FMINM_H': ('falu', 538),
    'FMINM_S': ('falu', 539),
    'FMIN_D': ('falu', 505),
    'FMIN_H': ('falu', 508),
    'FMIN_S': ('falu', 504),
    'FMSUB_D': ('fmac', 564),
    'FMSUB_H': ('fmac', 568),
    'FMSUB_S': ('fmac', 560),
    'FMUL_D': ('fmac', 549),
    'FMUL_H': ('fmac', 550),
    'FMUL_S': ('fmac', 547),
    'FMV_D_X': ('i2v', 403),
    'FMV_H_X': ('i2v', 406),
    'FMV_W_X': ('i2v', 405),
    'FMV_X_D': ('fcvt', 531),
    'FMV_X_H': ('fcvt', 533),
    'FMV_X_W': ('fcvt', 532),
    'FNMADD_D': ('fmac', 565),
    'FNMADD_H': ('fmac', 569),
    'FNMADD_S': ('fmac', 561),
    'FNMSUB_D': ('fmac', 566),
    'FNMSUB_H': ('fmac', 570),
    'FNMSUB_S': ('fmac', 562),
    'FROUNDNX_D': ('fcvt', 549),
    'FROUNDNX_H': ('fcvt', 547),
    'FROUNDNX_S': ('fcvt', 548),
    'FROUND_D': ('fcvt', 546),
    'FROUND_H': ('fcvt', 544),
    'FROUND_S': ('fcvt', 545),
    'FSD': ('stu', 402),
    'FSGNJN_D': ('falu', 545),
    'FSGNJN_H': ('falu', 546),
    'FSGNJN_S': ('falu', 544),
    'FSGNJX_D': ('falu', 542),
    'FSGNJX_H': ('falu', 543),
    'FSGNJX_S': ('falu', 541),
    'FSGNJ_D': ('falu', 539),
    'FSGNJ_H': ('falu', 540),
    'FSGNJ_S': ('falu', 538),
    'FSH': ('stu', 400),
    'FSQRT_D': ('fDivSqrt', 556),
    'FSQRT_H': ('fDivSqrt', 557),
    'FSQRT_S': ('fDivSqrt', 555),
    'FSUB_D': ('falu', 493),
    'FSUB_H': ('falu', 494),
    'FSUB_S': ('falu', 492),
    'FSW': ('stu', 401),
    'HFENCE_GVMA': ('fence', 490),
    'HFENCE_VVMA': ('fence', 491),
    'HINVAL_GVMA': ('fence', 497),
    'HINVAL_VVMA': ('fence', 498),
    'HLVX_HU': ('ldu', 506),
    'HLVX_WU': ('ldu', 507),
    'HLV_B': ('ldu', 499),
    'HLV_BU': ('ldu', 500),
    'HLV_D': ('ldu', 501),
    'HLV_H': ('ldu', 502),
    'HLV_HU': ('ldu', 503),
    'HLV_W': ('ldu', 504),
    'HLV_WU': ('ldu', 505),
    'HSV_B': ('stu', 508),
    'HSV_D': ('stu', 509),
    'HSV_H': ('stu', 510),
    'HSV_W': ('stu', 511),
    'JAL': ('jmp', 201),
    'JALR': ('jmp', 202),
    'LB': ('ldu', 141),
    'LBU': ('ldu', 142),
    'LD': ('ldu', 165),
    'LH': ('ldu', 139),
    'LHU': ('ldu', 140),
    'LR_D': ('mou', 263),
    'LR_W': ('mou', 261),
    'LUI': ('alu', 146),
    'LW': ('ldu', 138),
    'LWU': ('ldu', 166),
    'MAX': ('alu', 298),
    'MAXU': ('alu', 300),
    'MIN': ('alu', 301),
    'MINU': ('alu', 302),
    'MNRET': ('csr', 224),
    'MOP_R': ('alu', 528),
    'MOP_RR': ('alu', 529),
    'MRET': ('csr', 223),
    'MUL': ('mul', 185),
    'MULH': ('mul', 186),
    'MULHSU': ('mul', 188),
    'MULHU': ('mul', 187),
    'MULW': ('mul', 189),
    'OR': ('alu', 159),
    'ORC_B': ('alu', 315),
    'ORI': ('alu', 149),
    'ORN': ('alu', 288),
    'PACK': ('alu', 337),
    'PACKH': ('alu', 338),
    'PACKW': ('alu', 339),
    'PAUSE': ('fence', 231),
    'REM': ('div', 193),
    'REMU': ('div', 194),
    'REMUW': ('div', 198),
    'REMW': ('div', 197),
    'REV8': ('alu', 317),
    'ROL': ('alu', 308),
    'ROLW': ('alu', 310),
    'ROR': ('alu', 311),
    'RORI': ('alu', 312),
    'RORIW': ('alu', 313),
    'RORW': ('alu', 314),
    'SB': ('stu', 145),
    'SC_D': ('mou', 265),
    'SC_W': ('mou', 264),
    'SD': ('stu', 167),
    'SEXT_B': ('alu', 303),
    'SEXT_H': ('alu', 305),
    'SFENCE_INVAL_IR': ('fence', 460),
    'SFENCE_VMA': ('fence', 227),
    'SFENCE_W_INVAL': ('fence', 454),
    'SH': ('stu', 144),
    'SH1ADD': ('alu', 278),
    'SH1ADD_UW': ('alu', 279),
    'SH2ADD': ('alu', 280),
    'SH2ADD_UW': ('alu', 281),
    'SH3ADD': ('alu', 282),
    'SH3ADD_UW': ('alu', 283),
    'SHA256SIG0': ('bku', 367),
    'SHA256SIG1': ('bku', 368),
    'SHA256SUM0': ('bku', 369),
    'SHA256SUM1': ('bku', 370),
    'SHA512SIG0': ('bku', 371),
    'SHA512SIG1': ('bku', 372),
    'SHA512SUM0': ('bku', 373),
    'SHA512SUM1': ('bku', 374),
    'SINVAL_VMA': ('fence', 448),
    'SLL': ('alu', 153),
    'SLLI': ('alu', 168),
    'SLLIW': ('alu', 174),
    'SLLI_UW': ('alu', 284),
    'SLLW': ('alu', 180),
    'SLT': ('alu', 156),
    'SLTI': ('alu', 151),
    'SLTIU': ('alu', 152),
    'SLTU': ('alu', 157),
    'SM3P0': ('bku', 387),
    'SM3P1': ('bku', 388),
    'SM4ED0': ('bku', 377),
    'SM4ED1': ('bku', 378),
    'SM4ED2': ('bku', 379),
    'SM4ED3': ('bku', 380),
    'SM4KS0': ('bku', 381),
    'SM4KS1': ('bku', 382),
    'SM4KS2': ('bku', 383),
    'SM4KS3': ('bku', 384),
    'SRA': ('alu', 161),
    'SRAI': ('alu', 171),
    'SRAIW': ('alu', 175),
    'SRAW': ('alu', 181),
    'SRET': ('csr', 222),
    'SRL': ('alu', 162),
    'SRLI': ('alu', 170),
    'SRLIW': ('alu', 176),
    'SRLW': ('alu', 182),
    'SUB': ('alu', 155),
    'SUBW': ('alu', 179),
    'SW': ('stu', 143),
    'TRAP': ('alu', 567),
    'WFI': ('csr', 226),
    'WRS_NTO': ('csr', 234),
    'WRS_STO': ('csr', 235),
    'XNOR': ('alu', 289),
    'XOR': ('alu', 160),
    'XORI': ('alu', 150),
    'XPERM4': ('bku', 347),
    'XPERM8': ('bku', 348),
}
SCALAR_VECTOR_DECODER = frozenset(('FADD_D', 'FADD_H', 'FADD_S', 'FCLASS_D', 'FCLASS_H', 'FCLASS_S', 'FCVT_D_H', 'FCVT_D_S', 'FCVT_H_D', 'FCVT_H_S', 'FCVT_LU_D', 'FCVT_LU_H', 'FCVT_LU_S', 'FCVT_L_D', 'FCVT_L_H', 'FCVT_L_S', 'FCVT_S_D', 'FCVT_S_H', 'FCVT_WU_D', 'FCVT_WU_H', 'FCVT_WU_S', 'FCVT_W_D', 'FCVT_W_H', 'FCVT_W_S', 'FDIV_D', 'FDIV_H', 'FDIV_S', 'FEQ_D', 'FEQ_H', 'FEQ_S', 'FLE_D', 'FLE_H', 'FLE_S', 'FLT_D', 'FLT_H', 'FLT_S', 'FMADD_D', 'FMADD_H', 'FMADD_S', 'FMAX_D', 'FMAX_H', 'FMAX_S', 'FMIN_D', 'FMIN_H', 'FMIN_S', 'FMSUB_D', 'FMSUB_H', 'FMSUB_S', 'FMUL_D', 'FMUL_H', 'FMUL_S', 'FMV_X_D', 'FMV_X_H', 'FMV_X_W', 'FNMADD_D', 'FNMADD_H', 'FNMADD_S', 'FNMSUB_D', 'FNMSUB_H', 'FNMSUB_S', 'FSGNJN_D', 'FSGNJN_H', 'FSGNJN_S', 'FSGNJX_D', 'FSGNJX_H', 'FSGNJX_S', 'FSGNJ_D', 'FSGNJ_H', 'FSGNJ_S', 'FSQRT_D', 'FSQRT_H', 'FSQRT_S', 'FSUB_D', 'FSUB_H', 'FSUB_S'))
SOURCE_HASHES = {
    'Rob.scala': '6910ce3076a24a03212c5d09ad06e14f7ab6d5bca8eade9a4ee6196739c437c4',
    'Configs.scala': '52f1a7847cea7ccf759d863141700d3c5fa51986c555c5ec381d3e0a7c20bcb8',
    'Parameters.scala': '63781a89fa54333909045768aa6a8c5f20cf225c109751d46f7f050c0e1e4617',
    'VecDecoder.scala': '3eec0be04f5e3a375e57fea33b101a43d46184bcefbfec163b7942efdabf9aa6',
    'UopInfoGen.scala': '2d36d43ae188f63113cfe7498ec3261e26faac5f618f131dce686601ed3c25f4',
    'DecodeUnitComp.scala': '19e27757079fea650eaefdbae9ae0aab11fe88ed3a3cdbd6eeac294bcf7bafdf',
    'DecodeUnit.scala': '4111d249fbf9df65ccf01c0e0f55c8aee4eff364be45f186895f5449caa485b7',
    'ExeUnit.scala': '9d4807562982ba6f7c851d3121e221cbc57399f33e8df51ab53d3cbacbcded85',
    'NewDispatch.scala': '8bfe46e43ac9a238c1059d89fe80294958295637cb28559e0899a5ddb9a0e581',
    'Scheduler.scala': '025af518f2909bee54ac790553881f1c8b714fda0919d437fc8ab845b472b698',
}
# Flat local filenames -> pinned source URLs for the timing audit.
TIMING_SOURCE_PATHS = {
    'FuConfig.scala': ROOT + 'backend/fu/FuConfig.scala',
    'FuncUnit.scala': ROOT + 'backend/fu/FuncUnit.scala',
    'ExeUnitParams.scala': ROOT + 'backend/exu/ExeUnitParams.scala',
    'SRT16Divider.scala': ROOT + 'backend/fu/SRT16Divider.scala',
    'LoadUnit.scala': ROOT + 'mem/pipeline/LoadUnit.scala',
    'StoreUnit.scala': ROOT + 'mem/pipeline/StoreUnit.scala',
    'YunsuanFloatDivider.scala': YUNSUAN_ROOT + 'fpu/FloatDivider.scala',
    'YunsuanVectorFloatDivider.scala': YUNSUAN_ROOT + 'vector/VectorFloatDivider.scala',
    'YunsuanScalarSqrt.scala': YUNSUAN_ROOT + 'fpu/fqrt/fpsqrt_r16.scala',
    'Yunsuanfpsqrt_vector_r16.scala': YUNSUAN_ROOT + 'vector/vfsqrt/fpsqrt_vector_r16.scala',
    'YunsuanVectorIdiv.scala': YUNSUAN_ROOT + 'vector/VectorIdiv/VectorIdiv.scala',
    'YunsuanSRT16Divint.scala': YUNSUAN_ROOT + 'vector/VectorIdiv/SRT16Divint.scala',
    'YunsuanI8DivNr4.scala': YUNSUAN_ROOT + 'vector/VectorIdiv/I8DivNr4.scala',
}
SOURCE_HASHES.update({
    'FuConfig.scala': 'f281e28478a905cd11782f8b8cfec66a4da7c11cd1997d88f0cef8860629fefa',
    'FuncUnit.scala': '48ecf1db24de9a7a3b8511f49a082ae1517ffb16f20da90cb580fd486086ee1c',
    'ExeUnitParams.scala': 'd6678dc21e3e48a583c583b2155488eb874182116702b1e090bb1aa2b7283f61',
    'SRT16Divider.scala': 'b89dae02da4cbd2fa873d77ec5a755b84b7c186054e82721e714141b37ff9634',
    'LoadUnit.scala': 'f6c9cac234168799602aded1e7cce206efabfa5eec46cbe261bc376dd1460b0f',
    'StoreUnit.scala': 'd8014a60147c1a14eb9587b44c02361c208e1baac7e8af275cc37674b82daab8',
    'YunsuanFloatDivider.scala': '7816253a30b9f57e0cfffdd51adbd4afe2accda4f3cab80e18749eefaed5c7f2',
    'YunsuanVectorFloatDivider.scala': 'aa5c7c2471a44e5febec8c7e7dcf2f1d61d11a5d14217b9c19ad2f4de287d96a',
    'YunsuanScalarSqrt.scala': '44f7f9965dcb7b74962da166538b835f279a45810c30d3c9349bbad0ade3a753',
    'Yunsuanfpsqrt_vector_r16.scala': 'cd04a9d360bd7247fa9aa22bab0189e8e726675922bdb42cdbca6a76e61fbc5b',
    'YunsuanVectorIdiv.scala': '241912b89767f623944365736b760866b8c8f277940bde2c3e3307e8e7b93f6b',
    'YunsuanSRT16Divint.scala': 'b52fe4a7f56fdeb21c9ff118312f35041cae3920cc27ec2b178d32d770856f49',
    'YunsuanI8DivNr4.scala': '9c16ecc2720e9c58ede21744d636fb9a309b9955248d3cb3983c52f54b0d9a45',
})
DATASHEET_DIGEST = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
