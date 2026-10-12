; RUN: opt -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -reduction-fission-stack-budget=256 -force-vector-width=fission:2 -S %s | FileCheck %s --implicit-check-not=@malloc --implicit-check-not=@free
;
; One reducer is not itself grounds for rejection. These maps contain work
; outside the deliberately recognized product shape. Reusable multi-reductions
; likewise remain a distinct eligible transformation.
target triple = "riscv64-unknown-linux-gnu"

; CHECK-LABEL: define float @division(
; CHECK: alloca float, i64 64
; CHECK: fission.reduce.preheader
; CHECK: @llvm.vector.reduce.fadd
; CHECK: ret float
define float @division(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
entry:
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi float [0.0, %pre], [%update, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %product = fmul fast float %x, %y
  %work = fdiv fast float %product, %x
  %update = fadd fast float %sum, %work
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 64
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%update, %loop]
  ret float %result
}

; CHECK-LABEL: define float @indexed(
; CHECK: alloca float, i64 64
; CHECK: fission.reduce.preheader
; CHECK: @llvm.vector.reduce.fadd
; CHECK: ret float
define float @indexed(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
entry:
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi float [0.0, %pre], [%update, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %idxp = getelementptr i64, ptr %b, i64 %i
  %idx = load i64, ptr %idxp, align 8
  %q = getelementptr float, ptr %a, i64 %idx
  %y = load float, ptr %q, align 4
  %product = fmul fast float %x, %y
  %update = fadd fast float %sum, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 64
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%update, %loop]
  ret float %result
}

; CHECK-LABEL: define float @complex_fma(
; CHECK: alloca float, i64 64
; CHECK: fission.reduce.preheader
; CHECK: @llvm.vector.reduce.fadd
; CHECK: ret float
define float @complex_fma(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
entry:
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi float [0.0, %pre], [%update, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %extra = fadd fast float %x, %y
  %update = call fast float @llvm.fmuladd.f32(float %extra, float %y, float %sum)
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 64
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%update, %loop]
  ret float %result
}

declare float @llvm.fmuladd.f32(float, float, float)

; CHECK-LABEL: define float @shared(
; CHECK: alloca float, i64 64
; CHECK-NOT: = alloca
; CHECK: @llvm.vector.reduce.fadd
; CHECK: @llvm.vector.reduce.fadd
; CHECK: ret float
define float @shared(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
entry:
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi float [0.0, %pre], [%update, %loop]
  %sum2 = phi float [1.0, %pre], [%update2, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %product = fmul fast float %x, %y
  %update = fadd fast float %sum, %product
  %update2 = fadd fast float %sum2, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 64
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%update, %loop]
  %result2 = phi float [%update2, %loop]
  %both = fadd float %result, %result2
  ret float %both
}

; CHECK-LABEL: define float @two_streams(
; CHECK-NOT: = alloca
; CHECK: @llvm.vector.reduce.fadd
; CHECK: @llvm.vector.reduce.fadd
; CHECK: ret float
define float @two_streams(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
entry:
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi float [0.0, %pre], [%update, %loop]
  %sum2 = phi float [1.0, %pre], [%update2, %loop]
  %p = getelementptr inbounds nuw float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr inbounds nuw float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %update = fadd fast float %sum, %x
  %update2 = fadd fast float %sum2, %y
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 64
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%update, %loop]
  %result2 = phi float [%update2, %loop]
  %both = fadd float %result, %result2
  ret float %both
}

