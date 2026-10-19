"""Backend cost policy. Ablation branches replace only this policy module."""
from selection import PolicyBase
from cost_model import load_weights, score_observation


class Policy(PolicyBase):
    name = "backend-aware-cost"
    supports_fit = True
    scalar_reason = "no evaluable scalable vector candidates"

    def __init__(self, weights_path=None, spill_count_unit=None):
        super().__init__(weights_path, spill_count_unit)
        self.weights = load_weights(weights_path)[1] if weights_path else None

    def evaluate(self, candidate, observation):
        breakdown = score_observation(observation, self.weights)
        return {"status": "scored", "score": breakdown["score"], "breakdown": breakdown}

    def choose(self, rows):
        return super().choose([(candidate, status) for candidate, status in rows
                               if candidate["vf"].startswith("s")])
