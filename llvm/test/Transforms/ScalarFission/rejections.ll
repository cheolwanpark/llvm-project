; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -S %s | FileCheck %s
; A rejection must never leave partial scratch or stage CFG. These calls lack
; one of the required effects/control contracts; no name-based assumptions.

declare i32 @unsafe0(ptr) nounwind memory(none)
declare void @llvm.lifetime.start.p0(i64 immarg, ptr nocapture)
declare void @llvm.lifetime.end.p0(i64 immarg, ptr nocapture)

; Ending an object's lifetime in the producer cannot leave a delayed consumer
; load after that lifetime, even when the object's address is loop-invariant.
; CHECK-LABEL: define i32 @reject_lifetime(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_lifetime(i64 %n) {
entry:
  %p = alloca i32
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %s = phi i32 [9, %entry], [%u, %loop]
  call void @llvm.lifetime.start.p0(i64 4, ptr %p)
  store i32 3, ptr %p
  %x = load i32, ptr %p
  %u = add i32 %s, %x
  call void @llvm.lifetime.end.p0(i64 4, ptr %p)
  %next = add i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi i32 [%u, %loop]
  ret i32 %r
}

; CHECK-LABEL: define i32 @reject_call0(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_call0(ptr %p, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %s = phi i32 [9, %entry], [%u, %loop]
  %x = call i32 @unsafe0(ptr %p)
  %u = add i32 %s, %x
  %next = add i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi i32 [%u, %loop]
  ret i32 %r
}

declare i32 @unsafe1(ptr) willreturn memory(none)
; CHECK-LABEL: define i32 @reject_call1(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_call1(ptr %p, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %s = phi i32 [9, %entry], [%u, %loop]
  %x = call i32 @unsafe1(ptr %p)
  %u = add i32 %s, %x
  %next = add i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi i32 [%u, %loop]
  ret i32 %r
}

declare i32 @unsafe2(ptr) nounwind willreturn memory(readwrite)
; CHECK-LABEL: define i32 @reject_call2(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_call2(ptr %p, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %s = phi i32 [9, %entry], [%u, %loop]
  %x = call i32 @unsafe2(ptr %p)
  %u = add i32 %s, %x
  %next = add i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi i32 [%u, %loop]
  ret i32 %r
}

declare i32 @unsafe3(ptr) nounwind willreturn memory(read) nosync nofree
; CHECK-LABEL: define i32 @reject_call3(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_call3(ptr %p, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %s = phi i32 [9, %entry], [%u, %loop]
  %x = call i32 @unsafe3(ptr %p)
  %u = add i32 %s, %x
  %next = add i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi i32 [%u, %loop]
  ret i32 %r
}

declare i32 @unsafe4(ptr) nounwind willreturn memory(none) convergent
; CHECK-LABEL: define i32 @reject_call4(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_call4(ptr %p, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %s = phi i32 [9, %entry], [%u, %loop]
  %x = call i32 @unsafe4(ptr %p)
  %u = add i32 %s, %x
  %next = add i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi i32 [%u, %loop]
  ret i32 %r
}
