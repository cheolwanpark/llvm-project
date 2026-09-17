; RUN: opt -passes='loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -force-vector-width=fission:4 -scalable-vectorization=off -S %s | FileCheck %s
;
; Compiler-generated heap calls require available builtins. Stack scratch
; does not create calls to disabled builtins. Dynamic heap overflow/failure
; retains the original checked trap path.
target triple = "riscv64-unknown-linux-gnu"

; CHECK-LABEL: define float @no_builtins_fixed(
; CHECK: alloca float, i64 64
; CHECK-NOT: @malloc
; CHECK: fission.reduce.preheader
; CHECK: @llvm.vector.reduce.fadd
; CHECK-NOT: @free
; CHECK: ret float
define float @no_builtins_fixed(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, float %init) "no-builtins" {
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
  %done = icmp eq i64 %inc, 64
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [ %init, %entry ], [ %next, %loop ]
  ret float %result
}

; CHECK-LABEL: define float @no_builtins_dynamic(
; CHECK-NOT: fission
; CHECK-NOT: @malloc
; CHECK: ret float
define float @no_builtins_dynamic(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, float %init) "no-builtins" {
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

; CHECK-LABEL: define float @heap_overflow(
; CHECK: %fission.count = add i64
; CHECK: icmp eq i64 %fission.count, 0
; CHECK: @llvm.umul.with.overflow.i64(i64 %fission.count, i64 4)
; CHECK: label %fission.allocation.failure
; CHECK: call noalias ptr @malloc
; CHECK: icmp eq ptr %fission.buffer, null
; CHECK: label %fission.allocation.failure
; CHECK: fission.allocation.failure:
; CHECK-NEXT: call void @llvm.trap
; CHECK-NEXT: unreachable
; CHECK: @free
; CHECK: ret float
define float @heap_overflow(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, float %init) {
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
