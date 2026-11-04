; REQUIRES: asserts
; RUN: %python %S/Inputs/backend-contract.py selection opt %S/backend-pipeline.ll %t
; Whole-loop fallback, requested TTI policy and passive reports share the map
; fixture. Automatic epilogue failure is injected in VPlanBackendExecutionTest.
