; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -pass-remarks=vplan-reduction-fission \
; RUN:   -pass-remarks-missed=vplan-reduction-fission -S %s -o %t 2> %t.remarks
; RUN: FileCheck %s < %t
; RUN: FileCheck %s --check-prefix=REMARK < %t.remarks
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=3 -S %s | FileCheck %s --check-prefix=TINY --implicit-check-not=scalar.fission
;
; Allocation boundaries: one, maximum i8 trip count, first unrepresentable
; count, exact default byte ceiling, first over-ceiling now uses bounded chunks. Runtime zero/one/65
; and invalid entry guards are also exercised by scalar-acyclic.ll's checker.
; REMARK: scratch capacity 1, scratch bytes 4
; REMARK: scratch capacity 255, scratch bytes 1020
; REMARK: scalar-IR reduction fission rejected: trip-count-overflow
; REMARK: scratch capacity 16384, scratch bytes 65536
; REMARK: scratch capacity 16384, scratch bytes 65536, producer live-outs 0, chunked schedule, trip bound 16385

; CHECK-LABEL: define i32 @acyclic_one(
; CHECK: alloca [1 x i32]
; CHECK: scalar.fission.consumer.body:
; CHECK: ret i32
; TINY-LABEL: define i32 @acyclic_one(
; TINY: ret i32
define i32 @acyclic_one(i32 %cutoff) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i8 [0, %preheader], [%next, %latch]
  %sum = phi i32 [17, %preheader], [%update, %latch]
  %wide = zext i8 %iv to i32
  %choose = icmp ult i32 %wide, %cutoff
  br i1 %choose, label %left, label %first.merge
left:
  %lc = add i32 %wide, 3
  br label %first.merge
first.merge:
  %first = phi i32 [%wide, %loop], [%lc, %left]
  %bit = and i32 %wide, 1
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %right, label %latch
right:
  %rc = xor i32 %first, 7
  br label %latch
latch:
  %c = phi i32 [%first, %first.merge], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add i8 %iv, 1
  %done = icmp eq i8 %next, 1
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%update, %latch]
  ret i32 %result
}

; CHECK-LABEL: define i32 @acyclic_i8_max(
; CHECK: alloca [255 x i32]
; CHECK: scalar.fission.consumer.body:
; CHECK: ret i32
; TINY-LABEL: define i32 @acyclic_i8_max(
; TINY: ret i32
define i32 @acyclic_i8_max(i32 %cutoff) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i8 [0, %preheader], [%next, %latch]
  %sum = phi i32 [17, %preheader], [%update, %latch]
  %wide = zext i8 %iv to i32
  %choose = icmp ult i32 %wide, %cutoff
  br i1 %choose, label %left, label %first.merge
left:
  %lc = add i32 %wide, 3
  br label %first.merge
first.merge:
  %first = phi i32 [%wide, %loop], [%lc, %left]
  %bit = and i32 %wide, 1
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %right, label %latch
right:
  %rc = xor i32 %first, 7
  br label %latch
latch:
  %c = phi i32 [%first, %first.merge], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add i8 %iv, 1
  %done = icmp eq i8 %next, 255
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%update, %latch]
  ret i32 %result
}

; CHECK-LABEL: define i32 @acyclic_i8_overflow(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
; TINY-LABEL: define i32 @acyclic_i8_overflow(
; TINY: ret i32
define i32 @acyclic_i8_overflow(i32 %cutoff) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i8 [0, %preheader], [%next, %latch]
  %sum = phi i32 [17, %preheader], [%update, %latch]
  %wide = zext i8 %iv to i32
  %choose = icmp ult i32 %wide, %cutoff
  br i1 %choose, label %left, label %first.merge
left:
  %lc = add i32 %wide, 3
  br label %first.merge
first.merge:
  %first = phi i32 [%wide, %loop], [%lc, %left]
  %bit = and i32 %wide, 1
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %right, label %latch
right:
  %rc = xor i32 %first, 7
  br label %latch
latch:
  %c = phi i32 [%first, %first.merge], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add i8 %iv, 1
  %done = icmp eq i8 %next, 0
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%update, %latch]
  ret i32 %result
}

; CHECK-LABEL: define i32 @acyclic_default_limit(
; CHECK: alloca [16384 x i32]
; CHECK: scalar.fission.consumer.body:
; CHECK: ret i32
; TINY-LABEL: define i32 @acyclic_default_limit(
; TINY: ret i32
define i32 @acyclic_default_limit(i32 %cutoff) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i16 [0, %preheader], [%next, %latch]
  %sum = phi i32 [17, %preheader], [%update, %latch]
  %wide = zext i16 %iv to i32
  %choose = icmp ult i32 %wide, %cutoff
  br i1 %choose, label %left, label %first.merge
left:
  %lc = add i32 %wide, 3
  br label %first.merge
first.merge:
  %first = phi i32 [%wide, %loop], [%lc, %left]
  %bit = and i32 %wide, 1
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %right, label %latch
right:
  %rc = xor i32 %first, 7
  br label %latch
latch:
  %c = phi i32 [%first, %first.merge], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add i16 %iv, 1
  %done = icmp eq i16 %next, 16384
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%update, %latch]
  ret i32 %result
}

; CHECK-LABEL: define i32 @acyclic_over_limit(
; CHECK: alloca [16384 x i32]
; CHECK: scalar.fission.chunk:
; CHECK: %fission.chunk.partial = icmp ult i16 %fission.chunk.remaining, 16384
; CHECK: scalar.fission.consumer.body:
; CHECK: ret i32
; TINY-LABEL: define i32 @acyclic_over_limit(
; TINY: ret i32
define i32 @acyclic_over_limit(i32 %cutoff) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i16 [0, %preheader], [%next, %latch]
  %sum = phi i32 [17, %preheader], [%update, %latch]
  %wide = zext i16 %iv to i32
  %choose = icmp ult i32 %wide, %cutoff
  br i1 %choose, label %left, label %first.merge
left:
  %lc = add i32 %wide, 3
  br label %first.merge
first.merge:
  %first = phi i32 [%wide, %loop], [%lc, %left]
  %bit = and i32 %wide, 1
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %right, label %latch
right:
  %rc = xor i32 %first, 7
  br label %latch
latch:
  %c = phi i32 [%first, %first.merge], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add i16 %iv, 1
  %done = icmp eq i16 %next, 16385
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%update, %latch]
  ret i32 %result
}

