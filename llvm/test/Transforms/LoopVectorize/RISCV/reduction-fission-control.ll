; RUN: opt -passes='loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+d,+f -force-vector-width=fission:4 -scalable-vectorization=off -verify-dom-info -verify-loop-info -verify-scev -S %s | FileCheck %s
; RUN: opt -passes='loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+d,+f -force-vector-width=fission:2 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -S %s | FileCheck %s
;
; Full distribution preserves control-dependent contribution availability.
; Map conditionally loads the source and stores an identity on skipped updates,
; including on its scalar tail. Each reducer needs only the initialized stream.

target triple = "riscv64-unknown-linux-gnu"

; CHECK-LABEL: define float @conditional_load(
; CHECK: @malloc
; CHECK-NOT: @malloc
; CHECK: @llvm.{{(masked|vp)}}.load.{{(v4|nxv2)}}f32{{.*}}<{{(4|vscale x 2)}} x i1> %
; CHECK: fission.reduce.preheader
; CHECK: phi <vscale x 16 x float>
; CHECK: @llvm.vp.load.nxv16f32{{.*}}<vscale x 16 x i1> splat (i1 true)
; CHECK: fadd reassoc arcp contract afn <vscale x 16 x float>
; CHECK: @llvm.vector.reduce.fadd.nxv16f32
; CHECK: @free
; CHECK: ret float
define float @conditional_load(ptr noalias readonly %a, ptr noalias readonly %enabled, i64 %n, float %init) {
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
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [ %init, %entry ], [ %next, %latch ]
  ret float %result
}

; Both accumulators update on the same independent control path, but they must
; still have separate complete reduction loops. Neither needs predicate storage.
; CHECK-LABEL: define { float, float } @conditional_two_accumulators(
; CHECK: @malloc
; CHECK: fission.reduce.preheader
; CHECK: phi <vscale x 16 x float>
; CHECK: @llvm.vector.reduce.fadd.nxv16f32
; CHECK: phi <vscale x 16 x float>
; CHECK: @llvm.vector.reduce.fadd.nxv16f32
; CHECK: @free
; CHECK: ret { float, float }
define { float, float } @conditional_two_accumulators(ptr noalias readonly %a, ptr noalias readonly %b, ptr noalias readonly %enabled, i64 %n, float %init1, float %init2) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %latch ]
  %acc1 = phi float [ %init1, %preheader ], [ %next1, %latch ]
  %acc2 = phi float [ %init2, %preheader ], [ %next2, %latch ]
  %ep = getelementptr i8, ptr %enabled, i64 %i
  %flag = load i8, ptr %ep, align 1
  %active = icmp ne i8 %flag, 0
  br i1 %active, label %contribute, label %latch
contribute:
  %p = getelementptr float, ptr %a, i64 %i
  %q = getelementptr float, ptr %b, i64 %i
  %x = load float, ptr %p, align 4
  %y = load float, ptr %q, align 4
  %sum1 = fadd fast float %acc1, %x
  %sum2 = fadd fast float %acc2, %y
  br label %latch
latch:
  %next1 = phi float [ %acc1, %loop ], [ %sum1, %contribute ]
  %next2 = phi float [ %acc2, %loop ], [ %sum2, %contribute ]
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result1 = phi float [ %init1, %entry ], [ %next1, %latch ]
  %result2 = phi float [ %init2, %entry ], [ %next2, %latch ]
  %pair1 = insertvalue { float, float } poison, float %result1, 0
  %pair2 = insertvalue { float, float } %pair1, float %result2, 1
  ret { float, float } %pair2
}

