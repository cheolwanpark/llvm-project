; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=4 \
; RUN:   -pass-remarks=vplan-reduction-fission -pass-remarks-missed=vplan-reduction-fission -S %s -o %t 2> %t.remarks
; RUN: FileCheck %s --check-prefix=REASON < %t.remarks
; RUN: FileCheck %s < %t
;
; A small ceiling cannot bypass any existing legality contract. Every loop
; would need more than four full-trip scratch bytes. Noncanonical and reverse
; equality loops now use capacity-one original-control chunks. The latter's
; operand is one although it executes twice; executable checks retain this case.
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable
declare i32 @unsafe(i32) nounwind willreturn
declare double @llvm.experimental.constrained.fadd.f64(double, double, metadata, metadata)

; REASON: scalar-chunks-reject.c:12:3: scalar-IR reduction fission rejected: scalar-unsupported-recurrence
; CHECK-LABEL: define i32 @chunk_feedback(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
; CHECK-NOT: scalar.fission
define i32 @chunk_feedback(ptr %a, i64 %n) !dbg !10 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = add i32 %x, %sum
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !11
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
bypass:
  ret i32 17
}

; REASON: scalar-chunks-reject.c:22:3: scalar-IR reduction fission rejected: scalar-unsafe-call
; CHECK-LABEL: define i32 @chunk_effect(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
; CHECK-NOT: scalar.fission
define i32 @chunk_effect(ptr %a, i64 %n) !dbg !12 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @unsafe(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !13
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
bypass:
  ret i32 17
}

; REASON: scalar-chunks-reject.c:32:3: scalar-IR reduction fission rejected: scalar-non-simple-load
; CHECK-LABEL: define i32 @chunk_volatile(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
; CHECK-NOT: scalar.fission
define i32 @chunk_volatile(ptr %a, i64 %n) !dbg !14 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load volatile i32, ptr %p, align 4
  %c = call i32 @scalar_helper(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !15
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
bypass:
  ret i32 17
}

; REASON: scalar-chunks-reject.c:42:3: scalar-IR reduction fission rejected: scalar-strict-fp
; CHECK-LABEL: define i32 @chunk_strictfp(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
; CHECK-NOT: scalar.fission
define i32 @chunk_strictfp(ptr %a, i64 %n) strictfp !dbg !16 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @scalar_helper(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !17
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
bypass:
  ret i32 17
}

; The four-byte ceiling now schedules the 58-element affine stream in one-slot
; chunks. It forwards original control and the actual IV, without endpoint math.
; REASON: scalar-chunks-reject.c:52:3: split scalar-IR reduction loop; {{.*}}scratch capacity 1, scratch bytes 4
; CHECK-LABEL: define i32 @chunk_noncanonical(
; CHECK: alloca [1 x i32]
; CHECK: scalar.fission.chunk:
; CHECK: %fission.producer.iv.next = phi i64 [ %next, %loop ]
; CHECK: %fission.producer.completed = phi i64 [ %fission.producer.next, %loop ]
; CHECK: br i1 %fission.producer.continue, label %scalar.fission.chunk
; CHECK: ret i32
define i32 @chunk_noncanonical(ptr %a, i64 %n) !dbg !18 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ugt i64 %n, 7
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [7, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @scalar_helper(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !19
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
bypass:
  ret i32 17
}

; REASON: scalar-chunks-reject.c:62:3: split scalar-IR reduction loop; {{.*}}scratch capacity 1, scratch bytes 4
; CHECK-LABEL: define i32 @chunk_reverse_equality(
; CHECK: alloca [1 x i32]
; CHECK: scalar.fission.chunk:
; CHECK: %fission.producer.iv.next = phi i8 [ %next, %loop ]
; CHECK: %fission.producer.completed = phi i8 [ %fission.producer.next, %loop ]
; CHECK: br i1 %fission.producer.continue, label %scalar.fission.chunk
; CHECK: ret i32
define i32 @chunk_reverse_equality(i32 %x) !dbg !20 {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i8 [0, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %update = add i32 %sum, %x
  %next = add nuw i8 %iv, 1
  %done = icmp eq i8 %next, 1
  br i1 %done, label %loop, label %exit, !dbg !21
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
}

; REASON: scalar-chunks-reject.c:72:3: scalar-IR reduction fission rejected: scalar-strict-fp
; CHECK-LABEL: define double @chunk_constrained(
; CHECK-NOT: scalar.fission
; CHECK: ret double
; CHECK-NOT: scalar.fission
define double @chunk_constrained(ptr %a, i64 %n) !dbg !22 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi double [0.0, %preheader], [%update, %loop]
  %p = getelementptr double, ptr %a, i64 %iv
  %x = load double, ptr %p, align 8
  %c = call double @llvm.experimental.constrained.fadd.f64(double %x, double 1.0, metadata !"round.dynamic", metadata !"fpexcept.strict")
  %update = fadd double %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !23
exit:
  %result = phi double [%update, %loop]
  ret double %result
bypass:
  ret double 0.0
}

; Intentionally changed: canonical chunks now forward the delay's exact
; backedge, while every genuine rejection above retains its old contract.
; REASON: scalar-chunks-reject.c:82:3: split scalar-IR reduction loop; {{.*}}scratch capacity 1, scratch bytes 4
; REASON-SAME: producer state carries 1
; CHECK-LABEL: define i32 @chunk_retained_state(
; CHECK: %prev.chunk.carry = phi i32 [ 23, %preheader ], [ %prev.chunk.backedge, %scalar.fission.chunk.latch ]
; CHECK: %prev = phi i32 [ %prev.chunk.carry, %scalar.fission.producer.ph ], [ %x, %loop ]
; CHECK: %prev.chunk.backedge = phi i32 [ %x, %loop ]
; CHECK: ret i32
define i32 @chunk_retained_state(ptr %a, i64 %n) !dbg !24 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !25
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %prev = phi i32 [23, %preheader], [%x, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p
  %raw = xor i32 %prev, %x
  %c = call i32 @scalar_helper(i32 %raw)
  %update = add i32 %sum, %c
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !25
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
bypass:
  ret i32 17
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-chunks-reject.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!5 = !DISubroutineType(types: !6)
!6 = !{}
!20 = distinct !DISubprogram(name: "chunk_reverse_equality", scope: !1, file: !1, line: 60, type: !5, scopeLine: 60, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!21 = !DILocation(line: 62, column: 3, scope: !20)
!22 = distinct !DISubprogram(name: "chunk_constrained", scope: !1, file: !1, line: 70, type: !5, scopeLine: 70, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!23 = !DILocation(line: 72, column: 3, scope: !22)
!10 = distinct !DISubprogram(name: "chunk_feedback", scope: !1, file: !1, line: 10, type: !5, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 12, column: 3, scope: !10)
!12 = distinct !DISubprogram(name: "chunk_effect", scope: !1, file: !1, line: 20, type: !5, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 22, column: 3, scope: !12)
!14 = distinct !DISubprogram(name: "chunk_volatile", scope: !1, file: !1, line: 30, type: !5, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!15 = !DILocation(line: 32, column: 3, scope: !14)
!16 = distinct !DISubprogram(name: "chunk_strictfp", scope: !1, file: !1, line: 40, type: !5, scopeLine: 40, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!17 = !DILocation(line: 42, column: 3, scope: !16)
!18 = distinct !DISubprogram(name: "chunk_noncanonical", scope: !1, file: !1, line: 50, type: !5, scopeLine: 50, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!19 = !DILocation(line: 52, column: 3, scope: !18)
!24 = distinct !DISubprogram(name: "chunk_retained_state", scope: !1, file: !1, line: 80, type: !5, scopeLine: 80, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!25 = !DILocation(line: 82, column: 3, scope: !24)
