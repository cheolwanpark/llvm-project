; RUN: opt -passes='loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -force-vector-width=fission:4 -scalable-vectorization=off -verify-dom-info -verify-loop-info -verify-scev -S %s | FileCheck %s
; RUN: opt -passes='loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -force-vector-width=fission:2 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -S %s | FileCheck %s
;
; Map writes the identity for a skipped update to a single float stream.
; The original source load stays masked; no predicate scratch is necessary.
; The trip count is deliberately not a multiple of either Map or reduction VF.
target triple = "riscv64-unknown-linux-gnu"
; CHECK-LABEL: define float @conditional_fixed(
; CHECK: alloca float, i64 65
; CHECK-NOT: = alloca
; CHECK-NOT: @malloc
; CHECK-NOT: @llvm.memset
; CHECK: @llvm.lifetime.start
; CHECK: @llvm.{{(masked|vp)}}.load.{{(v4|nxv2)}}f32{{.*}}<{{(4|vscale x 2)}} x i1> %
; CHECK: fission.reduce.preheader
; CHECK: @llvm.{{(masked|vp)}}.load.nxv16f32
; CHECK: @llvm.vector.reduce.fadd
; CHECK: @llvm.lifetime.end
; CHECK-NOT: @free
; CHECK: ret float
define float @conditional_fixed(ptr noalias readonly %a, ptr noalias readonly %enabled, i64 %n, float %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %latch ]
  %acc = phi float [ %init, %preheader ], [ %next, %latch ]
  %ep = getelementptr i8, ptr %enabled, i64 %i
  %flag = load i8, ptr %ep, align 1
  %active = icmp ne i8 %flag, 0
  br i1 %active, label %contribute, label %latch
contribute:
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %sum = fadd fast float %acc, %x
  br label %latch
latch:
  %next = phi float [ %acc, %loop ], [ %sum, %contribute ]
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 65
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [ %init, %entry ], [ %next, %latch ]
  ret float %result
}
