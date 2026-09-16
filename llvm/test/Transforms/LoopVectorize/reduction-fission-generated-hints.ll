; RUN: opt %s -passes=loop-vectorize -force-vector-width=2 -force-vector-interleave=4 -scalable-vectorization=off -force-target-supports-scalable-vectors -pass-remarks=loop-vectorize -S 2>&1 | FileCheck %s
; RUN: opt %s -passes=loop-vectorize -force-vector-width=fission:2 -force-vector-interleave=4 -scalable-vectorization=on -force-target-supports-scalable-vectors -pass-remarks=loop-vectorize -S 2>&1 | FileCheck %s

; Generated loops retain their own width, scalable choice and interleave count
; under global overrides. A fission request must not be applied recursively.
; CHECK-DAG: vectorized loop (vectorization width: 8, interleaved count: 1)
; CHECK-DAG: vectorized loop (vectorization width: vscale x 8, interleaved count: 1)

; CHECK-LABEL: define void @fixed_map(
; CHECK: store <8 x i32>
define void @fixed_map(ptr %a, i64 %n) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %loop
loop:
  %iv = phi i64 [ 0, %entry ], [ %next, %loop ]
  %p = getelementptr i32, ptr %a, i64 %iv
  store i32 42, ptr %p, align 4
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !llvm.loop !0
exit:
  ret void
}

; CHECK-LABEL: define void @scalable_reduction_loop_policy(
; CHECK: store <vscale x 8 x i32>
define void @scalable_reduction_loop_policy(ptr %a, i64 %n) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %loop
loop:
  %iv = phi i64 [ 0, %entry ], [ %next, %loop ]
  %p = getelementptr i32, ptr %a, i64 %iv
  store i32 42, ptr %p, align 4
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !llvm.loop !1
exit:
  ret void
}

!0 = distinct !{!0, !2, !3, !4, !5, !6}
!1 = distinct !{!1, !2, !3, !4, !5, !7}
!2 = !{!"llvm.loop.reduction.fission.generated"}
!3 = !{!"llvm.loop.vectorize.enable", i1 true}
!4 = !{!"llvm.loop.vectorize.width", i32 8}
!5 = !{!"llvm.loop.interleave.count", i32 1}
!6 = !{!"llvm.loop.vectorize.scalable.enable", i1 false}
!7 = !{!"llvm.loop.vectorize.scalable.enable", i1 true}
