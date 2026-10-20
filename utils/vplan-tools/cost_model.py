"""Exact LLVM middle-end arithmetic and post-RA spill replacement; no fitting.

Targets the RISC-V reciprocal-throughput configuration used by search-dataset.
Costs remain integer quarter units through comparisons, as in InstructionCost.
The manifest does not encode all hints/filters or outside-loop profitability.
"""
from fractions import Fraction

from model_errors import ToolError
from observations import validate_middle_end

MODEL_VERSION = "llvm-backend-spill-v1"
MAX_COST = 2**63 - 1


def multiply(cost, count):
    """InstructionCost::operator*=(CostType), including intermediate saturation."""
    if cost is None:
        return None
    product = cost * min(MAX_COST, count * 4)
    return MAX_COST if product > MAX_COST else product // 4


def add(a, b):
    return None if a is None or b is None else min(MAX_COST, a + b)


def scalar_quarters(loop):
    value = loop["scalar_cost"]
    if value is None:
        return None
    value = Fraction(str(value)) * 4
    if value.denominator != 1 or not 0 <= value <= MAX_COST:
        raise ToolError("invalid middle-end scalar cost")
    return int(value)


def total(cost, width, scalar, trip_count, has_tail):
    if has_tail:
        return add(multiply(cost, trip_count // width),
                   multiply(scalar, trip_count % width))
    return multiply(cost, (trip_count + width - 1) // width)


def less(a, b, ties=False):
    # Invalid costs sort after valid costs. Invalid candidates cannot win.
    if a is None:
        return False
    return b is None or a < b or (ties and a == b)


def more_profitable(candidate, incumbent, loop, costs=None):
    """Replay the main-loop throughput branch of isMoreProfitable.

    incumbent=None denotes scalar f1. RISC-V uses the default TTI preference
    for scalable vectors on equal costs, including ties against scalar.
    Both sides use the new candidate's tail policy, exactly as LLVM does.
    """
    ca = costs[candidate["id"]] if costs is not None else candidate["middle_end"]["original"]
    wa = candidate["estimated_width"]
    scalar = scalar_quarters(loop)
    cb = (costs[incumbent["id"]] if costs is not None else incumbent["middle_end"]["original"]) if incumbent else scalar
    wb = incumbent["estimated_width"] if incumbent else 1
    prefer_scalable = candidate["vf"].startswith("s") and (
        incumbent is None or not incumbent["vf"].startswith("s"))
    trip_count = loop["max_trip_count"]
    if not trip_count:
        a, b = multiply(ca, wb), multiply(cb, wa)
    else:
        a = total(ca, wa, scalar, trip_count, candidate["scalar_tail"])
        b = total(cb, wb, scalar, trip_count, candidate["scalar_tail"])
    return less(a, b, prefer_scalable)


def score_candidate(candidate, loop, derived=None):
    """A display score; choose by pairwise comparisons, not rounded floats."""
    try:
        middle = candidate["middle_end"]
        validate_middle_end(middle)
        cost = derived["effective_body_quarters"] if derived is not None else middle["original"]
        width = candidate["estimated_width"]
        trip_count = loop["max_trip_count"]
        if type(width) is not int or width <= 0 or type(trip_count) is not int or trip_count < 0:
            raise ValueError("invalid width/trip count")
        if cost is None:
            return {"status": "unsupported", "reason": "invalid LLVM middle-end cost"}
        scalar = scalar_quarters(loop)
        value = total(cost, width, scalar, trip_count, candidate["scalar_tail"]) if trip_count else cost
        if value is None:
            return {"status": "unsupported", "reason": "invalid LLVM scalar-tail cost"}
        score = Fraction(value, 4 if trip_count else 4 * width)
        return {"status": "scored", "score": float(score),
                "score_exact": {"numerator": score.numerator, "denominator": score.denominator},
                "breakdown": {"body": cost / 4, "estimated_width": width,
                              "max_trip_count": trip_count, "scalar_cost": loop["scalar_cost"],
                              "scalar_tail": candidate["scalar_tail"],
                              "precomputed": middle["precomputed"],
                              "vector_region": middle["vector_region"],
                              "estimated_spill": middle["estimated_spill"],
                              "original": middle["original"],
                              "cost_scale": 4, **(derived or {})}}
    except (KeyError, TypeError, ValueError, OverflowError) as exc:
        raise ToolError(f"invalid LLVM middle-end observation: {exc}") from exc


def backend_cost(candidate, observation):
    """Replace only LLVM's spill estimate; never mutate the input manifest.

    Counts are static instructions in a proven body iteration, weighted by the
    number of physical registers moved. Division truncates once, in quarters.
    """
    from spill_observations import iteration_ratio, project_spills
    middle = candidate["middle_end"]
    validate_middle_end(middle)
    ratio = iteration_ratio(candidate, observation)
    counts = project_spills(candidate, observation)
    raw = 0
    for bucket in counts:
        bank = ("gpr", "fpr", "vector").index(bucket["kind"])
        for kind, units in (("spills", "spill_units"), ("reloads", "reload_units")):
            # Invalid TTI units retain InstructionCost's invalid propagation,
            # including multiplication by zero.
            unit = middle[units][bank]
            raw = None if raw is None or unit is None else raw + bucket[kind] * bucket["registers"] * unit
    normalized = None if raw is None else min(MAX_COST, raw // ratio)
    effective = add(add(middle["precomputed"], middle["vector_region"]), normalized)
    return dict(spill_counts=counts, spill_units=middle["spill_units"],
                reload_units=middle["reload_units"], iteration_ratio=ratio,
                backend_iteration_width=observation["Width"],
                backend_spill_raw_quarters=raw,
                backend_spill_exact={"numerator": raw, "denominator": ratio},
                backend_spill_quarters=normalized, effective_body_quarters=effective)
