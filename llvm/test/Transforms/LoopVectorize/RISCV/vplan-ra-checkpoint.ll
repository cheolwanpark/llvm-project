; RUN: opt -mtriple=riscv64 -mattr=+v -passes='default<O2>' -vplan-pipeline=prepare %s -o %t.bc
; RUN: opt -S %t.bc -o - | FileCheck %s --check-prefix=PREPARE
; RUN: opt -mtriple=riscv64 -mattr=+v -passes='default<O2>' -vplan-pipeline=resume -vplan-ra-run-id=test -vplan-candidates-output=%t.json %t.bc -S -o %t.ll
; RUN: FileCheck %s --check-prefix=RESUME < %t.ll
; RUN: FileCheck %s --check-prefix=MANIFEST < %t.json
; RUN: not opt -mtriple=riscv64 -passes='default<O2>' -vplan-pipeline=resume %s -disable-output 2>&1 | FileCheck %s --check-prefix=BAD-RESUME
; RUN: not opt -mtriple=riscv64 -passes='default<O1>' -vplan-pipeline=prepare %s -disable-output 2>&1 | FileCheck %s --check-prefix=BAD-LEVEL

; RUN: opt -mtriple=riscv64 -mattr=+v -passes='default<O3>' -vplan-pipeline=prepare %s -o %t.o3.bc
; RUN: opt -mtriple=riscv64 -mattr=+v -passes='default<O3>' -vplan-pipeline=resume -vplan-ra-run-id=o3 -vplan-candidates-output=%t.o3.json %t.o3.bc -S -o %t.o3.ll
; RUN: not opt -passes='default<O2>' -vplan-pipeline=resume %t.o3.bc -disable-output 2>&1 | FileCheck %s --check-prefix=MISMATCH
; MISMATCH: VPlan checkpoint optimization level mismatch
; PREPARE-NOT: vector.body
; PREPARE: llvm.vplan.checkpoint
; RESUME-NOT: vector.body
; RESUME-NOT: llvm.vplan.checkpoint
; MANIFEST-DAG: "run_id":"test"
; MANIFEST-DAG: "vf":"f1"
; MANIFEST-DAG: "selections":
; BAD-RESUME: vplan resume requires a prepared checkpoint
; BAD-LEVEL: VPlan checkpoint pipelines require non-LTO -O2/-O3

define void @kernel(ptr noalias %a, ptr noalias %b, i64 %n) {
entry:
  br label %loop
loop:
  %iv = phi i64 [ 0, %entry ], [ %next, %loop ]
  %pa = getelementptr i32, ptr %a, i64 %iv
  %pb = getelementptr i32, ptr %b, i64 %iv
  %x = load i32, ptr %pa, align 4
  %y = add i32 %x, 3
  store i32 %y, ptr %pb, align 4
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret void
}
