; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @integration_affine(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @integration_cross_edge(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @integration_chunk(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Dependent contribution arithmetic preserves positive feature coverage under
; the final producer depth policy. Checks exercise scalar fission and ordinary LV.
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

define void @integration_affine(ptr readonly %a, ptr %out, i64 %n, i32 %start) {
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
  %c.depth.mul = mul i32 %arg, 13
  %c.depth.bias = add i32 %c.depth.mul, 7
  %c = call i32 @scalar_helper(i32 %c.depth.bias)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 2
  %done = icmp eq i64 %next, %limit
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%start, %entry], [%update, %loop]
  store i32 %result, ptr %out
  ret void
}

define void @integration_cross_edge(ptr readonly %a, ptr %out, i64 %n, i32 %start) {
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
  %result = phi i32 [%start, %entry], [%update, %latch]
  store i32 %result, ptr %out
  ret void
}

define void @integration_chunk(ptr readonly %a, ptr %out, i64 %n, i32 %start) {
entry:
  %valid = icmp ule i64 %n, 255
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [%start, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %arg = xor i32 %x, 7
  %c.depth.mul = mul i32 %arg, 13
  %c.depth.bias = add i32 %c.depth.mul, 7
  %c = call i32 @scalar_helper(i32 %c.depth.bias)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%start, %entry], [%update, %loop]
  store i32 %result, ptr %out
  ret void
}
