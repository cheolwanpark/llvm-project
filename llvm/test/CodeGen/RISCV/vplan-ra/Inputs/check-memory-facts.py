import json
import sys
from pathlib import Path

a = json.loads(Path(sys.argv[1]).read_text())
assert a['schema'] == 'mir-local-observation-v2'
assert a['stage'] == 'post-frame-lowering'
loads = [o for o in a['instructions'] if o['load']]
assert [o['vl'] for o in loads] == [3, 3, 3, 4, None, 2], loads
assert [o['stride'] for o in loads] == [64, 64, -4, 0, None, 2], loads
