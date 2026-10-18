; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -enable-vplan-reduction-fission -pass-remarks-missed=vplan-reduction-fission \
; RUN:   -S %s -o %t 2> %t.remarks
; RUN: FileCheck %s < %t
; RUN: FileCheck %s --check-prefix=REASON < %t.remarks
; RUN: opt -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=18446744073709551615 \
; RUN:   -S %s | FileCheck %s --check-prefix=OVERFLOW
;
; Failure of the early path leaves original IR for normal LV. The checks
; prohibit new scalar-IR scratch, while permitting ordinary vectorization.
;
declare i32 @safe(i32) memory(none) nounwind willreturn speculatable
declare i32 @side_effect(i32) nounwind willreturn
declare i32 @throwing(i32) memory(none) willreturn speculatable
declare i32 @nonterminating(i32) memory(none) nounwind speculatable
declare i32 @nonspeculatable(i32) memory(none) nounwind willreturn
declare i32 @convergent_call(i32) memory(none) nounwind willreturn speculatable convergent
declare i32 @readonly_call(i32) memory(read) nounwind willreturn speculatable
declare i32 @noduplicate_call(i32) memory(none) nounwind willreturn speculatable noduplicate
declare double @llvm.experimental.constrained.fadd.f64(double, double, metadata, metadata)

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-reject.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = distinct !DISubprogram(name: "reject_side_effect", scope: !1, file: !1, line: 10, type: !5, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!5 = !DISubroutineType(types: !6)
!6 = !{}
!7 = !DILocation(line: 12, column: 3, scope: !4)

; REASON: scalar-reject.c:12:3: scalar-IR reduction fission rejected: scalar-unsafe-call
; CHECK-LABEL: define i32 @reject_side_effect(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_side_effect(ptr %a, i64 %n) !dbg !4 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @side_effect(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !7
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsafe-call
; CHECK-LABEL: define i32 @reject_throwing(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_throwing(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @throwing(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsafe-call
; CHECK-LABEL: define i32 @reject_nonterminating(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_nonterminating(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @nonterminating(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsafe-call
; CHECK-LABEL: define i32 @reject_nonspeculatable(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_nonspeculatable(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @nonspeculatable(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsafe-call
; CHECK-LABEL: define i32 @reject_convergent_call(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_convergent_call(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @convergent_call(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsafe-call
; CHECK-LABEL: define i32 @reject_readonly_call(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_readonly_call(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @readonly_call(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsafe-call
; CHECK-LABEL: define i32 @reject_noduplicate_call(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_noduplicate_call(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @noduplicate_call(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsupported-recurrence
; CHECK-LABEL: define i32 @reject_feedback(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_feedback(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @safe(i32 %sum)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-reduction-feedback
; CHECK-LABEL: define i32 @reject_update_feedback(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_update_feedback(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  %feedback = xor i32 %update, %x
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-strict-fp
; CHECK-LABEL: define i32 @reject_strictfp(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_strictfp(ptr %a, i64 %n) strictfp {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: {{non-constant-trip-count|scalar-scratch-limit}}
; CHECK-LABEL: define i32 @reject_unbounded(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_unbounded(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, -1
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsupported-live-out
; CHECK-LABEL: define i32 @reject_liveout(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_liveout(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %x
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsupported-recurrence
; CHECK-LABEL: define i32 @reject_old_accumulator_liveout(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_old_accumulator_liveout(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %sum
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-non-simple-load
; CHECK-LABEL: define i32 @reject_volatile_load(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_volatile_load(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load volatile i32, ptr %p, align 4
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-non-simple-load
; CHECK-LABEL: define i32 @reject_atomic_load(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_atomic_load(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load atomic i32, ptr %p monotonic, align 4
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsupported-instruction
; CHECK-LABEL: define i32 @reject_write(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_write(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  store i32 %x, ptr %p
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsupported-exit
; CHECK-LABEL: define i32 @reject_unsupported_exit(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_unsupported_exit(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i32 %c, 0
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsafe-call
; CHECK-LABEL: define i32 @reject_operand_bundle(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_operand_bundle(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @safe(i32 %x) [ "deopt"(i32 0) ]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsupported-recurrence
; CHECK-LABEL: define i32 @reject_other_recurrence(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_other_recurrence(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @safe(i32 %x)
  %update = xor i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-strict-fp
; CHECK-LABEL: define i32 @reject_constrained(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_constrained(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  %fp = call double @llvm.experimental.constrained.fadd.f64(double 1.0, double 2.0, metadata !"round.dynamic", metadata !"fpexcept.strict")
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; Multiple exits and participating-iteration control need a separate CFG path.
; REASON: scalar-IR reduction fission rejected: scalar-unsupported-cfg
; CHECK-LABEL: define i32 @reject_early_exit(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_early_exit(ptr %a) {
entry:
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %latch]
  %sum = phi i32 [19, %entry], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %stop = icmp eq i32 %x, 0
  br i1 %stop, label %early, label %latch
latch:
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, 65
  br i1 %done, label %exit, label %loop
early:
  ret i32 %sum
exit:
  ret i32 %update
}

; Even an unlimited byte option must not wrap the unbounded candidate's layout.
; OVERFLOW-LABEL: define i32 @reject_unbounded(
; OVERFLOW-NOT: scalar.fission
; OVERFLOW: ret i32

; A count outside uint64_t is rejected before multiplying element sizes.
; REASON: scalar-IR reduction fission rejected: trip-count-overflow
; CHECK-LABEL: define i32 @reject_trip_overflow(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_trip_overflow(i32 %x) {
entry:
  br label %loop
loop:
  %iv = phi i128 [0, %entry], [%next, %loop]
  %sum = phi i32 [19, %entry], [%update, %loop]
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i128 %iv, 1
  %done = icmp eq i128 %next, 18446744073709551616
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
}
