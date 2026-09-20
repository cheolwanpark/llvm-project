#!/usr/bin/env python3
# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
import concurrent.futures, hashlib, json, pathlib, re, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
C = pathlib.Path(sys.argv[1])
results = []
rs = [
    r
    for r in json.loads((C / "results.json").read_text())
    if r["mode"] == "fission" and r["status"] == "compiled"
]


def run(r):
    d = pathlib.Path(r["directory"])
    m = json.loads((d / "command.json").read_text())
    cmd = [
        str(ROOT / "build-fission/bin/llc"),
        *m["backend_flags"],
        "-verify-machineinstrs",
        "-start-after=riscv-vl-optimizer",
        "-stop-after=virtregrewriter",
        str(d / "before-vl-optimizer.mir"),
        "-o",
        str(d / "after-register-allocation.mir"),
    ]
    p = subprocess.run(cmd, capture_output=True, text=True)
    (d / "after-ra.stdout.log").write_text(p.stdout)
    (d / "after-ra.stderr.log").write_text(p.stderr)
    m["commands"].append(
        {"stage": "after-register-allocation", "argv": cmd, "returncode": p.returncode}
    )
    result = {"id": r["id"], "vf": r["vf"], "returncode": p.returncode}
    if p.returncode == 0:
        text = (d / "after-register-allocation.mir").read_text()
        body = text.split("body:             |")[-1]
        result["physical_vector_instructions"] = len(
            re.findall(r"^\s*[^\n]*\$v\d+(?:m[248])?[^\n]*PseudoV", body, re.M)
        )
        result["physical_liveins"] = re.findall(r"liveins: ([^\n]*)", body)
        m["artifacts"]["after-register-allocation.mir"] = hashlib.sha256(
            text.encode()
        ).hexdigest()
    (d / "command.json").write_text(json.dumps(m, indent=2))
    return result


with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    for r in pool.map(run, rs):
        results.append(r)
(C / "after-ra-summary.json").write_text(json.dumps(results, indent=2))
print(len(results), "verified", sum(r["returncode"] == 0 for r in results))
