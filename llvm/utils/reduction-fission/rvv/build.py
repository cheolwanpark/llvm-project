import hashlib, json, pathlib, re, subprocess, sys, shutil

SCRIPT = pathlib.Path(__file__).resolve().parent
ROOT = SCRIPT.parents[3]
OUT = pathlib.Path(sys.argv[1]).resolve()
OUT.mkdir(parents=True, exist_ok=True)
BIN = ROOT / "build-fission/bin"
TEST = ROOT / "llvm/test/Transforms/LoopVectorize/RISCV"
for name in ["harness.c", "allocation-guard.c"]:
    shutil.copyfile(SCRIPT / name, OUT / name)
files = [
    "normalize",
    "fp-semantics",
    "empty-map",
    "contributions",
    "short-loops",
    "pressure",
    "conditional-minmax",
    "widening-streams",
    "shared-short-loops",
    "minmax-chains",
]
source = "\n".join(
    (TEST / ("reduction-fission-" + n + ".ll")).read_text() for n in files
)
streams = (TEST / "reduction-fission-streams.ll").read_text()
source += (
    "\n@bounded = external global [64 x float]\n"
    + re.search(r"^define float @bounded_global_stream\(.*?^}", streams, re.M | re.S)[0]
    + "\n"
)
source = re.sub(r"^(target triple|attributes #0).*$", "", source, flags=re.M)
# Multiple fixtures can declare the same intrinsic.
seen = set()
source = "\n".join(
    line
    for line in source.splitlines()
    if not (line.startswith("declare ") and (line in seen or seen.add(line)))
)
source += "\nattributes #0 = { vscale_range(2,1024) }\n"
(OUT / "before.ll").write_text(source)
names = re.findall(r"^define .*?@([\w.]+)\(", source, re.M)
ref = re.sub(
    r"@([\w.]+)\(",
    lambda m: "@" + ("ref_" if m[1] in names else "") + m[1] + "(",
    source,
)
(OUT / "reference.ll").write_text(ref)
c = json.loads(
    (
        ROOT.parent
        / "code-lab/microbench/suite-vf-fission-sweep/generated/mlas-sgemm-8acc/fission/scalable-vf2/command.json"
    ).read_text()
)
bf = [
    x.replace("riscv64-unknown-elf", "riscv64-unknown-linux-gnu")
    for x in c["backend_flags"]
]
commands = []


def run(stage, args):
    p = subprocess.run([str(x) for x in args], capture_output=True, text=True)
    commands.append(
        {"stage": stage, "argv": [str(x) for x in args], "returncode": p.returncode}
    )
    (OUT / (stage + ".stdout.log")).write_text(p.stdout)
    (OUT / (stage + ".stderr.log")).write_text(p.stderr)
    (OUT / "commands.json").write_text(json.dumps(commands, indent=2))
    p.check_returncode()


run(
    "vectorize",
    [
        BIN / "opt",
        "-passes=loop-vectorize,verify",
        "-mtriple=riscv64-unknown-linux-gnu",
        "-mcpu=xiangshan-kunminghu",
        "-mattr=+v,+f,+d",
        "-force-vector-width=fission:2",
        "-scalable-vectorization=on",
        "-force-vector-interleave=1",
        "-riscv-v-vector-bits-min=128",
        "-pass-remarks=loop-vectorize",
        "-pass-remarks-missed=loop-vectorize",
        "-pass-remarks-analysis=loop-vectorize",
        "-verify-dom-info",
        "-verify-loop-info",
        "-verify-scev",
        "-S",
        OUT / "before.ll",
        "-o",
        OUT / "transformed.ll",
    ],
)
for name in ["reference", "transformed"]:
    run(
        name + "-before-vl",
        [
            BIN / "llc",
            *bf,
            "-verify-machineinstrs",
            "-stop-before=riscv-vl-optimizer",
            OUT / (name + ".ll"),
            "-o",
            OUT / (name + ".mir"),
        ],
    )
    run(
        name + "-llc",
        [
            BIN / "llc",
            *bf,
            "-verify-machineinstrs",
            "-start-after=riscv-vl-optimizer",
            OUT / (name + ".mir"),
            "-o",
            OUT / (name + ".s"),
        ],
    )
    run(
        name + "-assemble",
        [
            BIN / "clang",
            "--target=riscv64-unknown-linux-gnu",
            "-march=rv64gcv_zba_zbb_zbc_zbs_zicbom_zicboz_zvl128b",
            "-mcpu=xiangshan-kunminghu",
            "-mabi=lp64d",
            "-c",
            OUT / (name + ".s"),
            "-o",
            OUT / (name + ".o"),
        ],
    )
(OUT / "identity.json").write_text(
    json.dumps(
        {
            "compiler_sha256": hashlib.sha256((BIN / "opt").read_bytes()).hexdigest(),
            "source_fixtures": files,
            "source_sha256": hashlib.sha256(source.encode()).hexdigest(),
            "backend_policy": "verified-skip-vl-optimizer-v1",
            "profile": "archived XiangShan backend flags; Linux triple for QEMU userspace linking",
            "reference": "original scalar fixture IR, renamed symbols, same llc backend profile",
            "transformed": "loop-vectorize + IR verifier + two-stage machine verifier",
        },
        indent=2,
    )
)
print("built", len(names), "reference/transformed functions")
