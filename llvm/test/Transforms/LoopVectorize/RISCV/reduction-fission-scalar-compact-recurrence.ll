; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -pass-remarks=vplan-reduction-fission -S %s -o %t 2> %t.remarks
; RUN: FileCheck %s --check-prefix=SCALAR < %t
; RUN: FileCheck %s --check-prefix=REMARK < %t.remarks
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=4 -force-vector-interleave=1 \
; RUN:   -scalable-vectorization=always -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-allow-fp-reordering \
; RUN:   -tail-folding-policy=dont-fold-tail -enable-epilogue-vectorization=false -S %s -o %t.tail
; RUN: FileCheck %s --check-prefix=TAIL < %t.tail
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.tail -o /dev/null
;
; Closed compact accumulators coexist with integer and ordinary ordered FP
; producer state. State drives participation, addresses and contributions.
; Merge siblings update state only in the active arm; other siblings update
; state on skipped iterations too. Keep every retained PHI, operation, flag and
; branch in its original block/order. Never represent a skip by adding zero.
; The reverse sibling also retains an ordered fadd state used by its predicate.
; Reversed accumulator PHIs reserve double[65] then i32[65] = 780 bytes;
; integer-first uses 260+4+520 = 784. Traffic is 24*P, not 24*N or 24*M.
; Canonical, affine, enclosing reuse and capacity 1/255/5461 analogues are
; original/transformed/independent-formula execution inputs for the checker.
;
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

