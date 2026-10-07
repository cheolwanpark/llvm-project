; REQUIRES: asserts
; RUN: opt -passes=loop-vectorize -vectorizer-min-trip-count=0 -print-vplans -disable-output %s 2>&1 | FileCheck %s --check-prefix=TAIL
; RUN: opt -passes=loop-vectorize -vectorizer-min-trip-count=0 -mattr=+sve -tail-folding-policy=must-fold-tail -sve-vscale-for-tuning=2 -print-vplans -disable-output %s 2>&1 | FileCheck %s --check-prefix=FOLD
; RUN: opt -passes=loop-vectorize -vectorizer-min-trip-count=0 -force-target-instruction-cost=1 -print-detailed-vplans -disable-output %s 2>&1 | FileCheck %s --check-prefix=WEIGHT
; RUN: opt -passes=loop-vectorize -vectorizer-min-trip-count=0 -vectorizer-consider-reg-pressure -force-target-num-vector-regs=1 -print-detailed-vplans -disable-output %s 2>&1 | FileCheck %s --check-prefix=SPILL
; RUN: opt -passes=loop-vectorize -vectorizer-min-trip-count=0 -vectorizer-consider-reg-pressure=false -print-vplans -disable-output %s 2>&1 | FileCheck %s --check-prefix=NO-SPILL

; TAIL: function=known
; TAIL: maximum_trip_count=10 has_tail=1
; TAIL: trip-count-cost width=4 vector_iterations=2 remainder=2 vector_term=10 scalar_tail_term=14
; TAIL: candidate_compare=24 incumbent_compare=25
; TAIL: decision=1 reason=known-trip-count

; FOLD: function=known
; FOLD: tuning_vscale=2
; FOLD: tail_folded=1 scalar_tail=0
; FOLD: maximum_trip_count=10 has_tail=0
; FOLD: trip-count-cost width={{[248]}} vector_iterations={{[235]}} vector_term={{[0-9]+}} scalar_tail_term=0

; SPILL: register_class=0 local_peak=3 invariant_usage=1 limit=1
; SPILL-NEXT: coverage=expanded excess=2 getRegisterClassSpillCost=1 getRegisterClassReloadCost=1 spill_plus_reload=2 multiply=4
; SPILL: spill_cost=4
; SPILL: candidate_cost=9 status=evaluated

; NO-SPILL: register_pressure=not-considered reason=analysis-not-performed spill_cost=0
; NO-SPILL: register-pressure-policy vf=f1 enabled=0 reason=command-line

; WEIGHT: replacement=force-target-instruction-cost original=
; WEIGHT: function=predicated
; WEIGHT: scalar-block block=then instruction_sum=3 divisor=2 weighted_cost=1
; WEIGHT: scalar_iteration_cost=

target triple = "aarch64-unknown-linux-gnu"

define void @known(ptr noalias %a, ptr noalias %b) {
entry:
  br label %loop
loop:
  %iv = phi i64 [ 0, %entry ], [ %next, %loop ]
  %pa = getelementptr i32, ptr %a, i64 %iv
  %pb = getelementptr i32, ptr %b, i64 %iv
  %x = load i32, ptr %pa, align 4
  %y = add i32 %x, 3
  store i32 %y, ptr %pb, align 4
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, 10
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

define void @predicated(ptr noalias %a, ptr noalias %b, i64 %n) {
entry:
  br label %loop
loop:
  %iv = phi i64 [ 0, %entry ], [ %next, %latch ]
  %pa = getelementptr i32, ptr %a, i64 %iv
  %pb = getelementptr i32, ptr %b, i64 %iv
  %x = load i32, ptr %pa, align 4
  %cond = icmp sgt i32 %x, 0
  br i1 %cond, label %then, label %latch
then:
  %y = add i32 %x, 3
  store i32 %y, ptr %pb, align 4
  br label %latch
latch:
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret void
}
