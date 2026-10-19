; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @interleave4(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @interleave4_members(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @interleave5(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @interleave5_members(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @interleave6(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @interleave6_members(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @interleave7(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @interleave7_members(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @interleave8(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @interleave8_members(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
define void @interleave4(ptr readonly %a, ptr %out, i64 %n) !dbg !5 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !6
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [23, %preheader], [%u1, %loop]
  %base = mul nuw i64 %i, 4
  %idx3 = add nuw i64 %base, 3
  %p3 = getelementptr i32, ptr %a, i64 %idx3
  %x3 = load i32, ptr %p3, align 4
  %p0 = getelementptr i32, ptr %a, i64 %base
  %x0 = load i32, ptr %p0, align 4
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr i32, ptr %a, i64 %idx1
  %x1 = load i32, ptr %p1, align 4
  %idx2 = add nuw i64 %base, 2
  %p2 = getelementptr i32, ptr %a, i64 %idx2
  %x2 = load i32, ptr %p2, align 4
  %scaled = mul i32 %x0, 3
  %shared = xor i32 %scaled, %x0
  %term1 = add i32 %shared, %x1
  %term2 = xor i32 %term1, %x2
  %term3 = add i32 %term2, %x3
  %u0 = add i32 %r0, %term3
  %u1 = xor i32 %r1, %term3
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !6
exit:
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %u0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %u1, ptr %o1, align 4
  ret void
bypass:
  %b0 = getelementptr i32, ptr %out, i64 0
  store i32 17, ptr %b0, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  ret void
}

define void @interleave4_members(ptr readonly %a, ptr %out, i64 %n) !dbg !7 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !8
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [23, %preheader], [%u1, %loop]
  %r2 = phi i32 [29, %preheader], [%u2, %loop]
  %r3 = phi i32 [35, %preheader], [%u3, %loop]
  %r4 = phi i32 [41, %preheader], [%u4, %loop]
  %base = mul nuw i64 %i, 4
  %idx3 = add nuw i64 %base, 3
  %p3 = getelementptr i32, ptr %a, i64 %idx3
  %x3 = load i32, ptr %p3, align 4
  %p0 = getelementptr i32, ptr %a, i64 %base
  %x0 = load i32, ptr %p0, align 4
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr i32, ptr %a, i64 %idx1
  %x1 = load i32, ptr %p1, align 4
  %idx2 = add nuw i64 %base, 2
  %p2 = getelementptr i32, ptr %a, i64 %idx2
  %x2 = load i32, ptr %p2, align 4
  %u0 = add i32 %r0, %x0
  %u1 = xor i32 %r1, %x1
  %u2 = add i32 %r2, %x2
  %u3 = xor i32 %r3, %x3
  %u4 = add i32 %r4, %x3
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !8
exit:
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %u0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %u1, ptr %o1, align 4
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %u2, ptr %o2, align 4
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %u3, ptr %o3, align 4
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %u4, ptr %o4, align 4
  ret void
bypass:
  %b0 = getelementptr i32, ptr %out, i64 0
  store i32 17, ptr %b0, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  %b2 = getelementptr i32, ptr %out, i64 2
  store i32 29, ptr %b2, align 4
  %b3 = getelementptr i32, ptr %out, i64 3
  store i32 35, ptr %b3, align 4
  %b4 = getelementptr i32, ptr %out, i64 4
  store i32 41, ptr %b4, align 4
  ret void
}

define void @interleave5(ptr readonly %a, ptr %out, i64 %n) !dbg !9 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !10
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [23, %preheader], [%u1, %loop]
  %base = mul nuw i64 %i, 5
  %idx4 = add nuw i64 %base, 4
  %p4 = getelementptr i32, ptr %a, i64 %idx4
  %x4 = load i32, ptr %p4, align 4
  %p0 = getelementptr i32, ptr %a, i64 %base
  %x0 = load i32, ptr %p0, align 4
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr i32, ptr %a, i64 %idx1
  %x1 = load i32, ptr %p1, align 4
  %idx2 = add nuw i64 %base, 2
  %p2 = getelementptr i32, ptr %a, i64 %idx2
  %x2 = load i32, ptr %p2, align 4
  %idx3 = add nuw i64 %base, 3
  %p3 = getelementptr i32, ptr %a, i64 %idx3
  %x3 = load i32, ptr %p3, align 4
  %scaled = mul i32 %x0, 3
  %shared = xor i32 %scaled, %x0
  %term1 = add i32 %shared, %x1
  %term2 = xor i32 %term1, %x2
  %term3 = add i32 %term2, %x3
  %term4 = xor i32 %term3, %x4
  %u0 = add i32 %r0, %term4
  %u1 = xor i32 %r1, %term4
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !10
exit:
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %u0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %u1, ptr %o1, align 4
  ret void
bypass:
  %b0 = getelementptr i32, ptr %out, i64 0
  store i32 17, ptr %b0, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  ret void
}

define void @interleave5_members(ptr readonly %a, ptr %out, i64 %n) !dbg !11 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !12
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [23, %preheader], [%u1, %loop]
  %r2 = phi i32 [29, %preheader], [%u2, %loop]
  %r3 = phi i32 [35, %preheader], [%u3, %loop]
  %r4 = phi i32 [41, %preheader], [%u4, %loop]
  %r5 = phi i32 [47, %preheader], [%u5, %loop]
  %base = mul nuw i64 %i, 5
  %idx4 = add nuw i64 %base, 4
  %p4 = getelementptr i32, ptr %a, i64 %idx4
  %x4 = load i32, ptr %p4, align 4
  %p0 = getelementptr i32, ptr %a, i64 %base
  %x0 = load i32, ptr %p0, align 4
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr i32, ptr %a, i64 %idx1
  %x1 = load i32, ptr %p1, align 4
  %idx2 = add nuw i64 %base, 2
  %p2 = getelementptr i32, ptr %a, i64 %idx2
  %x2 = load i32, ptr %p2, align 4
  %idx3 = add nuw i64 %base, 3
  %p3 = getelementptr i32, ptr %a, i64 %idx3
  %x3 = load i32, ptr %p3, align 4
  %u0 = add i32 %r0, %x0
  %u1 = xor i32 %r1, %x1
  %u2 = add i32 %r2, %x2
  %u3 = xor i32 %r3, %x3
  %u4 = add i32 %r4, %x4
  %u5 = xor i32 %r5, %x4
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !12
exit:
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %u0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %u1, ptr %o1, align 4
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %u2, ptr %o2, align 4
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %u3, ptr %o3, align 4
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %u4, ptr %o4, align 4
  %o5 = getelementptr i32, ptr %out, i64 5
  store i32 %u5, ptr %o5, align 4
  ret void
bypass:
  %b0 = getelementptr i32, ptr %out, i64 0
  store i32 17, ptr %b0, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  %b2 = getelementptr i32, ptr %out, i64 2
  store i32 29, ptr %b2, align 4
  %b3 = getelementptr i32, ptr %out, i64 3
  store i32 35, ptr %b3, align 4
  %b4 = getelementptr i32, ptr %out, i64 4
  store i32 41, ptr %b4, align 4
  %b5 = getelementptr i32, ptr %out, i64 5
  store i32 47, ptr %b5, align 4
  ret void
}

define void @interleave6(ptr readonly %a, ptr %out, i64 %n) !dbg !13 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !14
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [23, %preheader], [%u1, %loop]
  %base = mul nuw i64 %i, 6
  %idx5 = add nuw i64 %base, 5
  %p5 = getelementptr i32, ptr %a, i64 %idx5
  %x5 = load i32, ptr %p5, align 4
  %p0 = getelementptr i32, ptr %a, i64 %base
  %x0 = load i32, ptr %p0, align 4
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr i32, ptr %a, i64 %idx1
  %x1 = load i32, ptr %p1, align 4
  %idx2 = add nuw i64 %base, 2
  %p2 = getelementptr i32, ptr %a, i64 %idx2
  %x2 = load i32, ptr %p2, align 4
  %idx3 = add nuw i64 %base, 3
  %p3 = getelementptr i32, ptr %a, i64 %idx3
  %x3 = load i32, ptr %p3, align 4
  %idx4 = add nuw i64 %base, 4
  %p4 = getelementptr i32, ptr %a, i64 %idx4
  %x4 = load i32, ptr %p4, align 4
  %scaled = mul i32 %x0, 3
  %shared = xor i32 %scaled, %x0
  %term1 = add i32 %shared, %x1
  %term2 = xor i32 %term1, %x2
  %term3 = add i32 %term2, %x3
  %term4 = xor i32 %term3, %x4
  %term5 = add i32 %term4, %x5
  %u0 = add i32 %r0, %term5
  %u1 = xor i32 %r1, %term5
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !14
exit:
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %u0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %u1, ptr %o1, align 4
  ret void
bypass:
  %b0 = getelementptr i32, ptr %out, i64 0
  store i32 17, ptr %b0, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  ret void
}

define void @interleave6_members(ptr readonly %a, ptr %out, i64 %n) !dbg !15 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !16
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [23, %preheader], [%u1, %loop]
  %r2 = phi i32 [29, %preheader], [%u2, %loop]
  %r3 = phi i32 [35, %preheader], [%u3, %loop]
  %r4 = phi i32 [41, %preheader], [%u4, %loop]
  %r5 = phi i32 [47, %preheader], [%u5, %loop]
  %r6 = phi i32 [53, %preheader], [%u6, %loop]
  %base = mul nuw i64 %i, 6
  %idx5 = add nuw i64 %base, 5
  %p5 = getelementptr i32, ptr %a, i64 %idx5
  %x5 = load i32, ptr %p5, align 4
  %p0 = getelementptr i32, ptr %a, i64 %base
  %x0 = load i32, ptr %p0, align 4
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr i32, ptr %a, i64 %idx1
  %x1 = load i32, ptr %p1, align 4
  %idx2 = add nuw i64 %base, 2
  %p2 = getelementptr i32, ptr %a, i64 %idx2
  %x2 = load i32, ptr %p2, align 4
  %idx3 = add nuw i64 %base, 3
  %p3 = getelementptr i32, ptr %a, i64 %idx3
  %x3 = load i32, ptr %p3, align 4
  %idx4 = add nuw i64 %base, 4
  %p4 = getelementptr i32, ptr %a, i64 %idx4
  %x4 = load i32, ptr %p4, align 4
  %u0 = add i32 %r0, %x0
  %u1 = xor i32 %r1, %x1
  %u2 = add i32 %r2, %x2
  %u3 = xor i32 %r3, %x3
  %u4 = add i32 %r4, %x4
  %u5 = xor i32 %r5, %x5
  %u6 = add i32 %r6, %x5
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !16
exit:
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %u0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %u1, ptr %o1, align 4
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %u2, ptr %o2, align 4
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %u3, ptr %o3, align 4
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %u4, ptr %o4, align 4
  %o5 = getelementptr i32, ptr %out, i64 5
  store i32 %u5, ptr %o5, align 4
  %o6 = getelementptr i32, ptr %out, i64 6
  store i32 %u6, ptr %o6, align 4
  ret void
bypass:
  %b0 = getelementptr i32, ptr %out, i64 0
  store i32 17, ptr %b0, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  %b2 = getelementptr i32, ptr %out, i64 2
  store i32 29, ptr %b2, align 4
  %b3 = getelementptr i32, ptr %out, i64 3
  store i32 35, ptr %b3, align 4
  %b4 = getelementptr i32, ptr %out, i64 4
  store i32 41, ptr %b4, align 4
  %b5 = getelementptr i32, ptr %out, i64 5
  store i32 47, ptr %b5, align 4
  %b6 = getelementptr i32, ptr %out, i64 6
  store i32 53, ptr %b6, align 4
  ret void
}

define void @interleave7(ptr readonly %a, ptr %out, i64 %n) !dbg !17 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !18
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [23, %preheader], [%u1, %loop]
  %base = mul nuw i64 %i, 7
  %idx6 = add nuw i64 %base, 6
  %p6 = getelementptr i32, ptr %a, i64 %idx6
  %x6 = load i32, ptr %p6, align 4
  %p0 = getelementptr i32, ptr %a, i64 %base
  %x0 = load i32, ptr %p0, align 4
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr i32, ptr %a, i64 %idx1
  %x1 = load i32, ptr %p1, align 4
  %idx2 = add nuw i64 %base, 2
  %p2 = getelementptr i32, ptr %a, i64 %idx2
  %x2 = load i32, ptr %p2, align 4
  %idx3 = add nuw i64 %base, 3
  %p3 = getelementptr i32, ptr %a, i64 %idx3
  %x3 = load i32, ptr %p3, align 4
  %idx4 = add nuw i64 %base, 4
  %p4 = getelementptr i32, ptr %a, i64 %idx4
  %x4 = load i32, ptr %p4, align 4
  %idx5 = add nuw i64 %base, 5
  %p5 = getelementptr i32, ptr %a, i64 %idx5
  %x5 = load i32, ptr %p5, align 4
  %scaled = mul i32 %x0, 3
  %shared = xor i32 %scaled, %x0
  %term1 = add i32 %shared, %x1
  %term2 = xor i32 %term1, %x2
  %term3 = add i32 %term2, %x3
  %term4 = xor i32 %term3, %x4
  %term5 = add i32 %term4, %x5
  %term6 = xor i32 %term5, %x6
  %u0 = add i32 %r0, %term6
  %u1 = xor i32 %r1, %term6
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !18
exit:
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %u0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %u1, ptr %o1, align 4
  ret void
bypass:
  %b0 = getelementptr i32, ptr %out, i64 0
  store i32 17, ptr %b0, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  ret void
}

define void @interleave7_members(ptr readonly %a, ptr %out, i64 %n) !dbg !19 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !20
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [23, %preheader], [%u1, %loop]
  %r2 = phi i32 [29, %preheader], [%u2, %loop]
  %r3 = phi i32 [35, %preheader], [%u3, %loop]
  %r4 = phi i32 [41, %preheader], [%u4, %loop]
  %r5 = phi i32 [47, %preheader], [%u5, %loop]
  %r6 = phi i32 [53, %preheader], [%u6, %loop]
  %r7 = phi i32 [59, %preheader], [%u7, %loop]
  %base = mul nuw i64 %i, 7
  %idx6 = add nuw i64 %base, 6
  %p6 = getelementptr i32, ptr %a, i64 %idx6
  %x6 = load i32, ptr %p6, align 4
  %p0 = getelementptr i32, ptr %a, i64 %base
  %x0 = load i32, ptr %p0, align 4
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr i32, ptr %a, i64 %idx1
  %x1 = load i32, ptr %p1, align 4
  %idx2 = add nuw i64 %base, 2
  %p2 = getelementptr i32, ptr %a, i64 %idx2
  %x2 = load i32, ptr %p2, align 4
  %idx3 = add nuw i64 %base, 3
  %p3 = getelementptr i32, ptr %a, i64 %idx3
  %x3 = load i32, ptr %p3, align 4
  %idx4 = add nuw i64 %base, 4
  %p4 = getelementptr i32, ptr %a, i64 %idx4
  %x4 = load i32, ptr %p4, align 4
  %idx5 = add nuw i64 %base, 5
  %p5 = getelementptr i32, ptr %a, i64 %idx5
  %x5 = load i32, ptr %p5, align 4
  %u0 = add i32 %r0, %x0
  %u1 = xor i32 %r1, %x1
  %u2 = add i32 %r2, %x2
  %u3 = xor i32 %r3, %x3
  %u4 = add i32 %r4, %x4
  %u5 = xor i32 %r5, %x5
  %u6 = add i32 %r6, %x6
  %u7 = xor i32 %r7, %x6
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !20
exit:
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %u0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %u1, ptr %o1, align 4
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %u2, ptr %o2, align 4
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %u3, ptr %o3, align 4
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %u4, ptr %o4, align 4
  %o5 = getelementptr i32, ptr %out, i64 5
  store i32 %u5, ptr %o5, align 4
  %o6 = getelementptr i32, ptr %out, i64 6
  store i32 %u6, ptr %o6, align 4
  %o7 = getelementptr i32, ptr %out, i64 7
  store i32 %u7, ptr %o7, align 4
  ret void
bypass:
  %b0 = getelementptr i32, ptr %out, i64 0
  store i32 17, ptr %b0, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  %b2 = getelementptr i32, ptr %out, i64 2
  store i32 29, ptr %b2, align 4
  %b3 = getelementptr i32, ptr %out, i64 3
  store i32 35, ptr %b3, align 4
  %b4 = getelementptr i32, ptr %out, i64 4
  store i32 41, ptr %b4, align 4
  %b5 = getelementptr i32, ptr %out, i64 5
  store i32 47, ptr %b5, align 4
  %b6 = getelementptr i32, ptr %out, i64 6
  store i32 53, ptr %b6, align 4
  %b7 = getelementptr i32, ptr %out, i64 7
  store i32 59, ptr %b7, align 4
  ret void
}

define void @interleave8(ptr readonly %a, ptr %out, i64 %n) !dbg !21 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !22
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [23, %preheader], [%u1, %loop]
  %base = mul nuw i64 %i, 8
  %idx7 = add nuw i64 %base, 7
  %p7 = getelementptr i32, ptr %a, i64 %idx7
  %x7 = load i32, ptr %p7, align 4
  %p0 = getelementptr i32, ptr %a, i64 %base
  %x0 = load i32, ptr %p0, align 4
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr i32, ptr %a, i64 %idx1
  %x1 = load i32, ptr %p1, align 4
  %idx2 = add nuw i64 %base, 2
  %p2 = getelementptr i32, ptr %a, i64 %idx2
  %x2 = load i32, ptr %p2, align 4
  %idx3 = add nuw i64 %base, 3
  %p3 = getelementptr i32, ptr %a, i64 %idx3
  %x3 = load i32, ptr %p3, align 4
  %idx4 = add nuw i64 %base, 4
  %p4 = getelementptr i32, ptr %a, i64 %idx4
  %x4 = load i32, ptr %p4, align 4
  %idx5 = add nuw i64 %base, 5
  %p5 = getelementptr i32, ptr %a, i64 %idx5
  %x5 = load i32, ptr %p5, align 4
  %idx6 = add nuw i64 %base, 6
  %p6 = getelementptr i32, ptr %a, i64 %idx6
  %x6 = load i32, ptr %p6, align 4
  %scaled = mul i32 %x0, 3
  %shared = xor i32 %scaled, %x0
  %term1 = add i32 %shared, %x1
  %term2 = xor i32 %term1, %x2
  %term3 = add i32 %term2, %x3
  %term4 = xor i32 %term3, %x4
  %term5 = add i32 %term4, %x5
  %term6 = xor i32 %term5, %x6
  %term7 = add i32 %term6, %x7
  %u0 = add i32 %r0, %term7
  %u1 = xor i32 %r1, %term7
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !22
exit:
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %u0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %u1, ptr %o1, align 4
  ret void
bypass:
  %b0 = getelementptr i32, ptr %out, i64 0
  store i32 17, ptr %b0, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  ret void
}

define void @interleave8_members(ptr readonly %a, ptr %out, i64 %n) !dbg !23 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !24
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [23, %preheader], [%u1, %loop]
  %r2 = phi i32 [29, %preheader], [%u2, %loop]
  %r3 = phi i32 [35, %preheader], [%u3, %loop]
  %r4 = phi i32 [41, %preheader], [%u4, %loop]
  %r5 = phi i32 [47, %preheader], [%u5, %loop]
  %r6 = phi i32 [53, %preheader], [%u6, %loop]
  %r7 = phi i32 [59, %preheader], [%u7, %loop]
  %r8 = phi i32 [65, %preheader], [%u8, %loop]
  %base = mul nuw i64 %i, 8
  %idx7 = add nuw i64 %base, 7
  %p7 = getelementptr i32, ptr %a, i64 %idx7
  %x7 = load i32, ptr %p7, align 4
  %p0 = getelementptr i32, ptr %a, i64 %base
  %x0 = load i32, ptr %p0, align 4
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr i32, ptr %a, i64 %idx1
  %x1 = load i32, ptr %p1, align 4
  %idx2 = add nuw i64 %base, 2
  %p2 = getelementptr i32, ptr %a, i64 %idx2
  %x2 = load i32, ptr %p2, align 4
  %idx3 = add nuw i64 %base, 3
  %p3 = getelementptr i32, ptr %a, i64 %idx3
  %x3 = load i32, ptr %p3, align 4
  %idx4 = add nuw i64 %base, 4
  %p4 = getelementptr i32, ptr %a, i64 %idx4
  %x4 = load i32, ptr %p4, align 4
  %idx5 = add nuw i64 %base, 5
  %p5 = getelementptr i32, ptr %a, i64 %idx5
  %x5 = load i32, ptr %p5, align 4
  %idx6 = add nuw i64 %base, 6
  %p6 = getelementptr i32, ptr %a, i64 %idx6
  %x6 = load i32, ptr %p6, align 4
  %u0 = add i32 %r0, %x0
  %u1 = xor i32 %r1, %x1
  %u2 = add i32 %r2, %x2
  %u3 = xor i32 %r3, %x3
  %u4 = add i32 %r4, %x4
  %u5 = xor i32 %r5, %x5
  %u6 = add i32 %r6, %x6
  %u7 = xor i32 %r7, %x7
  %u8 = add i32 %r8, %x7
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !24
exit:
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %u0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %u1, ptr %o1, align 4
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %u2, ptr %o2, align 4
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %u3, ptr %o3, align 4
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %u4, ptr %o4, align 4
  %o5 = getelementptr i32, ptr %out, i64 5
  store i32 %u5, ptr %o5, align 4
  %o6 = getelementptr i32, ptr %out, i64 6
  store i32 %u6, ptr %o6, align 4
  %o7 = getelementptr i32, ptr %out, i64 7
  store i32 %u7, ptr %o7, align 4
  %o8 = getelementptr i32, ptr %out, i64 8
  store i32 %u8, ptr %o8, align 4
  ret void
bypass:
  %b0 = getelementptr i32, ptr %out, i64 0
  store i32 17, ptr %b0, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  %b2 = getelementptr i32, ptr %out, i64 2
  store i32 29, ptr %b2, align 4
  %b3 = getelementptr i32, ptr %out, i64 3
  store i32 35, ptr %b3, align 4
  %b4 = getelementptr i32, ptr %out, i64 4
  store i32 41, ptr %b4, align 4
  %b5 = getelementptr i32, ptr %out, i64 5
  store i32 47, ptr %b5, align 4
  %b6 = getelementptr i32, ptr %out, i64 6
  store i32 53, ptr %b6, align 4
  %b7 = getelementptr i32, ptr %out, i64 7
  store i32 59, ptr %b7, align 4
  %b8 = getelementptr i32, ptr %out, i64 8
  store i32 65, ptr %b8, align 4
  ret void
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2}
!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "interleave-wide.c", directory: "/")
!2 = !{i32 2, !"Debug Info Version", i32 3}
!3 = !DISubroutineType(types: !4)
!4 = !{null}
!5 = distinct !DISubprogram(name: "interleave4", scope: !1, file: !1, line: 10, type: !3, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!6 = !DILocation(line: 10, column: 5, scope: !5)
!7 = distinct !DISubprogram(name: "interleave4_members", scope: !1, file: !1, line: 30, type: !3, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!8 = !DILocation(line: 30, column: 5, scope: !7)
!9 = distinct !DISubprogram(name: "interleave5", scope: !1, file: !1, line: 50, type: !3, scopeLine: 50, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!10 = !DILocation(line: 50, column: 5, scope: !9)
!11 = distinct !DISubprogram(name: "interleave5_members", scope: !1, file: !1, line: 70, type: !3, scopeLine: 70, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!12 = !DILocation(line: 70, column: 5, scope: !11)
!13 = distinct !DISubprogram(name: "interleave6", scope: !1, file: !1, line: 90, type: !3, scopeLine: 90, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!14 = !DILocation(line: 90, column: 5, scope: !13)
!15 = distinct !DISubprogram(name: "interleave6_members", scope: !1, file: !1, line: 110, type: !3, scopeLine: 110, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!16 = !DILocation(line: 110, column: 5, scope: !15)
!17 = distinct !DISubprogram(name: "interleave7", scope: !1, file: !1, line: 130, type: !3, scopeLine: 130, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!18 = !DILocation(line: 130, column: 5, scope: !17)
!19 = distinct !DISubprogram(name: "interleave7_members", scope: !1, file: !1, line: 150, type: !3, scopeLine: 150, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!20 = !DILocation(line: 150, column: 5, scope: !19)
!21 = distinct !DISubprogram(name: "interleave8", scope: !1, file: !1, line: 170, type: !3, scopeLine: 170, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!22 = !DILocation(line: 170, column: 5, scope: !21)
!23 = distinct !DISubprogram(name: "interleave8_members", scope: !1, file: !1, line: 190, type: !3, scopeLine: 190, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!24 = !DILocation(line: 190, column: 5, scope: !23)
