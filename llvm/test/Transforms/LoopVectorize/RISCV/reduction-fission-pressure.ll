; RUN: opt -passes='loop-vectorize,instcombine,simplifycfg,verify' -mtriple=riscv64 -mattr=+v,+f,+d -force-vector-width=fission:4 -scalable-vectorization=on -S %s | llc -mattr=+v,+f,+d -verify-machineinstrs | FileCheck %s --implicit-check-not=vs8r.v --implicit-check-not=vl8r.v --implicit-check-not='call malloc' --implicit-check-not='call free'
;
; All four buffers fit on the stack. Collapse each accumulator before later
; reductions so four independent LMUL8 groups do not remain live together.
; Map and the four reductions remain distinct loops with independent widths.
target triple = "riscv64-unknown-linux-gnu"

; CHECK-LABEL: four_accumulators:
; CHECK: vfredusum.vs
; CHECK: vfredusum.vs
; CHECK: vfredusum.vs
; CHECK: vfredusum.vs
; CHECK: ret
define void @four_accumulators(ptr noalias %a, ptr noalias %b, ptr noalias %out) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%inc, %loop]
  %s0 = phi float [0.0, %entry], [%n0, %loop]
  %s1 = phi float [0.0, %entry], [%n1, %loop]
  %s2 = phi float [0.0, %entry], [%n2, %loop]
  %s3 = phi float [0.0, %entry], [%n3, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %q = getelementptr float, ptr %b, i64 %i
  %x = load float, ptr %p, align 4
  %y = load float, ptr %q, align 4
  %product = fmul fast float %x, %y
  %square = fmul fast float %x, %x
  %n0 = fadd fast float %s0, %x
  %n1 = fadd fast float %s1, %y
  %n2 = fadd fast float %s2, %product
  %n3 = fadd fast float %s3, %square
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 256
  br i1 %done, label %exit, label %loop
exit:
  %r0 = phi float [%n0, %loop]
  %r1 = phi float [%n1, %loop]
  %r2 = phi float [%n2, %loop]
  %r3 = phi float [%n3, %loop]
  %o1 = getelementptr float, ptr %out, i64 1
  %o2 = getelementptr float, ptr %out, i64 2
  %o3 = getelementptr float, ptr %out, i64 3
  store float %r0, ptr %out, align 4
  store float %r1, ptr %o1, align 4
  store float %r2, ptr %o2, align 4
  store float %r3, ptr %o3, align 4
  ret void
}
