"""Calibrated decoder work with a single shared reporting/selection calculation."""
import hashlib
import json
import math
from pathlib import Path

from dependencies import Dependencies
from hardware import RULE_DIGEST, RULE_VERSION, REVISION, can_overlap, work_for_instruction
from model_errors import ToolError
from observations import SCHEMA, STAGE, iteration_factors, validate_observation

MODEL_VERSION = 'mir-basic-calibrated-v1'

# XiangShan MinimalConfig, VLEN 128. The memory/move scales were selected on
# search-dataset.sqlite (memory_triple_move_double, window 0). These are shared
# model weights, not hardware latencies or cycle predictions. Decoder facts
# remain in hardware.py. Pair coefficients are retained for nonzero windows.
FORWARD_WINDOW = 0
BACKWARD_WINDOW = 0
COEFFICIENTS = {
    'basic_convert': 1.,
    'basic_divide': 1.,
    'basic_fp_alu': 1.,
    'basic_fp_multiply': 1.,
    'basic_integer': 1.,
    'basic_mask': 1.,
    'basic_memory': 3.,
    'basic_move': 2.,
    'basic_multiply': 1.,
    'basic_permute': 1.,
    'basic_scalar': 1.,  # Reference unit.
    'contention': .25,
    'raw': .25,
    'ilp': .125,
    'middle_end_scale': 1.,
}
PARAMETERS = tuple(COEFFICIENTS)
IMPLEMENTATION_DIGEST = hashlib.sha256(Path(__file__).read_bytes() + Path(__file__).with_name('dependencies.py').read_bytes()).hexdigest()


def digest_json(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()).hexdigest()


def machine_parameters():
    return dict(cpu='xiangshan-kunminghu', vlen=128, forward_window=FORWARD_WINDOW,
                backward_window=BACKWARD_WINDOW, coefficients=dict(COEFFICIENTS),
                pair_work='min', contention_work='sum-shared-class-min-component-work',
                accumulation='sum', raw_contention='add',
                configuration=True, scalar_tail=True, distance='op-count',
                unknown_ilp='exclude', configuration_ops='excluded-from-body-and-windows')


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
    work, unsupported = {}, []
    for id_ in order:
        try: work[id_] = work_for_instruction(ops[id_])
        except ToolError as exc: unsupported.append(f'op {id_} {ops[id_]["opcode"]}: {exc}')
    if unsupported: raise ToolError('unsupported hardware coverage: ' + '; '.join(unsupported))
    pair_windows = [(direction, size) for direction, size in
                    (('forward', FORWARD_WINDOW), ('backward', BACKWARD_WINDOW)) if size]
    # Window 0 uses decoder work alone. Avoid building dependency graphs and
    # pair-only class aggregates as well as overlap checks and pair traversal.
    class_work = {}
    if pair_windows:
        for id_, item in work.items():
            class_work[id_] = {}
            for part in item['components']:
                cls = part['cost_class']
                class_work[id_][cls] = class_work[id_].get(cls, 0) + part['work']
        dep = Dependencies(a)
    rows, pairs, features = [], [], zero()
    # With no pair analysis these counters mean unexamined, not independent.
    coverage = dict(unknown_dependency=0, unknown_overlap=0, independent=0, dependent=0,
                    configuration_policy='excluded-from-body-and-windows', register=a['register_coverage'],
                    memory=a['memory_coverage'], unsupported=[])
    for index, id_ in enumerate(order):
        f = zero()
        for part in work[id_]['components']: f['basic_' + part['cost_class']] += part['work']
        row = dict(id=id_, mir=ops[id_]['mir'], opcode=ops[id_]['opcode'], hardware=work[id_], features=f)
        rows.append(row)
        # Anchors always belong to iteration 0. Neighbor identities retain
        # iteration offsets even when a window traverses several full loops.
        for direction, size in pair_windows:
            for distance in range(1, size + 1):
                offset, j = divmod(index + (distance if direction == 'forward' else -distance), len(order))
                other = order[j]
                relation = dep.relation((id_, 0), (other, offset))
                overlap = can_overlap(work[id_], work[other])
                shared = sorted(class_work[id_].keys() & class_work[other].keys())
                # Attribute contention to shared class work only; RAW and ILP
                # retain the full-op minimum. This is a modeling assumption.
                contention_amount = sum(min(class_work[id_][cls], class_work[other][cls]) for cls in shared)
                # Eligible effects intentionally coexist. Forward and backward
                # effects use their own anchored dynamic pair identity.
                contention = bool(shared) and direction == 'forward'
                raw = relation['raw'] and direction == 'forward'
                ilp = relation['independence'] == 'independent' and overlap is True and direction == 'backward'
                pf = zero()
                amount_a, amount_b = work[id_]['decode_uops'], work[other]['decode_uops']
                amount = min(amount_a, amount_b)
                if contention: pf['contention'] = contention_amount
                if raw: pf['raw'] = amount
                if ilp: pf['ilp'] = -amount
                for p in PARAMETERS: f[p] += pf[p]
                coverage['unknown_dependency'] += relation['independence'] == 'unknown'
                coverage['unknown_overlap'] += overlap is None
                coverage['independent'] += relation['independence'] == 'independent'
                coverage['dependent'] += relation['independence'] == 'dependent'
                pairs.append(dict(anchor=id_, other=other, iteration_offset=offset, direction=direction,
                                  distance=distance, dependency=relation, overlap=overlap,
                                  shared_classes=shared, pair_work=amount,
                                  contention_work=contention_amount, features=pf))
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
                body_features=body_features, ops=rows, pairs=pairs, coverage=coverage,
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
        row.update(basic=sum(f[p] * COEFFICIENTS[p] for p in PARAMETERS if p.startswith('basic_')),
                   stall=f['contention'] * COEFFICIENTS['contention'] + f['raw'] * COEFFICIENTS['raw'],
                   ilp=-f['ilp'] * COEFFICIENTS['ilp'], net=dot(f))
    for pair in value['pairs']:
        pair['contributions'] = {p: pair['features'][p] * COEFFICIENTS[p] for p in ('contention', 'raw', 'ilp')}
        pair['net'] = sum(pair['contributions'].values())
    value['basic'] = sum(op['basic'] for op in value['ops'])
    value['stall'] = sum(op['stall'] for op in value['ops'])
    value['ilp'] = sum(op['ilp'] for op in value['ops'])
    value['body_cost'] = sum(op['net'] for op in value['ops'])
    value['middle_end_cost'] = dot(value['features']) - value['body_iterations'] * value['body_cost']
    value['score'] = dot(value['features'])
    value['diagnostics'] = dict(negative_ops=[op['id'] for op in value['ops'] if op['net'] < 0],
                               negative_body=value['body_cost'] < 0, negative_score=value['score'] < 0,
                               ilp_fraction=value['ilp'] / (value['basic'] + value['stall']) if value['basic'] + value['stall'] else None,
                               bounded=False, unit='model-effect; not CPU cycles')
    if not math.isfinite(value['score']): raise ToolError('nonfinite model score')
    if not math.isclose(value['body_cost'], value['basic'] + value['stall'] - value['ilp'], abs_tol=1e-8):
        raise ToolError('op/body reconciliation failed')
    return value


def score_observation(a):
    return score_features(features_for_observation(a))
