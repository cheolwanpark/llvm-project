#!/usr/bin/env python3
# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
"""LLVM LoopInfo + feasible CFG, SSA collapse order and machine boundary audit."""

import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parents[3]


def load_suite_helpers():
    global evidence, target
    sys.path.insert(0, str(ROOT.parent / "code-lab"))
    sys.path.insert(0, str(ROOT.parent / "code-lab/microbench/tools"))
    from isolated_loops import evidence, target


def function_ir(ir):
    match = re.search(
        r"^define [^\n]*@selected_kernel\([^\n]*\{\n(.*?)^}", ir, re.M | re.S
    )
    if not match:
        raise ValueError("IR lacks selected_kernel definition")
    return match[1]


def reach(edges, start, blocked=()):
    seen = set()
    todo = [start]
    while todo:
        n = todo.pop()
        if n in seen or n in blocked:
            continue
        seen.add(n)
        todo.extend(edges.get(n, ()))
    return seen


def graph(ir):
    body = function_ir(ir)
    blocks = dict(
        re.findall(r"^([\w.$-]+):[^\n]*\n(.*?)(?=^[\w.$-]+:|\Z)", body, re.M | re.S)
    )
    edges = {}
    for name, block in blocks.items():
        b = re.search(
            r"^\s*br i1 (true|false), label %([\w.$-]+), label %([\w.$-]+)", block, re.M
        )
        edges[name] = (
            {b[2] if b[1] == "true" else b[3]}
            if b
            else set(re.findall(r"label %([\w.$-]+)", block))
        )
    return blocks, edges


def tagged_loops(ir, info):
    blocks, edges = graph(ir)
    md = dict(re.findall(r"^!(\d+) = (.*)$", ir, re.M))

    def tags(text):
        pending = re.findall(r"!llvm.loop !(\d+)", text)
        seen = set()
        values = ""
        while pending:
            k = pending.pop()
            if k in seen:
                continue
            seen.add(k)
            v = md.get(k, "")
            values += v
            pending += re.findall(r"!(\d+)", v)
        return values

    active = False
    loops = []
    maps = []
    for line in info.splitlines():
        if line.startswith("Loop info for function"):
            active = "'selected_kernel'" in line
        if not active or "Loop at depth" not in line:
            continue
        parts = re.findall(r"%([\w.$-]+)((?:<[^>]+>)*)", line)
        header = next((n for n, t in parts if "<header>" in t), None)
        latches = [n for n, t in parts if "<latch>" in t]
        labels = [n for n, t in parts]
        text = "\n".join(blocks.get(n, "") for n in labels)
        hints = "".join(tags(blocks.get(n, "")) for n in latches)
        if "llvm.loop.reduction.fission.reduction" not in hints:
            if "llvm.loop.reduction.fission.generated" in hints:
                maps += labels
            continue
        phis = re.findall(
            r"(%[\w.$-]+) = phi <vscale x (\d+) x (float|double|i\d+)>", text
        )
        if not phis:
            continue  # scalar tail
        loops.append(
            {
                "header": header,
                "blocks": labels,
                "latches": latches,
                "phis": phis,
                "cyclic": any(header in reach(edges, s) for s in edges.get(header, ())),
                "constant_branch": bool(re.search(r"br i1 (true|false)", text)),
            }
        )
    return blocks, edges, loops, maps


