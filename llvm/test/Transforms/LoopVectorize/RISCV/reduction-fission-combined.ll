; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -vplan-reduction-fission-force-producer-vf=8 -vplan-reduction-fission-force-accumulator-vf=2 \
; RUN:   -S %s -o %t
; RUN: FileCheck %s < %t
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t -o /dev/null
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -vplan-reduction-fission-force-producer-vf=8 -vplan-reduction-fission-force-accumulator-vf=2 \
; RUN:   -vplan-reduction-fission-allow-fp-reordering -S %s -o %t.relaxed
; RUN: FileCheck %s --check-prefix=RELAXED < %t.relaxed
;
; Exercise all five extensions together. The execution helper compares this
; kernel's reductions, complete output arrays and surrounding canaries.
; CHECK-LABEL: define void @combined(
; CHECK: vector.fission.producer.body:
; CHECK: phi <vscale x 8 x i32>
; CHECK: scalar.fission.producer.body:
; CHECK: mul i32 %step,
; CHECK: vector.fission.accumulator.body:
; CHECK: store <vscale x 2 x i32>
; CHECK: call double @llvm.vector.reduce.fadd
; CHECK: scalar.fission.accumulator.body:
; CHECK: store i32
; CHECK: fadd double
; RELAXED-LABEL: define void @combined(
; RELAXED: vector.fission.producer.body:
; RELAXED: fmul <vscale x 8 x double>
; RELAXED: vector.fission.accumulator.body:
; RELAXED: fadd reassoc <vscale x 2 x double>
; RELAXED: scalar.fission.accumulator.body:
; RELAXED: fadd reassoc double

define void @combined(ptr noalias readonly %a, ptr noalias %out, i64 %n, ptr noalias %fp, double %start, ptr noalias readonly %fpinput, ptr noalias %dst, ptr noalias %dst2, i32 %step) {
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
  %sum = phi double [ %start, %preheader ], [ %sum.next, %loop ]
  %j = phi i32 [ 19, %preheader ], [ %j.next, %loop ]
  %j.next = add i32 %j, %step
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %c0 = add i32 %x, %j
  %c1 = mul i32 %c0, 3
  %c2 = add i32 %c1, 7
  %c3 = xor i32 %c2, 11
  %c4 = mul i32 %c3, 13
  %c5 = call i32 @llvm.abs.i32(i32 %c4, i1 false)
  %fpp = getelementptr inbounds double, ptr %fpinput, i64 %iv
  %fx = load double, ptr %fpp, align 8
  %fm1 = fmul double %fx, 2.0
  %fm2 = fmul double %fm1, 3.0
  %fm3 = fmul double %fm2, 4.0
  %contribution = fmul double %fm3, 5.0
  %q = getelementptr inbounds i32, ptr %dst, i64 %iv
  store i32 %c5, ptr %q, align 4
  %q2 = getelementptr inbounds i32, ptr %dst2, i64 %iv
  store i32 %j, ptr %q2, align 4
  %sum.next = fadd double %sum, %contribution
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
  store double %sum.next, ptr %fp
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
