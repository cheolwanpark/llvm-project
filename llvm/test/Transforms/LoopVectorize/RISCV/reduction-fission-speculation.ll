; RUN: sed 's/%c4 = mul i32 %c3, 13/%c4 = udiv i32 %c3, %x/' %S/reduction-fission-general.ll \
; RUN:   | opt -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:     -force-vector-interleave=1 -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false \
; RUN:     -vplan-reduction-fission-min-chain-depth=4 -S | FileCheck %s
; RUN: sed 's/%c4 = mul i32 %c3, 13/%c4 = sdiv i32 %c3, %x/' %S/reduction-fission-general.ll \
; RUN:   | opt -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:     -force-vector-interleave=1 -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false \
; RUN:     -vplan-reduction-fission-min-chain-depth=4 -S | FileCheck %s
; RUN: sed 's/%c4 = mul i32 %c3, 13/%c4 = urem i32 %c3, %x/' %S/reduction-fission-general.ll \
; RUN:   | opt -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:     -force-vector-interleave=1 -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false \
; RUN:     -vplan-reduction-fission-min-chain-depth=4 -S | FileCheck %s
; RUN: sed 's/%c4 = mul i32 %c3, 13/%c4 = srem i32 %c3, %x/' %S/reduction-fission-general.ll \
; RUN:   | opt -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:     -force-vector-interleave=1 -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false \
; RUN:     -vplan-reduction-fission-min-chain-depth=4 -S | FileCheck %s
;
; The ordinary vectorizer uses EVL-predicated division/remainder. Preserve
; this baseline: fission retains its conservative speculation guard against
; poison/zero divisors in inactive lanes.
; CHECK-LABEL: define void @general(
; CHECK-NOT: fission
; CHECK: vector.body:
; CHECK: @llvm.vp.{{[us](div|rem)}}.nxv4i32
; CHECK-NOT: fission
; CHECK: ret void
