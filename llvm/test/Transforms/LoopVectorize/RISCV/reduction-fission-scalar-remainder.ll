; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -vplan-reduction-fission-force-producer-vf=16 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=2 \
; RUN:   -S %S/reduction-fission-general.ll -o %t
; RUN: FileCheck %s --implicit-check-not=llvm.masked --implicit-check-not=llvm.get.active.lane.mask < %t
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t -o /dev/null
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -vplan-reduction-fission-force-producer-vf=16 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=2 \
; RUN:   -tail-folding-policy=must-fold-tail -force-tail-folding-style=data \
; RUN:   -S %S/reduction-fission-general.ll -o %t.masked-baseline
; RUN: FileCheck %s --implicit-check-not=llvm.masked --implicit-check-not=llvm.get.active.lane.mask < %t.masked-baseline
; RUN: sed 's/257/7/g' %S/reduction-fission-general.ll | opt \
; RUN:   -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -vectorizer-min-trip-count=0 -vplan-reduction-fission-force-producer-vf=16 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=4 -S -o %t.small
; RUN: FileCheck %s --check-prefix=SMALL --implicit-check-not=llvm.masked < %t.small
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.small -o /dev/null
; RUN: sed 's/257/32/g' %S/reduction-fission-general.ll | opt \
; RUN:   -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -vplan-reduction-fission-force-producer-vf=16 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=2 -S -o %t.exact
; RUN: FileCheck %s --implicit-check-not=llvm.masked < %t.exact
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.exact -o /dev/null
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<loops>,verify<domtree>' \
; RUN:   -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -vplan-reduction-fission-force-producer-vf=16 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=2 \
; RUN:   -S %S/reduction-fission-general.ll | FileCheck %s \
; RUN:   --implicit-check-not='label %vector.body' --implicit-check-not=llvm.masked
;
; The odd trip count needs a real scalar remainder in both stages. Full vector
; chunks must not access outside the scratch allocation, even when runtime VF
; exceeds TC. The producer remainder must finish before the accumulator starts.
; General also checks nonzero reduction starts, multi-update chains and min/max.
; CHECK-LABEL: define void @general(
; CHECK: fission.vector.trip.count
; CHECK: br i1 {{.*}}, label %{{.*}}, label %{{.*}}
; CHECK: vector.fission.producer.body:
; CHECK: load <vscale x 16 x i32>
; CHECK: store <vscale x 16 x i32>
; CHECK: scalar.fission.producer.body:
; CHECK: load i32
; CHECK: @llvm.abs.i32
; CHECK: store i32
; CHECK: vector.fission.accumulator.body:
; CHECK: load <vscale x 2 x i32>
; CHECK: @llvm.vector.reduce.xor.
; CHECK: scalar.fission.accumulator.body:
; CHECK: phi i32
; CHECK: load i32
; CHECK: add i32
; CHECK: xor i32
; CHECK: @llvm.umax.i32
; CHECK: vector.fission.done:
;
; VLEN=128 gives runtime widths 32 and 8, both greater than N=7. Bypass
; resumes the original nonzero initializers, not a vector value from an
; unexecuted predecessor. With larger N, the same phis resume vector results.
; SMALL: [[PN:%.*]] = sub i64 7,
; SMALL: [[PB:%.*]] = icmp eq i64 [[PN]], 0
; SMALL: br i1 [[PB]], label %scalar.fission.producer.check, label %vector.fission.producer.ph
; SMALL: scalar.fission.producer.body:
; SMALL: phi i64 [ [[PN]], %scalar.fission.producer.ph ]
; SMALL: [[AN:%.*]] = sub i64 7,
; SMALL: [[AB:%.*]] = icmp eq i64 [[AN]], 0
; SMALL: br i1 [[AB]], label %scalar.fission.accumulator.check, label %vector.fission.accumulator.vector.ph
; SMALL: scalar.fission.accumulator.check:
; SMALL: [[RESUME:%.*]] = phi i32 [ 1, %vector.fission.accumulator.ph ], [ {{.*}}, %vector.fission.accumulator.exit.ph ]
; SMALL: scalar.fission.accumulator.body:
; SMALL: phi i64 [ [[AN]], %scalar.fission.accumulator.ph ]
; SMALL: phi i32 [ [[RESUME]], %scalar.fission.accumulator.ph ]
