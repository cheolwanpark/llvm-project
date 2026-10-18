; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -pass-remarks=vplan-reduction-fission -S %s -o %t 2> %t.remarks
; RUN: FileCheck %s < %t
; RUN: FileCheck %s --check-prefix=REMARK < %t.remarks
;
; Intentionally converted from recurrence-reject.ll: the delay %prev is local
; to the producer. The extracted %sum only feeds its update/bypass/merge and
; final result. The compact counter preserves exactly the old participating
; sequence, including a skipped iteration changing %prev. Original function
; IR and source location are preserved. The execution checker includes this
; exact function, original IR and an independent formula.
;
; REMARK: scalar-recurrence.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 260
; REMARK: scalar-recurrence.c:12:3: scalar-IR fission producer VF 1
; REMARK: scalar-recurrence.c:12:3: scalar-IR fission consumer VF 1
; CHECK-LABEL: define i32 @recurrence_compact(
; CHECK: alloca [65 x i32]
; CHECK: %prev = phi i32 [ 23, %preheader ], [ %x, %latch ]
; CHECK: %choose = icmp ne i32 %x, 0
; CHECK: %c = call i32 @scalar_helper(i32 %prev)
; CHECK: store i32 %c,
; CHECK: %fission.empty = icmp eq i64 %fission.participating.count, 0
; CHECK: %update.consume = add i32 %sum.consume,
; CHECK: %sum.result = phi i32 [ 17, %scalar.fission.consumer.guard ],
; CHECK: ret i32
;
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

define i32 @recurrence_compact(ptr %a, i64 %n) !dbg !12 {
entry:
  %valid = icmp ule i64 %n, 65
  %nz = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nz
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !13
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%x, %latch]
  %sum = phi i32 [17, %preheader], [%merge, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch
left:
  %c = call i32 @scalar_helper(i32 %prev)
  %update = add i32 %sum, %c
  br label %latch
latch:
  %merge = phi i32 [%update, %left], [%sum, %loop]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !13
exit:
  ret i32 %merge
bypass:
  ret i32 17
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-recurrence.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = !DISubroutineType(types: !5)
!5 = !{}
!12 = distinct !DISubprogram(name: "recurrence_compact", scope: !1, file: !1, line: 12, type: !4, scopeLine: 12, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 12, column: 3, scope: !12)
