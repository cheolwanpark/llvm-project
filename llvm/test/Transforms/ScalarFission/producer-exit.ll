; REQUIRES: riscv-registered-target
; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -S %s | FileCheck %s
; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=1 -S %s | FileCheck %s --check-prefix=ONE
; RUN: opt -passes='scalar-fission,loop-vectorize' -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -pass-remarks=scalar-fission -disable-output %s 2>&1 | FileCheck %s --check-prefix=LV
; RUN: opt -passes='default<O3>' -enable-scalar-fission -scalar-fission-early=true -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -pass-remarks=scalar-fission -disable-output %s 2>&1 | FileCheck %s --check-prefix=INTEGRATED
; RUN: opt -passes='default<O3>' -enable-scalar-fission -scalar-fission-early=false -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -pass-remarks=scalar-fission -disable-output %s 2>&1 | FileCheck %s --check-prefix=INTEGRATED
; INTEGRATED-COUNT-2: scalar-IR fission producer VF vscale x 4 IC 1; requested VF 0
;
; LV: scalar-IR fission producer VF vscale x 4 IC 1; requested VF 0
; LV: scalar-IR fission producer VF vscale x 4 IC 1; requested VF 0
; LV: scalar-IR fission producer VF vscale x 4 IC 1; requested VF 0
; LV: scalar-IR fission producer VF 1 IC 1; requested VF 0
;
; Keep integer comparisons exposed without changing the original continuation's
; poison semantics. The added capacity comparison is always nonpoison.
; CHECK-LABEL: define i32 @reverse(
; CHECK: %fission.continue = icmp samesign ne i64 %next, %n
; CHECK-NEXT: {{%.*}} = icmp ult i64 %fission.completed, 1024
; CHECK-NEXT: %fission.more = and i1 %fission.continue,
; CHECK-NEXT: br i1 %fission.more, label %loop, label %scalar.fission.producer.exit
; ONE-LABEL: define i32 @reverse(
; ONE: %fission.more = and i1 %fission.continue,
; ONE: br i1 %fission.more, label %loop, label %scalar.fission.producer.exit

define i32 @reverse(ptr %a, i64 %n, i32 %seed) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %s = phi i32 [%seed, %entry], [%u, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %square = mul i32 %x, %x
  %bias = add i32 %square, 3
  %f = xor i32 %bias, 9
  %u = add i32 %s, %f
  %next = add nuw i64 %i, 1
  %done = icmp samesign eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %r = phi i32 [%u, %loop]
  ret i32 %r
}

; CHECK-LABEL: define i32 @forward(
; CHECK: %more = icmp ult i64 %next, %n
; CHECK: %fission.more = and i1 %more,
; CHECK-NEXT: br i1 %fission.more, label %loop, label %scalar.fission.producer.exit
; ONE-LABEL: define i32 @forward(
; ONE: %fission.more = and i1 %more,

define i32 @forward(ptr %a, i64 %n, i32 %seed) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %s = phi i32 [%seed, %entry], [%u, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %square = mul i32 %x, %x
  %bias = add i32 %square, 3
  %f = xor i32 %bias, 9
  %u = add i32 %s, %f
  %next = add nuw i64 %i, 1
  %more = icmp ult i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi i32 [%u, %loop]
  ret i32 %r
}

; CHECK-LABEL: define i32 @single_chunk(
; CHECK-NOT: fission.more
; CHECK: %fission.continue = icmp ne i64 %next, 8
; CHECK-NEXT: br i1 %fission.continue, label %loop, label %scalar.fission.producer.exit
; ONE-LABEL: define i32 @single_chunk(
; ONE: %fission.more = and i1 %fission.continue,

define i32 @single_chunk(ptr %a, i32 %seed) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %s = phi i32 [%seed, %entry], [%u, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %square = mul i32 %x, %x
  %bias = add i32 %square, 3
  %f = xor i32 %bias, 9
  %u = add i32 %s, %f
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, 8
  br i1 %done, label %exit, label %loop
exit:
  %r = phi i32 [%u, %loop]
  ret i32 %r
}

; %end may be poison when %stop is true. Retain the lazy select and the generic
; inversion; no trip count is assumed. At capacity one, poison in %done must
; still reach the branch, even though the capacity comparison is false.
; CHECK-LABEL: define i32 @lazy_exit(
; CHECK: %done = select i1 %stop, i1 true, i1 %end
; CHECK: %fission.continue = xor i1 %done, true
; CHECK: %fission.more = and i1 %fission.continue,
; ONE-LABEL: define i32 @lazy_exit(
; ONE: %done = select i1 %stop, i1 true, i1 %end
; ONE: %fission.more = and i1 %fission.continue,

define i32 @lazy_exit(ptr %a, i1 %stop, i1 %end, i32 %seed) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %s = phi i32 [%seed, %entry], [%u, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %square = mul i32 %x, %x
  %bias = add i32 %square, 3
  %f = xor i32 %bias, 9
  %u = add i32 %s, %f
  %next = add i64 %i, 1
  %done = select i1 %stop, i1 true, i1 %end
  br i1 %done, label %exit, label %loop
exit:
  %r = phi i32 [%u, %loop]
  ret i32 %r
}

; Do not fold the inverted comparison before preserving its poison flags.
; CHECK-LABEL: define i32 @poison_compare(
; CHECK: %fission.continue = icmp samesign ne i64 -1, 8
; CHECK: %fission.more = and i1 %fission.continue,
; ONE-LABEL: define i32 @poison_compare(
; ONE: %fission.continue = icmp samesign ne i64 -1, 8
; ONE: %fission.more = and i1 %fission.continue,

define i32 @poison_compare(ptr %a, i32 %seed) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %s = phi i32 [%seed, %entry], [%u, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %square = mul i32 %x, %x
  %bias = add i32 %square, 3
  %f = xor i32 %bias, 9
  %u = add i32 %s, %f
  %next = add nuw i64 %i, 1
  %done = icmp samesign eq i64 -1, 8
  br i1 %done, label %exit, label %loop
exit:
  %r = phi i32 [%u, %loop]
  ret i32 %r
}
