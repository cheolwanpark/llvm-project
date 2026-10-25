"""Machine-independent descriptions of instruction expansion and execution demand."""
from dataclasses import asdict, dataclass
from fractions import Fraction as Q
import operator

from model_errors import ToolError


@dataclass(frozen=True)
class Evidence:
    source: str
    note: str = ''
    assumed: bool = False


@dataclass(frozen=True)
class Port:
    name: str
    capacity: Q
    evidence: Evidence


@dataclass(frozen=True)
class ServiceClass:
    name: str
    ports: tuple[str, ...]
    evidence: Evidence
    unit: str = 'operation'
    demand_per_unit: 'int | Q | Expr' = 1


@dataclass(frozen=True)
class Timing:
    """Per-uop result latency and start-to-start interval, in cycles.

Latency is never divided by pipeline depth on a dependency path. These are
nominal estimates, not measured instruction timings or port capacities.
"""
    latency: int
    initiation_interval: int
    pipelined: bool | None
    evidence: Evidence
    rtl_latency: int | None = None
    configuration: str = ''

    def __post_init__(self):
        if self.latency < 1 or self.initiation_interval < 1:
            raise ToolError('timing latency and initiation interval must be positive')

    def span(self, count, serial=False):
        if type(count) is not int or count < 0:
            raise ToolError('timing needs a nonnegative integer uop count')
        if count == 0:
            return 0
        return self.latency + (count - 1) * (max(self.latency, self.initiation_interval)
                                             if serial else self.initiation_interval)


@dataclass(frozen=True)
class Expr:
    """Small arithmetic tree. Strings are geometry variables, never Python code."""
    op: str
    args: tuple

    def evaluate(self, geometry):
        def value(x):
            if isinstance(x, Expr): return x.evaluate(geometry)
            if isinstance(x, str): return Q(geometry[x])
            return Q(x)
        if self.op == 'lookup':
            key, table = self.args
            return value(dict(table)[value(key)])
        if self.op == 'if':
            condition, yes, no = self.args
            return value(yes if value(condition) else no)
        args = [value(x) for x in self.args]
        operations = {'add': operator.add, 'sub': operator.sub, 'mul': operator.mul,
                      'div': operator.truediv, 'mod': operator.mod, 'max': max,
                      'min': min, 'ge': operator.ge, 'eq': operator.eq,
                      'ne': operator.ne, 'and': lambda a, b: bool(a and b)}
        return Q(operations[self.op](*args))


def expr(op, *args): return Expr(op, args)


@dataclass(frozen=True)
class Machine:
    name: str
    revision: str
    vlen: int
    elen: int
    ports: tuple[Port, ...]
    classes: tuple[ServiceClass, ...]

    def __post_init__(self):
        ports = {p.name for p in self.ports}
        if len(ports) != len(self.ports) or any(p.capacity <= 0 for p in self.ports):
            raise ToolError('duplicate port or nonpositive capacity')
        if len({c.name for c in self.classes}) != len(self.classes):
            raise ToolError('duplicate uop class')
        for c in self.classes:
            if not c.ports or len(set(c.ports)) != len(c.ports) or not set(c.ports) <= ports:
                raise ToolError('invalid possible ports for ' + c.name)


def number(value):
    """Lossless JSON scalar; floats are reserved for presentation."""
    value = Q(value)
    return int(value) if value.denominator == 1 else str(value)


@dataclass(frozen=True)
class ResourceUse:
    demand_key: str
    possible_ports: tuple[str, ...]
    work_units: Q
    work_unit: str
    demand_per_work_unit: Q
    demand_basis: str
    evidence: tuple[Evidence, ...]

    def __post_init__(self):
        object.__setattr__(self, 'work_units', Q(self.work_units))
        object.__setattr__(self, 'demand_per_work_unit', Q(self.demand_per_work_unit))
        if self.work_units < 0 or self.demand_per_work_unit <= 0:
            raise ToolError('invalid resource work/rate')
        if not self.possible_ports or len(set(self.possible_ports)) != len(self.possible_ports):
            raise ToolError('invalid resource possible ports')
        if self.demand_basis not in ('rtl-derived', 'assumed', 'calibrated'):
            raise ToolError('invalid demand basis')

    @property
    def demand(self):
        return self.work_units * self.demand_per_work_unit


