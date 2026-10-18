; RUN: opt -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -force-vector-interleave=1 -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false \
; RUN:   -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -vplan-reduction-fission-force-producer-vf=4 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=4 -S %s | FileCheck %s
; RUN: sed 's/> noundef/>/' %s | opt -passes=loop-vectorize -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -vplan-reduction-fission-force-producer-vf=4 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=4 -S | FileCheck %s --check-prefix=SAFE
; SAFE: vector.fission.producer.body:
; SAFE: @vecfoo(
; SAFE: vector.fission.accumulator.body:
;
; Fission must validate the actual variant, not just its scalar function: passing
; inactive poison lanes to a noundef parameter introduces immediate UB.
; CHECK-LABEL: define void @call_variant(
; CHECK-NOT: fission
; CHECK: call <vscale x 4 x i32> @vecfoo(
; CHECK-NOT: fission
; CHECK: ret void

define void @call_variant(ptr noalias readonly %a, ptr noalias %out) {
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
  %r8 = phi i32 [ 0, %entry ], [ %n8, %loop ]
  %r9 = phi i32 [ 0, %entry ], [ %n9, %loop ]
  %r10 = phi i32 [ 0, %entry ], [ %n10, %loop ]
  %r11 = phi i32 [ 0, %entry ], [ %n11, %loop ]
  %r12 = phi i32 [ 0, %entry ], [ %n12, %loop ]
  %r13 = phi i32 [ 0, %entry ], [ %n13, %loop ]
  %r14 = phi i32 [ 0, %entry ], [ %n14, %loop ]
  %r15 = phi i32 [ 0, %entry ], [ %n15, %loop ]
  %r16 = phi i32 [ 0, %entry ], [ %n16, %loop ]
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %c1 = mul i32 %x, 3
  %c2 = add i32 %c1, 7
  %c3 = xor i32 %c2, 11
  %c4 = mul i32 %c3, 13
  %c5 = call i32 @foo(i32 %c4) #1
  %t0 = add i32 %r0, %c5
  %n0 = add i32 %t0, %x
  %n1 = add i32 %r1, %c5
  %n2 = add i32 %r2, %c5
  %n3 = add i32 %r3, %c5
  %n4 = add i32 %r4, %c5
  %n5 = add i32 %r5, %c5
  %n6 = add i32 %r6, %c5
  %n7 = add i32 %r7, %c5
  %n8 = add i32 %r8, %c5
  %n9 = add i32 %r9, %c5
  %n10 = add i32 %r10, %c5
  %n11 = add i32 %r11, %c5
  %n12 = add i32 %r12, %c5
  %n13 = add i32 %r13, %c5
  %n14 = add i32 %r14, %c5
  %n15 = add i32 %r15, %c5
  %n16 = add i32 %r16, %c5
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
  %o8 = getelementptr i32, ptr %out, i64 8
  store i32 %n8, ptr %o8
  %o9 = getelementptr i32, ptr %out, i64 9
  store i32 %n9, ptr %o9
  %o10 = getelementptr i32, ptr %out, i64 10
  store i32 %n10, ptr %o10
  %o11 = getelementptr i32, ptr %out, i64 11
  store i32 %n11, ptr %o11
  %o12 = getelementptr i32, ptr %out, i64 12
  store i32 %n12, ptr %o12
  %o13 = getelementptr i32, ptr %out, i64 13
  store i32 %n13, ptr %o13
  %o14 = getelementptr i32, ptr %out, i64 14
  store i32 %n14, ptr %o14
  %o15 = getelementptr i32, ptr %out, i64 15
  store i32 %n15, ptr %o15
  %o16 = getelementptr i32, ptr %out, i64 16
  store i32 %n16, ptr %o16
  ret void
}

declare i32 @llvm.abs.i32(i32, i1 immarg)
declare i32 @llvm.umax.i32(i32, i32)

declare i32 @foo(i32) nounwind willreturn speculatable memory(none)
declare <vscale x 4 x i32> @vecfoo(<vscale x 4 x i32> noundef) nounwind willreturn speculatable memory(none)
attributes #1 = { "vector-function-abi-variant"="_ZGVrNxv_foo(vecfoo)" }
