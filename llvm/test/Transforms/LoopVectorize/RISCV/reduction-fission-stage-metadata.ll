; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -tail-folding-policy=dont-fold-tail -enable-epilogue-vectorization=false -enable-vplan-reduction-fission -S %s -o %t
; RUN: FileCheck %s --implicit-check-not=fission.scratch < %t
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t -o /dev/null
; RUN: opt -passes='loop-vectorize,loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -tail-folding-policy=dont-fold-tail -enable-epilogue-vectorization=false -enable-vplan-reduction-fission -vplan-reduction-fission-allow-fp-reordering -pass-remarks=vplan-reduction-fission -S %s -o %t.repeat 2> %t.remarks
; RUN: FileCheck %s --implicit-check-not=fission.scratch < %t.repeat
; RUN: FileCheck %s --check-prefix=REMARK --implicit-check-not='split ' < %t.remarks
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.repeat -o /dev/null
;
; Model already emitted stages with explicit vectorize.followup_all. Ordinary
; LV must still vectorize them and copy their provenance to the vector and
; remainder loops even though the follow-up ID replaces the original ID.
; Otherwise a later LV could recursively split the consumer. All three tags
; must remain reachable in printed metadata after one and three LV passes.
; REMARK-DAG: scalar-IR fission producer VF vscale x 4
; REMARK-DAG: scalar-IR fission consumer VF vscale x 4
;
; CHECK-LABEL: define i32 @marked_vplan(
; CHECK: vector.body:
; CHECK: @llvm.vector.reduce.add.nxv4i32
; CHECK: ret i32
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

; CHECK-LABEL: define i32 @marked_producer(
; CHECK: vector.body:
; CHECK: @llvm.vector.reduce.add.nxv4i32
; CHECK: ret i32
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

; CHECK-LABEL: define i32 @marked_consumer(
; CHECK: vector.body:
; CHECK: @llvm.vector.reduce.add.nxv4i32
; CHECK: ret i32
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

; CHECK-DAG: !{!"llvm.loop.reduction_fission.stage"}
; CHECK-DAG: !{!"llvm.loop.reduction_fission.producer"}
; CHECK-DAG: !{!"llvm.loop.reduction_fission.consumer"}

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
