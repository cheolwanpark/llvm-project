; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -S %s | FileCheck %s
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-allow-fp-reordering \
; RUN:   -S %s | FileCheck %s
;
; Export-only poison is forwarded as SSA through PHIs, without a new store,
; freeze, branch condition or other consuming operation. %observe=false keeps
; this originally defined even when %shift is out of range. This property is
; checked structurally; the mixed-type export matrix is separately executed.
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

; CHECK-LABEL: define i32 @export_possible_poison(
; CHECK: alloca [65 x i32]
; CHECK-NOT: alloca
; CHECK: loop:
; CHECK: %value = shl i32 %x, %shift
; CHECK-NOT: store i32 %value
; CHECK: scalar.fission.consumer.ph:
; CHECK: %value.fission.export = phi i32 [ %value, %loop ]
; CHECK-NOT: freeze
; CHECK-NOT: store i32 %value
; CHECK: producer.exit:
; CHECK: %last = phi i32 [ %value.fission.export, %scalar.fission.consumer.body ]
; CHECK: exit:
; CHECK: %observed = phi i32 [ -9, %entry ], [ %last, %producer.exit ]
; CHECK: %result = select i1 %observe, i32 %observed, i32 %sum.out
; CHECK: ret i32 %result
define i32 @export_possible_poison(i32 %x, i32 %shift, i64 %n, i1 %observe) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  %limit = add nuw nsw i64 %n, 7
  br label %loop
loop:
  %iv = phi i64 [7, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %c = call i32 @scalar_helper(i32 %x)
  %value = shl i32 %x, %shift
  %update = add i32 %sum, %c
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %limit
  br i1 %done, label %producer.exit, label %loop
producer.exit:
  %last = phi i32 [%value, %loop]
  %reduced = phi i32 [%update, %loop]
  br label %exit
exit:
  %observed = phi i32 [-9, %entry], [%last, %producer.exit]
  %sum.out = phi i32 [17, %entry], [%reduced, %producer.exit]
  %result = select i1 %observe, i32 %observed, i32 %sum.out
  ret i32 %result
}
