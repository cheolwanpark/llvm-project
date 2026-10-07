"""Check exact accounting and structural invariants of a detailed VPlan report."""
from fractions import Fraction
import re
import sys


def field(line, name):
    match = re.search(r"\b" + name + r"=(-?\d+(?:\.\d+)?|Invalid)(?=\s|$)", line)
    assert match, (name, line)
    return match[1] if match[1] == "Invalid" else Fraction(match[1])


def add(a, b):
    if "Invalid" in (a, b):
        return "Invalid"
    # InstructionCost uses signed, saturating quarter-unit storage.
    return min(max(a + b, Fraction(-(1 << 63), 4)), Fraction((1 << 63) - 1, 4))


checked = graphs = 0
ids = set()
rows = {}
for line in sys.stdin:
    if line.startswith("VPlan report_version="):
        assert "report_version=2 " in line, line
        rows = {}
        plan = None
        plan_ids = set()
        graph_ids = set()
    elif re.match(r"    (main|epilogue) \|", line):
        row = [v.strip() for v in line.split("|")]
        phase, plan_id, vf, width, cost, score, kind = row[:7]
        key = (phase, int(plan_id), vf)
        assert key not in rows, ("duplicate candidate score", line)
        rows[key] = cost
        if kind == "cost-per-lane" and cost != "Invalid":
            numerator, denominator = score.split("/")
            assert Fraction(numerator) == Fraction(cost), line
            assert denominator == width, line
    elif re.match(r"  plan=", line):
        plan = int(field(line, "plan"))
        assert plan not in plan_ids, ("duplicate plan section", line)
        plan_ids.add(plan)
        ids = set()
    elif line.startswith("VPlan '"):
        assert plan not in graph_ids, ("duplicate graph", line)
        graph_ids.add(plan)
        graphs += 1
    elif match := re.match(r"\s+\[R(\d+)\] ", line):
        rid = int(match[1])
        assert rid not in ids, ("duplicate graph recipe", line)
        ids.add(rid)
    elif match := re.match(r"      R(\d+) scope=", line):
        assert int(match[1]) in ids, ("recipe missing from graph", line)
    elif re.match(r"    evaluation=", line):
        legacy = recipes = backedges = 0
        vf = re.search(r" vf=([fs]\d+)", line)[1]
        phase = re.search(r" phase=(\S+)", line)[1]
        assert int(field(line, "plan")) == plan, line
    elif re.match(r"      legacy category=", line):
        legacy = add(legacy, field(line, "contribution"))
    elif re.match(r"        cost=", line):
        recipes = add(recipes, field(line, "contribution"))
    elif re.match(r"      region-backedge ", line):
        backedges = add(backedges, field(line, "cost"))
    elif re.match(r"      legacy_precomputed=", line):
        assert field(line, "legacy_precomputed") == legacy, line
    elif re.match(r"      vector_region_body=", line):
        assert field(line, "vector_region_body") == add(recipes, backedges), line
    elif re.match(r"      vector_region=", line):
        region = field(line, "vector_region")
    elif re.match(r"      register_pressure=", line):
        spills = field(line, "spill_cost")
    elif re.match(r"      candidate_cost=", line):
        cost = field(line, "candidate_cost")
        assert cost == add(add(legacy, region), spills), line
        if phase == "main-selection":
            table_cost = rows[("main", plan, vf)]
            table_cost = table_cost if table_cost == "Invalid" else Fraction(table_cost)
            assert cost == table_cost, line
        checked += 1
    elif line.startswith("End VPlan report"):
        assert plan_ids == graph_ids, "each plan needs exactly one graph"
    elif re.match(r"    scalar-block ", line):
        subtotal = field(line, "instruction_sum")
        divisor = field(line, "divisor")
        weighted = field(line, "weighted_cost")
        # Division truncates quarter units towards zero, after summing the block.
        assert weighted == Fraction(int(subtotal * 4 / divisor), 4), line
assert graphs, "report contained no plan graphs"
assert checked, "report contained no candidate accounting"
