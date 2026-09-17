; RUN: opt -passes='instcombine,simplifycfg' -S %s | llc -mattr=+v,+f,+d -verify-machineinstrs | FileCheck %s
;
; A reduced reproducer of the post-Fission cleanup path. InstCombine used to
; sink the collapse past free, requiring an entire LMUL8 group to be spilled.

target triple = "riscv64-unknown-linux-gnu"

declare float @llvm.vector.reduce.fadd.nxv16f32(float, <vscale x 16 x float>)
declare void @free(ptr)

; CHECK-LABEL: cleanup:
; CHECK-NOT: vs8r.v
; CHECK: vfredusum.vs
; CHECK: call free
; CHECK-NOT: vl8r.v
; CHECK-NOT: vfredusum.vs
; CHECK: ret
define float @cleanup(ptr %p, <vscale x 16 x float> %acc) {
entry:
  %sum = call fast float @llvm.vector.reduce.fadd.nxv16f32(float 0.0, <vscale x 16 x float> %acc)
  br label %cleanup
cleanup:
  call void @free(ptr %p)
  br label %exit
exit:
  ret float %sum
}

; The actual vectorizer output also uses the accumulator on a loop backedge.
; The reduction is still its last use on the path reaching free.
; CHECK-LABEL: cleanup_loop:
; CHECK-NOT: vs8r.v
; CHECK: vfredusum.vs
; CHECK: call free
; CHECK-NOT: vl8r.v
; CHECK-NOT: vfredusum.vs
; CHECK: ret
define float @cleanup_loop(ptr %p, <vscale x 16 x float> %v, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%inc, %loop]
  %acc = phi <vscale x 16 x float> [zeroinitializer, %entry], [%next, %loop]
  %next = fadd fast <vscale x 16 x float> %acc, %v
  %inc = add i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %collapse, label %loop
collapse:
  %sum = call fast float @llvm.vector.reduce.fadd.nxv16f32(float 0.0, <vscale x 16 x float> %next)
  br label %cleanup
cleanup:
  call void @free(ptr %p)
  br label %exit
exit:
  ret float %sum
}
