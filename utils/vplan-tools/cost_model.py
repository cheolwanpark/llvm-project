"""Fixed LLVM middle-end cost replay; no measurements, fitting or backend facts.

Targets the RISC-V reciprocal-throughput configuration used by search-dataset.
Costs remain integer quarter units through comparisons, as in InstructionCost.
The manifest does not encode all hints/filters or outside-loop profitability.
"""
from fractions import Fraction

from model_errors import ToolError
from observations import validate_middle_end

MODEL_VERSION = "llvm-middle-end-v1"
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


def more_profitable(candidate, incumbent, loop):
    """Replay the main-loop throughput branch of isMoreProfitable.

    incumbent=None denotes scalar f1. RISC-V uses the default TTI preference
    for scalable vectors on equal costs, including ties against scalar.
    Both sides use the new candidate's tail policy, exactly as LLVM does.
    """
    ca = candidate["middle_end"]["original"]
    wa = candidate["estimated_width"]
    scalar = scalar_quarters(loop)
    cb = incumbent["middle_end"]["original"] if incumbent else scalar
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


def score_candidate(candidate, loop):
    """A display score; choose by pairwise comparisons, not rounded floats."""
    try:
        middle = candidate["middle_end"]
        validate_middle_end(middle)
        cost = middle["original"]
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
                              "cost_scale": 4}}
    except (KeyError, TypeError, ValueError, OverflowError) as exc:
        raise ToolError(f"invalid LLVM middle-end observation: {exc}") from exc
