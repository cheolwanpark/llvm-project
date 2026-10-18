; REQUIRES: asserts
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v \
; RUN:   -tail-folding-policy=must-fold-tail \
; RUN:   -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false \
; RUN:   -vplan-reduction-fission-min-reductions=17 \
; RUN:   -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -debug-only=vplan-reduction-fission -disable-output %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=CANDIDATE
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v \
; RUN:   -tail-folding-policy=must-fold-tail \
; RUN:   -debug-only=vplan-reduction-fission -disable-output %s 2>&1 \
; RUN:   | FileCheck %s --allow-empty --implicit-check-not=LV-FISSION
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v \
; RUN:   -tail-folding-policy=must-fold-tail \
; RUN:   -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false \
; RUN:   -vplan-reduction-fission-min-reductions=17 \
; RUN:   -vplan-reduction-fission-min-chain-depth=4 -S %s \
; RUN:   | FileCheck %s --check-prefix=CODEGEN
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v \
; RUN:   -tail-folding-policy=must-fold-tail \
; RUN:   -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false \
; RUN:   -vplan-reduction-fission-min-reductions=17 \
; RUN:   -vplan-reduction-fission-min-chain-depth=4 -S %s \
; RUN:   | llc -mtriple=riscv64 -mattr=+v \
; RUN:   | FileCheck %s --check-prefix=BACKEND

; CANDIDATE: LV-FISSION: pressure_candidate: candidate: reductions=17
; CANDIDATE-SAME: scratch-bytes=256
; CANDIDATE-SAME: baseline-vf=vscale x 2
; CANDIDATE-SAME: producer-vf=vscale x 16
; CANDIDATE-SAME: accumulator-vf=vscale x 2

; CODEGEN-LABEL: define void @pressure_candidate(
; CODEGEN: alloca [64 x i32], align 4
; CODEGEN: vector.fission.producer.body:
; CODEGEN: store <vscale x 16 x i32>
; CODEGEN: vector.fission.accumulator.body:
; CODEGEN: load <vscale x 2 x i32>
; CODEGEN: call i32 @llvm.vector.reduce.add.nxv2i32
; CODEGEN-NOT: loop:

; BACKEND-LABEL: pressure_candidate:
; BACKEND: vector.fission.accumulator.body
; BACKEND-NOT: {{v[ls][1248]r\.v.*Folded (Spill|Reload)}}
; BACKEND: ret

define void @pressure_candidate(ptr noalias readonly %a, ptr noalias writeonly %out) {
entry:
  br label %loop

loop:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %loop ]
  %r0 = phi i32 [ 0, %entry ], [ %n0, %loop ]
  %r1 = phi i32 [ 0, %entry ], [ %n1, %loop ]
  %r2 = phi i32 [ 0, %entry ], [ %n2, %loop ]
  %r3 = phi i32 [ 0, %entry ], [ %n3, %loop ]
  %r4 = phi i32 [ 0, %entry ], [ %n4, %loop ]
  %r5 = phi i32 [ 0, %entry ], [ %n5, %loop ]
  %r6 = phi i32 [ 0, %entry ], [ %n6, %loop ]
  %r7 = phi i32 [ 0, %entry ], [ %n7, %loop ]
  %r8 = phi i32 [ 0, %entry ], [ %n8, %loop ]
  %r9 = phi i32 [ 0, %entry ], [ %n9, %loop ]
  %r10 = phi i32 [ 0, %entry ], [ %n10, %loop ]
  %r11 = phi i32 [ 0, %entry ], [ %n11, %loop ]
  %r12 = phi i32 [ 0, %entry ], [ %n12, %loop ]
  %r13 = phi i32 [ 0, %entry ], [ %n13, %loop ]
  %r14 = phi i32 [ 0, %entry ], [ %n14, %loop ]
  %r15 = phi i32 [ 0, %entry ], [ %n15, %loop ]
  %r16 = phi i32 [ 0, %entry ], [ %n16, %loop ]
  %p = getelementptr inbounds i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c1 = mul i32 %x, 3
  %c2 = add i32 %c1, 7
  %c3 = xor i32 %c2, 11
  %value = mul i32 %c3, 13
  %n0 = add i32 %r0, %value
  %n1 = add i32 %r1, %value
  %n2 = add i32 %r2, %value
  %n3 = add i32 %r3, %value
  %n4 = add i32 %r4, %value
  %n5 = add i32 %r5, %value
  %n6 = add i32 %r6, %value
  %n7 = add i32 %r7, %value
  %n8 = add i32 %r8, %value
  %n9 = add i32 %r9, %value
  %n10 = add i32 %r10, %value
  %n11 = add i32 %r11, %value
  %n12 = add i32 %r12, %value
  %n13 = add i32 %r13, %value
  %n14 = add i32 %r14, %value
  %n15 = add i32 %r15, %value
  %n16 = add i32 %r16, %value
  %iv.next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %iv.next, 64
  br i1 %done, label %exit, label %loop

exit:
  store i32 %n0, ptr %out, align 4
  %o1 = getelementptr inbounds i32, ptr %out, i64 1
  store i32 %n1, ptr %o1, align 4
  %o2 = getelementptr inbounds i32, ptr %out, i64 2
  store i32 %n2, ptr %o2, align 4
  %o3 = getelementptr inbounds i32, ptr %out, i64 3
  store i32 %n3, ptr %o3, align 4
  %o4 = getelementptr inbounds i32, ptr %out, i64 4
  store i32 %n4, ptr %o4, align 4
  %o5 = getelementptr inbounds i32, ptr %out, i64 5
  store i32 %n5, ptr %o5, align 4
  %o6 = getelementptr inbounds i32, ptr %out, i64 6
  store i32 %n6, ptr %o6, align 4
  %o7 = getelementptr inbounds i32, ptr %out, i64 7
  store i32 %n7, ptr %o7, align 4
  %o8 = getelementptr inbounds i32, ptr %out, i64 8
  store i32 %n8, ptr %o8, align 4
  %o9 = getelementptr inbounds i32, ptr %out, i64 9
  store i32 %n9, ptr %o9, align 4
  %o10 = getelementptr inbounds i32, ptr %out, i64 10
  store i32 %n10, ptr %o10, align 4
  %o11 = getelementptr inbounds i32, ptr %out, i64 11
  store i32 %n11, ptr %o11, align 4
  %o12 = getelementptr inbounds i32, ptr %out, i64 12
  store i32 %n12, ptr %o12, align 4
  %o13 = getelementptr inbounds i32, ptr %out, i64 13
  store i32 %n13, ptr %o13, align 4
  %o14 = getelementptr inbounds i32, ptr %out, i64 14
  store i32 %n14, ptr %o14, align 4
  %o15 = getelementptr inbounds i32, ptr %out, i64 15
  store i32 %n15, ptr %o15, align 4
  %o16 = getelementptr inbounds i32, ptr %out, i64 16
  store i32 %n16, ptr %o16, align 4
  ret void
}
