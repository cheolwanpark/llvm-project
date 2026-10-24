#!/usr/bin/env python3
"""Extract interpretable candidate facts from completed evaluations, without rescoring."""
import argparse,json
from fractions import Fraction as Q
from pathlib import Path

p=argparse.ArgumentParser();p.add_argument('--evaluation',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
s=json.loads((a.evaluation/'summary.json').read_text());assert s['complete'] and s['successful']
records=[]
for row in s['rows']:
    if not row['eligible']:continue
    # Stored report filenames are a slug plus an ID digest; find by saved candidate VF/population and exact row ID via shared naming utility.
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
    import vplan_tools as vt
    reports=json.loads((a.evaluation/'reports'/(vt.report_name(row['id'])+'.json')).read_text())
    caps={p['name']:Q(p['capacity']) for p in s['identity']['machine_parameters']['ports']}
    plans={}
    for r in reports:
        vf=int(r['vf'][1:])
        if vf not in plans or (Q(r['score_exact']),r['candidate'])<(Q(plans[vf]['score_exact']),plans[vf]['candidate']):plans[vf]=r
    oracle=min(row['measured_cycles'],key=lambda v:(row['measured_cycles'][v],int(v)))
    candidates=[]
    for vf,r in sorted(plans.items()):
        d={k:Q(v) for k,v in r['normalized_port_demands'].items()};m=max(d.values());binding=[p for p,v in d.items() if v==m]
        contributors={}
        for port in binding:
            op_rows=[]
            for op in r['ops']:
                contributions=[]
                for c in op['hardware']['components']:
                    if port in c['possible_ports']:contributions.append(dict(uop_class=c['uop_class'],amount=Q(c['per_port'])/caps[port],source=c['source']))
                amount=sum(c['amount'] for c in contributions)
                if amount:op_rows.append(dict(id=op['id'],opcode=op['opcode'],mir=op['mir'],normalized_demand=amount,classes=contributions))
            contributors[port]=sorted(op_rows,key=lambda x:(-x['normalized_demand'],x['id']))
        candidates.append(dict(vf=vf,candidate=r['candidate'],cycles=row['measured_cycles'][str(vf)],regret=row['measured_cycles'][str(vf)]/row['measured_cycles'][oracle]-1,selected=vf==row['selected_vf'],oracle=vf==int(oracle),score_exact=r['score_exact'],body_slope=r['features']['body_scale'],fixed_additions=r['features']['fixed_additions'],fixed_breakdown=r['middle_end']['unscaled_additions'],body_iterations=r['body_iterations'],body_cost=r['body_cost'],max_port_demand=m,total_normalized_demand=sum(d.values()),active_ports=sum(v>0 for v in d.values()),effective_max_width=sum(d.values())/m if m else 0,aggregate_to_max=Q(r['body_cost'])/m if m else 0,bottleneck_ports=binding,demands=sorted(d.items(),key=lambda kv:(-kv[1],kv[0])),class_demands=r['class_demands'],bottleneck_contributors=contributors,coverage=r['coverage'],scalar_remainder=r['scalar_remainder']))
    records.append(dict(id=row['id'],selected_vf=row['selected_vf'],oracle_vf=int(oracle),regret=row['top1_regret'],candidates=candidates))
a.output.write_text(json.dumps(dict(evaluation=str(a.evaluation),settings=s['identity']['machine_parameters']['settings'],cases=sorted(records,key=lambda r:(-r['regret'],r['id']))),indent=2,default=str)+'\n')
print(a.output)