def ir_audit(directory, stage, expected):
    ir = (directory / (stage + ".ll")).read_text()
    info = (directory / ("verify-" + stage + ".stderr.log")).read_text()
    blocks, edges, loops, maps = tagged_loops(ir, info)
    errors = []
    definitions = {}
    location = {}
    for block, text in blocks.items():
        for value, expr in re.findall(r"^\s*(%[\w.$-]+) = (.*)$", text, re.M):
            definitions[value] = expr
            location[value] = block
    phi_owner = {phi[0]: i for i, l in enumerate(loops) for phi in l["phis"]}

    def origins(values):
        found = set()
        seen = set()
        todo = list(values)
        while todo:
            value = todo.pop()
            if value in seen:
                continue
            seen.add(value)
            if value in phi_owner:
                found.add(phi_owner[value])
                continue
            todo += re.findall(r"%[\w.$-]+", definitions.get(value, ""))
        return found

    for value, expr in definitions.items():
        if not re.search(r"\bcall\b.*@llvm.vector.reduce\.", expr):
            continue
        vectors = re.findall(r"<vscale x \d+ x [^>]+>\s+(%[\w.$-]+)", expr)
        owners = origins(vectors)
        if len(owners) != 1:
            errors.append(
                "horizontal reduction has ambiguous accumulator origin: " + value
            )
            continue
        owner = next(iter(owners))
        loops[owner].setdefault("collapses", []).append(
            {"value": value, "block": location[value]}
        )
    if len(loops) != len(expected):
        errors.append(f"reducer count {len(loops)} != {len(expected)}")
    headers = {l["header"] for l in loops}
    loops.sort(key=lambda l: -len(reach(edges, l["header"]) & headers))
    for i, l in enumerate(loops):
        if len(l["phis"]) != 1:
            errors.append(l["header"] + ": not one data vector phi")
        if (
            l["header"] not in reach(edges, next(iter(blocks)))
            or not l["cyclic"]
            or l["constant_branch"]
        ):
            errors.append(l["header"] + ": absent/non-runtime backedge")
        calls = l.get("collapses", [])
        if len(calls) != 1:
            errors.append(l["header"] + ": not one identified exit collapse")
            continue
        collapse = calls[0]["block"]
        if collapse in l["blocks"]:
            errors.append(l["header"] + ": in-loop collapse")
        if i + 1 < len(loops) and loops[i + 1]["header"] in reach(
            edges, l["header"], [collapse]
        ):
            errors.append(l["header"] + ": next reducer reachable without collapse")
    actual = sorted(int(p[1]) for l in loops for p in l["phis"])
    if actual != sorted(expected):
        errors.append("VF list differs from actual maximum-supported plan schedule")
    return {"errors": errors, "loops": loops, "map_blocks": maps}


def machine_audit(directory, ir_result):
    asm = target.selected_body((directory / "xiangshan.raw.s").read_text())
    matches = list(re.finditer(r"^(?:\.LBB\d+_(\d+):|# %bb\.(\d+):)[^\n]*", asm, re.M))
    blocks = {}
    names = {}
    order = []
    for i, m in enumerate(matches):
        key = m[1] or m[2]
        order.append(key)
        blocks[key] = asm[
            m.end() : matches[i + 1].start() if i + 1 < len(matches) else len(asm)
        ]
        name = re.findall(r"# %([\w.$-]+)", m[0])
        names[key] = name[-1] if name else ""
    edges = {}
    instructions = {}
    for i, key in enumerate(order):
        inst = list(target.INSTRUCTION_RE.finditer(blocks[key]))
        instructions[key] = inst
        dest = set()
        fallthrough = True
        for ins in inst:
            op = ins["opcode"]
            args = target.operands(ins)
            branch = re.fullmatch(r"\.LBB\d+_(\d+)", args[-1]) if args else None
            if op in {"ret", "jr", "tail"}:
                fallthrough = False
            elif op == "j" and branch:
                dest.add(branch[1])
                fallthrough = False
            elif (
                re.fullmatch(
                    r"b(?:eq|ne|lt|ge|ltu|geu|eqz|nez|lez|gez|ltz|gtz|le|gt|leu|gtu)",
                    op,
                )
                and branch
            ):
                dest.add(branch[1])
        if fallthrough and i + 1 < len(order):
            dest.add(order[i + 1])
        edges[key] = dest
    errors = []
    components = []
    spills = []
    for k, loop in enumerate(ir_result["loops"]):
        header = next((b for b in order if names[b] == loop["header"]), None)
        collapse = next(
            (
                b
                for b in order
                if loop.get("collapses")
                and names[b] == loop["collapses"][0]["block"]
                and any(
                    re.match(r"v(?:f?red|cpop|first)", i["opcode"])
                    for i in instructions[b]
                )
            ),
            None,
        )
        if header is None:
            errors.append("missing machine header for " + loop["header"])
            continue
        back = [b for b in order if header in edges[b] and b in reach(edges, header)]
        if not back:
            errors.append("no machine backedge for " + loop["header"])
        component = {
            "header": header,
            "ir_header": loop["header"],
            "backedges": back,
            "collapse_block": collapse,
        }
        if collapse is None:
            errors.append("missing machine collapse block for " + loop["header"])
        else:
            horizontal = [
                i["opcode"]
                for i in instructions[collapse]
                if re.match(r"v(?:f?red|cpop|first)", i["opcode"])
            ]
            if not horizontal:
                errors.append("missing hardware collapse for " + loop["header"])
            component["horizontal"] = horizontal
            component["conditional_collapse"] = any(
                not edges.get(b) for b in reach(edges, header, [collapse])
            )
        components.append(component)
    for i, c in enumerate(components[:-1]):
        if c["collapse_block"] is not None and components[i + 1]["header"] in reach(
            edges, c["header"], [c["collapse_block"]]
        ):
            errors.append(c["ir_header"] + ": machine next reducer bypasses collapse")
    for key, text in blocks.items():
        for line in text.splitlines():
            if "Folded Spill" not in line and "Folded Reload" not in line:
                continue
            op = line.strip().split()[0]
            kind = "vector" if op.startswith("v") else "scalar"
            role = "map" if names[key] in ir_result["map_blocks"] else "setup/control"
            for i, l in enumerate(ir_result["loops"]):
                if names[key] in l["blocks"]:
                    role = "reducer " + str(i)
                elif any(names[key] == c["block"] for c in l.get("collapses", [])):
                    role = "collapse " + str(i)
            spills.append(
                {
                    "kind": kind,
                    "block": key,
                    "ir_block": names[key],
                    "role": role,
                    "instruction": line.strip(),
                }
            )
    return {"errors": errors, "components": components, "spills": spills}


