; REQUIRES: riscv-registered-target
; RUN: %python %S/Inputs/check-backend-scalar-cost-sources.py opt %s %t
; Generic divide and adjacent-difference loops exercise scalar/source symmetry.
; The checker verifies costs and observation equations without prescribing a VF.

define void @divide(ptr noalias %a, ptr noalias %b, ptr noalias %out) vscale_range(4,4) {
entry:
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %loop]
  %pa = getelementptr double, ptr %a, i64 %iv
  %pb = getelementptr double, ptr %b, i64 %iv
  %po = getelementptr double, ptr %out, i64 %iv
  %x = load double, ptr %pa, align 8
  %y = load double, ptr %pb, align 8
  %q = fdiv double %x, %y
  store double %q, ptr %po, align 8
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, 512
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

define void @adjacent_difference(ptr noalias %a, ptr noalias %out) vscale_range(4,4) {
entry:
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %loop]
  %next = add nuw nsw i64 %iv, 1
  %pa = getelementptr double, ptr %a, i64 %iv
  %pb = getelementptr double, ptr %a, i64 %next
  %po = getelementptr double, ptr %out, i64 %iv
  %x = load double, ptr %pa, align 8
  %y = load double, ptr %pb, align 8
  %d = fsub double %y, %x
  store double %d, ptr %po, align 8
  %done = icmp eq i64 %next, 512
  br i1 %done, label %exit, label %loop
exit:
  ret void
}
