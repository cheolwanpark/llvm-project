; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission \
; RUN:   -pass-remarks-missed=vplan-reduction-fission -S %s -o %t 2>%t.remarks
; RUN: FileCheck %s --implicit-check-not=scalar.fission < %t
; RUN: FileCheck %s --check-prefix=REASON < %t.remarks
; RUN: opt -passes='loop-vectorize,loop-vectorize' -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-allow-fp-reordering \
; RUN:   -S %s | FileCheck %s --implicit-check-not=scalar.fission
;
; Strict comparison and a bounded equality witness are both necessary for the
; new proof. Do not turn a merely bounded span into an assumed trip count.
; Existing affine-reject.ll retains feedback, live-out, effects and FP cases.

declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

; Equality continues this loop: every i8 value is <= 255. An equality witness
; cannot prove termination. This loop is not mustprogress.
; CHECK-LABEL: define i32 @equality_continues(
; CHECK: %next = add i8 %iv, 3
; CHECK: %more = icmp ule i8 %next, -1
; CHECK: br i1 %more, label %loop, label %exit
; CHECK: ret i32
; REASON: scalar-relational-reject.c:12:3: scalar-IR reduction fission rejected: non-constant-trip-count
define i32 @equality_continues(i8 %begin, i8 %n) !dbg !6 {
entry:
  br label %preheader
preheader:
  br label %loop, !dbg !7
loop:
  %iv = phi i8 [%begin, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %wide = zext i8 %iv to i32
  %c = call i32 @scalar_helper(i32 %wide)
  %update = add i32 %sum, %c
  %next = add i8 %iv, 3
  %more = icmp ule i8 %next, -1
  br i1 %more, label %loop, label %exit, !dbg !7
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
}

; A strict comparison alone is insufficient: an even IV never reaches 255.
; CHECK-LABEL: define i32 @unreachable_equality(
; CHECK: %next = add i8 %iv, 2
; CHECK: %more = icmp ult i8 %next, -1
; CHECK: br i1 %more, label %loop, label %exit
; CHECK: ret i32
; REASON: scalar-relational-reject.c:22:3: scalar-IR reduction fission rejected: non-constant-trip-count
define i32 @unreachable_equality() !dbg !8 {
entry:
  br label %preheader
preheader:
  br label %loop, !dbg !9
loop:
  %iv = phi i8 [0, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %wide = zext i8 %iv to i32
  %c = call i32 @scalar_helper(i32 %wide)
  %update = add i32 %sum, %c
  %next = add i8 %iv, 2
  %more = icmp ult i8 %next, -1
  br i1 %more, label %loop, label %exit, !dbg !9
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
}

; Equality is reachable but its span has no small unconditional bound. The
; n!=0 entry guard proves a representable count, not a bounded allocation.
; CHECK-LABEL: define i32 @unbounded_witness(
; CHECK: %next = add i64 %iv, 3
; CHECK: %more = icmp ult i64 %next, %limit
; CHECK: ret i32
; REASON: scalar-relational-reject.c:32:3: scalar-IR reduction fission rejected: scalar-scratch-limit
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
  %c = call i32 @scalar_helper(i32 %wide)
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
