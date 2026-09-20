; RUN: opt -passes='loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -force-vector-width=fission:2 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -S %s | FileCheck %s
;
; One scalar contribution per iteration for a two-term associative chain.
; The accumulator appears exactly once, and its initial value is used only in
; its own reducer. Reassociation intersects FMF and drops integer wrap flags.

; CHECK-LABEL: define i32 @integer_chain(
; CHECK: br i1 %empty, label %exit, label %pre
; CHECK: call noalias ptr @malloc
; CHECK-NOT: @malloc
; CHECK: add <vscale x 2 x i32>
; CHECK: fission.reduce.preheader
; CHECK: phi <vscale x 16 x i32>
; CHECK: add <vscale x 16 x i32>
; CHECK: @llvm.vector.reduce.add
; CHECK: @free
; CHECK-NOT: @free
; CHECK: ret i32
define i32 @integer_chain(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, i32 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %acc = phi i32 [%init, %pre], [%next, %loop]
  %pa = getelementptr i32, ptr %a, i64 %i
  %pb = getelementptr i32, ptr %b, i64 %i
  %a0 = load i32, ptr %pa
  %b0 = load i32, ptr %pb
  %partial = add nsw i32 %acc, %a0
  %next = add nsw i32 %partial, %b0
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%init, %entry], [%next, %loop]
  ret i32 %result
}

; CHECK-LABEL: define float @reassoc_chain(
; CHECK: br i1 %empty, label %exit, label %pre
; CHECK: call noalias ptr @malloc
; CHECK-NOT: @malloc
; CHECK: fadd reassoc <vscale x 2 x float>
; CHECK: fission.reduce.preheader
; CHECK: phi <vscale x 16 x float>
; CHECK: fadd reassoc <vscale x 16 x float>
; CHECK: @llvm.vector.reduce.fadd
; CHECK: @free
; CHECK-NOT: @free
; CHECK: ret float
define float @reassoc_chain(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, float %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %acc = phi float [%init, %pre], [%next, %loop]
  %pa = getelementptr float, ptr %a, i64 %i
  %pb = getelementptr float, ptr %b, i64 %i
  %a0 = load float, ptr %pa
  %b0 = load float, ptr %pb
  %partial = fadd fast float %acc, %a0
  %next = fadd reassoc float %partial, %b0
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%init, %entry], [%next, %loop]
  ret float %result
}

; CHECK-LABEL: define double @double_chain(
; CHECK: br i1 %empty, label %exit, label %pre
; CHECK: call noalias ptr @malloc
; CHECK-NOT: @malloc
; CHECK: fadd reassoc <vscale x 2 x double>
; CHECK: fission.reduce.preheader
; CHECK: phi <vscale x 8 x double>
; CHECK: fadd reassoc <vscale x 8 x double>
; CHECK: @llvm.vector.reduce.fadd
; CHECK: @free
; CHECK-NOT: @free
; CHECK: ret double
define double @double_chain(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, double %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %acc = phi double [%init, %pre], [%next, %loop]
  %pa = getelementptr double, ptr %a, i64 %i
  %pb = getelementptr double, ptr %b, i64 %i
  %a0 = load double, ptr %pa
  %b0 = load double, ptr %pb
  %partial = fadd reassoc double %acc, %a0
  %next = fadd reassoc double %partial, %b0
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi double [%init, %entry], [%next, %loop]
  ret double %result
}

; Combining two reusable streams must not introduce an owned buffer just to
; reduce the number of loads in the reducer. Both Map outputs are observable.
; CHECK-LABEL: define float @reuse_two_outputs(
; CHECK-NOT: @malloc
; CHECK: fission.reduce.preheader
; CHECK-NOT: @malloc
; CHECK: phi <vscale x 16 x float>
; CHECK: fadd fast <vscale x 16 x float>
; CHECK: fadd fast <vscale x 16 x float>
; CHECK: @llvm.vector.reduce.fadd
; CHECK-NOT: @free
; CHECK: ret float
define float @reuse_two_outputs(ptr noalias readonly %a, ptr noalias readonly %b, ptr noalias writeonly %out0, ptr noalias writeonly %out1, i64 %n, float %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %acc = phi float [%init, %pre], [%next, %loop]
  %pa = getelementptr inbounds nuw float, ptr %a, i64 %i
  %pb = getelementptr inbounds nuw float, ptr %b, i64 %i
  %po0 = getelementptr inbounds nuw float, ptr %out0, i64 %i
  %po1 = getelementptr inbounds nuw float, ptr %out1, i64 %i
  %x = load float, ptr %pa
  %y = load float, ptr %pb
  %p = fmul fast float %x, %x
  %q = fmul fast float %y, %y
  store float %p, ptr %po0
  store float %q, ptr %po1
  %partial = fadd fast float %acc, %p
  %next = fadd fast float %partial, %q
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%init, %entry], [%next, %loop]
  ret float %result
}

; Original finite intermediate values do not prove finiteness of the combined
; contribution. No poison-generating flags may be copied by intersection.
; CHECK-LABEL: define double @nnan_ninf_chain(
; CHECK: fadd reassoc nsz <vscale x 2 x double>
; CHECK: fission.reduce.preheader
; CHECK: fadd reassoc nsz <vscale x 8 x double>
; CHECK: ret double
define double @nnan_ninf_chain(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, double %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %acc = phi double [%init, %pre], [%next, %loop]
  %pa = getelementptr double, ptr %a, i64 %i
  %pb = getelementptr double, ptr %b, i64 %i
  %a0 = load double, ptr %pa
  %b0 = load double, ptr %pb
  %partial = fadd reassoc nnan ninf nsz double %acc, %a0
  %next = fadd reassoc nnan ninf nsz double %partial, %b0
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi double [%init, %entry], [%next, %loop]
  ret double %result
}
