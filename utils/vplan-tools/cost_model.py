"""Decoder and memory-request work with shared reporting/selection calculation."""
import hashlib
import json
import math
from pathlib import Path

from hardware import RULE_DIGEST, RULE_VERSION, REVISION, work_for_instruction
from model_errors import ToolError
from observations import SCHEMA, STAGE, iteration_factors, validate_observation
from memory_work import memory_work, category

MODEL_VERSION = 'mir-memory-requests-v4'

# XiangShan MinimalConfig, VLEN 128. Request scale selected on the full
# search-dataset.sqlite; non-memory weights retained from the decoder model. These are shared
# model weights, not hardware latencies or cycle predictions. Decoder facts
# remain in hardware.py.
COEFFICIENTS = {
    'basic_convert': 1.,
    'basic_divide': 1.,
    'basic_fp_alu': 1.,
    'basic_fp_multiply': 1.,
    'basic_integer': 1.,
    'basic_mask': 1.,
    'basic_move': 2.,
    'basic_multiply': 1.,
    'basic_permute': 1.,
    'basic_scalar': 1.,  # Reference unit.
    'memory_requests': 2.,
    'middle_end_scale': 1.,
}
PARAMETERS = tuple(COEFFICIENTS)
IMPLEMENTATION_DIGEST = hashlib.sha256(Path(__file__).read_bytes() +
                                     Path(__file__).with_name('memory_work.py').read_bytes()).hexdigest()


def digest_json(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()).hexdigest()


def machine_parameters():
    return dict(cpu='xiangshan-kunminghu', vlen=128, coefficients=dict(COEFFICIENTS),
                accumulation='sum', configuration=True, scalar_tail=True,
                configuration_ops='excluded-from-body')


def identity():
    return dict(model=MODEL_VERSION, implementation_digest=IMPLEMENTATION_DIGEST, observation_schema=SCHEMA,
                rule_version=RULE_VERSION, rule_digest=RULE_DIGEST, rtl_revision=REVISION, stage=STAGE,
                machine_parameters=machine_parameters())


def zero(): return dict.fromkeys(PARAMETERS, 0.)


def dot(features): return sum(features[p] * COEFFICIENTS[p] for p in PARAMETERS)


