; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,loop-vectorize' -verify-each -scalar-fission-chunk-capacity=1 -disable-output %s
; RUN: opt -passes=scalar-fission -scalar-fission-allow-fp-reordering -S %s | FileCheck %s --check-prefix=RELAX
;
; Standalone fission, unknown total count, nonidentity seeds and shared private
; suffixes. A width-one vectorization hint must not disable fission.
; CHECK-LABEL: define double @shared(
; CHECK: alloca [3 x double]
; CHECK-NOT: alloca
; CHECK: scalar.fission.chunk:
; CHECK: loop.consume:
; CHECK: fadd double
; CHECK: fsub double
; RELAX-LABEL: define double @shared(
; RELAX: fadd reassoc double
; RELAX: fsub double

define double @shared(ptr %a, i64 %n, double %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s = phi double [%seed, %ph], [%u, %loop]
  %t = phi double [1.0, %ph], [%v, %loop]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p
  %f = fmul double %x, %x
  %a1 = fadd double %f, 3.0
  %a2 = fmul double %f, 2.0
  %u = fadd double %s, %a1
  %v = fsub double %t, %a2
  %next = add i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit, !llvm.loop !0
exit:
  %r = phi double [%u, %loop]
  %r2 = phi double [%v, %loop]
  %total = fadd double %r, %r2
  br label %done
done:
  %result = phi double [%seed, %entry], [%total, %exit]
  ret double %result
}

; Different participation conditions, eager select semantics, and compound
; nonassociative updates. No reduction descriptor is needed.
; CHECK-LABEL: define i32 @conditions(
; CHECK: scalar.fission.chunk:
; CHECK: loop.consume:
; CHECK: select i1
; CHECK: left.consume:
; CHECK: mul i32
; CHECK: latch.consume:
; CHECK: phi i32

define i32 @conditions(ptr %a, i64 %n, i32 %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %latch]
  %s = phi i32 [%seed, %ph], [%u, %latch]
  %t = phi i32 [7, %ph], [%v, %latch]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %f = mul i32 %x, %x
  %odd = and i64 %i, 1
  %c = icmp ne i64 %odd, 0
  %d = icmp sgt i32 %f, 8
  %sum = add i32 %s, %f
  %u = select i1 %d, i32 %sum, i32 %s
  br i1 %c, label %left, label %latch
left:
  %scaled = mul i32 %t, 3
  %updated = sub i32 %scaled, %f
  br label %latch
latch:
  %v = phi i32 [%t, %loop], [%updated, %left]
  %next = add i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi i32 [%u, %latch]
  %q = phi i32 [%v, %latch]
  %total = xor i32 %r, %q
  br label %done
done:
  %result = phi i32 [%seed, %entry], [%total, %exit]
  ret i32 %result
}

; Producer-local helper calls need neither a vector mapping nor speculatable.
declare i32 @helper(ptr) nounwind willreturn nosync nofree nocallback memory(argmem: read)
; CHECK-LABEL: define i32 @data_exit(
; CHECK: call i32 @helper
; CHECK: scalar.fission.chunk:
; CHECK: loop.consume:
; CHECK-NOT: call i32 @helper
; CHECK: ret i32

define i32 @data_exit(ptr %a) {
entry:
  br label %loop
loop:
  %p = phi ptr [%a, %entry], [%next, %loop]
  %s = phi i32 [19, %entry], [%u, %loop]
  %x = call i32 @helper(ptr %p)
  %u = add i32 %s, %x
  %next = getelementptr i32, ptr %p, i64 1
  %more = icmp ne i32 %x, 0
  br i1 %more, label %loop, label %exit
exit:
  %r = phi i32 [%u, %loop]
  ret i32 %r
}

!0 = distinct !{!0, !1}
!1 = !{!"llvm.loop.vectorize.width", i32 1}
