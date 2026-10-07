; REQUIRES: asserts
; RUN: opt -passes=loop-vectorize -S %s -o %t.off 2> %t.silent
; RUN: test ! -s %t.silent
; RUN: opt -passes=loop-vectorize -print-vplans -S %s -o %t.summary 2> %t.report
; RUN: FileCheck %s --check-prefix=REPORT < %t.report
; RUN: %python %S/../Inputs/check-vplan-accounting.py < %t.report
; RUN: opt -passes=loop-vectorize -print-detailed-vplans -S %s -o %t.detail 2> %t.detailed
; RUN: FileCheck %s --check-prefixes=REPORT,DETAIL < %t.detailed
; RUN: %python %S/../Inputs/check-vplan-accounting.py < %t.detailed
; RUN: opt -passes=loop-vectorize -print-vplans -print-detailed-vplans -S %s -o %t.both 2> %t.combined
; RUN: diff %t.detailed %t.combined
; RUN: diff %t.off %t.summary
; RUN: diff %t.off %t.detail
; RUN: diff %t.off %t.both
; RUN: opt -passes=loop-vectorize -print-vplans -disable-output %s 2> %t.repeat
; RUN: diff %t.report %t.repeat
; RUN: opt -passes=loop-vectorize -force-vector-width=4 -print-vplans -disable-output %s 2>&1 | FileCheck %s --check-prefix=HINT

; REPORT: VPlan report_version=1 {{.*}} function=add loop=0 header=loop depth={{[12]}}
; REPORT: cost_kind=reciprocal_throughput units=model-units
; REPORT: plan=0
; REPORT: recipe_inventory:
; REPORT: R{{[0-9]+}} block=
; REPORT: evaluation={{[0-9]+}} plan={{[0-9]+}} vf=f{{[0-9]+}} phase=main-selection
; REPORT: legacy_precomputed=
; DETAIL: term=getMemoryOpCost result={{[0-9]+}} coverage=tti-leaf
; REPORT: scope=validity-only
; REPORT: vector_region=
; REPORT: candidate_cost={{[0-9]+}} status=evaluated
; REPORT: scalar-baseline phase=main-selection
; REPORT: scalar-block block=loop instruction_sum={{[0-9]+}} divisor=1 weighted_cost=
; REPORT: scalar_iteration_cost=
; REPORT: comparison-purpose=incumbent candidate_plan=
; REPORT: maximum_trip_count=0 has_tail=1
; REPORT: cross_product_a={{[0-9]+}} cross_product_b={{[0-9]+}} operator=<
; REPORT: reason=unknown-trip-count-cross-products
; REPORT: selected-for-main plan=
; REPORT: selected_interleave_count=
; REPORT: outcome=vectorization-emitted
; REPORT: End VPlan report

; HINT: phase=candidate-validation
; HINT: phase=interleave-selection
; HINT: selected-for-main plan=0 vf=f4 status=not-evaluated reason=user-vf
; HINT: interleave-selection plan=0 reused_body_cost=0
; HINT: outcome=vectorization-emitted

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