; A supported reduction next to an ordered reduction cannot be partly split.
; CHECK-LABEL: define float @mixed_fast_and_ordered(
; CHECK-NOT: @malloc
; CHECK-NOT: fission.reduce
; CHECK: ret float
define float @mixed_fast_and_ordered(ptr noalias readonly %a, i64 %n, float %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %fast.acc = phi float [ %init, %preheader ], [ %fast.next, %loop ]
  %strict.acc = phi float [ %init, %preheader ], [ %strict.next, %loop ]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %fast.next = fadd fast float %fast.acc, %x
  %strict.next = fadd float %strict.acc, %x
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %fast.result = phi float [ %init, %entry ], [ %fast.next, %loop ]
  %strict.result = phi float [ %init, %entry ], [ %strict.next, %loop ]
  %result = fadd float %fast.result, %strict.result
  ret float %result
}

; Integer product is recognized by LLVM, but its scalable horizontal reduction
; cannot be lowered by RVV. Reject the sum together with the product.
; CHECK-LABEL: define i32 @mixed_add_and_unsupported_product(
; CHECK-NOT: @malloc
; CHECK-NOT: fission.reduce
; CHECK: ret i32
define i32 @mixed_add_and_unsupported_product(ptr noalias readonly %a, i64 %n, i32 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %sum.acc = phi i32 [ %init, %preheader ], [ %sum.next, %loop ]
  %product.acc = phi i32 [ %init, %preheader ], [ %product.next, %loop ]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p, align 4
  %sum.next = add i32 %sum.acc, %x
  %product.next = mul i32 %product.acc, %x
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %sum.result = phi i32 [ %init, %entry ], [ %sum.next, %loop ]
  %product.result = phi i32 [ %init, %entry ], [ %product.next, %loop ]
  %result = xor i32 %sum.result, %product.result
  ret i32 %result
}

; Loop-invariant contributions need no scratch or Map copies, but still execute
; a full independent reduction. This is an LLVM-recognized fadd.
; CHECK-LABEL: define float @invariant_contribution(
; CHECK-NOT: @malloc
; CHECK-NOT: store
; CHECK: phi <vscale x 16 x float>
; CHECK: @llvm.vector.reduce.fadd.nxv16f32
; CHECK-NOT: @free
; CHECK: ret float
define float @invariant_contribution(i64 %n, float %init, float %step) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %acc = phi float [ %init, %preheader ], [ %next, %loop ]
  %next = fadd fast float %acc, %step
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [ %init, %entry ], [ %next, %loop ]
  ret float %result
}

; Each outer iteration must release its inner-loop scratch before the outer
; backedge. The zero-trip inner path skips allocation, reduction and cleanup.
; CHECK-LABEL: define void @nested_inner_lifetime(
; CHECK: outer:
; CHECK: @malloc
; CHECK: phi <vscale x 16 x float>
; CHECK: @llvm.vector.reduce.fadd.nxv16f32
; CHECK: fission.cleanup:
; CHECK: call void @free
; CHECK: br label %inner.exit
; CHECK: inner.exit:
; CHECK: store float
; CHECK: %row.next = add
; CHECK: br i1 %outer.done, label %exit.loopexit, label %outer
; CHECK: exit.loopexit:
; CHECK: br label %exit
define void @nested_inner_lifetime(ptr noalias readonly %a, ptr noalias %out, i64 %rows, i64 %n, float %init) {
entry:
  %no.rows = icmp eq i64 %rows, 0
  br i1 %no.rows, label %exit, label %outer.preheader
outer.preheader:
  br label %outer
outer:
  %row = phi i64 [ 0, %outer.preheader ], [ %row.next, %inner.exit ]
  %row.offset = mul i64 %row, %n
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %inner.exit, label %inner.preheader
inner.preheader:
  br label %inner
inner:
  %i = phi i64 [ 0, %inner.preheader ], [ %inc, %inner ]
  %acc = phi float [ %init, %inner.preheader ], [ %next, %inner ]
  %offset = add i64 %row.offset, %i
  %p = getelementptr float, ptr %a, i64 %offset
  %x = load float, ptr %p, align 4
  %next = fadd fast float %acc, %x
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %inner.exit, label %inner
inner.exit:
  %result = phi float [ %init, %outer ], [ %next, %inner ]
  %dst = getelementptr float, ptr %out, i64 %row
  store float %result, ptr %dst, align 4
  %row.next = add nuw i64 %row, 1
  %outer.done = icmp eq i64 %row.next, %rows
  br i1 %outer.done, label %exit, label %outer
exit:
  ret void
}
