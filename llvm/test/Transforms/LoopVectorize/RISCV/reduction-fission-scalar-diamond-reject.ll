; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_conditional_update(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_accumulator_predicate(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_accumulator_merge(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_updated_accumulator_use(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_extra_exit(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_internal_cycle(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_arm_cycle(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_arm_store(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_arm_volatile(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_arm_atomic(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_arm_readonly_call(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_arm_errno_call(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_arm_constrained(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_merged_liveout(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_induction_liveout(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_header_update_predicate(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
declare i32 @readonly_call(i32) memory(read) nounwind willreturn speculatable
declare i32 @effect_call(i32) nounwind willreturn
declare double @llvm.experimental.constrained.fadd.f64(double, double, metadata, metadata)

define i32 @reject_conditional_update(ptr %a, i64 %n) !dbg !4 {
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
  br i1 %choose, label %left, label %right, !dbg !7
left:
  %lc = add i32 %sum, %x
  br label %latch
right:
  %rc = xor i32 %x, 7
  br label %latch
latch:
  %merged = phi i32 [%lc, %left], [%sum, %right]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !7
exit:
  %partial = add i32 %sum, %merged
  ret i32 %partial
bypass:
  ret i32 19
}

define i32 @reject_accumulator_predicate(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %sum, 0
  br i1 %choose, label %left, label %right
left:
  %lc = mul i32 %x, 3
  br label %latch
right:
  %rc = xor i32 %x, 7
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

define i32 @reject_accumulator_merge(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = mul i32 %x, 3
  br label %latch
right:
  %rc = xor i32 %x, 7
  br label %latch
latch:
  %c = phi i32 [%sum, %left], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

define i32 @reject_updated_accumulator_use(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = mul i32 %x, 3
  br label %latch
right:
  %rc = xor i32 %x, 7
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [%rc, %right]
  %update = add i32 %sum, %c
  %observer = xor i32 %update, %x
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

define i32 @reject_extra_exit(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = mul i32 %x, 3
  %early = icmp eq i32 %x, 3
  br i1 %early, label %early.exit, label %latch
right:
  %rc = xor i32 %x, 7
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
early.exit:
  ret i32 %lc
bypass:
  ret i32 19
}

define i32 @reject_internal_cycle(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = mul i32 %x, 3
  %again = icmp eq i32 %x, 3
  br i1 %again, label %left, label %latch
right:
  %rc = xor i32 %x, 7
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

define i32 @reject_arm_cycle(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = mul i32 %x, 3
  br i1 %choose, label %left, label %right
right:
  %rc = xor i32 %x, 7
  br label %latch
latch:
  %c = phi i32 [%rc, %right]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

define i32 @reject_arm_store(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = mul i32 %x, 3
  br label %latch
right:
  store i32 %x, ptr %p
  %rc = xor i32 %x, 7
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

define i32 @reject_arm_volatile(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = load volatile i32, ptr %p, align 4
  br label %latch
right:
  %rc = xor i32 %x, 7
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

define i32 @reject_arm_atomic(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = load atomic i32, ptr %p monotonic, align 4
  br label %latch
right:
  %rc = xor i32 %x, 7
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

define i32 @reject_arm_readonly_call(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = mul i32 %x, 3
  br label %latch
right:
  %rc = call i32 @readonly_call(i32 %x)
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

define i32 @reject_arm_errno_call(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = mul i32 %x, 3
  br label %latch
right:
  %rc = call i32 @effect_call(i32 %x)
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

define i32 @reject_arm_constrained(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = mul i32 %x, 3
  br label %latch
right:
  %strict = call double @llvm.experimental.constrained.fadd.f64(double 1.0, double 2.0, metadata !"round.dynamic", metadata !"fpexcept.strict")
  %rc = xor i32 %x, 7
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

define i32 @reject_merged_liveout(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = mul i32 %x, 3
  br label %latch
right:
  %rc = xor i32 %x, 7
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %c
bypass:
  ret i32 19
}

define i32 @reject_induction_liveout(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = mul i32 %x, 3
  br label %latch
right:
  %rc = xor i32 %x, 7
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %export = trunc i64 %next to i32
  ret i32 %export
bypass:
  ret i32 19
}

define i32 @reject_header_update_predicate(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %update = add i32 %sum, %x
  %choose = icmp ne i32 %update, 0
  br i1 %choose, label %left, label %right
left:
  %lc = mul i32 %x, 3
  br label %latch
right:
  %rc = xor i32 %x, 7
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [%rc, %right]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-diamond-reject.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = distinct !DISubprogram(name: "reject_conditional_update", scope: !1, file: !1, line: 10, type: !5, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!5 = !DISubroutineType(types: !6)
!6 = !{}
!7 = !DILocation(line: 12, column: 3, scope: !4)
