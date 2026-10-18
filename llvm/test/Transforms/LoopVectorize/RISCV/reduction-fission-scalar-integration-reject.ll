; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=4 \
; RUN:   -pass-remarks-missed=vplan-reduction-fission -S %s -o %t 2> %t.remarks
; RUN: FileCheck %s --implicit-check-not=scalar.fission < %t
; RUN: FileCheck %s --check-prefix=REASON < %t.remarks
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=4 \
; RUN:   -vplan-reduction-fission-allow-fp-reordering -S %s -o %t.repeat
; RUN: FileCheck %s --implicit-check-not=scalar.fission < %t.repeat
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=260 \
; RUN:   -S %s | FileCheck %s --check-prefix=EXPORT
;
; Each control executes exactly 65 iterations. An affine endpoint, a current-IV
; equality operand, a swapped equality or a strict relational witness is not
; the canonical next-IV count consumed by N-base chunk scheduling. None may
; bypass the full-trip ceiling, even when one contribution fits. Live-out
; combinations are legal at sufficient capacity (see scalar-export-controls),
; but exports do not relax the full-trip scratch requirement here.
; REASON-COUNT-7: scalar-IR reduction fission rejected: scalar-scratch-limit

declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

; CHECK-LABEL: define i32 @oversized_offset(
; CHECK: ret i32
define i32 @oversized_offset(i32 %x) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i64 [7, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %c = call i32 @scalar_helper(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, 72
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
}

; CHECK-LABEL: define i32 @oversized_stride(
; CHECK: ret i32
define i32 @oversized_stride(i32 %x) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %c = call i32 @scalar_helper(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 2
  %done = icmp eq i64 %next, 130
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
}

; CHECK-LABEL: define i32 @oversized_current(
; CHECK: ret i32
define i32 @oversized_current(i32 %x) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %c = call i32 @scalar_helper(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %iv, 64
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
}

; CHECK-LABEL: define i32 @oversized_swapped(
; CHECK: ret i32
define i32 @oversized_swapped(i32 %x) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %c = call i32 @scalar_helper(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 65, %next
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
}

; CHECK-LABEL: define i32 @oversized_witness(
; CHECK: ret i32
define i32 @oversized_witness(i32 %x) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %c = call i32 @scalar_helper(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp ult i64 %next, 65
  br i1 %done, label %loop, label %exit
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
}

; CHECK-LABEL: define i64 @reject_export_integration_affine(
; CHECK: ret i64
; EXPORT-LABEL: define i64 @reject_export_integration_affine(
; EXPORT: alloca [65 x i32]
; EXPORT: scalar.fission.consumer.ph:
; EXPORT: %iv.fission.export = phi i64 [ %iv, %loop ]
; EXPORT: %[[FINAL_A:.*]] = phi i64 [ %iv.fission.export, %scalar.fission.consumer.body ]
; EXPORT: %observed = phi i64 [ 0, %entry ], [ %[[FINAL_A]], %{{.*}} ]
; EXPORT: ret i64
define i64 @reject_export_integration_affine(ptr readonly %a, ptr %out, i64 %n, i32 %start) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  %span = shl nuw i64 %n, 1
  %limit = add nuw i64 %span, 7
  br label %loop
loop:
  %iv = phi i64 [7, %preheader], [%next, %loop]
  %sum = phi i32 [%start, %preheader], [%update, %loop]
  %distance = sub nuw i64 %iv, 7
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %arg = xor i32 %x, 7
  %c = call i32 @scalar_helper(i32 %arg)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 2
  %done = icmp eq i64 %next, %limit
  br i1 %done, label %exit, label %loop
exit:
  %observed = phi i64 [0, %entry], [%iv, %loop]
  %result = phi i32 [%start, %entry], [%update, %loop]
  store i32 %result, ptr %out
  ret i64 %observed
}

; CHECK-LABEL: define i64 @reject_export_integration_cross_edge(
; CHECK: ret i64
; EXPORT-LABEL: define i64 @reject_export_integration_cross_edge(
; EXPORT: alloca [65 x i32]
; EXPORT: scalar.fission.consumer.ph:
; EXPORT: %iv.fission.export = phi i64 [ %iv, %latch ]
; EXPORT: %[[FINAL_C:.*]] = phi i64 [ %iv.fission.export, %scalar.fission.consumer.body ]
; EXPORT: %observed = phi i64 [ 0, %entry ], [ %[[FINAL_C]], %{{.*}} ]
; EXPORT: ret i64
define i64 @reject_export_integration_cross_edge(ptr readonly %a, ptr %out, i64 %n, i32 %start) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [%start, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = mul i32 %x, 3
  br label %right
right:
  %first = phi i32 [%lc, %left], [%x, %loop]
  %arg = xor i32 %first, 7
  %c = call i32 @scalar_helper(i32 %arg)
  br label %latch
latch:
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %observed = phi i64 [0, %entry], [%iv, %latch]
  %result = phi i32 [%start, %entry], [%update, %latch]
  store i32 %result, ptr %out
  ret i64 %observed
}
