; REQUIRES: asserts
; RUN: opt -passes=loop-vectorize -vectorizer-min-trip-count=0 -print-vplans -disable-output %s 2>&1 | FileCheck %s --check-prefix=TAIL
; RUN: opt -passes=loop-vectorize -vectorizer-min-trip-count=0 -mattr=+sve -tail-folding-policy=must-fold-tail -sve-vscale-for-tuning=2 -print-vplans -disable-output %s 2>&1 | FileCheck %s --check-prefix=FOLD
; RUN: opt -passes=loop-vectorize -vectorizer-min-trip-count=0 -force-target-instruction-cost=1 -print-detailed-vplans -disable-output %s 2> %t.weight
; RUN: FileCheck %s --check-prefix=WEIGHT < %t.weight
; RUN: %python %S/../Inputs/check-vplan-accounting.py < %t.weight
; RUN: opt -passes=loop-vectorize -vectorizer-min-trip-count=0 -vectorizer-consider-reg-pressure -force-target-num-vector-regs=1 -print-detailed-vplans -disable-output %s 2> %t.spill
; RUN: FileCheck %s --check-prefix=SPILL < %t.spill
; RUN: %python %S/../Inputs/check-vplan-accounting.py < %t.spill
; RUN: opt -passes=loop-vectorize -vectorizer-min-trip-count=0 -vectorizer-consider-reg-pressure=false -print-vplans -disable-output %s 2>&1 | FileCheck %s --check-prefix=NO-SPILL
; RUN: %python %S/../Inputs/check-vplan-invariance.py opt %s -vectorizer-min-trip-count=0
; RUN: %python %S/../Inputs/check-vplan-invariance.py opt %s -vectorizer-min-trip-count=0 -mattr=+sve -tail-folding-policy=must-fold-tail -sve-vscale-for-tuning=2
; RUN: %python %S/../Inputs/check-vplan-invariance.py opt %s -vectorizer-min-trip-count=0 -vectorizer-consider-reg-pressure -force-target-num-vector-regs=1

; TAIL: function=known
; TAIL: scalar-baseline cost=7
; TAIL: main | 1 | f2 | 2 | 5 | 25 | whole-loop | yes (plan=0 vf=f1; known-trip-count) | yes (scalar; known-trip-count)
; TAIL-NEXT: main | 1 | f4 | 4 | 5 | 24 | whole-loop | yes (plan=1 vf=f2; known-trip-count) | yes (scalar; known-trip-count)
; TAIL: selected-for-main plan=1 vf=f4
; TAIL: function=predicated
; TAIL: scalar-baseline cost=6.5
; TAIL: main | 1 | f2 | 2 | 13 | 13/2 | cost-per-lane | no (plan=0 vf=f1; unknown-trip-count-cross-products) | no (scalar; unknown-trip-count-cross-products)

; FOLD: function=known
; FOLD: tuning_vscale=2
; FOLD: main | 2 | s2 | 4 | 5 | 15 | whole-loop
; FOLD-NEXT: main | 2 | s4 | 8 | 5 | 10 | whole-loop
; FOLD: selected-for-main plan=2 vf=s4

; SPILL: register_class=0 local_peak=3 invariant_usage=1 limit=1
; SPILL-NEXT: coverage=expanded excess=2 getRegisterClassSpillCost=1 getRegisterClassReloadCost=1 spill_plus_reload=2 multiply=4
; SPILL: spill_cost=4
; SPILL: candidate_cost=9 status=evaluated

; NO-SPILL: register-pressure-policy vf=f1 enabled=0 reason=command-line
; NO-SPILL: selected-for-main plan=1 vf=f4

; WEIGHT: replacement=force-target-instruction-cost original=
; WEIGHT: function=predicated
; WEIGHT: scalar-block block=then instruction_sum=3 divisor=2 weighted_cost=1.5

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
