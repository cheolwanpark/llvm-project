; RUN: opt -passes='loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+d,+f -force-vector-width=fission:4 -scalable-vectorization=off -verify-dom-info -verify-loop-info -verify-scev -S %s | FileCheck %s
; RUN: opt -passes='loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+d,+f -force-vector-width=fission:2 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -S %s | FileCheck %s
;
; Reassociation is sufficient for unordered accumulation, but it does not waive
; signed-zero semantics. None of the positive cases grants nsz or fast.

target triple = "riscv64-unknown-linux-gnu"

; An empty loop returns its negative-zero initial value without allocating.
; For nonempty loops the reduction identity must also be negative zero. With
; exclusively negative-zero inputs this preserves the original result sign.
; CHECK-LABEL: define float @reassoc_negative_zero(
; CHECK: entry:
; CHECK-NEXT: %empty = icmp eq i64 %n, 0
; CHECK-NEXT: br i1 %empty, label %exit, label %preheader
; CHECK: @malloc
; CHECK: phi <vscale x 16 x float> [ {{.*}}splat (float -0.000000e+00)
; CHECK: fadd reassoc <vscale x 16 x float>
; CHECK: call reassoc float @llvm.vector.reduce.fadd.nxv16f32(float -0.000000e+00,
; CHECK: @free
; CHECK: exit:
; CHECK: phi float [ -0.000000e+00, %entry ],
; CHECK: ret float
define float @reassoc_negative_zero(ptr noalias readonly %a, i64 %n) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi float [ -0.000000e+00, %preheader ], [ %next, %loop ]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %next = fadd reassoc float %acc, %x
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [ -0.000000e+00, %entry ], [ %next, %loop ]
  ret float %result
}

; llvm.fmuladd permits fusion but does not require it. Its two independent
; multiplicands must cross the separation boundary separately. This checks the
; intrinsic survives vectorization; it is not a claim of strict fused semantics
; or of a particular target assembly instruction.
; CHECK-LABEL: define float @reassoc_fmuladd_two_inputs(
; CHECK: call noalias ptr @malloc
; CHECK: call noalias ptr @malloc
; CHECK: fission.reduce.preheader
; CHECK: phi <vscale x 16 x float>
; CHECK: {{(load <vscale x 16 x float>|@llvm.vp.load.nxv16f32|@llvm.masked.load.nxv16f32)}}
; CHECK: {{(load <vscale x 16 x float>|@llvm.vp.load.nxv16f32|@llvm.masked.load.nxv16f32)}}
; CHECK: call reassoc <vscale x 16 x float> @llvm.fmuladd.nxv16f32(
; CHECK: call reassoc float @llvm.vector.reduce.fadd.nxv16f32(float -0.000000e+00,
; CHECK: @free
; CHECK: @free
; CHECK: ret float
define float @reassoc_fmuladd_two_inputs(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, float %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi float [ %init, %preheader ], [ %next, %loop ]
  %p = getelementptr float, ptr %a, i64 %i
  %q = getelementptr float, ptr %b, i64 %i
  %x = load float, ptr %p, align 4
  %y = load float, ptr %q, align 4
  %next = call reassoc float @llvm.fmuladd.f32(float %x, float %y, float %acc)
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [ %init, %entry ], [ %next, %loop ]
  ret float %result
}

; llvm.fma requires a fused multiply-add. Upstream RecurrenceDescriptor does not
; recognize this recurrence, including with reassoc permission. Fission must
; reject it rather than replacing it with independent multiply and addition.
; CHECK-LABEL: define float @strictly_fused_fma_unsupported(
; CHECK-NOT: @malloc
; CHECK-NOT: fission.reduce
; CHECK: call reassoc float @llvm.fma.f32(float %x, float %y, float %acc)
; CHECK-NOT: @malloc
; CHECK-NOT: fission.reduce
; CHECK: ret float
define float @strictly_fused_fma_unsupported(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, float %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi float [ %init, %preheader ], [ %next, %loop ]
  %p = getelementptr float, ptr %a, i64 %i
  %q = getelementptr float, ptr %b, i64 %i
  %x = load float, ptr %p, align 4
  %y = load float, ptr %q, align 4
  %next = call reassoc float @llvm.fma.f32(float %x, float %y, float %acc)
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [ %init, %entry ], [ %next, %loop ]
  ret float %result
}

; Ordered fadd can be vectorized with in-loop horizontal reductions on RVV, but
; cannot use the required vector accumulator and exit-only collapse. One ordered
; recurrence therefore rejects the entire original loop, including its otherwise
; eligible reassoc recurrence. A force request must not add reassoc to either.
; CHECK-LABEL: define { double, double } @mixed_reassoc_and_ordered(
; CHECK-NOT: @malloc
; CHECK-NOT: fission.reduce
; CHECK: %unordered.next = fadd reassoc double %unordered.acc, %x
; CHECK-NEXT: %ordered.next = fadd double %ordered.acc, %x
; CHECK-NOT: @malloc
; CHECK-NOT: fission.reduce
; CHECK: ret { double, double }
define { double, double } @mixed_reassoc_and_ordered(ptr noalias readonly %a, i64 %n, double %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %unordered.acc = phi double [ %init, %preheader ], [ %unordered.next, %loop ]
  %ordered.acc = phi double [ %init, %preheader ], [ %ordered.next, %loop ]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p, align 8
  %unordered.next = fadd reassoc double %unordered.acc, %x
  %ordered.next = fadd double %ordered.acc, %x
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %unordered.result = phi double [ %init, %entry ], [ %unordered.next, %loop ]
  %ordered.result = phi double [ %init, %entry ], [ %ordered.next, %loop ]
  %pair1 = insertvalue { double, double } poison, double %unordered.result, 0
  %pair2 = insertvalue { double, double } %pair1, double %ordered.result, 1
  ret { double, double } %pair2
}

declare float @llvm.fmuladd.f32(float, float, float)
declare float @llvm.fma.f32(float, float, float)
