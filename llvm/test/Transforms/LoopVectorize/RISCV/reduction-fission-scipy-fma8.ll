; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @scipy_fma8_fixed(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
define void @scipy_fma8_fixed(ptr noalias readonly %x, ptr noalias readonly %y,
                              double %frequency, ptr noalias writeonly %out) {
entry:
  br label %loop

loop:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %loop ]
  %xc = phi double [ 0.0, %entry ], [ %xc.next, %loop ]
  %xs = phi double [ 0.0, %entry ], [ %xs.next, %loop ]
  %cc = phi double [ 0.0, %entry ], [ %cc.next, %loop ]
  %ss = phi double [ 0.0, %entry ], [ %ss.next, %loop ]
  %cs = phi double [ 0.0, %entry ], [ %cs.next, %loop ]
  %xp = getelementptr inbounds double, ptr %x, i64 %iv
  %xv = load double, ptr %xp, align 8
  %z = fmul fast double %xv, %frequency
  %c0 = fadd fast double %z, 0.25
  %s1 = call fast double @llvm.fma.f64(double %z, double 1.0001, double 0.0003)
  %c1 = call fast double @llvm.fma.f64(double %c0, double 0.9999, double -0.0002)
  %s2 = call fast double @llvm.fma.f64(double %s1, double 1.0001, double 0.0003)
  %c2 = call fast double @llvm.fma.f64(double %c1, double 0.9999, double -0.0002)
  %s3 = call fast double @llvm.fma.f64(double %s2, double 1.0001, double 0.0003)
  %c3 = call fast double @llvm.fma.f64(double %c2, double 0.9999, double -0.0002)
  %s4 = call fast double @llvm.fma.f64(double %s3, double 1.0001, double 0.0003)
  %c4 = call fast double @llvm.fma.f64(double %c3, double 0.9999, double -0.0002)
  %s5 = call fast double @llvm.fma.f64(double %s4, double 1.0001, double 0.0003)
  %c5 = call fast double @llvm.fma.f64(double %c4, double 0.9999, double -0.0002)
  %s6 = call fast double @llvm.fma.f64(double %s5, double 1.0001, double 0.0003)
  %c6 = call fast double @llvm.fma.f64(double %c5, double 0.9999, double -0.0002)
  %s7 = call fast double @llvm.fma.f64(double %s6, double 1.0001, double 0.0003)
  %c7 = call fast double @llvm.fma.f64(double %c6, double 0.9999, double -0.0002)
  %s8 = call fast double @llvm.fma.f64(double %s7, double 1.0001, double 0.0003)
  %c8 = call fast double @llvm.fma.f64(double %c7, double 0.9999, double -0.0002)
  %yp = getelementptr inbounds double, ptr %y, i64 %iv
  %yv = load double, ptr %yp, align 8
  %xc.term = fmul fast double %yv, %c8
  %xc.next = fadd fast double %xc, %xc.term
  %xs.term = fmul fast double %yv, %s8
  %xs.next = fadd fast double %xs, %xs.term
  %cc.term = fmul fast double %c8, %c8
  %cc.next = fadd fast double %cc, %cc.term
  %ss.term = fmul fast double %s8, %s8
  %ss.next = fadd fast double %ss, %ss.term
  %cs.term = fmul fast double %c8, %s8
  %cs.next = fadd fast double %cs, %cs.term
  %iv.next = add nuw i64 %iv, 1
  %done = icmp eq i64 %iv.next, 1024
  br i1 %done, label %exit, label %loop

exit:
  store double %xc.next, ptr %out, align 8
  %o1 = getelementptr inbounds double, ptr %out, i64 1
  store double %xs.next, ptr %o1, align 8
  %o2 = getelementptr inbounds double, ptr %out, i64 2
  store double %cc.next, ptr %o2, align 8
  %o3 = getelementptr inbounds double, ptr %out, i64 3
  store double %ss.next, ptr %o3, align 8
  %o4 = getelementptr inbounds double, ptr %out, i64 4
  store double %cs.next, ptr %o4, align 8
  ret void
}

declare double @llvm.fma.f64(double, double, double)
