; REQUIRES: asserts
; RUN: opt -verify-each -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' \
; RUN:   -mtriple=riscv64 -mattr=+v,+f,+d,+zvl128b \
; RUN:   -tail-folding-policy=must-fold-tail \
; RUN:   -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=4 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=2 \
; RUN:   -S %S/reduction-fission-scipy-same-vf.ll -o %t
; RUN: FileCheck %s < %t
; RUN: llc -verify-machineinstrs -mtriple=riscv64 -mattr=+v,+f,+d,+zvl128b %t -o /dev/null
; RUN: sed 's/i64 %90, 1024/i64 %90, 257/' %S/reduction-fission-scipy-same-vf.ll | opt -verify-each \
; RUN:   -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' \
; RUN:   -mtriple=riscv64 -mattr=+v,+f,+d,+zvl128b \
; RUN:   -tail-folding-policy=must-fold-tail \
; RUN:   -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=4 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=2 -S -o %t.tail
; RUN: FileCheck %s < %t.tail
; RUN: llc -verify-machineinstrs -mtriple=riscv64 -mattr=+v,+f,+d,+zvl128b %t.tail -o /dev/null
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v \
; RUN:   -tail-folding-policy=must-fold-tail \
; RUN:   -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=16 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=2 \
; RUN:   -S %S/reduction-fission-scipy-same-vf.ll | FileCheck %s --check-prefix=REJECT
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v \
; RUN:   -tail-folding-policy=must-fold-tail \
; RUN:   -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=4 \
; RUN:   -S %S/reduction-fission-scipy-same-vf.ll | FileCheck %s --check-prefix=REJECT
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v \
; RUN:   -tail-folding-policy=must-fold-tail \
; RUN:   -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=4 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=2 \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=8 \
; RUN:   -S %S/reduction-fission-scipy-same-vf.ll | FileCheck %s --check-prefix=REJECT
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v \
; RUN:   -tail-folding-policy=must-fold-tail \
; RUN:   -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=4 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=2 \
; RUN:   -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -S %S/reduction-fission-legality.ll | FileCheck %S/reduction-fission-legality.ll --implicit-check-not=fission.scratch
;
; Explicit stage widths may exceed estimated register capacity for experiments,
; but must not bypass recipe legality, scratch bounds or require new VFs beyond
; the checked candidate set. A partial pair must not silently choose a VF.
;
; CHECK-LABEL: define {{.*}}void @kernel(
; CHECK: vector.fission.producer.body:
; CHECK: @llvm.fabs.nxv4f64
; CHECK-COUNT-2: store <vscale x 4 x double>
; CHECK: vector.fission.accumulator.body:
; CHECK-COUNT-2: load <vscale x 2 x double>
; CHECK: @llvm.vector.reduce.fadd.nxv2f64
;
; REJECT-LABEL: define {{.*}}void @kernel(
; REJECT-NOT: fission
; REJECT: ret void