def virtual_liveness(directory, ir_result):
    mir = (
        (directory / "before-vl-optimizer.mir")
        .read_text()
        .split("body:             |")[-1]
    )
    blocks = {}
    for number, name, text in re.findall(
        r"^  bb\.(\d+)\.([^:\n]+):\n(.*?)(?=^  bb\.|^\.\.\.|\Z)", mir, re.M | re.S
    ):
        blocks[number] = (name, text)
    owner = {b: i for i, l in enumerate(ir_result["loops"]) for b in l["blocks"]}
    definitions = {}
    uses = {}
    for number, (name, text) in blocks.items():
        for line in text.splitlines():
            m = re.match(r"\s*(%\d+):vr(?:m[248])?(?:nov0)? = ", line)
            if m:
                definitions[m[1]] = (name, line)
            rhs = line.split(" = ", 1)[-1]
            for v in re.findall(r"%\d+\b", rhs):
                uses.setdefault(v, []).append((name, line))
    errors = []
    for loop in ir_result["loops"]:
        if not any(name in loop["blocks"] for name, _ in definitions.values()):
            errors.append("no MIR vector definition mapped to " + loop["header"])
    for value, (name, line) in definitions.items():
        if name not in owner:
            continue
        origin = owner[name]
        for used, inst in uses.get(value, []):
            if used in owner and owner[used] != origin:
                errors.append(value + " crosses data reducer boundary")
            # Use outside its own loop must be in its collapse block or another block
            # before the next reducer, not deferred to a later collapse.
            for i, l in enumerate(ir_result["loops"]):
                if i > origin and any(
                    used == c["block"] for c in l.get("collapses", [])
                ):
                    errors.append(value + " remains live until a later collapse")
    early = []
    for value, (name, line) in definitions.items():
        if name in owner or not re.search(r"PseudoVL(?:E|SE|UXEI|OXEI)", line):
            continue
        users = sorted({owner[b] for b, _ in uses.get(value, []) if b in owner})
        if users:
            early.append(
                {
                    "value": value,
                    "definition_block": name,
                    "users": users,
                    "instruction": line.strip(),
                }
            )
    return {
        "errors": sorted(set(errors)),
        "early_vector_loads": early,
        "vector_definitions_checked": sum(n in owner for n, _ in definitions.values()),
    }


