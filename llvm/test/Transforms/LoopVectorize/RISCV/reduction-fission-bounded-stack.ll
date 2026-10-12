; RUN: opt -reduction-fission-tile-budget=0 -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -force-vector-width=fission:2 -reduction-fission-filter=false -reduction-fission-stack-budget=0 -pass-remarks-missed=loop-vectorize -disable-output %s 2>&1 | FileCheck %s --check-prefix=REASON
; RUN: opt -reduction-fission-tile-budget=0 -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -force-vector-width=fission:2 -reduction-fission-filter=false -reduction-fission-stack-budget=256 -S %s -o %t
; RUN: FileCheck %s --check-prefix=STACK --implicit-check-not=@malloc --implicit-check-not=@free --implicit-check-not=.fission.trial < %t
; RUN: opt -reduction-fission-tile-budget=0 -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -force-vector-width=fission:2 -reduction-fission-filter=false -reduction-fission-stack-budget=0 -S %s | FileCheck %s --check-prefix=NORMAL --implicit-check-not=fission. --implicit-check-not=@malloc --implicit-check-not=@free
; RUN: opt -reduction-fission-tile-budget=0 -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -S %s | FileCheck %s --check-prefix=NORMAL
; RUN: opt -reduction-fission-tile-budget=0 -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -force-vector-width=fission:2 -reduction-fission-filter=false -reduction-fission-stack-budget=0 -reduction-fission-allow-heap -S %s -o %t.heap
; RUN: FileCheck %s --check-prefix=HEAP < %t.heap
; RUN: llc -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -verify-machineinstrs %t -o /dev/null
; RUN: llc -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -verify-machineinstrs %t.heap -o /dev/null
; Tiling is disabled here to retain full-loop storage/heap policy coverage.
;
; Capacity is proven by SCEV, not input data. Runtime iteration counts remain
; runtime counts. The 256-byte budget includes padding and existing allocas.
target triple = "riscv64-unknown-linux-gnu"

