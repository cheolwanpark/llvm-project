"""Memory replacement with independent service costs and maximum window demand.

A two-body scan exposes windows crossing the loop boundary. Service is counted
once and overlapping windows contribute only their maximum excess, not a sum.
Window time is a simple VF proxy, with no queue-state or dependency simulation.
"""
from dataclasses import dataclass, field
from fractions import Fraction as F

from cost_model import MAX_COST, add, backend_cost

MODEL_VERSION = 'backend-memory-window-v3'
KINDS = ('scalar', 'unit', 'strided', 'segment', 'segment-strided', 'indexed')


def fraction(value):
    return F(value['numerator'], value['denominator']) if isinstance(value, dict) else F(str(value))


@dataclass(frozen=True)
class Parameters:
    window_size: int = 8
    throughput: F = F(1)
    reference_width: F = F(8)
    headroom: F = F(0)
    interaction_weight: F = F(1)
    service_scale: F = F(1)
    llvm_memory_removal: str = 'recipes'
    service_costs: dict = field(default_factory=dict)
    demand_weights: dict = field(default_factory=dict)
    service_opcode_costs: dict = field(default_factory=dict)
    demand_opcode_counts: dict = field(default_factory=dict)
    stride_interval_bytes: F = F(8)
    stride_service_strength: F = F(0)
    stride_demand_strength: F = F(0)

    def __post_init__(self):
        if type(self.window_size) is not int or self.window_size < 1:
            raise ValueError('window_size must be a positive integer')
        if self.llvm_memory_removal not in ('recipes','hooks','none'):
            raise ValueError('unknown LLVM memory removal scope')
        for key in ('throughput', 'reference_width', 'headroom', 'interaction_weight', 'service_scale'):
            value = fraction(getattr(self, key))
            if value < 0 or (key in ('throughput', 'reference_width') and value == 0):
                raise ValueError(key+' has an invalid value')
            object.__setattr__(self, key, value)
        for key in ('stride_interval_bytes', 'stride_service_strength', 'stride_demand_strength'):
            value = fraction(getattr(self, key))
            if (value <= 0 if key == 'stride_interval_bytes' else not 0 <= value <= 1):
                raise ValueError(key+' has an invalid value')
            object.__setattr__(self,key,value)
        for key in ('service_costs', 'demand_weights', 'service_opcode_costs', 'demand_opcode_counts'):
            values = {name:fraction(value) for name,value in getattr(self,key).items()}
            if any(value < 0 for value in values.values()):
                raise ValueError(key+' must be nonnegative')
            if key in ('service_costs', 'demand_weights'):
                allowed = set(KINDS) | {k+':'+s for k in KINDS for s in ('load','store')}
                if not set(values) <= allowed:
                    raise ValueError('unknown memory kind in '+key)
            object.__setattr__(self,key,values)

    @classmethod
    def from_mapping(cls, values):
        return cls(**values)


def stride_factor(record, interval, strength):
    """Known ordinary strided accesses only; density is not a cache-miss model.

    Unknown strides retain factor one. Zero and reverse strides are handled
    explicitly, with reverse using its magnitude. Segmented/indexed accesses
    are unchanged. Strength zero exactly reproduces the previous model.
    """
    stride = record.get('stride')
    if record['kind'] != 'strided' or stride is None or not strength:
        return F(1)
    density = min(F(1),interval/max(F(1),abs(stride)))
    return 1-strength+strength*density


def operation_value(record, weights, overrides, interval=F(8), strength=F(0)):
    """Kind coefficients price raw requests; opcode overrides price one op."""
    if record['opcode'] in overrides:
        return overrides[record['opcode']]
    direction = ':load' if record['load'] else ':store'
    weight = weights.get(record['kind']+direction, weights.get(record['kind'], F(1)))
    return record['requests']*weight*stride_factor(record,interval,strength)


def geometry(facts, p):
    n = facts['body_length']
    if type(n) is not int or n < 1 or facts['width'] <= 0 or facts['iteration_ratio'] <= 0:
        raise ValueError('invalid memory body geometry')
    # No window includes more than one full period. The second period is only
    # needed to complete a window starting near the end of the first period.
    slots = min(p.window_size, n)
    time = slots*max(F(1), F(facts['width'])/p.reference_width)
    return n, slots, time, p.headroom+p.throughput*time


def window_peak(facts, values, size):
    """Return the maximum cyclic window demand and its earliest start."""
    n = facts['body_length']
    if type(n) is not int or n < 1 or type(size) is not int or size < 1:
        raise ValueError('invalid memory window size')
    slots = min(size,n)
    demands = [F(0)]*n
    for r,value in zip(facts['records'],values,strict=True):
        if not 0 <= r['position'] < n:
            raise ValueError('memory position outside body')
        demands[r['position']] += value
    # Explicit loop x2, followed by all n unique cyclic window starts.
    doubled = demands+demands
    current = sum(doubled[:slots],F(0))
    peak, start = current, 0
    for index in range(1,n):
        current += doubled[index+slots-1]-doubled[index-1]
        if current > peak:
            peak, start = current, index
    return peak,start


def normalized_terms(facts, p, service, peak):
    """Compose raw operation totals; normalize by the body ratio once."""
    n, slots, time, capacity = geometry(facts, p)
    excess = max(F(0),peak-capacity)
    interaction = p.interaction_weight*excess/p.throughput
    ratio = facts['iteration_ratio']
    return dict(service=p.service_scale*service/ratio, unscaled_service=service/ratio,
                interaction=interaction/ratio,
                peak_demand=peak, capacity=capacity, excess_demand=excess,
                window_time=time, window_slots=slots,
                windows_scanned=n, scanned_body_copies=2, iteration_ratio=ratio)


def window_terms(facts, p=Parameters()):
    service = sum((operation_value(r,p.service_costs,p.service_opcode_costs,
                                   p.stride_interval_bytes,p.stride_service_strength)
                   for r in facts['records']),F(0))
    demands = (operation_value(r,p.demand_weights,p.demand_opcode_counts,
                               p.stride_interval_bytes,p.stride_demand_strength) for r in facts['records'])
    peak,start = window_peak(facts,demands,p.window_size)
    terms = normalized_terms(facts,p,service,peak)
    end = start+terms['window_slots']
    return terms | dict(peak_start=start,peak_end=end,wraps=end>facts['body_length'],
        stride_known=sum(r['kind']=='strided' and r.get('stride') is not None for r in facts['records']),
        stride_unknown=sum(r['kind']=='strided' and r.get('stride') is None for r in facts['records']))


def memory_quarters(terms):
    """Round the combined memory cost once, after normalization."""
    return min(MAX_COST,int(4*(terms['service']+terms['interaction'])))


def replace_memory_cost(candidate, observation, terms, memory_recipe_quarters):
    derived = backend_cost(candidate,observation)
    middle = candidate['middle_end']
    if not 0 <= memory_recipe_quarters <= middle['vector_region'] < MAX_COST:
        raise ValueError('invalid memory recipe removal')
    extra = memory_quarters(terms)
    base = add(add(middle['precomputed'],middle['vector_region']-memory_recipe_quarters),
               derived['backend_spill_quarters'])
    return derived | dict(effective_body_quarters=add(base,extra),
                          memory_added_quarters=extra, memory_removed_quarters=memory_recipe_quarters,
                          memory_model=MODEL_VERSION, memory_terms=terms)
