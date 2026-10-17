; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v \
; RUN:   -tail-folding-policy=must-fold-tail \
; RUN:   -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-min-chain-depth=4 -S %s | FileCheck %s
;
; Scalar remainders preserve signed-zero initializers without inactive lanes.
; CHECK-LABEL: define void @signed_zero(
; CHECK: vector.fission.accumulator.body:
; CHECK-NOT: select reassoc
; CHECK: @llvm.vector.reduce.fadd
; CHECK: scalar.fission.accumulator.check:
; CHECK: phi double [ -0.000000e+00,
; CHECK: scalar.fission.accumulator.body:
; CHECK: fadd reassoc double

define void @signed_zero(ptr noalias readonly %a, ptr noalias writeonly %out) vscale_range(2,2) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %r0 = phi double [-0.0, %entry], [%n0, %loop]
  %r1 = phi double [-0.0, %entry], [%n1, %loop]
  %r2 = phi double [-0.0, %entry], [%n2, %loop]
  %r3 = phi double [-0.0, %entry], [%n3, %loop]
  %r4 = phi double [-0.0, %entry], [%n4, %loop]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p
  %c1 = fmul double %x, 2.0
  %c2 = fmul double %c1, 3.0
  %c3 = fmul double %c2, 4.0
  %c4 = fmul double %c3, 5.0
  %n0 = fadd reassoc double %r0, %c4
  %n1 = fadd reassoc double %r1, %c4
  %n2 = fadd reassoc double %r2, %c4
  %n3 = fadd reassoc double %r3, %c4
  %n4 = fadd reassoc double %r4, %c4
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, 65
  br i1 %done, label %exit, label %loop
exit:
  store double %n0, ptr %out
  %o1 = getelementptr double, ptr %out, i64 1
  store double %n1, ptr %o1
  %o2 = getelementptr double, ptr %out, i64 2
  store double %n2, ptr %o2
  %o3 = getelementptr double, ptr %out, i64 3
  store double %n3, ptr %o3
  %o4 = getelementptr double, ptr %out, i64 4
  store double %n4, ptr %o4
  ret void
}
