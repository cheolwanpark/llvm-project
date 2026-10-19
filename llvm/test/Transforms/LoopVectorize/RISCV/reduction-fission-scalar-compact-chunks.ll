; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @compact_chunk_diamond(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @compact_chunk_cfg(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @compact_chunk_narrow(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @compact_chunk_rows(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

define void @compact_chunk_diamond(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                      ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !10 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !11
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %older = phi i32 [-11, %preheader], [%prev, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %state.next = add i32 %x, %older
  %nonzero.x = icmp ne i32 %x, 0
  %state.bit = and i32 %prev, 1
  %state.odd = icmp ne i32 %state.bit, 0
  %state.mode = icmp eq i64 %rows, 2
  %state.choose = and i1 %nonzero.x, %state.odd
  %choose = select i1 %state.mode, i1 %state.choose, i1 %nonzero.x
  br i1 %choose, label %left, label %right
left:
  %raw = xor i32 %prev, %state.next
  %c = call i32 @scalar_helper(i32 %raw)
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %as.double = uitofp i32 %prev to double
  %dc = fsub double %dx, %as.double
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  br label %latch
right:
  br label %latch
latch:
  %m0 = phi i32 [%r0, %right], [%u0, %left]
  %m1 = phi i32 [%r1, %right], [%u1, %left]
  %md = phi double [%rd, %right], [%ud, %left]
  %last.dc = phi double [%start, %right], [%dc, %left]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %producer.exit, label %loop, !dbg !11
producer.exit:
  %out.r0 = phi i32 [%m0, %latch]
  %out.r1 = phi i32 [%m1, %latch]
  %out.prev = phi i32 [%prev, %latch]
  %out.older = phi i32 [%older, %latch]
  %out.state.next = phi i32 [%state.next, %latch]
  %out.rd = phi double [%md, %latch]
  %out.last.dc = phi double [%last.dc, %latch]
  %out.iv = phi i64 [%iv, %latch]
  %out.next = phi i64 [%next, %latch]
  %out.p0 = getelementptr i32, ptr %out, i64 0
  store i32 %out.r0, ptr %out.p0, align 4
  %out.p1 = getelementptr i32, ptr %out, i64 1
  store i32 %out.r1, ptr %out.p1, align 4
  %out.p2 = getelementptr i32, ptr %out, i64 2
  store i32 %out.prev, ptr %out.p2, align 4
  %out.p3 = getelementptr i32, ptr %out, i64 3
  store i32 %out.older, ptr %out.p3, align 4
  %out.p4 = getelementptr i32, ptr %out, i64 4
  store i32 %out.state.next, ptr %out.p4, align 4
  %dout.p0 = getelementptr double, ptr %dout, i64 0
  store double %out.rd, ptr %dout.p0, align 8
  %dout.p1 = getelementptr double, ptr %dout, i64 1
  store double %out.last.dc, ptr %dout.p1, align 8
  %indices.p0 = getelementptr i64, ptr %indices, i64 0
  store i64 %out.iv, ptr %indices.p0, align 8
  %indices.p1 = getelementptr i64, ptr %indices, i64 1
  store i64 %out.next, ptr %indices.p1, align 8
  ret void
bypass:
  ret void
}

define void @compact_chunk_cfg(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                      ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !12 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !13
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %older = phi i32 [-11, %preheader], [%prev, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %state.next = add i32 %x, %older
  %nonzero.x = icmp ne i32 %x, 0
  %state.bit = and i32 %prev, 1
  %state.odd = icmp ne i32 %state.bit, 0
  %state.mode = icmp eq i64 %rows, 2
  %state.choose = and i1 %nonzero.x, %state.odd
  %choose = select i1 %state.mode, i1 %state.choose, i1 %nonzero.x
  br i1 %nonzero.x, label %gate0, label %right
gate0:
  %skip = icmp eq i32 %x, 2
  br i1 %skip, label %right1, label %gate1
gate1:
  br i1 %choose, label %left, label %right2
left:
  %raw = xor i32 %prev, %state.next
  %c = call i32 @scalar_helper(i32 %raw)
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %as.double = uitofp i32 %prev to double
  %dc = fsub double %dx, %as.double
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  br label %latch
right:
  br label %latch
right1:
  br label %latch
right2:
  br label %latch
latch:
  %m0 = phi i32 [%r0, %right2], [%r0, %right1], [%r0, %right], [%u0, %left]
  %m1 = phi i32 [%r1, %right2], [%r1, %right1], [%r1, %right], [%u1, %left]
  %md = phi double [%rd, %right2], [%rd, %right1], [%rd, %right], [%ud, %left]
  %last.dc = phi double [%start, %right2], [%start, %right1], [%start, %right], [%dc, %left]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %producer.exit, label %loop, !dbg !13
producer.exit:
  %out.r0 = phi i32 [%m0, %latch]
  %out.r1 = phi i32 [%m1, %latch]
  %out.prev = phi i32 [%prev, %latch]
  %out.older = phi i32 [%older, %latch]
  %out.state.next = phi i32 [%state.next, %latch]
  %out.rd = phi double [%md, %latch]
  %out.last.dc = phi double [%last.dc, %latch]
  %out.iv = phi i64 [%iv, %latch]
  %out.next = phi i64 [%next, %latch]
  %out.p0 = getelementptr i32, ptr %out, i64 0
  store i32 %out.r0, ptr %out.p0, align 4
  %out.p1 = getelementptr i32, ptr %out, i64 1
  store i32 %out.r1, ptr %out.p1, align 4
  %out.p2 = getelementptr i32, ptr %out, i64 2
  store i32 %out.prev, ptr %out.p2, align 4
  %out.p3 = getelementptr i32, ptr %out, i64 3
  store i32 %out.older, ptr %out.p3, align 4
  %out.p4 = getelementptr i32, ptr %out, i64 4
  store i32 %out.state.next, ptr %out.p4, align 4
  %dout.p0 = getelementptr double, ptr %dout, i64 0
  store double %out.rd, ptr %dout.p0, align 8
  %dout.p1 = getelementptr double, ptr %dout, i64 1
  store double %out.last.dc, ptr %dout.p1, align 8
  %indices.p0 = getelementptr i64, ptr %indices, i64 0
  store i64 %out.iv, ptr %indices.p0, align 8
  %indices.p1 = getelementptr i64, ptr %indices, i64 1
  store i64 %out.next, ptr %indices.p1, align 8
  ret void
bypass:
  ret void
}

define void @compact_chunk_narrow(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                      ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !14 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  %n8 = trunc i64 %n to i8
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !15
loop:
  %iv = phi i8 [0, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %older = phi i32 [-11, %preheader], [%prev, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %wide = zext i8 %iv to i64
  %p = getelementptr i32, ptr %a, i64 %wide
  %x = load i32, ptr %p, align 4
  %state.next = add i32 %x, %older
  %nonzero.x = icmp ne i32 %x, 0
  %state.bit = and i32 %prev, 1
  %state.odd = icmp ne i32 %state.bit, 0
  %state.mode = icmp eq i64 %rows, 2
  %state.choose = and i1 %nonzero.x, %state.odd
  %choose = select i1 %state.mode, i1 %state.choose, i1 %nonzero.x
  br i1 %choose, label %left, label %right
left:
  %raw = xor i32 %prev, %state.next
  %c = call i32 @scalar_helper(i32 %raw)
  %dp = getelementptr double, ptr %fp, i64 %wide
  %dx = load double, ptr %dp, align 8
  %as.double = uitofp i32 %prev to double
  %dc = fsub double %dx, %as.double
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  br label %latch
right:
  br label %latch
latch:
  %m0 = phi i32 [%r0, %right], [%u0, %left]
  %m1 = phi i32 [%r1, %right], [%u1, %left]
  %md = phi double [%rd, %right], [%ud, %left]
  %last.dc = phi double [%start, %right], [%dc, %left]
  %next = add nuw i8 %iv, 1
  %done = icmp eq i8 %next, %n8
  br i1 %done, label %producer.exit, label %loop, !dbg !15
producer.exit:
  %out.r0 = phi i32 [%m0, %latch]
  %out.r1 = phi i32 [%m1, %latch]
  %out.prev = phi i32 [%prev, %latch]
  %out.older = phi i32 [%older, %latch]
  %out.state.next = phi i32 [%state.next, %latch]
  %out.rd = phi double [%md, %latch]
  %out.last.dc = phi double [%last.dc, %latch]
  %out.iv = phi i8 [%iv, %latch]
  %out.next = phi i8 [%next, %latch]
  %out.p0 = getelementptr i32, ptr %out, i64 0
  store i32 %out.r0, ptr %out.p0, align 4
  %out.p1 = getelementptr i32, ptr %out, i64 1
  store i32 %out.r1, ptr %out.p1, align 4
  %out.p2 = getelementptr i32, ptr %out, i64 2
  store i32 %out.prev, ptr %out.p2, align 4
  %out.p3 = getelementptr i32, ptr %out, i64 3
  store i32 %out.older, ptr %out.p3, align 4
  %out.p4 = getelementptr i32, ptr %out, i64 4
  store i32 %out.state.next, ptr %out.p4, align 4
  %dout.p0 = getelementptr double, ptr %dout, i64 0
  store double %out.rd, ptr %dout.p0, align 8
  %dout.p1 = getelementptr double, ptr %dout, i64 1
  store double %out.last.dc, ptr %dout.p1, align 8
  %indices.p0 = getelementptr i64, ptr %indices, i64 0
  %iv.wide = zext i8 %out.iv to i64
  store i64 %iv.wide, ptr %indices.p0, align 8
  %indices.p1 = getelementptr i64, ptr %indices, i64 1
  %next.wide = zext i8 %out.next to i64
  store i64 %next.wide, ptr %indices.p1, align 8
  ret void
bypass:
  ret void
}

define void @compact_chunk_rows(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                      ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !16 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  %rows.valid = icmp ule i64 %rows, 4
  %rows.nonzero = icmp ne i64 %rows, 0
  %rows.enter = and i1 %rows.valid, %rows.nonzero
  %enter = and i1 %inner.enter, %rows.enter
  br i1 %enter, label %outer.ph, label %bypass
outer.ph:
  br label %outer
outer:
  %row = phi i64 [0, %outer.ph], [%row.next, %row.exit]
  %carry0 = phi i32 [17, %outer.ph], [%out.r0, %row.exit]
  %carry1 = phi i32 [-7, %outer.ph], [%out.r1, %row.exit]
  %carryd = phi double [%start, %outer.ph], [%out.rd, %row.exit]
  %seed = phi i32 [23, %outer.ph], [%out.state.next, %row.exit]
  %oldseed = phi i32 [-11, %outer.ph], [%out.prev, %row.exit]
  %offset = mul i64 %row, 65
  br label %inner.ph
inner.ph:
  br label %loop, !dbg !17
loop:
  %iv = phi i64 [0, %inner.ph], [%next, %latch]
  %prev = phi i32 [%seed, %inner.ph], [%state.next, %latch]
  %r0 = phi i32 [%carry0, %inner.ph], [%m0, %latch]
  %older = phi i32 [%oldseed, %inner.ph], [%prev, %latch]
  %r1 = phi i32 [%carry1, %inner.ph], [%m1, %latch]
  %rd = phi double [%carryd, %inner.ph], [%md, %latch]
  %input.index = add i64 %offset, %iv
  %p = getelementptr i32, ptr %a, i64 %input.index
  %x = load i32, ptr %p, align 4
  %state.next = add i32 %x, %older
  %nonzero.x = icmp ne i32 %x, 0
  %state.bit = and i32 %prev, 1
  %state.odd = icmp ne i32 %state.bit, 0
  %state.mode = icmp eq i64 %rows, 2
  %state.choose = and i1 %nonzero.x, %state.odd
  %choose = select i1 %state.mode, i1 %state.choose, i1 %nonzero.x
  br i1 %nonzero.x, label %gate0, label %right
gate0:
  %skip = icmp eq i32 %x, 2
  br i1 %skip, label %right1, label %gate1
gate1:
  br i1 %choose, label %left, label %right2
left:
  %raw = xor i32 %prev, %state.next
  %c = call i32 @scalar_helper(i32 %raw)
  %dp = getelementptr double, ptr %fp, i64 %input.index
  %dx = load double, ptr %dp, align 8
  %as.double = uitofp i32 %prev to double
  %dc = fsub double %dx, %as.double
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  br label %latch
right:
  br label %latch
right1:
  br label %latch
right2:
  br label %latch
latch:
  %m0 = phi i32 [%r0, %right2], [%r0, %right1], [%r0, %right], [%u0, %left]
  %m1 = phi i32 [%r1, %right2], [%r1, %right1], [%r1, %right], [%u1, %left]
  %md = phi double [%rd, %right2], [%rd, %right1], [%rd, %right], [%ud, %left]
  %last.dc = phi double [%start, %right2], [%start, %right1], [%start, %right], [%dc, %left]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %row.exit, label %loop, !dbg !17
row.exit:
  %out.r0 = phi i32 [%m0, %latch]
  %out.r1 = phi i32 [%m1, %latch]
  %out.prev = phi i32 [%prev, %latch]
  %out.older = phi i32 [%older, %latch]
  %out.state.next = phi i32 [%state.next, %latch]
  %out.rd = phi double [%md, %latch]
  %out.last.dc = phi double [%last.dc, %latch]
  %out.iv = phi i64 [%iv, %latch]
  %out.next = phi i64 [%next, %latch]
  %out.base0 = mul i64 %row, 5
  %out.index0 = add i64 %out.base0, 0
  %out.p0 = getelementptr i32, ptr %out, i64 %out.index0
  store i32 %out.r0, ptr %out.p0, align 4
  %out.base1 = mul i64 %row, 5
  %out.index1 = add i64 %out.base1, 1
  %out.p1 = getelementptr i32, ptr %out, i64 %out.index1
  store i32 %out.r1, ptr %out.p1, align 4
  %out.base2 = mul i64 %row, 5
  %out.index2 = add i64 %out.base2, 2
  %out.p2 = getelementptr i32, ptr %out, i64 %out.index2
  store i32 %out.prev, ptr %out.p2, align 4
  %out.base3 = mul i64 %row, 5
  %out.index3 = add i64 %out.base3, 3
  %out.p3 = getelementptr i32, ptr %out, i64 %out.index3
  store i32 %out.older, ptr %out.p3, align 4
  %out.base4 = mul i64 %row, 5
  %out.index4 = add i64 %out.base4, 4
  %out.p4 = getelementptr i32, ptr %out, i64 %out.index4
  store i32 %out.state.next, ptr %out.p4, align 4
  %dout.base0 = mul i64 %row, 2
  %dout.index0 = add i64 %dout.base0, 0
  %dout.p0 = getelementptr double, ptr %dout, i64 %dout.index0
  store double %out.rd, ptr %dout.p0, align 8
  %dout.base1 = mul i64 %row, 2
  %dout.index1 = add i64 %dout.base1, 1
  %dout.p1 = getelementptr double, ptr %dout, i64 %dout.index1
  store double %out.last.dc, ptr %dout.p1, align 8
  %indices.base0 = mul i64 %row, 2
  %indices.index0 = add i64 %indices.base0, 0
  %indices.p0 = getelementptr i64, ptr %indices, i64 %indices.index0
  store i64 %out.iv, ptr %indices.p0, align 8
  %indices.base1 = mul i64 %row, 2
  %indices.index1 = add i64 %indices.base1, 1
  %indices.p1 = getelementptr i64, ptr %indices, i64 %indices.index1
  store i64 %out.next, ptr %indices.p1, align 8
  %row.next = add nuw i64 %row, 1
  %row.done = icmp eq i64 %row.next, %rows
  br i1 %row.done, label %exit, label %outer
exit:
  ret void
bypass:
  ret void
}
!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!3, !4}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "reduction fission", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-compact-chunks.c", directory: "/")
!2 = !DISubroutineType(types: !5)
!3 = !{i32 2, !"Dwarf Version", i32 4}
!4 = !{i32 2, !"Debug Info Version", i32 3}
!5 = !{}
!10 = distinct !DISubprogram(name: "compact_chunk_diamond", scope: !1, file: !1, line: 11, type: !2, scopeLine: 11, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 12, column: 3, scope: !10)
!12 = distinct !DISubprogram(name: "compact_chunk_cfg", scope: !1, file: !1, line: 21, type: !2, scopeLine: 21, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 22, column: 3, scope: !12)
!14 = distinct !DISubprogram(name: "compact_chunk_narrow", scope: !1, file: !1, line: 31, type: !2, scopeLine: 31, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!15 = !DILocation(line: 32, column: 3, scope: !14)
!16 = distinct !DISubprogram(name: "compact_chunk_rows", scope: !1, file: !1, line: 41, type: !2, scopeLine: 41, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!17 = !DILocation(line: 42, column: 3, scope: !16)
