"""Reporting must preserve IR and the vectorizer's cost/selection debug trace."""
import re
import subprocess
import sys

opt, source, *options = sys.argv[1:]
base = [opt, "-passes=loop-vectorize", "-debug-only=loop-vectorize", "-S", source, "-o", "-"]
def normalize_diagnostics(text):
    # Debug snapshots can assign different slots to temporary alias metadata
    # from plans that are later rejected, or print their process-local addresses.
    # Keep cost values and recipe text;
    # compare the actual output IR byte-for-byte below, including its metadata.
    return re.sub(r"(![A-Za-z_][\w.-]*\s+)(?:!\d+\b|<0x[0-9a-fA-F]+>)",
                  r"\1!MD", text)


reference = None
summary = None
detailed = None
for flags in ([], ["-print-vplans"], ["-print-detailed-vplans"],
              ["-print-vplans", "-print-detailed-vplans"]):
    result = subprocess.run(base + options + flags, capture_output=True, text=True, check=True)
    reports = re.findall(r"^VPlan report_version=.*?^End VPlan report\n",
                         result.stderr, flags=re.M | re.S)
    trace = re.sub(r"^VPlan report_version=.*?^End VPlan report\n", "",
                   result.stderr, flags=re.M | re.S)
    if reference is None:
        assert not reports
        reference = (result.stdout, normalize_diagnostics(trace))
        continue
    assert reports, "test must reach VPlan reporting"
    assert result.stdout == reference[0], (flags, "generated IR changed")
    assert normalize_diagnostics(trace) == reference[1], (flags, "cost/selection trace changed")
    if flags == ["-print-vplans"]:
        summary = reports
        for report in reports:
            for excluded in ("VPlan '", "recipe_inventory", "calculation=",
                             "features=", "scope=validity-only", "validity-checks"):
                assert excluded not in report, (excluded, report)
    else:
        common = [re.sub(r" depth=2\n", " depth=1\n",
                         r.split("  details:\n")[0]) + "End VPlan report\n"
                  for r in reports]
        assert common == summary, "detailed mode must include the same summary"
        if detailed is None:
            detailed = [normalize_diagnostics(r) for r in reports]
        else:
            assert detailed == [normalize_diagnostics(r) for r in reports], "both flags must emit just one detailed report"
