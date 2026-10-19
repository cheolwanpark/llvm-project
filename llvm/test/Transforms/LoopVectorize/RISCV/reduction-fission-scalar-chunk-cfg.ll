; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @chunk_cfg_diamond(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @chunk_cfg_serial(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @chunk_cfg_nested(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @chunk_cfg_header(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

define void @chunk_cfg_diamond(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
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
  %older = phi i32 [-11, %preheader], [%prev, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %dstate = phi double [%start, %preheader], [%dnext, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %state.next = add i32 %x, %older
  %nonzero.x = icmp ne i32 %x, 0
  %state.bit = and i32 %prev, 1
  %state.odd = icmp ne i32 %state.bit, 0
  %choose = and i1 %nonzero.x, %state.odd
  br i1 %choose, label %left, label %right
left:
  %q = sdiv i32 840, %x
  %ld = sitofp i32 %q to double
  br label %latch
right:
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  br label %latch
latch:
  %branch.c = phi i32 [%q, %left], [%x, %right]
  %delta = phi double [%ld, %left], [%dx, %right]
  %raw = xor i32 %prev, %state.next
  %arg = xor i32 %raw, %branch.c
  %c = call i32 @scalar_helper(i32 %arg)
  %dnext = fadd double %dstate, %delta
  %dc = fsub double %dnext, %dstate
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %producer.exit, label %loop, !dbg !11
producer.exit:
  %out.r0 = phi i32 [%u0, %latch]
  %out.r1 = phi i32 [%u1, %latch]
  %out.prev = phi i32 [%prev, %latch]
  %out.older = phi i32 [%older, %latch]
  %out.state.next = phi i32 [%state.next, %latch]
  %out.rd = phi double [%ud, %latch]
  %out.dstate = phi double [%dstate, %latch]
  %out.dnext = phi double [%dnext, %latch]
  %out.dc = phi double [%dc, %latch]
  %out.iv = phi i64 [%iv, %latch]
  %out.next = phi i64 [%next, %latch]
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

define void @chunk_cfg_serial(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
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
  %older = phi i32 [-11, %preheader], [%prev, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %dstate = phi double [%start, %preheader], [%dnext, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %state.next = add i32 %x, %older
  %nonzero.x = icmp ne i32 %x, 0
  %state.bit = and i32 %prev, 1
  %state.odd = icmp ne i32 %state.bit, 0
  %choose = and i1 %nonzero.x, %state.odd
  br i1 %choose, label %left, label %right
left:
  %q = sdiv i32 840, %x
  %ld = sitofp i32 %q to double
  br label %first.merge
right:
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  br label %first.merge
first.merge:
  %first.c = phi i32 [%q, %left], [%x, %right]
  %first.d = phi double [%ld, %left], [%dx, %right]
  %old.bit = and i32 %older, 1
  %second = icmp ne i32 %old.bit, 0
  br i1 %second, label %positive, label %negative
positive:
  %pc = add i32 %first.c, 23
  %pd = fmul double %first.d, 5.000000e-01
  br label %latch
negative:
  %nc = sub i32 %first.c, 9
  %nd = fmul double %first.d, -1.000000e+00
  br label %latch
latch:
  %branch.c = phi i32 [%pc, %positive], [%nc, %negative]
  %delta = phi double [%pd, %positive], [%nd, %negative]
  %raw = xor i32 %prev, %state.next
  %arg = xor i32 %raw, %branch.c
  %c = call i32 @scalar_helper(i32 %arg)
  %dnext = fadd double %dstate, %delta
  %dc = fsub double %dnext, %dstate
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %producer.exit, label %loop, !dbg !13
producer.exit:
  %out.r0 = phi i32 [%u0, %latch]
  %out.r1 = phi i32 [%u1, %latch]
  %out.prev = phi i32 [%prev, %latch]
  %out.older = phi i32 [%older, %latch]
  %out.state.next = phi i32 [%state.next, %latch]
  %out.rd = phi double [%ud, %latch]
  %out.dstate = phi double [%dstate, %latch]
  %out.dnext = phi double [%dnext, %latch]
  %out.dc = phi double [%dc, %latch]
  %out.iv = phi i64 [%iv, %latch]
  %out.next = phi i64 [%next, %latch]
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

define void @chunk_cfg_nested(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                         ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !14 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !15
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %older = phi i32 [-11, %preheader], [%prev, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %dstate = phi double [%start, %preheader], [%dnext, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %state.next = add i32 %x, %older
  %nonzero.x = icmp ne i32 %x, 0
  %state.bit = and i32 %prev, 1
  %state.odd = icmp ne i32 %state.bit, 0
  %choose = and i1 %nonzero.x, %state.odd
  br i1 %choose, label %left, label %right
left:
  %q = sdiv i32 840, %x
  %ld = sitofp i32 %q to double
  %old.bit = and i32 %older, 1
  %second = icmp ne i32 %old.bit, 0
  br i1 %second, label %positive, label %negative
positive:
  %pc = add i32 %q, 23
  %pd = fmul double %ld, 5.000000e-01
  br label %latch
negative:
  %nc = sub i32 %q, 9
  %nd = fmul double %ld, -1.000000e+00
  br label %latch
right:
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  br label %latch
latch:
  %branch.c = phi i32 [%pc, %positive], [%nc, %negative], [%x, %right]
  %delta = phi double [%pd, %positive], [%nd, %negative], [%dx, %right]
  %raw = xor i32 %prev, %state.next
  %arg = xor i32 %raw, %branch.c
  %c = call i32 @scalar_helper(i32 %arg)
  %dnext = fadd double %dstate, %delta
  %dc = fsub double %dnext, %dstate
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %producer.exit, label %loop, !dbg !15
producer.exit:
  %out.r0 = phi i32 [%u0, %latch]
  %out.r1 = phi i32 [%u1, %latch]
  %out.prev = phi i32 [%prev, %latch]
  %out.older = phi i32 [%older, %latch]
  %out.state.next = phi i32 [%state.next, %latch]
  %out.rd = phi double [%ud, %latch]
  %out.dstate = phi double [%dstate, %latch]
  %out.dnext = phi double [%dnext, %latch]
  %out.dc = phi double [%dc, %latch]
  %out.iv = phi i64 [%iv, %latch]
  %out.next = phi i64 [%next, %latch]
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

define void @chunk_cfg_header(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                         ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !16 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !17
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %older = phi i32 [-11, %preheader], [%prev, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %dstate = phi double [%start, %preheader], [%dnext, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %state.next = add i32 %x, %older
  %raw = xor i32 %prev, %state.next
  %c = call i32 @scalar_helper(i32 %raw)
  %as.double = sitofp i32 %x to double
  %dc = fsub double %dstate, %as.double
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %nonzero.x = icmp ne i32 %x, 0
  %state.bit = and i32 %prev, 1
  %state.odd = icmp ne i32 %state.bit, 0
  %choose = and i1 %nonzero.x, %state.odd
  br i1 %choose, label %left, label %right
left:
  %q = sdiv i32 840, %x
  %ld = sitofp i32 %q to double
  br label %latch
right:
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  br label %latch
latch:
  %delta = phi double [%ld, %left], [%dx, %right]
  %dnext = fadd double %dstate, %delta
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %producer.exit, label %loop, !dbg !17
producer.exit:
  %out.r0 = phi i32 [%u0, %latch]
  %out.r1 = phi i32 [%u1, %latch]
  %out.prev = phi i32 [%prev, %latch]
  %out.older = phi i32 [%older, %latch]
  %out.state.next = phi i32 [%state.next, %latch]
  %out.rd = phi double [%ud, %latch]
  %out.dstate = phi double [%dstate, %latch]
  %out.dnext = phi double [%dnext, %latch]
  %out.dc = phi double [%dc, %latch]
  %out.iv = phi i64 [%iv, %latch]
  %out.next = phi i64 [%next, %latch]
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

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-chunk-cfg.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!5 = !DISubroutineType(types: !6)
!6 = !{}
!10 = distinct !DISubprogram(name: "chunk_cfg_diamond", scope: !1, file: !1, line: 10, type: !5, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 12, column: 3, scope: !10)
!12 = distinct !DISubprogram(name: "chunk_cfg_serial", scope: !1, file: !1, line: 20, type: !5, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 22, column: 3, scope: !12)
!14 = distinct !DISubprogram(name: "chunk_cfg_nested", scope: !1, file: !1, line: 30, type: !5, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!15 = !DILocation(line: 32, column: 3, scope: !14)
!16 = distinct !DISubprogram(name: "chunk_cfg_header", scope: !1, file: !1, line: 40, type: !5, scopeLine: 40, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!17 = !DILocation(line: 42, column: 3, scope: !16)
