; RUN: opt -passes='loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -force-vector-width=fission:2 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -S %s | FileCheck %s --implicit-check-not=@malloc --implicit-check-not=@free --implicit-check-not='= alloca'
;
; Reusing read-only streams and invariant contributions needs no scratch.
; Map may be absent only when it has neither effects nor live-outs. Deleting
; it must not combine the independent reducers or consume the initial value.

target triple = "riscv64-unknown-linux-gnu"

; CHECK-LABEL: define float @readonly_sum(
; CHECK: br i1 %empty, label %exit, label %pre
; CHECK-NOT: loop:
; CHECK: fission.reduce.preheader
; CHECK: phi <vscale x 16 x float>
; CHECK: @llvm.experimental.get.vector.length
; CHECK: @llvm.vp.load.nxv16f32
; CHECK: fadd reassoc <vscale x 16 x float>
; CHECK: @llvm.vector.reduce.fadd.nxv16f32
; CHECK: ret float
define float @readonly_sum(ptr noalias readonly %a, i64 %n, float %init) "no-builtins" {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %acc = phi float [%init, %pre], [%next, %loop]
  %p = getelementptr inbounds nuw float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %next = fadd reassoc float %acc, %x
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %r = phi float [%init, %entry], [%next, %loop]
  ret float %r
}

; A single input is reused by two reducers. A complete collapse separates them.
; CHECK-LABEL: define void @readonly_minmax(
; CHECK-NOT: loop:
; CHECK: phi <vscale x 16 x float>
; CHECK: @llvm.vp.load.nxv16f32
; CHECK: @llvm.vector.reduce.f{{(min|max)}}
; CHECK: phi <vscale x 16 x float>
; CHECK: @llvm.vp.load.nxv16f32
; CHECK: @llvm.vector.reduce.f{{(min|max)}}
; CHECK: ret void
define void @readonly_minmax(ptr noalias readonly %a, ptr noalias %out, float %mininit, float %maxinit) #0 {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%inc, %loop]
  %min = phi float [%mininit, %entry], [%minnext, %loop]
  %max = phi float [%maxinit, %entry], [%maxnext, %loop]
  %p = getelementptr inbounds nuw float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %minnext = call nnan nsz float @llvm.minnum.f32(float %min, float %x)
  %maxnext = call nnan nsz float @llvm.maxnum.f32(float %max, float %x)
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 31
  br i1 %done, label %exit, label %loop
exit:
  %rmin = phi float [%minnext, %loop]
  %rmax = phi float [%maxnext, %loop]
  %o = getelementptr float, ptr %out, i64 1
  store float %rmin, ptr %out
  store float %rmax, ptr %o
  ret void
}

; CHECK-LABEL: define float @invariant(
; CHECK-NOT: loop:
; CHECK: phi <vscale x 16 x float>
; CHECK: fadd reassoc <vscale x 16 x float>
; CHECK: @llvm.vector.reduce.fadd.nxv16f32
; CHECK: ret float
define float @invariant(i64 %n, float %init, float %value) "no-builtins" {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %acc = phi float [%init, %pre], [%next, %loop]
  %next = fadd reassoc float %acc, %value
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %r = phi float [%init, %entry], [%next, %loop]
  ret float %r
}

; Invariant chain normalization is materialized once at entry, without N stores.
; CHECK-LABEL: define double @invariant_chain(
; CHECK: pre:
; CHECK: %fission.contribution = fadd reassoc double %x, %y
; CHECK-NOT: loop:
; CHECK: phi <vscale x 8 x double>
; CHECK: fadd reassoc <vscale x 8 x double>
; CHECK: @llvm.vector.reduce.fadd.nxv8f64
; CHECK: ret double
define double @invariant_chain(i64 %n, double %init, double %x, double %y) "no-builtins" {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %acc = phi double [%init, %pre], [%next, %loop]
  %partial = fadd reassoc double %acc, %x
  %next = fadd reassoc double %partial, %y
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %r = phi double [%init, %entry], [%next, %loop]
  ret double %r
}

; An invariant reducer cannot remove the observable Map store.
; CHECK-LABEL: define float @invariant_with_map(
; CHECK: @llvm.vp.store.nxv2i64
; CHECK: fission.reduce.preheader
; CHECK: phi <vscale x 16 x float>
; CHECK: @llvm.vector.reduce.fadd.nxv16f32
; CHECK: ret float
define float @invariant_with_map(ptr noalias %out, i64 %n, float %init, float %value) "no-builtins" {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %acc = phi float [%init, %pre], [%next, %loop]
  %p = getelementptr inbounds nuw i64, ptr %out, i64 %i
  store i64 %i, ptr %p, align 8
  %next = fadd reassoc float %acc, %value
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %r = phi float [%init, %entry], [%next, %loop]
  ret float %r
}

declare float @llvm.minnum.f32(float, float)
declare float @llvm.maxnum.f32(float, float)
attributes #0 = { vscale_range(2,1024) }

; The original induction has a live-out as well as the reducer. It must not be
; replaced with poison when reusing the stream, even if all Map loads are dead.
; CHECK-LABEL: define void @readonly_liveout(
; CHECK: fission.reduce.preheader
; CHECK: store i64 %{{[^,]+}}, ptr %indexout
; CHECK: ret void
define void @readonly_liveout(ptr noalias readonly %a, ptr noalias %out, ptr noalias %indexout, i64 %n, float %init) "no-builtins" {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %acc = phi float [%init, %pre], [%next, %loop]
  %p = getelementptr inbounds nuw float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %next = fadd reassoc float %acc, %x
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %r = phi float [%init, %entry], [%next, %loop]
  %last = phi i64 [-1, %entry], [%i, %loop]
  store float %r, ptr %out
  store i64 %last, ptr %indexout
  ret void
}

; Removing the inner empty Map must preserve its parent LoopInfo and the outer
; iteration's initial value. No scratch or lifetime is introduced.
; CHECK-LABEL: define void @nested_readonly(
; CHECK: outer:
; CHECK: phi <vscale x 16 x float>
; CHECK: @llvm.vector.reduce.fadd.nxv16f32
; CHECK: store float
; CHECK: ret void
define void @nested_readonly(ptr noalias readonly %a, ptr noalias %out, i64 %n, i64 %repeats, float %init) "no-builtins" {
entry:
  %empty = icmp eq i64 %repeats, 0
  br i1 %empty, label %exit, label %outer
outer:
  %j = phi i64 [0, %entry], [%jn, %inner.exit]
  %noinner = icmp eq i64 %n, 0
  br i1 %noinner, label %inner.exit, label %pre
pre:
  br label %inner
inner:
  %i = phi i64 [0, %pre], [%inc, %inner]
  %acc = phi float [%init, %pre], [%next, %inner]
  %p = getelementptr inbounds nuw float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %next = fadd reassoc float %acc, %x
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %inner.exit, label %inner
inner.exit:
  %r = phi float [%init, %outer], [%next, %inner]
  %o = getelementptr float, ptr %out, i64 %j
  store float %r, ptr %o, align 4
  %jn = add nuw i64 %j, 1
  %last = icmp eq i64 %jn, %repeats
  br i1 %last, label %exit, label %outer
exit:
  ret void
}

; With no owned allocation, a full-width iteration count cannot use allocation
; failure as an excuse to trap. Retain this original recurrence when its 2^64
; iterations cannot be represented in the generated reducer index.
; CHECK-LABEL: define float @full_width_trip(
; CHECK-NOT: fission
; CHECK-NOT: @llvm.trap
; CHECK: %next = fadd reassoc float %acc, %step
; CHECK: ret float
define float @full_width_trip(float %init, float %step) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%inc, %loop]
  %acc = phi float [%init, %entry], [%next, %loop]
  %next = fadd reassoc float %acc, %step
  %inc = add i64 %i, 1
  %done = icmp eq i64 %inc, 0
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%next, %loop]
  ret float %result
}
