"""Protocol v3 validation and binding of raw backend facts to loop context."""
from model_errors import ToolError
import math

PROTOCOL_VERSION = 3


def needs_scalar_cost(a):
    if not a['MaxTripCount'] or not a['ScalarTail']:
        return False
    return not (a['ExactTripCount'] > 0 and a['ExactTripCount'] % a['Width'] == 0
                and a['MaxTripCount'] % a['Width'] == 0)


def validate_scalar_cost(a):
    scalar = a.get('ScalarCost')
    if needs_scalar_cost(a) and scalar is None:
        raise ToolError('missing middle-end scalar cost for scalar tail')
    if scalar is not None and (type(scalar) not in (int, float) or not math.isfinite(scalar) or scalar < 0):
        raise ToolError('invalid middle-end scalar cost')


def iteration_factors(a):
    """Body iterations and unscaled scalar tail in the common v3 score."""
    t, w = a['MaxTripCount'], a['Width']
    main = 1 / w if not t else t // w if a['ScalarTail'] else (t + w - 1) // w
    tail = (t % w) * (a.get('ScalarCost') or 0) if t and a['ScalarTail'] else 0
    return main, tail


def validate_middle_end(value):
    if value['cost_scale'] != 4 or type(value['pressure']) is not bool:
        raise ValueError('invalid middle-end cost context')
    units = value['spill_units'] + value['reload_units']
    if len(value['spill_units']) != 3 or len(value['reload_units']) != 3:
        raise ValueError('invalid TTI register banks')
    for cost in [value[k] for k in ('precomputed', 'vector_region', 'estimated_spill', 'original')] + units:
        if cost is not None and (type(cost) is not int or not 0 <= cost <= 2**63 - 1):
            raise ValueError('invalid middle-end quarter cost')


def validate_manifest(value, run_id):
    try:
        if value['version'] != PROTOCOL_VERSION or value['run_id'] != run_id:
            raise ValueError('version/run mismatch')
        loops = value['loops']
        keys = [(r['function'], r['loop']) for r in loops]
        if len(set(keys)) != len(keys):
            raise ValueError('duplicate loops')
        for row in loops:
            if (not isinstance(row['function'], str) or type(row['loop']) is not int
                    or row['loop'] < 0 or type(row['max_trip_count']) is not int
                    or type(row['exact_trip_count']) is not int
                    or row['max_trip_count'] < 0 or row['exact_trip_count'] < 0):
                raise ValueError('invalid loop context')
        rows = value['candidates']
        if len({r['id'] for r in rows}) != len(rows):
            raise ValueError('duplicate candidates')
        for row in rows:
            validate_middle_end(row['middle_end'])
            if (type(row['probeable']) is not bool or type(row['scalar_tail']) is not bool
                    or (row['function'], row['loop']) not in keys
                    or row['vf'] == 'f1' or row['vf'][0] not in 'fs'
                    or int(row['vf'][1:]) <= 0 or row['estimated_width'] <= 0):
                raise ValueError('invalid vector candidate')
        if not isinstance(value['selections'], list) or not isinstance(value['failures'], list):
            raise ValueError('missing outcomes')
    except (KeyError, TypeError, ValueError, IndexError) as exc:
        raise ToolError(f'invalid manifest: {exc}') from exc
    return value


def bind_observation(a, candidate, loop, run_id):
    """Identity/schema faults are fatal; unsupported facts are scored separately."""
    try:
        if (a['Version'] != 2 or a['RunID'] != run_id
                or a['Candidate'] != candidate['id'] or a['Function'] != candidate['function']
                or a['Stage'] != 'post-ra-cleanup'
                or ('s' if a['ScalableVF'] else 'f') + str(a['VF']) != candidate['vf']
                or a['ScalarTail'] != candidate['scalar_tail']
                or a['MaxTripCount'] != loop['max_trip_count']
                or a['ExactTripCount'] != loop['exact_trip_count']):
            raise ValueError('analytics identity/context mismatch')
        for key in ('Instructions', 'Blocks', 'Edges'):
            if not isinstance(a[key], list):
                raise ValueError('invalid analytics arrays')
        for key in ('Error', 'CPU', 'DependencyCoverage'):
            if not isinstance(a[key], str):
                raise ValueError('invalid analytics strings')
        for key in ('VLen', 'Width'):
            if type(a[key]) is not int:
                raise ValueError('invalid analytics geometry')
        for i in a['Instructions']:
            for key in ('ID', 'Block', 'Group8', 'SEW', 'Bytes', 'Predicate'):
                if type(i[key]) is not int:
                    raise ValueError('invalid instruction geometry')
            for key in ('Meta', 'Barrier', 'ConfigUnused', 'ScalableBytes', 'SameCopy', 'Masked', 'Load', 'Store', 'Stack', 'Spill', 'SpillSlotAccess'):
                if type(i[key]) is not bool:
                    raise ValueError('invalid instruction flags')
            for key in ('Opcode', 'Base', 'Category'):
                if not isinstance(i[key], str):
                    raise ValueError('invalid instruction identity')
            for operand in i['Operands']:
                if operand['Bank'] not in ('gpr', 'fpr', 'vector', 'unknown'):
                    raise ValueError('invalid register bank')
                for key in ('Vector', 'Def', 'Implicit', 'Dead', 'EarlyClobber', 'SubReg', 'Undef', 'Tied'):
                    if type(operand[key]) is not bool:
                        raise ValueError('invalid operand flags')
        for edge in a['Edges']:
            if any(type(edge[k]) is not int for k in ('Source', 'Destination', 'OperandIndex', 'Distance')):
                raise ValueError('invalid dependency edge')
            if (not 0 <= edge['Source'] < len(a['Instructions'])
                    or not 0 <= edge['Destination'] < len(a['Instructions'])
                    or not 0 <= edge['OperandIndex'] < len(a['Instructions'][edge['Destination']]['Operands'])
                    or type(edge['WholeValue']) is not bool):
                raise ValueError('invalid dependency indices')
    except (KeyError, TypeError, ValueError) as exc:
        raise ToolError(f'invalid backend result: {exc}') from exc
    return a | {'ScalarCost': loop['scalar_cost'], 'MiddleEnd': candidate['middle_end']}
