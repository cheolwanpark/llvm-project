; RUN: opt -passes='loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -force-vector-width=fission:2 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -S %s | FileCheck %s

; Two terms become one contribution, without requiring FP reassoc for the
; intrinsically associative min/max operation under its checked permissions.
; CHECK-LABEL: define i32 @smin_chain(
; CHECK: call noalias ptr @malloc
; CHECK-NOT: @malloc
; CHECK: @llvm.smin.nxv2i32
; CHECK: fission.reduce.preheader
; CHECK: phi <vscale x 16 x i32>
; CHECK: @llvm.smin.nxv16i32
; CHECK: @llvm.vector.reduce.smin.nxv16i32
; CHECK: @free
; CHECK-NOT: @free
; CHECK: ret i32
define i32 @smin_chain(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, i32 %init) {
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
  %x = load i32, ptr %pa, align 4
  %y = load i32, ptr %pb, align 4
  %partial = call i32 @llvm.smin.i32(i32 %acc, i32 %x)
  %next = call i32 @llvm.smin.i32(i32 %y, i32 %partial)
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%init, %entry], [%next, %loop]
  ret i32 %result
}
declare i32 @llvm.smin.i32(i32, i32)

; Two terms become one contribution, without requiring FP reassoc for the
; intrinsically associative min/max operation under its checked permissions.
; CHECK-LABEL: define i32 @smax_chain(
; CHECK: call noalias ptr @malloc
; CHECK-NOT: @malloc
; CHECK: @llvm.smax.nxv2i32
; CHECK: fission.reduce.preheader
; CHECK: phi <vscale x 16 x i32>
; CHECK: @llvm.smax.nxv16i32
; CHECK: @llvm.vector.reduce.smax.nxv16i32
; CHECK: @free
; CHECK-NOT: @free
; CHECK: ret i32
define i32 @smax_chain(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, i32 %init) {
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
  %x = load i32, ptr %pa, align 4
  %y = load i32, ptr %pb, align 4
  %partial = call i32 @llvm.smax.i32(i32 %acc, i32 %x)
  %next = call i32 @llvm.smax.i32(i32 %y, i32 %partial)
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%init, %entry], [%next, %loop]
  ret i32 %result
}
declare i32 @llvm.smax.i32(i32, i32)

; Two terms become one contribution, without requiring FP reassoc for the
; intrinsically associative min/max operation under its checked permissions.
; CHECK-LABEL: define i32 @umin_chain(
; CHECK: call noalias ptr @malloc
; CHECK-NOT: @malloc
; CHECK: @llvm.umin.nxv2i32
; CHECK: fission.reduce.preheader
; CHECK: phi <vscale x 16 x i32>
; CHECK: @llvm.umin.nxv16i32
; CHECK: @llvm.vector.reduce.umin.nxv16i32
; CHECK: @free
; CHECK-NOT: @free
; CHECK: ret i32
define i32 @umin_chain(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, i32 %init) {
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
  %x = load i32, ptr %pa, align 4
  %y = load i32, ptr %pb, align 4
  %partial = call i32 @llvm.umin.i32(i32 %acc, i32 %x)
  %next = call i32 @llvm.umin.i32(i32 %y, i32 %partial)
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%init, %entry], [%next, %loop]
  ret i32 %result
}
declare i32 @llvm.umin.i32(i32, i32)

; Two terms become one contribution, without requiring FP reassoc for the
; intrinsically associative min/max operation under its checked permissions.
; CHECK-LABEL: define i32 @umax_chain(
; CHECK: call noalias ptr @malloc
; CHECK-NOT: @malloc
; CHECK: @llvm.umax.nxv2i32
; CHECK: fission.reduce.preheader
; CHECK: phi <vscale x 16 x i32>
; CHECK: @llvm.umax.nxv16i32
; CHECK: @llvm.vector.reduce.umax.nxv16i32
; CHECK: @free
; CHECK-NOT: @free
; CHECK: ret i32
define i32 @umax_chain(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, i32 %init) {
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
  %x = load i32, ptr %pa, align 4
  %y = load i32, ptr %pb, align 4
  %partial = call i32 @llvm.umax.i32(i32 %acc, i32 %x)
  %next = call i32 @llvm.umax.i32(i32 %y, i32 %partial)
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%init, %entry], [%next, %loop]
  ret i32 %result
}
declare i32 @llvm.umax.i32(i32, i32)

; Two terms become one contribution, without requiring FP reassoc for the
; intrinsically associative min/max operation under its checked permissions.
; CHECK-LABEL: define float @minnum_chain(
; CHECK: call noalias ptr @malloc
; CHECK-NOT: @malloc
; CHECK: @llvm.minnum.nxv2f32
; CHECK: fission.reduce.preheader
; CHECK: phi <vscale x 16 x float>
; CHECK: @llvm.minnum.nxv16f32
; CHECK: @llvm.vector.reduce.fmin.nxv16f32
; CHECK: @free
; CHECK-NOT: @free
; CHECK: ret float
define float @minnum_chain(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, float %init) {
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
  %x = load float, ptr %pa, align 4
  %y = load float, ptr %pb, align 4
  %partial = call nnan nsz float @llvm.minnum.f32(float %acc, float %x)
  %next = call nnan nsz float @llvm.minnum.f32(float %y, float %partial)
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%init, %entry], [%next, %loop]
  ret float %result
}
declare float @llvm.minnum.f32(float, float)

; Two terms become one contribution, without requiring FP reassoc for the
; intrinsically associative min/max operation under its checked permissions.
; CHECK-LABEL: define float @maxnum_chain(
; CHECK: call noalias ptr @malloc
; CHECK-NOT: @malloc
; CHECK: @llvm.maxnum.nxv2f32
; CHECK: fission.reduce.preheader
; CHECK: phi <vscale x 16 x float>
; CHECK: @llvm.maxnum.nxv16f32
; CHECK: @llvm.vector.reduce.fmax.nxv16f32
; CHECK: @free
; CHECK-NOT: @free
; CHECK: ret float
define float @maxnum_chain(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, float %init) {
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
  %x = load float, ptr %pa, align 4
  %y = load float, ptr %pb, align 4
  %partial = call nnan nsz float @llvm.maxnum.f32(float %acc, float %x)
  %next = call nnan nsz float @llvm.maxnum.f32(float %y, float %partial)
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%init, %entry], [%next, %loop]
  ret float %result
}
declare float @llvm.maxnum.f32(float, float)
