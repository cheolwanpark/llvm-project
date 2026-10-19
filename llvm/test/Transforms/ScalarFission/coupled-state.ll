; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -S %s | FileCheck %s
; Closed mutually dependent state is moved as a group, without reduction
; recognition or an assumption that its updates are associative.
; CHECK-LABEL: define i32 @coupled(
; CHECK: scalar.fission.chunk:
; CHECK: loop.consume:
; CHECK: %a.consume = phi i32
; CHECK: %b.consume = phi i32
; CHECK: ret i32

declare i32 @pure(i32) nounwind willreturn memory(none)
define i32 @coupled(ptr %input, i64 %n, i32 %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %a = phi i32 [%seed, %ph], [%anext, %loop]
  %b = phi i32 [7, %ph], [%bnext, %loop]
  %p = getelementptr i32, ptr %input, i64 %i
  %x = load i32, ptr %p
  %f = call i32 @pure(i32 %x)
  %mix = add i32 %a, %b
  %anext = add i32 %mix, %f
  %bnext = xor i32 %b, %a
  %next = add i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %ra = phi i32 [%anext, %loop]
  %rb = phi i32 [%bnext, %loop]
  %total = xor i32 %ra, %rb
  br label %done
done:
  %result = phi i32 [%seed, %entry], [%total, %exit]
  ret i32 %result
}