def storage_lifetimes(directory):
    ir = (directory / "final.ll").read_text()
    blocks, edges = graph(ir)
    live = reach(edges, next(iter(blocks)))
    edges = {n: edges[n] & live for n in live}
    pred = {n: {p for p in live if n in edges[p]} for n in live}

    def dominance(links, roots):
        result = {n: ({n} if n in roots else set(live)) for n in live}
        change = True
        while change:
            change = False
            for n in live - roots:
                parents = links[n]
                new = {n} | (
                    set.intersection(*(result[p] for p in parents))
                    if parents
                    else set()
                )
                if new != result[n]:
                    result[n] = new
                    change = True
        return result

    dom = dominance(pred, {next(iter(blocks))})
    postdom = dominance(edges, {n for n in live if not edges[n]})
    definitions, locations = {}, {}
    for b, text in blocks.items():
        for index, line in enumerate(text.splitlines()):
            m = re.match(r"\s*(%[\w.$-]+) = (.*)", line)
            if m:
                definitions[m[1]] = m[2]
                locations[m[1]] = (b, index)
    pointer = (
        r"\bptr(?: addrspace\(\d+\))?(?: (?:align \d+|nonnull|noundef))* (%[\w.$-]+)"
    )
    buffers = [
        v
        for v, expr in definitions.items()
        if v.startswith("%fission.buffer") and expr.startswith("alloca ")
    ]

    def roots(value, seen=None):
        seen = set() if seen is None else seen
        if value in seen:
            return set()
        seen.add(value)
        if value in buffers:
            return {value}
        expr = definitions.get(value, "")
        args = re.findall(pointer, expr)
        if expr.startswith("phi ptr"):
            args += re.findall(r"\[ (%[\w.$-]+),", expr)
        return set().union(*(roots(v, seen) for v in args)) if args else set()

    starts, ends, accesses = {}, {}, {}
    for b, text in blocks.items():
        for index, line in enumerate(text.splitlines()):
            owners = set().union(*(roots(v) for v in re.findall(pointer, line)))
            for owner in owners:
                mapping = (
                    starts
                    if "@llvm.lifetime.start" in line
                    else ends
                    if "@llvm.lifetime.end" in line
                    else accesses
                    if re.search(
                        r"\b(load|store)\b|@llvm\.(vp|masked)\.(load|store)", line
                    )
                    else None
                )
                if mapping is not None:
                    mapping.setdefault(owner, []).append((b, index))
    errors = []
    for buf in buffers:
        if (
            len(starts.get(buf, [])) != 1
            or len(ends.get(buf, [])) != 1
            or not accesses.get(buf)
        ):
            errors.append(buf + ": missing unique lifetime or memory consumers")
            continue
        sb, si = starts[buf][0]
        eb, ei = ends[buf][0]
        for ab, ai in accesses[buf]:
            if sb not in dom.get(ab, set()) or (sb == ab and si >= ai):
                errors.append(buf + ": access before lifetime start")
            if eb not in postdom.get(ab, set()) or (eb == ab and ei <= ai):
                errors.append(buf + ": access after/bypassing lifetime end")
    return {
        "buffers": len(buffers),
        "accesses": sum(map(len, accesses.values())),
        "errors": sorted(set(errors)),
    }


def audit(campaign):
    load_suite_helpers()
    results = []
    for r in json.loads((campaign / "results.json").read_text()):
        if r["mode"] != "fission" or r["status"] != "compiled":
            continue
        d = pathlib.Path(r["directory"])
        meta = json.loads((d / "command.json").read_text())
        expected = [
            int(evidence.arg(x, "ReductionVF").split()[-1]) for x in meta["schedules"]
        ]
        result = {"id": r["id"], "vf": r["vf"]}
        plans = [dict(x["args"]) for x in meta["plans"]]
        original = (d / "before.ll").read_text()
        result["source_components"] = plans
        result["plan_mapping_valid"] = (
            len(plans) == len(expected)
            and len({p["Accumulator"] for p in plans}) == len(plans)
            and all(
                re.search(re.escape(p["Accumulator"]) + r" = phi ", original)
                for p in plans
            )
            and sorted(int(p["Index"]) for p in plans) == list(range(len(plans)))
        )
        records = json.loads((d / "remarks.json").read_text())
        result["empty_map"] = any(
            x["name"] == "ReductionFissionEmptyMap" for x in records
        )
        source = campaign / "sources" / (r["id"] + ".c")
        map_records = [
            x
            for x in records
            if x["name"] == "Vectorized"
            and evidence.at_original(x, source.read_text(), source.name, trial=True)
        ]
        result["map_vectorizations"] = [dict(x["args"]) for x in map_records]
        result["map_width_valid"] = result["empty_map"] or any(
            p.get("VectorizationFactor") == "vscale x " + str(r["vf"])
            and p.get("InterleaveCount") == "1"
            for p in result["map_vectorizations"]
        )
        generated_vectorizations = [
            dict(x["args"])
            for x in records
            if x["name"] == "Vectorized"
            and x["function"] == "selected_kernel.fission.trial"
        ]
        result["all_components_ic1"] = bool(generated_vectorizations) and all(
            v.get("InterleaveCount") == "1" for v in generated_vectorizations
        )
        try:
            result["after"] = ir_audit(d, "after", expected)
            result["final"] = ir_audit(d, "final", expected)
            result["machine"] = machine_audit(d, result["final"])
            result["virtual_liveness"] = virtual_liveness(d, result["final"])
            result["storage_lifetimes"] = storage_lifetimes(d)
            result["errors"] = [
                stage + ": " + e
                for stage in [
                    "after",
                    "final",
                    "machine",
                    "virtual_liveness",
                    "storage_lifetimes",
                ]
                for e in result[stage]["errors"]
            ]
            if not result["plan_mapping_valid"]:
                result["errors"].append(
                    "original PHI/component mapping is not bijective"
                )
            if not result["map_width_valid"]:
                result["errors"].append("Map width/IC not confirmed")
            if not result["all_components_ic1"]:
                result["errors"].append("actual component IC differs from one")
            result["lmuls"] = [
                int(p[1])
                * ({"float": 32, "double": 64}.get(p[2]) or int(p[2][1:]))
                / 64
                for l in result["final"]["loops"]
                for p in l["phis"]
            ]
            if any(v != 8 for v in result["lmuls"]):
                result["errors"].append(
                    "non-m8 data accumulator needs separate legality explanation"
                )
        except Exception as e:
            result["errors"] = [repr(e)]
        (d / "boundary-audit.json").write_text(json.dumps(result, indent=2))
        results.append(result)
    (campaign / "boundary-audit.json").write_text(json.dumps(results, indent=2))
    print("audited", len(results), "failures", sum(bool(r["errors"]) for r in results))
    for r in results:
        if r["errors"]:
            print(r["id"], r["vf"], r["errors"][:4])


