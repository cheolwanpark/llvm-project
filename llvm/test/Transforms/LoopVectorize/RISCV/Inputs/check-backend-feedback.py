import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1])]
assert rows
assert len({r["candidate"] for r in rows}) == len(rows)
assert {r["function"] for r in rows} == {"kernel", "two_loops"}
assert len({r["loop"] for r in rows if r["function"] == "two_loops"}) == 2
if len(sys.argv) > 2:
    assert all(r["status"] == "unavailable" for r in rows)
    assert all("IC=1" in r["reason"] for r in rows)
    sys.exit(0)

assert len({r["vf"] for r in rows if r["scalable"]}) >= 2
for row in rows:
    assert row["feedback_point"] == "middle-end-before-vf-selection"
    assert row["status"] == "collected", row
    assert row["ic"] == 1 and not row["vector_epilogue"]
    a = row["observation"]
    assert a["candidate"] == row["candidate"]
    assert a["function"] == row["function"]
    assert a["vf"] == row["vf"] and a["scalable"] == row["scalable"]
    assert a["schema"] == "mir-local-observation-v2"
    assert a["stage"] == "post-frame-lowering"
    assert a["error"] == "", (row["candidate"], a["error"])
    assert a["iteration_mapping"] and a["iteration_width"] > 0
    assert a["middle_end"]["configuration_unit_quarters"] is not None
    assert a["scalar_cost"] is not None
    assert a["dependencies"] and a["body_order"]
    assert [op["id"] for op in a["instructions"]] == list(range(len(a["instructions"])))
    assert any(op["memory"] for op in a["instructions"])
    for edge in a["dependencies"]:
        assert edge["source"] in a["body_order"]
        assert edge["destination"] in a["body_order"]
        assert edge["iteration_distance"] in (0, 1)
    for op in a["instructions"]:
        assert op["mir"] and op["opcode"]
        for operand in op["operands"]:
            if operand["kind"] == "register":
                assert operand["physical"]
