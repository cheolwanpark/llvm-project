; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @marked_vplan(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @marked_producer(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @marked_consumer(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
define i32 @marked_vplan(ptr readonly %a) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %sum = phi i32 [17, %entry], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %update = add i32 %sum, %x
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, 65
  br i1 %done, label %exit, label %loop, !llvm.loop !0
exit:
  ret i32 %update
}

define i32 @marked_producer(ptr readonly %a) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %sum = phi i32 [17, %entry], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %update = add i32 %sum, %x
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, 65
  br i1 %done, label %exit, label %loop, !llvm.loop !1
exit:
  ret i32 %update
}

define i32 @marked_consumer(ptr readonly %a) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %sum = phi i32 [17, %entry], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %update = add i32 %sum, %x
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, 65
  br i1 %done, label %exit, label %loop, !llvm.loop !2
exit:
  ret i32 %update
}

!0 = distinct !{!0, !3, !6, !7, !9}
!1 = distinct !{!1, !4, !6, !7, !9}
!2 = distinct !{!2, !5, !6, !7, !9}
!3 = !{!"llvm.loop.reduction_fission.stage"}
!4 = !{!"llvm.loop.reduction_fission.producer"}
!5 = !{!"llvm.loop.reduction_fission.consumer"}
!6 = !{!"llvm.loop.vectorize.width", i32 4}
!7 = !{!"llvm.loop.vectorize.scalable.enable", i1 true}
!8 = !{!"llvm.loop.vectorize.enable", i1 true}
!9 = !{!"llvm.loop.vectorize.followup_all", !8}
