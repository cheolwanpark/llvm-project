; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @oversized_offset(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @oversized_stride(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @oversized_current(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @oversized_swapped(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @oversized_witness(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_export_integration_affine(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_export_integration_cross_edge(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

define i32 @oversized_offset(i32 %x) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i64 [7, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %c = call i32 @scalar_helper(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, 72
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
}

define i32 @oversized_stride(i32 %x) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %c = call i32 @scalar_helper(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 2
  %done = icmp eq i64 %next, 130
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
}

define i32 @oversized_current(i32 %x) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %c = call i32 @scalar_helper(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %iv, 64
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
}

define i32 @oversized_swapped(i32 %x) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %c = call i32 @scalar_helper(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 65, %next
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
}

define i32 @oversized_witness(i32 %x) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %c = call i32 @scalar_helper(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp ult i64 %next, 65
  br i1 %done, label %loop, label %exit
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
}

define i64 @reject_export_integration_affine(ptr readonly %a, ptr %out, i64 %n, i32 %start) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  %span = shl nuw i64 %n, 1
  %limit = add nuw i64 %span, 7
  br label %loop
loop:
  %iv = phi i64 [7, %preheader], [%next, %loop]
  %sum = phi i32 [%start, %preheader], [%update, %loop]
  %distance = sub nuw i64 %iv, 7
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %arg = xor i32 %x, 7
  %c = call i32 @scalar_helper(i32 %arg)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 2
  %done = icmp eq i64 %next, %limit
  br i1 %done, label %exit, label %loop
exit:
  %observed = phi i64 [0, %entry], [%iv, %loop]
  %result = phi i32 [%start, %entry], [%update, %loop]
  store i32 %result, ptr %out
  ret i64 %observed
}

define i64 @reject_export_integration_cross_edge(ptr readonly %a, ptr %out, i64 %n, i32 %start) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [%start, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = mul i32 %x, 3
  br label %right
right:
  %first = phi i32 [%lc, %left], [%x, %loop]
  %arg = xor i32 %first, 7
  %c = call i32 @scalar_helper(i32 %arg)
  br label %latch
latch:
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %observed = phi i64 [0, %entry], [%iv, %latch]
  %result = phi i32 [%start, %entry], [%update, %latch]
  store i32 %result, ptr %out
  ret i64 %observed
}