; STACK-LABEL: define float @exact(
; STACK: entry:
; STACK-NEXT: %fission.buffer = alloca float, i64 64
; STACK: @llvm.lifetime.start
; STACK: fission.reduce.preheader
; STACK: @llvm.vector.reduce.fadd
; STACK: @llvm.lifetime.end
; STACK: ret float
; NORMAL-LABEL: define float @exact(
; NORMAL: phi <vscale x
; NORMAL: @llvm.vector.reduce.fadd
; NORMAL: ret float
define float @exact(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
entry:
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi float [0.0, %pre], [%update, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %product = fmul fast float %x, %y
  %update = fadd fast float %sum, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 64
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%update, %loop]
  ret float %result
}

; STACK-LABEL: define float @over(
; STACK-NOT: fission.
; STACK: phi <vscale x
; STACK: @llvm.vector.reduce.fadd
; STACK: ret float
; NORMAL-LABEL: define float @over(
; NORMAL: phi <vscale x
; NORMAL: @llvm.vector.reduce.fadd
; NORMAL: ret float
define float @over(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
entry:
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi float [0.0, %pre], [%update, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %product = fmul fast float %x, %y
  %update = fadd fast float %sum, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 65
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%update, %loop]
  ret float %result
}

; STACK-LABEL: define float @bounded(
; STACK: entry:
; STACK-NEXT: %fission.buffer = alloca float, i64 64
; STACK: %fission.count = add i64 %masked, 1
; STACK: @llvm.lifetime.start
; STACK: phi i64 [ %fission.count, %vector.ph ]
; STACK: fission.reduce.preheader
; STACK: phi i64 [ %fission.count, %vector.ph{{[0-9]+}} ]
; STACK: @llvm.experimental.get.vector.length.i64(i64 %{{[^,]+}},
; STACK: @llvm.vector.reduce.fadd
; STACK: @llvm.lifetime.end
; STACK: ret float
; NORMAL-LABEL: define float @bounded(
; NORMAL: phi <vscale x
; NORMAL: @llvm.vector.reduce.fadd
; NORMAL: ret float
define float @bounded(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
entry:
  %masked = and i64 %n, 63
  %count = add nuw nsw i64 %masked, 1
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi float [0.0, %pre], [%update, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %product = fmul fast float %x, %y
  %update = fadd fast float %sum, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %count
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%update, %loop]
  ret float %result
}

; STACK-LABEL: define float @guarded(
; STACK: entry:
; STACK-NEXT: %fission.buffer = alloca float, i64 63
; STACK: br i1 %empty, label %exit, label %pre
; STACK: @llvm.lifetime.start
; STACK: fission.reduce.preheader
; STACK: @llvm.experimental.get.vector.length.i64(i64 %{{[^,]+}},
; STACK: @llvm.vector.reduce.fadd
; STACK: @llvm.lifetime.end
; STACK: ret float
; NORMAL-LABEL: define float @guarded(
; NORMAL: phi <vscale x
; NORMAL: @llvm.vector.reduce.fadd
; NORMAL: ret float
define float @guarded(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
entry:
  %count = and i64 %n, 63
  %empty = icmp eq i64 %count, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi float [0.0, %pre], [%update, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %product = fmul fast float %x, %y
  %update = fadd fast float %sum, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %count
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%update, %loop], [0.0, %entry]
  ret float %result
}

; STACK-LABEL: define float @unbounded(
; STACK-NOT: fission.
; STACK: phi <vscale x
; STACK: @llvm.vector.reduce.fadd
; STACK: ret float
; NORMAL-LABEL: define float @unbounded(
; NORMAL: phi <vscale x
; NORMAL: @llvm.vector.reduce.fadd
; NORMAL: ret float
; HEAP-LABEL: define float @unbounded(
; HEAP: @llvm.umul.with.overflow.i64
; HEAP: fission.allocation.failure
; HEAP: call {{.*}}ptr @malloc
; HEAP: icmp eq ptr
; HEAP: call void @llvm.trap
; HEAP: fission.reduce.preheader
; HEAP: call void @free
; HEAP: ret float
define float @unbounded(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi float [0.0, %pre], [%update, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %product = fmul fast float %x, %y
  %update = fadd fast float %sum, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%update, %loop], [0.0, %entry]
  ret float %result
}

; STACK-LABEL: define float @alignment_fits(
; STACK: entry:
; STACK-NEXT: %fission.buffer = alloca float, i64 60
; STACK: @llvm.lifetime.start
; STACK: fission.reduce.preheader
; STACK: @llvm.vector.reduce.fadd
; STACK: @llvm.lifetime.end
; STACK: ret float
; NORMAL-LABEL: define float @alignment_fits(
; NORMAL: phi <vscale x
; NORMAL: @llvm.vector.reduce.fadd
; NORMAL: ret float
define float @alignment_fits(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
entry:
  %local = alloca i8, i64 1, align 16
  call void @use(ptr %local)
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi float [0.0, %pre], [%update, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %product = fmul fast float %x, %y
  %update = fadd fast float %sum, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 60
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%update, %loop]
  ret float %result
}

; STACK-LABEL: define float @alignment_over(
; STACK-NOT: fission.
; STACK: phi <vscale x
; STACK: @llvm.vector.reduce.fadd
; STACK: ret float
; NORMAL-LABEL: define float @alignment_over(
; NORMAL: phi <vscale x
; NORMAL: @llvm.vector.reduce.fadd
; NORMAL: ret float
define float @alignment_over(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
entry:
  %local = alloca i8, i64 1, align 16
  call void @use(ptr %local)
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi float [0.0, %pre], [%update, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %product = fmul fast float %x, %y
  %update = fadd fast float %sum, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 61
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%update, %loop]
  ret float %result
}

; STACK-LABEL: define float @huge(
; STACK-NOT: fission.
; STACK: phi <vscale x
; STACK: @llvm.vector.reduce.fadd
; STACK: ret float
; NORMAL-LABEL: define float @huge(
; NORMAL: phi <vscale x
; NORMAL: @llvm.vector.reduce.fadd
; NORMAL: ret float
define float @huge(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
entry:
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi float [0.0, %pre], [%update, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %product = fmul fast float %x, %y
  %update = fadd fast float %sum, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 4611686018427387904
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%update, %loop]
  ret float %result
}

; STACK-LABEL: define float @excessive_bound(
; STACK-NOT: fission.
; STACK: phi <vscale x
; STACK: @llvm.vector.reduce.fadd
; STACK: ret float
; NORMAL-LABEL: define float @excessive_bound(
; NORMAL: phi <vscale x
; NORMAL: @llvm.vector.reduce.fadd
; NORMAL: ret float
define float @excessive_bound(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
entry:
  %masked = and i64 %n, 65535
  %count = add nuw nsw i64 %masked, 1
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi float [0.0, %pre], [%update, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %product = fmul fast float %x, %y
  %update = fadd fast float %sum, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %count
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%update, %loop]
  ret float %result
}

; STACK-LABEL: define float @dynamic_alloca(
; STACK-NOT: fission.
; STACK: phi <vscale x
; STACK: @llvm.vector.reduce.fadd
; STACK: ret float
; NORMAL-LABEL: define float @dynamic_alloca(
; NORMAL: phi <vscale x
; NORMAL: @llvm.vector.reduce.fadd
; NORMAL: ret float
define float @dynamic_alloca(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
entry:
  %local = alloca i8, i64 %n, align 16
  call void @use(ptr %local)
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi float [0.0, %pre], [%update, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %product = fmul fast float %x, %y
  %update = fadd fast float %sum, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 64
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%update, %loop]
  ret float %result
}

declare void @use(ptr)

; STACK-LABEL: define float @nested(
; STACK: entry:
; STACK-NEXT: %fission.buffer = alloca float, i64 64
; STACK-NOT: = alloca
; STACK: outer:
; STACK: @llvm.lifetime.start
; STACK: fission.reduce.preheader
; STACK: @llvm.vector.reduce.fadd
; STACK: @llvm.lifetime.end
; STACK: store float
; STACK-NOT: = alloca
; STACK: br i1 %last, label %end, label %outer
; STACK: ret float
; NORMAL-LABEL: define float @nested(
; NORMAL: phi <vscale x
; NORMAL: @llvm.vector.reduce.fadd
; NORMAL: ret float
define float @nested(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
entry:
  %masked = and i64 %n, 63
  %count = add nuw nsw i64 %masked, 1
  br label %outer
outer:
  %row = phi i64 [0, %entry], [%row.next, %exit]
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi float [0.0, %pre], [%update, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %product = fmul fast float %x, %y
  %update = fadd fast float %sum, %product
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %count
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%update, %loop]
  %o = getelementptr float, ptr %out, i64 %row
  store float %result, ptr %o, align 4
  %row.next = add nuw i64 %row, 1
  %last = icmp eq i64 %row.next, 10
  br i1 %last, label %end, label %outer
end:
  ret float %result
}

; A full-width count must not wrap into a small stack allocation.
; STACK-LABEL: define float @count_overflow(
; STACK-NOT: = alloca
; STACK-NOT: fission.
; STACK: ret float
; NORMAL-LABEL: define float @count_overflow(
; NORMAL: ret float
define float @count_overflow(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
entry:
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi float [0.0, %pre], [%update, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %product = fmul fast float %x, %y
  %update = fadd fast float %sum, %product
  %inc = add i64 %i, 1
  %done = icmp eq i64 %inc, 0
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%update, %loop]
  ret float %result
}

; A full-width count must not wrap into a small stack allocation.
; STACK-LABEL: define float @wide_count(
; STACK-NOT: = alloca
; STACK-NOT: fission.
; STACK: ret float
; NORMAL-LABEL: define float @wide_count(
; NORMAL: ret float
define float @wide_count(ptr noalias %a, ptr noalias %b, ptr noalias %out, i64 %n) {
entry:
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i128 [0, %pre], [%inc, %loop]
  %sum = phi float [0.0, %pre], [%update, %loop]
  %p = getelementptr float, ptr %a, i128 %i
  %x = load float, ptr %p, align 4
  %q = getelementptr float, ptr %b, i128 %i
  %y = load float, ptr %q, align 4
  %product = fmul fast float %x, %y
  %update = fadd fast float %sum, %product
  %inc = add nuw i128 %i, 1
  %done = icmp eq i128 %inc, 18446744073709551680
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%update, %loop]
  ret float %result
}

; REASON-COUNT-12: no permitted bounded scratch storage; selecting Normal
; REASON: trip count is wider than the buffer address space
