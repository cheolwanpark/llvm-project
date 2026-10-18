; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 -force-target-max-scalar-interleave=1 -enable-vplan-reduction-fission -pass-remarks-missed=vplan-reduction-fission -S %s -o %t 2> %t.remarks
; RUN: FileCheck %s --implicit-check-not=scalar.fission < %t
; RUN: FileCheck %s --check-prefix=REASON < %t.remarks
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 -force-target-max-scalar-interleave=1 -enable-vplan-reduction-fission -vplan-reduction-fission-allow-fp-reordering -S %s | FileCheck %s --implicit-check-not=scalar.fission
;
; Multiplication recognition retains accumulator/result edge closure, compatible
; participation, the exact opcode whitelist and simple-effect requirements.
; The positive file separately checks the padded below-one-entry ceiling.
declare void @effect(ptr) nounwind willreturn

; REASON: scalar-IR reduction fission rejected: scalar-reduction-feedback
; CHECK-LABEL: define i32 @multiply_feedback(
; CHECK: %update = mul i32 %sum, %x
; CHECK: ret i32
define i32 @multiply_feedback(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [ 0, %preheader ], [ %next, %loop ]
  %sum = phi i32 [ 19, %preheader ], [ %update, %loop ]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %update = mul i32 %sum, %x
  store i32 %update, ptr %p, align 4
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %update, %loop ]
  ret i32 %result
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsupported-recurrence
; CHECK-LABEL: define i32 @multiply_unsupported_division(
; CHECK: %update = udiv i32 %sum, %x
; CHECK: ret i32
define i32 @multiply_unsupported_division(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [ 0, %preheader ], [ %next, %loop ]
  %sum = phi i32 [ 19, %preheader ], [ %update, %loop ]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %update = udiv i32 %sum, %x
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %update, %loop ]
  ret i32 %result
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsafe-call
; CHECK-LABEL: define i32 @multiply_unsafe(
; CHECK: %update = mul i32 %sum, %x
; CHECK: ret i32
define i32 @multiply_unsafe(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [ 0, %preheader ], [ %next, %loop ]
  %sum = phi i32 [ 19, %preheader ], [ %update, %loop ]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %update = mul i32 %sum, %x
  call void @effect(ptr %p)
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %update, %loop ]
  ret i32 %result
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-non-simple-store
; CHECK-LABEL: define i32 @multiply_volatile(
; CHECK: %update = mul i32 %sum, %x
; CHECK: ret i32
define i32 @multiply_volatile(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [ 0, %preheader ], [ %next, %loop ]
  %sum = phi i32 [ 19, %preheader ], [ %update, %loop ]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %update = mul i32 %sum, %x
  store volatile i32 %x, ptr %p, align 4
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %update, %loop ]
  ret i32 %result
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-incompatible-participation
; CHECK-LABEL: define i32 @multiply_incompatible(
; CHECK: %u0 = mul i32 %r0, %x
; CHECK: %u1 = mul i32 %x, %r1
; CHECK: ret i32
define i32 @multiply_incompatible(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [ 0, %preheader ], [ %next, %latch ]
  %r0 = phi i32 [ 19, %preheader ], [ %u0, %latch ]
  %r1 = phi i32 [ 37, %preheader ], [ %m1, %latch ]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %u0 = mul i32 %r0, %x
  %active = icmp ne i32 %x, 0
  br i1 %active, label %left, label %right
left:
  %u1 = mul i32 %x, %r1
  br label %latch
right:
  br label %latch
latch:
  %m1 = phi i32 [ %u1, %left ], [ %r1, %right ]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %out0 = phi i32 [ %u0, %latch ]
  %out1 = phi i32 [ %m1, %latch ]
  %result = xor i32 %out0, %out1
  ret i32 %result
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsupported-cfg
; CHECK-LABEL: define i32 @multiply_switch(
; CHECK: switch i1 %active
; CHECK: ret i32
define i32 @multiply_switch(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [ 0, %preheader ], [ %next, %latch ]
  %r0 = phi i32 [ 19, %preheader ], [ %u0, %latch ]
  %r1 = phi i32 [ 37, %preheader ], [ %m1, %latch ]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %u0 = mul i32 %r0, %x
  %active = icmp ne i32 %x, 0
  switch i1 %active, label %right [ i1 true, label %left ]
left:
  %u1 = mul i32 %x, %r1
  br label %latch
right:
  br label %latch
latch:
  %m1 = phi i32 [ %u1, %left ], [ %r1, %right ]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %out0 = phi i32 [ %u0, %latch ]
  %out1 = phi i32 [ %m1, %latch ]
  %result = xor i32 %out0, %out1
  ret i32 %result
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsupported-recurrence
; CHECK-LABEL: define double @multiply_fp(
; CHECK: %update = fmul double %sum, %x
; CHECK: ret double
define double @multiply_fp(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [ 0, %preheader ], [ %next, %loop ]
  %sum = phi double [ 1.900000e+01, %preheader ], [ %update, %loop ]
  %p = getelementptr double, ptr %a, i64 %iv
  %x = load double, ptr %p, align 8
  %update = fmul double %sum, %x
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi double [ %update, %loop ]
  ret double %result
bypass:
  ret double 1.900000e+01
}
