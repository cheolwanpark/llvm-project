import json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[6] / 'utils/vplan-tools'))
from hardware import work_for_instruction
from memory_work import memory_work
from observations import validate_observation

a = validate_observation(json.loads(Path(sys.argv[1]).read_text()))
body = [a['instructions'][i] for i in a['body_order'] if not a['instructions'][i]['meta']]
assert not any(o['opcode'].startswith(('PseudoVSPILL', 'PseudoVRELOAD')) for o in body)
assert not any(v['kind'] == 'frame-index' for o in body for v in o['operands'])
work = [(o, memory_work(o, work_for_instruction(o), 128)) for o in body]
spills = [m for o, m in work if m and m['category'] == 'spill']
reloads = [m for o, m in work if m and m['category'] == 'reload']
assert sorted(m['bytes'] for m in spills) == [16, 32, 64], spills
assert sorted(m['bytes'] for m in reloads) == [16, 32, 64], reloads
assert all(m['bytes_kind'] == 'exact' for m in spills + reloads)
assert any(o['base_opcode'] == 'ADDI' and o['role'] == 'body' for o in body)
