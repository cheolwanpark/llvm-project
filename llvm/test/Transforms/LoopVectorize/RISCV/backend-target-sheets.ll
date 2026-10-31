; REQUIRES: riscv-registered-target
; RUN: opt -mtriple=riscv64 -mcpu=generic-rv64 -mtune=saturn-shuttle-v256d128 -mattr=+v -codegen-opt-level=2 -scalable-vectorization=always -force-vector-width=4 -force-vector-interleave=1 -enable-epilogue-vectorization=false -disable-loop-unrolling -passes=loop-vectorize -vplan-backend -vplan-backend-force-all -use-estimated-spill -vplan-backend-jsonl=%t.SATURN-EST %s -disable-output
; RUN: FileCheck %s --check-prefix=SATURN-EST < %t.SATURN-EST
; RUN: FileCheck %s --check-prefix=EST-RESULT --implicit-check-not=fallback < %t.SATURN-EST
; SATURN-EST: "tti_profile":"saturn-shuttle-v256d128"
; RUN: opt -mtriple=riscv64 -mcpu=generic-rv64 -mtune=saturn-shuttle-v256d128 -mattr=+v -codegen-opt-level=2 -scalable-vectorization=always -force-vector-width=4 -force-vector-interleave=1 -enable-epilogue-vectorization=false -disable-loop-unrolling -passes=loop-vectorize -vplan-backend -vplan-backend-force-all  -vplan-backend-jsonl=%t.SATURN-SPILL %s -disable-output
; RUN: FileCheck %s --check-prefix=SATURN-SPILL < %t.SATURN-SPILL
; RUN: FileCheck %s --check-prefix=SPILL-RESULT --implicit-check-not=fallback < %t.SATURN-SPILL
; SATURN-SPILL: "tti_profile":"saturn-shuttle-v256d128"
; RUN: opt -mtriple=riscv64 -mcpu=generic-rv64 -mtune=saturn-shuttle-v256d128 -mattr=+v -codegen-opt-level=2 -scalable-vectorization=always -force-vector-width=4 -force-vector-interleave=1 -enable-epilogue-vectorization=false -disable-loop-unrolling -passes=loop-vectorize -vplan-backend -vplan-backend-force-all -use-mir -vplan-backend-jsonl=%t.SATURN-MIR %s -disable-output
; RUN: FileCheck %s --check-prefix=SATURN-MIR < %t.SATURN-MIR
; RUN: FileCheck %s --check-prefix=MIR-RESULT --implicit-check-not=fallback < %t.SATURN-MIR
; SATURN-MIR: "tti_profile":"saturn-shuttle-v256d128"
; RUN: opt -mtriple=riscv64 -mcpu=generic-rv64 -mtune=saturn-shuttle-v256d128 -mattr=+v -codegen-opt-level=2 -scalable-vectorization=always -force-vector-width=4 -force-vector-interleave=1 -enable-epilogue-vectorization=false -disable-loop-unrolling -passes=loop-vectorize -vplan-backend -vplan-backend-force-all -use-mir -use-estimated-spill -vplan-backend-jsonl=%t.SATURN-ME %s -disable-output
; RUN: FileCheck %s --check-prefix=SATURN-ME < %t.SATURN-ME
; RUN: FileCheck %s --check-prefix=ME-RESULT --implicit-check-not=fallback < %t.SATURN-ME
; RUN: FileCheck %s --check-prefix=SATURN-MODEL < %t.SATURN-ME
; SATURN-ME: "tti_profile":"saturn-shuttle-v256d128"
; RUN: opt -mtriple=riscv64 -mcpu=generic-rv64 -mtune=saturn-shuttle-v256d128 -mattr=+v -codegen-opt-level=2 -scalable-vectorization=always -force-vector-width=4 -force-vector-interleave=1 -enable-epilogue-vectorization=false -disable-loop-unrolling -passes=loop-vectorize -vplan-backend -vplan-backend-force-all -use-mir -use-estimated-spill -use-default-tti -vplan-backend-jsonl=%t.SATURN-DEFAULT %s -disable-output
; RUN: FileCheck %s --check-prefix=SATURN-DEFAULT < %t.SATURN-DEFAULT
; RUN: FileCheck %s --check-prefix=DEFAULT-RESULT --implicit-check-not=fallback < %t.SATURN-DEFAULT
; RUN: FileCheck %s --check-prefix=SATURN-MODEL < %t.SATURN-DEFAULT
; SATURN-DEFAULT: "tti_profile":"native"
; RUN: FileCheck %s --check-prefix=SATURN-MODEL < %t.SATURN-MIR
; SATURN-MODEL: "mir_model":"saturn-shuttle-direct-v1"
; RUN: opt -mtriple=riscv64 -mcpu=generic-rv64 -mtune=spacemit-x60 -mattr=+v -codegen-opt-level=2 -scalable-vectorization=always -force-vector-width=4 -force-vector-interleave=1 -enable-epilogue-vectorization=false -disable-loop-unrolling -passes=loop-vectorize -vplan-backend -vplan-backend-force-all -use-estimated-spill -vplan-backend-jsonl=%t.K1-EST %s -disable-output
; RUN: FileCheck %s --check-prefix=K1-EST < %t.K1-EST
; RUN: FileCheck %s --check-prefix=EST-RESULT --implicit-check-not=fallback < %t.K1-EST
; K1-EST: "tti_profile":"spacemit-k1-256"
; RUN: opt -mtriple=riscv64 -mcpu=generic-rv64 -mtune=spacemit-x60 -mattr=+v -codegen-opt-level=2 -scalable-vectorization=always -force-vector-width=4 -force-vector-interleave=1 -enable-epilogue-vectorization=false -disable-loop-unrolling -passes=loop-vectorize -vplan-backend -vplan-backend-force-all  -vplan-backend-jsonl=%t.K1-SPILL %s -disable-output
; RUN: FileCheck %s --check-prefix=K1-SPILL < %t.K1-SPILL
; RUN: FileCheck %s --check-prefix=SPILL-RESULT --implicit-check-not=fallback < %t.K1-SPILL
; K1-SPILL: "tti_profile":"spacemit-k1-256"
; RUN: opt -mtriple=riscv64 -mcpu=generic-rv64 -mtune=spacemit-x60 -mattr=+v -codegen-opt-level=2 -scalable-vectorization=always -force-vector-width=4 -force-vector-interleave=1 -enable-epilogue-vectorization=false -disable-loop-unrolling -passes=loop-vectorize -vplan-backend -vplan-backend-force-all -use-mir -vplan-backend-jsonl=%t.K1-MIR %s -disable-output
; RUN: FileCheck %s --check-prefix=K1-MIR < %t.K1-MIR
; RUN: FileCheck %s --check-prefix=MIR-RESULT --implicit-check-not=fallback < %t.K1-MIR
; K1-MIR: "tti_profile":"spacemit-k1-256"
; RUN: opt -mtriple=riscv64 -mcpu=generic-rv64 -mtune=spacemit-x60 -mattr=+v -codegen-opt-level=2 -scalable-vectorization=always -force-vector-width=4 -force-vector-interleave=1 -enable-epilogue-vectorization=false -disable-loop-unrolling -passes=loop-vectorize -vplan-backend -vplan-backend-force-all -use-mir -use-estimated-spill -vplan-backend-jsonl=%t.K1-ME %s -disable-output
; RUN: FileCheck %s --check-prefix=K1-ME < %t.K1-ME
; RUN: FileCheck %s --check-prefix=ME-RESULT --implicit-check-not=fallback < %t.K1-ME
; RUN: FileCheck %s --check-prefix=K1-MODEL < %t.K1-ME
; K1-ME: "tti_profile":"spacemit-k1-256"
; RUN: opt -mtriple=riscv64 -mcpu=generic-rv64 -mtune=spacemit-x60 -mattr=+v -codegen-opt-level=2 -scalable-vectorization=always -force-vector-width=4 -force-vector-interleave=1 -enable-epilogue-vectorization=false -disable-loop-unrolling -passes=loop-vectorize -vplan-backend -vplan-backend-force-all -use-mir -use-estimated-spill -use-default-tti -vplan-backend-jsonl=%t.K1-DEFAULT %s -disable-output
; RUN: FileCheck %s --check-prefix=K1-DEFAULT < %t.K1-DEFAULT
; RUN: FileCheck %s --check-prefix=DEFAULT-RESULT --implicit-check-not=fallback < %t.K1-DEFAULT
; RUN: FileCheck %s --check-prefix=K1-MODEL < %t.K1-DEFAULT
; K1-DEFAULT: "tti_profile":"native"
; RUN: FileCheck %s --check-prefix=K1-MODEL < %t.K1-MIR
; K1-MODEL: "mir_model":"spacemit-k1-direct-v1"

