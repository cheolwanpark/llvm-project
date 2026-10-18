; RUN: opt -enable-scalar-reduction-fission=false -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v,+m -force-vector-interleave=1 -enable-vplan-reduction-fission -vplan-reduction-fission-min-chain-depth=4 -S %s -o %t
; RUN: opt -enable-scalar-reduction-fission=false -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v,+m -force-vector-interleave=1 -enable-vplan-reduction-fission -vplan-reduction-fission-min-chain-depth=4 -vplan-reduction-fission-combine-add-contributions=false -S %s -o %t.old
; RUN: FileCheck %s --check-prefix=ORIGINAL < %t.old
; RUN: FileCheck %s < %t
; RUN: llc -mtriple=riscv64 -mattr=+v,+m -verify-machineinstrs %t -o /dev/null
; RUN: opt -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v,+m -force-vector-interleave=1 -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false -vplan-reduction-fission-min-chain-depth=4 -vplan-reduction-fission-force-producer-vf=8 -vplan-reduction-fission-force-accumulator-vf=8 -S %s | FileCheck %s --check-prefix=FORCED
;
; Combining six private terms increases estimated producer pressure. Explicit
; fission now accepts that legal cut, saving five scratch arrays at the selected
; pair. The uncombined option still exposes all nine original scratch values.
; CHECK-LABEL: define void @pressure_fallback(
; CHECK-COUNT-4: alloca [257 x i32]
; CHECK-NOT: alloca [257 x i32]
; CHECK: vector.fission.producer.body:
; CHECK: vector.fission.accumulator.body:
; ORIGINAL-LABEL: define void @pressure_fallback(
; ORIGINAL-COUNT-9: alloca [257 x i32]
; ORIGINAL-NOT: alloca [257 x i32]
; ORIGINAL: vector.fission.producer.body:
; ORIGINAL: vector.fission.accumulator.body:
; Explicit VFs retain the same scratch saving and all stage legality checks.
; FORCED-COUNT-4: alloca [257 x i32]
; FORCED-NOT: alloca [257 x i32]
; FORCED: vector.fission.producer.body:

define void @pressure_fallback(ptr noalias readonly %a, ptr noalias %out) {
entry:
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %loop]
  %r0 = phi i32 [0, %entry], [%n0, %loop]
  %r1 = phi i32 [0, %entry], [%n1, %loop]
  %r2 = phi i32 [0, %entry], [%n2, %loop]
  %r3 = phi i32 [0, %entry], [%n3, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %a0 = mul i32 %x, 3
  %b0 = xor i32 %a0, 7
  %c0 = add i32 %b0, 11
  %d0 = mul i32 %c0, 13
  %a1 = mul i32 %x, 7
  %b1 = xor i32 %a1, 8
  %c1 = add i32 %b1, 12
  %d1 = mul i32 %c1, 14
  %a2 = mul i32 %x, 11
  %b2 = xor i32 %a2, 9
  %c2 = add i32 %b2, 13
  %d2 = mul i32 %c2, 15
  %a3 = mul i32 %x, 15
  %b3 = xor i32 %a3, 10
  %c3 = add i32 %b3, 14
  %d3 = mul i32 %c3, 16
  %a4 = mul i32 %x, 19
  %b4 = xor i32 %a4, 11
  %c4 = add i32 %b4, 15
  %d4 = mul i32 %c4, 17
  %a5 = mul i32 %x, 23
  %b5 = xor i32 %a5, 12
  %c5 = add i32 %b5, 16
  %d5 = mul i32 %c5, 18
  %a6 = mul i32 %x, 27
  %b6 = xor i32 %a6, 13
  %c6 = add i32 %b6, 17
  %d6 = mul i32 %c6, 19
  %a7 = mul i32 %x, 31
  %b7 = xor i32 %a7, 14
  %c7 = add i32 %b7, 18
  %d7 = mul i32 %c7, 20
  %a8 = mul i32 %x, 35
  %b8 = xor i32 %a8, 15
  %c8 = add i32 %b8, 19
  %d8 = mul i32 %c8, 21
  %u0 = add i32 %r0, %d0
  %u1 = add i32 %u0, %d1
  %u2 = add i32 %u1, %d2
  %u3 = add i32 %u2, %d3
  %u4 = add i32 %u3, %d4
  %n0 = add i32 %u4, %d5
  %n1 = add i32 %r1, %d6
  %n2 = add i32 %r2, %d7
  %n3 = add i32 %r3, %d8
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, 257
  br i1 %done, label %exit, label %loop
exit:
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %n0, ptr %o0
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %n1, ptr %o1
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %n2, ptr %o2
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %n3, ptr %o3
  ret void
}
