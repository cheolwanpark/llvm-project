; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -S %s | FileCheck %s
; RUN: opt -passes='instcombine,scalar-fission' -verify-each -S %s | FileCheck %s
; RUN: opt -passes='simplifycfg,scalar-fission' -verify-each -S %s | FileCheck %s
;
; Rotation is the only needed control normalization. SimplifyCFG's conversion
; of the conditional FP update to select must not change eligibility.
; CHECK-LABEL: define double @pretested(
; CHECK: scalar.fission.chunk:
; CHECK: fadd double
; CHECK: ret double

declare double @expensive(double) nounwind willreturn memory(none)
define double @pretested(ptr %a, i64 %n, double %seed) {
entry:
  br label %header
header:
  %i = phi i64 [0, %entry], [%next, %latch]
  %sum = phi double [%seed, %entry], [%merged, %latch]
  %more = icmp ult i64 %i, %n
  br i1 %more, label %body, label %exit
body:
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p
  %scaled = fmul double %x, 0.5
  %biased = fadd double %scaled, 1.25
  %f = call double @expensive(double %biased)
  %positive = fcmp ogt double %f, 0.0
  br i1 %positive, label %update, label %latch
update:
  %u = fadd double %sum, %f
  br label %latch
latch:
  %merged = phi double [%sum, %body], [%u, %update]
  %next = add i64 %i, 1
  br label %header
exit:
  ret double %sum
}
