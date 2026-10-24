"""One port-aware scorer for reports, selection, replay and affine analysis."""
from dataclasses import asdict, dataclass
from fractions import Fraction as Q
import hashlib
import json
import math
from pathlib import Path

from kunminghu_v2 import DATASHEET_DIGEST, MACHINE, work_for_instruction
from model_errors import ToolError
from observations import SCHEMA, STAGE, iteration_factors, validate_observation

MODEL_VERSION = 'mir-port-aware-v1'
AGGREGATIONS = ('max', 'sum')
IMPLEMENTATION_DIGEST = hashlib.sha256(Path(__file__).read_bytes() +
    Path(__file__).with_name('hardware_model.py').read_bytes()).hexdigest()


@dataclass(frozen=True)
class Settings:
    aggregation: str = 'max'
    body_scale: str = '1'

    def __post_init__(self):
        try:
            scale = Q(self.body_scale)
        except (ValueError, TypeError, ZeroDivisionError) as exc:
            raise ToolError('body scale must be a finite nonnegative number or fraction') from exc
        if self.aggregation not in AGGREGATIONS or scale < 0:
            raise ToolError('invalid aggregation/body scale')
        object.__setattr__(self, 'body_scale', str(scale))

    @classmethod
    def from_args(cls, args):
        return cls(args.aggregation, args.body_scale)


def add_arguments(parser):
    parser.add_argument('--aggregation', choices=AGGREGATIONS, default='max')
    parser.add_argument('--body-scale', default='1', help='nonnegative body multiplier; fractions accepted')


def settings_flags(settings):
    return ['--aggregation', settings.aggregation, '--body-scale', settings.body_scale]


def digest_json(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()).hexdigest()


def identity(settings=Settings()):
    return dict(model=MODEL_VERSION, implementation_digest=IMPLEMENTATION_DIGEST,
                datasheet_digest=DATASHEET_DIGEST, rtl_revision=MACHINE.revision,
                observation_schema=SCHEMA, stage=STAGE,
                machine_parameters=dict(cpu=MACHINE.name, vlen=MACHINE.vlen,
                    settings=asdict(settings), coefficients=dict(body_scale=settings.body_scale, fixed_additions=1),
                    ports=[dict(name=p.name, capacity=str(p.capacity), evidence=asdict(p.evidence)) for p in MACHINE.ports]))


def aggregate(ports, settings):
    values = [float(Q(v)) for v in ports.values()]
    if any(not math.isfinite(x) or x < 0 for x in values): raise ToolError('invalid port demand')
    result = max(values, default=0.) if settings.aggregation == 'max' else math.fsum(values)
    if not math.isfinite(result): raise ToolError('nonfinite aggregate')
    return result


def score_value(features, settings=Settings()):
    """Exact affine arithmetic on the persisted (possibly rounded) features."""
    return Q(features['body_scale']) * Q(settings.body_scale) + Q(features['fixed_additions'])


def ranking_score(report): return Q(report['score_exact'])


def rescore(report, settings=Settings()):
    value = dict(report)
    value['identity'] = identity(settings)
    value['coefficients'] = dict(body_scale=settings.body_scale, fixed_additions=1)
    value['body_cost'] = aggregate(value['normalized_port_demands'], settings)
    value['features'] = dict(body_scale=value['body_iterations'] * value['body_cost'],
                             fixed_additions=sum(value['middle_end']['unscaled_additions'].values()))
    value['middle_end_cost'] = value['features']['fixed_additions']
    exact = score_value(value['features'], settings)
    value['score_exact'], value['score'] = str(exact), float(exact)
    if not math.isfinite(value['score']): raise ToolError('nonfinite model score')
    return value


