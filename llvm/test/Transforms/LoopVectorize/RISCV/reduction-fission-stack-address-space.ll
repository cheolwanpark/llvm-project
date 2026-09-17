; RUN: opt -passes='loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -force-vector-width=fission:4 -scalable-vectorization=off -S %s | FileCheck %s
;
; Scratch and lifetime intrinsics use the allocation address space from DL.
target datalayout = "e-m:e-p:64:64-p5:64:64-i64:64-i128:128-n32:64-S128-A5"
target triple = "riscv64-unknown-linux-gnu"
; CHECK-LABEL: define float @alloca_address_space(
; CHECK: alloca float, i64 64, align 4, addrspace(5)
; CHECK-NOT: addrspacecast
; CHECK-NOT: @malloc
; CHECK: @llvm.lifetime.start.p5(ptr addrspace(5) %fission.buffer)
; CHECK: fission.reduce.preheader
; CHECK: @llvm.vector.reduce.fadd
; CHECK: @llvm.lifetime.end.p5(ptr addrspace(5) %fission.buffer)
; CHECK-NOT: @free
; CHECK: ret float
define float @alloca_address_space(ptr noalias %a, ptr noalias %b, i64 %n) {
entry:
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %acc = phi float [0.0, %pre], [%next, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %next = fadd fast float %acc, %x
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 64
  br i1 %done, label %exit, label %loop
exit:
  %r = phi float [%next, %loop]
  ret float %r
}
