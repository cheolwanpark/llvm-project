#!/usr/bin/env python3
# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
"""Build isolated baseline/preservation-only frontends; never overwrite live objects."""

import concurrent.futures, hashlib, json, os, pathlib, shlex, shutil, subprocess

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASELINE_REVISION = "000d853e209a8ab64b7b10dbc1333cfb46f9e501"
BUILD = ROOT / "build-fission"
OUT = (
    pathlib.Path(
        os.environ.get(
            "FISSION_ARTIFACT_ROOT",
            ROOT / "build-fission/experiments/reduction-fission-goal",
        )
    )
    / "controls"
)
OUT.mkdir(exist_ok=True)
SOURCE = ROOT / "llvm/lib/Transforms/Vectorize"
NINJA = "/opt/homebrew/bin/ninja"
ENV = {**os.environ, "DEVELOPER_DIR": "/Library/Developer/CommandLineTools"}


def command(target):
    return subprocess.check_output(
        [NINJA, "-C", str(BUILD), "-t", "commands", target], text=True
    ).splitlines()[-1]


def run(args, log, cwd=BUILD):
    p = subprocess.run(args, cwd=cwd, env=ENV, capture_output=True, text=True)
    log.write_text(p.stdout + p.stderr)
    p.check_returncode()


for mode in ["baseline", "preservation-only"]:
    out = OUT / mode
    src = out / "src"
    src.mkdir(parents=True, exist_ok=True)
    for h in SOURCE.glob("*.h"):
        shutil.copyfile(h, src / h.name)
    files = [
        "ReductionFission.cpp",
        "ReductionFission.h",
        "LoopVectorize.cpp",
        "VPlanTransforms.cpp",
        "VPlanTransforms.h",
    ]
    for name in files:
        (src / name).write_bytes(
            subprocess.check_output(
                [
                    "git",
                    "show",
                    BASELINE_REVISION + ":llvm/lib/Transforms/Vectorize/" + name,
                ],
                cwd=ROOT,
            )
        )
    if mode == "preservation-only":
        for name in ["VPlanTransforms.cpp", "VPlanTransforms.h"]:
            shutil.copyfile(SOURCE / name, src / name)
        p = src / "LoopVectorize.cpp"
        s = p.read_text()
        old = "VPlanTransforms::optimizeForVFAndUF(BestVPlan, BestVF, BestUF, PSE);"
        assert s.count(old) == 1
        p.write_text(
            s.replace(
                old,
                'VPlanTransforms::optimizeForVFAndUF(BestVPlan, BestVF, BestUF, PSE,\n      findOptionMDForLoop(OrigLoop, "llvm.loop.reduction.fission.reduction"));',
            )
        )
    commands = []

    def compile(name):
        obj = out / (name + ".o")
        target = "lib/Transforms/Vectorize/CMakeFiles/LLVMVectorize.dir/" + name + ".o"
        args = shlex.split(command(target))
        args.insert(1, "-I" + str(src))
        args = [str(src / name) if x == str(SOURCE / name) else x for x in args]
        for flag, value in [("-o", obj), ("-MF", out / (name + ".d")), ("-MT", obj)]:
            args[args.index(flag) + 1] = str(value)
        run(args, out / (name + ".log"))
        return {"stage": name, "argv": args}

    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        commands.extend(
            pool.map(
                compile,
                ["ReductionFission.cpp", "LoopVectorize.cpp", "VPlanTransforms.cpp"],
            )
        )
    archive = out / "libLLVMVectorize.a"
    shutil.copyfile(BUILD / "lib/libLLVMVectorize.a", archive)
    args = [
        "/opt/homebrew/opt/llvm/bin/llvm-ar",
        "rcs",
        str(archive),
        *[
            str(out / (n + ".o"))
            for n in [
                "ReductionFission.cpp",
                "LoopVectorize.cpp",
                "VPlanTransforms.cpp",
            ]
        ],
    ]
    run(args, out / "archive.log")
    commands.append({"stage": "archive", "argv": args})
    (out / "bin").mkdir(exist_ok=True)
    (out / "lib").mkdir(exist_ok=True)
    link = out / "lib/clang"
    if not link.exists():
        link.symlink_to(BUILD / "lib/clang", target_is_directory=True)
    for name, target in [("clang", "bin/clang-22"), ("opt", "bin/opt")]:
        args = shlex.split(command(target))
        args = args[2:-2] if args[:2] == [":", "&&"] else args
        args = [str(archive) if x == "lib/libLLVMVectorize.a" else x for x in args]
        args[args.index("-o") + 1] = str(out / "bin" / name)
        run(args, out / (name + "-link.log"))
        commands.append({"stage": "link-" + name, "argv": args})
    (out / "commands.json").write_text(json.dumps(commands, indent=2))
    (out / "identity.json").write_text(
        json.dumps(
            {
                "mode": mode,
                "revision": BASELINE_REVISION,
                "overlay": {
                    p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in src.iterdir()
                },
                "binaries": {
                    p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in (out / "bin").iterdir()
                },
            },
            indent=2,
        )
    )
    print(mode, "ready", flush=True)
