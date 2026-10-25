"""Resource demand and finite-window scorer shared by reporting and selection."""
from dataclasses import asdict, dataclass
from fractions import Fraction as Q
import hashlib
import json
import math
from pathlib import Path

from kunminghu_v2 import (DATASHEET_DIGEST, EXPANSION_VERSION, LLVM_VSCALE, MACHINE,
                         MAX_STACK_ACCESS_BYTES, ROB_ENTRIES, ROB_EVIDENCE, expand_instruction)
from hardware_model import (accumulate_port_demands, aggregate_demand, expansion_from_report,
                            expansion_report, number)
from dependencies import longest_path, prepare_dependencies
from model_errors import ToolError
from observations import SCHEMA, STAGE, iteration_factors, validate_observation

MODEL_VERSION = 'mir-uop-demand-v1'
DEMAND_SCHEMA = 'uop-demand-report-v1'
IMPLEMENTATION_DIGEST = hashlib.sha256(Path(__file__).read_bytes() +
    Path(__file__).with_name('hardware_model.py').read_bytes() +
    Path(__file__).with_name('dependencies.py').read_bytes() +
    Path(__file__).with_name('observations.py').read_bytes() +
    Path(__file__).with_name('selection.py').read_bytes()).hexdigest()


@dataclass(frozen=True)
class Settings:
    body_scale: str = '1'
    aggregation: str = 'max'
    window: str = 'enabled'

    def __post_init__(self):
        try:
            scale = Q(self.body_scale)
        except (ValueError, TypeError, ZeroDivisionError) as exc:
            raise ToolError('body scale must be a finite nonnegative number or fraction') from exc
        if scale < 0:
            raise ToolError('body scale must be nonnegative')
        object.__setattr__(self, 'body_scale', str(scale))
        if (self.aggregation, self.window) not in (('max', 'enabled'), ('max', 'disabled'), ('sum', 'disabled')):
            raise ToolError('supported policies: max/enabled, max/disabled, sum/disabled')

    @classmethod
    def from_args(cls, args):
        return cls(body_scale=args.body_scale, aggregation=args.aggregation, window=args.window)


def add_arguments(parser):
    parser.add_argument('--body-scale', default='1', help='nonnegative body multiplier; fractions accepted')
    parser.add_argument('--aggregation', choices=('max', 'sum'), default='max')
    parser.add_argument('--window', choices=('enabled', 'disabled'), default='enabled')


def settings_flags(settings):
    return ['--body-scale', settings.body_scale, '--aggregation', settings.aggregation, '--window', settings.window]


def digest_json(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()).hexdigest()


def identity(settings=Settings()):
    return dict(model=MODEL_VERSION, implementation_digest=IMPLEMENTATION_DIGEST,
                datasheet_digest=DATASHEET_DIGEST, rtl_revision=MACHINE.revision,
                expansion_version=EXPANSION_VERSION, arithmetic='fraction-v1', datasheet='nominal',
                observation_schema=SCHEMA, stage=STAGE,
                machine_parameters=dict(cpu=MACHINE.name, vlen=MACHINE.vlen,
                    rob_entries=ROB_ENTRIES, rob_evidence=asdict(ROB_EVIDENCE),
                    settings=asdict(settings), coefficients=dict(body_scale=settings.body_scale, fixed_additions=1),
                    ports=[dict(name=p.name, capacity=str(p.capacity), evidence=asdict(p.evidence)) for p in MACHINE.ports]))


def score_value(features, settings=Settings()):
    """Exact affine arithmetic on lossless persisted rational features."""
    return Q(features['body_scale']) * Q(settings.body_scale) + Q(features['fixed_additions'])


def ranking_score(report): return Q(report['score_exact'])


def rescore(report, settings=Settings()):
    if report.get('demand_schema') != DEMAND_SCHEMA:
        raise ToolError('uop model requires fresh expansions; rescore raw MIR observations')
    try:
        previous = Settings(**report['identity']['machine_parameters']['settings'])
        if report['identity'] != identity(previous):
            raise ToolError('incompatible saved uop model; rescore raw MIR observations')
    except (KeyError, TypeError) as exc:
        raise ToolError('missing saved model identity; rescore raw MIR observations') from exc
    if not all(k in report for k in ('dependency_path', 'dependency_graph', 'body_entries')):
        raise ToolError('model requires body/dependency facts; rescore raw MIR observations')
    expansions = [expansion_from_report(row) for row in report['ops']]
    summary = _demand_report(expansions)
    if any(report.get(k) != v for k, v in summary.items()):
        raise ToolError('persisted demand summary disagrees with uops')
    path = longest_path(report['dependency_graph'], {r['id']: r['timing']['latency'] for r in report['ops']})
    if path != report['dependency_path']:
        raise ToolError('persisted dependency path disagrees with uop timing')
    return _finish_score(report, settings)


def _demand_report(expansions):
    summary = accumulate_port_demands(expansions, MACHINE)
    maximum = aggregate_demand(summary, 'max')
    return dict(class_demands={k: number(v) for k, v in summary.class_demands},
        port_demands={p: str(v) for p, v in summary.port_demands},
        normalized_port_demands={p: str(v) for p, v in summary.normalized_port_demands},
        bottleneck_ports=[p for p, v in summary.normalized_port_demands if maximum and v == maximum],
        demand_max=number(maximum), demand_sum=number(aggregate_demand(summary, 'sum')))


