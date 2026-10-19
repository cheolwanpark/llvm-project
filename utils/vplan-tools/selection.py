"""Checkout-local policy loading and common protocol v3 selection mechanics."""
from importlib.util import module_from_spec, spec_from_file_location
import hashlib
from pathlib import Path

from model_errors import ToolError


class PolicyBase:
    supports_fit = False
    supports_ranking = True
    supports_spill_count_unit = False
    scalar_reason = "no evaluable vector candidates"

    def __init__(self, weights_path=None, spill_count_unit=None):
        if weights_path and not self.supports_fit:
            raise ToolError(f"{self.name} is a fixed ablation policy; fitting and weights are unsupported")
        if spill_count_unit is not None and not self.supports_spill_count_unit:
            raise ToolError(f"{self.name} does not support --spill-count-unit")
        self.spill_count_unit = spill_count_unit or "instruction"
        if self.spill_count_unit not in ("instruction", "register"):
            raise ToolError("invalid spill count unit")

    def choose(self, rows):
        eligible = [(c, s) for c, s in rows if s["status"] == "scored"]
        return min(eligible, key=lambda pair: pair[1]["score"])[0] if eligible else None


def load_policy(checkout=None, weights_path=None, spill_count_unit=None):
    directory = Path(checkout) / "utils/vplan-tools" if checkout else Path(__file__).resolve().parent
    path = directory / "selection_policy.py"
    if not path.is_file():
        raise ToolError(f"checkout has no v3 selection policy: {path}")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    spec = spec_from_file_location("vplan_policy_" + digest, path)
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    policy = module.Policy(weights_path, spill_count_unit)
    policy.identity = {"name": policy.name, "implementation": digest,
                       "spill_count_unit": policy.spill_count_unit if policy.supports_spill_count_unit else None,
                       "weights": hashlib.sha256(Path(weights_path).read_bytes()).hexdigest() if weights_path else None}
    return policy


def select_loops(policy, manifest, statuses):
    selections = []
    for loop in manifest["loops"]:
        key = (loop["function"], loop["loop"])
        rows = [(c, s) for c, s in zip(manifest["candidates"], statuses, strict=True)
                if (c["function"], c["loop"]) == key]
        selected = policy.choose(rows)
        choice = {"function": key[0], "loop": key[1], "scalar": selected is None,
                  "ic": 1, "epilogue_vf": "f0"}
        if selected is None:
            choice["reason"] = policy.scalar_reason
        else:
            choice["id"] = selected["id"]
        selections.append(choice)
    return selections
