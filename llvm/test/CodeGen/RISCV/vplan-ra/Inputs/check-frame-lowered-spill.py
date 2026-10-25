import json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[6] / 'utils/vplan-tools'))
from kunminghu_v2 import MACHINE, expand_instruction
from hardware_model import accumulate_port_demands
from observations import validate_observation

a = validate_observation(json.loads(Path(sys.argv[1]).read_text()))
body = [a['instructions'][i] for i in a['body_order'] if not a['instructions'][i]['meta']]
assert not any(o['opcode'].startswith(('PseudoVSPILL', 'PseudoVRELOAD')) for o in body)
assert not any(v['kind'] == 'frame-index' for o in body for v in o['operands'])
work = [(o, expand_instruction(o)) for o in body if not o['configuration']]
spills = [w for o, w in work if o['store'] and any(m['spill_slot'] for m in o['memory'])]
reloads = [w for o, w in work if o['load'] and any(m['spill_slot'] for m in o['memory'])]
def demands(expansion):
    return dict(accumulate_port_demands([expansion], MACHINE).class_demands)
assert sorted(demands(w)['vstore128'] for w in spills) == [1, 2, 4], spills
assert sorted(demands(w)['vload128'] for w in reloads) == [1, 2, 4], reloads
assert all(demands(w)['i2v'] == 1 for w in spills + reloads)
assert sorted(dict(w.uops[0].geometry)['whole'] * 16 for w in spills) == [16, 32, 64]
assert sorted(w.verified_decode_uops for w in spills) == [2, 3, 5]
assert any(o['base_opcode'] == 'ADDI' and o['role'] == 'body' for o in body)
