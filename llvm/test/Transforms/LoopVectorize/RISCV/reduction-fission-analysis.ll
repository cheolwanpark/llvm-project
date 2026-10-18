; REQUIRES: asserts
;
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v \
; RUN:   -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false \
; RUN:   -vplan-reduction-fission-min-chain-depth=8 \
; RUN:   -vplan-reduction-fission-min-reductions=5 \
; RUN:   -vplan-reduction-fission-min-pressure-percent=100 \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=4096 \
; RUN:   -vplan-reduction-fission-max-duplicated-recipes=2 \
; RUN:   -disable-output %s
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v \
; RUN:   -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false -debug-only=vplan-reduction-fission \
; RUN:   -disable-output %s 2>&1 | FileCheck %s --check-prefix=DEBUG
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v \
; RUN:   -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false \
; RUN:   -vplan-reduction-fission-min-pressure-percent=0 \
; RUN:   -vplan-reduction-fission-min-reductions=2 \
; RUN:   -vplan-reduction-fission-min-chain-depth=1 \
; RUN:   -debug-only=vplan-reduction-fission -disable-output %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=ONE

; DEBUG: LV-FISSION: dynamic_trip: rejected: non-constant-trip-count
; One reduction and a load are sufficient under the explicit enable flag.
; The historical minimum-count option no longer vetoes this candidate.
; ONE: LV-FISSION: constant_trip_one: candidate: reductions=1 scratch-bytes=256

define void @options_smoke() {
entry:
  ret void
}

define i32 @dynamic_trip(ptr noalias readonly %a, i64 %n) {
entry:
  br label %loop

loop:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %loop ]
  %sum = phi i32 [ 0, %entry ], [ %sum.next, %loop ]
  %p = getelementptr inbounds i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %sum.next = add i32 %sum, %x
  %iv.next = add nuw i64 %iv, 1
  %done = icmp eq i64 %iv.next, %n
  br i1 %done, label %exit, label %loop

exit:
  ret i32 %sum.next
}


define i32 @constant_trip_one(ptr noalias readonly %a) {
entry:
  br label %loop

loop:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %loop ]
  %sum = phi i32 [ 0, %entry ], [ %sum.next, %loop ]
  %p = getelementptr inbounds i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %sum.next = add i32 %sum, %x
  %iv.next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %iv.next, 64
  br i1 %done, label %exit, label %loop

exit:
  ret i32 %sum.next
}
