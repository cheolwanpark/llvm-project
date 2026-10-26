import json
import sys
from fractions import Fraction
rows = [json.loads(line) for line in open(sys.argv[1])]
assert not any(r['status'] == 'native-fallback' for r in rows), rows
candidates = [r for r in rows if 'candidate' in r]
assert candidates and all(r['status'] == 'collected' for r in candidates)
spilling = [r for r in candidates if r['raw_vector_spill_quarters'] > 0]
assert spilling, rows
assert any(a['load'] for r in spilling for a in r['observation']['spills'])
assert any(not a['load'] for r in spilling for a in r['observation']['spills'])
for r in candidates:
    o = r['observation']
    assert o['stage'] == 'post-rvv-ra-rewrite' and o['iteration_mapping']
    spill = Fraction(r['normalized_vector_spill_quarters_numerator'],
                     r['normalized_vector_spill_quarters_denominator'])
    assert spill == Fraction(r['raw_vector_spill_quarters'] * r['tti_width'],
                             o['iteration_width'])
    body = Fraction(r['body_quarters_numerator'], r['body_quarters_denominator'])
    assert body == r['profile_body_quarters'] - r['estimated_vector_spill_quarters'] + spill
