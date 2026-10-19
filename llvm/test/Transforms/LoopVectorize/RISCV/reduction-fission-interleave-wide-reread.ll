; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @interleave5_reread(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @interleave8_reread(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
define void @interleave5_reread(ptr readonly %a, ptr %out, i64 %n) !dbg !5 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !6
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [23, %preheader], [%u1, %loop]
  %base = mul nuw i64 %i, 5
  %idx4 = add nuw i64 %base, 4
  %p4 = getelementptr i32, ptr %a, i64 %idx4
  %x4 = load i32, ptr %p4, align 4
  %p0 = getelementptr i32, ptr %a, i64 %base
  %x0 = load i32, ptr %p0, align 4
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr i32, ptr %a, i64 %idx1
  %x1 = load i32, ptr %p1, align 4
  %idx2 = add nuw i64 %base, 2
  %p2 = getelementptr i32, ptr %a, i64 %idx2
  %x2 = load i32, ptr %p2, align 4
  %idx3 = add nuw i64 %base, 3
  %p3 = getelementptr i32, ptr %a, i64 %idx3
  %x3 = load i32, ptr %p3, align 4
  %c0 = mul i32 %x0, 3
  %c1 = xor i32 %c0, 5
  %c2 = mul i32 %c1, 7
  %c3 = xor i32 %c2, 9
  %c4 = mul i32 %c3, 11
  %c5 = xor i32 %c4, 13
  %c6 = mul i32 %c5, 15
  %c7 = xor i32 %c6, 17
  %c8 = mul i32 %c7, 19
  %c9 = xor i32 %c8, 21
  %c10 = mul i32 %c9, 23
  %c11 = xor i32 %c10, 25
  %c12 = mul i32 %c11, 27
  %c13 = xor i32 %c12, 29
  %c14 = mul i32 %c13, 31
  %c15 = xor i32 %c14, 33
  %c16 = mul i32 %c15, 35
  %c17 = xor i32 %c16, 37
  %c18 = mul i32 %c17, 39
  %c19 = xor i32 %c18, 41
  %c20 = mul i32 %c19, 43
  %short2 = xor i32 %x1, %x2
  %short3 = xor i32 %short2, %x3
  %short4 = xor i32 %short3, %x4
  %u0 = add i32 %r0, %c20
  %u1 = xor i32 %r1, %short4
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !6
exit:
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %u0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %u1, ptr %o1, align 4
  ret void
bypass:
  %b0 = getelementptr i32, ptr %out, i64 0
  store i32 17, ptr %b0, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  ret void
}

define void @interleave8_reread(ptr readonly %a, ptr %out, i64 %n) !dbg !7 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !8
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [23, %preheader], [%u1, %loop]
  %base = mul nuw i64 %i, 8
  %idx7 = add nuw i64 %base, 7
  %p7 = getelementptr i32, ptr %a, i64 %idx7
  %x7 = load i32, ptr %p7, align 4
  %p0 = getelementptr i32, ptr %a, i64 %base
  %x0 = load i32, ptr %p0, align 4
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr i32, ptr %a, i64 %idx1
  %x1 = load i32, ptr %p1, align 4
  %idx2 = add nuw i64 %base, 2
  %p2 = getelementptr i32, ptr %a, i64 %idx2
  %x2 = load i32, ptr %p2, align 4
  %idx3 = add nuw i64 %base, 3
  %p3 = getelementptr i32, ptr %a, i64 %idx3
  %x3 = load i32, ptr %p3, align 4
  %idx4 = add nuw i64 %base, 4
  %p4 = getelementptr i32, ptr %a, i64 %idx4
  %x4 = load i32, ptr %p4, align 4
  %idx5 = add nuw i64 %base, 5
  %p5 = getelementptr i32, ptr %a, i64 %idx5
  %x5 = load i32, ptr %p5, align 4
  %idx6 = add nuw i64 %base, 6
  %p6 = getelementptr i32, ptr %a, i64 %idx6
  %x6 = load i32, ptr %p6, align 4
  %c0 = mul i32 %x0, 3
  %c1 = xor i32 %c0, 5
  %c2 = mul i32 %c1, 7
  %c3 = xor i32 %c2, 9
  %c4 = mul i32 %c3, 11
  %c5 = xor i32 %c4, 13
  %c6 = mul i32 %c5, 15
  %c7 = xor i32 %c6, 17
  %c8 = mul i32 %c7, 19
  %c9 = xor i32 %c8, 21
  %c10 = mul i32 %c9, 23
  %c11 = xor i32 %c10, 25
  %c12 = mul i32 %c11, 27
  %c13 = xor i32 %c12, 29
  %c14 = mul i32 %c13, 31
  %c15 = xor i32 %c14, 33
  %c16 = mul i32 %c15, 35
  %c17 = xor i32 %c16, 37
  %c18 = mul i32 %c17, 39
  %c19 = xor i32 %c18, 41
  %c20 = mul i32 %c19, 43
  %short2 = xor i32 %x1, %x2
  %short3 = xor i32 %short2, %x3
  %short4 = xor i32 %short3, %x4
  %short5 = xor i32 %short4, %x5
  %short6 = xor i32 %short5, %x6
  %short7 = xor i32 %short6, %x7
  %u0 = add i32 %r0, %c20
  %u1 = xor i32 %r1, %short7
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !8
exit:
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %u0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %u1, ptr %o1, align 4
  ret void
bypass:
  %b0 = getelementptr i32, ptr %out, i64 0
  store i32 17, ptr %b0, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  ret void
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2}
!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "interleave-wide-reread.c", directory: "/")
!2 = !{i32 2, !"Debug Info Version", i32 3}
!3 = !DISubroutineType(types: !4)
!4 = !{null}
!5 = distinct !DISubprogram(name: "interleave5_reread", scope: !1, file: !1, line: 10, type: !3, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!6 = !DILocation(line: 10, column: 5, scope: !5)
!7 = distinct !DISubprogram(name: "interleave8_reread", scope: !1, file: !1, line: 30, type: !3, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!8 = !DILocation(line: 30, column: 5, scope: !7)
