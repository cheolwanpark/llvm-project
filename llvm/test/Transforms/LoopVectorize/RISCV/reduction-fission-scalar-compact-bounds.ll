; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -pass-remarks=vplan-reduction-fission \
; RUN:   -pass-remarks-missed=vplan-reduction-fission -S %s -o %t 2> %t.remarks
; RUN: FileCheck %s < %t
; RUN: FileCheck %s --check-prefix=REMARK < %t.remarks
;
; Bounds concern full original trips, even if the predicate admits no updates.
; A count of 255 fits i8; 256 original trips with an i8 IV do not fit the
; compact counter and must reject before mutation. No wrapping allocation.
; The default 65536-byte ceiling admits exactly 16384 i32 slots and rejects
; one additional slot. No profitability thresholds or runtime assumptions.
;
; REMARK: scratch capacity 255, scratch bytes 1020
; REMARK: scalar-IR reduction fission rejected: trip-count-overflow
; REMARK: scratch capacity 16384, scratch bytes 65536
; REMARK: scalar-IR reduction fission rejected: scalar-scratch-limit

; CHECK-LABEL: define i32 @compact_i8_max(
; CHECK: alloca [255 x i32]
; CHECK: scalar.fission.consumer.guard:
; CHECK: scalar.fission.consumer.body:
; CHECK: scalar.fission.consumer.exit:
; CHECK: ret i32
define i32 @compact_i8_max(i32 %cutoff) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i8 [0, %preheader], [%next, %latch]
  %sum = phi i32 [17, %preheader], [%merged, %latch]
  %wide = zext i8 %iv to i32
  %choose = icmp ult i32 %wide, %cutoff
  br i1 %choose, label %left, label %latch
left:
  %update = add i32 %sum, %wide
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %loop]
  %next = add i8 %iv, 1
  %done = icmp eq i8 %next, 255
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%merged, %latch]
  ret i32 %result
}

; CHECK-LABEL: define i32 @compact_i8_overflow(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @compact_i8_overflow(i32 %cutoff) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i8 [0, %preheader], [%next, %latch]
  %sum = phi i32 [17, %preheader], [%merged, %latch]
  %wide = zext i8 %iv to i32
  %choose = icmp ult i32 %wide, %cutoff
  br i1 %choose, label %left, label %latch
left:
  %update = add i32 %sum, %wide
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %loop]
  %next = add i8 %iv, 1
  %done = icmp eq i8 %next, 0
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%merged, %latch]
  ret i32 %result
}

; CHECK-LABEL: define i32 @compact_default_limit(
; CHECK: alloca [16384 x i32]
; CHECK: scalar.fission.consumer.guard:
; CHECK: scalar.fission.consumer.body:
; CHECK: scalar.fission.consumer.exit:
; CHECK: ret i32
define i32 @compact_default_limit(i32 %cutoff) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i16 [0, %preheader], [%next, %latch]
  %sum = phi i32 [17, %preheader], [%merged, %latch]
  %wide = zext i16 %iv to i32
  %choose = icmp ult i32 %wide, %cutoff
  br i1 %choose, label %left, label %latch
left:
  %update = add i32 %sum, %wide
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %loop]
  %next = add i16 %iv, 1
  %done = icmp eq i16 %next, 16384
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%merged, %latch]
  ret i32 %result
}

; CHECK-LABEL: define i32 @compact_over_limit(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @compact_over_limit(i32 %cutoff) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i16 [0, %preheader], [%next, %latch]
  %sum = phi i32 [17, %preheader], [%merged, %latch]
  %wide = zext i16 %iv to i32
  %choose = icmp ult i32 %wide, %cutoff
  br i1 %choose, label %left, label %latch
left:
  %update = add i32 %sum, %wide
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %loop]
  %next = add i16 %iv, 1
  %done = icmp eq i16 %next, 16385
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%merged, %latch]
  ret i32 %result
}

