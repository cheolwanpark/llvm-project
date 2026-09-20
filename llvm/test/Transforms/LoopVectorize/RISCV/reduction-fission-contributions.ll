; RUN: opt -passes='loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -force-vector-width=fission:2 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -S %s | FileCheck %s
;
; Commuted expressions and reordered PHI inputs share storage, never
; accumulator loops. Conditional
; expressions are projected at their original join; a skipped update does not
; grant nnan/ninf/nsz for the accumulator's identity combination.

target triple = "riscv64-unknown-linux-gnu"

; CHECK-LABEL: define void @shared_pair(
; CHECK: call noalias ptr @malloc
; CHECK-NOT: @malloc
; CHECK: fission.reduce.preheader
; CHECK: phi <vscale x 16 x float>
; CHECK: @llvm.vector.reduce.fadd.nxv16f32
; CHECK: phi <vscale x 16 x float>
; CHECK: @llvm.vector.reduce.fadd.nxv16f32
; CHECK: @free
; CHECK-NOT: @free
; CHECK: ret void
define void @shared_pair(ptr noalias readonly %a, ptr noalias readonly %b, ptr noalias %out, i64 %n, float %init0, float %init1) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %s0 = phi float [%init0, %pre], [%n0, %loop]
  %s1 = phi float [%init1, %pre], [%n1, %loop]
  %pa = getelementptr float, ptr %a, i64 %i
  %pb = getelementptr float, ptr %b, i64 %i
  %x = load float, ptr %pa, align 4
  %y = load float, ptr %pb, align 4
  %p0 = fadd reassoc float %s0, %x
  %n0 = fadd reassoc float %p0, %y
  %p1 = fadd reassoc float %s1, %y
  %n1 = fadd reassoc float %p1, %x
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %r0 = phi float [%init0, %entry], [%n0, %loop]
  %r1 = phi float [%init1, %entry], [%n1, %loop]
  %o1 = getelementptr float, ptr %out, i64 1
  store float %r0, ptr %out
  store float %r1, ptr %o1
  ret void
}

; CHECK-LABEL: define void @shared_guarded(
; CHECK: call noalias ptr @malloc
; CHECK-NOT: @malloc
; CHECK: @llvm.{{(masked|vp)}}.load.nxv2f32{{.*}}<vscale x 2 x i1> %
; CHECK: fission.reduce.preheader
; CHECK: phi <vscale x 16 x float>
; CHECK: fadd reassoc arcp contract afn <vscale x 16 x float>
; CHECK: @llvm.vector.reduce.fadd.nxv16f32
; CHECK: @llvm.is.fpclass.f32(float [[INIT0:%[^,]+]], i32 3)
; CHECK: select i1 %{{[^,]+}}, float [[INIT0]], float %
; CHECK: phi <vscale x 16 x float>
; CHECK: fadd reassoc arcp contract afn <vscale x 16 x float>
; CHECK: @llvm.vector.reduce.fadd.nxv16f32
; CHECK: @llvm.is.fpclass.f32(float [[INIT1:%[^,]+]], i32 3)
; CHECK: select i1 %{{[^,]+}}, float [[INIT1]], float %
; CHECK: @free
; CHECK-NOT: @free
; CHECK: ret void
define void @shared_guarded(ptr noalias readonly %a, ptr noalias readonly %b, ptr noalias readonly %flags, ptr noalias %out, i64 %n, float %init0, float %init1) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %latch]
  %s0 = phi float [%init0, %pre], [%n0, %latch]
  %s1 = phi float [%init1, %pre], [%n1, %latch]
  %pf = getelementptr i8, ptr %flags, i64 %i
  %flag = load i8, ptr %pf, align 1
  %active = icmp ne i8 %flag, 0
  br i1 %active, label %update, label %latch
