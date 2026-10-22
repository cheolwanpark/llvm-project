import json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[6] / 'utils/vplan-tools'))
from observations import validate_observation

a = validate_observation(json.loads(Path(sys.argv[1]).read_text()))
assert a['error'] == ''
ops = a['instructions']
body = [ops[i] for i in a['body_order']]
assert [i['opcode'] for i in body] == ['ADDI', 'ADD', 'SD', 'LD', 'BNE']
assert ops[body[-1]['id'] + 1]['role'] == 'exit'
assert body[0]['operands'][2]['kind'] == 'immediate'
assert body[0]['operands'][2]['value'] == 1
assert any(e['source'] == body[0]['id'] and e['destination'] == body[0]['id']
           and e['iteration_distance'] == 1 and e['operand_index'] == 1 for e in a['dependencies'])
assert any(e['source'] == body[0]['id'] and e['destination'] == body[1]['id']
           and e['iteration_distance'] == 0 and e['operand_index'] == 1 for e in a['dependencies'])
assert all(o['units'] == [] for i in ops for o in i['operands'] if o['kind'] == 'register' and o['name'] == 'X0')
store, load = body[2:4]
assert store['memory'][0]['stack_slot'] == load['memory'][0]['stack_slot'] == 0
assert store['memory'][0]['spill_slot'] and load['memory'][0]['spill_slot']
assert store['memory'][0]['store'] and load['memory'][0]['load']
assert store['memory'][0]['bytes'] == load['memory'][0]['bytes'] == 8
