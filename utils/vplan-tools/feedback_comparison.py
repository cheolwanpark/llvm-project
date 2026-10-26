"""Compare received middle-end facts with the existing backend file observer.

Only top-level transport identity/provenance is excluded. Machine/block IDs,
register assignments, MIR text, operand positions and dependency edges are exact.
"""
import json
from pathlib import Path

from cost_model import score_observation
from model_errors import ToolError
from observations import bind_observation, validate_manifest, validate_observation

PREFIX = 'VPLAN-BACKEND-FEEDBACK: '
IGNORED_FIELDS = ('candidate', 'run_id', 'feedback_pipeline')


def read_feedback(path, *, allow_empty=False):
    lines = Path(path).read_text().splitlines()
    # Stderr may also contain compiler remarks. JSONL contains only rows.
    if any(line.startswith(PREFIX) for line in lines):
        lines = [line[len(PREFIX):] for line in lines if line.startswith(PREFIX)]
    rows = [json.loads(line) for line in lines if line.strip()]
    if not rows and not allow_empty:
        raise ToolError('no middle-end feedback rows')
    for row in rows:
        if row.get('feedback_point') != 'middle-end-before-vf-selection':
            raise ToolError('feedback was not marked as received before VF selection')
        if row.get('ic') != 1 or row.get('vector_epilogue') is not False:
            raise ToolError('feedback probe geometry must be IC=1 without vector epilogue')
    return rows


def differences(left, right, path='$'):
    """All differences, preserving list order and numeric/bool distinctions."""
    if type(left) is not type(right):
        # JSON integer/double encodings may denote the same numeric fact.
        if type(left) in (int, float) and type(right) in (int, float) and left == right:
            return []
        return [dict(path=path, middle_end=left, backend=right)]
    if isinstance(left, dict):
        result = []
        for key in sorted(left.keys() | right.keys()):
            at = path + '.' + key
            if key not in left or key not in right:
                result.append(dict(path=at, middle_end=left.get(key), backend=right.get(key),
                                   missing='middle_end' if key not in left else 'backend'))
            else:
                result.extend(differences(left[key], right[key], at))
        return result
    if isinstance(left, list):
        result = []
        if len(left) != len(right):
            result.append(dict(path=path + '.length', middle_end=len(left), backend=len(right)))
        for i in range(min(len(left), len(right))):
            result.extend(differences(left[i], right[i], f'{path}[{i}]'))
        return result
    return [] if left == right else [dict(path=path, middle_end=left, backend=right)]


def compare_observations(middle_end, backend):
    validate_observation(middle_end)
    validate_observation(backend)
    left = {k: v for k, v in middle_end.items() if k not in IGNORED_FIELDS}
    right = {k: v for k, v in backend.items() if k not in IGNORED_FIELDS}
    diff = differences(left, right)
    regions = {}
    roles = {op['role'] for op in middle_end['instructions'] + backend['instructions']}
    for role in sorted(roles):
        a = [op for op in middle_end['instructions'] if op['role'] == role]
        b = [op for op in backend['instructions'] if op['role'] == role]
        regions[role] = dict(equal=a == b, middle_end_instructions=len(a), backend_instructions=len(b))
    scores = []
    for observation in (middle_end, backend):
        try:
            scores.append(dict(status='scored', score_exact=score_observation(observation)['score_exact']))
        except ToolError as exc:
            scores.append(dict(status='unsupported', reason=str(exc)))
    return dict(equal=not diff, differences=diff, instruction_regions=regions,
                body_order_equal=middle_end['body_order'] == backend['body_order'],
                dependencies_equal=middle_end['dependencies'] == backend['dependencies'],
                ignored_fields={k: dict(middle_end=middle_end.get(k), backend=backend.get(k))
                                for k in IGNORED_FIELDS},
                scores=dict(middle_end=scores[0], backend=scores[1]),
                scores_equal=(scores[0]['status'] == scores[1]['status'] == 'scored'
                              and scores[0]['score_exact'] == scores[1]['score_exact']))


def compare_collection(middle_end_path, backend_dir):
    directory = Path(backend_dir)
    manifest = json.loads((directory / 'candidates.json').read_text())
    validate_manifest(manifest, manifest['run_id'])
    loops = {(r['function'], r['loop']): r for r in manifest['loops']}
    left, right = {}, {}
    # An empty receipt is a population mismatch when the backend has candidates.
    # Keep those candidates in the report instead of dropping the whole input.
    for row in read_feedback(middle_end_path, allow_empty=True):
        vf = ('s' if row['scalable'] else 'f') + str(row['vf'])
        key = (row['function'], row['loop'], row['plan'], vf)
        if key in left:
            raise ToolError('duplicate feedback candidate; use one fresh compilation output')
        left[key] = row
    for i, candidate in enumerate(manifest['candidates']):
        # Function names may contain colons; only parse the known ID suffix.
        plan = int(candidate['id'].rsplit(':', 2)[1])
        key = (candidate['function'], candidate['loop'], plan, candidate['vf'])
        if key in right:
            raise ToolError('duplicate backend candidate')
        right[key] = (i, candidate)

    rows = []
    for key in sorted(left.keys() | right.keys()):
        record = dict(function=key[0], loop=key[1], plan=key[2], vf=key[3])
        rows.append(record)
        if key not in left or key not in right:
            record.update(equal=False, status='missing-candidate',
                          missing='middle_end' if key not in left else 'backend')
            continue
        row = left[key]
        i, candidate = right[key]
        path = directory / f'probe-{i:04d}.analytics.json'
        record.update(middle_end_candidate=row['candidate'], backend_candidate=candidate['id'],
                      backend_observation=str(path))
        if row['status'] == 'skipped':
            record.update(equal=False, status='skipped',
                          middle_end_reason=row.get('reason'),
                          register_usage_bound=row.get('register_usage_bound'))
            continue
        if row['status'] != 'collected' or not path.exists():
            record.update(equal=False, status='unavailable',
                          middle_end_status=row['status'], middle_end_reason=row.get('reason'),
                          backend_file_present=path.exists())
            continue
        a = row['observation']
        if (a['candidate'] != row['candidate'] or a['function'] != row['function']
                or a['vf'] != row['vf'] or a['scalable'] != row['scalable']):
            raise ToolError('middle-end row/observation identity mismatch')
        b = bind_observation(json.loads(path.read_text()), candidate,
                             loops[candidate['function'], candidate['loop']], manifest['run_id'])
        record.update(status='compared', **compare_observations(a, b))
    equal = sum(r['equal'] for r in rows)
    compared = sum(r['status'] == 'compared' for r in rows)
    return dict(schema='vplan-feedback-comparison-v1',
                middle_end=str(middle_end_path), backend_dir=str(directory),
                ignored_fields=list(IGNORED_FIELDS),
                population_equal=left.keys() == right.keys(),
                middle_end_candidates=len(left), backend_candidates=len(right),
                compared=compared, equal=equal, different=compared-equal,
                unavailable_or_missing=sum(r['status'] in ('unavailable', 'missing-candidate') for r in rows),
                skipped=sum(r['status'] == 'skipped' for r in rows),
                all_equal=bool(rows) and equal == len(rows), candidates=rows)
