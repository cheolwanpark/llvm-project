; REQUIRES: asserts
; RUN: opt -passes=loop-vectorize -mattr=+sve -force-vector-width=4 -tail-folding-policy=dont-fold-tail -print-vplans -disable-output %S/sve-invalid-costs.ll 2>&1 | FileCheck %s --check-prefix=INVALID
; RUN: opt -passes=loop-vectorize -epilogue-vectorization-minimum-VF=1 -print-vplans -disable-output %S/print-vplans.ll 2>&1 | FileCheck %s --check-prefix=EPILOGUE
; RUN: opt -passes=forceattrs,loop-vectorize -force-attribute=minsize -print-vplans -disable-output %S/optsize_minsize.ll 2>&1 | FileCheck %s --check-prefix=SIZE
; RUN: opt -passes=loop-vectorize -enable-vplan-native-path -mtriple=aarch64 -print-vplans -disable-output %S/../VPlan/vplan-printing-outer-loop.ll 2>&1 | FileCheck %s --check-prefix=OUTER

; RUN: %python %S/../Inputs/check-vplan-invariance.py opt %S/sve-invalid-costs.ll -mattr=+sve -force-vector-width=4 -tail-folding-policy=dont-fold-tail
; RUN: %python %S/../Inputs/check-vplan-invariance.py opt %S/print-vplans.ll -epilogue-vectorization-minimum-VF=1
; RUN: %python %S/../Inputs/check-vplan-invariance.py opt %S/optsize_minsize.ll -passes=forceattrs,loop-vectorize -force-attribute=minsize
; RUN: %python %S/../Inputs/check-vplan-invariance.py opt %S/../VPlan/vplan-printing-outer-loop.ll -enable-vplan-native-path -mtriple=aarch64

; RUN: opt -passes=loop-vectorize -print-vplans -disable-output %S/cost-no-valid-vplans-built.ll 2>&1 | FileCheck %s --check-prefix=NO-PLAN
; RUN: opt -passes=loop-vectorize -mattr=+sve -print-vplans -disable-output %S/low_trip_count_predicates.ll 2>&1 | FileCheck %s --check-prefix=LATE-REJECTION
; RUN: %python %S/../Inputs/check-vplan-invariance.py opt %S/cost-no-valid-vplans-built.ll
; RUN: %python %S/../Inputs/check-vplan-invariance.py opt %S/low_trip_count_predicates.ll -mattr=+sve

; INVALID: main | 0 | s4 | 4 | Invalid | not-evaluated
; INVALID: invalid-cost plan=0 vf=s4 recipe=R{{[0-9]+}} scope=vector-region source=recipe
; INVALID: discarded plan=0 reason=invalid-user-vf-cost
; INVALID: selected-for-main plan=1 vf=f1
; INVALID: End VPlan report

; EPILOGUE: epilogue | 1 | f2 | 2 | 5 | 22 | whole-loop | yes (none; first-eligible-candidate) | not-evaluated
; EPILOGUE-NEXT: epilogue | 1 | f4 | 4 | 5 | 26 | whole-loop | no (plan=1 vf=f2; known-trip-count) | not-evaluated
; EPILOGUE: selected-for-epilogue plan=2 vf=f2 source_plan=1 cost=reused
; EPILOGUE: outcome=vectorization-emitted

; SIZE: cost_kind=code_size
; SIZE: code-size-less-than-or-tie-larger-width
; SIZE: replication-under-opt-for-size
; SIZE: outcome=vectorization-rejected

; OUTER: scalar-baseline cost=not-evaluated
; OUTER: selected-for-main plan=0 vf={{[fs][0-9]+}} reason=outer-loop-heuristic
; OUTER: outcome=vectorization-emitted

; NO-PLAN: scalar-baseline cost=not-evaluated
; NO-PLAN: no-plan reason=base-plan-construction-failed
; NO-PLAN: selected-for-main plan=none vf=not-evaluated
; NO-PLAN: outcome=no-plan
; NO-PLAN-NEXT: End VPlan report

; LATE-REJECTION: function=too_many_runtime_checks
; LATE-REJECTION: outside-loop decision=0 reason=expected-trip-count-below-minimum
; LATE-REJECTION: selected-for-main plan={{[0-9]+}} vf=f16
; LATE-REJECTION: selected_interleave_count=not-evaluated
; LATE-REJECTION: outcome=vectorization-rejected
