"""Prepare a common dependence graph before applying any cost model.

Register RAW edges come from the compiler. Private frame-slot RAW edges use
byte-level reaching stores, including the previous loop iteration. No latency,
port, benchmark, or spill penalty belongs in this module.
"""
from collections import defaultdict

from model_errors import ToolError

GRAPH_SCHEMA = 'mir-dependencies-v1'


def prepare_dependencies(observation, *, vscale, max_stack_access_bytes):
    """O(N + E + B), B = bytes visited by bounded machine memory accesses.

The target supplies vscale and its maximum supported access width. Fixed stack
object identity survives frame-index elimination in MachineMemOperand facts.
Unknown/masked writes invalidate the slot instead of inventing a reaching def.
"""
    order = observation['body_order']
    ops = {op['id']: op for op in observation['instructions']}
    edges = [dict(e) for e in observation['dependencies']]
    accesses = {}
    unsupported = []
    for id_ in order:
        op = ops[id_]
        rows = []
        for index, m in enumerate(op['memory']):
            slot = m.get('stack_slot')
            if slot is None:
                continue
            size = m['bytes']
            if size is not None:
                size *= vscale if m['scalable'] else 1
            known = (size is not None and 0 < size <= max_stack_access_bytes
                     and not op['masked'] and not m['atomic'] and not m['volatile'])
            if not known:
                unsupported.append(dict(id=id_, memory_index=index, stack_slot=slot,
                                        reason='unknown, oversized, masked, atomic or volatile stack access'))
            rows.append((index, slot, m['offset'], size if known else None, m['load'], m['store']))
        accesses[id_] = rows

    reaching = defaultdict(dict)

    def write(id_):
        if not ops[id_]['registers_complete']:
            # Opaque calls/asm may modify memory as well as registers.
            reaching.clear()
        for index, slot, offset, size, _, store in accesses[id_]:
            if not store:
                continue
            if size is None:
                reaching.pop(slot, None)
                continue
            state = reaching[slot]
            for byte in range(offset, offset + size):
                state[byte] = (id_, index)

    # Seed loop-carried stores, then overwrite them with this iteration's defs.
    for id_ in order:
        write(id_)
    live_in_bytes = 0
    for id_ in order:
        if not ops[id_]['registers_complete']:
            reaching.clear()
        for index, slot, offset, size, load, _ in accesses[id_]:
            if not load or size is None:
                continue
            state = reaching.get(slot, {})
            # Run-length encode equal reaching defs. A partial overwrite may
            # leave several producers; a complete overwrite kills the old one.
            run_source, run_start = None, offset
            for byte in range(offset, offset + size + 1):
                source = state.get(byte) if byte < offset + size else None
                if byte < offset + size and source is None:
                    live_in_bytes += 1
                if source != run_source:
                    if run_source is not None:
                        src, src_index = run_source
                        edges.append(dict(source=src, destination=id_,
                            iteration_distance=int(src >= id_), kind='memory-raw',
                            source_memory_index=src_index, destination_memory_index=index,
                            stack_slot=slot, offset=run_start, bytes=byte - run_start))
                    run_source, run_start = source, byte
        write(id_)
    return dict(schema=GRAPH_SCHEMA, body_order=list(order), dependencies=edges,
                coverage=dict(register=observation['register_coverage'],
                    unsupported_register_ops=[id_ for id_ in order if not ops[id_]['registers_complete']],
                    memory='known frame-slot byte RAW, distances 0/1; general memory aliasing unmodeled',
                    stack_raw_edges=sum(e['kind'] == 'memory-raw' for e in edges),
                    stack_live_in_bytes=live_in_bytes, unsupported_stack_accesses=unsupported))


def longest_path(graph, latencies):
    """O(N + E) distance-0 longest path; all dependency kinds are identical here.

Configuration/meta nodes remain zero-weight connectors; their charges belong
to the existing fixed additions. Distance-1 edges remain graph facts but are
not traversed: L_path describes one iteration, not loop-carried recurrence.
"""
    order = graph['body_order']
    positions = {id_: n for n, id_ in enumerate(order)}
    predecessors = defaultdict(list)
    for e in graph['dependencies']:
        src, dst = e['source'], e['destination']
        if src not in positions or dst not in positions:
            raise ToolError('dependency outside body')
        distance = e['iteration_distance']
        if distance not in (0, 1):
            raise ToolError('unsupported iteration distance')
        if distance == 0:
            if positions[src] >= positions[dst]:
                raise ToolError('non-forward distance-0 dependency')
            predecessors[dst].append(src)
    costs, parents = {}, {}
    for id_ in order:
        weight = latencies.get(id_, 0)
        if weight < 0:
            raise ToolError('negative dependency latency')
        parent = max(predecessors[id_], key=lambda u: (costs[u], -u), default=None)
        costs[id_] = weight + (costs[parent] if parent is not None else 0)
        parents[id_] = parent
    end = max(order, key=lambda u: (costs[u], -u), default=None)
    path = []
    node = end
    while node is not None:
        path.append(node)
        node = parents[node]
    return dict(cost=costs[end] if end is not None else 0, path=list(reversed(path)),
                node_costs={str(k): v for k, v in costs.items()},
                scope='single-iteration distance-0 dependence path')
