; RUN: split-file %s %t
; RUN: opt -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -force-vector-width=fission:2 -reduction-fission-filter=false -reduction-fission-stack-budget=16 -reduction-fission-tile-budget=0 -S %t/dynamic.ll | FileCheck %s --check-prefix=NORMAL
; RUN: opt -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -force-vector-width=fission:2 -reduction-fission-filter=false -reduction-fission-stack-budget=16 -reduction-fission-tile-budget=16 -reduction-fission-allow-heap -S %t/dynamic.ll | FileCheck %s --check-prefix=TILE --implicit-check-not=@malloc --implicit-check-not=@free
; RUN: opt -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -scalable-vectorization=off -verify-dom-info -verify-loop-info -verify-scev -force-vector-width=fission:2 -reduction-fission-filter=false -reduction-fission-stack-budget=16 -reduction-fission-tile-budget=16 -S %t/dynamic.ll | FileCheck %s --check-prefix=TILE --implicit-check-not=@malloc --implicit-check-not=@free
; RUN: opt -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -force-vector-width=fission:2 -reduction-fission-filter=false -reduction-fission-stack-budget=0 -reduction-fission-tile-budget=16 -S %t/dynamic.ll | FileCheck %s --check-prefix=NORMAL
; RUN: opt -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -force-vector-width=fission:2 -reduction-fission-filter=false -reduction-fission-stack-budget=3 -reduction-fission-tile-budget=16 -S %t/dynamic.ll | FileCheck %s --check-prefix=NORMAL
; RUN: opt -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -force-vector-width=fission:2 -reduction-fission-filter=false -reduction-fission-stack-budget=4 -reduction-fission-tile-budget=4 -S %t/dynamic.ll | FileCheck %s --check-prefix=ONE
; RUN: opt -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -force-vector-width=fission:2 -reduction-fission-filter=false -reduction-fission-stack-budget=32 -reduction-fission-tile-budget=32 -data-layout="e-m:e-p:64:64-i8:8:32-i32:32-i64:64-n32:64-S128" -S %t/layout.ll | FileCheck %s --check-prefix=LAYOUT
; RUN: opt -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -force-vector-width=fission:2 -reduction-fission-filter=false -reduction-fission-stack-budget=11 -reduction-fission-tile-budget=32 -data-layout="e-m:e-p:64:64-i8:8:32-i32:32-i64:64-n32:64-S128" -S %t/layout.ll | FileCheck %s --check-prefix=NORMAL
; RUN: opt -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -force-vector-width=fission:2 -reduction-fission-filter=false -reduction-fission-stack-budget=16 -reduction-fission-tile-budget=16 -S %t/reject.ll | FileCheck %s --check-prefix=REJECT --implicit-check-not=fission. --implicit-check-not=@malloc --implicit-check-not=@free
; RUN: opt -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -force-vector-width=fission:2 -reduction-fission-stack-budget=16 -reduction-fission-tile-budget=16 -S %t/cheap.ll | FileCheck %s --check-prefix=NORMAL
; RUN: opt -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -force-vector-width=fission:2 -reduction-fission-filter=false -reduction-fission-stack-budget=16 -reduction-fission-tile-budget=16 -S %t/cheap.ll | FileCheck %s --check-prefix=CHEAP
; RUN: opt -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -force-vector-width=fission:2 -reduction-fission-filter=false -reduction-fission-stack-budget=16 -reduction-fission-tile-budget=16 -pass-remarks-missed=loop-vectorize -S %t/rollback.ll 2>&1 | FileCheck %s --check-prefix=ROLLBACK

