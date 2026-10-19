; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_acyclic_early_exit(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_acyclic_internal_cycle(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_acyclic_predicate(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_acyclic_contribution(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_acyclic_result_feedback(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_acyclic_liveout(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_acyclic_store(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_acyclic_unsafe_call(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_acyclic_header_update(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_acyclic_switch(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_acyclic_conditional_serial(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_acyclic_conditional_nested(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
declare i32 @safe(i32) memory(none) nounwind willreturn speculatable
declare i32 @unsafe(i32) memory(read) nounwind willreturn speculatable

define i32 @reject_acyclic_early_exit(ptr %a, i64 %n) !dbg !6 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !7
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @safe(i32 %x)
  br label %first.merge
right:
  %rc = xor i32 %x, 7
  br label %first.merge
first.merge:
  %first = phi i32 [%lc, %left], [%rc, %right]
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %left2, label %right2
left2:
  %pc = add i32 %first, 23
  %early = icmp eq i32 %x, 3
  br i1 %early, label %early.exit, label %latch
right2:
  %nc = sub i32 %first, 9
  br label %latch
latch:
  %c = phi i32 [%pc, %left2], [%nc, %right2]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !7
exit:
  ret i32 %update
early.exit:
  ret i32 0
bypass:
  ret i32 19
}

define i32 @reject_acyclic_internal_cycle(ptr %a, i64 %n) !dbg !8 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !9
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @safe(i32 %x)
  br label %first.merge
right:
  %rc = xor i32 %x, 7
  br label %first.merge
first.merge:
  %first = phi i32 [%lc, %left], [%rc, %right]
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %left2, label %right2
left2:
  %pc = add i32 %first, 23
  %again = icmp eq i32 %x, 3
  br i1 %again, label %left2, label %latch, !dbg !33, !llvm.loop !34
right2:
  %nc = sub i32 %first, 9
  br label %latch
latch:
  %c = phi i32 [%pc, %left2], [%nc, %right2]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !9, !llvm.loop !30
exit:
  ret i32 %update
bypass:
  ret i32 19
}

define i32 @reject_acyclic_predicate(ptr %a, i64 %n) !dbg !10 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !11
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %sum, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @safe(i32 %x)
  br label %first.merge
right:
  %rc = xor i32 %x, 7
  br label %first.merge
first.merge:
  %first = phi i32 [%lc, %left], [%rc, %right]
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %left2, label %right2
left2:
  %pc = add i32 %first, 23
  br label %latch
right2:
  %nc = sub i32 %first, 9
  br label %latch
latch:
  %c = phi i32 [%pc, %left2], [%nc, %right2]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !11
exit:
  ret i32 %update
bypass:
  ret i32 19
}

define i32 @reject_acyclic_contribution(ptr %a, i64 %n) !dbg !12 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !13
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @safe(i32 %x)
  br label %first.merge
right:
  %rc = xor i32 %x, 7
  br label %first.merge
first.merge:
  %first = phi i32 [%lc, %left], [%rc, %right]
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %left2, label %right2
left2:
  %pc = add i32 %first, %sum
  br label %latch
right2:
  %nc = sub i32 %first, 9
  br label %latch
latch:
  %c = phi i32 [%pc, %left2], [%nc, %right2]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !13
exit:
  ret i32 %update
bypass:
  ret i32 19
}

define i32 @reject_acyclic_result_feedback(ptr %a, i64 %n) !dbg !14 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !15
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @safe(i32 %x)
  br label %first.merge
right:
  %rc = xor i32 %x, 7
  br label %first.merge
first.merge:
  %first = phi i32 [%lc, %left], [%rc, %right]
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %left2, label %right2
left2:
  %pc = add i32 %first, 23
  br label %latch
right2:
  %nc = sub i32 %first, 9
  br label %latch
latch:
  %c = phi i32 [%pc, %left2], [%nc, %right2]
  %update = add i32 %sum, %c
  %observer = xor i32 %update, %x
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !15
exit:
  ret i32 %update
bypass:
  ret i32 19
}

define i32 @reject_acyclic_liveout(ptr %a, i64 %n) !dbg !16 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !17
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @safe(i32 %x)
  br label %first.merge
right:
  %rc = xor i32 %x, 7
  br label %first.merge
first.merge:
  %first = phi i32 [%lc, %left], [%rc, %right]
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %left2, label %right2
left2:
  %pc = add i32 %first, 23
  br label %latch
right2:
  %nc = sub i32 %first, 9
  br label %latch
latch:
  %c = phi i32 [%pc, %left2], [%nc, %right2]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !17
exit:
  ret i32 %c
bypass:
  ret i32 19
}

define i32 @reject_acyclic_store(ptr %a, i64 %n) !dbg !18 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !19
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @safe(i32 %x)
  br label %first.merge
right:
  %rc = xor i32 %x, 7
  br label %first.merge
first.merge:
  %first = phi i32 [%lc, %left], [%rc, %right]
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %left2, label %right2
left2:
  %pc = add i32 %first, 23
  br label %latch
right2:
  store i32 %x, ptr %p
  %nc = sub i32 %first, 9
  br label %latch
latch:
  %c = phi i32 [%pc, %left2], [%nc, %right2]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !19
exit:
  ret i32 %update
bypass:
  ret i32 19
}

define i32 @reject_acyclic_unsafe_call(ptr %a, i64 %n) !dbg !20 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !21
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @unsafe(i32 %x)
  br label %first.merge
right:
  %rc = xor i32 %x, 7
  br label %first.merge
first.merge:
  %first = phi i32 [%lc, %left], [%rc, %right]
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %left2, label %right2
left2:
  %pc = add i32 %first, 23
  br label %latch
right2:
  %nc = sub i32 %first, 9
  br label %latch
latch:
  %c = phi i32 [%pc, %left2], [%nc, %right2]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !21
exit:
  ret i32 %update
bypass:
  ret i32 19
}

define i32 @reject_acyclic_header_update(ptr %a, i64 %n) !dbg !22 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !23
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %update = add i32 %sum, %x
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @safe(i32 %x)
  br label %first.merge
right:
  %rc = xor i32 %x, 7
  br label %first.merge
first.merge:
  %first = phi i32 [%lc, %left], [%rc, %right]
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %left2, label %right2
left2:
  %pc = add i32 %first, 23
  br label %latch
right2:
  %nc = sub i32 %first, 9
  br label %latch
latch:
  %c = phi i32 [%pc, %left2], [%nc, %right2]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !23
exit:
  ret i32 %update
bypass:
  ret i32 19
}

define i32 @reject_acyclic_switch(ptr %a, i64 %n) !dbg !24 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !25
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @safe(i32 %x)
  br label %first.merge
right:
  %rc = xor i32 %x, 7
  br label %first.merge
first.merge:
  %first = phi i32 [%lc, %left], [%rc, %right]
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  switch i1 %second, label %left2 [ i1 false, label %right2 ]
left2:
  %pc = add i32 %first, 23
  br label %latch
right2:
  %nc = sub i32 %first, 9
  br label %latch
latch:
  %c = phi i32 [%pc, %left2], [%nc, %right2]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !25
exit:
  ret i32 %update
bypass:
  ret i32 19
}

define i32 @reject_acyclic_conditional_serial(ptr %a, i64 %n) !dbg !26 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !27
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @safe(i32 %x)
  br label %first.merge
right:
  %rc = xor i32 %x, 7
  br label %first.merge
first.merge:
  %first = phi i32 [%lc, %left], [%rc, %right]
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %left2, label %right2
left2:
  %pc = add i32 %sum, %first
  br label %latch
right2:
  %nc = sub i32 %first, 9
  br label %latch
latch:
  %merged = phi i32 [%pc, %left2], [%sum, %right2]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !27
exit:
  ret i32 %merged
bypass:
  ret i32 19
}

define i32 @reject_acyclic_conditional_nested(ptr %a, i64 %n) !dbg !28 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !29
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch
left:
  %lc = call i32 @safe(i32 %x)
  br label %first.merge
first.merge:
  %first = phi i32 [%lc, %left]
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %left2, label %right2
left2:
  %pc = add i32 %first, 23
  br label %active.merge
right2:
  %nc = sub i32 %first, 9
  br label %active.merge
active.merge:
  %active = phi i32 [%pc, %left2], [%nc, %right2]
  %update = add i32 %sum, %active
  br label %latch
latch:
  %merged = phi i32 [%update, %active.merge], [%sum, %loop]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !29
exit:
  ret i32 %merged
bypass:
  ret i32 19
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-acyclic-reject.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = !DISubroutineType(types: !5)
!5 = !{}
!6 = distinct !DISubprogram(name: "reject_acyclic_early_exit", scope: !1, file: !1, line: 10, type: !4, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!7 = !DILocation(line: 12, column: 3, scope: !6)
!8 = distinct !DISubprogram(name: "reject_acyclic_internal_cycle", scope: !1, file: !1, line: 20, type: !4, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!9 = !DILocation(line: 22, column: 3, scope: !8)
!10 = distinct !DISubprogram(name: "reject_acyclic_predicate", scope: !1, file: !1, line: 30, type: !4, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 32, column: 3, scope: !10)
!12 = distinct !DISubprogram(name: "reject_acyclic_contribution", scope: !1, file: !1, line: 40, type: !4, scopeLine: 40, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 42, column: 3, scope: !12)
!14 = distinct !DISubprogram(name: "reject_acyclic_result_feedback", scope: !1, file: !1, line: 50, type: !4, scopeLine: 50, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!15 = !DILocation(line: 52, column: 3, scope: !14)
!16 = distinct !DISubprogram(name: "reject_acyclic_liveout", scope: !1, file: !1, line: 60, type: !4, scopeLine: 60, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!17 = !DILocation(line: 62, column: 3, scope: !16)
!18 = distinct !DISubprogram(name: "reject_acyclic_store", scope: !1, file: !1, line: 70, type: !4, scopeLine: 70, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!19 = !DILocation(line: 72, column: 3, scope: !18)
!20 = distinct !DISubprogram(name: "reject_acyclic_unsafe_call", scope: !1, file: !1, line: 80, type: !4, scopeLine: 80, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!21 = !DILocation(line: 82, column: 3, scope: !20)
!22 = distinct !DISubprogram(name: "reject_acyclic_header_update", scope: !1, file: !1, line: 90, type: !4, scopeLine: 90, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!23 = !DILocation(line: 92, column: 3, scope: !22)
!24 = distinct !DISubprogram(name: "reject_acyclic_switch", scope: !1, file: !1, line: 100, type: !4, scopeLine: 100, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!25 = !DILocation(line: 102, column: 3, scope: !24)
!26 = distinct !DISubprogram(name: "reject_acyclic_conditional_serial", scope: !1, file: !1, line: 110, type: !4, scopeLine: 110, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!27 = !DILocation(line: 112, column: 3, scope: !26)
!28 = distinct !DISubprogram(name: "reject_acyclic_conditional_nested", scope: !1, file: !1, line: 120, type: !4, scopeLine: 120, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!29 = !DILocation(line: 122, column: 3, scope: !28)
!30 = distinct !{!30, !9, !31, !32}
!31 = !{!"llvm.loop.vectorize.enable", i1 true}
!32 = !{!"llvm.loop.vectorize.width", i32 2}
!33 = !DILocation(line: 25, column: 5, scope: !8)
!34 = distinct !{!34, !33}
