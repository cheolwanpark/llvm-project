; RUN: opt -passes='loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+d,+f -force-vector-width=fission:4 -scalable-vectorization=off -verify-dom-info -verify-loop-info -verify-scev -S %s | FileCheck %s
;
; Full fission cannot leave true memory recurrences in Map even when the
; original loop is vectorizable at a VF smaller than the dependence distance.
; A recurrence requires a cycle of SSA/control and true memory flow edges.
; Mere within-iteration, anti-, or acyclic flow dependences remain supported.
; The reverse case checks dependence direction against program order; the
; two-memory-edge case requires reachability through other memory flow edges.
; Conditional writes and differing join PHIs carry state through control, but
; an unrelated unconditional store after the join must not inherit control.

target triple = "riscv64-unknown-linux-gnu"

; CHECK-LABEL: define i32 @flow_recurrence(
; CHECK-NOT: @malloc
; CHECK-NOT: fission.reduce
; CHECK: ret i32
define i32 @flow_recurrence(ptr noalias %a, ptr noalias readonly %x, i64 %n, i32 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%next, %loop]
  %sum = phi i32 [%init, %pre], [%sum.next, %loop]
  %shift = add nuw i64 %i, 8
  %p = getelementptr i32, ptr %a, i64 %i
  %v = load i32, ptr %p, align 4
  %xp = getelementptr i32, ptr %x, i64 %i
  %xv = load i32, ptr %xp, align 4
  %updated = add i32 %v, %xv
  %q = getelementptr i32, ptr %a, i64 %shift
  store i32 %updated, ptr %q, align 4
  %sum.next = add i32 %sum, %v
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%init, %entry], [%sum.next, %loop]
  ret i32 %result
}

; CHECK-LABEL: define i32 @within_iteration(
; CHECK: @malloc
; CHECK: fission.reduce.preheader
; CHECK: phi <vscale x 16 x i32>
; CHECK: @llvm.vector.reduce.add.nxv16i32
; CHECK: @free
; CHECK: ret i32
define i32 @within_iteration(ptr noalias %a, ptr noalias readonly %x, i64 %n, i32 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%next, %loop]
  %sum = phi i32 [%init, %pre], [%sum.next, %loop]
  %shift = add nuw i64 %i, 8
  %p = getelementptr i32, ptr %a, i64 %i
  %v = load i32, ptr %p, align 4
  %xp = getelementptr i32, ptr %x, i64 %i
  %xv = load i32, ptr %xp, align 4
  %updated = add i32 %v, %xv
  %q = getelementptr i32, ptr %a, i64 %i
  store i32 %updated, ptr %q, align 4
  %sum.next = add i32 %sum, %v
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%init, %entry], [%sum.next, %loop]
  ret i32 %result
}

; CHECK-LABEL: define i32 @anti_dependence(
; CHECK: @malloc
; CHECK: fission.reduce.preheader
; CHECK: phi <vscale x 16 x i32>
; CHECK: @llvm.vector.reduce.add.nxv16i32
; CHECK: @free
; CHECK: ret i32
define i32 @anti_dependence(ptr noalias %a, ptr noalias readonly %x, i64 %n, i32 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%next, %loop]
  %sum = phi i32 [%init, %pre], [%sum.next, %loop]
  %shift = add nuw i64 %i, 8
  %p = getelementptr i32, ptr %a, i64 %shift
  %v = load i32, ptr %p, align 4
  %xp = getelementptr i32, ptr %x, i64 %i
  %xv = load i32, ptr %xp, align 4
  %updated = add i32 %v, %xv
  %q = getelementptr i32, ptr %a, i64 %i
  store i32 %updated, ptr %q, align 4
  %sum.next = add i32 %sum, %v
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%init, %entry], [%sum.next, %loop]
  ret i32 %result
}

; CHECK-LABEL: define i32 @flow_without_cycle(
; CHECK: @malloc
; CHECK: fission.reduce.preheader
; CHECK: phi <vscale x 16 x i32>
; CHECK: @llvm.vector.reduce.add.nxv16i32
; CHECK: @free
; CHECK: ret i32
define i32 @flow_without_cycle(ptr noalias %a, ptr noalias readonly %x, i64 %n, i32 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%next, %loop]
  %sum = phi i32 [%init, %pre], [%sum.next, %loop]
  %shift = add nuw i64 %i, 8
  %p = getelementptr i32, ptr %a, i64 %i
  %v = load i32, ptr %p, align 4
  %xp = getelementptr i32, ptr %x, i64 %i
  %xv = load i32, ptr %xp, align 4
  %updated = add i32 %v, %xv
  %q = getelementptr i32, ptr %a, i64 %shift
  store i32 %xv, ptr %q, align 4
  %sum.next = add i32 %sum, %v
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%init, %entry], [%sum.next, %loop]
  ret i32 %result
}

