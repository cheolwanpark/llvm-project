"""Strict observation contract. No weights or measurements enter this module."""
import math
import re
from model_errors import ToolError

PROTOCOL_VERSION = 4
SCHEMA = 'mir-local-observation-v1'
STAGE = 'post-ra-cleanup'


def nonnegative(value):
    return type(value) is int and value >= 0


def validate_manifest(value, run_id):
    try:
        if value['version'] != PROTOCOL_VERSION or value['run_id'] != run_id:
            raise ValueError('incompatible protocol or run identity; recollect')
        keys = [(r['function'], r['loop']) for r in value['loops']]
        if len(keys) != len(set(keys)): raise ValueError('duplicate loop')
        for loop in value['loops']:
            if not all(nonnegative(loop[k]) for k in ('loop', 'max_trip_count', 'exact_trip_count')):
                raise ValueError('invalid trip count')
            scalar = loop['scalar_cost']
            if scalar is not None and (type(scalar) not in (int, float) or not math.isfinite(scalar) or scalar < 0):
                raise ValueError('invalid middle-end scalar cost')
            if loop['max_trip_count'] and loop['exact_trip_count'] > loop['max_trip_count']:
                raise ValueError('exact trip count exceeds bound')
        ids = [r['id'] for r in value['candidates']]
        if len(ids) != len(set(ids)): raise ValueError('duplicate candidate')
        for row in value['candidates']:
            if (not re.fullmatch(r'[fs][1-9][0-9]*', row['vf']) or row['vf'] == 'f1'
                    or (row['function'], row['loop']) not in keys
                    or type(row['probeable']) is not bool or type(row['scalar_tail']) is not bool
                    or type(row['estimated_width']) is not int or row['estimated_width'] < 1):
                raise ValueError('invalid candidate context')
            me = row['middle_end']
            unit = me['configuration_unit_quarters']
            if unit is not None and not nonnegative(unit): raise ValueError('invalid configuration TTI unit')
            if (me['unit'] != 'TTI-reciprocal-throughput-quarter'
                    or me['configuration_scope'] != 'per-observed-MIR-configuration'
                    or me['configuration_source'] != 'TTI.getIntrinsicInstrCost(riscv_vsetvlimax)'):
                raise ValueError('invalid configuration cost provenance')
        if not isinstance(value['selections'], list) or not isinstance(value['failures'], list):
            raise ValueError('invalid replay outcomes')
    except (KeyError, TypeError, ValueError) as exc:
        raise ToolError(f'invalid candidate manifest: {exc}') from exc
    return value


def validate_observation(a):
    try:
        if a['schema'] != SCHEMA or a['stage'] != STAGE:
            raise ValueError('incompatible observation schema/stage; recollect')
        for k in ('candidate', 'function', 'compiler', 'cpu', 'target_triple', 'features', 'error', 'run_id', 'register_coverage', 'memory_coverage'):
            if not isinstance(a[k], str): raise ValueError(f'invalid {k}')
        if not all(nonnegative(a[k]) for k in ('vlen', 'vf', 'iteration_width', 'max_trip_count', 'exact_trip_count')):
            raise ValueError('invalid observation geometry')
        for k in ('iteration_mapping', 'scalable', 'scalar_tail'):
            if type(a[k]) is not bool: raise ValueError(f'invalid {k}')
        block_ids = [b['id'] for b in a['blocks']]
        if len(block_ids) != len(set(block_ids)): raise ValueError('duplicate blocks')
        ids = [op['id'] for op in a['instructions']]
        if any(type(i) is not int for i in ids) or ids != list(range(len(ids))): raise ValueError('instruction IDs must preserve MIR order')
        order = a['body_order']
        body = {b['id'] for b in a['blocks'] if b['role'] == 'body'}
        if order != [op['id'] for op in a['instructions'] if op['role'] == 'body']:
            raise ValueError('body execution order disagrees with single-block MIR order')
        for op in a['instructions']:
            if op['block'] not in block_ids: raise ValueError('instruction block missing')
            if not isinstance(op['mir'], str) or not isinstance(op['base_opcode'], str): raise ValueError('invalid MIR')
            for key in ('vector', 'meta', 'configuration', 'pseudo', 'registers_complete', 'load', 'store', 'masked'):
                if type(op[key]) is not bool: raise ValueError(f'invalid op flag {key}')
            for key in ('lmul8', 'sew', 'vl', 'index_emul8', 'index_eew'):
                if op[key] is not None and not nonnegative(op[key]): raise ValueError('invalid known/unknown geometry')
            for index, operand in enumerate(op['operands']):
                if operand['index'] != index: raise ValueError('operand position lost')
                if operand['kind'] == 'register':
                    if not all(nonnegative(u) for u in operand['units']): raise ValueError('invalid register units')
                    for k in ('def', 'use', 'undef', 'physical', 'implicit', 'dead', 'kill', 'early_clobber', 'tied', 'internal_read'):
                        if type(operand[k]) is not bool: raise ValueError(f'invalid register flag {k}')
                    if not nonnegative(operand['subregister']): raise ValueError('invalid subregister')
            for m in op['memory']:
                if type(m['offset']) is not int or not nonnegative(m['alignment']) or m['alignment'] < 1:
                    raise ValueError('invalid memory location')
                for k in ('load', 'store', 'volatile', 'atomic', 'scalable', 'alias_scope', 'noalias'):
                    if type(m[k]) is not bool: raise ValueError('invalid memory metadata')
                if m['bytes'] is not None and not nonnegative(m['bytes']): raise ValueError('invalid memory size')
        for e in a['dependencies']:
            if not all(nonnegative(e[k]) for k in ('source', 'destination', 'iteration_distance', 'operand_index', 'unit')):
                raise ValueError('invalid dependency field types')
            if (e['source'] not in order or e['destination'] not in order or e['iteration_distance'] not in (0, 1)
                    or e['kind'] != 'register-raw'):
                raise ValueError('invalid reaching-def edge')
            op = a['instructions'][e['destination']]
            operand = op['operands'][e['operand_index']]
            if operand['kind'] != 'register' or not operand['use'] or e['unit'] not in operand['units']:
                raise ValueError('dependency operand/unit mismatch')
            if not e['iteration_distance'] and e['source'] >= e['destination']:
                raise ValueError('non-forward reaching-def edge')
    except (KeyError, TypeError, ValueError, IndexError) as exc:
        raise ToolError(f'invalid MIR observation: {exc}') from exc
    return a


def bind_observation(a, candidate, loop, run_id):
    validate_observation(a)
    if (a['run_id'] != run_id or a['candidate'] != candidate['id'] or a['function'] != candidate['function']
            or ('s' if a['scalable'] else 'f') + str(a['vf']) != candidate['vf']
            or a['scalar_tail'] != candidate['scalar_tail']
            or any(a[k] != loop[k] for k in ('max_trip_count', 'exact_trip_count'))):
        raise ToolError('MIR observation/candidate identity mismatch')
    return a | {'middle_end': candidate['middle_end'], 'scalar_cost': loop['scalar_cost']}


def iteration_factors(a):
    """Only exact counts give a kernel total. A bound is never a runtime count."""
    t, width = a['exact_trip_count'], a['iteration_width']
    if width < 1: raise ToolError('unproven iteration width')
    if not t:
        return 1 / width, 0, 'steady-state-per-scalar-iteration'
    if a['scalar_tail']:
        return t // width, t % width, 'exact-trip-count'
    return (t + width - 1) // width, 0, 'exact-trip-count-folded-tail'