def score_observation(a, settings=Settings()):
    validate_observation(a)
    if a['error']: raise ToolError(a['error'])
    if a['vlen'] != MACHINE.vlen or a['cpu'] != MACHINE.name: raise ToolError('datasheet target mismatch')
    if not a['iteration_mapping']: raise ToolError('unproven scalar iteration mapping')
    body = [b for b in a['blocks'] if b['role'] == 'body']
    if len(body) != 1 or body[0]['id'] != a['header']: raise ToolError('only a single-block circular body is supported')
    ops = {o['id']: o for o in a['instructions']}
    order = [i for i in a['body_order'] if not ops[i]['meta'] and not ops[i]['configuration']]
    if not order: raise ToolError('empty executable body')
    rows, classes = [], {}
    for id_ in order:
        op = ops[id_]
        try:
            work = work_for_instruction(op)
        except ToolError as exc:
            raise ToolError(f'op {id_} {op["opcode"]}: {exc}') from exc
        rows.append(dict(id=id_, mir=op['mir'], opcode=op['opcode'], hardware=work,
                         spill_slot=any(m.get('spill_slot', False) for m in op['memory'])))
        for name, amount in work['class_demands'].items(): classes[name] = classes.get(name, 0) + amount
    raw, normalized = MACHINE.distribute(classes)
    maximum = max(normalized.values())
    report = dict(candidate=a['candidate'], vf=('s' if a['scalable'] else 'f') + str(a['vf']),
        compiler=a['compiler'], run_id=a['run_id'], cpu=a['cpu'], vlen=a['vlen'], stage=a['stage'],
        iteration_width=a['iteration_width'], exact_trip_count=a['exact_trip_count'], max_trip_count=a['max_trip_count'],
        class_demands=classes, port_demands={p: str(v) for p, v in raw.items()},
        normalized_port_demands={p: str(v) for p, v in normalized.items()},
        bottleneck_ports=[p for p, v in normalized.items() if maximum and v == maximum], ops=rows,
        coverage=dict(register=a['register_coverage'], memory=a['memory_coverage'],
            unknown_ops=[r['id'] for r in rows if 'unknown' in r['hardware']['class_demands']],
            assumed_ops=[dict(id=r['id'], opcode=r['opcode'], assumptions=r['hardware']['assumptions'])
                         for r in rows if r['hardware']['assumptions']],
            configuration_policy='excluded-from-body'),
        diagnostics=dict(unit='capacity-normalized uop-demand proxy; not predicted CPU cycles',
                         memory_requests='excluded', scheduling='equal shares; no dynamic scheduling'))
    # Iteration/configuration/tail accounting is unchanged from v4.
    main, remainder, scope = iteration_factors(a)
    config_ids = [i for i in a['body_order'] if ops[i]['configuration']]
    setup_blocks = {b['id'] for b in a['blocks'] if b['role'] == 'setup'}
    setup_ids = [o['id'] for o in a['instructions'] if o['block'] in setup_blocks and o['configuration']]
    additions = dict(configuration=0., scalar_tail=0., setup_configuration=0.)
    if config_ids or setup_ids:
        unit = a['middle_end']['configuration_unit_quarters']
        if unit is None: raise ToolError('missing middle-end configuration unit')
        additions['configuration'] = main * len(config_ids) * unit / 4
        if a['exact_trip_count']: additions['setup_configuration'] = len(setup_ids) * unit / 4
    if remainder:
        scalar = a.get('scalar_cost')
        if scalar is None: raise ToolError('missing middle-end scalar iteration cost for remainder')
        additions['scalar_tail'] = scalar * remainder
    report.update(body_iterations=main, scalar_remainder=remainder if a['exact_trip_count'] else None, scope=scope,
        middle_end=dict(source=a['middle_end'], scalar_source='CM.expectedCost(f1)',
            scalar_unit='TTI-reciprocal-throughput-per-original-iteration', configuration_ids=config_ids,
            setup_configuration_ids=setup_ids,
            unknown_setup_amortization=not a['exact_trip_count'] and bool(setup_ids),
            scalar_tail_scope='exact-remainder' if a['exact_trip_count'] else 'excluded-from-steady-state-score; runtime remainder unknown',
            unscaled_additions=additions))
    return rescore(report, settings)
