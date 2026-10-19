; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @minmax_feedback(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @minmax_unsupported_division(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @minmax_unsafe(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @minmax_volatile(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @minmax_incompatible(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @minmax_no_accumulator(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @minmax_twice(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @minmax_ordinary_call(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @minmax_address(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @minmax_cross(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @minmax_tail(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @minmax_bundle(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @minmax_noduplicate(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @minmax_abs(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @minmax_float(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @minmax_predicate(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
declare i32 @llvm.smin.i32(i32, i32)
declare i32 @llvm.smax.i32(i32, i32)
declare i32 @llvm.umin.i32(i32, i32)
declare i32 @llvm.umax.i32(i32, i32)

declare void @effect(ptr) nounwind willreturn

define i32 @minmax_feedback(ptr %a, i64 %n) {
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
  %update = call i32 @llvm.smin.i32(i32 %sum, i32 %x)
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

define i32 @minmax_unsupported_division(ptr %a, i64 %n) {
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

define i32 @minmax_unsafe(ptr %a, i64 %n) {
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
  %update = call i32 @llvm.smax.i32(i32 %sum, i32 %x)
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

define i32 @minmax_volatile(ptr %a, i64 %n) {
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
  %update = call i32 @llvm.umax.i32(i32 %sum, i32 %x)
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

define i32 @minmax_incompatible(ptr %a, i64 %n) {
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
  %u0 = call i32 @llvm.umin.i32(i32 %r0, i32 %x)
  %active = icmp ne i32 %x, 0
  br i1 %active, label %left, label %right
left:
  %u1 = call i32 @llvm.umax.i32(i32 %x, i32 %r1)
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

define i32 @minmax_no_accumulator(ptr %a, i64 %n) {
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
  %update = call i32 @llvm.smin.i32(i32 %x, i32 9)
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %update, %loop ]
  ret i32 %result
bypass:
  ret i32 19
}

define i32 @minmax_twice(ptr %a, i64 %n) {
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
  %update = call i32 @llvm.umax.i32(i32 %sum, i32 %sum)
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %update, %loop ]
  ret i32 %result
bypass:
  ret i32 19
}

define i32 @minmax_ordinary_call(ptr %a, i64 %n) {
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
  %update = call i32 @other_min(i32 %sum, i32 %x)
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %update, %loop ]
  ret i32 %result
bypass:
  ret i32 19
}

declare i32 @other_min(i32, i32) nounwind willreturn speculatable memory(none)

define i32 @minmax_address(ptr %a, i64 %n) {
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
  %update = call i32 @llvm.smin.i32(i32 %sum, i32 %x)
  %offset = zext i32 %update to i64
  %q = getelementptr i32, ptr %a, i64 %offset
  store i32 %x, ptr %q, align 4
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %update, %loop ]
  ret i32 %result
bypass:
  ret i32 19
}

define i32 @minmax_cross(ptr %a, i64 %n) {
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
  %r1 = phi i32 [ 37, %preheader ], [ %u1, %loop ]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %update = call i32 @llvm.smin.i32(i32 %sum, i32 %r1)
  %u1 = call i32 @llvm.umax.i32(i32 %r1, i32 %sum)
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %update, %loop ]
  ret i32 %result
bypass:
  ret i32 19
}

define i32 @minmax_tail(ptr %a, i64 %n) {
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
  %update = tail call i32 @llvm.smin.i32(i32 %sum, i32 %x)
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %update, %loop ]
  ret i32 %result
bypass:
  ret i32 19
}

define i32 @minmax_bundle(ptr %a, i64 %n) {
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
  %update = call i32 @llvm.smin.i32(i32 %sum, i32 %x) [ "deopt"() ]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %update, %loop ]
  ret i32 %result
bypass:
  ret i32 19
}

define i32 @minmax_noduplicate(ptr %a, i64 %n) {
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
  %update = call i32 @llvm.smin.i32(i32 %sum, i32 %x) noduplicate
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %update, %loop ]
  ret i32 %result
bypass:
  ret i32 19
}

define i32 @minmax_abs(ptr %a, i64 %n) {
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
  %update = call i32 @llvm.abs.i32(i32 %sum, i1 false)
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %update, %loop ]
  ret i32 %result
bypass:
  ret i32 19
}

declare i32 @llvm.abs.i32(i32, i1 immarg)

define float @minmax_float(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [ 0, %preheader ], [ %next, %loop ]
  %sum = phi float [ 1.900000e+01, %preheader ], [ %update, %loop ]
  %p = getelementptr float, ptr %a, i64 %iv
  %x = load float, ptr %p, align 4
  %update = call float @llvm.minnum.f32(float %sum, float %x)
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [ %update, %loop ]
  ret float %result
bypass:
  ret float 1.900000e+01
}
declare float @llvm.minnum.f32(float, float)

define i32 @minmax_predicate(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [ 0, %preheader ], [ %next, %latch ]
  %sum = phi i32 [ 19, %preheader ], [ %merged, %latch ]
  %choose = icmp ne i32 %sum, 0
  br i1 %choose, label %left, label %latch
left:
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %update = call i32 @llvm.smin.i32(i32 %sum, i32 %x)
  br label %latch
latch:
  %merged = phi i32 [ %update, %left ], [ %sum, %loop ]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %merged, %latch ]
  ret i32 %result
bypass:
  ret i32 19
}
