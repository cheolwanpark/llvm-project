; RUN: opt -passes='loop-vectorize,verify' -verify-dom-info -verify-loop-info -verify-scev -mtriple=riscv64 -mattr=+v,+f,+d -force-vector-width=fission:2 -scalable-vectorization=on -pass-remarks=loop-vectorize -pass-remarks-missed=loop-vectorize -S %s 2>&1 | FileCheck %s --implicit-check-not='committed fission' --implicit-check-not='call {{.*}}@malloc' --implicit-check-not='call {{.*}}@free' --implicit-check-not='fission.buffer' --implicit-check-not='phi <vscale'
;
; A function transaction must undo earlier successful original-loop transforms
; when a later original loop has an unsupported component. Here both components
; of the aligned sum vectorize before the second, underaligned Map fails. The
; second reduction still vectorizes in the trial, but the final function retains
; both original scalar loops and contains no generated allocations or buffers.
; CHECK: selected Fission MapVF=vscale x 2
; CHECK: vectorized loop (vectorization width: vscale x 2, interleaved count: 1)
; CHECK: vectorized loop (vectorization width: vscale x 16, interleaved count: 1)
; CHECK: selected Fission MapVF=vscale x 2
; CHECK: selected fission component could not be vectorized
; CHECK: vectorized loop (vectorization width: vscale x 16, interleaved count: 1)
; CHECK: fission rejected: a component failed; original function preserved
; CHECK-LABEL: define float @successful_then_failed(
; CHECK: first.loop:
; CHECK: %first.acc = phi float
; CHECK: %first.x = load float, ptr %first.p, align 4
; CHECK: %first.update = fadd fast float %first.acc, %first.x
; CHECK: br i1 %first.done, label %first.exit, label %first.loop
; CHECK: second.loop:
; CHECK: %second.acc = phi float
; CHECK: %second.x = load float, ptr %second.p, align 2
; CHECK: %second.update = fadd fast float %second.acc, %second.x
; CHECK: br i1 %second.done, label %exit, label %second.loop
; CHECK: %result = fadd float %first.result, %second.result
; CHECK: ret float %result

define float @successful_then_failed(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, float %initial) {
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
  %first.done = icmp eq i64 %first.next, %n
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
