"""Score replayed selections and summarize benchmark-level metrics."""
from collections import Counter
import statistics

import vplan_tools as vt


def selection_row(benchmark, result, expected_vlen=None):
    row = dict(id=benchmark.id, split=benchmark.kind, eligible=False,
               compile_failed=bool(result.returncode), status="compile-failed",
               reason=None, actual_selection=None, selected_vf=None,
               measured_cycles={str(v): c for v, c in benchmark.measured.items()},
               ignored_measured_cycles={}, evaluated_vfs=[],
               top1_correct=None, top1_regret=None)
    if result.returncode:
        row["reason"] = result.stderr[-3000:]
        return row
    outcome = getattr(result, "driver_result", {})
    if outcome.get("status") == "backend-observation-unavailable":
        row.update(status=outcome["status"], reason=outcome["reason"],
                   unavailable_candidates=outcome["unavailable_candidates"])
        return row
    manifest, final = result.manifest, result.final_manifest
    if (final["selections"] != result.selection["selections"] or final["failures"]
            or final["candidates"] != manifest["candidates"] or final["loops"] != manifest["loops"]
            or final["run_id"] != result.selection["run_id"] or final["run_id"] != manifest["run_id"]):
        raise vt.ToolError("final replay mismatch")
    loops = manifest["loops"]
    choices = final["selections"]
    if len(loops) != 1 or len(choices) != 1 or loops[0]["function"] != "selected_kernel":
        row.update(status="ambiguous-loops" if loops else "no-loop", reason="expected one selected_kernel loop")
        return row
    candidate_vfs = {int(c["vf"][1:]) for c in manifest["candidates"]
                     if c["function"] == loops[0]["function"] and c["loop"] == loops[0]["loop"]
                     and c["vf"].startswith("s")}
    row["evaluated_vfs"] = sorted(candidate_vfs)
    actual = dict(choices[0])
    row["actual_selection"] = actual
    if actual["scalar"]:
        actual.update(main_vf="f1", emitted=False)
    else:
        candidate = next(c for c in manifest["candidates"] if c["id"] == actual["id"])
        actual.update(main_vf=candidate["vf"], emitted=True)
    try:
        benchmark = vt.restrict_measurements(benchmark, candidate_vfs)
    except vt.ToolError as exc:
        row.update(status="missing-measurements", reason=str(exc))
        return row
    row["measured_cycles"] = {str(v): c for v, c in benchmark.measured.items()}
    row["ignored_measured_cycles"] = {str(v): c for v, c in benchmark.ignored_measured.items()}
    statuses = {s["id"]: s for s in result.candidate_status["candidates"]}
    middle_end = result.candidate_status.get("policy", {}).get("name") == "llvm-middle-end"
    if expected_vlen and not middle_end and any(s.get("vlen") != expected_vlen
            for s in statuses.values() if s["status"] == "scored"):
        row.update(status="vlen-mismatch", reason="analytics VLEN differs from measured VLEN")
        return row
    if actual["scalar"]:
        scoped = result.candidate_status.get('policy', {}).get('candidate_scope') == 'scalable'
        row.update(status="no-scalable-candidates" if scoped else "scalar-selection", reason=actual.get("reason"))
        return row
    vf = candidate["vf"]
    if vf.startswith("s"):
        row["selected_vf"] = int(vf[1:])
    selected, measured = row["selected_vf"], benchmark.measured
    if selected not in measured:
        row.update(status="unmeasured-vf", reason=f"no measurement for {vf}")
    elif len(measured) < 2:
        row.update(status="insufficient-measurements", reason="fewer than two measured VFs")
    else:
        winner = min(measured, key=lambda v: (measured[v], v))
        row.update(status="scored", eligible=True, top1_correct=selected == winner,
                   top1_regret=measured[selected] / measured[winner] - 1,
                   regret_exact={"numerator": measured[selected] - measured[winner], "denominator": measured[winner]})
    return row


def summarize_rows(rows):
    scored = [r for r in rows if r["eligible"]]
    regrets = [r["top1_regret"] for r in scored]
    return dict(total=len(rows), scored=len(scored), excluded=len(rows) - len(scored),
                compile_failed=sum(r["compile_failed"] for r in rows),
                coverage=len(scored) / len(rows) if rows else None,
                statuses=dict(Counter(r["status"] for r in rows)),
                top1=dict(n=len(scored), exact=statistics.mean(r["top1_correct"] for r in scored) if scored else None),
                top1_regret=dict(n=len(regrets), mean=statistics.mean(regrets) if regrets else None,
                                median=statistics.median(regrets) if regrets else None,
                                p95=vt.percentile(regrets, .95) if regrets else None))