@dataclass(frozen=True)
class Uop:
    mir_id: int
    ordinal: int
    kind: str
    origin: str
    geometry: tuple[tuple[str, Q], ...]
    resource_uses: tuple[ResourceUse, ...]
    # One group reference per ResourceUse, in the same order. A store has two.
    timing_group_ids: tuple[str, ...]
    evidence: tuple[Evidence, ...]
    assumptions: tuple[str, ...] = ()

    def __post_init__(self):
        if self.origin not in ('rtl-derived', 'assumed', 'fallback'):
            raise ToolError('invalid uop origin')
        if len(self.resource_uses) != len(self.timing_group_ids):
            raise ToolError('resource/timing group references disagree')

    @property
    def demand(self):
        return sum((r.demand for r in self.resource_uses), Q(0))


@dataclass(frozen=True)
class TimingGroup:
    id: str
    demand_key: str
    timing: Timing
    serial: bool = False
    transfer_prefix: bool = False


@dataclass(frozen=True)
class InstructionExpansion:
    mir_id: int
    rule_id: str
    uops: tuple[Uop, ...]
    verified_decode_uops: int | None
    timing_groups: tuple[TimingGroup, ...]
    completion_policy: str = 'transfer-prefix + max(primary-components)'
    assumptions: tuple[str, ...] = ()

    def __post_init__(self):
        if [(u.mir_id, u.ordinal) for u in self.uops] != [(self.mir_id, i) for i in range(len(self.uops))]:
            raise ToolError('unstable uop identity/order')
        if self.verified_decode_uops is not None and self.verified_decode_uops != len(self.uops):
            raise ToolError('verified decode count differs from expansion')
        groups = {g.id: g for g in self.timing_groups}
        if len(groups) != len(self.timing_groups):
            raise ToolError('duplicate timing group')
        referenced = set()
        for u in self.uops:
            for r, gid in zip(u.resource_uses, u.timing_group_ids, strict=True):
                if gid not in groups or groups[gid].demand_key != r.demand_key:
                    raise ToolError('invalid timing group reference')
                referenced.add(gid)
        if referenced != set(groups):
            raise ToolError('unused timing group')


@dataclass(frozen=True)
class PortDemandSummary:
    class_demands: tuple[tuple[str, Q], ...]
    port_demands: tuple[tuple[str, Q], ...]
    normalized_port_demands: tuple[tuple[str, Q], ...]


def accumulate_port_demands(expansions, machine):
    """Required resources add; alternatives share demand before normalization."""
    raw = dict.fromkeys((p.name for p in machine.ports), Q(0))
    classes = {}
    for expansion in expansions:
        for uop in expansion.uops:
            for use in uop.resource_uses:
                classes[use.demand_key] = classes.get(use.demand_key, Q(0)) + use.demand
                for port in use.possible_ports:
                    if port not in raw:
                        raise ToolError('unknown resource port: ' + port)
                    raw[port] += use.demand / len(use.possible_ports)
    return PortDemandSummary(tuple(classes.items()), tuple(raw.items()),
                             tuple((p.name, raw[p.name] / p.capacity) for p in machine.ports))


def aggregate_demand(summary, mode):
    values = [v for _, v in summary.normalized_port_demands]
    if mode == 'max':
        return max(values, default=Q(0))
    if mode == 'sum':
        return sum(values, Q(0))
    raise ToolError('unsupported demand aggregation: ' + mode)


