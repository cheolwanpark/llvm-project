; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @equality_continues(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @unreachable_equality(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @unbounded_witness(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Dependent contribution arithmetic preserves positive feature coverage under
; the final producer depth policy. Checks exercise scalar fission and ordinary LV.
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

define i32 @equality_continues(i8 %begin, i8 %n) !dbg !6 {
entry:
  br label %preheader
preheader:
  br label %loop, !dbg !7
loop:
  %iv = phi i8 [%begin, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %wide = zext i8 %iv to i32
  %c.depth.first = call i32 @scalar_helper(i32 %wide)
  %c.depth.bias = call i32 @scalar_helper(i32 %c.depth.first)
  %c = call i32 @scalar_helper(i32 %c.depth.bias)
  %update = add i32 %sum, %c
  %next = add i8 %iv, 3
  %more = icmp ule i8 %next, -1
  br i1 %more, label %loop, label %exit, !dbg !7
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
}

define i32 @unreachable_equality() !dbg !8 {
entry:
  br label %preheader
preheader:
  br label %loop, !dbg !9
loop:
  %iv = phi i8 [0, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %wide = zext i8 %iv to i32
  %c.depth.first = call i32 @scalar_helper(i32 %wide)
  %c.depth.bias = call i32 @scalar_helper(i32 %c.depth.first)
  %c = call i32 @scalar_helper(i32 %c.depth.bias)
  %update = add i32 %sum, %c
  %next = add i8 %iv, 2
  %more = icmp ult i8 %next, -1
  br i1 %more, label %loop, label %exit, !dbg !9
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
}

define i32 @unbounded_witness(i64 %begin, i64 %n) !dbg !10 {
entry:
  %enter = icmp ne i64 %n, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  %span = mul i64 %n, 3
  %limit = add i64 %begin, %span
  br label %loop, !dbg !11
loop:
  %iv = phi i64 [%begin, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %wide = trunc i64 %iv to i32
  %c.depth.first = call i32 @scalar_helper(i32 %wide)
  %c.depth.bias = call i32 @scalar_helper(i32 %c.depth.first)
  %c = call i32 @scalar_helper(i32 %c.depth.bias)
  %update = add i32 %sum, %c
  %next = add i64 %iv, 3
  %more = icmp ult i64 %next, %limit
  br i1 %more, label %loop, label %exit, !dbg !11
exit:
  %result = phi i32 [17, %entry], [%update, %loop]
  ret i32 %result
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-relational-reject.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = !DISubroutineType(types: !5)
!5 = !{}
!6 = distinct !DISubprogram(name: "equality_continues", scope: !1, file: !1, line: 10, type: !4, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!7 = !DILocation(line: 12, column: 3, scope: !6)
!8 = distinct !DISubprogram(name: "unreachable_equality", scope: !1, file: !1, line: 20, type: !4, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!9 = !DILocation(line: 22, column: 3, scope: !8)
!10 = distinct !DISubprogram(name: "unbounded_witness", scope: !1, file: !1, line: 30, type: !4, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 32, column: 3, scope: !10)
