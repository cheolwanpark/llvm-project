; RUN: opt -passes='loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -force-vector-width=fission:2 -scalable-vectorization=on -S %s | FileCheck %s
;
; An nnan/nsz min operation is not evaluated on a skipped path. Its flags do
; not constrain an arbitrary initial value when every update is skipped.
; CHECK-LABEL: define float @conditional_minmax(
; CHECK: call noalias ptr @malloc
; CHECK-NOT: @malloc
; CHECK: phi <vscale x 16 x float>
; CHECK: @llvm.vector.reduce.fmin.nxv16f32
; CHECK: @llvm.is.fpclass.f32
; CHECK: select i1
; CHECK: ret float

define float @conditional_minmax(ptr noalias readonly %a, ptr noalias readonly %flags, i64 %n, float %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %latch]
  %acc = phi float [%init, %pre], [%next, %latch]
  %pf = getelementptr i8, ptr %flags, i64 %i
  %flag = load i8, ptr %pf, align 1
  %active = icmp ne i8 %flag, 0
  br i1 %active, label %update, label %latch
update:
  %pa = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %pa, align 4
  %v = call nnan nsz float @llvm.minnum.f32(float %acc, float %x)
  br label %latch
latch:
  %next = phi float [%acc, %loop], [%v, %update]
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%init, %entry], [%next, %latch]
  ret float %result
}

declare float @llvm.minnum.f32(float, float)

; A finite initializer needs no special-value correction. Only the scalar
; contribution crosses the boundary; the predicate stays in Map.
; CHECK-LABEL: define float @conditional_minmax_finite(
; CHECK: call noalias ptr @malloc
; CHECK-NOT: @malloc
; CHECK: phi <vscale x 16 x float>
; CHECK: @llvm.vp.load.nxv16f32{{.*}}<vscale x 16 x i1> splat (i1 true)
; CHECK: @llvm.vector.reduce.fmin.nxv16f32
; CHECK: ret float
define float @conditional_minmax_finite(ptr noalias readonly %a, ptr noalias readonly %flags, i64 %n, float %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %latch]
  %acc = phi float [1.0, %pre], [%next, %latch]
  %pf = getelementptr i8, ptr %flags, i64 %i
  %flag = load i8, ptr %pf, align 1
  %active = icmp ne i8 %flag, 0
  br i1 %active, label %update, label %latch
update:
  %pa = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %pa, align 4
  %v = call nnan nsz float @llvm.minnum.f32(float %acc, float %x)
  br label %latch
latch:
  %next = phi float [%acc, %loop], [%v, %update]
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [1.0, %entry], [%next, %latch]
  ret float %result
}

; Positive zero also has an observable sign when all updates are skipped.
; CHECK-LABEL: define float @conditional_minmax_zero(
; CHECK: call noalias ptr @malloc
; CHECK-NOT: @malloc
; CHECK: phi <vscale x 16 x float>
; CHECK: @llvm.vector.reduce.fmin.nxv16f32
; CHECK: @llvm.is.fpclass.f32
; CHECK: select i1
; CHECK: ret float
define float @conditional_minmax_zero(ptr noalias readonly %a, ptr noalias readonly %flags, i64 %n, float %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %latch]
  %acc = phi float [0.0, %pre], [%next, %latch]
  %pf = getelementptr i8, ptr %flags, i64 %i
  %flag = load i8, ptr %pf, align 1
  %active = icmp ne i8 %flag, 0
  br i1 %active, label %update, label %latch
update:
  %pa = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %pa, align 4
  %v = call nnan nsz float @llvm.minnum.f32(float %acc, float %x)
  br label %latch
latch:
  %next = phi float [%acc, %loop], [%v, %update]
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [0.0, %entry], [%next, %latch]
  ret float %result
}

; ninf requires the largest finite identity rather than infinity. Restoring
; exceptional initializers and zero signs takes place after the data collapse.
; CHECK-LABEL: define float @conditional_minmax_ninf(
; CHECK: call noalias ptr @malloc
; CHECK-NOT: @malloc
; CHECK: float 0x47EFFFFFE0000000
; CHECK: phi <vscale x 16 x float>
; CHECK: @llvm.vector.reduce.fmin.nxv16f32
; CHECK: @llvm.is.fpclass.f32
; CHECK: select i1
; CHECK: ret float
define float @conditional_minmax_ninf(ptr noalias readonly %a, ptr noalias readonly %flags, i64 %n, float %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %latch]
  %acc = phi float [%init, %pre], [%next, %latch]
  %pf = getelementptr i8, ptr %flags, i64 %i
  %flag = load i8, ptr %pf, align 1
  %active = icmp ne i8 %flag, 0
  br i1 %active, label %update, label %latch
update:
  %pa = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %pa, align 4
  %v = call fast float @llvm.minnum.f32(float %acc, float %x)
  br label %latch
latch:
  %next = phi float [%acc, %loop], [%v, %update]
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%init, %entry], [%next, %latch]
  ret float %result
}
