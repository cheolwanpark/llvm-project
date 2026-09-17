; RUN: opt -passes='loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -force-vector-width=fission:4 -scalable-vectorization=off -verify-dom-info -verify-loop-info -verify-scev -S %s | FileCheck %s

; Reuse only a non-wrapping contiguous stream with no possibly aliasing Map
; overwrite. Every positive case retains a Map store and a separate reduction.
target triple = "riscv64-unknown-linux-gnu"

; CHECK-LABEL: define float @output_stream(
; CHECK-NOT: = alloca
; CHECK-NOT: call {{.*}}@malloc
; CHECK: store <4 x float>
; CHECK: fission.reduce.preheader
; CHECK: @llvm.vp.load.nxv16f32
; CHECK: @llvm.vector.reduce.fadd
; CHECK-NOT: call void @free
; CHECK: ret float
define float @output_stream(ptr noalias %a, ptr noalias %b, ptr writeonly %out, ptr %other, i64 %n) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %acc = phi float [0.0, %pre], [%next, %loop]
  %p = getelementptr inbounds nuw float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr inbounds nuw float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %product = fmul fast float %x, %y
  %o = getelementptr inbounds nuw float, ptr %out, i64 %i
  store float %product, ptr %o, align 4
  %next = fadd fast float %acc, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [0.0, %entry], [%next, %loop]
  ret float %result
}

; CHECK-LABEL: define float @input_stream(
; CHECK-NOT: = alloca
; CHECK-NOT: call {{.*}}@malloc
; CHECK: store <4 x float>
; CHECK: fission.reduce.preheader
; CHECK: @llvm.vp.load.nxv16f32
; CHECK: @llvm.vector.reduce.fadd
; CHECK-NOT: call void @free
; CHECK: ret float
define float @input_stream(ptr noalias %a, ptr noalias %b, ptr writeonly %out, ptr %other, i64 %n) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %acc = phi float [0.0, %pre], [%next, %loop]
  %p = getelementptr inbounds nuw float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr inbounds nuw float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %product = fmul fast float %x, %y
  %o = getelementptr inbounds nuw float, ptr %out, i64 %i
  store float %product, ptr %o, align 4
  %next = fadd fast float %acc, %x
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [0.0, %entry], [%next, %loop]
  ret float %result
}

; CHECK-LABEL: define float @may_alias_output(
; CHECK: call {{.*}}@malloc
; CHECK: fission.reduce.preheader
; CHECK: @llvm.vector.reduce.fadd
; CHECK: call void @free
; CHECK: ret float
define float @may_alias_output(ptr noalias %a, ptr noalias %b, ptr writeonly %out, ptr %other, i64 %n) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %acc = phi float [0.0, %pre], [%next, %loop]
  %p = getelementptr inbounds nuw float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr inbounds nuw float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %product = fmul fast float %x, %y
  %o = getelementptr inbounds nuw float, ptr %out, i64 %i
  store float %product, ptr %o, align 4
  %r = getelementptr inbounds nuw float, ptr %other, i64 %i
  store float 0.0, ptr %r, align 4
  %next = fadd fast float %acc, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [0.0, %entry], [%next, %loop]
  ret float %result
}

; CHECK-LABEL: define float @overwritten_input(
; CHECK: call {{.*}}@malloc
; CHECK: fission.reduce.preheader
; CHECK: @llvm.vector.reduce.fadd
; CHECK: call void @free
; CHECK: ret float
define float @overwritten_input(ptr noalias %a, ptr noalias %b, ptr writeonly %out, ptr %other, i64 %n) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %acc = phi float [0.0, %pre], [%next, %loop]
  %p = getelementptr inbounds nuw float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr inbounds nuw float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %product = fmul fast float %x, %y
  %o = getelementptr inbounds nuw float, ptr %out, i64 %i
  store float %product, ptr %o, align 4
  store float %product, ptr %p, align 4
  %next = fadd fast float %acc, %x
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [0.0, %entry], [%next, %loop]
  ret float %result
}

; CHECK-LABEL: define float @noncontiguous_output(
; CHECK: call {{.*}}@malloc
; CHECK: fission.reduce.preheader
; CHECK: @llvm.vector.reduce.fadd
; CHECK: call void @free
; CHECK: ret float
define float @noncontiguous_output(ptr noalias %a, ptr noalias %b, ptr writeonly %out, ptr %other, i64 %n) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %acc = phi float [0.0, %pre], [%next, %loop]
  %p = getelementptr inbounds nuw float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr inbounds nuw float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %product = fmul fast float %x, %y
  %twice = mul nuw i64 %i, 2
  %o = getelementptr inbounds nuw float, ptr %out, i64 %twice
  store float %product, ptr %o, align 4
  %next = fadd fast float %acc, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [0.0, %entry], [%next, %loop]
  ret float %result
}

; Without a non-wrapping address proof, retain the materialized contribution.
; CHECK-LABEL: define float @unproven_wrap(
; CHECK: call {{.*}}@malloc
; CHECK: fission.reduce.preheader
; CHECK: @llvm.vector.reduce.fadd
; CHECK: call void @free
; CHECK: ret float
define float @unproven_wrap(ptr noalias %a, ptr noalias %b, ptr writeonly %out, ptr %other, i64 %n) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %acc = phi float [0.0, %pre], [%next, %loop]
  %p = getelementptr inbounds nuw float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr inbounds nuw float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %product = fmul fast float %x, %y
  %o = getelementptr float, ptr %out, i64 %i
  store float %product, ptr %o, align 4
  %next = fadd fast float %acc, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [0.0, %entry], [%next, %loop]
  ret float %result
}
