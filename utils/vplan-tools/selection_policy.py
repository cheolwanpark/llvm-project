"""Fixed RISC-V LLVM middle-end policy, independent of measured cycles."""
from selection import PolicyBase
from cost_model import more_profitable, score_candidate


class Policy(PolicyBase):
    name = "llvm-middle-end"
    requires_backend = False
    scalar_reason = "no vector candidate profitable against LLVM scalar baseline"

    def evaluate_middle_end(self, candidate, loop):
        return score_candidate(candidate, loop)

    def evaluate(self, candidate, observation):
        return self.evaluate_middle_end(candidate, {
            "scalar_cost": observation["ScalarCost"],
            "max_trip_count": observation["MaxTripCount"]})

    def choose_loop(self, rows, loop):
        best = None
        for candidate, status in rows:
            if status["status"] == "scored" and more_profitable(candidate, best, loop):
                best = candidate
        return best
