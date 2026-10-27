import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1])]
rows = [r for r in rows if "candidate" in r]
assert rows
assert len({r["candidate"] for r in rows}) == len(rows)
assert {r["function"] for r in rows} == {"kernel", "two_loops"}
assert len({r["loop"] for r in rows if r["function"] == "two_loops"}) == 2
ic = int(sys.argv[2]) if len(sys.argv) > 2 else 1

if len(sys.argv) > 3:
    assert all(not r["scalable"] for r in rows)
else:
    assert len({r["vf"] for r in rows if r["scalable"]}) >= 2
for row in rows:
    assert row["feedback_point"] == "middle-end-before-vf-selection"
    assert row["status"] == "collected", row
    assert row["ic"] == ic and not row["vector_epilogue"]
    a = row["observation"]
    assert a["candidate"] == row["candidate"]
    assert a["vf"] == row["vf"] and a["scalable"] == row["scalable"]
    assert a["schema"] == "rvv-vector-spill-v1"
    assert a["stage"] == "post-stack-slot-coloring"
    assert a["iteration_mapping"] and a["iteration_width"] >= ic
    assert row["body_quarters_denominator"] > 0
    assert row["model"] == "tti-real-vector-spill-v1"
    assert a["ic"] == ic
    assert a["observation_role"] == row["role"]
    assert "instructions" not in a and "dependencies" not in a
    assert "scalar_cost" not in a and "middle_end" not in a
    for spill in a["spills"]:
        assert spill["register_group"] in (1, 2, 4, 8)
        assert spill["bytes"] > 0 and spill["whole_register"]
        assert spill["alignment"] > 0
