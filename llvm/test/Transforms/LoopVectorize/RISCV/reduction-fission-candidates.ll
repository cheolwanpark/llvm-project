; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v,+f,+d -force-vector-width=4 -scalable-vectorization=off -pass-remarks-analysis=loop-vectorize -S %s 2>&1 | FileCheck %s --check-prefix=NORMAL
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v,+f,+d -force-vector-width=fission:4 -scalable-vectorization=off -pass-remarks=loop-vectorize -S %s 2>&1 | FileCheck %s --check-prefix=FISSION
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v,+f,+d -force-vector-width=fission:8 -scalable-vectorization=off -pass-remarks=loop-vectorize -S %s 2>&1 | FileCheck %s --check-prefix=FISSION
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v,+f,+d -scalable-vectorization=off -pass-remarks-analysis=loop-vectorize -S %s 2>&1 | FileCheck %s --check-prefix=AUTO-FIXED
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v,+f,+d -scalable-vectorization=on -pass-remarks-analysis=loop-vectorize -S %s 2>&1 | FileCheck %s --check-prefix=AUTO-SCALABLE
;
; Logical candidates share a Map VF without overloading ElementCount or the
; normal VPlan lookup. INF is diagnostic policy, never an invalid numeric cost.
; NORMAL: candidate Normal MapVF=4 cost=normal
; NORMAL-NEXT: {{.*}}candidate Fission MapVF=4 cost=INF (manual only)
; NORMAL-NOT: candidate Normal
; NORMAL-NOT: candidate Fission
; NORMAL-NOT: @malloc
; NORMAL-NOT: fission.buffer
; NORMAL: ret float
;
; FISSION: selected Fission MapVF={{4|8}}
; FISSION: vectorized loop (vectorization width: vscale x 16, interleaved count: 1)
; FISSION: committed fission for 1 original loops; every component vectorized at its requested VF
; FISSION: phi <vscale x 16 x float>
; FISSION: call fast float @llvm.vector.reduce.fadd.nxv16f32

; Automatic planning lists paired candidates but cannot select Fission.
; AUTO-FIXED: {{.*}}candidate Normal MapVF=2 cost=normal
; AUTO-FIXED-NEXT: {{.*}}candidate Fission MapVF=2 cost=INF (manual only)
; AUTO-FIXED-NEXT: {{.*}}candidate Normal MapVF=4 cost=normal
; AUTO-FIXED-NEXT: {{.*}}candidate Fission MapVF=4 cost=INF (manual only)
; AUTO-FIXED-NEXT: {{.*}}candidate Normal MapVF=8 cost=normal
; AUTO-FIXED-NEXT: {{.*}}candidate Fission MapVF=8 cost=INF (manual only)
; AUTO-FIXED-NOT: candidate Normal
; AUTO-FIXED-NOT: candidate Fission
; AUTO-FIXED-NOT: @malloc
; AUTO-FIXED-NOT: fission.buffer
; AUTO-FIXED: ret float
; AUTO-SCALABLE: {{.*}}candidate Normal MapVF=vscale x 1 cost=normal
; AUTO-SCALABLE-NEXT: {{.*}}candidate Fission MapVF=vscale x 1 cost=INF (manual only)
; AUTO-SCALABLE-NEXT: {{.*}}candidate Normal MapVF=vscale x 2 cost=normal
; AUTO-SCALABLE-NEXT: {{.*}}candidate Fission MapVF=vscale x 2 cost=INF (manual only)
; AUTO-SCALABLE-NEXT: {{.*}}candidate Normal MapVF=vscale x 4 cost=normal
; AUTO-SCALABLE-NEXT: {{.*}}candidate Fission MapVF=vscale x 4 cost=INF (manual only)
; AUTO-SCALABLE-NOT: candidate Normal
; AUTO-SCALABLE-NOT: candidate Fission
; AUTO-SCALABLE-NOT: @malloc
; AUTO-SCALABLE-NOT: fission.buffer
; AUTO-SCALABLE: ret float

define float @sum(ptr %a, i64 %n, float %initial) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi float [%initial, %preheader], [%update, %loop]
  %p = getelementptr float, ptr %a, i64 %i
  %x = load float, ptr %p
  %update = fadd fast float %sum, %x
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%initial, %entry], [%update, %loop]
  ret float %result
}
