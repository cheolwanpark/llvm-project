; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s
; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-allow-fp-reordering -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s
;
; The structural cut transfers f and a. The private (d+1) operand of a
; can be reconstructed from existing consumer definitions. Removing a's
; store eliminates the duplicated division without opening any input walk.
; The alternative must retain depth three; producer effects and freezes
; still impose their original boundaries.

; CHECK-LABEL: define double @earlier(
; CHECK-COUNT-1: alloca [3 x double]
; CHECK-NOT: alloca
; CHECK-NOT: = fdiv
; CHECK: %f = fmul double %bias, 5.000000e-01
; CHECK-NOT: = fdiv
; CHECK: loop.consume:
; CHECK: %d.consume = fdiv double 1.000000e+00, %f.scratch
; CHECK: %private.consume = fadd double %d.consume, 1.000000e+00
; CHECK: %a0.consume = fmul double %private.consume, %c.consume
; CHECK: ret double

define double @earlier(ptr noalias %a, ptr noalias %out, i64 %n, double %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s0 = phi double [%seed, %ph], [%u0, %loop]
  %s1 = phi double [%seed, %ph], [%u1, %loop]
  %s2 = phi double [%seed, %ph], [%u2, %loop]
  %s3 = phi double [%seed, %ph], [%u3, %loop]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p
  %square = fmul double %x, %x
  %bias = fadd double %square, 1.25
  %f = fmul double %bias, 0.5
  %d = fdiv double 1.0, %f
  %c = fmul double %d, %d
  %private = fadd double %d, 1.0

  %a0 = fmul double %private, %c
  %a1 = fmul double %a0, %f
  %u0 = fadd double %s0, %a0
  %u1 = fadd double %s1, %a1
  %u2 = fadd double %s2, %c
  %u3 = fadd double %s3, %f
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r0 = phi double [%u0, %loop]
  %r1 = phi double [%u1, %loop]
  %r2 = phi double [%u2, %loop]
  %r3 = phi double [%u3, %loop]
  %r01 = fadd double %r0, %r1
  %r23 = fadd double %r2, %r3
  %r = fadd double %r01, %r23
  br label %done
done:
  %result = phi double [%seed, %entry], [%r, %exit]
  ret double %result
}

; A failed alternative keeps the deep structural producer and its two streams.
; CHECK-LABEL: define double @shallow(
; CHECK-COUNT-2: alloca [3 x double]
; CHECK-NOT: alloca
; CHECK: %d = fdiv double 1.000000e+00, %f
; CHECK: store double %a0, ptr
; CHECK: loop.consume:
; CHECK: %a0.scratch = load double
; CHECK-NOT: %a0.consume =
; CHECK: ret double

define double @shallow(ptr noalias %a, ptr noalias %out, i64 %n, double %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s0 = phi double [%seed, %ph], [%u0, %loop]
  %s1 = phi double [%seed, %ph], [%u1, %loop]
  %s2 = phi double [%seed, %ph], [%u2, %loop]
  %s3 = phi double [%seed, %ph], [%u3, %loop]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p
  %square = fmul double %x, %x
  %f = fadd double %square, 1.25

  %d = fdiv double 1.0, %f
  %c = fmul double %d, %d
  %private = fadd double %d, 1.0

  %a0 = fmul double %private, %c
  %a1 = fmul double %a0, %f
  %u0 = fadd double %s0, %a0
  %u1 = fadd double %s1, %a1
  %u2 = fadd double %s2, %c
  %u3 = fadd double %s3, %f
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r0 = phi double [%u0, %loop]
  %r1 = phi double [%u1, %loop]
  %r2 = phi double [%u2, %loop]
  %r3 = phi double [%u3, %loop]
  %r01 = fadd double %r0, %r1
  %r23 = fadd double %r2, %r3
  %r = fadd double %r01, %r23
  br label %done
done:
  %result = phi double [%seed, %entry], [%r, %exit]
  ret double %result
}

; The private addition is still needed by a producer effect.
; CHECK-LABEL: define double @retained_private(
; CHECK-COUNT-2: alloca [3 x double]
; CHECK-NOT: alloca
; CHECK: %private = fadd double %d, 1.000000e+00
; CHECK: store double %private, ptr %out
; CHECK: loop.consume:
; CHECK: %a0.scratch = load double
; CHECK-NOT: %private.consume =
; CHECK: ret double

define double @retained_private(ptr noalias %a, ptr noalias %out, i64 %n, double %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s0 = phi double [%seed, %ph], [%u0, %loop]
  %s1 = phi double [%seed, %ph], [%u1, %loop]
  %s2 = phi double [%seed, %ph], [%u2, %loop]
  %s3 = phi double [%seed, %ph], [%u3, %loop]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p
  %square = fmul double %x, %x
  %bias = fadd double %square, 1.25
  %f = fmul double %bias, 0.5
  %d = fdiv double 1.0, %f
  %c = fmul double %d, %d
  %private = fadd double %d, 1.0
  store double %private, ptr %out
  %a0 = fmul double %private, %c
  %a1 = fmul double %a0, %f
  %u0 = fadd double %s0, %a0
  %u1 = fadd double %s1, %a1
  %u2 = fadd double %s2, %c
  %u3 = fadd double %s3, %f
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r0 = phi double [%u0, %loop]
  %r1 = phi double [%u1, %loop]
  %r2 = phi double [%u2, %loop]
  %r3 = phi double [%u3, %loop]
  %r01 = fadd double %r0, %r1
  %r23 = fadd double %r2, %r3
  %r = fadd double %r01, %r23
  br label %done
done:
  %result = phi double [%seed, %entry], [%r, %exit]
  ret double %result
}

; A mandatory boundary cannot be independently reconstructed.
; CHECK-LABEL: define double @frozen_private(
; CHECK-COUNT-2: alloca [3 x double]
; CHECK-NOT: alloca
; CHECK: %private = freeze double %d
; CHECK: loop.consume:
; CHECK: %a0.scratch = load double
; CHECK-NOT: freeze
; CHECK: ret double

define double @frozen_private(ptr noalias %a, ptr noalias %out, i64 %n, double %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s0 = phi double [%seed, %ph], [%u0, %loop]
  %s1 = phi double [%seed, %ph], [%u1, %loop]
  %s2 = phi double [%seed, %ph], [%u2, %loop]
  %s3 = phi double [%seed, %ph], [%u3, %loop]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p
  %square = fmul double %x, %x
  %bias = fadd double %square, 1.25
  %f = fmul double %bias, 0.5
  %d = fdiv double 1.0, %f
  %c = fmul double %d, %d
  %private = freeze double %d

  %a0 = fmul double %private, %c
  %a1 = fmul double %a0, %f
  %u0 = fadd double %s0, %a0
  %u1 = fadd double %s1, %a1
  %u2 = fadd double %s2, %c
  %u3 = fadd double %s3, %f
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r0 = phi double [%u0, %loop]
  %r1 = phi double [%u1, %loop]
  %r2 = phi double [%u2, %loop]
  %r3 = phi double [%u3, %loop]
  %r01 = fadd double %r0, %r1
  %r23 = fadd double %r2, %r3
  %r = fadd double %r01, %r23
  br label %done
done:
  %result = phi double [%seed, %entry], [%r, %exit]
  ret double %result
}

; Reconstructing an operand cannot make an original load newly available.
; CHECK-LABEL: define double @unavailable_private(
; CHECK-COUNT-2: alloca [3 x double]
; CHECK-NOT: alloca
; CHECK: %private = fadd double %d, %x
; CHECK: loop.consume:
; CHECK: %a0.scratch = load double
; CHECK-NOT: %x.consume = load
; CHECK: ret double

define double @unavailable_private(ptr noalias %a, ptr noalias %out, i64 %n, double %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s0 = phi double [%seed, %ph], [%u0, %loop]
  %s1 = phi double [%seed, %ph], [%u1, %loop]
  %s2 = phi double [%seed, %ph], [%u2, %loop]
  %s3 = phi double [%seed, %ph], [%u3, %loop]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p
  %square = fmul double %x, %x
  %bias = fadd double %square, 1.25
  %f = fmul double %bias, 0.5
  %d = fdiv double 1.0, %f
  %c = fmul double %d, %d
  %private = fadd double %d, %x

  %a0 = fmul double %private, %c
  %a1 = fmul double %a0, %f
  %u0 = fadd double %s0, %a0
  %u1 = fadd double %s1, %a1
  %u2 = fadd double %s2, %c
  %u3 = fadd double %s3, %f
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r0 = phi double [%u0, %loop]
  %r1 = phi double [%u1, %loop]
  %r2 = phi double [%u2, %loop]
  %r3 = phi double [%u3, %loop]
  %r01 = fadd double %r0, %r1
  %r23 = fadd double %r2, %r3
  %r = fadd double %r01, %r23
  br label %done
done:
  %result = phi double [%seed, %entry], [%r, %exit]
  ret double %result
}

; Retained control still needs the division, even if the result stream moves.
; CHECK-LABEL: define double @retained_control(
; CHECK: %d = fdiv double 1.000000e+00, %f
; CHECK: %private = fadd double %d, 1.000000e+00
; CHECK: %choose = fcmp ogt double %private, 0.000000e+00
; CHECK: br i1 %choose, label %update, label %latch
; CHECK: loop.consume:
; CHECK: %d.consume = fdiv double 1.000000e+00, %f.scratch
; CHECK: %private.consume = fadd double %d.consume, 1.000000e+00
; CHECK: br i1 %choose.consume, label %update.consume, label %latch.consume
; CHECK: ret double

define double @retained_control(ptr noalias %a, ptr noalias %out, i64 %n, double %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %latch]
  %s0 = phi double [%seed, %ph], [%v0, %latch]
  %s1 = phi double [%seed, %ph], [%v1, %latch]
  %s2 = phi double [%seed, %ph], [%v2, %latch]
  %s3 = phi double [%seed, %ph], [%v3, %latch]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p
  %square = fmul double %x, %x
  %bias = fadd double %square, 1.25
  %f = fmul double %bias, 0.5
  %d = fdiv double 1.0, %f
  %c = fmul double %d, %d
  %private = fadd double %d, 1.0

  %choose = fcmp ogt double %private, 0.0
  br i1 %choose, label %update, label %latch
update:
  %a0 = fmul double %private, %c
  %a1 = fmul double %a0, %f
  %u0 = fadd double %s0, %a0
  %u1 = fadd double %s1, %a1
  %u2 = fadd double %s2, %c
  %u3 = fadd double %s3, %f
  br label %latch
latch:
  %v0 = phi double [%s0, %loop], [%u0, %update]
  %v1 = phi double [%s1, %loop], [%u1, %update]
  %v2 = phi double [%s2, %loop], [%u2, %update]
  %v3 = phi double [%s3, %loop], [%u3, %update]
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r0 = phi double [%v0, %latch]
  %r1 = phi double [%v1, %latch]
  %r2 = phi double [%v2, %latch]
  %r3 = phi double [%v3, %latch]
  %r01 = fadd double %r0, %r1
  %r23 = fadd double %r2, %r3
  %r = fadd double %r01, %r23
  br label %done
done:
  %result = phi double [%seed, %entry], [%r, %exit]
  ret double %result
}
