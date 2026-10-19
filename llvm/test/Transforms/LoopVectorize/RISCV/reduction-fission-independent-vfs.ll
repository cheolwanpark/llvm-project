; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @independent_vfs(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @independent_vfs_bounded(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
define void @independent_vfs(ptr noalias readonly %a, ptr noalias %out) !dbg !5 {
entry:
  br label %loop, !dbg !6
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %sum = phi i32 [0, %entry], [%update, %loop]
  %p = getelementptr i64, ptr %a, i64 %i
  %x = load i64, ptr %p, align 8
  %term = call i32 @foo(i64 %x) #0, !dbg !6
  %update = add i32 %sum, %term
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, 65
  br i1 %done, label %exit, label %loop, !dbg !6
exit:
  store i32 %update, ptr %out, align 4
  ret void
}

define void @independent_vfs_bounded(ptr noalias readonly %a, ptr noalias %out, i64 %n) !dbg !7 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !8
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %bits = phi i32 [23, %preheader], [%update, %loop]
  %p = getelementptr i64, ptr %a, i64 %i
  %x = load i64, ptr %p, align 8
  %lo = trunc i64 %x to i32
  %term = call i32 @bar(i32 %lo, i64 %x) #1, !dbg !8
  %update = xor i32 %bits, %term
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !8
exit:
  store i32 %update, ptr %out, align 4
  ret void
bypass:
  store i32 23, ptr %out, align 4
  ret void
}

declare i32 @foo(i64) nounwind willreturn speculatable memory(none)
declare <vscale x 2 x i32> @vecfoo(<vscale x 2 x i64>) nounwind willreturn speculatable memory(none)
declare i32 @bar(i32, i64) nounwind willreturn speculatable memory(none)
declare <vscale x 2 x i32> @vecbar(<vscale x 2 x i32>, <vscale x 2 x i64>) nounwind willreturn speculatable memory(none)
attributes #0 = { "vector-function-abi-variant"="_ZGVrNxv_foo(vecfoo)" }
attributes #1 = { "vector-function-abi-variant"="_ZGVrNxvv_bar(vecbar)" }

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2}
!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "independent-vfs.c", directory: "/")
!2 = !{i32 2, !"Debug Info Version", i32 3}
!3 = !DISubroutineType(types: !4)
!4 = !{null}
!5 = distinct !DISubprogram(name: "independent_vfs", scope: !1, file: !1, line: 1, type: !3, scopeLine: 1, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!6 = !DILocation(line: 10, column: 5, scope: !5)
!7 = distinct !DISubprogram(name: "independent_vfs_bounded", scope: !1, file: !1, line: 20, type: !3, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!8 = !DILocation(line: 30, column: 7, scope: !7)
