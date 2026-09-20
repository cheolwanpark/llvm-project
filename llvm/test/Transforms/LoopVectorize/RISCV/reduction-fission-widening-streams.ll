; RUN: opt -passes='loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -force-vector-width=fission:2 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -S %s | FileCheck %s --implicit-check-not=@malloc --implicit-check-not=@free --implicit-check-not='= alloca'
;
; Exact extensions permit reusing the original narrower stream. Signed and
; unsigned decoding must stay distinct. Each accumulator keeps its own largest
; legal VF, including when both read the same underlying bytes.

target triple = "riscv64-unknown-linux-gnu"

; CHECK-LABEL: define void @signed_unsigned_widening(
; CHECK: phi <vscale x 16 x i32>
; CHECK: @llvm.vp.load.nxv16i8
; CHECK: sext <vscale x 16 x i8>
; CHECK: @llvm.vector.reduce.add.nxv16i32
; CHECK: phi <vscale x 16 x i32>
; CHECK: @llvm.vp.load.nxv16i8
; CHECK: zext <vscale x 16 x i8>
; CHECK: @llvm.vector.reduce.add.nxv16i32
; CHECK: ret void
define void @signed_unsigned_widening(ptr noalias readonly %a, ptr noalias %out, i64 %n, i32 %init0, i32 %init1) "no-builtins" {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %s0 = phi i32 [%init0, %pre], [%n0, %loop]
  %s1 = phi i32 [%init1, %pre], [%n1, %loop]
  %p = getelementptr inbounds nuw i8, ptr %a, i64 %i
  %x = load i8, ptr %p, align 1
  %signed = sext i8 %x to i32
  %unsigned = zext i8 %x to i32
  %n0 = add i32 %s0, %signed
  %n1 = add i32 %s1, %unsigned
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %r0 = phi i32 [%init0, %entry], [%n0, %loop]
  %r1 = phi i32 [%init1, %entry], [%n1, %loop]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %r0, ptr %out
  store i32 %r1, ptr %o1
  ret void
}

; CHECK-LABEL: define void @mixed_widening(
; CHECK: phi <vscale x 16 x float>
; CHECK: @llvm.vp.load.nxv16f32
; CHECK: @llvm.vector.reduce.fadd.nxv16f32
; CHECK: phi <vscale x 8 x double>
; CHECK: @llvm.vp.load.nxv8f32
; CHECK: fpext <vscale x 8 x float>
; CHECK: @llvm.vector.reduce.fadd.nxv8f64
; CHECK: ret void
define void @mixed_widening(ptr noalias readonly %a, ptr noalias %out, i64 %n, float %init0, double %init1) "no-builtins" {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %s0 = phi float [%init0, %pre], [%n0, %loop]
  %s1 = phi double [%init1, %pre], [%n1, %loop]
  %p = getelementptr inbounds nuw float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %wide = fpext float %x to double
  %n0 = fadd reassoc float %s0, %x
  %n1 = fadd reassoc double %s1, %wide
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %r0 = phi float [%init0, %entry], [%n0, %loop]
  %r1 = phi double [%init1, %entry], [%n1, %loop]
  %wideout = fpext float %r0 to double
  %o1 = getelementptr double, ptr %out, i64 1
  store double %wideout, ptr %out
  store double %r1, ptr %o1
  ret void
}