update:
  %pa = getelementptr float, ptr %a, i64 %i
  %pb = getelementptr float, ptr %b, i64 %i
  %x = load float, ptr %pa, align 4
  %y = load float, ptr %pb, align 4
  %p0 = fadd fast float %s0, %x
  %v0 = fadd fast float %p0, %y
  %p1 = fadd fast float %s1, %x
  %v1 = fadd fast float %p1, %y
  br label %latch
latch:
  %n0 = phi float [%s0, %loop], [%v0, %update]
  %n1 = phi float [%v1, %update], [%s1, %loop]
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %r0 = phi float [%init0, %entry], [%n0, %latch]
  %r1 = phi float [%init1, %entry], [%n1, %latch]
  %o1 = getelementptr float, ptr %out, i64 1
  store float %r0, ptr %out
  store float %r1, ptr %o1
  ret void
}

; The poison produced by the unselected fast addition must remain unobserved.
; CHECK-LABEL: define float @selected_contribution(
; CHECK: call noalias ptr @malloc
; CHECK-NOT: @malloc
; CHECK: select <vscale x 2 x i1>
; CHECK: fission.reduce.preheader
; CHECK: phi <vscale x 16 x float>
; CHECK: fadd reassoc arcp contract afn <vscale x 16 x float>
; CHECK: @llvm.vector.reduce.fadd
; CHECK: @free
; CHECK-NOT: @free
; CHECK: ret float
define float @selected_contribution(ptr noalias readonly %a, ptr noalias readonly %flags, i64 %n, float %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %acc = phi float [%init, %pre], [%next, %loop]
  %pa = getelementptr float, ptr %a, i64 %i
  %pf = getelementptr i8, ptr %flags, i64 %i
  %x = load float, ptr %pa, align 4
  %flag = load i8, ptr %pf, align 1
  %active = icmp ne i8 %flag, 0
  %sum = fadd fast float %acc, %x
  %next = select i1 %active, float %sum, float %acc
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%init, %entry], [%next, %loop]
  ret float %result
}

; CHECK-LABEL: define i32 @conditional_division(
; CHECK: call noalias ptr @malloc
; CHECK-NOT: @malloc
; CHECK: fission.reduce.preheader
; CHECK: phi <vscale x 16 x i32>
; CHECK-NOT: udiv
; CHECK: @llvm.vector.reduce.add.nxv16i32
; CHECK: @free
; CHECK-NOT: @free
; CHECK: ret i32
define i32 @conditional_division(ptr noalias readonly %denoms, ptr noalias readonly %flags, i64 %n, i32 %init, i32 %num) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %latch]
  %acc = phi i32 [%init, %pre], [%next, %latch]
  %pf = getelementptr i8, ptr %flags, i64 %i
  %flag = load i8, ptr %pf, align 1
  %active = icmp ne i8 %flag, 0
  br i1 %active, label %update, label %latch
update:
  %pd = getelementptr i32, ptr %denoms, i64 %i
  %den = load i32, ptr %pd, align 4
  %q = udiv i32 %num, %den
  %sum = add i32 %acc, %q
  br label %latch
latch:
  %next = phi i32 [%acc, %loop], [%sum, %update]
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%init, %entry], [%next, %latch]
  ret i32 %result
}

; RUN: opt -passes='loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -force-vector-width=fission:2 -scalable-vectorization=on -pass-remarks-analysis=loop-vectorize -disable-output %s 2>&1 | FileCheck %s --check-prefix=PLAN
; PLAN: reduction 0 accumulator=%s0 initial=%init0 type=float: homogeneous associative scalar contribution; scratch streams=1; borrowed streams=0; shared contribution=false
; PLAN: reduction 1 accumulator=%s1 initial=%init1 type=float: homogeneous associative scalar contribution; scratch streams=1; borrowed streams=0; shared contribution=true
; PLAN: reduction 0 accumulator=%s0 initial=%init0 type=float: conditional scalar contribution with identity; scratch streams=1; borrowed streams=0; shared contribution=false
; PLAN: reduction 1 accumulator=%s1 initial=%init1 type=float: conditional scalar contribution with identity; scratch streams=1; borrowed streams=0; shared contribution=true
