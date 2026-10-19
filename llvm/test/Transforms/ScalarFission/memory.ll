; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -pass-remarks-missed=scalar-fission -S %s -o %t 2> %t.err
; RUN: FileCheck %s < %t
;
; A stable consumer-only load moves; the computed helper value is the single
; shared stream. The unrelated store is proven disjoint for ALL iterations.
declare i32 @pure(i32) nounwind willreturn memory(none)
; CHECK-LABEL: define i32 @stable(
; CHECK: alloca
; CHECK-NOT: alloca
; CHECK: call i32 @pure
; CHECK: loop.consume:
; CHECK: load i32, ptr %p.consume
; CHECK: ret i32
define i32 @stable(ptr noalias %a, ptr noalias %out, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %s = phi i32 [9, %entry], [%u, %loop]
  %t = phi i32 [3, %entry], [%v, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %f = call i32 @pure(i32 7)
  %u = add i32 %s, %x
  %v = xor i32 %t, %f
  store i32 5, ptr %out
  %next = add i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi i32 [%u, %loop]
  %q = phi i32 [%v, %loop]
  %result = xor i32 %r, %q
  ret i32 %result
}

; A later producer write can overwrite an earlier consumer read, including
; equal and shifted aliases. Neither a raw relay nor a bitcast wrapper is a
; legal workaround. The entire candidate is rejected without scratch.
; CHECK-LABEL: define i32 @snapshot(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @snapshot(ptr %a, ptr %out, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %s = phi i32 [9, %entry], [%u, %loop]
  %t = phi i32 [3, %entry], [%v, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p
  %bits = bitcast float %x to i32
  %f = call i32 @pure(i32 7)
  %u = add i32 %s, %bits
  %v = xor i32 %t, %f
  store i32 5, ptr %out
  %next = add i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi i32 [%u, %loop]
  %q = phi i32 [%v, %loop]
  %result = xor i32 %r, %q
  ret i32 %result
}

; Retrying at a genuinely computed result is valid even with an aliased store.
; CHECK-LABEL: define i32 @computed_snapshot(
; CHECK: scalar.fission.scratch
; CHECK: store i32 %f
; CHECK: loop.consume:
; CHECK: load i32
; CHECK: ret i32
define i32 @computed_snapshot(ptr %a, ptr %out, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %s = phi i32 [9, %entry], [%u, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %f = mul i32 %x, 3
  %u = add i32 %s, %f
  store i32 5, ptr %out
  %next = add i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi i32 [%u, %loop]
  ret i32 %r
}

; CHECK-LABEL: define i32 @identity_relay(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @identity_relay(ptr %a, ptr %out, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %s = phi i32 [9, %entry], [%u, %loop]
  %x = load i32, ptr %a
  %f = add i32 %x, 0
  %u = add i32 %s, %f
  store i32 5, ptr %out
  %next = add i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi i32 [%u, %loop]
  ret i32 %r
}

; Reuse an existing computed result buffer, with injective nonwrapping stores.
; CHECK-LABEL: define i32 @reuse(
; CHECK-NOT: alloca
; CHECK: scalar.fission.chunk:
; CHECK: loop.consume:
; CHECK: load i32, ptr %p.consume
; CHECK: ret i32
define i32 @reuse(ptr %out, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %s = phi i32 [9, %entry], [%u, %loop]
  %p = getelementptr inbounds i32, ptr %out, i64 %i
  %f = call i32 @pure(i32 7)
  store i32 %f, ptr %p
  %u = add i32 %s, %f
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi i32 [%u, %loop]
  ret i32 %r
}
