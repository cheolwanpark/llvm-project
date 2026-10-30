; RUN: opt -codegen-opt-level=2 -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v -scalable-vectorization=always -force-vector-interleave=1 -enable-epilogue-vectorization=false -disable-loop-unrolling -passes=loop-vectorize %s -S -o %t.base.ll
; RUN: rm -f %t.jsonl
; RUN: opt -codegen-opt-level=2 -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v -scalable-vectorization=always -force-vector-interleave=1 -enable-epilogue-vectorization=false -disable-loop-unrolling -passes=loop-vectorize -vplan-backend -vplan-backend-force-all -vplan-backend-jsonl=%t.jsonl -verify-each -verify-machineinstrs %s -S -o %t.feedback.ll

; RUN: %python %S/Inputs/check-backend-feedback.py %t.jsonl
; The transport works without any output file.
; RUN: opt -codegen-opt-level=2 -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v -scalable-vectorization=always -force-vector-interleave=1 -enable-epilogue-vectorization=false -disable-loop-unrolling -passes=loop-vectorize -vplan-backend -vplan-backend-force-all %s -S -o %t.memory.ll
; RUN: diff %t.feedback.ll %t.memory.ll
; Timing and summary output do not alter costs or selected IR.
; RUN: rm -f %t.timed.jsonl
; RUN: opt -codegen-opt-level=2 -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v -scalable-vectorization=always -force-vector-interleave=1 -enable-epilogue-vectorization=false -disable-loop-unrolling -passes=loop-vectorize -vplan-backend -vplan-backend-force-all -vplan-backend-time -vplan-backend-jsonl=%t.timed.jsonl %s -S -o %t.timed.ll 2>%t.phases
; RUN: diff %t.feedback.ll %t.timed.ll
; RUN: diff %t.jsonl %t.timed.jsonl
; RUN: FileCheck %s --check-prefix=PHASE <%t.phases
; PHASE: "partial_rewrite_wall_seconds":
; PHASE-SAME: "post_rvv_to_stack_slot_coloring_wall_seconds":
; PHASE-SAME: "rvv_allocation_wall_seconds":
; PHASE-SAME: "spill_collection_wall_seconds":
; Probe only: opt does not run normal final object codegen.
; RUN: opt -codegen-opt-level=2 -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v -scalable-vectorization=always -force-vector-interleave=1 -enable-epilogue-vectorization=false -disable-loop-unrolling -passes=loop-vectorize -vplan-backend -vplan-backend-force-all -print-after-all %s -disable-output 2>%t.passes
; RUN: %python %S/Inputs/check-spill-probe-passes.py %t.passes
; IC=2 is materialized and normalized, rather than rejected.
; RUN: opt -codegen-opt-level=2 -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v -scalable-vectorization=always -force-vector-interleave=2 -disable-loop-unrolling -passes=loop-vectorize %s -S -o %t.ic2.base.ll
; RUN: rm -f %t.ic2.jsonl
; RUN: opt -codegen-opt-level=2 -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v -scalable-vectorization=always -force-vector-interleave=2 -disable-loop-unrolling -passes=loop-vectorize -vplan-backend -vplan-backend-force-all -vplan-backend-jsonl=%t.ic2.jsonl %s -S -o %t.ic2.ll

; RUN: %python %S/Inputs/check-backend-feedback.py %t.ic2.jsonl 2

; Fixed VF and IC=4 retain the typed spill contract and exact normalization.
; RUN: rm -f %t.fixed.jsonl
; RUN: opt -codegen-opt-level=2 -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v -scalable-vectorization=off -force-vector-interleave=4 -force-vector-width=8 -enable-epilogue-vectorization=false -disable-loop-unrolling -passes=loop-vectorize -vplan-backend -vplan-backend-force-all -vplan-backend-jsonl=%t.fixed.jsonl %s -S -o %t.fixed.ll
; RUN: %python %S/Inputs/check-backend-feedback.py %t.fixed.jsonl 4 fixed
; Forced epilogue is present in main probes and final IR.
; RUN: rm -f %t.epilogue.jsonl
; RUN: opt -codegen-opt-level=2 -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v -scalable-vectorization=off -force-vector-interleave=4 -force-vector-width=8 -epilogue-vectorization-force-VF=2 -disable-loop-unrolling -passes=loop-vectorize -vplan-backend -vplan-backend-force-all -vplan-backend-jsonl=%t.epilogue.jsonl %s -S -o %t.epilogue.ll
; RUN: FileCheck %s --check-prefix=EPILOGUE <%t.epilogue.ll
; RUN: %python %S/Inputs/check-forced-spill-epilogue.py %t.epilogue.jsonl
; EPILOGUE: vec.epilog
; RUN: rm -f %t.unsupported.jsonl
; Fast allocation cannot provide the guaranteed observation point.
; RUN: opt -codegen-opt-level=2 -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v -scalable-vectorization=always -force-vector-interleave=1 -enable-epilogue-vectorization=false -disable-loop-unrolling -passes=loop-vectorize -vplan-backend -vplan-backend-force-all -riscv-rvv-regalloc=fast -vplan-backend-jsonl=%t.unsupported.jsonl %s -S -o %t.unsupported.ll 2>%t.unsupported
; RUN: FileCheck %s --check-prefix=FAST-FAIL <%t.unsupported.jsonl
; FAST-FAIL: "reason":"tti-real-vector-spill-v1: backend feedback requires optimized RVV allocation"
; FAST-FAIL-SAME: "status":"estimated-fallback"

; RUN: rm -f %t.no-ssc.jsonl
; Disabling the required cleanup cannot masquerade as a post-coloring probe.
; RUN: opt -codegen-opt-level=2 -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v -scalable-vectorization=always -force-vector-interleave=1 -enable-epilogue-vectorization=false -disable-loop-unrolling -passes=loop-vectorize -vplan-backend -vplan-backend-force-all -disable-ssc -vplan-backend-jsonl=%t.no-ssc.jsonl %s -S -o %t.no-ssc.ll 2>%t.no-ssc
; RUN: diff %t.unsupported.ll %t.no-ssc.ll
; RUN: FileCheck %s --check-prefix=NO-SSC <%t.no-ssc.jsonl
; NO-SSC: "reason":"tti-real-vector-spill-v1: backend feedback requires StackSlotColoring"
; NO-SSC-SAME: "status":"estimated-fallback"

; Diagnostic flags without the master must not query the provider or tune costs.
; RUN: rm -f %t.off.jsonl
; RUN: opt -codegen-opt-level=2 -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v -scalable-vectorization=always -force-vector-interleave=1 -enable-epilogue-vectorization=false -disable-loop-unrolling -passes=loop-vectorize -vplan-backend-time -vplan-backend-force-all -vplan-backend-jsonl=%t.off.jsonl %s -S -o %t.off.ll 2>%t.off.stderr
; RUN: diff %t.base.ll %t.off.ll
; RUN: test ! -e %t.off.jsonl
; RUN: test ! -s %t.off.stderr

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
