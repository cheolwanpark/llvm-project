"""Protocol v3 validation and binding of raw backend facts to loop context."""
from model_errors import ToolError

PROTOCOL_VERSION = 3


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
            for key in ('Meta', 'Barrier', 'ConfigUnused', 'ScalableBytes', 'SameCopy', 'Masked', 'Load', 'Store', 'Stack'):
                if type(i[key]) is not bool:
                    raise ValueError('invalid instruction flags')
            for key in ('Opcode', 'Base', 'Category'):
                if not isinstance(i[key], str):
                    raise ValueError('invalid instruction identity')
            for operand in i['Operands']:
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
    return a | {'ScalarCost': loop['scalar_cost']}
