; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -pass-remarks=vplan-reduction-fission \
; RUN:   -pass-remarks-missed=vplan-reduction-fission -S %s -o %t 2> %t.remarks
; RUN: FileCheck %s < %t
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t -o /dev/null
; RUN: FileCheck %s --check-prefix=REMARK < %t.remarks
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=3 -S %s | FileCheck %s --check-prefix=TINY --implicit-check-not=scalar.fission
;
; Private count representability is separate from the control IV range.
; The 255-trip i8 control wraps, but its ordinal/count does not. The 256-trip
; sibling needs an unrepresentable completed count and must reject. Nonzero
; starts with positive/negative strides reach one trip and the exact default
; scratch byte ceiling. Every original operation remains in the producer.
; Executable comparisons cover all admitted capacities after one and two LVs.

; CHECK-LABEL: define i32 @affine_one(
; CHECK: alloca [1 x i32]
; CHECK: %fission.ordinal = phi i8 [ 0, %preheader ]
; CHECK: %fission.completed = add nuw i8 %fission.ordinal, 1
; CHECK: %fission.completed.count = phi i8 [ %fission.completed, %latch ]
; CHECK: scalar.fission.consumer.body:
; CHECK: %fission.consumer.next = add nuw i8 %fission.consumer.iv, 1
; REMARK: scalar-affine-bounds.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 1, scratch bytes 4
; CHECK: ret i32
; TINY-LABEL: define i32 @affine_one(
; TINY: ret i32
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

; CHECK-LABEL: define i32 @affine_i8_max(
; CHECK: alloca [255 x i32]
; CHECK: %fission.ordinal = phi i8 [ 0, %preheader ]
; CHECK: %fission.completed = add nuw i8 %fission.ordinal, 1
; CHECK: %fission.completed.count = phi i8 [ %fission.completed, %latch ]
; CHECK: scalar.fission.consumer.body:
; CHECK: %fission.consumer.next = add nuw i8 %fission.consumer.iv, 1
; REMARK: scalar-affine-bounds.c:22:3: split scalar-IR reduction loop; {{.*}}scratch capacity 255, scratch bytes 1020
; CHECK: ret i32
; TINY-LABEL: define i32 @affine_i8_max(
; TINY: ret i32
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

; CHECK-LABEL: define i32 @affine_i8_overflow(
; CHECK-NOT: scalar.fission
; REMARK: scalar-affine-bounds.c:32:3: scalar-IR reduction fission rejected: trip-count-overflow
; CHECK: ret i32
; TINY-LABEL: define i32 @affine_i8_overflow(
; TINY: ret i32
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

; CHECK-LABEL: define i32 @affine_default_limit(
; CHECK: alloca [16384 x i32]
; CHECK: %fission.ordinal = phi i32 [ 0, %preheader ]
; CHECK: %fission.completed = add nuw i32 %fission.ordinal, 1
; CHECK: %fission.completed.count = phi i32 [ %fission.completed, %latch ]
; CHECK: scalar.fission.consumer.body:
; CHECK: %fission.consumer.next = add nuw i32 %fission.consumer.iv, 1
; REMARK: scalar-affine-bounds.c:42:3: split scalar-IR reduction loop; {{.*}}scratch capacity 16384, scratch bytes 65536
; CHECK: ret i32
; TINY-LABEL: define i32 @affine_default_limit(
; TINY: ret i32
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

; CHECK-LABEL: define i32 @affine_over_limit(
; CHECK-NOT: scalar.fission
; REMARK: scalar-affine-bounds.c:52:3: scalar-IR reduction fission rejected: scalar-scratch-limit
; CHECK: ret i32
; TINY-LABEL: define i32 @affine_over_limit(
; TINY: ret i32
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
