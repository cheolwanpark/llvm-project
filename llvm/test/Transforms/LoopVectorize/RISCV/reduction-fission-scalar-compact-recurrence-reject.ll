; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @compact_recurrence_reject_predicate(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @compact_recurrence_reject_state(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @compact_recurrence_reject_address(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @compact_recurrence_reject_state_export(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @compact_recurrence_reject_incompatible(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @compact_recurrence_reject_store(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @compact_recurrence_reject_strict(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @compact_recurrence_reject_constrained(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @compact_recurrence_reject_unbounded(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @compact_recurrence_reject_over_capacity(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Dependent contribution arithmetic preserves positive feature coverage under
; the final producer depth policy. Checks exercise scalar fission and ordinary LV.
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable
declare double @llvm.experimental.constrained.fsub.f64(double, double, metadata, metadata)

define void @compact_recurrence_reject_predicate(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !12 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  %mode = and i64 %begin, 7
  br label %loop, !dbg !13
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %older = phi i32 [11, %preheader], [%prev, %latch]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %dolder = phi double [0.5, %preheader], [%dprev, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %bit = and i32 %r0, 1
  %odd = icmp ne i32 %bit, 0
  %positive = fcmp ogt double %dprev, 0.0
  %first = icmp eq i64 %iv, 0
  %pos.next = add nuw nsw i64 %iv, 1
  %last = icmp eq i64 %pos.next, %n
  %none.mode = icmp eq i64 %mode, 0
  %all.mode = icmp eq i64 %mode, 1
  %first.mode = icmp eq i64 %mode, 3
  %last.mode = icmp eq i64 %mode, 4
  %fp.mode = icmp eq i64 %mode, 5
  %sparse = select i1 %fp.mode, i1 %positive, i1 %odd
  %pick.last = select i1 %last.mode, i1 %last, i1 %sparse
  %pick.first = select i1 %first.mode, i1 %first, i1 %pick.last
  %pick.all = select i1 %all.mode, i1 true, i1 %pick.first
  %choose = select i1 %none.mode, i1 false, i1 %pick.all
  br i1 %choose, label %left, label %right
left:
  %offset = and i32 %prev, 63
  %offset64 = zext i32 %offset to i64
  %ap = getelementptr i32, ptr %a, i64 %offset64
  %ax = load i32, ptr %ap, align 4
  %adp = getelementptr double, ptr %fp, i64 %offset64
  %adx = load double, ptr %adp, align 8
  %raw = xor i32 %prev, %ax
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %adx, %dprev
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  br label %latch
right:
  br label %latch
latch:
  %m0 = phi i32 [%u0, %left], [%r0, %right]
  %m1 = phi i32 [%u1, %left], [%r1, %right]
  %md = phi double [%ud, %left], [%rd, %right]
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !13
exit:
  %v0 = phi i32 [17, %entry], [%m0, %latch]
  %v1 = phi i32 [-7, %entry], [%m1, %latch]
  %vd = phi double [%start, %entry], [%md, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  ret void
}

define void @compact_recurrence_reject_state(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !14 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  %mode = and i64 %begin, 7
  br label %loop, !dbg !15
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %older = phi i32 [11, %preheader], [%prev, %latch]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %dolder = phi double [0.5, %preheader], [%dprev, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %bounded = and i32 %x, 127
  %dstate.next = fsub double %dx, %dolder
  %bit = and i32 %prev, 1
  %odd = icmp ne i32 %bit, 0
  %positive = fcmp ogt double %dprev, 0.0
  %first = icmp eq i64 %iv, 0
  %pos.next = add nuw nsw i64 %iv, 1
  %last = icmp eq i64 %pos.next, %n
  %none.mode = icmp eq i64 %mode, 0
  %all.mode = icmp eq i64 %mode, 1
  %first.mode = icmp eq i64 %mode, 3
  %last.mode = icmp eq i64 %mode, 4
  %fp.mode = icmp eq i64 %mode, 5
  %sparse = select i1 %fp.mode, i1 %positive, i1 %odd
  %pick.last = select i1 %last.mode, i1 %last, i1 %sparse
  %pick.first = select i1 %first.mode, i1 %first, i1 %pick.last
  %pick.all = select i1 %all.mode, i1 true, i1 %pick.first
  %choose = select i1 %none.mode, i1 false, i1 %pick.all
  br i1 %choose, label %left, label %right
left:
  %offset = and i32 %prev, 63
  %offset64 = zext i32 %offset to i64
  %ap = getelementptr i32, ptr %a, i64 %offset64
  %ax = load i32, ptr %ap, align 4
  %adp = getelementptr double, ptr %fp, i64 %offset64
  %adx = load double, ptr %adp, align 8
  %raw = xor i32 %prev, %ax
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %adx, %dprev
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  br label %latch
right:
  br label %latch
latch:
  %m0 = phi i32 [%u0, %left], [%r0, %right]
  %m1 = phi i32 [%u1, %left], [%r1, %right]
  %md = phi double [%ud, %left], [%rd, %right]
  %state.next = add i32 %bounded, %m0
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !15
exit:
  %v0 = phi i32 [17, %entry], [%m0, %latch]
  %v1 = phi i32 [-7, %entry], [%m1, %latch]
  %vd = phi double [%start, %entry], [%md, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  ret void
}

define void @compact_recurrence_reject_address(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !16 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  %mode = and i64 %begin, 7
  br label %loop, !dbg !17
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %older = phi i32 [11, %preheader], [%prev, %latch]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %dolder = phi double [0.5, %preheader], [%dprev, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %bit = and i32 %prev, 1
  %odd = icmp ne i32 %bit, 0
  %positive = fcmp ogt double %dprev, 0.0
  %first = icmp eq i64 %iv, 0
  %pos.next = add nuw nsw i64 %iv, 1
  %last = icmp eq i64 %pos.next, %n
  %none.mode = icmp eq i64 %mode, 0
  %all.mode = icmp eq i64 %mode, 1
  %first.mode = icmp eq i64 %mode, 3
  %last.mode = icmp eq i64 %mode, 4
  %fp.mode = icmp eq i64 %mode, 5
  %sparse = select i1 %fp.mode, i1 %positive, i1 %odd
  %pick.last = select i1 %last.mode, i1 %last, i1 %sparse
  %pick.first = select i1 %first.mode, i1 %first, i1 %pick.last
  %pick.all = select i1 %all.mode, i1 true, i1 %pick.first
  %choose = select i1 %none.mode, i1 false, i1 %pick.all
  br i1 %choose, label %left, label %right
left:
  %offset = and i32 %r0, 63
  %offset64 = zext i32 %offset to i64
  %ap = getelementptr i32, ptr %a, i64 %offset64
  %ax = load i32, ptr %ap, align 4
  %adp = getelementptr double, ptr %fp, i64 %offset64
  %adx = load double, ptr %adp, align 8
  %raw = xor i32 %prev, %ax
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %adx, %dprev
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  br label %latch
right:
  br label %latch
latch:
  %m0 = phi i32 [%u0, %left], [%r0, %right]
  %m1 = phi i32 [%u1, %left], [%r1, %right]
  %md = phi double [%ud, %left], [%rd, %right]
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !17
exit:
  %v0 = phi i32 [17, %entry], [%m0, %latch]
  %v1 = phi i32 [-7, %entry], [%m1, %latch]
  %vd = phi double [%start, %entry], [%md, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  ret void
}

define void @compact_recurrence_reject_state_export(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !18 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  %mode = and i64 %begin, 7
  br label %loop, !dbg !19
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %older = phi i32 [11, %preheader], [%prev, %latch]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %dolder = phi double [0.5, %preheader], [%dprev, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %bit = and i32 %prev, 1
  %odd = icmp ne i32 %bit, 0
  %positive = fcmp ogt double %dprev, 0.0
  %first = icmp eq i64 %iv, 0
  %pos.next = add nuw nsw i64 %iv, 1
  %last = icmp eq i64 %pos.next, %n
  %none.mode = icmp eq i64 %mode, 0
  %all.mode = icmp eq i64 %mode, 1
  %first.mode = icmp eq i64 %mode, 3
  %last.mode = icmp eq i64 %mode, 4
  %fp.mode = icmp eq i64 %mode, 5
  %sparse = select i1 %fp.mode, i1 %positive, i1 %odd
  %pick.last = select i1 %last.mode, i1 %last, i1 %sparse
  %pick.first = select i1 %first.mode, i1 %first, i1 %pick.last
  %pick.all = select i1 %all.mode, i1 true, i1 %pick.first
  %choose = select i1 %none.mode, i1 false, i1 %pick.all
  br i1 %choose, label %left, label %right
left:
  %offset = and i32 %prev, 63
  %offset64 = zext i32 %offset to i64
  %ap = getelementptr i32, ptr %a, i64 %offset64
  %ax = load i32, ptr %ap, align 4
  %adp = getelementptr double, ptr %fp, i64 %offset64
  %adx = load double, ptr %adp, align 8
  %raw = xor i32 %prev, %ax
  %c.depth.mul = mul i32 %raw, 13
  %c.depth.bias = add i32 %c.depth.mul, 7
  %c = call i32 @scalar_helper(i32 %c.depth.bias)
  %dc = fsub double %adx, %dprev
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  br label %latch
right:
  br label %latch
latch:
  %m0 = phi i32 [%u0, %left], [%r0, %right]
  %m1 = phi i32 [%u1, %left], [%r1, %right]
  %md = phi double [%ud, %left], [%rd, %right]
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !19
exit:
  %export = phi i32 [23, %entry], [%prev, %latch]
  %v0 = phi i32 [17, %entry], [%m0, %latch]
  %v1 = phi i32 [-7, %entry], [%m1, %latch]
  %vd = phi double [%start, %entry], [%md, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  %observable = add i32 %v0, %export
  store i32 %observable, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  ret void
}

define void @compact_recurrence_reject_incompatible(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !20 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  %mode = and i64 %begin, 7
  br label %loop, !dbg !21
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %older = phi i32 [11, %preheader], [%prev, %latch]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %dolder = phi double [0.5, %preheader], [%dprev, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %bit = and i32 %prev, 1
  %odd = icmp ne i32 %bit, 0
  %positive = fcmp ogt double %dprev, 0.0
  %first = icmp eq i64 %iv, 0
  %pos.next = add nuw nsw i64 %iv, 1
  %last = icmp eq i64 %pos.next, %n
  %none.mode = icmp eq i64 %mode, 0
  %all.mode = icmp eq i64 %mode, 1
  %first.mode = icmp eq i64 %mode, 3
  %last.mode = icmp eq i64 %mode, 4
  %fp.mode = icmp eq i64 %mode, 5
  %sparse = select i1 %fp.mode, i1 %positive, i1 %odd
  %pick.last = select i1 %last.mode, i1 %last, i1 %sparse
  %pick.first = select i1 %first.mode, i1 %first, i1 %pick.last
  %pick.all = select i1 %all.mode, i1 true, i1 %pick.first
  %choose = select i1 %none.mode, i1 false, i1 %pick.all
  br i1 %choose, label %left, label %right
left:
  %offset = and i32 %prev, 63
  %offset64 = zext i32 %offset to i64
  %ap = getelementptr i32, ptr %a, i64 %offset64
  %ax = load i32, ptr %ap, align 4
  %adp = getelementptr double, ptr %fp, i64 %offset64
  %adx = load double, ptr %adp, align 8
  %raw = xor i32 %prev, %ax
  %c.depth.mul = mul i32 %raw, 13
  %c.depth.bias = add i32 %c.depth.mul, 7
  %c = call i32 @scalar_helper(i32 %c.depth.bias)
  %dc = fsub double %adx, %dprev
  %u0 = add i32 %r0, %c
  %ud = fadd double %rd, %dc
  br label %latch
right:
  %u1 = add i32 1, %r1
  br label %latch
latch:
  %m0 = phi i32 [%u0, %left], [%r0, %right]
  %m1 = phi i32 [%r1, %left], [%u1, %right]
  %md = phi double [%ud, %left], [%rd, %right]
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !21
exit:
  %v0 = phi i32 [17, %entry], [%m0, %latch]
  %v1 = phi i32 [-7, %entry], [%m1, %latch]
  %vd = phi double [%start, %entry], [%md, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  ret void
}

define void @compact_recurrence_reject_store(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !22 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  %mode = and i64 %begin, 7
  br label %loop, !dbg !23
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %older = phi i32 [11, %preheader], [%prev, %latch]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %dolder = phi double [0.5, %preheader], [%dprev, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %bit = and i32 %prev, 1
  %odd = icmp ne i32 %bit, 0
  %positive = fcmp ogt double %dprev, 0.0
  %first = icmp eq i64 %iv, 0
  %pos.next = add nuw nsw i64 %iv, 1
  %last = icmp eq i64 %pos.next, %n
  %none.mode = icmp eq i64 %mode, 0
  %all.mode = icmp eq i64 %mode, 1
  %first.mode = icmp eq i64 %mode, 3
  %last.mode = icmp eq i64 %mode, 4
  %fp.mode = icmp eq i64 %mode, 5
  %sparse = select i1 %fp.mode, i1 %positive, i1 %odd
  %pick.last = select i1 %last.mode, i1 %last, i1 %sparse
  %pick.first = select i1 %first.mode, i1 %first, i1 %pick.last
  %pick.all = select i1 %all.mode, i1 true, i1 %pick.first
  %choose = select i1 %none.mode, i1 false, i1 %pick.all
  br i1 %choose, label %left, label %right
left:
  %offset = and i32 %prev, 63
  %offset64 = zext i32 %offset to i64
  %ap = getelementptr i32, ptr %a, i64 %offset64
  %ax = load i32, ptr %ap, align 4
  %adp = getelementptr double, ptr %fp, i64 %offset64
  %adx = load double, ptr %adp, align 8
  store i32 %ax, ptr %out
  %raw = xor i32 %prev, %ax
  %c.depth.mul = mul i32 %raw, 13
  %c.depth.bias = add i32 %c.depth.mul, 7
  %c = call i32 @scalar_helper(i32 %c.depth.bias)
  %dc = fsub double %adx, %dprev
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  br label %latch
right:
  br label %latch
latch:
  %m0 = phi i32 [%u0, %left], [%r0, %right]
  %m1 = phi i32 [%u1, %left], [%r1, %right]
  %md = phi double [%ud, %left], [%rd, %right]
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !23
exit:
  %v0 = phi i32 [17, %entry], [%m0, %latch]
  %v1 = phi i32 [-7, %entry], [%m1, %latch]
  %vd = phi double [%start, %entry], [%md, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  ret void
}

define void @compact_recurrence_reject_strict(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) strictfp !dbg !24 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  %mode = and i64 %begin, 7
  br label %loop, !dbg !25
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %older = phi i32 [11, %preheader], [%prev, %latch]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %dolder = phi double [0.5, %preheader], [%dprev, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %bit = and i32 %prev, 1
  %odd = icmp ne i32 %bit, 0
  %positive = fcmp ogt double %dprev, 0.0
  %first = icmp eq i64 %iv, 0
  %pos.next = add nuw nsw i64 %iv, 1
  %last = icmp eq i64 %pos.next, %n
  %none.mode = icmp eq i64 %mode, 0
  %all.mode = icmp eq i64 %mode, 1
  %first.mode = icmp eq i64 %mode, 3
  %last.mode = icmp eq i64 %mode, 4
  %fp.mode = icmp eq i64 %mode, 5
  %sparse = select i1 %fp.mode, i1 %positive, i1 %odd
  %pick.last = select i1 %last.mode, i1 %last, i1 %sparse
  %pick.first = select i1 %first.mode, i1 %first, i1 %pick.last
  %pick.all = select i1 %all.mode, i1 true, i1 %pick.first
  %choose = select i1 %none.mode, i1 false, i1 %pick.all
  br i1 %choose, label %left, label %right
left:
  %offset = and i32 %prev, 63
  %offset64 = zext i32 %offset to i64
  %ap = getelementptr i32, ptr %a, i64 %offset64
  %ax = load i32, ptr %ap, align 4
  %adp = getelementptr double, ptr %fp, i64 %offset64
  %adx = load double, ptr %adp, align 8
  %raw = xor i32 %prev, %ax
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %adx, %dprev
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  br label %latch
right:
  br label %latch
latch:
  %m0 = phi i32 [%u0, %left], [%r0, %right]
  %m1 = phi i32 [%u1, %left], [%r1, %right]
  %md = phi double [%ud, %left], [%rd, %right]
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !25
exit:
  %v0 = phi i32 [17, %entry], [%m0, %latch]
  %v1 = phi i32 [-7, %entry], [%m1, %latch]
  %vd = phi double [%start, %entry], [%md, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  ret void
}

define void @compact_recurrence_reject_constrained(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !26 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  %mode = and i64 %begin, 7
  br label %loop, !dbg !27
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %older = phi i32 [11, %preheader], [%prev, %latch]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %dolder = phi double [0.5, %preheader], [%dprev, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %bit = and i32 %prev, 1
  %odd = icmp ne i32 %bit, 0
  %positive = fcmp ogt double %dprev, 0.0
  %first = icmp eq i64 %iv, 0
  %pos.next = add nuw nsw i64 %iv, 1
  %last = icmp eq i64 %pos.next, %n
  %none.mode = icmp eq i64 %mode, 0
  %all.mode = icmp eq i64 %mode, 1
  %first.mode = icmp eq i64 %mode, 3
  %last.mode = icmp eq i64 %mode, 4
  %fp.mode = icmp eq i64 %mode, 5
  %sparse = select i1 %fp.mode, i1 %positive, i1 %odd
  %pick.last = select i1 %last.mode, i1 %last, i1 %sparse
  %pick.first = select i1 %first.mode, i1 %first, i1 %pick.last
  %pick.all = select i1 %all.mode, i1 true, i1 %pick.first
  %choose = select i1 %none.mode, i1 false, i1 %pick.all
  br i1 %choose, label %left, label %right
left:
  %offset = and i32 %prev, 63
  %offset64 = zext i32 %offset to i64
  %ap = getelementptr i32, ptr %a, i64 %offset64
  %ax = load i32, ptr %ap, align 4
  %adp = getelementptr double, ptr %fp, i64 %offset64
  %adx = load double, ptr %adp, align 8
  %raw = xor i32 %prev, %ax
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = call double @llvm.experimental.constrained.fsub.f64(double %adx, double %dprev, metadata !"round.dynamic", metadata !"fpexcept.strict")
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  br label %latch
right:
  br label %latch
latch:
  %m0 = phi i32 [%u0, %left], [%r0, %right]
  %m1 = phi i32 [%u1, %left], [%r1, %right]
  %md = phi double [%ud, %left], [%rd, %right]
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !27
exit:
  %v0 = phi i32 [17, %entry], [%m0, %latch]
  %v1 = phi i32 [-7, %entry], [%m1, %latch]
  %vd = phi double [%start, %entry], [%md, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  ret void
}

define void @compact_recurrence_reject_unbounded(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !28 {
entry:
  %valid = icmp ule i64 %n, -1
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  %mode = and i64 %begin, 7
  br label %loop, !dbg !29
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %older = phi i32 [11, %preheader], [%prev, %latch]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %dolder = phi double [0.5, %preheader], [%dprev, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %bit = and i32 %prev, 1
  %odd = icmp ne i32 %bit, 0
  %positive = fcmp ogt double %dprev, 0.0
  %first = icmp eq i64 %iv, 0
  %pos.next = add nuw nsw i64 %iv, 1
  %last = icmp eq i64 %pos.next, %n
  %none.mode = icmp eq i64 %mode, 0
  %all.mode = icmp eq i64 %mode, 1
  %first.mode = icmp eq i64 %mode, 3
  %last.mode = icmp eq i64 %mode, 4
  %fp.mode = icmp eq i64 %mode, 5
  %sparse = select i1 %fp.mode, i1 %positive, i1 %odd
  %pick.last = select i1 %last.mode, i1 %last, i1 %sparse
  %pick.first = select i1 %first.mode, i1 %first, i1 %pick.last
  %pick.all = select i1 %all.mode, i1 true, i1 %pick.first
  %choose = select i1 %none.mode, i1 false, i1 %pick.all
  br i1 %choose, label %left, label %right
left:
  %offset = and i32 %prev, 63
  %offset64 = zext i32 %offset to i64
  %ap = getelementptr i32, ptr %a, i64 %offset64
  %ax = load i32, ptr %ap, align 4
  %adp = getelementptr double, ptr %fp, i64 %offset64
  %adx = load double, ptr %adp, align 8
  %raw = xor i32 %prev, %ax
  %c.depth.mul = mul i32 %raw, 13
  %c.depth.bias = add i32 %c.depth.mul, 7
  %c = call i32 @scalar_helper(i32 %c.depth.bias)
  %dc = fsub double %adx, %dprev
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  br label %latch
right:
  br label %latch
latch:
  %m0 = phi i32 [%u0, %left], [%r0, %right]
  %m1 = phi i32 [%u1, %left], [%r1, %right]
  %md = phi double [%ud, %left], [%rd, %right]
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !29
exit:
  %v0 = phi i32 [17, %entry], [%m0, %latch]
  %v1 = phi i32 [-7, %entry], [%m1, %latch]
  %vd = phi double [%start, %entry], [%md, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  ret void
}

define void @compact_recurrence_reject_over_capacity(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !30 {
entry:
  %valid = icmp ule i64 %n, 5462
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  %mode = and i64 %begin, 7
  br label %loop, !dbg !31
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %older = phi i32 [11, %preheader], [%prev, %latch]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %dolder = phi double [0.5, %preheader], [%dprev, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %bit = and i32 %prev, 1
  %odd = icmp ne i32 %bit, 0
  %positive = fcmp ogt double %dprev, 0.0
  %first = icmp eq i64 %iv, 0
  %pos.next = add nuw nsw i64 %iv, 1
  %last = icmp eq i64 %pos.next, %n
  %none.mode = icmp eq i64 %mode, 0
  %all.mode = icmp eq i64 %mode, 1
  %first.mode = icmp eq i64 %mode, 3
  %last.mode = icmp eq i64 %mode, 4
  %fp.mode = icmp eq i64 %mode, 5
  %sparse = select i1 %fp.mode, i1 %positive, i1 %odd
  %pick.last = select i1 %last.mode, i1 %last, i1 %sparse
  %pick.first = select i1 %first.mode, i1 %first, i1 %pick.last
  %pick.all = select i1 %all.mode, i1 true, i1 %pick.first
  %choose = select i1 %none.mode, i1 false, i1 %pick.all
  br i1 %choose, label %left, label %right
left:
  %offset = and i32 %prev, 63
  %offset64 = zext i32 %offset to i64
  %ap = getelementptr i32, ptr %a, i64 %offset64
  %ax = load i32, ptr %ap, align 4
  %adp = getelementptr double, ptr %fp, i64 %offset64
  %adx = load double, ptr %adp, align 8
  %raw = xor i32 %prev, %ax
  %c.depth.mul = mul i32 %raw, 13
  %c.depth.bias = add i32 %c.depth.mul, 7
  %c = call i32 @scalar_helper(i32 %c.depth.bias)
  %dc = fsub double %adx, %dprev
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  br label %latch
right:
  br label %latch
latch:
  %m0 = phi i32 [%u0, %left], [%r0, %right]
  %m1 = phi i32 [%u1, %left], [%r1, %right]
  %md = phi double [%ud, %left], [%rd, %right]
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !31
exit:
  %v0 = phi i32 [17, %entry], [%m0, %latch]
  %v1 = phi i32 [-7, %entry], [%m1, %latch]
  %vd = phi double [%start, %entry], [%md, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  ret void
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-compact-recurrence.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = !DISubroutineType(types: !5)
!5 = !{}
!12 = distinct !DISubprogram(name: "compact_recurrence_reject_predicate", scope: !1, file: !1, line: 12, type: !4, scopeLine: 12, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 12, column: 3, scope: !12)
!14 = distinct !DISubprogram(name: "compact_recurrence_reject_state", scope: !1, file: !1, line: 22, type: !4, scopeLine: 22, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!15 = !DILocation(line: 22, column: 3, scope: !14)
!16 = distinct !DISubprogram(name: "compact_recurrence_reject_address", scope: !1, file: !1, line: 32, type: !4, scopeLine: 32, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!17 = !DILocation(line: 32, column: 3, scope: !16)
!18 = distinct !DISubprogram(name: "compact_recurrence_reject_state_export", scope: !1, file: !1, line: 42, type: !4, scopeLine: 42, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!19 = !DILocation(line: 42, column: 3, scope: !18)
!20 = distinct !DISubprogram(name: "compact_recurrence_reject_incompatible", scope: !1, file: !1, line: 52, type: !4, scopeLine: 52, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!21 = !DILocation(line: 52, column: 3, scope: !20)
!22 = distinct !DISubprogram(name: "compact_recurrence_reject_store", scope: !1, file: !1, line: 62, type: !4, scopeLine: 62, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!23 = !DILocation(line: 62, column: 3, scope: !22)
!24 = distinct !DISubprogram(name: "compact_recurrence_reject_strict", scope: !1, file: !1, line: 72, type: !4, scopeLine: 72, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!25 = !DILocation(line: 72, column: 3, scope: !24)
!26 = distinct !DISubprogram(name: "compact_recurrence_reject_constrained", scope: !1, file: !1, line: 82, type: !4, scopeLine: 82, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!27 = !DILocation(line: 82, column: 3, scope: !26)
!28 = distinct !DISubprogram(name: "compact_recurrence_reject_unbounded", scope: !1, file: !1, line: 92, type: !4, scopeLine: 92, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!29 = !DILocation(line: 92, column: 3, scope: !28)
!30 = distinct !DISubprogram(name: "compact_recurrence_reject_over_capacity", scope: !1, file: !1, line: 102, type: !4, scopeLine: 102, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!31 = !DILocation(line: 102, column: 3, scope: !30)
