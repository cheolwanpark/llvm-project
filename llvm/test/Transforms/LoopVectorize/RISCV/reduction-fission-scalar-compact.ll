; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @compact_triangle(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @compact_diamond(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @compact_integer(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @compact_nested(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

define void @compact_triangle(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start) !dbg !4 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %rf = phi float [%fstart, %preheader], [%mf, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch, !dbg !7
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dc = load double, ptr %dp, align 8
  %fc = fptrunc double %dc to float
  %u0 = add i32 %r0, %lc
  %u1 = add i32 %lc, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  br label %latch
latch:
  %m0 = phi i32 [%u0, %left], [%r0, %loop]
  %m1 = phi i32 [%u1, %left], [%r1, %loop]
  %md = phi double [%ud, %left], [%rd, %loop]
  %mf = phi float [%uf, %left], [%rf, %loop]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !7
exit:
  %v0 = phi i32 [17, %entry], [%m0, %latch]
  %v1 = phi i32 [-7, %entry], [%m1, %latch]
  %vd = phi double [%start, %entry], [%md, %latch]
  %vf = phi float [%fstart, %entry], [%mf, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  store float %vf, ptr %fout
  ret void
}

define void @compact_diamond(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start) !dbg !8 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %rf = phi float [%fstart, %preheader], [%mf, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp eq i32 %x, 0
  br i1 %choose, label %right, label %left, !dbg !9
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dc = load double, ptr %dp, align 8
  %fc = fptrunc double %dc to float
  %u0 = add i32 %r0, %lc
  %u1 = add i32 %lc, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  br label %latch
right:
  %unused = xor i32 %x, 7
  br label %latch
latch:
  %m0 = phi i32 [%u0, %left], [%r0, %right]
  %m1 = phi i32 [%u1, %left], [%r1, %right]
  %md = phi double [%ud, %left], [%rd, %right]
  %mf = phi float [%uf, %left], [%rf, %right]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !9
exit:
  %v0 = phi i32 [17, %entry], [%m0, %latch]
  %v1 = phi i32 [-7, %entry], [%m1, %latch]
  %vd = phi double [%start, %entry], [%md, %latch]
  %vf = phi float [%fstart, %entry], [%mf, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  store float %vf, ptr %fout
  ret void
}

define void @compact_integer(ptr readonly %a, ptr %out, i64 %n, i32 %start) !dbg !10 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %initial = zext i32 %start to i64
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i64 [%initial, %preheader], [%m, %latch]
  %sum2 = phi i64 [0, %preheader], [%m2, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp eq i32 %x, 0
  br i1 %choose, label %latch, label %left, !dbg !11
left:
  %wide = zext i32 %x to i64
  %c = mul nuw nsw i64 %wide, 13
  %u = add nuw nsw i64 %c, %sum
  %u2 = add nuw nsw i64 %sum2, %c
  br label %latch
latch:
  %m = phi i64 [%sum, %loop], [%u, %left]
  %m2 = phi i64 [%sum2, %loop], [%u2, %left]
  %next = add nuw i64 %iv, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit, !dbg !11
exit:
  %result = phi i64 [%initial, %entry], [%m, %latch]
  %result2 = phi i64 [0, %entry], [%m2, %latch]
  %combined = add i64 %result, %result2
  store i64 %combined, ptr %out
  ret void
}

define void @compact_nested(ptr readonly %a, ptr readonly %fp, ptr %out,
                                  ptr %dout, i64 %rows, i64 %n, double %start) !dbg !12 {
entry:
  %rows.valid = icmp ule i64 %rows, 4
  %rows.nonzero = icmp ne i64 %rows, 0
  %rows.enter = and i1 %rows.valid, %rows.nonzero
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  %enter = and i1 %rows.enter, %inner.enter
  br i1 %enter, label %outer.ph, label %exit
outer.ph:
  br label %outer
outer:
  %row = phi i64 [0, %outer.ph], [%row.next, %row.exit]
  %carry = phi i32 [19, %outer.ph], [%row.sum, %row.exit]
  %dcarry = phi double [%start, %outer.ph], [%row.dsum, %row.exit]
  %offset = mul nuw i64 %row, 65
  %base = getelementptr i32, ptr %a, i64 %offset
  %dbase = getelementptr double, ptr %fp, i64 %offset
  %salt = trunc i64 %row to i32
  br label %inner.ph
inner.ph:
  br label %inner
inner:
  %iv = phi i64 [0, %inner.ph], [%next, %latch]
  %sum = phi i32 [%carry, %inner.ph], [%merged, %latch]
  %dsum = phi double [%dcarry, %inner.ph], [%dmerged, %latch]
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %salted = xor i32 %x, %salt
  %bit = and i32 %x, 1
  %choose = icmp ne i32 %bit, 0
  br i1 %choose, label %left, label %right, !dbg !13
left:
  %lc = call i32 @scalar_helper(i32 %salted)
  %dp = getelementptr double, ptr %dbase, i64 %iv
  %dx = load double, ptr %dp, align 8
  %ld = fmul double %dx, 3.0
  %update = add i32 %sum, %lc
  %dupdate = fadd double %dsum, %ld
  br label %latch
right:
  %unused = xor i32 %x, 7
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %right]
  %dmerged = phi double [%dupdate, %left], [%dsum, %right]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %row.exit, label %inner, !dbg !13
row.exit:
  %row.sum = phi i32 [%merged, %latch]
  %row.dsum = phi double [%dmerged, %latch]
  %dst = getelementptr i32, ptr %out, i64 %row
  %ddst = getelementptr double, ptr %dout, i64 %row
  store i32 %row.sum, ptr %dst
  store double %row.dsum, ptr %ddst
  %row.next = add nuw i64 %row, 1
  %rows.done = icmp eq i64 %row.next, %rows
  br i1 %rows.done, label %exit, label %outer
exit:
  ret void
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-compact.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = distinct !DISubprogram(name: "compact_triangle", scope: !1, file: !1, line: 10, type: !5, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!5 = !DISubroutineType(types: !6)
!6 = !{}
!7 = !DILocation(line: 12, column: 3, scope: !4)
!8 = distinct !DISubprogram(name: "compact_diamond", scope: !1, file: !1, line: 20, type: !5, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!9 = !DILocation(line: 22, column: 5, scope: !8)
!10 = distinct !DISubprogram(name: "compact_integer", scope: !1, file: !1, line: 30, type: !5, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 32, column: 7, scope: !10)
!12 = distinct !DISubprogram(name: "compact_nested", scope: !1, file: !1, line: 40, type: !5, scopeLine: 40, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 42, column: 9, scope: !12)
