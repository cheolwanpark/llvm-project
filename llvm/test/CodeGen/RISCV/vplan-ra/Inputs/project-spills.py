"""Check the production cost-free projection against native MIR observations."""
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[6] / 'utils/vplan-tools'))
from model_errors import ToolError
from spill_observations import project_spills

try:
    counts = project_spills({'estimated_width': int(sys.argv[2])}, json.loads(Path(sys.argv[1]).read_text()))
    value = dict(supported=True, counts=counts)
except ToolError as exc:
    value = dict(supported=False, reason=str(exc))
print(json.dumps(value, sort_keys=True, separators=(',', ':')))