; CHECK-LABEL: define i32 @two_memory_edge_cycle(
; CHECK-NOT: @malloc
; CHECK-NOT: fission.reduce
; CHECK: ret i32
define i32 @two_memory_edge_cycle(ptr noalias %a, ptr noalias %b, ptr noalias readonly %x, i64 %n, i32 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%next, %loop]
  %sum = phi i32 [%init, %pre], [%sum.next, %loop]
  %shift = add nuw i64 %i, 8
  %ap = getelementptr i32, ptr %a, i64 %i
  %av = load i32, ptr %ap, align 4
  %bp = getelementptr i32, ptr %b, i64 %i
  %bv = load i32, ptr %bp, align 4
  %xp = getelementptr i32, ptr %x, i64 %i
  %xv = load i32, ptr %xp, align 4
  %anext = add i32 %bv, %xv
  %bnext = add i32 %av, %xv
  %aq = getelementptr i32, ptr %a, i64 %shift
  %bq = getelementptr i32, ptr %b, i64 %shift
  store i32 %anext, ptr %aq, align 4
  store i32 %bnext, ptr %bq, align 4
  %sum.next = add i32 %sum, %xv
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%init, %entry], [%sum.next, %loop]
  ret i32 %result
}

; CHECK-LABEL: define i32 @backward_anti(
; CHECK: @malloc
; CHECK: fission.reduce.preheader
; CHECK: phi <vscale x 16 x i32>
; CHECK: @llvm.vector.reduce.add.nxv16i32
; CHECK: @free
; CHECK: ret i32
define i32 @backward_anti(ptr noalias %a, ptr noalias readonly %x, i64 %n, i32 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%next, %loop]
  %sum = phi i32 [%init, %pre], [%sum.next, %loop]
  %shift = add nuw i64 %i, 8
  %xp = getelementptr i32, ptr %x, i64 %i
  %xv = load i32, ptr %xp, align 4
  %q = getelementptr i32, ptr %a, i64 %i
  store i32 %xv, ptr %q, align 4
  %p = getelementptr i32, ptr %a, i64 %shift
  %v = load i32, ptr %p, align 4
  %sum.next = add i32 %sum, %v
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%init, %entry], [%sum.next, %loop]
  ret i32 %result
}

; CHECK-LABEL: define i32 @reverse_flow_recurrence(
; CHECK-NOT: @malloc
; CHECK-NOT: fission.reduce
; CHECK: ret i32
define i32 @reverse_flow_recurrence(ptr noalias %a, ptr noalias readonly %x, i64 %n, i32 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%next, %loop]
  %sum = phi i32 [%init, %pre], [%sum.next, %loop]
  %pos = sub i64 %n, %i
  %dst = sub i64 %pos, 1
  %src = add i64 %pos, 7
  %p = getelementptr i32, ptr %a, i64 %src
  %v = load i32, ptr %p, align 4
  %xp = getelementptr i32, ptr %x, i64 %i
  %xv = load i32, ptr %xp, align 4
  %updated = add i32 %v, %xv
  %q = getelementptr i32, ptr %a, i64 %dst
  store i32 %updated, ptr %q, align 4
  %sum.next = add i32 %sum, %v
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%init, %entry], [%sum.next, %loop]
  ret i32 %result
}

; CHECK-LABEL: define i32 @conditional_store_recurrence(
; CHECK-NOT: @malloc
; CHECK-NOT: fission.reduce
; CHECK: ret i32
define i32 @conditional_store_recurrence(ptr noalias %a, ptr noalias readonly %x, i64 %n, i32 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%next, %latch]
  %sum = phi i32 [%init, %pre], [%sum.next, %latch]
  %shift = add nuw i64 %i, 8
  %p = getelementptr i32, ptr %a, i64 %i
  %v = load i32, ptr %p, align 4
  %xp = getelementptr i32, ptr %x, i64 %i
  %xv = load i32, ptr %xp, align 4
  %q = getelementptr i32, ptr %a, i64 %shift
  %enabled = icmp ne i32 %v, 0
  br i1 %enabled, label %write, label %latch
write:
  store i32 %xv, ptr %q, align 4
  br label %latch
latch:

  %sum.next = add i32 %sum, %xv
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%init, %entry], [%sum.next, %latch]
  ret i32 %result
}

; CHECK-LABEL: define i32 @conditional_phi_recurrence(
; CHECK-NOT: @malloc
; CHECK-NOT: fission.reduce
; CHECK: ret i32
define i32 @conditional_phi_recurrence(ptr noalias %a, ptr noalias readonly %x, i64 %n, i32 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%next, %latch]
  %sum = phi i32 [%init, %pre], [%sum.next, %latch]
  %shift = add nuw i64 %i, 8
  %p = getelementptr i32, ptr %a, i64 %i
  %v = load i32, ptr %p, align 4
  %xp = getelementptr i32, ptr %x, i64 %i
  %xv = load i32, ptr %xp, align 4
  %q = getelementptr i32, ptr %a, i64 %shift
  %enabled = icmp ne i32 %v, 0
  br i1 %enabled, label %write, label %latch
write:
  %neg = sub i32 0, %xv
  br label %latch
latch:
  %chosen = phi i32 [%xv, %loop], [%neg, %write]
  store i32 %chosen, ptr %q, align 4
  %sum.next = add i32 %sum, %xv
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%init, %entry], [%sum.next, %latch]
  ret i32 %result
}

