; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @affine_one(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @affine_i8_max(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @affine_i8_overflow(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @affine_default_limit(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @affine_over_limit(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @affine_relational_limit(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @affine_relational_over_limit(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @affine_relational_i8_max(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @affine_relational_i8_overflow(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
define i32 @affine_one(i32 %cutoff) !dbg !6 {
entry:
  br label %preheader
preheader:
  br label %loop, !dbg !7
loop:
  %iv = phi i8 [7, %preheader], [%next, %latch]
  %sum = phi i32 [17, %preheader], [%update, %latch]
  %distance = sub i8 7, %iv
  %wide = zext i8 %distance to i32
  %choose = icmp ult i32 %wide, %cutoff
  br i1 %choose, label %left, label %first.merge
left:
  %lc = add i32 %wide, 3
  br label %first.merge
first.merge:
  %first = phi i32 [%wide, %loop], [%lc, %left]
  %bit = and i32 %wide, 1
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %right, label %latch
right:
  %rc = xor i32 %first, 7
  br label %latch
latch:
  %c = phi i32 [%first, %first.merge], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add i8 %iv, -3
  %done = icmp eq i8 4, %next
  br i1 %done, label %exit, label %loop, !dbg !7
exit:
  %result = phi i32 [%update, %latch]
  ret i32 %result
}

define i32 @affine_i8_max(i32 %cutoff) !dbg !8 {
entry:
  br label %preheader
preheader:
  br label %loop, !dbg !9
loop:
  %iv = phi i8 [11, %preheader], [%next, %latch]
  %sum = phi i32 [17, %preheader], [%update, %latch]
  %distance = sub i8 %iv, 11
  %wide = zext i8 %distance to i32
  %choose = icmp ult i32 %wide, %cutoff
  br i1 %choose, label %left, label %first.merge
left:
  %lc = add i32 %wide, 3
  br label %first.merge
first.merge:
  %first = phi i32 [%wide, %loop], [%lc, %left]
  %bit = and i32 %wide, 1
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %right, label %latch
right:
  %rc = xor i32 %first, 7
  br label %latch
latch:
  %c = phi i32 [%first, %first.merge], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add i8 %iv, 1
  %done = icmp eq i8 10, %next
  br i1 %done, label %exit, label %loop, !dbg !9
exit:
  %result = phi i32 [%update, %latch]
  ret i32 %result
}

define i32 @affine_i8_overflow(i32 %cutoff) !dbg !10 {
entry:
  br label %preheader
preheader:
  br label %loop, !dbg !11
loop:
  %iv = phi i8 [11, %preheader], [%next, %latch]
  %sum = phi i32 [17, %preheader], [%update, %latch]
  %distance = sub i8 %iv, 11
  %wide = zext i8 %distance to i32
  %choose = icmp ult i32 %wide, %cutoff
  br i1 %choose, label %left, label %first.merge
left:
  %lc = add i32 %wide, 3
  br label %first.merge
first.merge:
  %first = phi i32 [%wide, %loop], [%lc, %left]
  %bit = and i32 %wide, 1
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %right, label %latch
right:
  %rc = xor i32 %first, 7
  br label %latch
latch:
  %c = phi i32 [%first, %first.merge], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add i8 %iv, 1
  %done = icmp eq i8 11, %next
  br i1 %done, label %exit, label %loop, !dbg !11
exit:
  %result = phi i32 [%update, %latch]
  ret i32 %result
}

define i32 @affine_default_limit(i32 %cutoff) !dbg !12 {
entry:
  br label %preheader
preheader:
  br label %loop, !dbg !13
loop:
  %iv = phi i32 [23, %preheader], [%next, %latch]
  %sum = phi i32 [17, %preheader], [%update, %latch]
  %distance = sub nuw i32 %iv, 23
  %wide = udiv i32 %distance, 3
  %choose = icmp ult i32 %wide, %cutoff
  br i1 %choose, label %left, label %first.merge
left:
  %lc = add i32 %wide, 3
  br label %first.merge
first.merge:
  %first = phi i32 [%wide, %loop], [%lc, %left]
  %bit = and i32 %wide, 1
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %right, label %latch
right:
  %rc = xor i32 %first, 7
  br label %latch
latch:
  %c = phi i32 [%first, %first.merge], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add i32 %iv, 3
  %done = icmp eq i32 49175, %next
  br i1 %done, label %exit, label %loop, !dbg !13
exit:
  %result = phi i32 [%update, %latch]
  ret i32 %result
}

define i32 @affine_over_limit(i32 %cutoff) !dbg !14 {
entry:
  br label %preheader
preheader:
  br label %loop, !dbg !15
loop:
  %iv = phi i32 [23, %preheader], [%next, %latch]
  %sum = phi i32 [17, %preheader], [%update, %latch]
  %distance = sub nuw i32 %iv, 23
  %wide = udiv i32 %distance, 3
  %choose = icmp ult i32 %wide, %cutoff
  br i1 %choose, label %left, label %first.merge
left:
  %lc = add i32 %wide, 3
  br label %first.merge
first.merge:
  %first = phi i32 [%wide, %loop], [%lc, %left]
  %bit = and i32 %wide, 1
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %right, label %latch
right:
  %rc = xor i32 %first, 7
  br label %latch
latch:
  %c = phi i32 [%first, %first.merge], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add i32 %iv, 3
  %done = icmp eq i32 49178, %next
  br i1 %done, label %exit, label %loop, !dbg !15
exit:
  %result = phi i32 [%update, %latch]
  ret i32 %result
}

define i32 @affine_relational_limit(i32 %cutoff) !dbg !16 {
entry:
  br label %preheader
preheader:
  br label %loop, !dbg !17
loop:
  %iv = phi i32 [23, %preheader], [%next, %latch]
  %sum = phi i32 [17, %preheader], [%update, %latch]
  %distance = sub nuw i32 %iv, 23
  %wide = udiv i32 %distance, 3
  %choose = icmp ult i32 %wide, %cutoff
  br i1 %choose, label %left, label %first.merge
left:
  %lc = add i32 %wide, 3
  br label %first.merge
first.merge:
  %first = phi i32 [%wide, %loop], [%lc, %left]
  %bit = and i32 %wide, 1
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %right, label %latch
right:
  %rc = xor i32 %first, 7
  br label %latch
latch:
  %c = phi i32 [%first, %first.merge], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add i32 %iv, 3
  %done = icmp ult i32 %next, 49175
  br i1 %done, label %loop, label %exit, !dbg !17
exit:
  %result = phi i32 [%update, %latch]
  ret i32 %result
}

define i32 @affine_relational_over_limit(i32 %cutoff) !dbg !18 {
entry:
  br label %preheader
preheader:
  br label %loop, !dbg !19
loop:
  %iv = phi i32 [23, %preheader], [%next, %latch]
  %sum = phi i32 [17, %preheader], [%update, %latch]
  %distance = sub nuw i32 %iv, 23
  %wide = udiv i32 %distance, 3
  %choose = icmp ult i32 %wide, %cutoff
  br i1 %choose, label %left, label %first.merge
left:
  %lc = add i32 %wide, 3
  br label %first.merge
first.merge:
  %first = phi i32 [%wide, %loop], [%lc, %left]
  %bit = and i32 %wide, 1
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %right, label %latch
right:
  %rc = xor i32 %first, 7
  br label %latch
latch:
  %c = phi i32 [%first, %first.merge], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add i32 %iv, 3
  %done = icmp ult i32 %next, 49178
  br i1 %done, label %loop, label %exit, !dbg !19
exit:
  %result = phi i32 [%update, %latch]
  ret i32 %result
}

define i32 @affine_relational_i8_max(i32 %cutoff) !dbg !20 {
entry:
  br label %preheader
preheader:
  br label %loop, !dbg !21
loop:
  %iv = phi i8 [0, %preheader], [%next, %latch]
  %sum = phi i32 [17, %preheader], [%update, %latch]
  %distance = sub i8 %iv, 0
  %wide = zext i8 %distance to i32
  %choose = icmp ult i32 %wide, %cutoff
  br i1 %choose, label %left, label %first.merge
left:
  %lc = add i32 %wide, 3
  br label %first.merge
first.merge:
  %first = phi i32 [%wide, %loop], [%lc, %left]
  %bit = and i32 %wide, 1
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %right, label %latch
right:
  %rc = xor i32 %first, 7
  br label %latch
latch:
  %c = phi i32 [%first, %first.merge], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add i8 %iv, 1
  %done = icmp ult i8 %next, -1
  br i1 %done, label %loop, label %exit, !dbg !21
exit:
  %result = phi i32 [%update, %latch]
  ret i32 %result
}

define i32 @affine_relational_i8_overflow(i32 %cutoff) !dbg !22 {
entry:
  br label %preheader
preheader:
  %begin = trunc i32 %cutoff to i8
  %limit = add i8 %begin, -1
  br label %loop, !dbg !23
loop:
  %iv = phi i8 [%begin, %preheader], [%next, %latch]
  %sum = phi i32 [17, %preheader], [%update, %latch]
  %distance = sub i8 %iv, %begin
  %wide = zext i8 %distance to i32
  %choose = icmp ult i32 %wide, %cutoff
  br i1 %choose, label %left, label %first.merge
left:
  %lc = add i32 %wide, 3
  br label %first.merge
first.merge:
  %first = phi i32 [%wide, %loop], [%lc, %left]
  %bit = and i32 %wide, 1
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %right, label %latch
right:
  %rc = xor i32 %first, 7
  br label %latch
latch:
  %c = phi i32 [%first, %first.merge], [%rc, %right]
  %update = add i32 %sum, %c
  %next = add i8 %iv, 1
  %done = icmp ult i8 %iv, %limit
  br i1 %done, label %loop, label %exit, !dbg !23
exit:
  %result = phi i32 [%update, %latch]
  ret i32 %result
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-affine-bounds.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = !DISubroutineType(types: !5)
!5 = !{}
!6 = distinct !DISubprogram(name: "affine_one", scope: !1, file: !1, line: 10, type: !4, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!7 = !DILocation(line: 12, column: 3, scope: !6)
!8 = distinct !DISubprogram(name: "affine_i8_max", scope: !1, file: !1, line: 20, type: !4, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!9 = !DILocation(line: 22, column: 3, scope: !8)
!10 = distinct !DISubprogram(name: "affine_i8_overflow", scope: !1, file: !1, line: 30, type: !4, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 32, column: 3, scope: !10)
!12 = distinct !DISubprogram(name: "affine_default_limit", scope: !1, file: !1, line: 40, type: !4, scopeLine: 40, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 42, column: 3, scope: !12)
!14 = distinct !DISubprogram(name: "affine_over_limit", scope: !1, file: !1, line: 50, type: !4, scopeLine: 50, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!15 = !DILocation(line: 52, column: 3, scope: !14)
!16 = distinct !DISubprogram(name: "affine_relational_limit", scope: !1, file: !1, line: 60, type: !4, scopeLine: 60, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!17 = !DILocation(line: 62, column: 3, scope: !16)
!18 = distinct !DISubprogram(name: "affine_relational_over_limit", scope: !1, file: !1, line: 70, type: !4, scopeLine: 70, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!19 = !DILocation(line: 72, column: 3, scope: !18)
!20 = distinct !DISubprogram(name: "affine_relational_i8_max", scope: !1, file: !1, line: 80, type: !4, scopeLine: 80, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!21 = !DILocation(line: 82, column: 3, scope: !20)
!22 = distinct !DISubprogram(name: "affine_relational_i8_overflow", scope: !1, file: !1, line: 90, type: !4, scopeLine: 90, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!23 = !DILocation(line: 92, column: 3, scope: !22)
