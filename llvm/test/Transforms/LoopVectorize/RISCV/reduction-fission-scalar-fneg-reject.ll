; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_accumulator_negation(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_update_negation(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_vector_negation(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_strictfp(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_constrained(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_unsafe_call(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @reject_negation_recurrence(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
declare double @unsafe(double) memory(none) nounwind willreturn
declare double @llvm.experimental.constrained.fadd.f64(double, double, metadata, metadata)

define double @reject_accumulator_negation(ptr %a, i64 %n, double %start, <2 x double> %v) !dbg !10 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi double [%start, %preheader], [%update, %loop]
  %p = getelementptr double, ptr %a, i64 %iv
  %x = load double, ptr %p, align 8
  %c = fneg double %sum
  %update = fadd double %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !11
exit:
  %result = phi double [%update, %loop]
  ret double %result
bypass:
  ret double %start
}

define double @reject_update_negation(ptr %a, i64 %n, double %start, <2 x double> %v) !dbg !12 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi double [%start, %preheader], [%update, %loop]
  %p = getelementptr double, ptr %a, i64 %iv
  %x = load double, ptr %p, align 8
  %c = fneg double %x
  %update = fadd double %sum, %c
  %feedback = fneg double %update
  store double %feedback, ptr %p, align 8
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !13
exit:
  %result = phi double [%update, %loop]
  ret double %result
bypass:
  ret double %start
}

define double @reject_vector_negation(ptr %a, i64 %n, double %start, <2 x double> %v) !dbg !14 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi double [%start, %preheader], [%update, %loop]
  %p = getelementptr double, ptr %a, i64 %iv
  %x = load double, ptr %p, align 8
  %c = fneg double %x
  %bad = fneg <2 x double> %v
  %lane = extractelement <2 x double> %bad, i32 0
  %update = fadd double %sum, %lane
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !15
exit:
  %result = phi double [%update, %loop]
  ret double %result
bypass:
  ret double %start
}

define double @reject_strictfp(ptr %a, i64 %n, double %start, <2 x double> %v) strictfp !dbg !16 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi double [%start, %preheader], [%update, %loop]
  %p = getelementptr double, ptr %a, i64 %iv
  %x = load double, ptr %p, align 8
  %c = fneg double %x
  %update = fadd double %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !17
exit:
  %result = phi double [%update, %loop]
  ret double %result
bypass:
  ret double %start
}

define double @reject_constrained(ptr %a, i64 %n, double %start, <2 x double> %v) !dbg !18 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi double [%start, %preheader], [%update, %loop]
  %p = getelementptr double, ptr %a, i64 %iv
  %x = load double, ptr %p, align 8
  %neg = fneg double %x
  %c = call double @llvm.experimental.constrained.fadd.f64(double %neg, double 1.0, metadata !"round.dynamic", metadata !"fpexcept.strict")
  %update = fadd double %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !19
exit:
  %result = phi double [%update, %loop]
  ret double %result
bypass:
  ret double %start
}

define double @reject_unsafe_call(ptr %a, i64 %n, double %start, <2 x double> %v) !dbg !20 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi double [%start, %preheader], [%update, %loop]
  %p = getelementptr double, ptr %a, i64 %iv
  %x = load double, ptr %p, align 8
  %neg = fneg double %x
  %c = call double @unsafe(double %neg)
  %update = fadd double %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !21
exit:
  %result = phi double [%update, %loop]
  ret double %result
bypass:
  ret double %start
}

define double @reject_negation_recurrence(ptr %a, i64 %n, double %start, <2 x double> %v) !dbg !22 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi double [%start, %preheader], [%update, %loop]
  %p = getelementptr double, ptr %a, i64 %iv
  %x = load double, ptr %p, align 8
  %c = fneg double %x
  %update = fneg double %sum
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !23
exit:
  %result = phi double [%update, %loop]
  ret double %result
bypass:
  ret double %start
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-fneg-reject.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!5 = !DISubroutineType(types: !6)
!6 = !{}
!10 = distinct !DISubprogram(name: "reject_accumulator_negation", scope: !1, file: !1, line: 10, type: !5, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 12, column: 3, scope: !10)
!12 = distinct !DISubprogram(name: "reject_update_negation", scope: !1, file: !1, line: 20, type: !5, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 22, column: 3, scope: !12)
!14 = distinct !DISubprogram(name: "reject_vector_negation", scope: !1, file: !1, line: 30, type: !5, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!15 = !DILocation(line: 32, column: 3, scope: !14)
!16 = distinct !DISubprogram(name: "reject_strictfp", scope: !1, file: !1, line: 40, type: !5, scopeLine: 40, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!17 = !DILocation(line: 42, column: 3, scope: !16)
!18 = distinct !DISubprogram(name: "reject_constrained", scope: !1, file: !1, line: 50, type: !5, scopeLine: 50, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!19 = !DILocation(line: 52, column: 3, scope: !18)
!20 = distinct !DISubprogram(name: "reject_unsafe_call", scope: !1, file: !1, line: 60, type: !5, scopeLine: 60, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!21 = !DILocation(line: 62, column: 3, scope: !20)
!22 = distinct !DISubprogram(name: "reject_negation_recurrence", scope: !1, file: !1, line: 70, type: !5, scopeLine: 70, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!23 = !DILocation(line: 72, column: 3, scope: !22)
