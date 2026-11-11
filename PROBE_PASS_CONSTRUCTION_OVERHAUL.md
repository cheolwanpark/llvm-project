# Probe pass construction overhaul

Implemented. This brief is superseded by the
[probe pipeline contract](BACKEND_FEEDBACK.md#one-probe-pipeline-and-independent-observations)
and [build and verification instructions](README.md#build-and-verification).

The change fixes tuning options captured before default pipeline aliases were
applied, and removes inference of the IR optimization level from the backend
codegen level. Each LV pipeline now owns its continuation configuration.

Compile-only diagnostics from implementation are retained in
`.cache/probe-pass-construction-overhaul/`. They are not runtime measurements.