; CHECK-LABEL: define i32 @unrelated_store_after_join(
; CHECK: @malloc
; CHECK: fission.reduce.preheader
; CHECK: phi <vscale x 16 x i32>
; CHECK: @llvm.vector.reduce.add.nxv16i32
; CHECK: @free
; CHECK: ret i32
define i32 @unrelated_store_after_join(ptr noalias %a, ptr noalias readonly %x, ptr noalias %b, i64 %n, i32 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%next, %latch]
  %sum = phi i32 [%init, %pre], [%sum.next, %latch]
  %shift = add nuw i64 %i, 8
  %p = getelementptr i32, ptr %a, i64 %i
  %v = load i32, ptr %p, align 4
  %xp = getelementptr i32, ptr %x, i64 %i
  %xv = load i32, ptr %xp, align 4
  %q = getelementptr i32, ptr %a, i64 %shift
  %enabled = icmp ne i32 %v, 0
  br i1 %enabled, label %write, label %latch
write:
  %bp = getelementptr i32, ptr %b, i64 %i
  store i32 %xv, ptr %bp, align 4
  br label %latch
latch:
  store i32 %xv, ptr %q, align 4
  %sum.next = add i32 %sum, %xv
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%init, %entry], [%sum.next, %latch]
  ret i32 %result
}

; Runtime alias checks cannot exclude recurrence on the scalar Map path.
; The same-address connector joins a carried edge to a separate in-iteration
; store/load pair, which LAA may omit from its reported dependence list.

; CHECK-LABEL: define i32 @runtime_alias_cycle(
; CHECK-NOT: @malloc
; CHECK-NOT: fission.reduce
; CHECK: ret i32
define i32 @runtime_alias_cycle(ptr %a, ptr %b, ptr noalias readonly %x, i64 %n, i32 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%next, %loop]
  %sum = phi i32 [%init, %pre], [%sum.next, %loop]
  %shift = add nuw i64 %i, 8
  %p = getelementptr i32, ptr %a, i64 %i
  %v = load i32, ptr %p, align 4
  %xp = getelementptr i32, ptr %x, i64 %i
  %xv = load i32, ptr %xp, align 4
  %updated = add i32 %v, %xv
  %q = getelementptr i32, ptr %b, i64 %i
  store i32 %updated, ptr %q, align 4
  %sum.next = add i32 %sum, %v
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%init, %entry], [%sum.next, %loop]
  ret i32 %result
}

; CHECK-LABEL: define i32 @runtime_alias_acyclic(
; CHECK: @malloc
; CHECK: fission.reduce.preheader
; CHECK: phi <vscale x 16 x i32>
; CHECK: @llvm.vector.reduce.add.nxv16i32
; CHECK: @free
; CHECK: ret i32
define i32 @runtime_alias_acyclic(ptr %a, ptr %b, ptr noalias readonly %x, i64 %n, i32 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%next, %loop]
  %sum = phi i32 [%init, %pre], [%sum.next, %loop]
  %shift = add nuw i64 %i, 8
  %p = getelementptr i32, ptr %a, i64 %i
  %v = load i32, ptr %p, align 4
  %xp = getelementptr i32, ptr %x, i64 %i
  %xv = load i32, ptr %xp, align 4
  %updated = add i32 %v, %xv
  %q = getelementptr i32, ptr %b, i64 %i
  store i32 %xv, ptr %q, align 4
  %sum.next = add i32 %sum, %v
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%init, %entry], [%sum.next, %loop]
  ret i32 %result
}

; CHECK-LABEL: define i32 @same_address_forward_connector(
; CHECK-NOT: @malloc
; CHECK-NOT: fission.reduce
; CHECK: ret i32
define i32 @same_address_forward_connector(ptr noalias %a, ptr noalias %b, ptr noalias readonly %x, i64 %n, i32 %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%next, %loop]
  %sum = phi i32 [%init, %pre], [%sum.next, %loop]
  %shift = add nuw i64 %i, 8
  %p = getelementptr i32, ptr %a, i64 %i
  %v = load i32, ptr %p, align 4
  %xp = getelementptr i32, ptr %x, i64 %i
  %xv = load i32, ptr %xp, align 4
  %updated = add i32 %v, %xv
  %bp = getelementptr i32, ptr %b, i64 %i
  store i32 %updated, ptr %bp, align 4
  %bv = load i32, ptr %bp, align 4
  %q = getelementptr i32, ptr %a, i64 %shift
  store i32 %bv, ptr %q, align 4
  %sum.next = add i32 %sum, %v
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%init, %entry], [%sum.next, %loop]
  ret i32 %result
}
