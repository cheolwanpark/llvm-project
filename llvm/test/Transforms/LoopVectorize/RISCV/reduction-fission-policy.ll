; RUN: opt -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -pass-remarks-missed=loop-vectorize -S %s -o %t.normal
; RUN: opt -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -force-vector-width=fission:2 -pass-remarks-missed=loop-vectorize -S %s -o %t.filtered 2>&1 | FileCheck %s --check-prefix=REMARK
; RUN: diff %t.normal %t.filtered
; RUN: FileCheck %s --check-prefix=NORMAL < %t.filtered
; RUN: opt -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -force-vector-width=fission:2 -reduction-fission-filter=false -S %s -o %t.fission
; RUN: FileCheck %s --check-prefix=FISSION < %t.fission
; RUN: llc -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -verify-machineinstrs %t.filtered -o /dev/null
; RUN: llc -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -verify-machineinstrs %t.fission -o /dev/null
;
; These are intentionally narrow heuristics, independently switchable from
; legality and storage permission. Rejection must run ordinary Normal planning.
; REMARK-COUNT-4: recognized cheap product Map with owned scratch; selecting Normal
; REMARK: empty Map with one reducer; selecting Normal

target triple = "riscv64-unknown-linux-gnu"

; NORMAL-LABEL: define float @dot(
; NORMAL: phi <vscale x
; NORMAL: @llvm.vector.reduce.fadd
; NORMAL: ret float
; FISSION-LABEL: define float @dot(
; FISSION: alloca float, i64 64
; FISSION: fission.reduce.preheader
; FISSION: @llvm.vector.reduce.fadd
; FISSION: ret float
define float @dot(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
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
  %update = fadd fast float %sum, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 64
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%update, %loop]
  ret float %result
}

; NORMAL-LABEL: define float @squares(
; NORMAL: phi <vscale x
; NORMAL: @llvm.vector.reduce.fadd
; NORMAL: ret float
; FISSION-LABEL: define float @squares(
; FISSION: alloca float, i64 64
; FISSION: fission.reduce.preheader
; FISSION: @llvm.vector.reduce.fadd
; FISSION: ret float
define float @squares(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
entry:
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi float [0.0, %pre], [%update, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %product = fmul fast float %x, %x
  %update = fadd fast float %sum, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 64
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%update, %loop]
  ret float %result
}

; NORMAL-LABEL: define float @copy_squares(
; NORMAL: phi <vscale x
; NORMAL: @llvm.vector.reduce.fadd
; NORMAL: ret float
; FISSION-LABEL: define float @copy_squares(
; FISSION: alloca float, i64 64
; FISSION: fission.reduce.preheader
; FISSION: @llvm.vector.reduce.fadd
; FISSION: ret float
define float @copy_squares(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
entry:
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi float [0.0, %pre], [%update, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %product = fmul fast float %x, %x
  %o = getelementptr float, ptr %out, i64 %i
  store float %x, ptr %o, align 4
  %update = fadd fast float %sum, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 64
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%update, %loop]
  ret float %result
}

; NORMAL-LABEL: define float @multiply_add(
; NORMAL: phi <vscale x
; NORMAL: @llvm.vector.reduce.fadd
; NORMAL: ret float
; FISSION-LABEL: define float @multiply_add(
; FISSION: alloca float, i64 64
; FISSION: fission.reduce.preheader
; FISSION: @llvm.vector.reduce.fadd
; FISSION: ret float
define float @multiply_add(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
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
  %update = call fast float @llvm.fmuladd.f32(float %x, float %y, float %sum)
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 64
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%update, %loop]
  ret float %result
}

; NORMAL-LABEL: define float @empty_map(
; NORMAL: phi <vscale x
; NORMAL: @llvm.vector.reduce.fadd
; NORMAL: ret float
; FISSION-LABEL: define float @empty_map(
; FISSION-NOT: = alloca
; FISSION: fission.reduce.preheader
; FISSION: @llvm.vector.reduce.fadd
; FISSION: ret float
define float @empty_map(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
entry:
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi float [0.0, %pre], [%update, %loop]
  %p = getelementptr inbounds nuw float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %update = fadd fast float %sum, %x
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 64
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%update, %loop]
  ret float %result
}

declare float @llvm.fmuladd.f32(float, float, float)

; Independent metadata survives the Normal retry. The Fission Map width 2
; must not override the explicitly requested Normal width 8.
; NORMAL-LABEL: define float @hinted(
; NORMAL: phi <vscale x 8 x float>
; NORMAL: ret float
; FISSION-LABEL: define float @hinted(
; FISSION: fission.reduce.preheader
; FISSION: ret float
define float @hinted(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
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
  %update = fadd fast float %sum, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 64
  br i1 %done, label %exit, label %loop, !llvm.loop !0
exit:
  %result = phi float [%update, %loop]
  ret float %result
}

; NORMAL-LABEL: define float @disabled(
; NORMAL-NOT: vector.body
; NORMAL: %update = fadd fast float
; NORMAL: ret float
; FISSION-LABEL: define float @disabled(
; FISSION-NOT: fission.reduce
; FISSION: ret float
define float @disabled(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
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
  %update = fadd fast float %sum, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 64
  br i1 %done, label %exit, label %loop, !llvm.loop !4
exit:
  %result = phi float [%update, %loop]
  ret float %result
}

; NORMAL-LABEL: define i32 @integer_dot(
; NORMAL: phi <vscale x
; NORMAL: @llvm.vector.reduce.add
; NORMAL: ret i32
; FISSION-LABEL: define i32 @integer_dot(
; FISSION: alloca i32, i64 64
; FISSION: fission.reduce.preheader
; FISSION: @llvm.vector.reduce.add
; FISSION: ret i32
define i32 @integer_dot(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
entry:
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi i32 [0, %pre], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p, align 4
  %q = getelementptr i32, ptr %b, i64 %i
  %y = load i32, ptr %q, align 4
  %product = mul i32 %x, %y
  %update = add i32 %sum, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 64
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
}

!0 = distinct !{!0, !1, !2, !3}
!1 = !{!"llvm.loop.vectorize.enable", i1 true}
!2 = !{!"llvm.loop.vectorize.width", i32 8}
!3 = !{!"llvm.loop.vectorize.scalable.enable", i1 true}
!4 = distinct !{!4, !5}
!5 = !{!"llvm.loop.vectorize.enable", i1 false}
