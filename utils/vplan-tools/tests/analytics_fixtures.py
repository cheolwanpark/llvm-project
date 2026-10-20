"""Synthetic backend observations for raw analytics/spill transport tests."""
def operand(**kwargs):
    return dict.fromkeys(("Vector", "Def", "Implicit", "Dead", "EarlyClobber",
                          "SubReg", "Undef", "Tied"), False) | kwargs


def instruction(category="scalar", **kwargs):
    return {"ID": 0, "Block": 0, "Opcode": "test", "Base": "VADD_VV",
        "Category": category, "SEW": 32, "Group8": 8, "Bytes": 0,
        "Operands": [operand(Vector=True, Def=True), operand(Vector=True)],
        **dict.fromkeys(("Meta", "Barrier", "ConfigUnused", "ScalableBytes", "SameCopy",
                        "Masked", "Load", "Store", "Stack"), False), "Predicate": 0, **kwargs}


def analytics(instructions=None, vf=1, scalable=False, **kwargs):
    ins = instructions if instructions is not None else [instruction()]
    return {"Version": 2, "Stage": "post-ra-cleanup", "Error": "", "RunID": "run",
        "Function": "selected_kernel", "CPU": "xiangshan-kunminghu", "VLen": 128,
        "Width": vf, "VF": vf, "ScalableVF": scalable, "MaxTripCount": 0, "ExactTripCount": 0,
        "ScalarTail": False, "Candidate": f"selected_kernel:0:0:{'s' if scalable else 'f'}{vf}",
        "DependencyCoverage": "single-block-distance-0-1", "Blocks": [{"ID": 0, "Role": "body"}],
        "Instructions": [i | {"ID": n} for n, i in enumerate(ins)], "Edges": [], **kwargs}

