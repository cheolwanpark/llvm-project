; RUN: opt -passes='loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -force-vector-width=fission:4 -scalable-vectorization=off -S %s | FileCheck %s --check-prefix=DEFAULT
; RUN: opt -passes='loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -force-vector-width=fission:4 -scalable-vectorization=off -reduction-fission-stack-budget=256 -verify-dom-info -verify-loop-info -verify-scev -S %s | FileCheck %s
; RUN: opt -passes='loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -force-vector-width=fission:4 -scalable-vectorization=off -reduction-fission-stack-budget=0 -S %s | FileCheck %s --check-prefix=HEAP

; Fixed scratch is charged as a cohort, including existing static allocas.
; Entry allocation is reused across outer-loop iterations; lifetime.end is
; not used as a substitute for restoring a dynamic stack pointer.
target triple = "riscv64-unknown-linux-gnu"

declare void @use(ptr)

; CHECK-LABEL: define float @at_budget(
; HEAP-LABEL: define float @at_budget(
; HEAP: call {{.*}}@malloc
; HEAP: call void @free
; CHECK: alloca float, i64 64
; CHECK: call void @llvm.lifetime.start
; CHECK-NOT: call {{.*}}@malloc
; CHECK: fission.reduce.preheader
; CHECK: @llvm.vector.reduce.
; CHECK: call void @llvm.lifetime.end
; CHECK-NOT: call void @free
; CHECK: ret float
define float @at_budget(ptr noalias %a, ptr noalias %b, i64 %n) {
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

; CHECK-LABEL: define float @over_budget(
; HEAP-LABEL: define float @over_budget(
; HEAP: call {{.*}}@malloc
; HEAP: call void @free
; CHECK: call {{.*}}@malloc
; CHECK: fission.reduce.preheader
; CHECK: @llvm.vector.reduce.
; CHECK: call void @free
; CHECK: ret float
define float @over_budget(ptr noalias %a, ptr noalias %b, i64 %n) {
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
  %done = icmp eq i64 %inc, 65
  br i1 %done, label %exit, label %loop
exit:
  %r = phi float [%next, %loop]
  ret float %r
}

; CHECK-LABEL: define float @two_at_budget(
; HEAP-LABEL: define float @two_at_budget(
; HEAP: call {{.*}}@malloc
; HEAP: call void @free
; CHECK: alloca float, i64 32
; CHECK: call void @llvm.lifetime.start
; CHECK-NOT: call {{.*}}@malloc
; CHECK: fission.reduce.preheader
; CHECK: @llvm.vector.reduce.
; CHECK: call void @llvm.lifetime.end
; CHECK-NOT: call void @free
; CHECK: ret float
define float @two_at_budget(ptr noalias %a, ptr noalias %b, i64 %n) {
entry:
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %acc = phi float [0.0, %pre], [%next, %loop]
  %acc2 = phi float [0.0, %pre], [%next2, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %next = fadd fast float %acc, %x
  %q = getelementptr float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %next2 = fadd fast float %acc2, %y
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 32
  br i1 %done, label %exit, label %loop
exit:
  %r = phi float [%next, %loop]
  %r2 = phi float [%next2, %loop]
  %combined = fadd float %r, %r2
  ret float %combined
}

; CHECK-LABEL: define float @two_over_budget(
; HEAP-LABEL: define float @two_over_budget(
; HEAP: call {{.*}}@malloc
; HEAP: call void @free
; CHECK: call {{.*}}@malloc
; CHECK: fission.reduce.preheader
; CHECK: @llvm.vector.reduce.
; CHECK: call void @free
; CHECK: ret float
define float @two_over_budget(ptr noalias %a, ptr noalias %b, i64 %n) {
entry:
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %acc = phi float [0.0, %pre], [%next, %loop]
  %acc2 = phi float [0.0, %pre], [%next2, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %next = fadd fast float %acc, %x
  %q = getelementptr float, ptr %b, i64 %i
  %y = load float, ptr %q, align 4
  %next2 = fadd fast float %acc2, %y
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 33
  br i1 %done, label %exit, label %loop
exit:
  %r = phi float [%next, %loop]
  %r2 = phi float [%next2, %loop]
  %combined = fadd float %r, %r2
  ret float %combined
}

; CHECK-LABEL: define i16 @half_width(
; HEAP-LABEL: define i16 @half_width(
; HEAP: call {{.*}}@malloc
; HEAP: call void @free
; CHECK: alloca i16, i64 128
; CHECK: call void @llvm.lifetime.start
; CHECK-NOT: call {{.*}}@malloc
; CHECK: fission.reduce.preheader
; CHECK: @llvm.vector.reduce.
; CHECK: call void @llvm.lifetime.end
; CHECK-NOT: call void @free
; CHECK: ret i16
define i16 @half_width(ptr noalias %a, ptr noalias %b, i64 %n) {
entry:
  br label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %acc = phi i16 [0, %pre], [%next, %loop]
  %p = getelementptr i16, ptr %a, i64 %i
  %x = load i16, ptr %p, align 2
  %next = add i16 %acc, %x
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 128
  br i1 %done, label %exit, label %loop
exit:
  %r = phi i16 [%next, %loop]
  ret i16 %r
}

; CHECK-LABEL: define float @runtime_count(
; HEAP-LABEL: define float @runtime_count(
; HEAP: call {{.*}}@malloc
; HEAP: call void @free
; CHECK: call {{.*}}@malloc
; CHECK: fission.reduce.preheader
; CHECK: @llvm.vector.reduce.
; CHECK: call void @free
; CHECK: ret float
define float @runtime_count(ptr noalias %a, ptr noalias %b, i64 %n) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %acc = phi float [0.0, %pre], [%next, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %next = fadd fast float %acc, %x
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %r = phi float [%next, %loop], [0.0, %entry]
  ret float %r
}

; CHECK-LABEL: define float @existing_at_budget(
; HEAP-LABEL: define float @existing_at_budget(
; HEAP: call {{.*}}@malloc
; HEAP: call void @free
; CHECK: alloca float, i64 48
; CHECK: call void @llvm.lifetime.start
; CHECK-NOT: call {{.*}}@malloc
; CHECK: fission.reduce.preheader
; CHECK: @llvm.vector.reduce.
; CHECK: call void @llvm.lifetime.end
; CHECK-NOT: call void @free
; CHECK: ret float
define float @existing_at_budget(ptr noalias %a, ptr noalias %b, i64 %n) {
entry:
  %local = alloca i8, i64 64, align 16
  call void @use(ptr %local)
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
  %done = icmp eq i64 %inc, 48
  br i1 %done, label %exit, label %loop
exit:
  %r = phi float [%next, %loop]
  call void @use(ptr %local)
  ret float %r
}

; CHECK-LABEL: define float @existing_over_budget(
; HEAP-LABEL: define float @existing_over_budget(
; HEAP: call {{.*}}@malloc
; HEAP: call void @free
; CHECK: call {{.*}}@malloc
; CHECK: fission.reduce.preheader
; CHECK: @llvm.vector.reduce.
; CHECK: call void @free
; CHECK: ret float
define float @existing_over_budget(ptr noalias %a, ptr noalias %b, i64 %n) {
entry:
  %local = alloca i8, i64 64, align 16
  call void @use(ptr %local)
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
  %done = icmp eq i64 %inc, 49
  br i1 %done, label %exit, label %loop
exit:
  %r = phi float [%next, %loop]
  call void @use(ptr %local)
  ret float %r
}

; CHECK-LABEL: define float @existing_dynamic(
; HEAP-LABEL: define float @existing_dynamic(
; HEAP: call {{.*}}@malloc
; HEAP: call void @free
; CHECK: call {{.*}}@malloc
; CHECK: fission.reduce.preheader
; CHECK: @llvm.vector.reduce.
; CHECK: call void @free
; CHECK: ret float
define float @existing_dynamic(ptr noalias %a, ptr noalias %b, i64 %n) {
entry:
  %local = alloca i8, i64 %n, align 16
  call void @use(ptr %local)
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
  call void @use(ptr %local)
  ret float %r
}

; CHECK-LABEL: define void @outer_loop(
; CHECK: entry:
; CHECK-NEXT: %fission.buffer = alloca float, i64 64
; CHECK: outer:
; CHECK-NOT: = alloca
; CHECK: call void @llvm.lifetime.start
; CHECK: fission.reduce.preheader
; CHECK: @llvm.vector.reduce.fadd
; CHECK: call void @llvm.lifetime.end
; CHECK: store float
; CHECK-NOT: = alloca
; CHECK: ret void
; HEAP-LABEL: define void @outer_loop(
; HEAP: call {{.*}}@malloc
; HEAP: call void @free
define void @outer_loop(ptr noalias %a, ptr noalias %out, i64 %repeats) {
entry:
  %empty = icmp eq i64 %repeats, 0
  br i1 %empty, label %exit, label %outer
outer:
  %j = phi i64 [0, %entry], [%jn, %inner.exit]
  br label %pre
pre:
  br label %inner
inner:
  %i = phi i64 [0, %pre], [%inc, %inner]
  %acc = phi float [0.0, %pre], [%next, %inner]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %next = fadd fast float %acc, %x
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 64
  br i1 %done, label %inner.exit, label %inner
inner.exit:
  %r = phi float [%next, %inner]
  %o = getelementptr float, ptr %out, i64 %j
  store float %r, ptr %o, align 4
  %jn = add nuw i64 %j, 1
  %last = icmp eq i64 %jn, %repeats
  br i1 %last, label %exit, label %outer
exit:
  ret void
}

; CHECK-LABEL: define float @default_boundary(
; CHECK: call {{.*}}@malloc
; CHECK: call void @free
; HEAP-LABEL: define float @default_boundary(
; HEAP: call {{.*}}@malloc
; HEAP: call void @free
; DEFAULT-LABEL: define float @default_boundary(
; DEFAULT: alloca float, i64 4096
; DEFAULT-NOT: @malloc
; DEFAULT: @llvm.lifetime.end
; DEFAULT-NOT: @free
; DEFAULT: ret float
define float @default_boundary(ptr noalias %a, ptr noalias %b, i64 %n) {
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
  %done = icmp eq i64 %inc, 4096
  br i1 %done, label %exit, label %loop
exit:
  %r = phi float [%next, %loop]
  ret float %r
}

; CHECK-LABEL: define float @default_over(
; CHECK: call {{.*}}@malloc
; CHECK: call void @free
; HEAP-LABEL: define float @default_over(
; HEAP: call {{.*}}@malloc
; HEAP: call void @free
; DEFAULT-LABEL: define float @default_over(
; DEFAULT: call {{.*}}@malloc
; DEFAULT: call void @free
; DEFAULT: ret float
define float @default_over(ptr noalias %a, ptr noalias %b, i64 %n) {
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
  %done = icmp eq i64 %inc, 4097
  br i1 %done, label %exit, label %loop
exit:
  %r = phi float [%next, %loop]
  ret float %r
}

; CHECK-LABEL: define float @two_fissions(
; CHECK: alloca float, i64 64
; CHECK-NOT: = alloca
; CHECK: @llvm.lifetime.start
; CHECK: @llvm.lifetime.end
; CHECK-NOT: = alloca
; CHECK: call {{.*}}@malloc
; CHECK: call void @free
; CHECK: ret float
; HEAP-LABEL: define float @two_fissions(
; HEAP: call {{.*}}@malloc
; HEAP: call void @free
; HEAP: call {{.*}}@malloc
; HEAP: call void @free
define float @two_fissions(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n, float %initial) {
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
  %second.x = load float, ptr %second.p, align 4
  %second.update = fadd fast float %second.acc, %second.x
  %second.next = add nuw i64 %second.i, 1
  %second.done = icmp eq i64 %second.next, 64
  br i1 %second.done, label %exit, label %second.loop
exit:
  %second.result = phi float [ %initial, %first.exit ], [ %second.update, %second.loop ]
  %result = fadd float %first.result, %second.result
  ret float %result
}
