; RUN: opt -passes='loop-vectorize,verify' -verify-dom-info -verify-loop-info -verify-scev -mtriple=riscv64 -mattr=+v,+f,+d -force-vector-width=fission:2 -scalable-vectorization=on -pass-remarks=loop-vectorize -pass-remarks-missed=loop-vectorize -S %s 2>&1 | FileCheck %s
;
; Underaligned scalable loads have invalid target costs. Even though the
; generated reduction vectorizes, Map failure must roll back the entire trial.
; A provisional selection must never be reported as a successful fission.
; CHECK: selected Fission MapVF=vscale x 2
; CHECK: selected fission component could not be vectorized
; CHECK: vectorized loop (vectorization width: vscale x 16, interleaved count: 1)
; CHECK: fission rejected: a component failed; original function preserved
; CHECK-NOT: committed fission
; CHECK-LABEL: define float @sum(
; CHECK-NOT: call {{.*}}@malloc
; CHECK-NOT: fission.
; CHECK: %sum = phi float
; CHECK: %x = load float, ptr %p, align 2
; CHECK: %update = fadd fast float %sum, %x
; CHECK: ret float %result

define float @sum(ptr %a, i64 %n, float %initial) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi float [%initial, %preheader], [%update, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 2
  %update = fadd fast float %sum, %x
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%initial, %entry], [%update, %loop]
  ret float %result
}
