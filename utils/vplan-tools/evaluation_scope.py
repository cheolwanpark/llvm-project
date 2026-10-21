"""Candidate scope for dataset evaluations, independent of compilation policy."""
from selection_policy import Policy


class ScalablePolicy(Policy):
    scalar_reason = 'no evaluable scalable candidates'
    candidate_scope = 'scalable'


def evaluation_policy(scope):
    if scope not in ('scalable', 'all'):
        raise ValueError('unknown candidate scope')
    return ScalablePolicy() if scope == 'scalable' else Policy()


def scope_prepared(prep, scope='scalable'):
    """Drop fixed facts/costs/errors before pricing, retaining saved row order."""
    if scope not in ('scalable', 'all'):
        raise ValueError('unknown candidate scope')
    if scope == 'all':
        if prep.get('candidate_scope') == 'scalable':
            raise ValueError('cannot restore fixed candidates from scalable-only facts')
        return dict(prep, candidate_scope=scope)
    pairs = [(c, s) for c, s in zip(prep['manifest']['candidates'], prep['statuses'], strict=True)
             if c['vf'].startswith('s')]
    ids = {c['id'] for c, _ in pairs}
    return dict(prep, candidate_scope=scope,
                manifest=prep['manifest'] | {'candidates': [c for c, _ in pairs]},
                statuses=[s for _, s in pairs],
                data={cid: d for cid, d in prep['data'].items() if cid in ids},
                errors=[e for e in prep['errors'] if e['candidate'] in ids],
                removal_errors=[e for e in prep['removal_errors'] if e['candidate'] in ids])
