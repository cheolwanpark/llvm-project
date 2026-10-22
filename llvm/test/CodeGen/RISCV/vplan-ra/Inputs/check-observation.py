"""Validate raw MIR facts on the backend regression corpus."""
import json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[6] / 'utils/vplan-tools'))
from observations import validate_observation
value = validate_observation(json.loads(Path(sys.argv[1]).read_text()))
assert value['candidate']
assert value['register_coverage'] == 'physical-register-units-distance-0-1'
assert all(len(i['operands']) == len({o['index'] for o in i['operands']}) for i in value['instructions'])
