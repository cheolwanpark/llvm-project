import json
import sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert not any(r['status'] == 'native-fallback' for r in rows), rows
assert any(r.get('vector_epilogue') for r in rows), rows
assert any(r['status'] == 'selected' and r['vf'] == 8 and r['ic'] == 4
           and r['epilogue_vf'] == 2 for r in rows), rows
for r in rows:
    if 'candidate' not in r:
        continue
    assert r['status'] == 'collected', r
    o = r['observation']
    assert o['stage'] == 'post-stack-slot-coloring'
    assert o['ic'] == 4 and o['observation_role'] == 'main'
    assert o['iteration_mapping'] and o['iteration_width'] >= r['vf'] * r['ic']