def features_for_observation(a):
    validate_observation(a)
    if a['error']: raise ToolError(a['error'])
    if a['vlen'] != 128 or a['cpu'] != 'xiangshan-kunminghu':
        raise ToolError('hardware rules require xiangshan-kunminghu with VLEN 128')
    if not a['iteration_mapping']: raise ToolError('unproven scalar iteration mapping')
    body_blocks = [b for b in a['blocks'] if b['role'] == 'body']
    if len(body_blocks) != 1 or body_blocks[0]['id'] != a['header']:
        raise ToolError('only a single-block circular body is supported')
    ops = {o['id']: o for o in a['instructions']}
    order = [i for i in a['body_order'] if not ops[i]['meta'] and not ops[i]['configuration']]
    if not order: raise ToolError('empty executable body')
    work, memory, unsupported = {}, {}, []
    for id_ in order:
        try:
            work[id_] = work_for_instruction(ops[id_])
            memory[id_] = memory_work(ops[id_], work[id_], a['vlen'])
        except ToolError as exc: unsupported.append(f'op {id_} {ops[id_]["opcode"]}: {exc}')
    if unsupported: raise ToolError('unsupported hardware coverage: ' + '; '.join(unsupported))
    rows, features = [], zero()
    coverage = dict(configuration_policy='excluded-from-body', register=a['register_coverage'],
                    memory=a['memory_coverage'], unsupported=[])
    for id_ in order:
        f = zero()
        for part in work[id_]['components']:
            if part['cost_class'] != 'memory': f['basic_' + part['cost_class']] += part['work']
        m = memory[id_]
        if m:
            f['memory_requests'] = m['requests']
        row = dict(id=id_, mir=ops[id_]['mir'], opcode=ops[id_]['opcode'], hardware=work[id_], features=f,
                   memory=m, category=category(ops[id_], m))
        rows.append(row)
        for p in PARAMETERS: features[p] += f[p]
    main, remainder, scope = iteration_factors(a)
    body_features = dict(features)
    for p in PARAMETERS: features[p] *= main
    config_ids = [i for i in a['body_order'] if ops[i]['configuration']]
    setup_blocks = {b['id'] for b in a['blocks'] if b['role'] == 'setup'}
    setup_ids = [o['id'] for o in a['instructions'] if o['block'] in setup_blocks and o['configuration']]
    additions = dict(configuration=0., scalar_tail=0., setup_configuration=0.)
    if config_ids or setup_ids:
        unit = a['middle_end']['configuration_unit_quarters']
        if unit is None: raise ToolError('missing middle-end configuration unit')
        additions['configuration'] = main * len(config_ids) * unit / 4
        # An unknown exact trip count yields a steady-state score; one-time
        # work has no known amortization denominator and remains reported.
        if a['exact_trip_count']: additions['setup_configuration'] = len(setup_ids) * unit / 4
    if remainder:
        scalar = a.get('scalar_cost')
        if scalar is None: raise ToolError('missing middle-end scalar iteration cost for remainder')
        additions['scalar_tail'] = scalar * remainder
    features['middle_end_scale'] = sum(additions.values())
    return dict(identity=identity(),
                candidate=a['candidate'], vf=('s' if a['scalable'] else 'f') + str(a['vf']),
                compiler=a['compiler'], cpu=a['cpu'], vlen=a['vlen'], stage=a['stage'],
                run_id=a['run_id'], iteration_width=a['iteration_width'], scope=scope,
                exact_trip_count=a['exact_trip_count'], max_trip_count=a['max_trip_count'],
                body_iterations=main, scalar_remainder=remainder if a['exact_trip_count'] else None, features=features,
                body_features=body_features, ops=rows, coverage=coverage,
                middle_end=dict(source=a['middle_end'], scalar_source='CM.expectedCost(f1)',
                                scalar_unit='TTI-reciprocal-throughput-per-original-iteration',
                                configuration_ids=config_ids, setup_configuration_ids=setup_ids,
                                unknown_setup_amortization=not a['exact_trip_count'] and bool(setup_ids),
                                scalar_tail_scope='exact-remainder' if a['exact_trip_count'] else 'excluded-from-steady-state-score; runtime remainder unknown',
                                unscaled_additions=additions))


def score_features(report):
    # A new immutable calculation result for reporting, no stale cached scores.
    value = json.loads(json.dumps(report))
    value['coefficients'] = dict(COEFFICIENTS)
    value['parameter_digest'] = digest_json(machine_parameters())
    for row in value['ops']:
        f = row['features']
        row['basic'] = sum(f[p] * COEFFICIENTS[p] for p in PARAMETERS if p.startswith('basic_'))
        row['cost'] = dot(f)
    value['basic'] = sum(op['basic'] for op in value['ops'])
    value['body_cost'] = sum(op['cost'] for op in value['ops'])
    groups = {}
    for op in value['ops']:
        group = groups.setdefault(op['category'], dict(instructions=0, cost=0., bytes=0, upper_bound_bytes=False))
        group['instructions'] += 1
        group['cost'] += op['cost']
        if op['memory']:
            group['bytes'] += op['memory']['bytes']
            group['upper_bound_bytes'] |= op['memory']['bytes_kind'] != 'exact'
    value['body_breakdown'] = groups
    value['middle_end_cost'] = dot(value['features']) - value['body_iterations'] * value['body_cost']
    value['score'] = dot(value['features'])
    value['diagnostics'] = dict(negative_ops=[op['id'] for op in value['ops'] if op['basic'] < 0],
                               negative_body=value['body_cost'] < 0, negative_score=value['score'] < 0,
                               unit='model-effect; not CPU cycles')
    if not math.isfinite(value['score']): raise ToolError('nonfinite model score')
    if not math.isclose(value['body_cost'], dot(value['body_features']), abs_tol=1e-8):
        raise ToolError('op/body reconciliation failed')
    return value


def score_observation(a):
    return score_features(features_for_observation(a))
