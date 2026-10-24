import json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[6] / 'utils/vplan-tools'))
from kunminghu_v2 import work_for_instruction
from observations import validate_observation

a = validate_observation(json.loads(Path(sys.argv[1]).read_text()))
body = [a['instructions'][i] for i in a['body_order'] if not a['instructions'][i]['meta']]
assert not any(o['opcode'].startswith(('PseudoVSPILL', 'PseudoVRELOAD')) for o in body)
assert not any(v['kind'] == 'frame-index' for o in body for v in o['operands'])
work = [(o, work_for_instruction(o)) for o in body if not o['configuration']]
spills = [w for o, w in work if o['store'] and any(m['spill_slot'] for m in o['memory'])]
reloads = [w for o, w in work if o['load'] and any(m['spill_slot'] for m in o['memory'])]
assert sorted(w['class_demands']['vstu'] for w in spills) == [1, 2, 4], spills
assert sorted(w['class_demands']['vldu'] for w in reloads) == [1, 2, 4], reloads
assert all(w['class_demands']['i2v'] == 1 for w in spills + reloads)
assert sorted(int(w['geometry']['whole']) * 16 for w in spills) == [16, 32, 64]
assert any(o['base_opcode'] == 'ADDI' and o['role'] == 'body' for o in body)