def instruction_latency(expansion):
    """MIR readiness from resource work, independently of demand coefficients."""
    if expansion.completion_policy != 'transfer-prefix + max(primary-components)':
        raise ToolError('unsupported completion policy')
    work = dict.fromkeys((g.id for g in expansion.timing_groups), Q(0))
    for u in expansion.uops:
        for r, gid in zip(u.resource_uses, u.timing_group_ids, strict=True):
            work[gid] += r.work_units
    rows = []
    for g in expansion.timing_groups:
        count = work[g.id]
        if count.denominator != 1:
            raise ToolError('instruction latency requires integral physical work units')
        rows.append(dict(id=g.id, demand_key=g.demand_key, work_units=int(count),
                         **asdict(g.timing), completion_cycles=g.timing.span(int(count), g.serial),
                         expansion='serial-upper-estimate' if g.serial else 'pipeline-span',
                         transfer_prefix=g.transfer_prefix))
    transfers = sum(r['completion_cycles'] for r in rows if r['transfer_prefix'])
    primary = max((r['completion_cycles'] for r in rows if not r['transfer_prefix']), default=0)
    return dict(latency=transfers + primary, groups=rows,
                combination=expansion.completion_policy,
                assumptions=['Whole-instruction readiness; no lane streaming or multi-EXU uop striping.',
                    'No bypass-specific operand latencies; not a measured CPU cycle prediction.'] +
                    (['Dependent split uops conservatively serialized; exact internal DAG is not collected.']
                     if any(g.serial for g in expansion.timing_groups) else []),
                fallback=any(g.demand_key in ('unknown', 'csr', 'fence') for g in expansion.timing_groups))


def expansion_report(expansion):
    """Serialize only derived quantities; there is no second reporting scorer."""
    uops = []
    for u in expansion.uops:
        uses = []
        for r in u.resource_uses:
            uses.append(dict(demand_key=r.demand_key, possible_ports=list(r.possible_ports),
                work_units=number(r.work_units), work_unit=r.work_unit,
                demand_per_work_unit=number(r.demand_per_work_unit), demand=number(r.demand),
                demand_basis=r.demand_basis, evidence=[asdict(e) for e in r.evidence],
                per_port={p: str(r.demand / len(r.possible_ports)) for p in r.possible_ports}))
        uops.append(dict(id=[u.mir_id, u.ordinal], kind=u.kind, origin=u.origin,
            geometry={k: number(v) for k, v in u.geometry}, resource_uses=uses,
            timing_group_ids=list(u.timing_group_ids), demand=number(u.demand),
            evidence=[asdict(e) for e in u.evidence], assumptions=list(u.assumptions)))
    timing = instruction_latency(expansion)
    return dict(uops=uops, expansion=dict(rule_id=expansion.rule_id,
        modeled_uop_count=len(uops), verified_decode_uops=expansion.verified_decode_uops,
        timing_groups=timing['groups'], completion_policy=expansion.completion_policy,
        assumptions=list(expansion.assumptions)), timing=timing)


def expansion_from_report(row):
    """Validate persisted uops, including all redundant work/demand/timing fields."""
    try:
        uops = []
        for u in row['uops']:
            uses = tuple(ResourceUse(r['demand_key'], tuple(r['possible_ports']), Q(r['work_units']),
                r['work_unit'], Q(r['demand_per_work_unit']), r['demand_basis'],
                tuple(Evidence(**e) for e in r['evidence'])) for r in u['resource_uses'])
            uops.append(Uop(*u['id'], u['kind'], u['origin'],
                tuple((k, Q(v)) for k, v in u['geometry'].items()), uses,
                tuple(u['timing_group_ids']), tuple(Evidence(**e) for e in u['evidence']),
                tuple(u['assumptions'])))
        meta = row['expansion']
        groups = []
        for g in meta['timing_groups']:
            timing = Timing(g['latency'], g['initiation_interval'], g['pipelined'],
                            Evidence(**g['evidence']), g['rtl_latency'], g['configuration'])
            groups.append(TimingGroup(g['id'], g['demand_key'], timing,
                g['expansion'] == 'serial-upper-estimate', g['transfer_prefix']))
        expansion = InstructionExpansion(row['id'], meta['rule_id'], tuple(uops),
            meta['verified_decode_uops'], tuple(groups), meta['completion_policy'], tuple(meta['assumptions']))
        expected = expansion_report(expansion)
        if any(row[k] != v for k, v in expected.items()):
            raise ToolError('inconsistent persisted uop work/demand/timing')
        return expansion
    except (KeyError, TypeError, ValueError, ZeroDivisionError) as exc:
        raise ToolError(f'invalid uop report: {exc}') from exc
