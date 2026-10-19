; RUN: opt -passes=scalar-fission -verify-each -S %s | FileCheck %s
; No input snapshot may reach scratch through selection, identity arithmetic,
; or freezing, including a select with only one computed alternative.
declare i32 @pure(i32) nounwind willreturn memory(none)

; CHECK-LABEL: define i32 @relay_select(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @relay_select(ptr %a, ptr %out, i64 %n, i1 %choose) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %sum = phi i32 [7, %entry], [%u, %loop]
  %sum2 = phi i32 [9, %entry], [%u2, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %y = load i32, ptr %a
  %f = select i1 %choose, i32 %x, i32 %y
  %c = call i32 @pure(i32 7)
  %u = add i32 %sum, %f
  %u2 = add i32 %sum2, %c
  store i32 0, ptr %out
  %next = add i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi i32 [%u, %loop]
  %r2 = phi i32 [%u2, %loop]
  %result = xor i32 %r, %r2
  ret i32 %result
}

; CHECK-LABEL: define i32 @relay_or_identity(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @relay_or_identity(ptr %a, ptr %out, i64 %n, i1 %choose) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %sum = phi i32 [7, %entry], [%u, %loop]
  %sum2 = phi i32 [9, %entry], [%u2, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %y = load i32, ptr %a
  %f = or i32 %x, %x
  %c = call i32 @pure(i32 7)
  %u = add i32 %sum, %f
  %u2 = add i32 %sum2, %c
  store i32 0, ptr %out
  %next = add i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi i32 [%u, %loop]
  %r2 = phi i32 [%u2, %loop]
  %result = xor i32 %r, %r2
  ret i32 %result
}

; CHECK-LABEL: define i32 @relay_freeze(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @relay_freeze(ptr %a, ptr %out, i64 %n, i1 %choose) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %sum = phi i32 [7, %entry], [%u, %loop]
  %sum2 = phi i32 [9, %entry], [%u2, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %y = load i32, ptr %a
  %f = freeze i32 %x
  %c = call i32 @pure(i32 7)
  %u = add i32 %sum, %f
  %u2 = add i32 %sum2, %c
  store i32 0, ptr %out
  %next = add i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi i32 [%u, %loop]
  %r2 = phi i32 [%u2, %loop]
  %result = xor i32 %r, %r2
  ret i32 %result
}

; CHECK-LABEL: define i32 @relay_mixed_select(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @relay_mixed_select(ptr %a, ptr %out, i64 %n, i1 %choose) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %sum = phi i32 [7, %entry], [%u, %loop]
  %sum2 = phi i32 [9, %entry], [%u2, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %y = load i32, ptr %a
  %squared = mul i32 %x, %x
  %f = select i1 %choose, i32 %squared, i32 %y
  %c = call i32 @pure(i32 7)
  %u = add i32 %sum, %f
  %u2 = add i32 %sum2, %c
  store i32 0, ptr %out
  %next = add i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi i32 [%u, %loop]
  %r2 = phi i32 [%u2, %loop]
  %result = xor i32 %r, %r2
  ret i32 %result
}
