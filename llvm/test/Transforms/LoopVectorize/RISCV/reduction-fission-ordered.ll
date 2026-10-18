; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -vplan-reduction-fission-force-producer-vf=8 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=2 -S %s -o %t
; RUN: FileCheck %s < %t
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t -o /dev/null

; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t -o - | FileCheck %s --check-prefix=ASM
; RUN: opt -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false \
; RUN:   -vplan-reduction-fission-min-chain-depth=4 -tail-folding-policy=must-fold-tail \
; RUN:   -force-tail-folding-style=data -S %s | FileCheck %s
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v \
; RUN:   -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false \
; RUN:   -vplan-reduction-fission-min-chain-depth=4 -pass-remarks=vplan-reduction-fission \
; RUN:   -disable-output %s 2>&1 | FileCheck %s --check-prefix=REMARK
; REMARK: trip count bounded-runtime, scratch capacity 1024
; REMARK: reduction sum: ordered, reordering permission: IR
; ASM: vfredosum.vs

; Mixed integer and ordered FP sums exercise selection with scalar FP pressure.
; CHECK-LABEL: define void @ordered(
; CHECK: vector.fission.producer.body:
; CHECK: scalar.fission.producer.body:
; CHECK: vector.fission.accumulator.body:
; CHECK: phi double
; CHECK: call double @llvm.vector.reduce.fadd.{{.*}}(double {{%.*}}, <vscale x
; CHECK: scalar.fission.accumulator.body:
; CHECK: fadd double
; CHECK: vector.fission.done:

define void @ordered(ptr noalias readonly %a, ptr noalias %out, i64 %n, ptr noalias %fp, double %start) {
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
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %c1 = mul i32 %x, 3
  %c2 = add i32 %c1, 7
  %c3 = xor i32 %c2, 11
  %c4 = mul i32 %c3, 13
  %c5 = call i32 @llvm.abs.i32(i32 %c4, i1 false)
  %contribution = sitofp i32 %c5 to double
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
