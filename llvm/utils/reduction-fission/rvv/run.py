import hashlib, json, pathlib, re, subprocess, sys

out = pathlib.Path(sys.argv[1]).resolve()
(out / "results.json").unlink(missing_ok=True)
commands = []
results = []


def run(stage, args):
    p = subprocess.run(args, capture_output=True, text=True, timeout=90)
    commands.append({"stage": stage, "argv": args, "returncode": p.returncode})
    (out / (stage + ".stdout.log")).write_text(p.stdout)
    (out / (stage + ".stderr.log")).write_text(p.stderr)
    (out / "run-commands.json").write_text(json.dumps(commands, indent=2))
    p.check_returncode()
    return p


run(
    "qemu-version",
    ["docker", "exec", "reduction-fission-rvv", "qemu-riscv64", "--version"],
)
run(
    "packages",
    [
        "docker",
        "exec",
        "reduction-fission-rvv",
        "dpkg-query",
        "-W",
        "qemu-user",
        "gcc-riscv64-linux-gnu",
        "libc6-dev-riscv64-cross",
    ],
)
run(
    "link",
    [
        "docker",
        "exec",
        "reduction-fission-rvv",
        "riscv64-linux-gnu-gcc",
        "-O2",
        "-fsignaling-nans",
        "-fno-tree-vectorize",
        "-fno-tree-slp-vectorize",
        "-march=rv64gc",
        "-mabi=lp64d",
        "/work/harness.c",
        "/work/allocation-guard.c",
        "-Wl,--wrap=malloc,--wrap=free",
        "/work/reference.o",
        "/work/transformed.o",
        "-lm",
        "-o",
        "/work/validate",
    ],
)
for vlen in [128, 256, 512]:
    p = run(
        "vlen" + str(vlen),
        [
            "docker",
            "exec",
            "reduction-fission-rvv",
            "qemu-riscv64",
            "-L",
            "/usr/riscv64-linux-gnu",
            "-cpu",
            f"rv64,v=true,vlen={vlen},elen=64,vext_spec=v1.0",
            "/work/validate",
        ],
    )
    n = int(re.search(r"passed (\d+)", p.stdout)[1])
    results.append(
        {
            "vlen": vlen,
            "comparisons": n,
            "exit_code": p.returncode,
            "allocation_guard": p.stdout.splitlines()[0],
        }
    )
    print(vlen, p.stdout.strip(), flush=True)
(out / "results.json").write_text(
    json.dumps(
        {
            "runner": "QEMU RVV 8.2.2, Linux userspace in disposable ubuntu24.04 amd64 container",
            "results": results,
            "total_comparisons": sum(x["comparisons"] for x in results),
            "binary_sha256": hashlib.sha256(
                (out / "validate").read_bytes()
            ).hexdigest(),
            "harness_sha256": hashlib.sha256(
                (out / "harness.c").read_bytes()
            ).hexdigest(),
            "target_semantics_not_rtl_performance": True,
            "conditional_minmax": "transformed, with initializer NaN/Inf/zero corrections",
        },
        indent=2,
    )
)
