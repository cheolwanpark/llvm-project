"""Experimental memory service and separable interaction costs (model units).

Explicit exploratory parameters, not hardware queue capacities. Three
stages: distance; distance + stride adjustment; those + load/store address term.
No runtime measurements or benchmark identifiers are accepted.
"""
from dataclasses import dataclass
from fractions import Fraction as F

from cost_model import MAX_COST, add, backend_cost

MODEL_VERSION = 'backend-memory-interaction-v2'


@dataclass(frozen=True)
class Parameters:
    alpha: F = F(1, 2)
    threshold: int = 8
    distance_scale: int = 4
    locality_bytes: int = 16
    line_bytes: int = 64
    reverse_weight: F = F(0)
    unknown_stride_weight: F = F(1)

    def __post_init__(self):
        for name in ('alpha', 'reverse_weight', 'unknown_stride_weight'):
            value = F(getattr(self, name))
            if value < 0:
                raise ValueError(name + ' must be nonnegative')
            object.__setattr__(self, name, value)
        for name in ('threshold', 'distance_scale', 'locality_bytes', 'line_bytes'):
            value = getattr(self, name)
            if type(value) is not int or value < (0 if name == 'threshold' else 1):
                raise ValueError(name + ' has an invalid integer value')

    @classmethod
    def from_mapping(cls, values):
        values = dict(values)
        for name in ('alpha', 'reverse_weight', 'unknown_stride_weight'):
            if name in values:
                value = values[name]
                values[name] = F(value['numerator'], value['denominator']) if isinstance(value, dict) else F(str(value))
        return cls(**values)


def locality(record, p):
    stride = record['stride']
    if stride is None:
        return p.unknown_stride_weight  # explicitly report unknown
    if stride < 0 and abs(stride) == record['eew'] // 8:
        return p.reverse_weight  # extra contention only, not base service
    return min(F(1), F(p.locality_bytes, max(1, abs(stride))))


def _shared_lines(a, b, p):
    """Average over unknown base line alignment; not a bank-conflict claim."""
    if not a['address'] or not b['address'] or a['address'][0] != b['address'][0]:
        return F(0)
    if a['iteration_delta'] is None or a['iteration_delta'] != b['iteration_delta']:
        return F(0)
    if a['stride'] is None or b['stride'] is None:
        return F(0)
    if a['vl'].denominator != 1 or b['vl'].denominator != 1:
        return F(0)
    total = F(0)
    for base in range(p.line_bytes):
        sets = []
        for r in (a, b):
            lines = set()
            for k in range(int(r['vl'])):
                start = base + r['address'][1] + k * r['stride']
                lines.update(range(start // p.line_bytes, (start + r['eew']//8 - 1)//p.line_bytes + 1))
            sets.append(lines)
        total += F(len(sets[0] & sets[1]), max(1, min(map(len, sets))))
    return total / p.line_bytes


def memory_terms(facts, p=Parameters(), *, include_address=True):
    rs = facts['records']
    loads = [r for r in rs if r['kind'] == 'strided' and r['load']]
    stores = [r for r in rs if r['kind'] == 'strided' and not r['load']]
    distance = stride_adjustment = address = F(0)
    pairs, address_pairs = [], []
    n = facts['body_length']
    for index, a in enumerate(loads):
        b = loads[(index + 1) % len(loads)]
        wrap = index == len(loads) - 1
        gap = b['position'] + (n if wrap else 0) - a['position'] - 1
        near = F(p.distance_scale, p.distance_scale + gap)
        # Steady-state cyclic adjacency: no finite-trip discount or dependence gate.
        raw = p.alpha * near * max(F(0), a['requests'] + b['requests'] - p.threshold)
        gated = raw * min(locality(a, p), locality(b, p))
        distance += raw
        stride_adjustment += gated - raw
        pairs.append(dict(source=a['id'], destination=b['id'], wrap=wrap, gap=gap,
                          raw=raw, stride_conditioned=gated))
    for a in loads if include_address else []:
        options = []
        for b in stores:
            share = _shared_lines(a, b, p)
            gap = abs(b['position'] - a['position']) - 1
            value = p.alpha * F(p.distance_scale, p.distance_scale + gap) * share * min(locality(a, p), locality(b, p)) * max(F(0), a['requests'] + b['requests'] - p.threshold)
            options.append((value, b['id'], share))
        if options:
            value, store, share = max(options)
            address += value
            address_pairs.append(dict(load=a['id'], store=store, share=share, cost=value))
    ratio = facts['iteration_ratio']
    return dict(service=sum((r['requests'] for r in rs), F(0)) / ratio,
                distance=distance / ratio, stride_adjustment=stride_adjustment / ratio,
                address=address / ratio, pairs=pairs, address_pairs=address_pairs,
                unknown_stride=[r['id'] for r in loads + stores if r['stride'] is None],
                unknown_address=[r['id'] for r in loads + stores if r['address'] is None or r['iteration_delta'] is None])


def apply_memory_cost(candidate, observation, terms, *, mode, stage, llvm_memory_quarters=0):
    """Keep the original scalar comparator/tail and spill replacement policy."""
    if mode not in ('add', 'replace', 'residual') or stage not in ('distance', 'stride', 'address'):
        raise ValueError('unknown memory model variant')
    derived = backend_cost(candidate, observation)
    interaction = terms['distance']
    if stage in ('stride', 'address'):
        interaction += terms['stride_adjustment']
    if stage == 'address':
        interaction += terms['address']
    value = interaction + (terms['service'] if mode != 'residual' else 0)
    quarters = min(MAX_COST, int(4 * value))
    middle = candidate['middle_end']
    removed = llvm_memory_quarters if mode == 'replace' else 0
    if not 0 <= removed <= middle['vector_region'] or middle['vector_region'] == MAX_COST:
        raise ValueError('cannot remove memory from saturated/invalid vector region')
    effective = add(add(middle['precomputed'], middle['vector_region'] - removed), derived['backend_spill_quarters'])
    derived.update(effective_body_quarters=add(effective, quarters),
                   memory_mode=mode, memory_stage=stage, memory_added_exact_quarters=4*value,
                   memory_added_quarters=quarters, memory_removed_quarters=removed,
                   memory_terms={k: terms[k] for k in ('service', 'distance', 'stride_adjustment', 'address')})
    return derived
