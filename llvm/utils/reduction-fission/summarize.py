import collections, csv, hashlib, json, pathlib, re, sys, os

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = pathlib.Path(
    os.environ.get(
        "FISSION_ARTIFACT_ROOT",
        ROOT / "build-fission/experiments/reduction-fission-goal",
    )
).resolve()
C = BASE / "full-source-final"
sys.path.insert(0, str(ROOT.parent / "code-lab"))
sys.path.insert(0, str(ROOT.parent / "code-lab/microbench/tools"))
from isolated_loops import evidence, target

M = json.loads(
    (
        ROOT.parent / "code-lab/microbench/suite-vf-fission-sweep/manifest.json"
    ).read_text()
)
old = {(x["benchmark"], x["mode"], x["vf"]): x for x in M["attempts"]}
audit = {
    (x["id"], x["vf"]): x for x in json.loads((C / "boundary-audit.json").read_text())
}
rows = []
for r in json.loads((C / "results.json").read_text()):
    d = pathlib.Path(r["directory"])
    meta = json.loads((d / "command.json").read_text())
    records = json.loads((d / "remarks.json").read_text())
    orig = old.get((r["id"], r["mode"], r["vf"]), {})
    ir = (d / "final.ll").read_text()
    body = evidence.function_ir(ir)
    buffers = []
    for name, n, ty in re.findall(
        r"(%fission.buffer[\w.$-]*) = alloca \[(\d+) x (float|double|i\d+)\]", body
    ):
        size = {"float": 4, "double": 8}.get(ty) or (int(ty[1:]) + 7) // 8
        buffers.append(
            {"name": name, "count": int(n), "type": ty, "bytes": int(n) * size}
        )
    old_storage = orig.get("vector_configuration", {}).get("storage", [])
    a = audit.get((r["id"], r["vf"])) if r["mode"] == "fission" else None
    actual_normal = any(
        x["name"] == "Vectorized"
        and ["VectorizationFactor", "vscale x " + str(r["vf"])] in x["args"]
        for x in records
    )
    status = (
        ("committed, audited" if a and not a["errors"] else r["status"])
        if r["mode"] == "fission"
        else (
            "vectorized requested VF"
            if actual_normal
            else "not vectorized; unchanged baseline"
        )
    )
    raw = (d / "xiangshan.raw.s").read_text()
    asm = target.selected_body(raw)
    plans = [dict(x["args"]) for x in meta.get("plans", [])]
    row = {
        "case": r["id"],
        "mode": r["mode"],
        "requested_map_vf": r["vf"],
        "status": status,
        "old_status": orig.get("status", "new"),
        "map_form": (
            "empty"
            if a["empty_map"]
            else ("loop" if a["final"]["map_blocks"] else "folded block")
        )
        if a
        else "",
        "reducers": len(a["final"]["loops"]) if a else "",
        "reduction_vfs": ",".join(p[1] for l in a["final"]["loops"] for p in l["phis"])
        if a
        else "",
        "lmuls": ",".join(str(x) for x in a["lmuls"]) if a else "",
        "old_buffers": len(old_storage),
        "new_buffers": len(buffers),
        "old_payload_bytes": sum(x["bytes"] for x in old_storage),
        "new_payload_bytes": sum(x["bytes"] for x in buffers),
        "vector_spill_reload": len(
            re.findall(r"^\s+v\w+[^\n]*Folded (?:Spill|Reload)", asm, re.M)
        ),
        "scalar_spill_reload": len(
            re.findall(r"^\s+(?!v)\w+[^\n]*Folded (?:Spill|Reload)", asm, re.M)
        ),
        "raw_instruction_statements": len(list(target.INSTRUCTION_RE.finditer(asm))),
        "patched_instruction_statements": len(
            list(
                target.INSTRUCTION_RE.finditer(
                    target.selected_body((d / "xiangshan.s").read_text())
                )
            )
        ),
        "workaround_sites": meta["workaround"]["count"],
        "directory": str(d),
    }
    rows.append(row)
    detail = {
        "summary": row,
        "storage": buffers,
        "contribution_plans": plans,
        "boundary_audit": "boundary-audit.json" if a else None,
    }
    (d / "summary.json").write_text(json.dumps(detail, indent=2))
with (C / "summary.csv").open("w") as out:
    writer = csv.DictWriter(out, fieldnames=list(rows[0]))
    writer.writeheader()
    writer.writerows(rows)
(C / "summary.json").write_text(json.dumps(rows, indent=2))
print(collections.Counter((x["mode"], x["status"]) for x in rows))
for name in [
    "mlas-sgemm-8acc",
    "mlas-sgemm-4acc",
    "mlas-q4-minmax",
    "tsvc-s311-l00",
    "tsvc-s316-l00",
    "tsvc-s319-l00",
    "rajaperf-reduce-struct",
    "rodinia-srad-row",
    "mlas-globalavg-signed",
    "mlas-globalavg-unsigned",
    "tsvc-s3111-l00",
    "tsvc-s352-l00",
]:
    r = next(
        x
        for x in rows
        if x["case"] == name and x["mode"] == "fission" and x["requested_map_vf"] == 2
    )
    print(
        name,
        r["map_form"],
        r["reducers"],
        r["new_buffers"],
        r["new_payload_bytes"],
        r["raw_instruction_statements"],
        r["vector_spill_reload"],
    )
