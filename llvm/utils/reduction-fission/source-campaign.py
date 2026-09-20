#!/usr/bin/env python3
# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#!/usr/bin/env python3
"""Regenerate discovery and candidate kernels from every archived C context.
Imports only record parsing/backend-profile/assembly workaround helpers from the
suite. Its SCC transform verifier is deliberately not used.
"""

import concurrent.futures, hashlib, json, pathlib, re, shutil, subprocess, sys, os

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = pathlib.Path(
    os.environ.get(
        "FISSION_ARTIFACT_ROOT",
        ROOT / "build-fission/experiments/reduction-fission-goal",
    )
).resolve()
SUITE = ROOT.parent / "code-lab/microbench/suite-vf-fission-sweep"
OUT = BASE / (sys.argv[1] if len(sys.argv) > 1 else "source-campaign")
BIN = ROOT / "build-fission/bin"
sys.path.insert(0, str(SUITE.parent / "tools"))
sys.path.insert(0, str(SUITE.parent.parent))
from isolated_loops import evidence, core, target

M = json.loads((SUITE / "manifest.json").read_text())
OUT.mkdir(exist_ok=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, obj):
    path.write_text(json.dumps(obj, indent=2))


write(
    OUT / "identity.json",
    {
        "scope": "full C frontend regeneration, discovery and verified kernel codegen; no RTL measurements",
        "revision": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
        ).strip(),
        "clang_sha256": digest(BIN / "clang"),
        "manifest_sha256": digest(SUITE / "manifest.json"),
        "header_image": "sha256:9fbd6174824d187655eb6e3803b34025e8b053dabd7ef2b361edcbc9580903f0",
        "headers": {
            str(p.relative_to(BASE / "headers")): digest(p)
            for p in (BASE / "headers").rglob("*")
            if p.is_file()
        },
        "helpers": {
            str(p): digest(p)
            for p in [
                pathlib.Path(evidence.__file__),
                pathlib.Path(core.__file__),
                pathlib.Path(target.__file__),
            ]
        },
    },
)
(OUT / "source.diff").write_text(
    subprocess.check_output(["git", "diff"], cwd=ROOT, text=True)
)
for c in M["inventory"]:
    p = SUITE / "generated/sources" / c.get("source_file", c["id"] + ".c")
    d = OUT / "sources" / p.name
    d.parent.mkdir(exist_ok=True)
    shutil.copyfile(p, d)


