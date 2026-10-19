; RUN: opt -passes='scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-producer-vf=2 -scalar-fission-consumer-vf=4 -scalar-fission-producer-interleave=1 -scalar-fission-consumer-interleave=1 -S %s | FileCheck %s
; CHECK-LABEL: define i32 @vector_pair(
; CHECK-DAG: <2 x i32>
; CHECK-DAG: <4 x i32>
; CHECK: ret i32

define i32 @vector_pair(ptr %a, i64 %n, i32 %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s = phi i32 [%seed, %ph], [%u, %loop]
  %t = phi i32 [7, %ph], [%v, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %square = mul i32 %x, %x
  %f = add i32 %square, 3
  %a1 = add i32 %f, 1
  %a2 = xor i32 %f, 7
  %u = add i32 %s, %a1
  %v = xor i32 %t, %a2
  %next = add i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi i32 [%u, %loop]
  %q = phi i32 [%v, %loop]
  %total = xor i32 %r, %q
  br label %done
done:
  %result = phi i32 [%seed, %entry], [%total, %exit]
  ret i32 %result
}
