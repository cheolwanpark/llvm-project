; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @options_smoke(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @dynamic_trip(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @constant_trip_one(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
define void @options_smoke() {
entry:
  ret void
}

define i32 @dynamic_trip(ptr noalias readonly %a, i64 %n) {
entry:
  br label %loop

loop:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %loop ]
  %sum = phi i32 [ 0, %entry ], [ %sum.next, %loop ]
  %p = getelementptr inbounds i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %sum.next = add i32 %sum, %x
  %iv.next = add nuw i64 %iv, 1
  %done = icmp eq i64 %iv.next, %n
  br i1 %done, label %exit, label %loop

exit:
  ret i32 %sum.next
}

define i32 @constant_trip_one(ptr noalias readonly %a) {
entry:
  br label %loop

loop:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %loop ]
  %sum = phi i32 [ 0, %entry ], [ %sum.next, %loop ]
  %p = getelementptr inbounds i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %sum.next = add i32 %sum, %x
  %iv.next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %iv.next, 64
  br i1 %done, label %exit, label %loop

exit:
  ret i32 %sum.next
}
