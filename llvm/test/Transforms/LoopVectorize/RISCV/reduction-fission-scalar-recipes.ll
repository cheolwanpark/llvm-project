; RUN: sed 's/getelementptr i32, ptr %base/getelementptr i16, ptr %base/' %S/reduction-fission-general.ll \
; RUN:   | sed 's/%x = load i32, ptr %%p, align 4/%raw = load i16, ptr %%p, align 2 %x = sext i16 %raw to i32/' \
; RUN:   | opt -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:     -force-vector-interleave=1 -enable-vplan-reduction-fission \
; RUN:     -vplan-reduction-fission-min-chain-depth=4 \
; RUN:     -vplan-reduction-fission-force-producer-vf=16 \
; RUN:     -vplan-reduction-fission-force-accumulator-vf=2 -S -o %t.cast
; RUN: FileCheck %s --check-prefix=CAST < %t.cast
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.cast -o /dev/null
; RUN: sed 's/%n5 = call i32 @llvm.umax.i32(i32 %r5, i32 %c5)/%cmp = icmp ugt i32 %r5, %c5 %n5 = select i1 %cmp, i32 %r5, i32 %c5/' %S/reduction-fission-general.ll \
; RUN:   | opt -passes='instcombine,loop-vectorize' -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:     -force-vector-interleave=1 -enable-vplan-reduction-fission \
; RUN:     -vplan-reduction-fission-min-chain-depth=4 \
; RUN:     -vplan-reduction-fission-force-producer-vf=16 \
; RUN:     -vplan-reduction-fission-force-accumulator-vf=2 -S -o %t.minmax
; RUN: FileCheck %s --check-prefix=MINMAX < %t.minmax
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.minmax -o /dev/null
;
; LLVM 23's widened arithmetic, casts and intrinsics cannot execute at VF=1.
; Scalar companions must lower these recipes while retaining their types,
; including min/max canonicalized from compare/select before vectorization.
;
; CAST-LABEL: define void @general(
; CAST: vector.fission.producer.body:
; CAST: load <vscale x 16 x i16>
; CAST: sext <vscale x 16 x i16> {{.*}} to <vscale x 16 x i32>
; CAST: scalar.fission.producer.body:
; CAST: load i16
; CAST: sext i16 {{.*}} to i32
; CAST: store i32
; CAST: vector.fission.accumulator.body:
; CAST: load <vscale x 2 x i32>
;
; MINMAX-LABEL: define void @general(
; MINMAX: vector.fission.accumulator.body:
; MINMAX: @llvm.umax.nxv2i32
; MINMAX: scalar.fission.accumulator.body:
; MINMAX: @llvm.umax.i32
