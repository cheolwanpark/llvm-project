"""Check the independent accounting invariants of a VPlan text report."""
import re
import sys


def field(line, name):
    match = re.search(r"\b" + name + r"=(-?\d+|Invalid)\b", line)
    if not match:
        return None
    return match[1] if match[1] == "Invalid" else int(match[1])


def add(a, b):
    if "Invalid" in (a, b):
        return "Invalid"
    return min(max(a + b, -(1 << 63)), (1 << 63) - 1)


checked = 0
for line in sys.stdin:
    if re.match(r"    evaluation=", line):
        legacy = recipes = backedges = 0
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
        assert field(line, "candidate_cost") == add(add(legacy, region), spills), line
        checked += 1
    elif re.match(r"    scalar-block ", line):
        subtotal = field(line, "instruction_sum")
        divisor = field(line, "divisor")
        weighted = field(line, "weighted_cost")
        assert weighted == subtotal // divisor, line
assert checked, "report contained no candidate accounting"
