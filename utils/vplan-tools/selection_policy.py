"""Fixed RISC-V LLVM costs with observed post-RA spill/reload replacement."""
from selection import PolicyBase
from cost_model import MODEL_VERSION, backend_cost, more_profitable, score_candidate


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
        best = None
        costs = {c["id"]: s["breakdown"]["effective_body_quarters"]
                 for c, s in rows if s["status"] == "scored"}
        for candidate, status in rows:
            if status["status"] == "scored" and more_profitable(candidate, best, loop, costs):
                best = candidate
        return best
