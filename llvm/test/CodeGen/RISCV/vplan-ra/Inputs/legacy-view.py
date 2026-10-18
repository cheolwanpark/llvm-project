#!/usr/bin/env python3
"""Test-only projection of raw analytics onto the frozen v1 regression checks.

This is not consumed by the compiler or driver. It keeps the existing MIR
regression corpus checking the same observations after the schema migration.
"""
import json
import sys

a = json.load(open(sys.argv[1]))
assert a['Version'] == 2 and a['Stage'] == 'post-ra-cleanup'
assert not any(key in json.dumps(a) for key in ('work8', 'latency', 'resource_demand'))
r = dict(version=1, supported=False, loop_blocks=0,
         **{k + '8': 0 for k in ('unit', 'spill', 'strided', 'indexed', 'masked',
                                'integer', 'fp', 'fused', 'scalar', 'config',
                                'config_unused', 'config_additive')},
         operations=[], recurrences=[], load_use_nodes=[])
body = {b['ID'] for b in a['Blocks'] if b['Role'] == 'body'}
r['loop_blocks'] = len(body)
ins = a['Instructions']
assert [i['ID'] for i in ins] == list(range(len(ins)))
for e in a['Edges']:
    assert 0 <= e['Source'] < len(ins) and 0 <= e['Destination'] < len(ins)
    assert e['Distance'] in (0, 1)
    assert e['Distance'] or e['Source'] < e['Destination']

def op(i):
    k, g, sew = i['Category'], i['Group8'], i['SEW']
    family = i['Base'].split('_')[0]
    if k in ('integer', 'fp', 'fused') and family.startswith(('VW', 'VFW', 'VNSR', 'VNCLIP', 'VFNC')):
        g *= 2
    w = max(8, g * a['VLen'] // (sew if k in ('strided', 'indexed') else 1024 if k == 'mask_logical' else 128))
    if k == 'copy': w = 0 if i['SameCopy'] else g * a['VLen'] // 128
    if k == 'spill': w = max(8, i['Bytes'] * a['VLen'] // 128 if i['ScalableBytes'] else i['Bytes'] // 2)
    o = dict(kind=k, sew=sew, group8=g, work8=w, masked=i['Masked'], index_sew=i['IndexSEW'], index_group8=i['IndexGroup8'])
    if k == 'spill': o.update(sew=0, group8=0)
    if k == 'fp_div': o['form'] = 'reverse_vf' if family == 'VFRDIV' else i['Base'].split('_')[1].lower()
    if k in ('unit', 'strided', 'indexed'):
        o['direction'] = 'load' if i['Load'] else 'store'
        if i['Masked']: o['predicate_id'] = i['Predicate']
    return o

supported = not a['Error'] and a['CPU'] == 'xiangshan-kunminghu'
if supported:
    for i in ins:
        if i['Block'] not in body or i['Meta']: continue
        k = i['Category']
        if k == 'unknown' or i['Barrier']:
            supported = False
            break
        if k == 'scalar': r['scalar8'] += 8; continue
        if k == 'config':
            r['config8'] += 8
            r['config_unused8' if i['ConfigUnused'] else 'config_additive8'] += 8
            continue
        o = op(i)
        key = ('integer' if k == 'mask_logical' else k) + '8'
        if key in r: r[key] += o['work8']
        if k in ('unit', 'strided', 'indexed') and i['Masked']: r['masked8'] += o['work8']
        r['operations'].append(o)
r['supported'] = supported

def plain(i):
    ds = [o for o in i['Operands'] if o['Def'] and o['Vector']]
    return (len(ds) == 1 and not any(ds[0][k] for k in ('Implicit', 'Dead', 'EarlyClobber', 'SubReg'))
            and not i['Masked'] and not i['Barrier'] and i['Group8'] and i['SEW'] >= 8)
def recurrence_kind(i):
    if not plain(i) or i['SEW'] not in (32, 64): return None
    f = i['Base'].split('_')[0]
    if f in ('VFADD', 'VFSUB', 'VFMUL'): return 'fp'
    if f in ('VFMACC', 'VFNMACC', 'VFMSAC', 'VFNMSAC'): return 'fused'
def edge(e, fused):
    u = ins[e['Destination']]['Operands'][e['OperandIndex']]
    return e['WholeValue'] and u['Vector'] and not u['Implicit'] and not u['Undef'] and not u['SubReg'] and (fused or not u['Tied'])
def chunks(i): return max(1, i['Group8'] * a['VLen'] // 1024)
if supported and len(body) == 1:
    preds = {i['ID']: [] for i in ins}
    for e in a['Edges']:
        s, d = e['Source'], e['Destination']
        if (ins[d]['Block'] in body and recurrence_kind(ins[s]) and recurrence_kind(ins[d])
                and edge(e, recurrence_kind(ins[d]) == 'fused') and s not in preds[d]):
            preds[d].append(s)
    for e in a['Edges']:
        s, d = e['Source'], e['Destination']
        if not e['Distance'] or s not in preds[d]: continue
        counts = dict(fp_steps=0, fused_steps=0, extra_chunks=0)
        cur = s
        while True:
            counts[recurrence_kind(ins[cur]) + '_steps'] += 1
            counts['extra_chunks'] += chunks(ins[cur]) - 1
            if cur == d:
                r['recurrences'].append(counts)
                break
            ps = [p for p in preds[cur] if p < cur]
            if len(ps) != 1 or ps[0] < d: break
            cur = ps[0]
    known = {}
    families = {'load': ('VLE8','VLE16','VLE32','VLE64'), 'fp': ('VFADD','VFSUB','VFRSUB','VFMUL'),
                'fused': ('VFMACC','VFNMACC','VFMSAC','VFNMSAC','VFMADD','VFNMADD','VFMSUB','VFNMSUB'),
                'integer': ('VADD','VSUB','VRSUB','VAND','VOR','VXOR','VSLL','VSRL','VSRA','VMIN','VMINU','VMAX','VMAXU'),
                'multiply': ('VMUL','VMULH','VMULHU','VMULHSU')}
    for i in ins:
        if i['Block'] not in body or not plain(i): continue
        f = i['Base'].split('_')[0]
        k = next((k for k, fs in families.items() if f in fs), None)
        if k is None or (k in ('fp','fused') and i['SEW'] < 32): continue
        if k == 'load' and (i['Stack'] or not i['Load'] or i['Store']): continue
        ps = []
        for e in a['Edges']:
            s = e['Source']
            if e['Destination'] != i['ID'] or e['Distance'] or s not in known or not edge(e, k == 'fused'): continue
            if ins[s]['Group8'] == i['Group8'] and ins[s]['SEW'] == i['SEW'] and known[s] not in ps: ps.append(known[s])
        if k != 'load' and not ps: continue
        known[i['ID']] = len(r['load_use_nodes'])
        r['load_use_nodes'].append(dict(kind=k, chunks=chunks(i), predecessors=ps))
json.dump(dict(features=dict(resource_demand=r)), sys.stdout, sort_keys=True, separators=(',', ':'))
