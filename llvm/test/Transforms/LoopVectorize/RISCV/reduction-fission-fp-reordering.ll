; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -vplan-reduction-fission-allow-fp-reordering -S %s -o %t
; RUN: FileCheck %s --check-prefix=RELAXED < %t
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t -o - | FileCheck %s --check-prefix=ASM
; RUN: opt -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false \
; RUN:   -vplan-reduction-fission-min-chain-depth=4 -S %s -o %t.default
; RUN: opt -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false \
; RUN:   -vplan-reduction-fission-min-chain-depth=4 -vplan-reduction-fission-allow-fp-reordering=false \
; RUN:   -S %s -o %t.false
; RUN: diff %t.default %t.false
; RUN: FileCheck %s --check-prefix=DEFAULT < %t.default
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false \
; RUN:   -force-ordered-reductions=false -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false \
; RUN:   -vplan-reduction-fission-min-chain-depth=4 -vplan-reduction-fission-allow-fp-reordering \
; RUN:   -S %s -o %t.early
; RUN: FileCheck %s --check-prefix=RELAXED < %t.early
; RUN: opt -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=1 -S %s -o %t.reject
; RUN: opt -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=1 -vplan-reduction-fission-allow-fp-reordering \
; RUN:   -S %s -o %t.reject-relaxed
; RUN: diff %t.reject %t.reject-relaxed
; RUN: opt -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -force-vector-interleave=1 -hints-allow-reordering=false -vplan-reduction-fission-allow-fp-reordering \
; RUN:   -S %s -o %t.disabled
; RUN: diff %t.default %t.disabled
; RUN: opt -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false \
; RUN:   -vplan-reduction-fission-allow-fp-reordering -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -force-vector-width=2 -S %s | FileCheck %s --check-prefix=NOFISSION
; RUN: opt -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -force-vector-interleave=2 -hints-allow-reordering=false -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false \
; RUN:   -vplan-reduction-fission-allow-fp-reordering -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -S %s | FileCheck %s --check-prefix=NOFISSION
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v \
; RUN:   -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false \
; RUN:   -vplan-reduction-fission-allow-fp-reordering -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -pass-remarks=vplan-reduction-fission -disable-output %s 2>&1 | FileCheck %s --check-prefix=REMARK
; NOFISSION-LABEL: define void @fp_reordering(
; NOFISSION-NOT: fission
; NOFISSION-NOT: reassoc
; NOFISSION: ret void
; REMARK: split reduction loop: baseline VF {{.*}}, producer VF {{.*}}, accumulator VF {{.*}}, trip count constant, scratch capacity 65, scratch bytes 520
; REMARK: reduction r0: unordered, reordering permission: fission-option
;
; Only recurrence adds gain reassoc. Producer math retains its original flags;
; no nnan/ninf/nsz/contract assumptions are added and -0.0 is the identity.
; RELAXED-LABEL: define void @fp_reordering(
; RELAXED: vector.fission.producer.body:
; RELAXED: fmul <vscale x
; RELAXED-NOT: fmul reassoc
; RELAXED: vector.fission.accumulator.body:
; RELAXED: fadd reassoc <vscale x
; RELAXED: call reassoc double @llvm.vector.reduce.fadd.{{.*}}(double -0.000000e+00,
; RELAXED: scalar.fission.accumulator.body:
; RELAXED: fadd reassoc double
; DEFAULT-NOT: fadd reassoc
; DEFAULT: @llvm.vp.reduce.fadd
; DEFAULT-NOT: fadd reassoc
; ASM: vfredusum.vs

define void @fp_reordering(ptr noalias readonly %a, ptr noalias writeonly %out) vscale_range(2,2) {
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
  %n0 = fadd double %r0, %c4
  %n1 = fadd double %r1, %c4
  %n2 = fadd double %r2, %c4
  %n3 = fadd double %r3, %c4
  %n4 = fadd double %r4, %c4
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

; RELAXED-LABEL: define void @strict_fp(
; RELAXED-NOT: fission
; RELAXED-NOT: reassoc
; RELAXED: ret void

define void @strict_fp(ptr noalias readonly %a, ptr noalias writeonly %out) strictfp vscale_range(2,2) {
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
  %n0 = fadd double %r0, %c4
  %n1 = fadd double %r1, %c4
  %n2 = fadd double %r2, %c4
  %n3 = fadd double %r3, %c4
  %n4 = fadd double %r4, %c4
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

; RELAXED-LABEL: define void @multiple_updates(
; RELAXED-NOT: fission
; RELAXED: ret void

define void @multiple_updates(ptr noalias readonly %a, ptr noalias writeonly %out) vscale_range(2,2) {
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
  %intermediate = fadd double %r0, %c4
  %n0 = fadd double %intermediate, 1.0
  %n1 = fadd double %r1, %c4
  %n2 = fadd double %r2, %c4
  %n3 = fadd double %r3, %c4
  %n4 = fadd double %r4, %c4
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

; RELAXED-LABEL: define void @accumulator_fma(
; RELAXED-NOT: fission
; RELAXED: ret void

define void @accumulator_fma(ptr noalias readonly %a, ptr noalias writeonly %out) vscale_range(2,2) {
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
  %n0 = call double @llvm.fmuladd.f64(double %c4, double 2.0, double %r0)
  %n1 = fadd double %r1, %c4
  %n2 = fadd double %r2, %c4
  %n3 = fadd double %r3, %c4
  %n4 = fadd double %r4, %c4
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

declare double @llvm.fmuladd.f64(double, double, double)
