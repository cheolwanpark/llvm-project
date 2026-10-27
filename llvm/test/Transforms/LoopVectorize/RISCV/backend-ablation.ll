; RUN: %python %S/Inputs/check-backend-ablation.py opt %s %t %S/backend-feedback-spills.ll
; A low-pressure loop distinguishes a required MIR body query from spill gating.

define void @kernel(ptr noalias %a, ptr noalias %b, i64 %n) vscale_range(2,2) {
entry:
  br label %loop
loop:
  %iv = phi i64 [ 0, %entry ], [ %next, %loop ]
  %pa = getelementptr double, ptr %a, i64 %iv
  %pb = getelementptr double, ptr %b, i64 %iv
  %x = load double, ptr %pa, align 8
  %y = fadd double %x, 1.0
  store double %y, ptr %pb, align 8
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret void
}
