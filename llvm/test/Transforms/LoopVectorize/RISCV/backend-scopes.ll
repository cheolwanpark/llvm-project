; REQUIRES: asserts
; RUN: %python %S/Inputs/backend-contract.py scopes opt %s %t
;
; At VF16 the native suffix removes this loop. The driver also uses a 16-trip
; version whose backedge is already absent at materialization time.
define void @finite(ptr noalias %a, ptr noalias %b, ptr noalias %c) vscale_range(2,2) {
entry: br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %q = getelementptr float, ptr %b, i64 %i
  %dst = getelementptr float, ptr %c, i64 %i
  %x = load float, ptr %p
  %y = load float, ptr %q
  %positive = fcmp ogt float %x, 0.0
  %square = fmul float %x, %x
  %sum = fadd float %square, %y
  %r = select i1 %positive, float %sum, float %y
  store float %r, ptr %dst
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, 64
  br i1 %done, label %exit, label %loop, !llvm.loop !0
exit: ret void
}
!0 = distinct !{!0, !1}
!1 = !{!"llvm.loop.unroll.full"}