def compile_case(c, mode=None, vf=None):
    ident = c["id"]
    d = OUT / ("discovery" if mode is None else "variants") / ident
    if mode:
        d = d / mode / ("scalable-vf" + str(vf))
    d.mkdir(parents=True, exist_ok=True)
    source = OUT / "sources" / c.get("source_file", ident + ".c")
    old = json.loads(
        (SUITE / "generated/discovery" / ident / "command.json").read_text()
    )
    result = {
        "id": ident,
        "mode": mode,
        "vf": vf,
        "source_sha256": digest(source),
        "directory": str(d),
        "commands": [],
    }

    def call(stage, args):
        cmd = [str(x) for x in args]
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        (d / (stage + ".stdout.log")).write_text(p.stdout)
        (d / (stage + ".stderr.log")).write_text(p.stderr)
        result["commands"].append(
            {"stage": stage, "argv": cmd, "returncode": p.returncode}
        )
        write(d / "command.json", result)
        if p.returncode:
            raise RuntimeError(
                stage + " failed (" + str(p.returncode) + "): " + p.stderr[-1000:]
            )
        return p

    def flags(stage):
        orig = next(x["argv"] for x in old["commands"] if x["stage"] == stage)
        cmd = [BIN / "clang"]
        i = 1
        while i < len(orig):
            v = orig[i]
            if v == "-o":
                i += 2
                continue
            if v.endswith(".c"):
                i += 1
                continue
            if v.startswith("-foptimization-record-file="):
                i += 1
                continue
            if v == "-mllvm" and orig[i + 1].startswith("-ir-dump-directory="):
                i += 2
                continue
            v = v.replace(
                "/opt/builder/include", str(BASE / "headers/builder")
            ).replace(
                "/usr/lib/picolibc/riscv64-unknown-elf/include",
                str(BASE / "headers/picolibc"),
            )
            cmd.append(v)
            i += 1
        if mode:
            cmd += [
                "-mllvm",
                "-force-vector-width="
                + ("fission:" if mode == "fission" else "")
                + str(vf),
            ]
        return cmd

    try:
        if mode is None:
            call(
                "scalar-frontend",
                flags("scalar-frontend") + [source, "-o", d / "scalar.ll"],
            )
        call(
            "compile",
            flags("compile")
            + [
                source,
                "-o",
                d / "final.ll",
                "-foptimization-record-file=" + str(d / "remarks.yaml"),
                "-mllvm",
                "-ir-dump-directory=" + str(d / "pass-dumps"),
                "-Xclang",
                "-fdebug-pass-manager",
            ],
        )
        records = evidence.remarks((d / "remarks.yaml").read_text())
        write(d / "remarks.json", records)
        if mode is None:
            result["candidates"] = evidence.candidates(
                records, source.read_text(), source.name
            )
        for which in ["before", "after"]:
            dumps = [
                p
                for p in (d / "pass-dumps").glob("*" + which + ".ll")
                if re.search(
                    "IR Dump "
                    + which.title()
                    + " LoopVectorizePass on selected_kernel",
                    p.read_text().splitlines()[0],
                )
            ]
            if len(dumps) > 1:
                raise RuntimeError("multiple selected_kernel dumps")
            if dumps:
                (d / (which + ".ll")).write_text(
                    "\n".join(dumps[0].read_text().splitlines()[1:]) + "\n"
                )
        for which in ["before", "after", "final"]:
            path = d / (which + ".ll")
            if path.exists():
                call(
                    "verify-" + which,
                    [
                        BIN / "opt",
                        "-passes=verify,print<loops>",
                        "-disable-output",
                        path,
                    ],
                )
        result["status"] = "discovered" if mode is None else "compiled"
        if mode:
            ir = (d / "final.ll").read_text()
            bf = core.backend_flags(ir, {"triple": "riscv64-unknown-elf"})
            result["backend_flags"] = bf
            result["backend_policy"] = "verified-skip-vl-optimizer-v1"
            call(
                "before-vl",
                [
                    BIN / "llc",
                    *bf,
                    "-verify-machineinstrs",
                    "-stop-before=riscv-vl-optimizer",
                    d / "final.ll",
                    "-o",
                    d / "before-vl-optimizer.mir",
                ],
            )
            call(
                "llc",
                [
                    BIN / "llc",
                    *bf,
                    "-verify-machineinstrs",
                    "-start-after=riscv-vl-optimizer",
                    d / "before-vl-optimizer.mir",
                    "-o",
                    d / "xiangshan.raw.s",
                ],
            )
            raw = (d / "xiangshan.raw.s").read_text()
            patched, info = target.patch(raw)
            target.check_patched(patched)
            (d / "xiangshan.s").write_text(patched)
            result["workaround"] = info
            call(
                "assemble",
                [
                    BIN / "clang",
                    "--target=riscv64-unknown-elf",
                    "-march=rv64gcv_zba_zbb_zbc_zbs_zicbom_zicboz_zvl128b",
                    "-mcpu=xiangshan-kunminghu",
                    "-mabi=lp64d",
                    "-c",
                    d / "xiangshan.s",
                    "-o",
                    d / "kernel.o",
                ],
            )
            result["committed"] = any(
                r["name"] == "ReductionFissionCommitted" for r in records
            )
            result["plans"] = [
                r for r in records if r["name"] == "ReductionFissionContribution"
            ]
            result["schedules"] = [
                r for r in records if r["name"] == "ReductionFissionSchedule"
            ]
            if mode == "fission" and not result["committed"]:
                result["status"] = "rejected"
            result["reasons"] = [
                r
                for r in records
                if r["name"].startswith("ReductionFission") and r["kind"] == "!Missed"
            ]
            if core.SEGMENT_RE.search(core.selected_body(raw)):
                result["status"] = "unsupported XiangShan segmented memory instruction"
    except Exception as e:
        result["status"] = "failed"
        result["error"] = str(e)
    result["artifacts"] = {
        p.name: digest(p)
        for p in d.iterdir()
        if p.is_file() and p.name != "command.json"
    }
    write(d / "command.json", result)
    # Keep the summary compact; full commands/remarks stay with each artifact.
    return {
        k: v
        for k, v in result.items()
        if k
        not in [
            "commands",
            "artifacts",
            "backend_flags",
            "plans",
            "schedules",
            "reasons",
        ]
    }


if __name__ == "__main__":
    discoveries = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for r in pool.map(compile_case, M["inventory"]):
            discoveries.append(r)
            write(OUT / "discovery.json", discoveries)
            if len(discoveries) % 25 == 0:
                print(
                    "discovery", len(discoveries), "/", len(M["inventory"]), flush=True
                )
    tasks = {(a["benchmark"], a["mode"], a["vf"]) for a in M["attempts"]}
    for r in discoveries:
        for mode, vfs in r.get("candidates", {}).items():
            tasks.update((r["id"], mode, vf) for vf in vfs)
    cases = {c["id"]: c for c in M["inventory"]}
    results = []
    print("variants", len(tasks), flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for r in pool.map(
            lambda t: compile_case(cases[t[0]], t[1], t[2]), sorted(tasks)
        ):
            results.append(r)
            write(OUT / "results.json", results)
            if len(results) % 50 == 0:
                print("variants", len(results), "/", len(tasks), flush=True)
    print("done", len(results), flush=True)
