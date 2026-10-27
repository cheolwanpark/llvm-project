; REQUIRES: asserts
; RUN: %python %S/Inputs/check-backend-cost-report.py opt %S/backend-feedback.ll %t.basic
; RUN: %python %S/Inputs/check-backend-cost-report.py opt %S/backend-feedback-spills.ll %t.spills spills
;
; Exercise the existing integrated fixtures with both cost-report options.
; Printing is passive across success, gate skip, actual spills and fallback.
