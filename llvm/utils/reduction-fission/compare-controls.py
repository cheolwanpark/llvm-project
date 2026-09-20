#!/usr/bin/env python3
# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
import concurrent.futures, hashlib, json, pathlib, re, subprocess, sys, os

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = pathlib.Path(
    os.environ.get(
        "FISSION_ARTIFACT_ROOT",
        ROOT / "build-fission/experiments/reduction-fission-goal",
    )
).resolve()
CAMPAIGN = BASE / (sys.argv[1] if len(sys.argv) > 1 else "full-source-minmax")
OUT = BASE / ("control-comparisons-" + CAMPAIGN.name)
OUT.mkdir(exist_ok=True)
sys.path.insert(0, str(ROOT.parent / "code-lab"))
sys.path.insert(0, str(ROOT.parent / "code-lab/microbench/tools"))
from isolated_loops import target

records = json.loads((CAMPAIGN / "results.json").read_text())


def run(record, mode="baseline"):
    current = pathlib.Path(record["directory"])
    out = OUT / mode / record["id"] / record["mode"] / ("vf" + str(record["vf"]))
    out.mkdir(parents=True, exist_ok=True)
    meta = json.loads((current / "command.json").read_text())
    orig = next(x["argv"] for x in meta["commands"] if x["stage"] == "compile")
    cmd = [
        str(BASE / "controls" / mode / "bin/clang"),
        *[x.replace(str(current), str(out)) for x in orig[1:]],
    ]
    commands = []

    def call(stage, args):
        p = subprocess.run(args, capture_output=True, text=True)
        (out / (stage + ".stdout.log")).write_text(p.stdout)
        (out / (stage + ".stderr.log")).write_text(p.stderr)
        commands.append({"stage": stage, "argv": args, "returncode": p.returncode})
        (out / "commands.json").write_text(json.dumps(commands, indent=2))
        p.check_returncode()
        return p

    result = {
        "id": record["id"],
        "mode": record["mode"],
        "vf": record["vf"],
        "compiler": mode,
    }
    try:
        call("compile", cmd)
        old = (out / "final.ll").read_text()
        new = (current / "final.ll").read_text()
        result["identical_ir"] = old == new
        result["old_sha256"] = hashlib.sha256(old.encode()).hexdigest()
        result["new_sha256"] = hashlib.sha256(new.encode()).hexdigest()
        if record["mode"] == "fission":
            bf = meta["backend_flags"]
            llc = str(ROOT / "build-fission/bin/llc")
            p = call(
                "loop-info",
                [
                    str(ROOT / "build-fission/bin/opt"),
                    "-passes=verify,print<loops>",
                    "-disable-output",
                    str(out / "final.ll"),
                ],
            )
            result["loops"] = p.stderr.count("Loop at depth")
            call(
                "before-vl",
                [
                    llc,
                    *bf,
                    "-verify-machineinstrs",
                    "-stop-before=riscv-vl-optimizer",
                    str(out / "final.ll"),
                    "-o",
                    str(out / "before-vl.mir"),
                ],
            )
            call(
                "llc",
                [
                    llc,
                    *bf,
                    "-verify-machineinstrs",
                    "-start-after=riscv-vl-optimizer",
                    str(out / "before-vl.mir"),
                    "-o",
                    str(out / "xiangshan.raw.s"),
                ],
            )
            asm = (out / "xiangshan.raw.s").read_text()
            patched, info = target.patch(asm)
            (out / "xiangshan.s").write_text(patched)
            result["vector_spills"] = len(
                re.findall(r"^\s+v\w+[^\n]*Folded (?:Spill|Reload)", asm, re.M)
            )
            result["buffers"] = len(re.findall(r"alloca \[31 x float\]", old))
            result["static_instructions"] = len(
                list(target.INSTRUCTION_RE.finditer(target.selected_body(asm)))
            )
        result["status"] = "passed"
    except Exception as e:
        result["status"] = "failed"
        result["error"] = str(e)
    (out / "result.json").write_text(json.dumps(result, indent=2))
    return result


results = []
normal = [r for r in records if r["mode"] == "normal"]
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    for r in pool.map(run, normal):
        results.append(r)
        if len(results) % 100 == 0:
            print("normal", len(results), "/", len(normal), flush=True)
        (OUT / "normal.json").write_text(json.dumps(results, indent=2))
sgemm = next(
    r
    for r in records
    if r["id"] == "mlas-sgemm-8acc" and r["mode"] == "fission" and r["vf"] == 2
)
results = [run(sgemm, mode) for mode in ["baseline", "preservation-only"]]
(OUT / "sgemm.json").write_text(json.dumps(results, indent=2))
print(results, flush=True)
