; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=520 -vplan-reduction-fission-allow-fp-reordering \
; RUN:   -pass-remarks=vplan-reduction-fission -S %s -o %t.on 2> %t.remarks
; RUN: FileCheck %s < %t.on
; RUN: FileCheck %s --check-prefix=ISOLATION < %t.on
; RUN: FileCheck %s --check-prefix=REMARK < %t.remarks
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.on -o /dev/null
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=520 -vplan-reduction-fission-allow-fp-reordering=false \
; RUN:   -S %s -o %t.off
; RUN: FileCheck %s --check-prefix=ORDERED --implicit-check-not=reassoc < %t.off
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.off -o /dev/null
;
; The first loop exceeds the scratch limit and falls back to ordered ordinary
; vectorization. The second loop fits: only its four sums may gain reassoc.
; Preserve existing ninf on one sum, contract on producer math, and nnan nsz
; (without reassoc) on the unselected min reduction, including scalar tails.
;
; ISOLATION-LABEL: define void @isolated_attempts(
; ISOLATION-NOT: reassoc
; ISOLATION-NOT: vector.fission
; ISOLATION: second.entry:
; ISOLATION: vector.fission.done:
; ISOLATION-NOT: reassoc
; ISOLATION: ret void
;
; CHECK-LABEL: define void @isolated_attempts(
; CHECK: vector.body:
; CHECK: fmul contract <vscale x 2 x double>
; CHECK: call nnan nsz <vscale x 2 x double> @llvm.minnum.
; CHECK-NEXT: {{.*}}call ninf double @llvm.vector.reduce.fadd.
; CHECK-NEXT: {{.*}}call double @llvm.vector.reduce.fadd.
; CHECK: second.entry:
; CHECK: vector.fission.producer.body:
; CHECK: fmul contract <vscale x 8 x double>
; CHECK-NEXT: {{.*}}fmul <vscale x 8 x double>
; CHECK: scalar.fission.producer.body:
; CHECK: fmul contract double
; CHECK-NEXT: {{.*}}fmul double
; CHECK: vector.fission.accumulator.body:
; CHECK: fadd reassoc ninf <vscale x 4 x double>
; CHECK-NEXT: {{.*}}fadd reassoc <vscale x 4 x double>
; CHECK-NEXT: {{.*}}fadd reassoc <vscale x 4 x double>
; CHECK-NEXT: {{.*}}fadd reassoc <vscale x 4 x double>
; CHECK-NEXT: {{.*}}call nnan nsz <vscale x 4 x double> @llvm.minnum.
; CHECK: call reassoc ninf double @llvm.vector.reduce.fadd.{{.*}}(double -0.000000e+00,
; CHECK: call nnan nsz double @llvm.vector.reduce.fmin.
; CHECK: scalar.fission.accumulator.body:
; CHECK: fadd reassoc ninf double
; CHECK-NEXT: {{.*}}fadd reassoc double
; CHECK-NEXT: {{.*}}fadd reassoc double
; CHECK-NEXT: {{.*}}fadd reassoc double
; CHECK-NEXT: {{.*}}call nnan nsz double @llvm.minnum.
; CHECK: ret void
;
; ORDERED-LABEL: define void @isolated_attempts(
; ORDERED: second.entry:
; ORDERED: vector.fission.accumulator.body:
; ORDERED: call ninf double @llvm.vector.reduce.fadd.
; ORDERED: scalar.fission.accumulator.body:
; ORDERED-DAG: fadd ninf double
; ORDERED-DAG: call nnan nsz double @llvm.minnum.
; ORDERED: ret void
;
; REMARK-NOT: split reduction loop
; REMARK: split reduction loop: {{.*}}scratch capacity 65, scratch bytes 520
; REMARK: reduction second.r0: unordered, reordering permission: fission-option
; REMARK: reduction second.r4: unordered, reordering permission: IR
; REMARK-NOT: split reduction loop

define void @isolated_attempts(ptr noalias readonly %a, ptr noalias writeonly %out, ptr noalias readonly %b, ptr noalias writeonly %out2) vscale_range(2,2) {
first.entry:
  br label %first.loop
first.loop:
  %first.i = phi i64 [0, %first.entry], [%first.next, %first.loop]
  %first.r0 = phi double [-0.0, %first.entry], [%first.n0, %first.loop]
  %first.r1 = phi double [-0.0, %first.entry], [%first.n1, %first.loop]
  %first.r2 = phi double [-0.0, %first.entry], [%first.n2, %first.loop]
  %first.r3 = phi double [-0.0, %first.entry], [%first.n3, %first.loop]
  %first.r4 = phi double [-0.0, %first.entry], [%first.n4, %first.loop]
  %first.p = getelementptr double, ptr %a, i64 %first.i
  %first.x = load double, ptr %first.p
  %first.c1 = fmul contract double %first.x, 2.0
  %first.c2 = fmul double %first.c1, 3.0
  %first.c3 = fmul double %first.c2, 4.0
  %first.c4 = fmul double %first.c3, 5.0
  %first.n0 = fadd ninf double %first.r0, %first.c4
  %first.n1 = fadd double %first.r1, %first.c4
  %first.n2 = fadd double %first.r2, %first.c4
  %first.n3 = fadd double %first.r3, %first.c4
  %first.n4 = call nnan nsz double @llvm.minnum.f64(double %first.r4, double %first.c4)
  %first.next = add nuw i64 %first.i, 1
  %first.done = icmp eq i64 %first.next, 1024
  br i1 %first.done, label %first.exit, label %first.loop
first.exit:
  store double %first.n0, ptr %out
  %first.o1 = getelementptr double, ptr %out, i64 1
  store double %first.n1, ptr %first.o1
  %first.o2 = getelementptr double, ptr %out, i64 2
  store double %first.n2, ptr %first.o2
  %first.o3 = getelementptr double, ptr %out, i64 3
  store double %first.n3, ptr %first.o3
  %first.o4 = getelementptr double, ptr %out, i64 4
  store double %first.n4, ptr %first.o4
  br label %second.entry
second.entry:
  br label %second.loop
second.loop:
  %second.i = phi i64 [0, %second.entry], [%second.next, %second.loop]
  %second.r0 = phi double [-0.0, %second.entry], [%second.n0, %second.loop]
  %second.r1 = phi double [-0.0, %second.entry], [%second.n1, %second.loop]
  %second.r2 = phi double [-0.0, %second.entry], [%second.n2, %second.loop]
  %second.r3 = phi double [-0.0, %second.entry], [%second.n3, %second.loop]
  %second.r4 = phi double [-0.0, %second.entry], [%second.n4, %second.loop]
  %second.p = getelementptr double, ptr %b, i64 %second.i
  %second.x = load double, ptr %second.p
  %second.c1 = fmul contract double %second.x, 2.0
  %second.c2 = fmul double %second.c1, 3.0
  %second.c3 = fmul double %second.c2, 4.0
  %second.c4 = fmul double %second.c3, 5.0
  %second.n0 = fadd ninf double %second.r0, %second.c4
  %second.n1 = fadd double %second.r1, %second.c4
  %second.n2 = fadd double %second.r2, %second.c4
  %second.n3 = fadd double %second.r3, %second.c4
  %second.n4 = call nnan nsz double @llvm.minnum.f64(double %second.r4, double %second.c4)
  %second.next = add nuw i64 %second.i, 1
  %second.done = icmp eq i64 %second.next, 65
  br i1 %second.done, label %second.exit, label %second.loop
second.exit:
  store double %second.n0, ptr %out2
  %second.o1 = getelementptr double, ptr %out2, i64 1
  store double %second.n1, ptr %second.o1
  %second.o2 = getelementptr double, ptr %out2, i64 2
  store double %second.n2, ptr %second.o2
  %second.o3 = getelementptr double, ptr %out2, i64 3
  store double %second.n3, ptr %second.o3
  %second.o4 = getelementptr double, ptr %out2, i64 4
  store double %second.n4, ptr %second.o4
  ret void
}

declare double @llvm.minnum.f64(double, double)
