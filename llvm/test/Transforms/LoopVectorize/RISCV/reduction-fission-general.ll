; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -tail-folding-policy=must-fold-tail -S %s \
; RUN:   | FileCheck %s
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-min-chain-depth=4 -S %s \
; RUN:   | FileCheck %s
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-min-chain-depth=4 -S %s \
; RUN:   | llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs -o /dev/null
; RUN: opt -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -force-vector-interleave=1 -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -vplan-reduction-fission-force-producer-vf=16 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=2 -S %s -o %t
; RUN: FileCheck %s --check-prefix=WIDE < %t
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t -o /dev/null
;
; The exploration bound is relative to target register/data width, not the
; smallest VF in a plan (which can be a fractional register for i32).
; WIDE: vector.fission.producer.body:
; WIDE-NOT: @llvm.stepvector
; WIDE: store <vscale x 16 x i32>
; WIDE: vector.fission.accumulator.body:
; WIDE: load <vscale x 2 x i32>
;
; No operator-specific recurrence rewriting: preserve the multi-add, bitwise,
; min/max updates, with a shared producer using scalar-immarg and
; ordinary elementwise intrinsics. Odd TC tests scalar stage remainders.
; CHECK-LABEL: define void @general(
; CHECK: fission.scratch = alloca [257 x i32]
; CHECK: vector.fission.producer.body:
; CHECK: call <vscale x {{[0-9]+}} x i32> @llvm.abs.
; CHECK: store <vscale x
; CHECK: vector.fission.accumulator.body:
; CHECK: load <vscale x {{[0-9]+}} x i32>
; CHECK: add <vscale x
; CHECK: add <vscale x
; CHECK: xor <vscale x
; CHECK: or <vscale x
; CHECK: and <vscale x
; CHECK: @llvm.umax.
; CHECK: @llvm.vector.reduce.xor.
; CHECK: @llvm.vector.reduce.or.
; CHECK: @llvm.vector.reduce.and.
; CHECK: @llvm.vector.reduce.umax.

define void @general(ptr noalias readonly %a, ptr noalias %out) {
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
