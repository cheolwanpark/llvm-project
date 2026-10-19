"""Fixed ablation: replace the middle-end spill estimate with TTI-priced spills."""
import math

from model_errors import ToolError
from observations import iteration_factors, validate_scalar_cost
from selection import PolicyBase
from spill_observations import iteration_ratio, project_spills

MAX_COST = 2**63 - 1


def add_cost(a, b):
    return min(MAX_COST, a + b)


def multiply_cost(cost, count):
    """Mirror InstructionCost multiplication, including intermediate saturation."""
    scaled_count = min(MAX_COST, count * 4)
    product = cost * scaled_count
    return MAX_COST if product > MAX_COST else product // 4


def price_spills(counts, middle, ratio, count_unit):
    total = 0
    for row in counts:
        bank = ("gpr", "fpr", "vector").index(row["kind"])
        terms = []
        for direction, units in (("spills", "spill_units"), ("reloads", "reload_units")):
            count, unit = row[direction], middle[units][bank]
            if count and unit is None:
                raise ToolError("unsupported-tti-unit")
            terms.append(multiply_cost(unit, count) if count else 0)
        multiplier = row["registers"] if count_unit == "register" else 1
        total = add_cost(total, multiply_cost(add_cost(*terms), multiplier))
    return total, total // ratio


class Policy(PolicyBase):
    name = "spill-aware"
    supports_spill_count_unit = True

    def evaluate(self, candidate, observation):
        ratio = iteration_ratio(candidate, observation)
        middle = candidate["middle_end"]
        if any(middle[k] is None for k in ("precomputed", "vector_region", "estimated_spill", "original")):
            raise ToolError("invalid-middle-end-cost")
        validate_scalar_cost(observation)
        effective = middle["estimated_spill"]
        source, reason, counts, observed = "disabled", None, None, None
        if middle["pressure"]:
            try:
                counts = project_spills(candidate, observation)
                observed, effective = price_spills(counts, middle, ratio, self.spill_count_unit)
                source = "post-ra"
            except ToolError as exc:
                source, reason = "heuristic", str(exc)
        # Select the spill term before addition, never subtract from a saturated
        # original total. Quarter-unit rounding happens once after accumulation.
        cost = add_cost(add_cost(middle["precomputed"], middle["vector_region"]), effective)
        body = (cost / 4) * ratio
        iterations, tail = iteration_factors(observation)
        score = body * iterations + tail  # ablation has fixed tail_scale = 1
        if not math.isfinite(score) or score < 0:
            raise ToolError("invalid spill-aware score")
        breakdown = dict(body=body, body_iterations=iterations, tail=tail, score=score,
            original_cost_q=middle["original"], candidate_cost_q=cost,
            estimated_spill_q=middle["estimated_spill"], observed_spill_q=observed,
            effective_spill_q=effective, source=source, fallback_reason=reason, counts=counts,
            original_width=candidate["estimated_width"], observed_width=observation["Width"],
            unroll_factor=ratio, spill_count_unit=self.spill_count_unit)
        return {"status": "scored", "score": score, "breakdown": breakdown}
