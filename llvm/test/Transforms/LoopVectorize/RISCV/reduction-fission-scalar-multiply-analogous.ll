; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission -force-vector-width=1 -force-vector-interleave=0 -force-target-max-scalar-interleave=1 -scalable-vectorization=off -S %s | FileCheck %s
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission -force-vector-width=1 -force-vector-interleave=0 -force-target-max-scalar-interleave=1 -scalable-vectorization=off -vplan-reduction-fission-allow-fp-reordering -S %s | FileCheck %s
;
; Exact former bitwise_unsupported body: multiplication is now admitted.
; CHECK-LABEL: define i32 @bitwise_unsupported(
; CHECK: alloca [65 x i32]
; CHECK: scalar.fission.consumer.body:
; CHECK: %sum.consume = phi i32 [ 19,
; CHECK: %update.consume = mul i32 %sum.consume,
; CHECK: ret i32
define i32 @bitwise_unsupported(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [ 0, %preheader ], [ %next, %loop ]
  %sum = phi i32 [ 19, %preheader ], [ %update, %loop ]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %update = mul i32 %sum, %x
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %update, %loop ]
  ret i32 %result
bypass:
  ret i32 19
}


; Exact former compact non-add body; skip-zero iterations have no update.
; CHECK-LABEL: define i32 @reject_compact_non_add(
; CHECK: alloca [65 x i32]
; CHECK: scalar.fission.consumer.guard:
; CHECK: scalar.fission.consumer.body:
; CHECK: %update.consume = mul i32 %sum.consume,
; CHECK: ret i32
define i32 @reject_compact_non_add(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch
left:
  %update = mul i32 %sum, %x
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %loop]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %merged
bypass:
  ret i32 19
}
