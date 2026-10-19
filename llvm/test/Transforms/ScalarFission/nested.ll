; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -scalar-fission-chunk-capacity=2 -verify-each -S %s | FileCheck %s
; RUN: opt -passes='scalar-fission,loop-vectorize' -scalar-fission-chunk-capacity=1 -verify-each -disable-output %s
;
; The inner producer, including its memory-effect call, stays intact. Its
; LCSSA result crosses the outer boundary. The total outer count is unknown.
; CHECK-LABEL: define i32 @nested(
; CHECK: inner:
; CHECK: call i32 @effect
; CHECK: scalar.fission.chunk:
; CHECK: outer.consume:
; CHECK-NOT: inner.consume:
; CHECK: inner.exit.consume:
; CHECK: load i32
; CHECK: ret i32

declare i32 @effect(ptr) nounwind willreturn nosync nofree nocallback memory(argmem: readwrite)

define i32 @nested(ptr %p, i64 %n, i32 %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %outer
outer:
  %i = phi i64 [0, %ph], [%inext, %latch]
  %s = phi i32 [%seed, %ph], [%u, %latch]
  br label %inner.ph
inner.ph:
  br label %inner
inner:
  %j = phi i32 [0, %inner.ph], [%jnext, %inner]
  %v = phi i32 [0, %inner.ph], [%vnext, %inner]
  %x = call i32 @effect(ptr %p)
  %vnext = add i32 %v, %x
  %jnext = add i32 %j, 1
  %again = icmp ne i32 %jnext, 3
  br i1 %again, label %inner, label %inner.exit
inner.exit:
  %value = phi i32 [%vnext, %inner]
  br label %latch
latch:
  %u = add i32 %s, %value
  %inext = add i64 %i, 1
  %more = icmp ne i64 %inext, %n
  br i1 %more, label %outer, label %exit
exit:
  %r = phi i32 [%u, %latch]
  br label %done
done:
  %result = phi i32 [%seed, %entry], [%r, %exit]
  ret i32 %result
}
