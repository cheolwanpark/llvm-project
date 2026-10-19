; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @signed_zero(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
define void @signed_zero(ptr noalias readonly %a, ptr noalias writeonly %out) vscale_range(2,2) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %r0 = phi double [-0.0, %entry], [%n0, %loop]
  %r1 = phi double [-0.0, %entry], [%n1, %loop]
  %r2 = phi double [-0.0, %entry], [%n2, %loop]
  %r3 = phi double [-0.0, %entry], [%n3, %loop]
  %r4 = phi double [-0.0, %entry], [%n4, %loop]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p
  %c1 = fmul double %x, 2.0
  %c2 = fmul double %c1, 3.0
  %c3 = fmul double %c2, 4.0
  %c4 = fmul double %c3, 5.0
  %n0 = fadd reassoc double %r0, %c4
  %n1 = fadd reassoc double %r1, %c4
  %n2 = fadd reassoc double %r2, %c4
  %n3 = fadd reassoc double %r3, %c4
  %n4 = fadd reassoc double %r4, %c4
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, 65
  br i1 %done, label %exit, label %loop
exit:
  store double %n0, ptr %out
  %o1 = getelementptr double, ptr %out, i64 1
  store double %n1, ptr %o1
  %o2 = getelementptr double, ptr %out, i64 2
  store double %n2, ptr %o2
  %o3 = getelementptr double, ptr %out, i64 3
  store double %n3, ptr %o3
  %o4 = getelementptr double, ptr %out, i64 4
  store double %n4, ptr %o4
  ret void
}
