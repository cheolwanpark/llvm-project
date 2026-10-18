; REQUIRES: asserts
; RUN: opt -enable-scalar-reduction-fission=false -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 \
; RUN:   -debug-only=vplan-reduction-fission -disable-output %S/reduction-fission-interleave.ll 2>&1 | FileCheck %s
; RUN: opt -enable-scalar-reduction-fission=false -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 \
; RUN:   -tail-folding-policy=dont-fold-tail -debug-only=vplan-reduction-fission \
; RUN:   -disable-output %S/reduction-fission-interleave.ll 2>&1 | FileCheck %s
;
; Check the saved representation before EVL lowering, not the ordinary fallback
; IR. Scalar address multiplication must survive structural discovery, stage
; cloning and independent target legality. The companion fixture checks the
; actual emitted stages, remarks and scalar tails; the execution checker runs
; all of them with exact visit counts and guarded input ends.
;
; CHECK-LABEL: LV-FISSION: saved plan for interleave2{{$}}
; CHECK: EMIT{{.*}} = shl
; CHECK-LABEL: LV-FISSION: saved plan for interleave3{{$}}
; CHECK: CLONE {{.*}} = mul{{.*}}ir<3>
; CHECK: LV-FISSION: interleave3: candidate: reductions=2 scratch-bytes=260
; CHECK-SAME: producer-vf=vscale x 2 accumulator-vf=vscale x 4
; CHECK-LABEL: LV-FISSION: saved plan for interleave3_ordered{{$}}
; CHECK: CLONE {{.*}} = mul{{.*}}ir<3>
; CHECK: LV-FISSION: interleave3_ordered: candidate: reductions=2 scratch-bytes=520
; CHECK-SAME: producer-vf=vscale x 2 accumulator-vf=vscale x 4
; CHECK-LABEL: LV-FISSION: saved plan for interleave3_members{{$}}
; CHECK: CLONE {{.*}} = mul{{.*}}ir<3>
; CHECK: LV-FISSION: interleave3_members: candidate: reductions=3 scratch-bytes=780
; CHECK-SAME: producer-vf=vscale x 2 accumulator-vf=vscale x 4
