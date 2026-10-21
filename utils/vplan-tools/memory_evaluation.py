"""Shared candidate projection and exact regret metrics for memory experiments.

This module consumes already-priced statuses. It has no dependency on a
particular memory model or CLI and never modifies the supplied observations.
"""
from fractions import Fraction as F
from pathlib import Path

from evaluation_scope import evaluation_policy, scope_prepared
from selection import select_loops


def encode(value):
    if isinstance(value, F):
        return dict(numerator=value.numerator, denominator=value.denominator)
    if isinstance(value, Path):
        return str(value)
    raise TypeError(type(value))


def metrics(rows):
    values = sorted(r['regret'] for r in rows if r['eligible'])
    if not values:
        return dict(n=0, correct=0, mean=None, p95=None, maximum=None)
    pos = F(95, 100) * (len(values) - 1)
    lo = int(pos)
    return dict(n=len(values), correct=sum(r['correct'] for r in rows if r['eligible']),
                mean=sum(values)/len(values), p95=values[lo] + (values[min(lo+1, len(values)-1)] - values[lo])*(pos-lo), maximum=max(values))


def project(old, prep, *, fallback=None):
    scope = prep.get('candidate_scope', 'scalable')
    prep = scope_prepared(prep, scope)
    statuses = prep['statuses']
    fallback = [] if fallback is None else fallback
    candidates = {}
    for c, s in zip(prep['manifest']['candidates'], statuses, strict=True):
        if s['status'] != 'scored':
            continue
        q = s['breakdown']['effective_body_quarters']
        candidates[c['id']] = dict(vf=c['vf'], body_quarters=q,
                                   per_element=F(q, 4*c['estimated_width']) if q is not None else None,
                                   added=s['breakdown'].get('memory_added_quarters', 0),
                                   removed=s['breakdown'].get('memory_removed_quarters', 0))
    out = dict(id=old['id'], vf=(old.get('actual_selection') or {}).get('main_vf') if scope == 'all' else None,
               eligible=False, status=old['status'], regret=None, correct=None,
               fallback=fallback, candidates=candidates,
               strided=any(any(r['kind']=='strided' for r in d.get('facts', {}).get('records', [])) for d in prep['data'].values()))
    if old['status'] in ('ambiguous-loops', 'no-loop', 'missing-measurements', 'vlen-mismatch'):
        return out
    if old['status'] == 'backend-observation-unavailable' and (
            scope == 'all' or any(s['status'] in ('unavailable', 'backend-observation-unavailable') for s in statuses)):
        return out
    choices = select_loops(evaluation_policy(scope), prep['manifest'], statuses)
    assert len(choices) == 1
    choice = choices[0]
    if scope == 'scalable' and choice['scalar']:
        out['status'] = 'no-scalable-candidates'
        return out
    vf = 'f1' if choice['scalar'] else next(c['vf'] for c in prep['manifest']['candidates'] if c['id'] == choice['id'])
    out['vf'] = vf
    measured = old['measured_cycles']
    if not vf.startswith('s') or vf[1:] not in measured:
        out['status'] = 'unmeasured-vf'
        return out
    best = min(measured, key=lambda v: (measured[v], int(v)))
    out.update(eligible=True, status='scored', cycles=measured[vf[1:]],
               regret=F(measured[vf[1:]], measured[best])-1, correct=vf[1:]==best)
    return out


def compare(rows, baseline):
    ref = {r['id']: r for r in baseline}
    common = [r for r in rows if r['eligible'] and ref[r['id']]['eligible']]
    changes = [dict(id=r['id'], old_vf=ref[r['id']]['vf'], new_vf=r['vf'],
                    old_regret=ref[r['id']]['regret'], new_regret=r['regret'],
                    delta=r['regret']-ref[r['id']]['regret']) for r in common if r['vf'] != ref[r['id']]['vf']]
    return dict(metrics=metrics(rows), common=metrics(common),
                baseline_common=metrics([ref[r['id']] for r in common]),
                regressions=sorted([r for r in changes if r['delta'] > 0], key=lambda r:-r['delta']),
                improvements=sorted([r for r in changes if r['delta'] < 0], key=lambda r:r['delta']),
                newly_excluded=[r['id'] for r in rows if ref[r['id']]['eligible'] and not r['eligible']],
                newly_included=[r['id'] for r in rows if not ref[r['id']]['eligible'] and r['eligible']],
                fallbacks=[r['id'] for r in rows if r['fallback']],
                cohorts={kind:metrics([r for r in common if r['strided']==flag]) for kind,flag in [('strided', True), ('unit-only',False)]}, rows=rows)
