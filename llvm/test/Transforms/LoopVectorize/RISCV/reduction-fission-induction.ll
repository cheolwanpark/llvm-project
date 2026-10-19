; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @induction(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @negative_step(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @truncated(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @induction_liveout(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @floating_induction(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
define void @induction(ptr noalias readonly %a, ptr noalias %out, i32 %step) {
entry:
  %base = getelementptr i32, ptr %a, i64 1
  br label %loop
loop:
  %iv = phi i64 [ 0, %entry ], [ %next, %loop ]
  %r0 = phi i32 [ 0, %entry ], [ %n0, %loop ]
  %r1 = phi i32 [ 0, %entry ], [ %n1, %loop ]
  %r2 = phi i32 [ 0, %entry ], [ %n2, %loop ]
  %r3 = phi i32 [ -1, %entry ], [ %n3, %loop ]
  %r4 = phi i32 [ 1, %entry ], [ %n4, %loop ]
  %r5 = phi i32 [ 0, %entry ], [ %n5, %loop ]
  %r6 = phi i32 [ 0, %entry ], [ %n6, %loop ]
  %r7 = phi i32 [ 0, %entry ], [ %n7, %loop ]
  %j = phi i32 [ 19, %entry ], [ %j.next, %loop ]
  %j.next = add i32 %j, %step
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %c0 = add i32 %x, %j
  %c1 = mul i32 %c0, 3
  %c2 = add i32 %c1, 7
  %c3 = xor i32 %c2, 11
  %c4 = mul i32 %c3, 13
  %c5 = call i32 @llvm.abs.i32(i32 %c4, i1 false)
  %t0 = add i32 %r0, %c5
  %n0 = add i32 %t0, %x
  %n1 = xor i32 %r1, %c5
  %n2 = or i32 %r2, %c5
  %n3 = and i32 %r3, %c5
  %n4 = xor i32 %r4, %c5
  %n5 = call i32 @llvm.umax.i32(i32 %r5, i32 %c5)
  %n6 = add i32 %r6, %c5
  %n7 = add i32 %r7, %c5
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, 257
  br i1 %done, label %exit, label %loop
exit:
  store i32 %n0, ptr %out
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %n1, ptr %o1
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %n2, ptr %o2
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %n3, ptr %o3
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %n4, ptr %o4
  %o5 = getelementptr i32, ptr %out, i64 5
  store i32 %n5, ptr %o5
  %o6 = getelementptr i32, ptr %out, i64 6
  store i32 %n6, ptr %o6
  %o7 = getelementptr i32, ptr %out, i64 7
  store i32 %n7, ptr %o7
  ret void
}

define void @negative_step(ptr noalias readonly %a, ptr noalias %out, i32 %step) {
entry:
  %base = getelementptr i32, ptr %a, i64 1
  br label %loop
loop:
  %iv = phi i64 [ 0, %entry ], [ %next, %loop ]
  %r0 = phi i32 [ 0, %entry ], [ %n0, %loop ]
  %r1 = phi i32 [ 0, %entry ], [ %n1, %loop ]
  %r2 = phi i32 [ 0, %entry ], [ %n2, %loop ]
  %r3 = phi i32 [ -1, %entry ], [ %n3, %loop ]
  %r4 = phi i32 [ 1, %entry ], [ %n4, %loop ]
  %r5 = phi i32 [ 0, %entry ], [ %n5, %loop ]
  %r6 = phi i32 [ 0, %entry ], [ %n6, %loop ]
  %r7 = phi i32 [ 0, %entry ], [ %n7, %loop ]
  %j = phi i32 [ 19, %entry ], [ %j.next, %loop ]
  %j.next = add i32 %j, -3
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %c0 = add i32 %x, %j
  %c1 = mul i32 %c0, 3
  %c2 = add i32 %c1, 7
  %c3 = xor i32 %c2, 11
  %c4 = mul i32 %c3, 13
  %c5 = call i32 @llvm.abs.i32(i32 %c4, i1 false)
  %t0 = add i32 %r0, %c5
  %n0 = add i32 %t0, %x
  %n1 = xor i32 %r1, %c5
  %n2 = or i32 %r2, %c5
  %n3 = and i32 %r3, %c5
  %n4 = xor i32 %r4, %c5
  %n5 = call i32 @llvm.umax.i32(i32 %r5, i32 %c5)
  %n6 = add i32 %r6, %c5
  %n7 = add i32 %r7, %c5
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, 257
  br i1 %done, label %exit, label %loop
exit:
  store i32 %n0, ptr %out
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %n1, ptr %o1
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %n2, ptr %o2
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %n3, ptr %o3
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %n4, ptr %o4
  %o5 = getelementptr i32, ptr %out, i64 5
  store i32 %n5, ptr %o5
  %o6 = getelementptr i32, ptr %out, i64 6
  store i32 %n6, ptr %o6
  %o7 = getelementptr i32, ptr %out, i64 7
  store i32 %n7, ptr %o7
  ret void
}

define void @truncated(ptr noalias readonly %a, ptr noalias %out, i32 %step) {
entry:
  %wide.step = sext i32 %step to i64
  %base = getelementptr i32, ptr %a, i64 1
  br label %loop
loop:
  %iv = phi i64 [ 0, %entry ], [ %next, %loop ]
  %r0 = phi i32 [ 0, %entry ], [ %n0, %loop ]
  %r1 = phi i32 [ 0, %entry ], [ %n1, %loop ]
  %r2 = phi i32 [ 0, %entry ], [ %n2, %loop ]
  %r3 = phi i32 [ -1, %entry ], [ %n3, %loop ]
  %r4 = phi i32 [ 1, %entry ], [ %n4, %loop ]
  %r5 = phi i32 [ 0, %entry ], [ %n5, %loop ]
  %r6 = phi i32 [ 0, %entry ], [ %n6, %loop ]
  %r7 = phi i32 [ 0, %entry ], [ %n7, %loop ]
  %wide.j = phi i64 [ 9223372036854775806, %entry ], [ %wide.next, %loop ]
  %wide.next = add i64 %wide.j, %wide.step
  %narrow.j = trunc i64 %wide.j to i8
  %j = zext i8 %narrow.j to i32
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %c0 = add i32 %x, %j
  %c1 = mul i32 %c0, 3
  %c2 = add i32 %c1, 7
  %c3 = xor i32 %c2, 11
  %c4 = mul i32 %c3, 13
  %c5 = call i32 @llvm.abs.i32(i32 %c4, i1 false)
  %t0 = add i32 %r0, %c5
  %n0 = add i32 %t0, %x
  %n1 = xor i32 %r1, %c5
  %n2 = or i32 %r2, %c5
  %n3 = and i32 %r3, %c5
  %n4 = xor i32 %r4, %c5
  %n5 = call i32 @llvm.umax.i32(i32 %r5, i32 %c5)
  %n6 = add i32 %r6, %c5
  %n7 = add i32 %r7, %c5
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, 257
  br i1 %done, label %exit, label %loop
exit:
  store i32 %n0, ptr %out
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %n1, ptr %o1
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %n2, ptr %o2
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %n3, ptr %o3
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %n4, ptr %o4
  %o5 = getelementptr i32, ptr %out, i64 5
  store i32 %n5, ptr %o5
  %o6 = getelementptr i32, ptr %out, i64 6
  store i32 %n6, ptr %o6
  %o7 = getelementptr i32, ptr %out, i64 7
  store i32 %n7, ptr %o7
  ret void
}

define void @induction_liveout(ptr noalias readonly %a, ptr noalias %out, i32 %step) {
entry:
  %base = getelementptr i32, ptr %a, i64 1
  br label %loop
loop:
  %iv = phi i64 [ 0, %entry ], [ %next, %loop ]
  %r0 = phi i32 [ 0, %entry ], [ %n0, %loop ]
  %r1 = phi i32 [ 0, %entry ], [ %n1, %loop ]
  %r2 = phi i32 [ 0, %entry ], [ %n2, %loop ]
  %r3 = phi i32 [ -1, %entry ], [ %n3, %loop ]
  %r4 = phi i32 [ 1, %entry ], [ %n4, %loop ]
  %r5 = phi i32 [ 0, %entry ], [ %n5, %loop ]
  %r6 = phi i32 [ 0, %entry ], [ %n6, %loop ]
  %r7 = phi i32 [ 0, %entry ], [ %n7, %loop ]
  %j = phi i32 [ 19, %entry ], [ %j.next, %loop ]
  %j.next = add i32 %j, %step
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %c0 = add i32 %x, %j
  %c1 = mul i32 %c0, 3
  %c2 = add i32 %c1, 7
  %c3 = xor i32 %c2, 11
  %c4 = mul i32 %c3, 13
  %c5 = call i32 @llvm.abs.i32(i32 %c4, i1 false)
  %t0 = add i32 %r0, %c5
  %n0 = add i32 %t0, %x
  %n1 = xor i32 %r1, %c5
  %n2 = or i32 %r2, %c5
  %n3 = and i32 %r3, %c5
  %n4 = xor i32 %r4, %c5
  %n5 = call i32 @llvm.umax.i32(i32 %r5, i32 %c5)
  %n6 = add i32 %r6, %c5
  %n7 = add i32 %r7, %c5
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, 257
  br i1 %done, label %exit, label %loop
exit:
  store i32 %j, ptr %out
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %n1, ptr %o1
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %n2, ptr %o2
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %n3, ptr %o3
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %n4, ptr %o4
  %o5 = getelementptr i32, ptr %out, i64 5
  store i32 %n5, ptr %o5
  %o6 = getelementptr i32, ptr %out, i64 6
  store i32 %n6, ptr %o6
  %o7 = getelementptr i32, ptr %out, i64 7
  store i32 %n7, ptr %o7
  ret void
}

define void @floating_induction(ptr noalias readonly %a, ptr noalias %out, i32 %step) {
entry:
  %base = getelementptr i32, ptr %a, i64 1
  br label %loop
loop:
  %iv = phi i64 [ 0, %entry ], [ %next, %loop ]
  %r0 = phi i32 [ 0, %entry ], [ %n0, %loop ]
  %r1 = phi i32 [ 0, %entry ], [ %n1, %loop ]
  %r2 = phi i32 [ 0, %entry ], [ %n2, %loop ]
  %r3 = phi i32 [ -1, %entry ], [ %n3, %loop ]
  %r4 = phi i32 [ 1, %entry ], [ %n4, %loop ]
  %r5 = phi i32 [ 0, %entry ], [ %n5, %loop ]
  %r6 = phi i32 [ 0, %entry ], [ %n6, %loop ]
  %r7 = phi i32 [ 0, %entry ], [ %n7, %loop ]
  %fj = phi double [ 1.5, %entry ], [ %fj.next, %loop ]
  %fj.next = fadd fast double %fj, 1.5
  %j = fptosi double %fj to i32
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %c0 = add i32 %x, %j
  %c1 = mul i32 %c0, 3
  %c2 = add i32 %c1, 7
  %c3 = xor i32 %c2, 11
  %c4 = mul i32 %c3, 13
  %c5 = call i32 @llvm.abs.i32(i32 %c4, i1 false)
  %t0 = add i32 %r0, %c5
  %n0 = add i32 %t0, %x
  %n1 = xor i32 %r1, %c5
  %n2 = or i32 %r2, %c5
  %n3 = and i32 %r3, %c5
  %n4 = xor i32 %r4, %c5
  %n5 = call i32 @llvm.umax.i32(i32 %r5, i32 %c5)
  %n6 = add i32 %r6, %c5
  %n7 = add i32 %r7, %c5
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, 257
  br i1 %done, label %exit, label %loop
exit:
  store i32 %n0, ptr %out
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %n1, ptr %o1
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %n2, ptr %o2
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %n3, ptr %o3
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %n4, ptr %o4
  %o5 = getelementptr i32, ptr %out, i64 5
  store i32 %n5, ptr %o5
  %o6 = getelementptr i32, ptr %out, i64 6
  store i32 %n6, ptr %o6
  %o7 = getelementptr i32, ptr %out, i64 7
  store i32 %n7, ptr %o7
  ret void
}

declare i32 @llvm.abs.i32(i32, i1 immarg)
declare i32 @llvm.umax.i32(i32, i32)
