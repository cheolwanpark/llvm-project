; NOTE: Focused semantic inputs, independent of benchmark extraction.
; RUN: opt -passes='loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+d,+f -force-vector-width=fission:4 -scalable-vectorization=off -S %s | FileCheck %s --check-prefix=FISSION
; RUN: opt -passes='loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+d,+f -force-vector-width=fission:2 -scalable-vectorization=on -S %s | FileCheck %s --check-prefix=FISSION
; RUN: opt -passes='loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+d,+f -force-vector-width=4 -S %s | FileCheck %s --check-prefix=NORMAL
;
; Reduction VF is independent of Map VF: RVV m8 = nxv16f32/nxv8f64/
; nxv16i32. These checks require vector accumulator updates and final collapse.
; NORMAL-NOT: fission.reduce

target triple = "riscv64-unknown-linux-gnu"

; FISSION-LABEL: define float @sum_f32(
; FISSION: fission.reduce.preheader
; FISSION: phi <vscale x 16 x float>
; FISSION: fadd{{.*}}<vscale x 16 x float>
; FISSION: @llvm.vector.reduce.fadd.nxv16
define float @sum_f32(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, float %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi float [ %init, %preheader ], [ %next, %loop ]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %next = fadd fast float %acc, %x
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [ %init, %entry ], [ %next, %loop ]
  ret float %result
}

; FISSION-LABEL: define double @sum_f64(
; FISSION: fission.reduce.preheader
; FISSION: phi <vscale x 8 x double>
; FISSION: fadd{{.*}}<vscale x 8 x double>
; FISSION: @llvm.vector.reduce.fadd.nxv8
define double @sum_f64(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, double %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi double [ %init, %preheader ], [ %next, %loop ]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p, align 8
  %next = fadd fast double %acc, %x
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi double [ %init, %entry ], [ %next, %loop ]
  ret double %result
}

; FISSION-LABEL: define float @dot_f32(
; FISSION: fission.reduce.preheader
; FISSION: phi <vscale x 16 x float>
; FISSION: fadd{{.*}}<vscale x 16 x float>
; FISSION: @llvm.vector.reduce.fadd.nxv16
define float @dot_f32(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, float %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi float [ %init, %preheader ], [ %next, %loop ]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %product = fmul fast float %x, %y
  %next = fadd fast float %acc, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [ %init, %entry ], [ %next, %loop ]
  ret float %result
}

; FISSION-LABEL: define double @dot_f64(
; FISSION: fission.reduce.preheader
; FISSION: phi <vscale x 8 x double>
; FISSION: fadd{{.*}}<vscale x 8 x double>
; FISSION: @llvm.vector.reduce.fadd.nxv8
define double @dot_f64(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, double %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi double [ %init, %preheader ], [ %next, %loop ]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p, align 8
  %q = getelementptr double, ptr %b, i64 %i
  %y = load double, ptr %q, align 8
  %product = fmul fast double %x, %y
  %next = fadd fast double %acc, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi double [ %init, %entry ], [ %next, %loop ]
  ret double %result
}

; FISSION-LABEL: define i16 @add_i16(
; FISSION: fission.reduce.preheader
; FISSION: phi <vscale x 32 x i16>
; FISSION: add{{.*}}<vscale x 32 x i16>
; FISSION: @llvm.vector.reduce.add.nxv32
define i16 @add_i16(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, i16 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi i16 [ %init, %preheader ], [ %next, %loop ]
  %p = getelementptr i16, ptr %a, i64 %i
  %x = load i16, ptr %p, align 2
  %next = add i16 %acc, %x
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i16 [ %init, %entry ], [ %next, %loop ]
  ret i16 %result
}

; FISSION-LABEL: define i32 @widen_i16_i32(
; FISSION: fission.reduce.preheader
; FISSION: phi <vscale x 16 x i32>
; FISSION: add{{.*}}<vscale x 16 x i32>
; FISSION: @llvm.vector.reduce.add.nxv16
define i32 @widen_i16_i32(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, i32 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi i32 [ %init, %preheader ], [ %next, %loop ]
  %p = getelementptr i16, ptr %a, i64 %i
  %x = load i16, ptr %p, align 2
  %wide = sext i16 %x to i32
  %next = add i32 %acc, %wide
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %init, %entry ], [ %next, %loop ]
  ret i32 %result
}

; FISSION-LABEL: define double @widen_f32_f64(
; FISSION: fission.reduce.preheader
; FISSION: phi <vscale x 8 x double>
; FISSION: fadd{{.*}}<vscale x 8 x double>
; FISSION: @llvm.vector.reduce.fadd.nxv8
define double @widen_f32_f64(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, double %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi double [ %init, %preheader ], [ %next, %loop ]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %wide = fpext float %x to double
  %next = fadd fast double %acc, %wide
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi double [ %init, %entry ], [ %next, %loop ]
  ret double %result
}

; FISSION-LABEL: define i32 @add_i32(
; FISSION: fission.reduce.preheader
; FISSION: phi <vscale x 16 x i32>
; FISSION: add{{.*}}<vscale x 16 x i32>
; FISSION: @llvm.vector.reduce.add.nxv16
define i32 @add_i32(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, i32 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi i32 [ %init, %preheader ], [ %next, %loop ]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p, align 4
  %next = add i32 %acc, %x
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %init, %entry ], [ %next, %loop ]
  ret i32 %result
}

; FISSION-LABEL: define i32 @and_i32(
; FISSION: fission.reduce.preheader
; FISSION: phi <vscale x 16 x i32>
; FISSION: and{{.*}}<vscale x 16 x i32>
; FISSION: @llvm.vector.reduce.and.nxv16
define i32 @and_i32(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, i32 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi i32 [ %init, %preheader ], [ %next, %loop ]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p, align 4
  %next = and i32 %acc, %x
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %init, %entry ], [ %next, %loop ]
  ret i32 %result
}

; FISSION-LABEL: define i32 @or_i32(
; FISSION: fission.reduce.preheader
; FISSION: phi <vscale x 16 x i32>
; FISSION: or{{.*}}<vscale x 16 x i32>
; FISSION: @llvm.vector.reduce.or.nxv16
define i32 @or_i32(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, i32 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi i32 [ %init, %preheader ], [ %next, %loop ]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p, align 4
  %next = or i32 %acc, %x
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %init, %entry ], [ %next, %loop ]
  ret i32 %result
}

; FISSION-LABEL: define i32 @xor_i32(
; FISSION: fission.reduce.preheader
; FISSION: phi <vscale x 16 x i32>
; FISSION: xor{{.*}}<vscale x 16 x i32>
; FISSION: @llvm.vector.reduce.xor.nxv16
define i32 @xor_i32(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, i32 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi i32 [ %init, %preheader ], [ %next, %loop ]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p, align 4
  %next = xor i32 %acc, %x
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %init, %entry ], [ %next, %loop ]
  ret i32 %result
}

; FISSION-LABEL: define i32 @smin_i32(
; FISSION: fission.reduce.preheader
; FISSION: phi <vscale x 16 x i32>
; FISSION: llvm.smin{{.*}}<vscale x 16 x i32>
; FISSION: @llvm.vector.reduce.smin.nxv16
define i32 @smin_i32(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, i32 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi i32 [ %init, %preheader ], [ %next, %loop ]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p, align 4
  %next = call i32 @llvm.smin.i32(i32 %acc, i32 %x)
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %init, %entry ], [ %next, %loop ]
  ret i32 %result
}

; FISSION-LABEL: define i32 @smax_i32(
; FISSION: fission.reduce.preheader
; FISSION: phi <vscale x 16 x i32>
; FISSION: llvm.smax{{.*}}<vscale x 16 x i32>
; FISSION: @llvm.vector.reduce.smax.nxv16
define i32 @smax_i32(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, i32 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi i32 [ %init, %preheader ], [ %next, %loop ]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p, align 4
  %next = call i32 @llvm.smax.i32(i32 %acc, i32 %x)
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %init, %entry ], [ %next, %loop ]
  ret i32 %result
}

; FISSION-LABEL: define i32 @umin_i32(
; FISSION: fission.reduce.preheader
; FISSION: phi <vscale x 16 x i32>
; FISSION: llvm.umin{{.*}}<vscale x 16 x i32>
; FISSION: @llvm.vector.reduce.umin.nxv16
define i32 @umin_i32(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, i32 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi i32 [ %init, %preheader ], [ %next, %loop ]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p, align 4
  %next = call i32 @llvm.umin.i32(i32 %acc, i32 %x)
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %init, %entry ], [ %next, %loop ]
  ret i32 %result
}

; FISSION-LABEL: define i32 @umax_i32(
; FISSION: fission.reduce.preheader
; FISSION: phi <vscale x 16 x i32>
; FISSION: llvm.umax{{.*}}<vscale x 16 x i32>
; FISSION: @llvm.vector.reduce.umax.nxv16
define i32 @umax_i32(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, i32 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi i32 [ %init, %preheader ], [ %next, %loop ]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p, align 4
  %next = call i32 @llvm.umax.i32(i32 %acc, i32 %x)
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %init, %entry ], [ %next, %loop ]
  ret i32 %result
}

; FISSION-LABEL: define float @min_f32(
; FISSION: fission.reduce.preheader
; FISSION: phi <vscale x 16 x float>
; FISSION: llvm.minnum{{.*}}<vscale x 16 x float>
; FISSION: @llvm.vector.reduce.fmin.nxv16
define float @min_f32(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, float %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi float [ %init, %preheader ], [ %next, %loop ]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %next = call fast float @llvm.minnum.f32(float %acc, float %x)
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [ %init, %entry ], [ %next, %loop ]
  ret float %result
}

; FISSION-LABEL: define double @max_f64(
; FISSION: fission.reduce.preheader
; FISSION: phi <vscale x 8 x double>
; FISSION: llvm.maxnum{{.*}}<vscale x 8 x double>
; FISSION: @llvm.vector.reduce.fmax.nxv8
define double @max_f64(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, double %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi double [ %init, %preheader ], [ %next, %loop ]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p, align 8
  %next = call fast double @llvm.maxnum.f64(double %acc, double %x)
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi double [ %init, %entry ], [ %next, %loop ]
  ret double %result
}

; FISSION-LABEL: define float @conditional_f32(
; FISSION: fission.reduce.preheader
; FISSION: phi <vscale x 16 x float>
; FISSION: fadd{{.*}}<vscale x 16 x float>
; FISSION: @llvm.vector.reduce.fadd.nxv16
define float @conditional_f32(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, float %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi float [ %init, %preheader ], [ %next, %loop ]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %positive = fcmp ogt float %x, 0.0
  %contribution = select i1 %positive, float %x, float 0.0
  %next = fadd fast float %acc, %contribution
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [ %init, %entry ], [ %next, %loop ]
  ret float %result
}

; FISSION-LABEL: define float @fmuladd_f32(
; FISSION: fission.reduce.preheader
; FISSION: phi <vscale x 16 x float>
; FISSION: llvm.fmuladd{{.*}}<vscale x 16 x float>
; FISSION: @llvm.vector.reduce.fadd.nxv16
define float @fmuladd_f32(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, float %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi float [ %init, %preheader ], [ %next, %loop ]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %next = call fast float @llvm.fmuladd.f32(float %x, float %y, float %acc)
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [ %init, %entry ], [ %next, %loop ]
  ret float %result
}

; Two independent accumulators must produce two separate reduction loops.
; FISSION-LABEL: define void @independent(
; FISSION: fission.reduce.preheader
; FISSION: phi <vscale x 16 x float>
; FISSION: @llvm.vector.reduce.fadd.nxv16f32
; FISSION: fission.reduce.preheader
; FISSION: phi <vscale x 16 x float>
; FISSION: @llvm.vector.reduce.fadd.nxv16f32
define void @independent(ptr noalias readonly %a, ptr noalias readonly %b, ptr noalias %out, i64 %n, float %init0, float %init1) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc0 = phi float [ %init0, %preheader ], [ %next0, %loop ]
  %acc1 = phi float [ %init1, %preheader ], [ %next1, %loop ]
  %p = getelementptr float, ptr %a, i64 %i
  %q = getelementptr float, ptr %b, i64 %i
  %x = load float, ptr %p, align 4
  %y = load float, ptr %q, align 4
  %next0 = fadd fast float %acc0, %x
  %product = fmul fast float %x, %y
  %next1 = fadd fast float %acc1, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %r0 = phi float [ %init0, %entry ], [ %next0, %loop ]
  %r1 = phi float [ %init1, %entry ], [ %next1, %loop ]
  store float %r0, ptr %out
  %out1 = getelementptr float, ptr %out, i64 1
  store float %r1, ptr %out1
  ret void
}

; FISSION-LABEL: define float @observed_intermediate(
; FISSION-NOT: fission.reduce
; FISSION: ret float
define float @observed_intermediate(ptr noalias readonly %a, ptr noalias %b, i64 %n, float %init) {
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
  %next = fadd fast float %acc, %x
  store float %next, ptr %q, align 4
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [ %init, %entry ], [ %next, %loop ]
  ret float %result
}

; FISSION-LABEL: define float @cross_accumulator(
; FISSION-NOT: fission.reduce
; FISSION: ret float
define float @cross_accumulator(ptr noalias readonly %a, ptr noalias %b, i64 %n, float %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi float [ %init, %preheader ], [ %next, %loop ]
  %other = phi float [ 0.0, %preheader ], [ %other.next, %loop ]
  %p = getelementptr float, ptr %a, i64 %i
  %q = getelementptr float, ptr %b, i64 %i
  %x = load float, ptr %p, align 4
  %next = fadd fast float %acc, %x
  %other.next = fadd fast float %other, %next
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [ %init, %entry ], [ %next, %loop ]
  %other.result = phi float [ 0.0, %entry ], [ %other.next, %loop ]
  %combined = fadd fast float %result, %other.result
  ret float %combined
}

; FISSION-LABEL: define float @remaining_recurrence(
; FISSION-NOT: fission.reduce
; FISSION: ret float
define float @remaining_recurrence(ptr noalias readonly %a, ptr noalias %b, i64 %n, float %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi float [ %init, %preheader ], [ %next, %loop ]
  %rec = phi float [ 1.0, %preheader ], [ %rec.next, %loop ]
  %p = getelementptr float, ptr %a, i64 %i
  %q = getelementptr float, ptr %b, i64 %i
  %x = load float, ptr %p, align 4
  %next = fadd fast float %acc, %x
  %rec.next = fdiv float %x, %rec
  store float %rec.next, ptr %q, align 4
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [ %init, %entry ], [ %next, %loop ]
  ret float %result
}

; FISSION-LABEL: define float @strict_fp(
; FISSION-NOT: fission.reduce
; FISSION: ret float
define float @strict_fp(ptr noalias readonly %a, ptr noalias %b, i64 %n, float %init) {
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
  %next = fadd float %acc, %x
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [ %init, %entry ], [ %next, %loop ]
  ret float %result
}

declare i32 @llvm.smin.i32(i32, i32)
declare i32 @llvm.smax.i32(i32, i32)
declare i32 @llvm.umin.i32(i32, i32)
declare i32 @llvm.umax.i32(i32, i32)
declare float @llvm.minnum.f32(float, float)
declare double @llvm.maxnum.f64(double, double)
declare float @llvm.fmuladd.f32(float, float, float)
