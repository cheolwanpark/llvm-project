"""Machine-independent descriptions of instruction expansion and execution demand."""
from dataclasses import asdict, dataclass, field
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
class Demand:
    service_class: str
    work: int | Q | Expr


@dataclass(frozen=True)
class InstructionRule:
    name: str
    components: tuple[Demand, ...]
    evidence: Evidence


@dataclass(frozen=True)
class ResolvedInstruction:
    rule: InstructionRule
    geometry: dict = field(default_factory=dict)
    assumptions: tuple[str, ...] = ()


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

    def expand(self, instruction):
        classes = {c.name: c for c in self.classes}
        rule, geometry = instruction.rule, instruction.geometry
        amounts, ports, components = {}, {}, []
        assumptions = list(instruction.assumptions)
        if rule.evidence.assumed: assumptions.append(rule.evidence.note)
        def evaluate(x):
            try:
                return x.evaluate(geometry) if isinstance(x, Expr) else Q(x)
            except (KeyError, TypeError, ValueError, ZeroDivisionError) as exc:
                raise ToolError(f'{rule.name}: invalid/missing geometry: {exc}') from exc
        def number(x):
            return int(x) if x.denominator == 1 else str(x)
        for component in rule.components:
            work = evaluate(component.work)
            c = classes[component.service_class]
            rate = evaluate(c.demand_per_unit)
            if work < 0 or rate <= 0:
                raise ToolError(f'{rule.name}: invalid service work/rate {work}/{rate}')
            amount = work * rate
            if c.evidence.assumed: assumptions.append(c.evidence.note)
            amounts[c.name] = amounts.get(c.name, Q(0)) + amount
            share = amount / len(c.ports)
            for p in c.ports: ports[p] = ports.get(p, Q(0)) + share
            components.append(dict(service_class=c.name, work_units=number(work), work_unit=c.unit,
                                   demand_per_unit=number(rate), demand=number(amount),
                                   possible_ports=list(c.ports), per_port=str(share),
                                   evidence=asdict(c.evidence)))
        return dict(rule=rule.name, source=rule.evidence.source, geometry={k: str(v) for k, v in geometry.items()},
                    demand_unit='normalized service cycles (ALU II=1)', components=components,
                    class_demands={k: number(v) for k, v in amounts.items()},
                    port_demands={k: str(v) for k, v in ports.items()},
                    assumptions=sorted(set(assumptions)))

    def distribute(self, classes):
        """Use exact fractions through the equal-share and capacity calculation."""
        raw = dict.fromkeys((p.name for p in self.ports), Q(0))
        for c in self.classes:
            share = Q(classes.get(c.name, 0)) / len(c.ports)
            for p in c.ports: raw[p] += share
        if set(classes) - {c.name for c in self.classes}: raise ToolError('unknown demand class')
        return raw, {p.name: raw[p.name] / p.capacity for p in self.ports}
