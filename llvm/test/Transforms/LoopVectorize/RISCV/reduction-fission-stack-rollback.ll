; RUN: opt -passes='loop-vectorize,verify' -verify-dom-info -verify-loop-info -verify-scev -mtriple=riscv64 -mattr=+v,+f,+d -force-vector-width=fission:2 -scalable-vectorization=on -pass-remarks=loop-vectorize -pass-remarks-missed=loop-vectorize -S %s 2>&1 | FileCheck %s
;
; The first loop creates fixed entry scratch. Failure to vectorize the
; underaligned second Map must roll back the complete function transaction.
; CHECK: selected Fission
; CHECK: selected Fission
; CHECK: fission rejected: a component failed; original function preserved
; CHECK-LABEL: define float @stack_then_failed(
; CHECK-NOT: = alloca
; CHECK-NOT: call {{.*}}@malloc
; CHECK-NOT: call {{.*}}@free
; CHECK-NOT: fission.buffer
; CHECK: %first.update = fadd fast float
; CHECK: %second.x = load float, ptr %second.p, align 2
; CHECK: ret float
define float @stack_then_failed(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, float %initial) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %first.exit, label %first.preheader
first.preheader:
  br label %first.loop
first.loop:
  %first.i = phi i64 [ 0, %first.preheader ], [ %first.next, %first.loop ]
  %first.acc = phi float [ %initial, %first.preheader ], [ %first.update, %first.loop ]
  %first.p = getelementptr float, ptr %a, i64 %first.i
  %first.x = load float, ptr %first.p, align 4
  %first.update = fadd fast float %first.acc, %first.x
  %first.next = add nuw i64 %first.i, 1
  %first.done = icmp eq i64 %first.next, 64
  br i1 %first.done, label %first.exit, label %first.loop
first.exit:
  %first.result = phi float [ %initial, %entry ], [ %first.update, %first.loop ]
  br i1 %empty, label %exit, label %second.preheader
second.preheader:
  br label %second.loop
second.loop:
  %second.i = phi i64 [ 0, %second.preheader ], [ %second.next, %second.loop ]
  %second.acc = phi float [ %initial, %second.preheader ], [ %second.update, %second.loop ]
  %second.p = getelementptr float, ptr %b, i64 %second.i
  %second.x = load float, ptr %second.p, align 2
  %second.update = fadd fast float %second.acc, %second.x
  %second.next = add nuw i64 %second.i, 1
  %second.done = icmp eq i64 %second.next, %n
  br i1 %second.done, label %exit, label %second.loop
exit:
  %second.result = phi float [ %initial, %first.exit ], [ %second.update, %second.loop ]
  %result = fadd float %first.result, %second.result
  ret float %result
}
