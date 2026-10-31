; RUN: %python %S/Inputs/check-backend-scalar-probe.py opt %s %t
; Scalar probes retain the original function context and use the same native
; suffix and post-frame observer as vector probes. These opt-only tests do not
; rely on final code generation to perform another vectorization pass.

define void @context(ptr noalias %a, ptr noalias %b, ptr noalias %state, i64 %n) vscale_range(2,2) {
entry:
  br label %prefix
prefix:
  %pi = phi i64 [ 0, %entry ], [ %pn, %prefix ]
  %p = getelementptr i64, ptr %state, i64 %pi
  %s = load volatile i64, ptr %p, align 8
  %x = xor i64 %s, 13
  store volatile i64 %x, ptr %p, align 8
  %pn = add nuw i64 %pi, 1
  %pd = icmp eq i64 %pn, %n
  br i1 %pd, label %preheader, label %prefix, !llvm.loop !0
preheader:
  %bound = shl nuw i64 %n, 2
  br label %loop
loop:
  %iv = phi i64 [ 0, %preheader ], [ %next, %loop ]
  %pa = getelementptr double, ptr %a, i64 %iv
  %pb = getelementptr double, ptr %b, i64 %iv
  %v = load double, ptr %pa, align 8
  %r = fadd double %v, 1.0
  store double %r, ptr %pb, align 8
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %bound
  br i1 %done, label %exit, label %loop, !llvm.loop !3
exit:
  ret void
}

!0 = distinct !{!0, !1, !2}
!1 = !{!"llvm.loop.vectorize.enable", i1 false}
!2 = !{!"llvm.loop.unroll.disable"}
!3 = distinct !{!3, !4}
!4 = !{!"llvm.loop.unroll.count", i32 4}
