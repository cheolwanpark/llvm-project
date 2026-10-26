; RUN: opt -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v -scalable-vectorization=always -force-vector-interleave=1 -enable-epilogue-vectorization=false -disable-loop-unrolling -passes=loop-vectorize %s -S -o %t.base.ll
; RUN: rm -f %t.jsonl
; RUN: opt -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v -scalable-vectorization=always -force-vector-interleave=1 -enable-epilogue-vectorization=false -disable-loop-unrolling -passes=loop-vectorize -enable-vplan-backend-feedback -vplan-backend-feedback-force-all -vplan-backend-feedback-output=%t.jsonl -verify-each -verify-machineinstrs %s -S -o %t.feedback.ll
; RUN: diff %t.base.ll %t.feedback.ll
; RUN: %python %S/Inputs/check-backend-feedback.py %t.jsonl
; The transport works without any output file.
; RUN: opt -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v -scalable-vectorization=always -force-vector-interleave=1 -enable-epilogue-vectorization=false -disable-loop-unrolling -passes=loop-vectorize -enable-vplan-backend-feedback -vplan-backend-feedback-force-all %s -S -o %t.memory.ll
; RUN: diff %t.base.ll %t.memory.ll
; Optional late cleanup and timing must also leave the original IR unchanged.
; RUN: rm -f %t.late.jsonl
; RUN: opt -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v -scalable-vectorization=always -force-vector-interleave=1 -enable-epilogue-vectorization=false -disable-loop-unrolling -passes=loop-vectorize -enable-vplan-backend-feedback -vplan-backend-feedback-force-all -vplan-backend-feedback-late-cleanup -time-vplan-backend-feedback -vplan-backend-feedback-output=%t.late.jsonl -verify-each -verify-machineinstrs %s -S -o %t.late.ll 2>%t.timing
; RUN: diff %t.base.ll %t.late.ll
; RUN: %python %S/Inputs/check-backend-feedback.py %t.late.jsonl
; RUN: FileCheck %s --check-prefix=TIMING <%t.timing
; TIMING: VPLAN-BACKEND-FEEDBACK-TIMING:
; TIMING-SAME: "late_cleanup":true
; RUN: FileCheck %s --check-prefix=LATE <%t.late.jsonl
; LATE: "feedback_pipeline":"vector-suffix-O{{[23]}}+late-cleanup"
; Unsupported probe geometry must leave the real IC decision alone.
; RUN: opt -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v -scalable-vectorization=always -force-vector-interleave=2 -disable-loop-unrolling -passes=loop-vectorize %s -S -o %t.ic2.base.ll
; RUN: rm -f %t.ic2.jsonl
; RUN: opt -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v -scalable-vectorization=always -force-vector-interleave=2 -disable-loop-unrolling -passes=loop-vectorize -enable-vplan-backend-feedback -vplan-backend-feedback-force-all -vplan-backend-feedback-output=%t.ic2.jsonl %s -S -o %t.ic2.ll
; RUN: diff %t.ic2.base.ll %t.ic2.ll
; RUN: %python %S/Inputs/check-backend-feedback.py %t.ic2.jsonl unavailable

define void @kernel(ptr noalias %a, ptr noalias %b) #0 {
entry:
  br label %loop
loop:
  %iv = phi i64 [ 0, %entry ], [ %next, %loop ]
  %pa = getelementptr double, ptr %a, i64 %iv
  %pb = getelementptr double, ptr %b, i64 %iv
  %x = load double, ptr %pa, align 8
  %y = fadd double %x, 1.0
  store double %y, ptr %pb, align 8
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, 1024
  br i1 %done, label %exit, label %loop
exit:
  ret void
}

; Two loops in another function exercise clone header mapping and per-query
; ownership after an earlier loop in the original function was vectorized.
define void @two_loops(ptr noalias %a, ptr noalias %b, i64 %n) #0 {
entry:
  br label %first
first:
  %i = phi i64 [ 0, %entry ], [ %inext, %first ]
  %p = getelementptr i32, ptr %a, i64 %i
  store i32 7, ptr %p, align 4
  %inext = add nuw i64 %i, 1
  %idone = icmp eq i64 %inext, %n
  br i1 %idone, label %between, label %first
between:
  br label %second
second:
  %j = phi i64 [ 0, %between ], [ %jnext, %second ]
  %q = getelementptr i32, ptr %b, i64 %j
  store i32 9, ptr %q, align 4
  %jnext = add nuw i64 %j, 1
  %jdone = icmp eq i64 %jnext, %n
  br i1 %jdone, label %exit, label %second
exit:
  ret void
}

attributes #0 = { vscale_range(2,2) }
