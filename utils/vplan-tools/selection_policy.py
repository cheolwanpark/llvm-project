"""Fixed ablation: select the largest scalable VF without vector spills."""
from selection import PolicyBase
from spill_observations import project_spills


class Policy(PolicyBase):
    name = "spill-reject"
    supports_ranking = False
    scalar_reason = "no zero-vector-spill scalable candidates"

    def evaluate(self, candidate, observation):
        if not candidate["vf"].startswith("s"):
            return {"status": "rejected", "reason": "fixed-width-candidate"}
        counts = project_spills(candidate, observation)
        accepted = not any(row["spills"] or row["reloads"] for row in counts if row["kind"] == "vector")
        return {"status": "accepted" if accepted else "rejected",
                "reason": "zero-vector-spill" if accepted else "vector-spill-or-reload",
                "breakdown": {"counts": counts}}

    def choose(self, rows):
        accepted = [c for c, s in rows if s["status"] == "accepted"]
        # max keeps the first equal-width candidate; inspect every VF because
        # spills need not increase monotonically with width.
        return max(accepted, key=lambda c: int(c["vf"][1:])) if accepted else None