def _finish_score(report, settings):
    value = dict(report)
    value['identity'] = identity(settings)
    value['coefficients'] = dict(body_scale=settings.body_scale, fixed_additions=1)
    if not all(k in value for k in ('dependency_path', 'dependency_graph', 'body_entries')):
        raise ToolError('window model requires body/dependency facts; rescore raw MIR observations')
    if value['dependency_graph']['coverage']['unsupported_stack_accesses']:
        raise ToolError('window model requires known, unconditional bounded stack accesses')
    if value['dependency_graph']['coverage']['unsupported_register_ops']:
        raise ToolError('window model requires complete register dependency facts')
    demand = Q(value['demand_max'] if settings.aggregation == 'max' else value['demand_sum'])
    # Whole-body ROB footprint, not split-uop work or just critical-path nodes.
    # This is an occupancy proxy, not recurrence or a simulated ROB schedule.
    window = (Q(value['body_entries'] * value['dependency_path']['cost'], ROB_ENTRIES)
              if settings.window == 'enabled' else None)
    body = max(demand, window) if window is not None else demand
    value['demand_cost'], value['window_cost'], value['body_cost'] = number(demand), number(window) if window is not None else None, number(body)
    value['features'] = dict(body_scale=number(Q(value['body_iterations']) * body),
        fixed_additions=number(sum((Q(v) for v in value['middle_end']['unscaled_additions'].values()), Q(0))))
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
    graph = prepare_dependencies(a, vscale=LLVM_VSCALE, max_stack_access_bytes=MAX_STACK_ACCESS_BYTES)
    rows, expansions = [], []
    for id_ in order:
        op = ops[id_]
        try:
            expansion = expand_instruction(op)
        except ToolError as exc:
            raise ToolError(f'op {id_} {op["opcode"]}: {exc}') from exc
        expansions.append(expansion)
        rows.append(dict(id=id_, mir=op['mir'], opcode=op['opcode'], **expansion_report(expansion),
                         spill_slot=any(m.get('spill_slot', False) for m in op['memory'])))
    report = dict(demand_schema=DEMAND_SCHEMA, candidate=a['candidate'], vf=('s' if a['scalable'] else 'f') + str(a['vf']),
        compiler=a['compiler'], run_id=a['run_id'], cpu=a['cpu'], vlen=a['vlen'], stage=a['stage'],
        iteration_width=a['iteration_width'], exact_trip_count=a['exact_trip_count'], max_trip_count=a['max_trip_count'],
        **_demand_report(expansions), ops=rows,
        body_entries=sum(not ops[i]['meta'] for i in a['body_order']), dependency_graph=graph,
        dependency_path=longest_path(graph, {r['id']: r['timing']['latency'] for r in rows}),
        coverage=dict(register=a['register_coverage'], memory=a['memory_coverage'],
            unknown_ops=[r['id'] for r in rows if any(use['demand_key'] == 'unknown'
                         for u in r['uops'] for use in u['resource_uses'])],
            timing_fallback_ops=[r['id'] for r in rows if r['timing']['fallback']],
            assumed_ops=[dict(id=r['id'], opcode=r['opcode'], assumptions=r['expansion']['assumptions'])
                         for r in rows if r['expansion']['assumptions']],
            configuration_policy='counted-in-ROB-footprint; charged-in-middle-end-additions'),
        diagnostics=dict(unit='demand/window cycle proxy; not predicted CPU cycles',
                         memory_requests='nominal aligned/full-active flows; no cache misses or replay',
                         service_policy='fixed RTL-derived nominal II; no fitted class weights',
                         scheduling='equal shares; no dynamic scheduling'))
    # Iteration/configuration/tail accounting is unchanged from v4.
    main, remainder, scope = iteration_factors(a)
    config_ids = [i for i in a['body_order'] if ops[i]['configuration']]
    setup_blocks = {b['id'] for b in a['blocks'] if b['role'] == 'setup'}
    setup_ids = [o['id'] for o in a['instructions'] if o['block'] in setup_blocks and o['configuration']]
    additions = dict(configuration=Q(0), scalar_tail=Q(0), setup_configuration=Q(0))
    if config_ids or setup_ids:
        unit = a['middle_end']['configuration_unit_quarters']
        if unit is None: raise ToolError('missing middle-end configuration unit')
        additions['configuration'] = main * len(config_ids) * Q(unit, 4)
        if a['exact_trip_count']: additions['setup_configuration'] = len(setup_ids) * Q(unit, 4)
    if remainder:
        scalar = a.get('scalar_cost')
        if scalar is None: raise ToolError('missing middle-end scalar iteration cost for remainder')
        additions['scalar_tail'] = Q(str(scalar)) * remainder
    report.update(body_iterations=number(main), scalar_remainder=remainder if a['exact_trip_count'] else None, scope=scope,
        middle_end=dict(source=a['middle_end'], scalar_source='CM.expectedCost(f1)',
            scalar_unit='TTI-reciprocal-throughput-per-original-iteration', configuration_ids=config_ids,
            setup_configuration_ids=setup_ids,
            unknown_setup_amortization=not a['exact_trip_count'] and bool(setup_ids),
            scalar_tail_scope='exact-remainder' if a['exact_trip_count'] else 'excluded-from-steady-state-score; runtime remainder unknown',
            unscaled_additions={k: number(v) for k, v in additions.items()}))
    return _finish_score(report, settings)
