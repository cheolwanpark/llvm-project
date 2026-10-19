; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @state_cfg_serial(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @state_cfg_nested(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @state_cfg_affine(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

define void @state_cfg_serial(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                            ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !10 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %inner.enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !11
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %state = phi i32 [23, %preheader], [%state.merge, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %rf = phi float [%fstart, %preheader], [%mf, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %nonzero.x = icmp ne i32 %x, 0
  %state.bit = and i32 %state, 1
  %state.odd = icmp ne i32 %state.bit, 0
  %state.choose = and i1 %nonzero.x, %state.odd
  %state.mode = icmp eq i64 %rows, 2
  %choose = select i1 %state.mode, i1 %state.choose, i1 %nonzero.x
  %parity = and i64 %iv, 1
  %odd = icmp ne i64 %parity, 0
  br i1 %odd, label %odd.arm, label %even.arm
odd.arm:
  %odd.bias = add i32 %x, 23
  br label %first.merge
even.arm:
  %even.bias = sub i32 %x, 9
  br label %first.merge
first.merge:
  %bias = phi i32 [%odd.bias, %odd.arm], [%even.bias, %even.arm]
  %large = icmp ugt i32 %x, 5
  br i1 %large, label %large.arm, label %small.arm
large.arm:
  %large.bias = add i32 %bias, 5
  br label %second.merge
small.arm:
  %small.bias = xor i32 %bias, 3
  br label %second.merge
second.merge:
  %extra = phi i32 [%small.bias, %small.arm], [%large.bias, %large.arm]
  br i1 %choose, label %left, label %right
left:
  %q = sdiv i32 840, %x
  %arg = xor i32 %q, %extra
  %state.arg = xor i32 %arg, %state
  %lc = call i32 @scalar_helper(i32 %state.arg)
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %ld = fmul double %dx, 3.0
  %lf = fptrunc double %ld to float
  %u0 = add i32 %r0, %lc
  %u1 = add i32 %lc, %r1
  %ud = fadd double %rd, %ld
  %uf = fadd float %rf, %lf
  br label %latch
right:
  %state.delta = add i32 %x, 1
  %state.next = add i32 %state, %state.delta
  %rc = xor i32 %x, 7
  br label %latch
latch:
  %state.merge = phi i32 [%state, %left], [%state.next, %right]
  %c = phi i32 [%lc, %left], [%rc, %right]
  %dc = phi double [%ld, %left], [-0.0, %right]
  %fc = phi float [%lf, %left], [-0.0, %right]
  %m0 = phi i32 [%u0, %left], [%r0, %right]
  %m1 = phi i32 [%u1, %left], [%r1, %right]
  %md = phi double [%ud, %left], [%rd, %right]
  %mf = phi float [%uf, %left], [%rf, %right]
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %producer.exit, label %loop, !dbg !11
producer.exit:
  %out.x = phi i32 [%x, %latch]
  %out.c = phi i32 [%c, %latch]
  %out.c.copy = phi i32 [%state.merge, %latch]
  %out.iv = phi i64 [%iv, %latch]
  %out.next = phi i64 [%next, %latch]
  %out.dc = phi double [%dc, %latch]
  %out.fc = phi float [%fc, %latch]
  %out.r0 = phi i32 [%m0, %latch]
  %out.r1 = phi i32 [%m1, %latch]
  %out.rd = phi double [%md, %latch]
  %out.rf = phi float [%mf, %latch]
  br label %exit
exit:
  %final.x = phi i32 [-99, %entry], [%out.x, %producer.exit]
  %final.c = phi i32 [-101, %entry], [%out.c, %producer.exit]
  %final.c.copy = phi i32 [23, %entry], [%out.c.copy, %producer.exit]
  %final.iv = phi i64 [-1, %entry], [%out.iv, %producer.exit]
  %final.next = phi i64 [0, %entry], [%out.next, %producer.exit]
  %final.dc = phi double [-0.0, %entry], [%out.dc, %producer.exit]
  %final.fc = phi float [-0.0, %entry], [%out.fc, %producer.exit]
  %final.r0 = phi i32 [17, %entry], [%out.r0, %producer.exit]
  %final.r1 = phi i32 [-7, %entry], [%out.r1, %producer.exit]
  %final.rd = phi double [%start, %entry], [%out.rd, %producer.exit]
  %final.rf = phi float [%fstart, %entry], [%out.rf, %producer.exit]
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %final.r0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %final.r1, ptr %o1, align 4
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %final.x, ptr %o2, align 4
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %final.c, ptr %o3, align 4
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %final.c.copy, ptr %o4, align 4
  %indices0 = getelementptr i64, ptr %indices, i64 0
  store i64 %final.iv, ptr %indices0, align 8
  %indices1 = getelementptr i64, ptr %indices, i64 1
  store i64 %final.next, ptr %indices1, align 8
  %dout0 = getelementptr double, ptr %dout, i64 0
  store double %final.rd, ptr %dout0, align 8
  %dout1 = getelementptr double, ptr %dout, i64 1
  store double %final.dc, ptr %dout1, align 8
  %fout0 = getelementptr float, ptr %fout, i64 0
  store float %final.rf, ptr %fout0, align 4
  %fout1 = getelementptr float, ptr %fout, i64 1
  store float %final.fc, ptr %fout1, align 4
  ret void
}

define void @state_cfg_nested(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                            ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !12 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %inner.enter, label %preheader, label %exit
preheader:
  %span = shl nuw nsw i64 %n, 1
  %limit = add nuw nsw i64 %span, 7
  br label %loop, !dbg !13
loop:
  %iv = phi i64 [7, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %rf = phi float [%fstart, %preheader], [%mf, %latch]
  %state = phi i32 [23, %preheader], [%state.merge, %latch]
  %distance = sub nuw nsw i64 %iv, 7
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %nonzero.x = icmp ne i32 %x, 0
  %state.bit = and i32 %state, 1
  %state.odd = icmp ne i32 %state.bit, 0
  %state.choose = and i1 %nonzero.x, %state.odd
  %state.mode = icmp eq i64 %rows, 2
  %choose = select i1 %state.mode, i1 %state.choose, i1 %nonzero.x
  br i1 %choose, label %active.entry, label %right
active.entry:
  %q = sdiv i32 840, %x
  %large = icmp ugt i32 %x, 5
  br i1 %large, label %high, label %low
high:
  %parity = and i64 %index, 1
  %even = icmp eq i64 %parity, 0
  br i1 %even, label %even.arm, label %odd.arm
even.arm:
  %even.arg = add i32 %q, 5
  br label %active.merge
odd.arm:
  %odd.arg = add i32 %q, 23
  br label %active.merge
low:
  %low.arg = xor i32 %q, -1
  br label %active.merge
active.merge:
  %arg = phi i32 [%low.arg, %low], [%odd.arg, %odd.arm], [%even.arg, %even.arm]
  br label %left
left:
  %state.arg = xor i32 %arg, %state
  %lc = call i32 @scalar_helper(i32 %state.arg)
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %ld = fmul double %dx, 3.0
  %lf = fptrunc double %ld to float
  %u0 = add i32 %r0, %lc
  %u1 = add i32 %lc, %r1
  %ud = fadd double %rd, %ld
  %uf = fadd float %rf, %lf
  br label %latch
right:
  %state.delta = add i32 %x, 1
  %state.next = add i32 %state, %state.delta
  %rc = xor i32 %x, 7
  br label %latch
latch:
  %state.merge = phi i32 [%state, %left], [%state.next, %right]
  %c = phi i32 [%lc, %left], [%rc, %right]
  %dc = phi double [%ld, %left], [-0.0, %right]
  %fc = phi float [%lf, %left], [-0.0, %right]
  %m0 = phi i32 [%u0, %left], [%r0, %right]
  %m1 = phi i32 [%u1, %left], [%r1, %right]
  %md = phi double [%ud, %left], [%rd, %right]
  %mf = phi float [%uf, %left], [%rf, %right]
  %next = add nuw nsw i64 %iv, 2
  %done = icmp uge i64 %next, %limit
  br i1 %done, label %producer.exit, label %loop, !dbg !13
producer.exit:
  %out.x = phi i32 [%x, %latch]
  %out.c = phi i32 [%c, %latch]
  %out.c.copy = phi i32 [%state.merge, %latch]
  %out.iv = phi i64 [%iv, %latch]
  %out.next = phi i64 [%next, %latch]
  %out.dc = phi double [%dc, %latch]
  %out.fc = phi float [%fc, %latch]
  %out.r0 = phi i32 [%m0, %latch]
  %out.r1 = phi i32 [%m1, %latch]
  %out.rd = phi double [%md, %latch]
  %out.rf = phi float [%mf, %latch]
  br label %exit
exit:
  %final.x = phi i32 [-99, %entry], [%out.x, %producer.exit]
  %final.c = phi i32 [-101, %entry], [%out.c, %producer.exit]
  %final.c.copy = phi i32 [23, %entry], [%out.c.copy, %producer.exit]
  %final.iv = phi i64 [-1, %entry], [%out.iv, %producer.exit]
  %final.next = phi i64 [0, %entry], [%out.next, %producer.exit]
  %final.dc = phi double [-0.0, %entry], [%out.dc, %producer.exit]
  %final.fc = phi float [-0.0, %entry], [%out.fc, %producer.exit]
  %final.r0 = phi i32 [17, %entry], [%out.r0, %producer.exit]
  %final.r1 = phi i32 [-7, %entry], [%out.r1, %producer.exit]
  %final.rd = phi double [%start, %entry], [%out.rd, %producer.exit]
  %final.rf = phi float [%fstart, %entry], [%out.rf, %producer.exit]
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %final.r0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %final.r1, ptr %o1, align 4
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %final.x, ptr %o2, align 4
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %final.c, ptr %o3, align 4
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %final.c.copy, ptr %o4, align 4
  %indices0 = getelementptr i64, ptr %indices, i64 0
  store i64 %final.iv, ptr %indices0, align 8
  %indices1 = getelementptr i64, ptr %indices, i64 1
  store i64 %final.next, ptr %indices1, align 8
  %dout0 = getelementptr double, ptr %dout, i64 0
  store double %final.rd, ptr %dout0, align 8
  %dout1 = getelementptr double, ptr %dout, i64 1
  store double %final.dc, ptr %dout1, align 8
  %fout0 = getelementptr float, ptr %fout, i64 0
  store float %final.rf, ptr %fout0, align 4
  %fout1 = getelementptr float, ptr %fout, i64 1
  store float %final.fc, ptr %fout1, align 4
  ret void
}

define void @state_cfg_affine(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                            ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !14 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %inner.enter, label %preheader, label %exit
preheader:
  %span = shl nuw nsw i64 %n, 1
  %limit = add nuw nsw i64 %span, 7
  br label %loop, !dbg !15
loop:
  %iv = phi i64 [7, %preheader], [%next, %latch]
  %state = phi i32 [23, %preheader], [%state.merge, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %rf = phi float [%fstart, %preheader], [%mf, %latch]
  %distance = sub nuw nsw i64 %iv, 7
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp eq i32 %x, 0
  br i1 %choose, label %inactive.dispatch, label %active.entry
active.entry:
  %q = sdiv i32 840, %x
  %large = icmp ugt i32 %x, 5
  br i1 %large, label %high, label %low
high:
  %parity = and i64 %index, 1
  %even = icmp eq i64 %parity, 0
  br i1 %even, label %even.arm, label %odd.arm
even.arm:
  %even.arg = add i32 %q, 5
  br label %active.merge
odd.arm:
  %odd.arg = add i32 %q, 23
  br label %active.merge
low:
  %low.arg = xor i32 %q, -1
  br label %active.merge
active.merge:
  %arg = phi i32 [%low.arg, %low], [%odd.arg, %odd.arm], [%even.arg, %even.arm]
  br label %left
left:
  %state.arg = xor i32 %arg, %state
  %lc = call i32 @scalar_helper(i32 %state.arg)
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %ld = fmul double %dx, 3.0
  %lf = fptrunc double %ld to float
  %u0 = add i32 %r0, %lc
  %u1 = add i32 %lc, %r1
  %ud = fadd double %rd, %ld
  %uf = fadd float %rf, %lf
  br label %latch
inactive.dispatch:
  %rc = xor i32 %x, 7
  %route = urem i64 %index, 3
  %route.zero = icmp eq i64 %route, 0
  br i1 %route.zero, label %right, label %inactive.second
inactive.second:
  %route.one = icmp eq i64 %route, 1
  br i1 %route.one, label %right1, label %right2
right:
  br label %latch
right1:
  %state.delta = add i32 %x, 1
  %state.next = add i32 %state, %state.delta
  br label %latch
right2:
  br label %latch
latch:
  %state.merge = phi i32 [%state, %right2], [%state, %left], [%state, %right], [%state.next, %right1]
  %c = phi i32 [%rc, %right2], [%lc, %left], [%rc, %right], [%rc, %right1]
  %dc = phi double [-0.0, %right2], [%ld, %left], [-0.0, %right], [-0.0, %right1]
  %fc = phi float [-0.0, %right2], [%lf, %left], [-0.0, %right], [-0.0, %right1]
  %m0 = phi i32 [%r0, %right2], [%u0, %left], [%r0, %right], [%r0, %right1]
  %m1 = phi i32 [%r1, %right2], [%u1, %left], [%r1, %right], [%r1, %right1]
  %md = phi double [%rd, %right2], [%ud, %left], [%rd, %right], [%rd, %right1]
  %mf = phi float [%rf, %right2], [%uf, %left], [%rf, %right], [%rf, %right1]
  %next = add nuw nsw i64 %iv, 2
  %done = icmp uge i64 %next, %limit
  br i1 %done, label %producer.exit, label %loop, !dbg !15
producer.exit:
  %out.x = phi i32 [%x, %latch]
  %out.c = phi i32 [%c, %latch]
  %out.c.copy = phi i32 [%state.merge, %latch]
  %out.iv = phi i64 [%iv, %latch]
  %out.next = phi i64 [%next, %latch]
  %out.dc = phi double [%dc, %latch]
  %out.fc = phi float [%fc, %latch]
  %out.r0 = phi i32 [%m0, %latch]
  %out.r1 = phi i32 [%m1, %latch]
  %out.rd = phi double [%md, %latch]
  %out.rf = phi float [%mf, %latch]
  br label %exit
exit:
  %final.x = phi i32 [-99, %entry], [%out.x, %producer.exit]
  %final.c = phi i32 [-101, %entry], [%out.c, %producer.exit]
  %final.c.copy = phi i32 [23, %entry], [%out.c.copy, %producer.exit]
  %final.iv = phi i64 [-1, %entry], [%out.iv, %producer.exit]
  %final.next = phi i64 [0, %entry], [%out.next, %producer.exit]
  %final.dc = phi double [-0.0, %entry], [%out.dc, %producer.exit]
  %final.fc = phi float [-0.0, %entry], [%out.fc, %producer.exit]
  %final.r0 = phi i32 [17, %entry], [%out.r0, %producer.exit]
  %final.r1 = phi i32 [-7, %entry], [%out.r1, %producer.exit]
  %final.rd = phi double [%start, %entry], [%out.rd, %producer.exit]
  %final.rf = phi float [%fstart, %entry], [%out.rf, %producer.exit]
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %final.r0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %final.r1, ptr %o1, align 4
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %final.x, ptr %o2, align 4
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %final.c, ptr %o3, align 4
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %final.c.copy, ptr %o4, align 4
  %indices0 = getelementptr i64, ptr %indices, i64 0
  store i64 %final.iv, ptr %indices0, align 8
  %indices1 = getelementptr i64, ptr %indices, i64 1
  store i64 %final.next, ptr %indices1, align 8
  %dout0 = getelementptr double, ptr %dout, i64 0
  store double %final.rd, ptr %dout0, align 8
  %dout1 = getelementptr double, ptr %dout, i64 1
  store double %final.dc, ptr %dout1, align 8
  %fout0 = getelementptr float, ptr %fout, i64 0
  store float %final.rf, ptr %fout0, align 4
  %fout1 = getelementptr float, ptr %fout, i64 1
  store float %final.fc, ptr %fout1, align 4
  ret void
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-state-cfg.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!5 = !DISubroutineType(types: !6)
!6 = !{}
!10 = distinct !DISubprogram(name: "state_cfg_serial", scope: !1, file: !1, line: 10, type: !5, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 12, column: 3, scope: !10)
!12 = distinct !DISubprogram(name: "state_cfg_nested", scope: !1, file: !1, line: 20, type: !5, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 22, column: 3, scope: !12)
!14 = distinct !DISubprogram(name: "state_cfg_affine", scope: !1, file: !1, line: 30, type: !5, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!15 = !DILocation(line: 32, column: 3, scope: !14)
