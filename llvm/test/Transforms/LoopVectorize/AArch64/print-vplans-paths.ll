; REQUIRES: asserts
; RUN: opt -passes=loop-vectorize -mattr=+sve -force-vector-width=4 -tail-folding-policy=dont-fold-tail -print-vplans -disable-output %S/sve-invalid-costs.ll 2>&1 | FileCheck %s --check-prefix=INVALID
; RUN: opt -passes=loop-vectorize -epilogue-vectorization-minimum-VF=1 -print-vplans -disable-output %S/print-vplans.ll 2>&1 | FileCheck %s --check-prefix=EPILOGUE
; RUN: opt -passes=forceattrs,loop-vectorize -force-attribute=minsize -print-vplans -disable-output %S/optsize_minsize.ll 2>&1 | FileCheck %s --check-prefix=SIZE
; RUN: opt -passes=loop-vectorize -enable-vplan-native-path -mtriple=aarch64 -print-vplans -disable-output %S/../VPlan/vplan-printing-outer-loop.ll 2>&1 | FileCheck %s --check-prefix=OUTER

; INVALID: evaluation=0 plan=0 vf=s4 phase=candidate-validation
; INVALID: candidate_cost=Invalid status=invalid
; INVALID: status=not-evaluated
; INVALID: plan=1
; INVALID: discarded plan=0 reason=invalid-user-vf-cost
; INVALID: selected-for-main plan=1 vf=f1
; INVALID: End VPlan report

; EPILOGUE: phase=outside-loop-profitability
; EPILOGUE: scope=outside-loop-profitability
; EPILOGUE-NEXT: cost={{[0-9]+}} contribution=0
; EPILOGUE: epilogue_cost=omitted
; EPILOGUE: epilogue-candidate cost_source_plan=1 reused_cost=5 source_evaluation={{[0-9]+}} vf=f2
; EPILOGUE: comparison phase=epilogue-selection
; EPILOGUE: selected-for-epilogue plan=2 source_plan=1 reused_cost=5
; EPILOGUE: outcome=vectorization-emitted

; SIZE: cost_kind=code_size
; SIZE: reason=code-size-less-than-or-tie-larger-width
; SIZE: outcome=vectorization-rejected

; OUTER: selected-for-main plan=0 vf={{[fs][0-9]+}} status=not-evaluated reason=outer-loop-heuristic
; OUTER: outcome=vectorization-emitted