; NORMAL-NOT: fission.
; NORMAL-NOT: @malloc
; NORMAL-NOT: @free
; NORMAL: define
; NORMAL-NOT: fission.
; NORMAL-NOT: @malloc
; NORMAL-NOT: @free
; TILE: alloca i32, i64 4
; TILE: fission.tile:
; TILE: @llvm.vector.reduce.add
; ONE: alloca i32, i64 1
; ONE: @llvm.umin.i64(i64 %fission.remaining, i64 1)
; ONE: fission.base.next = add nuw i64 %fission.base, %fission.length
; ONE: @llvm.vector.reduce.add
;
; The existing 4-byte alloca leaves 28 bytes. i8 has preferred alignment 4:
; K=floor((28-3)/(1+4))=5, charging alignTo(5,4)+20=28 bytes.
; Neither logical accumulator width nor the number of consumers sets capacity.
; LAYOUT: entry:
; LAYOUT-NEXT: %fission.buffer = alloca i8, i64 5, align 4
; LAYOUT-NEXT: %fission.buffer1 = alloca i32, i64 5, align 4
; LAYOUT-NEXT: %existing = alloca i32, align 4
; LAYOUT: @llvm.umin.i64(i64 %fission.remaining, i64 5)
; LAYOUT: @llvm.vector.reduce.add
; LAYOUT: @llvm.vector.reduce.add
; CHEAP: alloca i32, i64 4
; CHEAP: fission.tile:
; CHEAP: @llvm.vector.reduce.add
; ROLLBACK: fission rejected: failed transformation trial; selecting Normal
; ROLLBACK: define
; ROLLBACK-NOT: fission.
; ROLLBACK-NOT: = alloca
; ROLLBACK-NOT: @malloc
; ROLLBACK-NOT: @free
; ROLLBACK: ret float
; REJECT-LABEL: define float @conditional_cfg(
; REJECT: ret float
; REJECT-LABEL: define float @ordered(
; REJECT: ret float
; REJECT-LABEL: define float @strict_fma(
; REJECT: @llvm.fma.f32
; REJECT: ret float
; REJECT-LABEL: define i32 @full_width(
; REJECT: ret i32
;
;--- dynamic.ll

define i32 @dynamic(ptr noalias readonly %a, i64 %n) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi i32 [37, %pre], [%update, %loop]
  %p = getelementptr inbounds nuw i32, ptr %a, i64 %i
  %x = load i32, ptr %p, align 4
  %v = xor i32 %x, 123
  %update = add i32 %sum, %v
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [37, %entry], [%update, %loop]
  ret i32 %result
}

;--- layout.ll

define { i32, i32 } @layout(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n) {
entry:
  %existing = alloca i32, align 4
  call void @use(ptr %existing)
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %s = phi i32 [17, %pre], [%sn, %loop]
  %u = phi i32 [29, %pre], [%un, %loop]
  %p = getelementptr inbounds nuw i8, ptr %a, i64 %i
  %x = load i8, ptr %p, align 1
  %v = xor i8 %x, -128
  %sv = sext i8 %v to i32
  %q = getelementptr inbounds nuw i32, ptr %b, i64 %i
  %y = load i32, ptr %q, align 4
  %uv = xor i32 %y, 7
  %sn = add i32 %s, %sv
  %un = add i32 %u, %uv
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %rs = phi i32 [17, %entry], [%sn, %loop]
  %ru = phi i32 [29, %entry], [%un, %loop]
  %r0 = insertvalue { i32, i32 } poison, i32 %rs, 0
  %r1 = insertvalue { i32, i32 } %r0, i32 %ru, 1
  ret { i32, i32 } %r1
}

declare void @use(ptr)

;--- cheap.ll

define i32 @cheap(ptr noalias readonly %a, i64 %n) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi i32 [37, %pre], [%update, %loop]
  %p = getelementptr inbounds nuw i32, ptr %a, i64 %i
  %x = load i32, ptr %p, align 4
  %v = mul i32 %x, 123
  %update = add i32 %sum, %v
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [37, %entry], [%update, %loop]
  ret i32 %result
}

;--- reject.ll

define float @conditional_cfg(ptr noalias readonly %a, ptr noalias readonly %enabled, i64 %n, float %init) {
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

define float @ordered(ptr noalias readonly %a, i64 %n) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi float [3.5, %pre], [%update, %loop]
  %p = getelementptr inbounds nuw float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %v = fmul float %x, %x
  %update = fadd float %sum, %v
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [3.5, %entry], [%update, %loop]
  ret float %result
}

define float @strict_fma(ptr noalias readonly %a, i64 %n) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi float [3.5, %pre], [%update, %loop]
  %p = getelementptr inbounds nuw float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %v = fmul float %x, %x
  %update = call float @llvm.fma.f32(float %x, float %x, float %sum)
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [3.5, %entry], [%update, %loop]
  ret float %result
}

define i32 @full_width(ptr noalias readonly %a, i64 %n) {
entry:
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi i32 [37, %pre], [%update, %loop]
  %p = getelementptr inbounds nuw i32, ptr %a, i64 %i
  %x = load i32, ptr %p, align 4
  %v = xor i32 %x, 123
  %update = add i32 %sum, %v
  %inc = add i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
}

declare float @llvm.fma.f32(float, float, float)

;--- rollback.ll

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