; EST-RESULT-DAG: "cost_source":"estimated"
; EST-RESULT-DAG: "model":"tti-v1"
; EST-RESULT-DAG: "status":"skipped"
; SPILL-RESULT-DAG: "cost_source":"observation"
; SPILL-RESULT-DAG: "model":"tti-real-vector-spill-v1"
; SPILL-RESULT-DAG: "status":"collected"
; MIR-RESULT-DAG: "cost_source":"observation"
; MIR-RESULT-DAG: "model":"mir-v1"
; MIR-RESULT-DAG: "status":"collected"
; ME-RESULT-DAG: "cost_source":"observation"
; ME-RESULT-DAG: "model":"mir-me-spill-v1"
; ME-RESULT-DAG: "status":"collected"
; DEFAULT-RESULT-DAG: "cost_source":"observation"
; DEFAULT-RESULT-DAG: "model":"mir-me-spill-v1"
; DEFAULT-RESULT-DAG: "status":"collected"

define void @kernel(ptr noalias %a, ptr noalias %b) vscale_range(4,4) {
entry:
  br label %loop
loop:
  %iv = phi i64 [ 0, %entry ], [ %next, %loop ]
  %pa = getelementptr float, ptr %a, i64 %iv
  %pb = getelementptr float, ptr %b, i64 %iv
  %x = load float, ptr %pa, align 4
  %y = fadd float %x, 1.0
  store float %y, ptr %pb, align 4
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, 1024
  br i1 %done, label %exit, label %loop
exit:
  ret void
}