; REMARK: scalar-compact-recurrence.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; SCALAR-LABEL: define void @compact_recurrence(
; SCALAR-DAG: alloca [65 x i32]
; SCALAR-DAG: alloca [65 x double]
; SCALAR: %prev = phi i32
; SCALAR: %choose = select
; SCALAR-DAG: store i32 %c,
; SCALAR-DAG: store double %dc,
; SCALAR: scalar.fission.consumer.guard:
; SCALAR: %fission.empty = icmp eq i64 %fission.participating.count, 0
; SCALAR: %ud.consume = fadd double %rd.consume,
; SCALAR: %r0.result = phi i32 [ 17, %scalar.fission.consumer.guard ],
; SCALAR: ret void
; TAIL-LABEL: define void @compact_recurrence(
; TAIL: %prev = phi i32
; TAIL: scalar.fission.consumer.guard:
; TAIL: vector.body:
; TAIL: @llvm.vector.reduce.fadd.nxv4f64
; TAIL: scalar.fission.consumer.body:
; TAIL: %ud.consume = fadd double %rd.consume,
; TAIL: ret void
define void @compact_recurrence(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
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

; REMARK: scalar-compact-recurrence.c:22:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 780
; SCALAR-LABEL: define void @compact_recurrence_reverse(
; SCALAR-DAG: alloca [65 x i32]
; SCALAR-DAG: alloca [65 x double]
; SCALAR: %prev = phi i32
; SCALAR: %choose = select
; SCALAR-DAG: store i32 %c,
; SCALAR-DAG: store double %dc,
; SCALAR: scalar.fission.consumer.guard:
; SCALAR: %fission.empty = icmp eq i64 %fission.participating.count, 0
; SCALAR: %ud.consume = fadd double %rd.consume,
; SCALAR: %r0.result = phi i32 [ 17, %scalar.fission.consumer.guard ],
; SCALAR: ret void
; TAIL-LABEL: define void @compact_recurrence_reverse(
; TAIL: %prev = phi i32
; TAIL: scalar.fission.consumer.guard:
; TAIL: vector.body:
; TAIL: @llvm.vector.reduce.fadd.nxv4f64
; TAIL: scalar.fission.consumer.body:
; TAIL: %ud.consume = fadd double %rd.consume,
; TAIL: ret void
define void @compact_recurrence_reverse(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
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
  %rd = phi double [%start, %preheader], [%md, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %older = phi i32 [11, %preheader], [%prev, %latch]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fadd double %dprev, %dx
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

; REMARK: scalar-compact-recurrence.c:32:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; SCALAR-LABEL: define void @compact_recurrence_merge(
; SCALAR-DAG: alloca [65 x i32]
; SCALAR-DAG: alloca [65 x double]
; SCALAR: %prev = phi i32
; SCALAR: %choose = select
; SCALAR-DAG: store i32 %c,
; SCALAR-DAG: store double %dc,
; SCALAR: scalar.fission.consumer.guard:
; SCALAR: %fission.empty = icmp eq i64 %fission.participating.count, 0
; SCALAR: %ud.consume = fadd double %rd.consume,
; SCALAR: %r0.result = phi i32 [ 17, %scalar.fission.consumer.guard ],
; SCALAR: ret void
; TAIL-LABEL: define void @compact_recurrence_merge(
; TAIL: %prev = phi i32
; TAIL: scalar.fission.consumer.guard:
; TAIL: vector.body:
; TAIL: @llvm.vector.reduce.fadd.nxv4f64
; TAIL: scalar.fission.consumer.body:
; TAIL: %ud.consume = fadd double %rd.consume,
; TAIL: ret void
define void @compact_recurrence_merge(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
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
  %state.update = add nuw nsw i32 %bounded, %older
  %dstate.update = fsub double %dx, %dolder
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
  %state.next = phi i32 [%state.update, %left], [%prev, %right]
  %dstate.next = phi double [%dstate.update, %left], [%dprev, %right]
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

; REMARK: scalar-compact-recurrence.c:42:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; SCALAR-LABEL: define void @compact_recurrence_affine(
; SCALAR-DAG: alloca [65 x i32]
; SCALAR-DAG: alloca [65 x double]
; SCALAR: %prev = phi i32
; SCALAR: %choose = select
; SCALAR-DAG: store i32 %c,
; SCALAR-DAG: store double %dc,
; SCALAR: scalar.fission.consumer.guard:
; SCALAR: %fission.empty = icmp eq i64 %fission.participating.count, 0
; SCALAR: %ud.consume = fadd double %rd.consume,
; SCALAR: %r0.result = phi i32 [ 17, %scalar.fission.consumer.guard ],
; SCALAR: ret void
; TAIL-LABEL: define void @compact_recurrence_affine(
; TAIL: %prev = phi i32
; TAIL: scalar.fission.consumer.guard:
; TAIL: vector.body:
; TAIL: @llvm.vector.reduce.fadd.nxv4f64
; TAIL: scalar.fission.consumer.body:
; TAIL: %ud.consume = fadd double %rd.consume,
; TAIL: ret void
define void @compact_recurrence_affine(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !18 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  %span = mul nuw nsw i64 %n, 3
  %limit = add nuw nsw i64 %span, 7
  %mode = and i64 %begin, 7
  br label %loop, !dbg !19
loop:
  %iv = phi i64 [7, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %older = phi i32 [11, %preheader], [%prev, %latch]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %dolder = phi double [0.5, %preheader], [%dprev, %latch]
  %distance = sub i64 %iv, 7
  %pos = udiv i64 %distance, 3
  %p = getelementptr i32, ptr %a, i64 %pos
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %pos
  %dx = load double, ptr %dp, align 8
  %bounded = and i32 %x, 127
  %bit = and i32 %prev, 1
  %odd = icmp ne i32 %bit, 0
  %positive = fcmp ogt double %dprev, 0.0
  %first = icmp eq i64 %pos, 0
  %pos.next = add nuw nsw i64 %pos, 1
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
  %state.update = add nuw nsw i32 %bounded, %older
  %dstate.update = fsub double %dx, %dolder
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
  %state.next = phi i32 [%state.update, %left], [%prev, %right]
  %dstate.next = phi double [%dstate.update, %left], [%dprev, %right]
  %next = add nuw nsw i64 %iv, 3
  %done = icmp uge i64 %next, %limit
  br i1 %done, label %exit, label %loop, !dbg !19
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

; REMARK: scalar-compact-recurrence.c:52:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 780
; SCALAR-LABEL: define void @compact_recurrence_runtime(
; SCALAR-DAG: alloca [65 x i32]
; SCALAR-DAG: alloca [65 x double]
; SCALAR: %prev = phi i32
; SCALAR: %choose = select
; SCALAR-DAG: store i32 %c,
; SCALAR-DAG: store double %dc,
; SCALAR: scalar.fission.consumer.guard:
; SCALAR: %fission.empty = icmp eq i64 %fission.participating.count, 0
; SCALAR: %ud.consume = fadd double %rd.consume,
; SCALAR: %r0.result = phi i32 [ 17, %scalar.fission.consumer.guard ],
; SCALAR: ret void
; TAIL-LABEL: define void @compact_recurrence_runtime(
; TAIL: %prev = phi i32
; TAIL: scalar.fission.consumer.guard:
; TAIL: vector.body:
; TAIL: @llvm.vector.reduce.fadd.nxv4f64
; TAIL: scalar.fission.consumer.body:
; TAIL: %ud.consume = fadd double %rd.consume,
; TAIL: ret void
define void @compact_recurrence_runtime(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !20 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  %origin = and i64 %begin, 255
  %span = shl nuw nsw i64 %n, 1
  %limit = add nuw nsw i64 %origin, %span
  %mode = and i64 %begin, 7
  br label %loop, !dbg !21
loop:
  %iv = phi i64 [%origin, %preheader], [%next, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %older = phi i32 [11, %preheader], [%prev, %latch]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %dolder = phi double [0.5, %preheader], [%dprev, %latch]
  %distance = sub i64 %iv, %origin
  %pos = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %pos
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %pos
  %dx = load double, ptr %dp, align 8
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %bit = and i32 %prev, 1
  %odd = icmp ne i32 %bit, 0
  %positive = fcmp ogt double %dprev, 0.0
  %first = icmp eq i64 %pos, 0
  %pos.next = add nuw nsw i64 %pos, 1
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
  %next = add nuw nsw i64 %iv, 2
  %done = icmp eq i64 %next, %limit
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

; REMARK: scalar-compact-recurrence.c:62:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; SCALAR-LABEL: define void @compact_recurrence_enclosing(
; SCALAR-DAG: alloca [65 x i32]
; SCALAR-DAG: alloca [65 x double]
; SCALAR: %prev = phi i32
; SCALAR: %choose = select
; SCALAR-DAG: store i32 %c,
; SCALAR-DAG: store double %dc,
; SCALAR: scalar.fission.consumer.guard:
; SCALAR: %fission.empty = icmp eq i64 %fission.participating.count, 0
; SCALAR: %ud.consume = fadd double %rd.consume,
; SCALAR: %r0.result = phi i32 [ %carry0, %scalar.fission.consumer.guard ],
; SCALAR: ret void
; TAIL-LABEL: define void @compact_recurrence_enclosing(
; TAIL: %prev = phi i32
; TAIL: scalar.fission.consumer.guard:
; TAIL: vector.body:
; TAIL: @llvm.vector.reduce.fadd.nxv4f64
; TAIL: scalar.fission.consumer.body:
; TAIL: %ud.consume = fadd double %rd.consume,
; TAIL: ret void
define void @compact_recurrence_enclosing(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !22 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %rows.valid = icmp ule i64 %rows, 4
  %rows.nonzero = icmp ne i64 %rows, 0
  %row.enter = and i1 %rows.valid, %rows.nonzero
  %both = and i1 %enter, %row.enter
  br i1 %both, label %outer.ph, label %exit
outer.ph:
  br label %outer
outer:
  %row = phi i64 [0, %outer.ph], [%row.next, %row.exit]
  %carry0 = phi i32 [17, %outer.ph], [%v0, %row.exit]
  %carry1 = phi i32 [-7, %outer.ph], [%v1, %row.exit]
  %dcarry = phi double [%start, %outer.ph], [%vd, %row.exit]
  %base = mul nuw nsw i64 %row, 65
  br label %inner.ph
inner.ph:
  %span = mul nuw nsw i64 %n, 3
  %limit = add nuw nsw i64 %span, 7
  %mode = and i64 %begin, 7
  br label %inner, !dbg !23
inner:
  %iv = phi i64 [7, %inner.ph], [%next, %latch]
  %prev = phi i32 [23, %inner.ph], [%state.next, %latch]
  %r0 = phi i32 [%carry0, %inner.ph], [%m0, %latch]
  %older = phi i32 [11, %inner.ph], [%prev, %latch]
  %dprev = phi double [-0.0, %inner.ph], [%dstate.next, %latch]
  %r1 = phi i32 [%carry1, %inner.ph], [%m1, %latch]
  %rd = phi double [%dcarry, %inner.ph], [%md, %latch]
  %dolder = phi double [0.5, %inner.ph], [%dprev, %latch]
  %distance = sub i64 %iv, 7
  %pos = udiv i64 %distance, 3
  %index = add nuw nsw i64 %base, %pos
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %bounded = and i32 %x, 127
  %bit = and i32 %prev, 1
  %odd = icmp ne i32 %bit, 0
  %positive = fcmp ogt double %dprev, 0.0
  %first = icmp eq i64 %pos, 0
  %pos.next = add nuw nsw i64 %pos, 1
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
  %address = add nuw nsw i64 %base, %offset64
  %ap = getelementptr i32, ptr %a, i64 %address
  %ax = load i32, ptr %ap, align 4
  %adp = getelementptr double, ptr %fp, i64 %address
  %adx = load double, ptr %adp, align 8
  %raw = xor i32 %prev, %ax
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %adx, %dprev
  %state.update = add nuw nsw i32 %bounded, %older
  %dstate.update = fsub double %dx, %dolder
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
  %state.next = phi i32 [%state.update, %left], [%prev, %right]
  %dstate.next = phi double [%dstate.update, %left], [%dprev, %right]
  %next = add nuw nsw i64 %iv, 3
  %done = icmp uge i64 %next, %limit
  br i1 %done, label %row.exit, label %inner, !dbg !23
row.exit:
  %v0 = phi i32 [%m0, %latch]
  %v1 = phi i32 [%m1, %latch]
  %vd = phi double [%md, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  %row.next = add nuw nsw i64 %row, 1
  %more = icmp ult i64 %row.next, %rows
  br i1 %more, label %outer, label %exit
exit:
  %result0 = phi i32 [17, %entry], [%v0, %row.exit]
  %result1 = phi i32 [-7, %entry], [%v1, %row.exit]
  %resultd = phi double [%start, %entry], [%vd, %row.exit]
  %last.o1 = getelementptr i32, ptr %out, i64 1
  store i32 %result0, ptr %out
  store i32 %result1, ptr %last.o1
  store double %resultd, ptr %dout
  ret void
}

; REMARK: scalar-compact-recurrence.c:72:3: split scalar-IR reduction loop; {{.*}}scratch capacity 1, scratch bytes 16
; SCALAR-LABEL: define void @compact_recurrence_one(
; SCALAR-DAG: alloca [1 x i32]
; SCALAR-DAG: alloca [1 x double]
; SCALAR: %prev = phi i32
; SCALAR: %choose = select
; SCALAR-DAG: store i32 %c,
; SCALAR-DAG: store double %dc,
; SCALAR: scalar.fission.consumer.guard:
; SCALAR: %fission.empty = icmp eq i64 %fission.participating.count, 0
; SCALAR: %ud.consume = fadd double %rd.consume,
; SCALAR: %r0.result = phi i32 [ 17, %scalar.fission.consumer.guard ],
; SCALAR: ret void
define void @compact_recurrence_one(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !24 {
entry:
  %valid = icmp ule i64 %n, 1
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
  %state.update = add nuw nsw i32 %bounded, %older
  %dstate.update = fsub double %dx, %dolder
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
  %state.next = phi i32 [%state.update, %left], [%prev, %right]
  %dstate.next = phi double [%dstate.update, %left], [%dprev, %right]
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

; REMARK: scalar-compact-recurrence.c:82:3: split scalar-IR reduction loop; {{.*}}scratch capacity 255, scratch bytes 3064
; SCALAR-LABEL: define void @compact_recurrence_255(
; SCALAR-DAG: alloca [255 x i32]
; SCALAR-DAG: alloca [255 x double]
; SCALAR: %prev = phi i32
; SCALAR: %choose = select
; SCALAR-DAG: store i32 %c,
; SCALAR-DAG: store double %dc,
; SCALAR: scalar.fission.consumer.guard:
; SCALAR: %fission.empty = icmp eq i64 %fission.participating.count, 0
; SCALAR: %ud.consume = fadd double %rd.consume,
; SCALAR: %r0.result = phi i32 [ 17, %scalar.fission.consumer.guard ],
; SCALAR: ret void
define void @compact_recurrence_255(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !26 {
entry:
  %valid = icmp ule i64 %n, 255
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

; REMARK: scalar-compact-recurrence.c:92:3: split scalar-IR reduction loop; {{.*}}scratch capacity 5461, scratch bytes 65536
; SCALAR-LABEL: define void @compact_recurrence_limit(
; SCALAR-DAG: alloca [5461 x i32]
; SCALAR-DAG: alloca [5461 x double]
; SCALAR: %prev = phi i32
; SCALAR: %choose = select
; SCALAR-DAG: store i32 %c,
; SCALAR-DAG: store double %dc,
; SCALAR: scalar.fission.consumer.guard:
; SCALAR: %fission.empty = icmp eq i64 %fission.participating.count, 0
; SCALAR: %ud.consume = fadd double %rd.consume,
; SCALAR: %r0.result = phi i32 [ 17, %scalar.fission.consumer.guard ],
; SCALAR: ret void
define void @compact_recurrence_limit(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !28 {
entry:
  %valid = icmp ule i64 %n, 5461
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
  %state.update = add nuw nsw i32 %bounded, %older
  %dstate.update = fsub double %dx, %dolder
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
  %state.next = phi i32 [%state.update, %left], [%prev, %right]
  %dstate.next = phi double [%dstate.update, %left], [%dprev, %right]
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

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-compact-recurrence.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = !DISubroutineType(types: !5)
!5 = !{}
!12 = distinct !DISubprogram(name: "compact_recurrence", scope: !1, file: !1, line: 12, type: !4, scopeLine: 12, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 12, column: 3, scope: !12)
!14 = distinct !DISubprogram(name: "compact_recurrence_reverse", scope: !1, file: !1, line: 22, type: !4, scopeLine: 22, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!15 = !DILocation(line: 22, column: 3, scope: !14)
!16 = distinct !DISubprogram(name: "compact_recurrence_merge", scope: !1, file: !1, line: 32, type: !4, scopeLine: 32, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!17 = !DILocation(line: 32, column: 3, scope: !16)
!18 = distinct !DISubprogram(name: "compact_recurrence_affine", scope: !1, file: !1, line: 42, type: !4, scopeLine: 42, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!19 = !DILocation(line: 42, column: 3, scope: !18)
!20 = distinct !DISubprogram(name: "compact_recurrence_runtime", scope: !1, file: !1, line: 52, type: !4, scopeLine: 52, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!21 = !DILocation(line: 52, column: 3, scope: !20)
!22 = distinct !DISubprogram(name: "compact_recurrence_enclosing", scope: !1, file: !1, line: 62, type: !4, scopeLine: 62, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!23 = !DILocation(line: 62, column: 3, scope: !22)
!24 = distinct !DISubprogram(name: "compact_recurrence_one", scope: !1, file: !1, line: 72, type: !4, scopeLine: 72, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!25 = !DILocation(line: 72, column: 3, scope: !24)
!26 = distinct !DISubprogram(name: "compact_recurrence_255", scope: !1, file: !1, line: 82, type: !4, scopeLine: 82, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!27 = !DILocation(line: 82, column: 3, scope: !26)
!28 = distinct !DISubprogram(name: "compact_recurrence_limit", scope: !1, file: !1, line: 92, type: !4, scopeLine: 92, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!29 = !DILocation(line: 92, column: 3, scope: !28)
