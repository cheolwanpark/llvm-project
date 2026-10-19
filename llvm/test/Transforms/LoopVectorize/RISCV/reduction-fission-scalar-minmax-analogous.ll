; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission -force-vector-width=1 -force-vector-interleave=0 -force-target-max-scalar-interleave=1 -scalable-vectorization=off -S %s | FileCheck %s
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission -force-vector-width=1 -force-vector-interleave=0 -force-target-max-scalar-interleave=1 -scalable-vectorization=off -vplan-reduction-fission-allow-fp-reordering -S %s | FileCheck %s
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission -force-vector-width=4 -force-vector-interleave=1 -scalable-vectorization=always -hints-allow-reordering=false -tail-folding-policy=dont-fold-tail -enable-epilogue-vectorization=false -S %s -o %t
; RUN: FileCheck %s --check-prefix=VECTOR < %t
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t -o /dev/null
;
; Analogous i16 updates use all four operations. %local is an unsupported
; ordinary call recurrence: when an independent min/max can move it remains
; producer-local, as does a recognized min/max observed by the producer.
declare i16 @llvm.smin.i16(i16, i16)
declare i16 @llvm.smax.i16(i16, i16)
declare i16 @llvm.umin.i16(i16, i16)
declare i16 @llvm.umax.i16(i16, i16)
declare i16 @other_min(i16, i16) nounwind willreturn speculatable memory(none)

; CHECK-LABEL: define void @minmax_retained(
; CHECK-COUNT-1: alloca [65 x i16]
; CHECK-NOT: alloca
; CHECK: %local = phi i16
; CHECK: %observed = phi i16
; CHECK: %local.next = call i16 @other_min(i16 %local, i16 %x)
; CHECK: %observed.next = call i16 @llvm.smax.i16(i16 %observed, i16 %x)
; CHECK: store i16 %observed.next, ptr %p
; CHECK: scalar.fission.consumer.body:
; CHECK: %u0.consume = call i16 @llvm.smin.i16(i16 %r0.consume,
; CHECK: %u1.consume = call i16 @llvm.smax.i16(i16 {{%[-a-zA-Z$._0-9]+}}, i16 %r1.consume)
; CHECK: %u2.consume = call i16 @llvm.umin.i16(i16 %r2.consume,
; CHECK: %u3.consume = call i16 @llvm.umax.i16(i16 {{%[-a-zA-Z$._0-9]+}}, i16 %r3.consume)
; CHECK: %u4.consume = call i16 @llvm.smin.i16(i16 {{%[-a-zA-Z$._0-9]+}}, i16 %r4.consume)
; CHECK: %u5.consume = call i16 @llvm.smax.i16(i16 %r5.consume,
; CHECK: %u6.consume = call i16 @llvm.umin.i16(i16 {{%[-a-zA-Z$._0-9]+}}, i16 %r6.consume)
; CHECK: %u7.consume = call i16 @llvm.umax.i16(i16 %r7.consume,
; CHECK: ret void
; VECTOR-LABEL: define void @minmax_retained(
; VECTOR: scalar.fission.consumer.ph:
; VECTOR: vector.body:
; VECTOR: call i16 @llvm.vector.reduce.smin.nxv4i16(
; VECTOR: call i16 @llvm.vector.reduce.smax.nxv4i16(
; VECTOR: call i16 @llvm.vector.reduce.umin.nxv4i16(
; VECTOR: call i16 @llvm.vector.reduce.umax.nxv4i16(
; VECTOR: call i16 @llvm.vector.reduce.smin.nxv4i16(
; VECTOR: call i16 @llvm.vector.reduce.smax.nxv4i16(
; VECTOR: call i16 @llvm.vector.reduce.umin.nxv4i16(
; VECTOR: call i16 @llvm.vector.reduce.umax.nxv4i16(
; VECTOR: ret void
define void @minmax_retained(ptr %a, ptr %out, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i64 [ 0, %preheader ], [ %next, %loop ]
  %local = phi i16 [ 37, %preheader ], [ %local.next, %loop ]
  %observed = phi i16 [ -19, %preheader ], [ %observed.next, %loop ]
  %r0 = phi i16 [ 123, %preheader ], [ %u0, %loop ]
  %r1 = phi i16 [ -321, %preheader ], [ %u1, %loop ]
  %r2 = phi i16 [ 456, %preheader ], [ %u2, %loop ]
  %r3 = phi i16 [ 789, %preheader ], [ %u3, %loop ]
  %r4 = phi i16 [ -123, %preheader ], [ %u4, %loop ]
  %r5 = phi i16 [ 321, %preheader ], [ %u5, %loop ]
  %r6 = phi i16 [ -456, %preheader ], [ %u6, %loop ]
  %r7 = phi i16 [ -789, %preheader ], [ %u7, %loop ]
  %p = getelementptr i16, ptr %a, i64 %iv
  %x = load i16, ptr %p, align 2
  %local.next = call i16 @other_min(i16 %local, i16 %x)
  %observed.next = call i16 @llvm.smax.i16(i16 %observed, i16 %x)
  store i16 %observed.next, ptr %p, align 2
  %c = xor i16 %local, %x
  %u0 = call i16 @llvm.smin.i16(i16 %r0, i16 %c)
  %u1 = call i16 @llvm.smax.i16(i16 %c, i16 %r1)
  %u2 = call i16 @llvm.umin.i16(i16 %r2, i16 %c)
  %u3 = call i16 @llvm.umax.i16(i16 %c, i16 %r3)
  %u4 = call i16 @llvm.smin.i16(i16 %c, i16 %r4)
  %u5 = call i16 @llvm.smax.i16(i16 %r5, i16 %c)
  %u6 = call i16 @llvm.umin.i16(i16 %c, i16 %r6)
  %u7 = call i16 @llvm.umax.i16(i16 %r7, i16 %c)
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %producer.exit, label %loop
producer.exit:
  %v0 = phi i16 [ %u0, %loop ]
  %v1 = phi i16 [ %u1, %loop ]
  %v2 = phi i16 [ %u2, %loop ]
  %v3 = phi i16 [ %u3, %loop ]
  %v4 = phi i16 [ %local.next, %loop ]
  %v5 = phi i16 [ %u4, %loop ]
  %v6 = phi i16 [ %u5, %loop ]
  %v7 = phi i16 [ %u6, %loop ]
  %v8 = phi i16 [ %u7, %loop ]
  %p1 = getelementptr i16, ptr %out, i64 1
  %p2 = getelementptr i16, ptr %out, i64 2
  %p3 = getelementptr i16, ptr %out, i64 3
  %p4 = getelementptr i16, ptr %out, i64 4
  %p5 = getelementptr i16, ptr %out, i64 5
  %p6 = getelementptr i16, ptr %out, i64 6
  %p7 = getelementptr i16, ptr %out, i64 7
  %p8 = getelementptr i16, ptr %out, i64 8
  store i16 %v0, ptr %out, align 2
  store i16 %v1, ptr %p1, align 2
  store i16 %v2, ptr %p2, align 2
  store i16 %v3, ptr %p3, align 2
  store i16 %v4, ptr %p4, align 2
  store i16 %v5, ptr %p5, align 2
  store i16 %v6, ptr %p6, align 2
  store i16 %v7, ptr %p7, align 2
  store i16 %v8, ptr %p8, align 2
  br label %exit
exit:
  ret void
}
