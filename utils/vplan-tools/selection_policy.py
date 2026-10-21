"""Fixed RISC-V LLVM costs with observed post-RA spill/reload replacement."""
from selection import PolicyBase
from cost_model import MODEL_VERSION, backend_cost, more_profitable, score_candidate


def choose_priced(candidates, loop, costs, *, scalable_only=False):
    """Select in compiler order using the same trip/tail and tie rules."""
    best = None
    for candidate in candidates:
        if scalable_only and not candidate['vf'].startswith('s'):
            continue
        if costs.get(candidate['id']) is not None and (
                (scalable_only and best is None) or more_profitable(candidate,best,loop,costs)):
            best = candidate
    return best


class Policy(PolicyBase):
    name = "llvm-backend-spill"
    version = MODEL_VERSION
    requires_backend = True
    scalar_reason = "no vector candidate profitable against LLVM scalar baseline"

    def evaluate(self, candidate, observation):
        derived = backend_cost(candidate, observation)
        result = score_candidate(candidate, {
            "scalar_cost": observation["ScalarCost"],
            "max_trip_count": observation["MaxTripCount"]}, derived)
        if result["status"] == "unsupported":
            result["status"] = "backend-observation-unavailable"
            result["breakdown"] = candidate["middle_end"] | derived
        return result

    def choose_loop(self, rows, loop):
        scalable_only = getattr(self, 'candidate_scope', 'all') == 'scalable'
        if scalable_only:
            rows = [(c, s) for c, s in rows if c['vf'].startswith('s')]
        costs = {c["id"]: s["breakdown"]["effective_body_quarters"]
                 for c, s in rows if s["status"] == "scored"}
        return choose_priced([c for c,_ in rows],loop,costs,scalable_only=scalable_only)
