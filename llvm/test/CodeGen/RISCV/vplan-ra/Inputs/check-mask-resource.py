import json
import sys

mode, path = sys.argv[1:3]
with open(path) as f:
    r = json.load(f)["features"]["resource_demand"]

mask = lambda group, work: dict(group8=group, index_group8=0, index_sew=0,
                                kind="mask_logical", masked=False, sew=1,
                                work8=work)
assert r["version"] == 1 and r["loop_blocks"] == 1
assert r["fp8"] == r["fused8"] == r["strided8"] == r["indexed8"] == r["spill8"] == 0
assert r["config8"] == 8 and r["recurrences"] == []

if mode == "logic":
    vlen = int(sys.argv[3])
    # Independently count packed bits at B=1,2,4,8,16,32,64, then convert
    # 128-bit service units to eighths. The four small masks issue once.
    # Explicit tables catch an accidental data-LMUL or byte-lane multiplier.
    work, total = {
        128: ([8, 8, 8, 8, 8, 8, 8], 560),
        256: ([16, 8, 8, 8, 8, 8, 8], 640),
        1024: ([64, 32, 16, 8, 8, 8, 8], 1440),
        2048: ([128, 64, 32, 16, 8, 8, 8], 2640),
    }[vlen]
    expected = [mask(g, w) for g, w in zip([64, 32, 16, 8, 4, 2, 1], work)] * 10
    assert r["supported"] is True
    assert r["integer8"] == total and r["scalar8"] == 24
    assert r["unit8"] == r["masked8"] == 0
    assert r["operations"] == expected, (r["operations"], expected)

elif mode == "provenance":
    assert r["supported"] is True
    assert r["integer8"] == 64 and r["scalar8"] == 24
    assert r["unit8"] == r["masked8"] == 176
    ops = r["operations"]
    assert len(ops) == 25
    assert [o for o in ops if o["kind"] == "mask_logical"] == [mask(8, 8)] * 8
    copy = dict(group8=8, index_group8=0, index_sew=0, kind="copy",
                masked=False, sew=0, work8=8)
    assert [o for o in ops if o["kind"] == "copy"] == [copy] * 6
    stores = [o for o in ops if o["kind"] == "unit"]
    assert len(stores) == 11
    expected_store = dict(group8=16, index_group8=0, index_sew=0, kind="unit",
                          direction="store", masked=True, sew=32, work8=16)
    assert [{k: v for k, v in o.items() if k != "predicate_id"}
            for o in stores] == [expected_store] * 11
    p = [o["predicate_id"] for o in stores]
    assert p[0] == p[2] and p[3] == p[4] and p[10] == 0
    distinct = [p[i] for i in [0, 1, 3, 5, 6, 7, 8, 9]]
    assert min(distinct) > 0 and len(set(distinct)) == 8, p

elif mode == "fallback":
    assert r["supported"] is False
    assert r["integer8"] == 8 and r["scalar8"] == 0
    assert r["unit8"] == r["masked8"] == 0
    assert r["operations"] == [mask(64, 8)]

else:
    raise AssertionError(mode)
