; RUN: opt -passes=scalar-fission -pass-remarks-output=%t.frontier.yaml -pass-remarks-filter=scalar-fission -disable-output %s
; RUN: FileCheck %s --check-prefix=FRONTIER < %t.frontier.yaml
; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @compact_i8_max(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @compact_i8_overflow(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @compact_default_limit(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @compact_over_limit(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
; FRONTIER: Name: Rejected
; FRONTIER: Function: compact_i8_max
; FRONTIER: Reason: no-computed-boundary
define i32 @compact_i8_max(i32 %cutoff) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i8 [0, %preheader], [%next, %latch]
  %sum = phi i32 [17, %preheader], [%merged, %latch]
  %wide = zext i8 %iv to i32
  %choose = icmp ult i32 %wide, %cutoff
  br i1 %choose, label %left, label %latch
left:
  %update = add i32 %sum, %wide
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %loop]
  %next = add i8 %iv, 1
  %done = icmp eq i8 %next, 255
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%merged, %latch]
  ret i32 %result
}

; FRONTIER: Name: Rejected
; FRONTIER: Function: compact_i8_overflow
; FRONTIER: Reason: no-computed-boundary
define i32 @compact_i8_overflow(i32 %cutoff) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i8 [0, %preheader], [%next, %latch]
  %sum = phi i32 [17, %preheader], [%merged, %latch]
  %wide = zext i8 %iv to i32
  %choose = icmp ult i32 %wide, %cutoff
  br i1 %choose, label %left, label %latch
left:
  %update = add i32 %sum, %wide
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %loop]
  %next = add i8 %iv, 1
  %done = icmp eq i8 %next, 0
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%merged, %latch]
  ret i32 %result
}

; FRONTIER: Name: Rejected
; FRONTIER: Function: compact_default_limit
; FRONTIER: Reason: no-computed-boundary
define i32 @compact_default_limit(i32 %cutoff) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i16 [0, %preheader], [%next, %latch]
  %sum = phi i32 [17, %preheader], [%merged, %latch]
  %wide = zext i16 %iv to i32
  %choose = icmp ult i32 %wide, %cutoff
  br i1 %choose, label %left, label %latch
left:
  %update = add i32 %sum, %wide
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %loop]
  %next = add i16 %iv, 1
  %done = icmp eq i16 %next, 16384
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%merged, %latch]
  ret i32 %result
}

; FRONTIER: Name: Rejected
; FRONTIER: Function: compact_over_limit
; FRONTIER: Reason: no-computed-boundary
define i32 @compact_over_limit(i32 %cutoff) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i16 [0, %preheader], [%next, %latch]
  %sum = phi i32 [17, %preheader], [%merged, %latch]
  %wide = zext i16 %iv to i32
  %choose = icmp ult i32 %wide, %cutoff
  br i1 %choose, label %left, label %latch
left:
  %update = add i32 %sum, %wide
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %loop]
  %next = add i16 %iv, 1
  %done = icmp eq i16 %next, 16385
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%merged, %latch]
  ret i32 %result
}

