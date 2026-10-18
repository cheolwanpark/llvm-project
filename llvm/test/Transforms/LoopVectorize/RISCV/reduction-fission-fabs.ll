; RUN: opt -verify-each -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' \
; RUN:   -mtriple=riscv64 -mattr=+v \
; RUN:   -tail-folding-policy=must-fold-tail \
; RUN:   -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false \
; RUN:   -S %s -o %t
; RUN: FileCheck %s < %t
; RUN: llc -verify-machineinstrs -mtriple=riscv64 -mattr=+v %t -o - \
; RUN:   | FileCheck %s --check-prefix=ASM
; RUN: sed 's/llvm.fabs/llvm.sqrt/g' %s | opt -passes=loop-vectorize \
; RUN:   -mtriple=riscv64 -mattr=+v \
; RUN:   -tail-folding-policy=must-fold-tail \
; RUN:   -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false \
; RUN:   -S -o %t.sqrt
; RUN: FileCheck %s --check-prefix=SQRT < %t.sqrt
; RUN: llc -verify-machineinstrs -mtriple=riscv64 -mattr=+v %t.sqrt -o /dev/null
;
; fabs is elementwise and must remain valid when stage VFs differ. Exercise it
; in both the long producer chain and a short chain retained with accumulators.
; Neither fabs call has fast-math flags: permitting it must not require them.
; The same general legality check admits vectorizable sqrt at legal stage VFs.
;
; CHECK-LABEL: define void @fabs_producer_and_accumulator(
; CHECK: vector.fission.producer.body:
; CHECK: call <vscale x 4 x double> @llvm.fabs.nxv4f64
; CHECK: store <vscale x 4 x double>
; CHECK: scalar.fission.producer.body:
; CHECK: call double @llvm.fabs.f64
; CHECK: call fast double @llvm.fma.f64
; CHECK: vector.fission.accumulator.body:
; CHECK: call <vscale x 2 x double> @llvm.fabs.nxv2f64
; CHECK: @llvm.vector.reduce.fadd.nxv2f64
; CHECK: scalar.fission.accumulator.body:
; CHECK: call double @llvm.fabs.f64
;
; ASM-LABEL: fabs_producer_and_accumulator:
; ASM: vfabs.v
; ASM: vfabs.v
; ASM: ret
;
; SQRT-LABEL: define void @fabs_producer_and_accumulator(
; SQRT: vector.fission.producer.body:
; SQRT: @llvm.sqrt.nxv4f64
; SQRT: vector.fission.accumulator.body:
; SQRT: @llvm.sqrt.nxv2f64
; SQRT: ret void

define void @fabs_producer_and_accumulator(ptr noalias readonly %x, ptr noalias readonly %y,
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
  %z.raw = fmul fast double %xv, %frequency
  %z = call double @llvm.fabs.f64(double %z.raw)
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
  %yv.raw = load double, ptr %yp, align 8
  %yv = call double @llvm.fabs.f64(double %yv.raw)
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

declare double @llvm.fabs.f64(double)
