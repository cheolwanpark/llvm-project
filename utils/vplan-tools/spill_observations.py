"""Cost-free projection of common post-RA facts into six spill buckets."""
from model_errors import ToolError

BUCKETS = (("gpr", 1), ("fpr", 1), ("vector", 1), ("vector", 2), ("vector", 4), ("vector", 8))


def iteration_ratio(candidate, observation):
    if observation["Error"]:
        raise ToolError(observation["Error"])
    original, observed = candidate["estimated_width"], observation["Width"]
    if not 0 < original <= observed <= 2**32 - 1 or observed % original:
        raise ToolError("unproven-iteration-width")
    if not any(b["Role"] == "body" for b in observation["Blocks"]):
        raise ToolError("missing-loop")
    return observed // original


def project_spills(candidate, observation):
    """Missing facts reject the observation; they never supply zero counts."""
    iteration_ratio(candidate, observation)
    body = {b["ID"] for b in observation["Blocks"] if b["Role"] == "body"}
    counts = [dict(kind=bank, registers=group, spills=0, reloads=0) for bank, group in BUCKETS]
    for i in observation["Instructions"]:
        if i["Block"] not in body or i["Meta"] or not (i["Load"] or i["Store"]):
            continue
        if i["SpillSlotAccess"] and not i["Spill"]:
            raise ToolError("unrecognized-spill-access")
        if i["Stack"] and i["Bytes"] <= 0:
            raise ToolError("unrecognized-stack-access")
        if not i["Spill"]:
            continue
        if not i["Stack"] or i["Load"] == i["Store"] or not i["Operands"] or i["Bytes"] <= 0:
            raise ToolError("unrecognized-spill-access")
        operand = i["Operands"][0]
        bank = operand["Bank"]
        if bank in ("gpr", "fpr") and not i["ScalableBytes"]:
            group = 1
        elif bank == "vector" and operand["Vector"] and i["ScalableBytes"]:
            group, remainder = divmod(i["Bytes"], 8)  # RISCV::RVVBytesPerBlock
            if remainder or group not in (1, 2, 4, 8):
                raise ToolError("unrecognized-spill-group")
        else:
            raise ToolError("unrecognized-spill-register")
        counts[BUCKETS.index((bank, group))]["reloads" if i["Load"] else "spills"] += 1
    return counts
