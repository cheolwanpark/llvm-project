; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -vplan-reduction-fission-force-producer-vf=16 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=2 -S %s -o %t
; RUN: FileCheck %s < %t
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t -o /dev/null

; RUN: opt -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -force-vector-interleave=1 -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=8192 -S %s | FileCheck %s
; RUN: opt -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -force-vector-interleave=1 -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=8191 -S %s | FileCheck %s --check-prefix=REJECT
; RUN: sed 's/icmp ule i64 %n, 1024/icmp ule i64 %n, -1/' %s | opt -passes=loop-vectorize -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false \
; RUN:   -vplan-reduction-fission-min-chain-depth=4 -S | FileCheck %s --check-prefix=REJECT
; REJECT-LABEL: define void @bounded(
; REJECT-NOT: fission
; REJECT: ret void

; The entry guard remains in front of all four stages. Capacity is 1024,
; while both vector bounds and both scalar exits use the same dynamic N.
; CHECK-LABEL: define void @bounded(
; CHECK: alloca [1024 x i32]
; CHECK: br i1 %enter, label %preheader, label %bypass
; CHECK: [[PN:%.*]] = sub i64 %n,
; CHECK: vector.fission.producer.body:
; CHECK: scalar.fission.producer.body:
; CHECK: icmp eq i64 {{.*}}, %n
; CHECK: [[AN:%.*]] = sub i64 %n,
; CHECK: vector.fission.accumulator.body:
; CHECK: scalar.fission.accumulator.body:
; CHECK: icmp eq i64 {{.*}}, %n
; CHECK: bypass:

define void @bounded(ptr noalias readonly %a, ptr noalias %out, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 1024
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  %base = getelementptr i32, ptr %a, i64 1
  br label %loop
loop:
  %iv = phi i64 [ 0, %preheader ], [ %next, %loop ]
  %r0 = phi i32 [ 0, %preheader ], [ %n0, %loop ]
  %r1 = phi i32 [ 0, %preheader ], [ %n1, %loop ]
  %r2 = phi i32 [ 0, %preheader ], [ %n2, %loop ]
  %r3 = phi i32 [ -1, %preheader ], [ %n3, %loop ]
  %r4 = phi i32 [ 1, %preheader ], [ %n4, %loop ]
  %r5 = phi i32 [ 0, %preheader ], [ %n5, %loop ]
  %r6 = phi i32 [ 0, %preheader ], [ %n6, %loop ]
  %r7 = phi i32 [ 0, %preheader ], [ %n7, %loop ]
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %c1 = mul i32 %x, 3
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
  %done = icmp eq i64 %next, %n
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
bypass:
  ret void
}

declare i32 @llvm.abs.i32(i32, i1 immarg)
declare i32 @llvm.umax.i32(i32, i32)
