; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @interleave_reread(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @interleave3_reread(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
define void @interleave_reread(ptr readonly %a, ptr %out, i64 %n) {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %bits = phi i32 [23, %preheader], [%updated.bits, %loop]
  %base = mul nuw i64 %i, 2
  %p0 = getelementptr i32, ptr %a, i64 %base
  %x0 = load i32, ptr %p0, align 4
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr i32, ptr %a, i64 %idx1
  %x1 = load i32, ptr %p1, align 4
  %c0 = mul i32 %x0, 3
  %c1 = xor i32 %c0, 5
  %c2 = mul i32 %c1, 7
  %c3 = xor i32 %c2, 9
  %c4 = mul i32 %c3, 11
  %c5 = xor i32 %c4, 13
  %c6 = mul i32 %c5, 15
  %c7 = xor i32 %c6, 17
  %c8 = mul i32 %c7, 19
  %c9 = xor i32 %c8, 21
  %term = mul i32 %c9, 23
  %update = add i32 %sum, %term
  %updated.bits = xor i32 %bits, %x1
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  store i32 %update, ptr %out, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %updated.bits, ptr %o1, align 4
  ret void
bypass:
  store i32 17, ptr %out, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  ret void
}

define void @interleave3_reread(ptr readonly %a, ptr %out, i64 %n) {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %bits = phi i32 [23, %preheader], [%updated.bits, %loop]
  %base = mul nuw i64 %i, 3
  %p0 = getelementptr i32, ptr %a, i64 %base
  %x0 = load i32, ptr %p0, align 4
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr i32, ptr %a, i64 %idx1
  %x1 = load i32, ptr %p1, align 4
  %idx2 = add nuw i64 %base, 2
  %p2 = getelementptr i32, ptr %a, i64 %idx2
  %x2 = load i32, ptr %p2, align 4
  %c0 = mul i32 %x0, 3
  %c1 = xor i32 %c0, 5
  %c2 = mul i32 %c1, 7
  %c3 = xor i32 %c2, 9
  %c4 = mul i32 %c3, 11
  %c5 = xor i32 %c4, 13
  %c6 = mul i32 %c5, 15
  %c7 = xor i32 %c6, 17
  %c8 = mul i32 %c7, 19
  %c9 = xor i32 %c8, 21
  %term = mul i32 %c9, 23
  %short = add i32 %x1, %x2
  %update = add i32 %sum, %term
  %updated.bits = xor i32 %bits, %short
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  store i32 %update, ptr %out, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %updated.bits, ptr %o1, align 4
  ret void
bypass:
  store i32 17, ptr %out, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  ret void
}
