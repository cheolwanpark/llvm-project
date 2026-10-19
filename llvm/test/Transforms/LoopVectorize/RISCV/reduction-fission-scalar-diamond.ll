; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @scalar_diamond(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @diamond_arithmetic(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @scalar_diamond_nested(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

define void @scalar_diamond(ptr readonly %a, ptr readonly %fp, ptr %out,
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
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !7
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  %lf = fptrunc double %ld to float
  br label %latch
right:
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  %rfp = fptrunc double %rc to float
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [17, %right]
  %dc = phi double [%ld, %left], [%rc, %right]
  %fc = phi float [%lf, %left], [%rfp, %right]
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !7
exit:
  %v0 = phi i32 [17, %entry], [%u0, %latch]
  %v1 = phi i32 [-7, %entry], [%u1, %latch]
  %vd = phi double [%start, %entry], [%ud, %latch]
  %vf = phi float [%fstart, %entry], [%uf, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  store float %vf, ptr %fout
  ret void
}

define void @diamond_arithmetic(ptr readonly %a, ptr %out, i64 %n, i32 %start) !dbg !8 {
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
  %sum = phi i64 [%initial, %preheader], [%update, %latch]
  %hsum = phi i64 [0, %preheader], [%hupdate, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %wide = zext i32 %x to i64
  %hupdate = add nuw nsw i64 %hsum, %wide
  %bit = and i32 %x, 1
  %choose = icmp ne i32 %bit, 0
  br i1 %choose, label %left, label %right, !dbg !9
left:
  %lc = mul nuw nsw i64 %wide, 13
  br label %latch
right:
  %shift = lshr i32 %x, 1
  %rc = zext i32 %shift to i64
  br label %latch
latch:
  %c = phi i64 [%lc, %left], [%rc, %right]
  %update = add nuw nsw i64 %c, %sum
  %next = add nuw i64 %iv, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit, !dbg !9
exit:
  %result = phi i64 [%initial, %entry], [%update, %latch]
  %hresult = phi i64 [0, %entry], [%hupdate, %latch]
  %combined = add i64 %result, %hresult
  store i64 %combined, ptr %out
  ret void
}

define void @scalar_diamond_nested(ptr readonly %a, ptr readonly %fp, ptr %out,
                                  ptr %dout, i64 %rows, i64 %n, double %start) !dbg !10 {
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
  %sum = phi i32 [%carry, %inner.ph], [%update, %latch]
  %dsum = phi double [%dcarry, %inner.ph], [%dupdate, %latch]
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %salted = xor i32 %x, %salt
  %bit = and i32 %x, 1
  %choose = icmp ne i32 %bit, 0
  br i1 %choose, label %left, label %right, !dbg !11
left:
  %lc = call i32 @scalar_helper(i32 %salted)
  %dp = getelementptr double, ptr %dbase, i64 %iv
  %dx = load double, ptr %dp, align 8
  %ld = fmul double %dx, 3.0
  br label %latch
right:
  %rc = sub i32 0, %salted
  %rd = sitofp i32 %rc to double
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [%rc, %right]
  %dc = phi double [%ld, %left], [%rd, %right]
  %update = add i32 %sum, %c
  %dupdate = fadd double %dsum, %dc
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %row.exit, label %inner, !dbg !11
row.exit:
  %row.sum = phi i32 [%update, %latch]
  %row.dsum = phi double [%dupdate, %latch]
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
!1 = !DIFile(filename: "scalar-diamond.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = distinct !DISubprogram(name: "scalar_diamond", scope: !1, file: !1, line: 20, type: !5, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!5 = !DISubroutineType(types: !6)
!6 = !{}
!7 = !DILocation(line: 32, column: 7, scope: !4)
!8 = distinct !DISubprogram(name: "diamond_arithmetic", scope: !1, file: !1, line: 40, type: !5, scopeLine: 40, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!9 = !DILocation(line: 42, column: 3, scope: !8)
!10 = distinct !DISubprogram(name: "scalar_diamond_nested", scope: !1, file: !1, line: 50, type: !5, scopeLine: 50, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 62, column: 5, scope: !10)
