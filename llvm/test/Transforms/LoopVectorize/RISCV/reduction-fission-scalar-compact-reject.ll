; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_compact_predicate_feedback(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_compact_contribution_feedback(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_compact_updated_feedback(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_compact_cross_reduction(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_compact_different_participation(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_compact_mixed_participation(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_compact_changed_bypass(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_compact_partial_state_export(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_compact_producer_export(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_compact_store(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_compact_volatile(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_compact_atomic(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_compact_readonly_call(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_compact_errno_call(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_compact_constrained(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_compact_strictfp(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_compact_unsupported_division(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
declare i32 @readonly_helper(i32) memory(read) nounwind willreturn speculatable
declare i32 @errno_helper(i32) nounwind willreturn
declare double @llvm.experimental.constrained.fadd.f64(double, double, metadata, metadata)

define i32 @reject_compact_predicate_feedback(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %sum, 0
  br i1 %choose, label %left, label %latch
left:
  %update = add i32 %sum, %x
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %loop]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %merged
bypass:
  ret i32 19
}

define i32 @reject_compact_contribution_feedback(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch
left:
  %feedback = xor i32 %sum, %x
  %update = add i32 %sum, %feedback
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %loop]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %merged
bypass:
  ret i32 19
}

define i32 @reject_compact_updated_feedback(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch
left:
  %update = add i32 %sum, %x
  %feedback = xor i32 %update, %x
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %loop]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %merged
bypass:
  ret i32 19
}

define i32 @reject_compact_cross_reduction(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %sum2 = phi i32 [7, %preheader], [%merged2, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch
left:
  %update = add i32 %sum, %x
  %update2 = add i32 %sum2, %sum
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %loop]
  %merged2 = phi i32 [%update2, %left], [%sum2, %loop]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %merged
bypass:
  ret i32 19
}

define i32 @reject_compact_different_participation(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %sum2 = phi i32 [7, %preheader], [%merged2, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %update = add i32 %sum, %x
  br label %latch
right:
  %update2 = add i32 %sum2, %x
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %right]
  %merged2 = phi i32 [%sum2, %left], [%update2, %right]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %merged
bypass:
  ret i32 19
}

define i32 @reject_compact_mixed_participation(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %sum2 = phi i32 [7, %preheader], [%update2, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch
left:
  %update = add i32 %sum, %x
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %loop]
  %update2 = add i32 %sum2, %x
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %merged
bypass:
  ret i32 19
}

define i32 @reject_compact_changed_bypass(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch
left:
  %update = add i32 %sum, %x
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [0, %loop]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %merged
bypass:
  ret i32 19
}

define i32 @reject_compact_partial_state_export(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch
left:
  %update = add i32 %sum, %x
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %loop]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %old = phi i32 [%sum, %latch]
  %result = add i32 %old, %merged
  ret i32 %result
bypass:
  ret i32 19
}

define i32 @reject_compact_producer_export(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch
left:
  %update = add i32 %sum, %x
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %loop]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %other = phi i32 [%x, %latch]
  %result = xor i32 %other, %merged
  ret i32 %result
bypass:
  ret i32 19
}

define i32 @reject_compact_store(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch
left:
  %update = add i32 %sum, %x
  store i32 %x, ptr %a
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %loop]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %merged
bypass:
  ret i32 19
}

define i32 @reject_compact_volatile(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch
left:
  %update = add i32 %sum, %x
  %volatile = load volatile i32, ptr %a
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %loop]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %merged
bypass:
  ret i32 19
}

define i32 @reject_compact_atomic(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch
left:
  %update = add i32 %sum, %x
  %atomic = load atomic i32, ptr %a monotonic, align 4
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %loop]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %merged
bypass:
  ret i32 19
}

define i32 @reject_compact_readonly_call(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch
left:
  %update = add i32 %sum, %x
  %unsafe = call i32 @readonly_helper(i32 %x)
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %loop]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %merged
bypass:
  ret i32 19
}

define i32 @reject_compact_errno_call(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch
left:
  %update = add i32 %sum, %x
  %unsafe = call i32 @errno_helper(i32 %x)
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %loop]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %merged
bypass:
  ret i32 19
}

define i32 @reject_compact_constrained(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch
left:
  %update = add i32 %sum, %x
  %constrained = call double @llvm.experimental.constrained.fadd.f64(double 0.0, double 1.0, metadata !"round.dynamic", metadata !"fpexcept.strict")
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %loop]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %merged
bypass:
  ret i32 19
}

define i32 @reject_compact_strictfp(ptr %a, i64 %n) strictfp {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch
left:
  %update = add i32 %sum, %x
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %loop]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %merged
bypass:
  ret i32 19
}

define i32 @reject_compact_unsupported_division(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch
left:
  %update = udiv i32 %sum, %x
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %loop]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %merged
bypass:
  ret i32 19
}
