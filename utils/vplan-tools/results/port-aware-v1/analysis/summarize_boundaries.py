#!/usr/bin/env python3
"""Read-only analysis of completed evaluations and their saved exact boundaries."""
import argparse, csv, json, math
from collections import Counter
from fractions import Fraction as Q
from pathlib import Path

def contains(r, x):
    lo, hi = Q(r['lower']), None if r['upper'] is None else Q(r['upper'])
    return (x > lo or x == lo and r['lower_closed']) and (hi is None or x < hi or x == hi and r['upper_closed'])

def interval(r):
    lo, hi = Q(r['lower']), None if r['upper'] is None else Q(r['upper'])
    return ('[' if r['lower_closed'] else '(') + str(lo) + ', ' + (str(hi) if hi is not None else 'inf') + (']' if r['upper_closed'] else ')')

def merge_same_vf(segments):
    out=[]
    for original in segments:
        s=dict(original)
        if out and out[-1]['vf']==s['vf'] and out[-1]['upper'] is not None and Q(out[-1]['upper'])==Q(s['lower']) and (out[-1]['upper_closed'] or s['lower_closed']):
            out[-1].update(upper=s['upper'], upper_closed=s['upper_closed'])
        else: out.append(s)
    return out

def width(r):
    lo,hi=Q(r['lower']),None if r['upper'] is None else Q(r['upper'])
    return dict(lower=float(lo),upper=None if hi is None else float(hi), additive=None if hi is None else float(hi-lo), fold=None if hi is None or lo==0 else float(hi/lo), octaves=None if hi is None or lo==0 else math.log2(float(hi/lo)), lower_closed=r['lower_closed'], upper_closed=r['upper_closed'])

def write_csv(path, fields, rows):
    with path.open('w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=fields);w.writeheader();w.writerows(rows)

def main():
    p=argparse.ArgumentParser();p.add_argument('--evaluation',type=Path,required=True);p.add_argument('--boundaries',type=Path,required=True);p.add_argument('--output-dir',type=Path,required=True);a=p.parse_args()
    e=json.loads((a.evaluation/'summary.json').read_text()); b=json.loads(a.boundaries.read_text())
    assert e['complete'] and e['successful']
    assert e['identity']==b['identity'] and e['dataset_fingerprint']==b['dataset_fingerprint']
    assert b['axes'][0]['key']=='body_scale' and len(b['axes'])==1
    axis=b['axes'][0];cases=axis['cases'];raw={c['id']:c for c in b['candidates']};n=len(cases)
    out=a.output_dir;out.mkdir(parents=True,exist_ok=True)
    reference=[];violations=[];case_records=[]
    for c in cases:
        segs=merge_same_vf(c['segments'])
        base=next(s for s in segs if contains(s,Q(1)))
        assert base['vf']==c['baseline_vf']
        keep=[s for s in segs if s['vf']==c['baseline_vf']]
        bad=[s for s in segs if Q(s['regret'])>Q(c['baseline_regret'])+Q(15,100)]
        for s in bad:
            violations.append(dict(benchmark=c['id'],reference_vf=c['baseline_vf'],new_vf=s['vf'],reference_regret=float(Q(c['baseline_regret'])),new_regret=float(Q(s['regret'])),regret_delta_pp=100*float(Q(s['regret_delta'])),interval=interval(s),**width(s)))
        reference.append(dict(benchmark=c['id'],reference_vf=c['baseline_vf'],oracle_vf=c['oracle_vf'],reference_regret=float(Q(c['baseline_regret'])),reference_interval=interval(base),all_keep_intervals='; '.join(interval(s) for s in keep),ever_violates=bool(bad),oracle_reachable=bool(c['oracle']),**width(base)))
        case_records.append(dict(id=c['id'],reference_vf=c['baseline_vf'],reference_regret=float(Q(c['baseline_regret'])),reference_interval=base,unchanged_vf_intervals=keep,violating_intervals=bad,vf_segments=segs))
    regions=[]
    for r in axis['global_regions']:
        bad=[s for s in r['changes'] if not s['within_15pp']]
        regions.append(dict(interval=interval(r),contains_reference=r['contains_reference'],mean_regret=float(Q(r['metrics']['mean_regret'])),median_regret=r['metrics']['median_regret'],p95_regret=r['metrics']['p95_regret'],worst_regret=float(Q(r['metrics']['worst_regret'])),correct=r['metrics']['correct'],unchanged=r['metrics']['unchanged'],violation_count=len(bad),violation_ids='; '.join(s['id'] for s in bad),**width(r)))
    def details(r):
        contributions=r['mean_contributions'];total=sum(Q(x['regret']) for x in contributions)
        tail={str(k):dict(share_of_total_regret=float(sum(Q(x['regret']) for x in contributions[:k])/total) if total else 0.,mean_contribution=float(sum(Q(x['mean_contribution']) for x in contributions[:k])),ids=[x['id'] for x in contributions[:k]]) for k in (1,5,10)}
        changes=r['changes'];good=sorted((x for x in changes if Q(x['regret_delta'])<0),key=lambda x:Q(x['regret_delta']));bad=sorted((x for x in changes if Q(x['regret_delta'])>0),key=lambda x:-Q(x['regret_delta']))
        return dict(interval=interval(r),width=width(r),metrics=r['metrics'],tail=tail,contributions=contributions,violations=[x for x in changes if not x['within_15pp']],improvements=good,regressions=bad)
    ref=next(r for r in axis['global_regions'] if r['contains_reference'])
    baseline=e.get('comparison',{}).get('baseline')
    summary=dict(aggregation=e['identity']['machine_parameters']['settings']['aggregation'],settings=e['identity']['machine_parameters']['settings'],scored=n,total=e['metrics']['total'],reference=details(ref),llvm_matched_metrics=baseline,global_regions=len(regions),violating_global_regions=sum(r['violation_count']>0 for r in regions),max_violations_at_once=max(r['violation_count'] for r in regions),benchmarks_ever_violating=len({r['benchmark'] for r in violations}),benchmark_violation_segments=len(violations),all_vf_preserving=[dict(interval=interval(r),width=width(r)) for r in axis['preserve_all']],globally_within_15pp=[dict(interval=interval(r),width=width(r)) for r in axis['within_15pp_all']],minimum_mean_regions=[details(r) for r in axis['best']],per_case=case_records)
    (out/'analysis.json').write_text(json.dumps(summary,indent=2,default=str)+'\n')
    write_csv(out/'reference_intervals.csv',list(reference[0]),reference)
    write_csv(out/'violations.csv',list(violations[0]) if violations else ['benchmark','reference_vf','new_vf','interval','regret_delta_pp'],violations)
    write_csv(out/'global_regions.csv',list(regions[0]),regions)
    print(json.dumps({k:summary[k] for k in ('aggregation','scored','global_regions','violating_global_regions','max_violations_at_once','benchmarks_ever_violating')}))
    print('reference',interval(ref),float(Q(ref['metrics']['mean_regret'])))
    print('best',[(interval(r),float(Q(r['metrics']['mean_regret']))) for r in axis['best']])

if __name__=='__main__':main()
