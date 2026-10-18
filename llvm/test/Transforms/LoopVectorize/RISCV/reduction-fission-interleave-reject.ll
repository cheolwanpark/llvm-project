; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -S %s -o %t
; RUN: FileCheck %s --implicit-check-not=vector.fission --implicit-check-not=fission.scratch < %t
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t -o /dev/null
; RUN: opt -enable-scalar-reduction-fission=false -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -tail-folding-policy=dont-fold-tail -enable-vplan-reduction-fission -S %s | FileCheck %s \
; RUN:   --implicit-check-not=vector.fission --implicit-check-not=fission.scratch
;
; Gaps, reverse groups and interleaved stores need separate implementations.
; The final case has a real distance-one dependence through the original input.
; No restrict/metadata assumption may hide it. Unit coverage also directly
; rejects data-predicated, volatile and atomic group recipes.

; CHECK-LABEL: define void @interleave_gap(
; CHECK: ret void
define void @interleave_gap(ptr noalias readonly %a, ptr noalias %out, i64 %n) {
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
  %idx2 = add nuw i64 %base, 2
  %p2 = getelementptr i32, ptr %a, i64 %idx2
  %x2 = load i32, ptr %p2, align 4
  %scaled = mul i32 %x0, 3
  %shared = xor i32 %scaled, %x0
  %pair = sub i32 %shared, %x0
  %term = add i32 %pair, %x2
  %update = add i32 %sum, %term
  %updated.bits = xor i32 %bits, %term
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

; CHECK-LABEL: define void @interleave_reverse(
; CHECK: ret void
define void @interleave_reverse(ptr noalias readonly %a, ptr noalias %out, i64 %n) {
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
  %reverse = sub nuw i64 64, %i
  %base = mul nuw i64 %reverse, 2
  %p0 = getelementptr i32, ptr %a, i64 %base
  %x0 = load i32, ptr %p0, align 4
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr i32, ptr %a, i64 %idx1
  %x1 = load i32, ptr %p1, align 4
  %scaled = mul i32 %x0, 3
  %shared = xor i32 %scaled, %x0
  %pair = sub i32 %shared, %x1
  %term = mul i32 %pair, 7
  %update = add i32 %sum, %term
  %updated.bits = xor i32 %bits, %term
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

; CHECK-LABEL: define void @interleave_store(
; CHECK: ret void
define void @interleave_store(ptr noalias readonly %a, ptr noalias %out, i64 %n, ptr noalias %dst) {
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
  %scaled = mul i32 %x0, 3
  %shared = xor i32 %scaled, %x0
  %pair = sub i32 %shared, %x1
  %term = mul i32 %pair, 7
  %update = add i32 %sum, %term
  %updated.bits = xor i32 %bits, %term
  %d0 = getelementptr i32, ptr %dst, i64 %base
  %d1 = getelementptr i32, ptr %d0, i64 1
  store i32 %x0, ptr %d0, align 4
  store i32 %x1, ptr %d1, align 4
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

; CHECK-LABEL: define void @interleave_dependence(
; CHECK: ret void
define void @interleave_dependence(ptr noalias %a, ptr noalias %out, i64 %n) {
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
  %scaled = mul i32 %x0, 3
  %shared = xor i32 %scaled, %x0
  %pair = sub i32 %shared, %x1
  %term = mul i32 %pair, 7
  %update = add i32 %sum, %term
  %updated.bits = xor i32 %bits, %term
  %future = getelementptr i32, ptr %p0, i64 2
  store i32 %x0, ptr %future, align 4
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
