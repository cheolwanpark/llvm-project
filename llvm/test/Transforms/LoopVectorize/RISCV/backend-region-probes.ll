; RUN: %python %S/Inputs/check-backend-region-probes.py opt %s %t
;
; The probe suffix fully unrolls this body. Region probes must recover its
; scalar work count without leaking into the selected output IR.
define void @unrolled(ptr noalias %a, ptr noalias %b, ptr noalias %c,
                      ptr noalias %d, ptr noalias %e) vscale_range(2,2) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %pa = getelementptr float, ptr %a, i64 %i
  %pb = getelementptr float, ptr %b, i64 %i
  %pc = getelementptr float, ptr %c, i64 %i
  %pd = getelementptr float, ptr %d, i64 %i
  %pe = getelementptr float, ptr %e, i64 %i
  %bv = load float, ptr %pb, align 4
  %cv = load float, ptr %pc, align 4
  %dv = load float, ptr %pd, align 4
  %ev = load float, ptr %pe, align 4
  %positive = fcmp ogt float %bv, 0.0
  %x = call float @llvm.fmuladd.f32(float %dv, float %ev, float %bv)
  %y = call float @llvm.fmuladd.f32(float %dv, float %ev, float %cv)
  %r = select i1 %positive, float %x, float %y
  store float %r, ptr %pa, align 4
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, 320
  br i1 %done, label %exit, label %loop, !llvm.loop !5
exit:
  ret void
}

; VPlan eliminates the backedge while materializing this single vector
; iteration, before the probe suffix can see a Loop.
define void @single_iteration(ptr noalias %a, ptr noalias %b, ptr noalias %c,
                      ptr noalias %d, ptr noalias %e) vscale_range(2,2) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %pa = getelementptr float, ptr %a, i64 %i
  %pb = getelementptr float, ptr %b, i64 %i
  %pc = getelementptr float, ptr %c, i64 %i
  %pd = getelementptr float, ptr %d, i64 %i
  %pe = getelementptr float, ptr %e, i64 %i
  %bv = load float, ptr %pb, align 4
  %cv = load float, ptr %pc, align 4
  %dv = load float, ptr %pd, align 4
  %ev = load float, ptr %pe, align 4
  %positive = fcmp ogt float %bv, 0.0
  %x = call float @llvm.fmuladd.f32(float %dv, float %ev, float %bv)
  %y = call float @llvm.fmuladd.f32(float %dv, float %ev, float %cv)
  %r = select i1 %positive, float %x, float %y
  store float %r, ptr %pa, align 4
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, 16
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

declare float @llvm.fmuladd.f32(float, float, float)

; Unrolling the outer loop duplicates the marked inner loop. The prototype
; must reject these separate regions rather than select one of the copies.
define void @cloned(ptr noalias %a, ptr noalias %b) vscale_range(2,2) {
entry:
  br label %outer
outer:
  %j = phi i64 [ 0, %entry ], [ %jnext, %inner.exit ]
  %offset = mul i64 %j, 128
  br label %inner
inner:
  %i = phi i64 [ 0, %outer ], [ %next, %inner ]
  %idx = add i64 %offset, %i
  %pa = getelementptr float, ptr %a, i64 %idx
  %pb = getelementptr float, ptr %b, i64 %idx
  %v = load float, ptr %pa, align 4
  %r = fadd float %v, 1.0
  store float %r, ptr %pb, align 4
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, 128
  br i1 %done, label %inner.exit, label %inner, !llvm.loop !0
inner.exit:
  %jnext = add nuw i64 %j, 1
  %outer.done = icmp eq i64 %jnext, 16
  br i1 %outer.done, label %exit, label %outer, !llvm.loop !2
exit:
  ret void
}

!0 = distinct !{!0, !1}
!1 = !{!"llvm.loop.unroll.disable"}
!2 = distinct !{!2, !3, !4}
!3 = !{!"llvm.loop.unroll.count", i32 2}
!4 = !{!"llvm.loop.vectorize.enable", i1 false}
!5 = distinct !{!5, !6}
!6 = !{!"llvm.loop.unroll.full"}
