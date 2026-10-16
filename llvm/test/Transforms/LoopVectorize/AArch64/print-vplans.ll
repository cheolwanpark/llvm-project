; REQUIRES: asserts
; RUN: opt -passes=loop-vectorize -S %s -o %t.off 2> %t.silent
; RUN: test ! -s %t.silent
; RUN: opt -passes=loop-vectorize -print-vplans -S %s -o %t.summary 2> %t.report
; RUN: FileCheck %s --check-prefix=REPORT --implicit-check-not="VPlan '" --implicit-check-not=recipe_inventory --implicit-check-not=calculation= --implicit-check-not=features= --implicit-check-not=validity-checks < %t.report
; RUN: opt -passes=loop-vectorize -print-detailed-vplans -S %s -o %t.detail 2> %t.detailed
; RUN: FileCheck %s --check-prefixes=REPORT,DETAIL --implicit-check-not=recipe_inventory < %t.detailed
; RUN: %python %S/../Inputs/check-vplan-accounting.py < %t.detailed
; RUN: opt -passes=loop-vectorize -print-vplans -print-detailed-vplans -S %s -o %t.both 2> %t.combined
; RUN: diff %t.detailed %t.combined
; RUN: diff %t.off %t.summary
; RUN: diff %t.off %t.detail
; RUN: diff %t.off %t.both
; RUN: opt -passes=loop-vectorize -print-vplans -disable-output %s 2> %t.repeat
; RUN: diff %t.report %t.repeat
; RUN: opt -passes=loop-vectorize -force-vector-width=4 -print-vplans -disable-output %s 2>&1 | FileCheck %s --check-prefix=HINT
; RUN: opt -passes=loop-vectorize -mcpu=cortex-a57 -print-vplans -disable-output %s 2>&1 | FileCheck %s --check-prefix=CPU
; RUN: %python %S/../Inputs/check-vplan-invariance.py opt %s
; RUN: %python %S/../Inputs/check-vplan-invariance.py opt %s -force-vector-width=4

; REPORT: VPlan report_version=2 {{.*}} function=add loop=0 header=loop depth={{[12]}}
; REPORT: target=aarch64-unknown-linux-gnu cpu=unspecified
; REPORT: cost_kind=reciprocal_throughput units=model-units
; REPORT: scalar-baseline cost=7
; REPORT-NEXT: candidates:
; REPORT-NEXT: phase | plan | vf | estimated_width | body_cost | score | score_kind | vs_incumbent | vs_scalar | reason
; REPORT-NEXT: main | 1 | f2 | 2 | 5 | 5/2 | cost-per-lane | yes (plan=0 vf=f1; unknown-trip-count-cross-products) | yes (scalar; unknown-trip-count-cross-products) | -
; REPORT-NEXT: main | 1 | f4 | 4 | 5 | 5/4 | cost-per-lane | yes (plan=1 vf=f2; unknown-trip-count-cross-products) | yes (scalar; unknown-trip-count-cross-products) | -
; REPORT: selected-for-main plan=1 vf=f4
; REPORT-NEXT: selected-for-epilogue plan=none vf=not-evaluated
; REPORT-NEXT: selected_interleave_count=2 reason=reduce-branch-cost
; REPORT-NEXT: outcome=vectorization-emitted
; DETAIL-NEXT: details:
; DETAIL-NEXT: plan=0
; DETAIL: VPlan 'Initial VPlan for VF={1},UF>=1' {
; DETAIL: [R{{[0-9]+}}] CLONE
; DETAIL: plan=1
; DETAIL: VPlan 'Initial VPlan for VF={2,4},UF>=1' {
; DETAIL: [R[[LOAD:[0-9]+]]] WIDEN ir<%x> = load
; DETAIL: costs vf=f2
; DETAIL-NEXT: evaluation={{[0-9]+}} plan=1 vf=f2 phase=main-selection
; DETAIL: R[[LOAD]] scope=vector-region
; DETAIL-NEXT: calculation=VPWidenMemoryRecipe::computeCost {
; DETAIL: term=getMemoryOpCost result=1 coverage=tti-leaf
; DETAIL: vector_region=4
; DETAIL: candidate_cost=5 status=evaluated
; DETAIL-NEXT: validity-checks passed=11 recipes=R0-R8, R19-R20
; DETAIL: costs vf=f4
; DETAIL: phase=outside-loop-profitability
; DETAIL: not-evaluated count=19 recipes=R0-R18
; DETAIL: scalar-block block=loop instruction_sum=7 divisor=1 weighted_cost=7
; REPORT: End VPlan report

; HINT: scalar-baseline cost=not-evaluated
; HINT: main | 0 | f4 | 4 | 5 | not-evaluated | not-evaluated | not-evaluated | not-evaluated | user-vf
; HINT: selected-for-main plan=0 vf=f4 reason=user-vf
; HINT: selected_interleave_count=2
; HINT: outcome=vectorization-emitted

; CPU: target=aarch64-unknown-linux-gnu cpu=cortex-a57

target triple = "aarch64-unknown-linux-gnu"

define void @add(ptr noalias %a, ptr noalias %b, i64 %n) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %loop
loop:
  %iv = phi i64 [ 0, %entry ], [ %next, %loop ]
  %pa = getelementptr i32, ptr %a, i64 %iv
  %pb = getelementptr i32, ptr %b, i64 %iv
  %x = load i32, ptr %pa, align 4
  %y = add i32 %x, 3
  store i32 %y, ptr %pb, align 4
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret void
}
