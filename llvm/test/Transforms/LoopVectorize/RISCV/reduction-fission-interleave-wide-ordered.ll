; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @interleave4_ordered(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @interleave8_ordered(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
define void @interleave4_ordered(ptr readonly %a, ptr %out, i64 %n, double %start) !dbg !5 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !6
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi double [%start, %preheader], [%u0, %loop]
  %r1 = phi double [-0.0, %preheader], [%u1, %loop]
  %base = mul nuw i64 %i, 4
  %idx3 = add nuw i64 %base, 3
  %p3 = getelementptr double, ptr %a, i64 %idx3
  %x3 = load double, ptr %p3, align 8
  %p0 = getelementptr double, ptr %a, i64 %base
  %x0 = load double, ptr %p0, align 8
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr double, ptr %a, i64 %idx1
  %x1 = load double, ptr %p1, align 8
  %idx2 = add nuw i64 %base, 2
  %p2 = getelementptr double, ptr %a, i64 %idx2
  %x2 = load double, ptr %p2, align 8
  %scaled = fmul double %x0, 2.0
  %shared = fadd double %scaled, %x0
  %term1 = fsub double %shared, %x1
  %term2 = fadd double %term1, %x2
  %term3 = fsub double %term2, %x3
  %u0 = fadd double %r0, %term3
  %u1 = fadd double %r1, %term3
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !6
exit:
  %o0 = getelementptr double, ptr %out, i64 0
  store double %u0, ptr %o0, align 8
  %o1 = getelementptr double, ptr %out, i64 1
  store double %u1, ptr %o1, align 8
  ret void
bypass:
  %b0 = getelementptr double, ptr %out, i64 0
  store double %start, ptr %b0, align 8
  %b1 = getelementptr double, ptr %out, i64 1
  store double -0.0, ptr %b1, align 8
  ret void
}

define void @interleave8_ordered(ptr readonly %a, ptr %out, i64 %n, double %start) !dbg !7 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !8
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi double [%start, %preheader], [%u0, %loop]
  %r1 = phi double [-0.0, %preheader], [%u1, %loop]
  %base = mul nuw i64 %i, 8
  %idx7 = add nuw i64 %base, 7
  %p7 = getelementptr double, ptr %a, i64 %idx7
  %x7 = load double, ptr %p7, align 8
  %p0 = getelementptr double, ptr %a, i64 %base
  %x0 = load double, ptr %p0, align 8
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr double, ptr %a, i64 %idx1
  %x1 = load double, ptr %p1, align 8
  %idx2 = add nuw i64 %base, 2
  %p2 = getelementptr double, ptr %a, i64 %idx2
  %x2 = load double, ptr %p2, align 8
  %idx3 = add nuw i64 %base, 3
  %p3 = getelementptr double, ptr %a, i64 %idx3
  %x3 = load double, ptr %p3, align 8
  %idx4 = add nuw i64 %base, 4
  %p4 = getelementptr double, ptr %a, i64 %idx4
  %x4 = load double, ptr %p4, align 8
  %idx5 = add nuw i64 %base, 5
  %p5 = getelementptr double, ptr %a, i64 %idx5
  %x5 = load double, ptr %p5, align 8
  %idx6 = add nuw i64 %base, 6
  %p6 = getelementptr double, ptr %a, i64 %idx6
  %x6 = load double, ptr %p6, align 8
  %scaled = fmul double %x0, 2.0
  %shared = fadd double %scaled, %x0
  %term1 = fsub double %shared, %x1
  %term2 = fadd double %term1, %x2
  %term3 = fsub double %term2, %x3
  %term4 = fadd double %term3, %x4
  %term5 = fsub double %term4, %x5
  %term6 = fadd double %term5, %x6
  %term7 = fsub double %term6, %x7
  %u0 = fadd double %r0, %term7
  %u1 = fadd double %r1, %term7
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !8
exit:
  %o0 = getelementptr double, ptr %out, i64 0
  store double %u0, ptr %o0, align 8
  %o1 = getelementptr double, ptr %out, i64 1
  store double %u1, ptr %o1, align 8
  ret void
bypass:
  %b0 = getelementptr double, ptr %out, i64 0
  store double %start, ptr %b0, align 8
  %b1 = getelementptr double, ptr %out, i64 1
  store double -0.0, ptr %b1, align 8
  ret void
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2}
!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "interleave-wide-ordered.c", directory: "/")
!2 = !{i32 2, !"Debug Info Version", i32 3}
!3 = !DISubroutineType(types: !4)
!4 = !{null}
!5 = distinct !DISubprogram(name: "interleave4_ordered", scope: !1, file: !1, line: 10, type: !3, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!6 = !DILocation(line: 10, column: 5, scope: !5)
!7 = distinct !DISubprogram(name: "interleave8_ordered", scope: !1, file: !1, line: 30, type: !3, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!8 = !DILocation(line: 30, column: 5, scope: !7)
