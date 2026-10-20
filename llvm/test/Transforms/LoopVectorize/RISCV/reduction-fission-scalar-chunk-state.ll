; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @chunk_state_delay(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @chunk_state_pair(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @chunk_state_fp(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @chunk_state_nested(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Dependent contribution arithmetic preserves positive feature coverage under
; the final producer depth policy. Checks exercise scalar fission and ordinary LV.
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

define void @chunk_state_delay(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                         ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !10 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !11
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %prev = phi i32 [23, %preheader], [%x, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %dstate = phi double [%start, %preheader], [%dnext, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %raw = xor i32 %prev, %x
  %c.depth.mul = mul i32 %raw, 13
  %c.depth.bias = add i32 %c.depth.mul, 7
  %c = call i32 @scalar_helper(i32 %c.depth.bias)
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %dnext = fadd double %dstate, %dx
  %dc = fsub double %dnext, %dstate
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %producer.exit, label %loop, !dbg !11
producer.exit:
  %out.r0 = phi i32 [%u0, %loop]
  %out.r1 = phi i32 [%u1, %loop]
  %out.prev = phi i32 [%prev, %loop]
  %out.state.next = phi i32 [%x, %loop]
  %out.rd = phi double [%ud, %loop]
  %out.dstate = phi double [%dstate, %loop]
  %out.dnext = phi double [%dnext, %loop]
  %out.dc = phi double [%dc, %loop]
  %out.iv = phi i64 [%iv, %loop]
  %out.next = phi i64 [%next, %loop]
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %out.r0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %out.r1, ptr %o1, align 4
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %out.prev, ptr %o2, align 4
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 -11, ptr %o3, align 4
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %out.state.next, ptr %o4, align 4
  %d0 = getelementptr double, ptr %dout, i64 0
  store double %out.rd, ptr %d0, align 8
  %d1 = getelementptr double, ptr %dout, i64 1
  store double %out.dstate, ptr %d1, align 8
  %d2 = getelementptr double, ptr %dout, i64 2
  store double %out.dnext, ptr %d2, align 8
  %d3 = getelementptr double, ptr %dout, i64 3
  store double %out.dc, ptr %d3, align 8
  %idx0 = getelementptr i64, ptr %indices, i64 0
  store i64 %out.iv, ptr %idx0, align 8
  %idx1 = getelementptr i64, ptr %indices, i64 1
  store i64 %out.next, ptr %idx1, align 8
  ret void
bypass:
  ret void
}

define void @chunk_state_pair(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                         ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !12 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !13
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %prev = phi i32 [23, %preheader], [%state.next, %loop]
  %older = phi i32 [-11, %preheader], [%prev, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %dstate = phi double [%start, %preheader], [%dnext, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %state.next = add i32 %x, %older
  %raw = xor i32 %prev, %state.next
  %c = call i32 @scalar_helper(i32 %raw)
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %dnext = fadd double %dstate, %dx
  %dc = fsub double %dnext, %dstate
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %producer.exit, label %loop, !dbg !13
producer.exit:
  %out.r0 = phi i32 [%u0, %loop]
  %out.r1 = phi i32 [%u1, %loop]
  %out.prev = phi i32 [%prev, %loop]
  %out.older = phi i32 [%older, %loop]
  %out.state.next = phi i32 [%state.next, %loop]
  %out.rd = phi double [%ud, %loop]
  %out.dstate = phi double [%dstate, %loop]
  %out.dnext = phi double [%dnext, %loop]
  %out.dc = phi double [%dc, %loop]
  %out.iv = phi i64 [%iv, %loop]
  %out.next = phi i64 [%next, %loop]
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %out.r0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %out.r1, ptr %o1, align 4
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %out.prev, ptr %o2, align 4
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %out.older, ptr %o3, align 4
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %out.state.next, ptr %o4, align 4
  %d0 = getelementptr double, ptr %dout, i64 0
  store double %out.rd, ptr %d0, align 8
  %d1 = getelementptr double, ptr %dout, i64 1
  store double %out.dstate, ptr %d1, align 8
  %d2 = getelementptr double, ptr %dout, i64 2
  store double %out.dnext, ptr %d2, align 8
  %d3 = getelementptr double, ptr %dout, i64 3
  store double %out.dc, ptr %d3, align 8
  %idx0 = getelementptr i64, ptr %indices, i64 0
  store i64 %out.iv, ptr %idx0, align 8
  %idx1 = getelementptr i64, ptr %indices, i64 1
  store i64 %out.next, ptr %idx1, align 8
  ret void
bypass:
  ret void
}

define void @chunk_state_fp(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                         ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !14 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !15
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %prev = phi i32 [23, %preheader], [%x, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %dstate = phi double [%start, %preheader], [%dnext, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %raw = xor i32 %prev, %x
  %c.depth.mul = mul i32 %raw, 13
  %c.depth.bias = add i32 %c.depth.mul, 7
  %c = call i32 @scalar_helper(i32 %c.depth.bias)
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %dnext = fadd double %dstate, %dx
  %dc = fsub double %dstate, %dx
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %producer.exit, label %loop, !dbg !15
producer.exit:
  %out.r0 = phi i32 [%u0, %loop]
  %out.r1 = phi i32 [%u1, %loop]
  %out.prev = phi i32 [%prev, %loop]
  %out.state.next = phi i32 [%x, %loop]
  %out.rd = phi double [%ud, %loop]
  %out.dstate = phi double [%dstate, %loop]
  %out.dnext = phi double [%dnext, %loop]
  %out.dc = phi double [%dc, %loop]
  %out.iv = phi i64 [%iv, %loop]
  %out.next = phi i64 [%next, %loop]
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %out.r0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %out.r1, ptr %o1, align 4
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %out.prev, ptr %o2, align 4
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 -11, ptr %o3, align 4
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %out.state.next, ptr %o4, align 4
  %d0 = getelementptr double, ptr %dout, i64 0
  store double %out.rd, ptr %d0, align 8
  %d1 = getelementptr double, ptr %dout, i64 1
  store double %out.dstate, ptr %d1, align 8
  %d2 = getelementptr double, ptr %dout, i64 2
  store double %out.dnext, ptr %d2, align 8
  %d3 = getelementptr double, ptr %dout, i64 3
  store double %out.dc, ptr %d3, align 8
  %idx0 = getelementptr i64, ptr %indices, i64 0
  store i64 %out.iv, ptr %idx0, align 8
  %idx1 = getelementptr i64, ptr %indices, i64 1
  store i64 %out.next, ptr %idx1, align 8
  ret void
bypass:
  ret void
}

define void @chunk_state_nested(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
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
  %dseed = phi double [%start, %outer.ph], [%out.dnext, %row.exit]
  %input.base = mul nuw i64 %row, 65
  %output.base = mul nuw i64 %row, 5
  %double.base = mul nuw i64 %row, 4
  %index.base = mul nuw i64 %row, 2
  br label %inner.ph
inner.ph:
  br label %loop, !dbg !17
loop:
  %iv = phi i64 [0, %inner.ph], [%next, %loop]
  %prev = phi i32 [%seed, %inner.ph], [%state.next, %loop]
  %older = phi i32 [%oldseed, %inner.ph], [%prev, %loop]
  %r0 = phi i32 [%carry0, %inner.ph], [%u0, %loop]
  %dstate = phi double [%dseed, %inner.ph], [%dnext, %loop]
  %r1 = phi i32 [%carry1, %inner.ph], [%u1, %loop]
  %rd = phi double [%carryd, %inner.ph], [%ud, %loop]
  %offset = add nuw i64 %input.base, %iv
  %p = getelementptr i32, ptr %a, i64 %offset
  %x = load i32, ptr %p, align 4
  %state.next = add i32 %x, %older
  %raw = xor i32 %prev, %state.next
  %c = call i32 @scalar_helper(i32 %raw)
  %dp = getelementptr double, ptr %fp, i64 %offset
  %dx = load double, ptr %dp, align 8
  %dnext = fadd double %dstate, %dx
  %dc = fsub double %dnext, %dstate
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %row.exit, label %loop, !dbg !17
row.exit:
  %out.r0 = phi i32 [%u0, %loop]
  %out.r1 = phi i32 [%u1, %loop]
  %out.prev = phi i32 [%prev, %loop]
  %out.older = phi i32 [%older, %loop]
  %out.state.next = phi i32 [%state.next, %loop]
  %out.rd = phi double [%ud, %loop]
  %out.dstate = phi double [%dstate, %loop]
  %out.dnext = phi double [%dnext, %loop]
  %out.dc = phi double [%dc, %loop]
  %out.iv = phi i64 [%iv, %loop]
  %out.next = phi i64 [%next, %loop]
  %oi0 = add nuw i64 %output.base, 0
  %o0 = getelementptr i32, ptr %out, i64 %oi0
  store i32 %out.r0, ptr %o0, align 4
  %oi1 = add nuw i64 %output.base, 1
  %o1 = getelementptr i32, ptr %out, i64 %oi1
  store i32 %out.r1, ptr %o1, align 4
  %oi2 = add nuw i64 %output.base, 2
  %o2 = getelementptr i32, ptr %out, i64 %oi2
  store i32 %out.prev, ptr %o2, align 4
  %oi3 = add nuw i64 %output.base, 3
  %o3 = getelementptr i32, ptr %out, i64 %oi3
  store i32 %out.older, ptr %o3, align 4
  %oi4 = add nuw i64 %output.base, 4
  %o4 = getelementptr i32, ptr %out, i64 %oi4
  store i32 %out.state.next, ptr %o4, align 4
  %di0 = add nuw i64 %double.base, 0
  %d0 = getelementptr double, ptr %dout, i64 %di0
  store double %out.rd, ptr %d0, align 8
  %di1 = add nuw i64 %double.base, 1
  %d1 = getelementptr double, ptr %dout, i64 %di1
  store double %out.dstate, ptr %d1, align 8
  %di2 = add nuw i64 %double.base, 2
  %d2 = getelementptr double, ptr %dout, i64 %di2
  store double %out.dnext, ptr %d2, align 8
  %di3 = add nuw i64 %double.base, 3
  %d3 = getelementptr double, ptr %dout, i64 %di3
  store double %out.dc, ptr %d3, align 8
  %ii0 = add nuw i64 %index.base, 0
  %idx0 = getelementptr i64, ptr %indices, i64 %ii0
  store i64 %out.iv, ptr %idx0, align 8
  %ii1 = add nuw i64 %index.base, 1
  %idx1 = getelementptr i64, ptr %indices, i64 %ii1
  store i64 %out.next, ptr %idx1, align 8
  %row.next = add nuw i64 %row, 1
  %row.done = icmp eq i64 %row.next, %rows
  br i1 %row.done, label %exit, label %outer
exit:
  ret void
bypass:
  ret void
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-chunk-state.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!5 = !DISubroutineType(types: !6)
!6 = !{}
!10 = distinct !DISubprogram(name: "chunk_state_delay", scope: !1, file: !1, line: 10, type: !5, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 12, column: 3, scope: !10)
!12 = distinct !DISubprogram(name: "chunk_state_pair", scope: !1, file: !1, line: 20, type: !5, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 22, column: 3, scope: !12)
!14 = distinct !DISubprogram(name: "chunk_state_fp", scope: !1, file: !1, line: 30, type: !5, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!15 = !DILocation(line: 32, column: 3, scope: !14)
!16 = distinct !DISubprogram(name: "chunk_state_nested", scope: !1, file: !1, line: 40, type: !5, scopeLine: 40, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!17 = !DILocation(line: 42, column: 3, scope: !16)