def self_test(opt):
    import subprocess, tempfile

    base = """define float @selected_kernel(i1 %again) {
entry:
  br label %a
 a:
  %x = phi <vscale x 16 x float> [ zeroinitializer, %entry ], [ %xn, %a ]
  %xn = fadd reassoc <vscale x 16 x float> %x, splat (float 1.0)
  br i1 %again, label %a, label %middle, !llvm.loop !0
middle:
  %xout = phi <vscale x 16 x float> [ %xn, %a ]
  %r0 = call reassoc float @llvm.vector.reduce.fadd.nxv16f32(float -0.0, <vscale x 16 x float> %xout)
  br label %b
b:
  %y = phi <vscale x 16 x float> [ zeroinitializer, %middle ], [ %yn, %b ]
  %yn = fadd reassoc <vscale x 16 x float> %y, splat (float 1.0)
  br i1 %again, label %b, label %exit, !llvm.loop !1
exit:
  %yout = phi <vscale x 16 x float> [ %yn, %b ]
  %r1 = call reassoc float @llvm.vector.reduce.fadd.nxv16f32(float -0.0, <vscale x 16 x float> %yout)
  %result = fadd float %r0, %r1
  ret float %result
}
declare float @llvm.vector.reduce.fadd.nxv16f32(float, <vscale x 16 x float>)
!0 = distinct !{!0, !2}
!1 = distinct !{!1, !2}
!2 = !{!"llvm.loop.reduction.fission.reduction"}
""".replace("\n a:", "\na:")
    collapse = next(line for line in base.splitlines(True) if "%r0 = call" in line)
    cases = {
        "valid": (base, False),
        "constant_exit": (
            base.replace("br i1 %again, label %a", "br i1 false, label %a"),
            True,
        ),
        "late_collapse": (
            base.replace(collapse, "").replace(
                "  %r1 = call", collapse + "  %r1 = call"
            ),
            True,
        ),
        "unreachable": (
            base.replace(
                "  br label %a", "  br i1 false, label %a, label %dead"
            ).replace("\na:", "\ndead:\n  ret float 0.0\na:"),
            True,
        ),
    }
    with tempfile.TemporaryDirectory() as t:
        d = pathlib.Path(t)
        for name, (ir, should_fail) in cases.items():
            (d / "final.ll").write_text(ir)
            p = subprocess.run(
                [
                    opt,
                    "-passes=verify,print<loops>",
                    "-disable-output",
                    str(d / "final.ll"),
                ],
                capture_output=True,
                text=True,
            )
            if p.returncode:
                raise RuntimeError(p.stderr)
            (d / "verify-final.stderr.log").write_text(p.stderr)
            result = ir_audit(d, "final", [16, 16])
            if bool(result["errors"]) != should_fail:
                raise AssertionError((name, result))
    print(
        "CFG audit self-tests passed (including constant, unreachable, and late-collapse cases)"
    )


if __name__ == "__main__":
    if sys.argv[1] == "--self-test":
        self_test(sys.argv[2])
    else:
        audit(pathlib.Path(sys.argv[1]))
