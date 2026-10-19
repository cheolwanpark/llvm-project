; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -scalar-fission-allow-fp-reordering -verify-each -S %s | FileCheck %s --implicit-check-not=reassoc
; Coupled compensated state and accumulator-dependent FMA move in exact order;
; neither is granted sum reassociation by the opt-in policy.
declare double @square(double) nounwind willreturn memory(none)
declare double @llvm.fma.f64(double, double, double)

; CHECK-LABEL: define double @compensated(
; CHECK: scalar.fission.chunk:
; CHECK: fsub double
; CHECK: fadd double
; CHECK: ret double
define double @compensated(ptr %input, i64 %n, double %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %sum = phi double [%seed, %ph], [%sum.next, %loop]
  %error = phi double [0.0, %ph], [%error.next, %loop]
  %p = getelementptr double, ptr %input, i64 %i
  %x = load double, ptr %p
  %f = call double @square(double %x)
  %y = fsub double %f, %error
  %sum.next = fadd double %sum, %y
  %delta = fsub double %sum.next, %sum
  %error.next = fsub double %delta, %y
  %next = add i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi double [%sum.next, %loop]
  br label %done
done:
  %result = phi double [%seed, %entry], [%r, %exit]
  ret double %result
}

; CHECK-LABEL: define double @state_fma(
; CHECK: scalar.fission.chunk:
; CHECK: call double @llvm.fma.f64
; CHECK: ret double
define double @state_fma(ptr %input, i64 %n, double %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %sum = phi double [%seed, %ph], [%sum.next, %loop]
  %p = getelementptr double, ptr %input, i64 %i
  %x = load double, ptr %p
  %f = call double @square(double %x)
  %sum.next = call double @llvm.fma.f64(double %sum, double 5.0e-1, double %f)
  %next = add i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi double [%sum.next, %loop]
  br label %done
done:
  %result = phi double [%seed, %entry], [%r, %exit]
  ret double %result
}
