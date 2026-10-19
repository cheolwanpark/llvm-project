; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @multiply_feedback(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @multiply_unsupported_division(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @multiply_unsafe(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @multiply_volatile(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @multiply_incompatible(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @multiply_switch(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @multiply_fp(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
declare void @effect(ptr) nounwind willreturn

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
