; RUN: opt -mtriple=riscv64 -mcpu=xiangshan-kunminghu -passes='default<O3>' -vplan-pipeline=prepare %s -o %t.bc
; RUN: opt -mtriple=riscv64 -mcpu=xiangshan-kunminghu -passes='default<O3>' -vplan-pipeline=resume -vplan-ra-run-id=test -vplan-probe-candidate=stream:0:2:s1 -vplan-candidates-output=%t.json %t.bc -S -o %t.ll
; RUN: FileCheck %s < %t.ll
; RUN: llc -mtriple=riscv64 -mcpu=xiangshan-kunminghu -vplan-ra-run-id=test -vplan-probe-candidate=stream:0:2:s1 -vplan-analytics-output=%t.analytics.json -stop-after=riscv-vplan-analytics %t.ll -o /dev/null
; RUN: FileCheck %s --check-prefix=ANALYTICS < %t.analytics.json
;
; The vectorizer records an IV step of vscale for s1. Post-vectorizer
; optimization folds it to 2. Width is already 2 and must stay 2, not 4.
; CHECK: %index.next = add nuw i64 %index, 2
; CHECK: "vplan.ra.iteration-mapping"="1"
; CHECK-SAME: "vplan.ra.width"="2"
; ANALYTICS-DAG: "Error":""
; ANALYTICS-DAG: "Width":2
; ANALYTICS-DAG: "ScalableVF":true
; ANALYTICS-DAG: "VF":1,

define void @stream(ptr noalias %a, ptr noalias %b, ptr noalias %c) #0 {
entry:
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %loop]
  %pa = getelementptr double, ptr %a, i64 %iv
  %pb = getelementptr double, ptr %b, i64 %iv
  %pc = getelementptr double, ptr %c, i64 %iv
  %a.val = load double, ptr %pa, align 8
  %b.val = load double, ptr %pb, align 8
  %sum = fadd double %a.val, %b.val
  store double %sum, ptr %pc, align 8
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, 1024
  br i1 %done, label %exit, label %loop, !llvm.loop !0
exit:
  ret void
}
attributes #0 = { vscale_range(2,2) }
!0 = distinct !{!0, !1, !2}
!1 = !{!"llvm.loop.unroll.disable"}
!2 = !{!"llvm.loop.interleave.count", i32 1}
