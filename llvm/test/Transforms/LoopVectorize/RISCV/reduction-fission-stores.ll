; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @stores(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @shifted_input(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @same_iteration(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @overlapping_stores(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @invariant_store(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @volatile_store(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @atomic_store(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @prefix_store(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
define void @stores(ptr noalias readonly %a, ptr noalias %out, ptr noalias %dst, ptr noalias %dst2) {
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
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %c1 = mul i32 %x, 3
  %c2 = add i32 %c1, 7
  %c3 = xor i32 %c2, 11
  %c4 = mul i32 %c3, 13
  %c5 = call i32 @llvm.abs.i32(i32 %c4, i1 false)
  %q = getelementptr inbounds i32, ptr %dst, i64 %iv
  store i32 %c5, ptr %q, align 4
  %q2 = getelementptr inbounds i32, ptr %dst2, i64 %iv
  store i32 %x, ptr %q2, align 4
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

define void @shifted_input(ptr noalias %a, ptr noalias %out, ptr noalias %dst, ptr noalias %dst2) {
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
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %c1 = mul i32 %x, 3
  %c2 = add i32 %c1, 7
  %c3 = xor i32 %c2, 11
  %c4 = mul i32 %c3, 13
  %c5 = call i32 @llvm.abs.i32(i32 %c4, i1 false)
  %shift = add i64 %iv, 1
  %q = getelementptr inbounds i32, ptr %base, i64 %shift
  store i32 %c5, ptr %q, align 4
  %q2 = getelementptr inbounds i32, ptr %dst2, i64 %iv
  store i32 %x, ptr %q2, align 4
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

define void @same_iteration(ptr noalias %a, ptr noalias %out, ptr noalias %dst, ptr noalias %dst2) {
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
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %c1 = mul i32 %x, 3
  %c2 = add i32 %c1, 7
  %c3 = xor i32 %c2, 11
  %c4 = mul i32 %c3, 13
  %c5 = call i32 @llvm.abs.i32(i32 %c4, i1 false)
  %q = getelementptr inbounds i32, ptr %base, i64 %iv
  store i32 %c5, ptr %q, align 4
  %q2 = getelementptr inbounds i32, ptr %dst2, i64 %iv
  store i32 %x, ptr %q2, align 4
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

define void @overlapping_stores(ptr noalias readonly %a, ptr noalias %out, ptr noalias %dst, ptr noalias %dst2) {
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
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %c1 = mul i32 %x, 3
  %c2 = add i32 %c1, 7
  %c3 = xor i32 %c2, 11
  %c4 = mul i32 %c3, 13
  %c5 = call i32 @llvm.abs.i32(i32 %c4, i1 false)
  %q = getelementptr inbounds i32, ptr %dst, i64 %iv
  store i32 %c5, ptr %q, align 4
  %q2 = getelementptr inbounds i32, ptr %dst, i64 %iv
  store i32 %x, ptr %q2, align 4
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

define void @invariant_store(ptr noalias readonly %a, ptr noalias %out, ptr noalias %dst, ptr noalias %dst2) {
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
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %c1 = mul i32 %x, 3
  %c2 = add i32 %c1, 7
  %c3 = xor i32 %c2, 11
  %c4 = mul i32 %c3, 13
  %c5 = call i32 @llvm.abs.i32(i32 %c4, i1 false)
  %q = getelementptr inbounds i32, ptr %dst, i64 0
  store i32 %c5, ptr %q, align 4
  %q2 = getelementptr inbounds i32, ptr %dst2, i64 %iv
  store i32 %x, ptr %q2, align 4
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

define void @volatile_store(ptr noalias readonly %a, ptr noalias %out, ptr noalias %dst, ptr noalias %dst2) {
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
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %c1 = mul i32 %x, 3
  %c2 = add i32 %c1, 7
  %c3 = xor i32 %c2, 11
  %c4 = mul i32 %c3, 13
  %c5 = call i32 @llvm.abs.i32(i32 %c4, i1 false)
  %q = getelementptr inbounds i32, ptr %dst, i64 %iv
  store volatile i32 %c5, ptr %q, align 4
  %q2 = getelementptr inbounds i32, ptr %dst2, i64 %iv
  store i32 %x, ptr %q2, align 4
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

define void @atomic_store(ptr noalias readonly %a, ptr noalias %out, ptr noalias %dst, ptr noalias %dst2) {
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
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %c1 = mul i32 %x, 3
  %c2 = add i32 %c1, 7
  %c3 = xor i32 %c2, 11
  %c4 = mul i32 %c3, 13
  %c5 = call i32 @llvm.abs.i32(i32 %c4, i1 false)
  %q = getelementptr inbounds i32, ptr %dst, i64 %iv
  store atomic i32 %c5, ptr %q monotonic, align 4
  %q2 = getelementptr inbounds i32, ptr %dst2, i64 %iv
  store i32 %x, ptr %q2, align 4
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

define void @prefix_store(ptr noalias readonly %a, ptr noalias %out, ptr noalias %dst, ptr noalias %dst2) {
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
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %c1 = mul i32 %x, 3
  %c2 = add i32 %c1, 7
  %c3 = xor i32 %c2, 11
  %c4 = mul i32 %c3, 13
  %c5 = call i32 @llvm.abs.i32(i32 %c4, i1 false)
  %q = getelementptr inbounds i32, ptr %dst, i64 %iv
  %q2 = getelementptr inbounds i32, ptr %dst2, i64 %iv
  store i32 %x, ptr %q2, align 4
  %t0 = add i32 %r0, %c5
  %n0 = add i32 %t0, %x
  %n1 = xor i32 %r1, %c5
  %n2 = or i32 %r2, %c5
  %n3 = and i32 %r3, %c5
  %n4 = xor i32 %r4, %c5
  %n5 = call i32 @llvm.umax.i32(i32 %r5, i32 %c5)
  %n6 = add i32 %r6, %c5
  %n7 = add i32 %r7, %c5
  store i32 %n7, ptr %q, align 4
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
