"""Dynamic pair identity and conservative transitive dependency queries."""
from functools import lru_cache


def memory_relation(a, b):
    """Earlier/later memory ops: dependent, independent or unknown.

    Alias scopes are retained as facts but never interpreted as an alias proof
    without their complete scope domains. Only distinct fixed stack objects or
    nonoverlapping fixed ranges prove memory independence here.
    """
    if not (a['load'] or a['store']) or not (b['load'] or b['store']): return 'independent'
    if any(m['volatile'] or m['atomic'] for op in (a, b) for m in op['memory']): return 'unknown'
    if not a['store'] and not b['store']: return 'independent'
    if not a['memory'] or not b['memory']: return 'unknown'
    unknown = False
    for x in a['memory']:
        for y in b['memory']:
            if not x['store'] and not y['store']: continue
            if x['stack_slot'] is None or y['stack_slot'] is None:
                unknown = True
            elif x['stack_slot'] != y['stack_slot']:
                continue
            elif x['bytes'] is None or y['bytes'] is None or x['scalable'] or y['scalable']:
                unknown = True
            elif max(x['offset'], y['offset']) < min(x['offset'] + x['bytes'], y['offset'] + y['bytes']):
                return 'dependent'
    return 'unknown' if unknown else 'independent'


class Dependencies:
    def __init__(self, observation):
        self.ops = {op['id']: op for op in observation['instructions']}
        self.order = observation['body_order']
        self.position = {id_: i for i, id_ in enumerate(self.order)}
        self.n = len(self.order)
        self.predecessors = {id_: set() for id_ in self.order}
        self.complete = all(self.ops[id_]['registers_complete'] for id_ in self.order)
        for edge in observation['dependencies']:
            self.predecessors[edge['destination']].add((edge['source'], edge['iteration_distance']))
        self.relation = lru_cache(maxsize=None)(self.relation)
        self.memory_ids = [id_ for id_ in self.order if self.ops[id_]['load'] or self.ops[id_]['store']]

    def node(self, ordinal):
        iteration, position = divmod(ordinal, self.n)
        return self.order[position], iteration

    def ordinal(self, node):
        id_, iteration = node
        return iteration * self.n + self.position[id_]

    def relation(self, source, destination):
        """Acyclic expansion of reaching defs across as many iterations as needed.

        A possible memory path propagates unknown through register paths too.
        The static loop is never collapsed into a self-edge.
        """
        lo, hi = sorted((self.ordinal(source), self.ordinal(destination)))
        if lo == hi: return dict(raw=False, independence='dependent', reason='same dynamic instance')
        first, _ = self.node(lo)
        definite, possible, raw_reachable = {lo}, {lo}, {lo}
        memory_seen = []
        for ordinal in range(lo, hi + 1):
            id_, iteration = self.node(ordinal)
            if ordinal != lo:
                for pred, distance in self.predecessors[id_]:
                    p = self.ordinal((pred, iteration - distance))
                    if p in definite: definite.add(ordinal)
                    if p in possible: possible.add(ordinal)
                    if p in raw_reachable: raw_reachable.add(ordinal)
                for p in memory_seen:
                    prev, _ = self.node(p)
                    relation = memory_relation(self.ops[prev], self.ops[id_])
                    if relation == 'dependent' and p in definite: definite.add(ordinal)
                    if (relation == 'dependent' and p in raw_reachable
                            and self.ops[prev]['store'] and self.ops[id_]['load']):
                        raw_reachable.add(ordinal)
                    if relation != 'independent' and p in possible: possible.add(ordinal)
            if id_ in self.memory_ids: memory_seen.append(ordinal)
        if hi in definite:
            return dict(raw=hi in raw_reachable, independence='dependent', reason='direct/transitive register or stack-memory RAW/order')
        if hi in possible or not self.complete:
            return dict(raw=False, independence='unknown', reason='possible memory path or incomplete register facts')
        # Physical anti/output hazards are not value RAW edges, but cannot
        # establish independence without a rename/lifetime proof.
        last, _ = self.node(hi)
        def units(op, key):
            return {u for o in op['operands'] if o['kind'] == 'register' and o[key] for u in o['units']}
        if units(self.ops[first], 'use') & units(self.ops[last], 'def') or units(self.ops[first], 'def') & units(self.ops[last], 'def'):
            return dict(raw=False, independence='unknown', reason='physical WAR/WAW; no rename proof')
        return dict(raw=False, independence='independent', reason='complete reaching defs; memory paths disjoint or read-only')
