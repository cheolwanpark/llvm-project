; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission -force-vector-width=1 \
; RUN:   -force-vector-interleave=0 -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=112 -pass-remarks=vplan-reduction-fission \
; RUN:   -S %s -o %t.scalar 2> %t.remarks
; RUN: FileCheck %s --check-prefix=SCALAR < %t.scalar
; RUN: FileCheck %s --check-prefix=NINE < %t.remarks
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission -force-vector-width=1 \
; RUN:   -force-vector-interleave=0 -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=15 -pass-remarks=vplan-reduction-fission \
; RUN:   -pass-remarks-missed=vplan-reduction-fission -disable-output %s 2>&1 | FileCheck %s --check-prefix=REJECT
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission -force-vector-width=1 \
; RUN:   -force-vector-interleave=0 -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=16 -pass-remarks=vplan-reduction-fission \
; RUN:   -pass-remarks-missed=vplan-reduction-fission -disable-output %s 2>&1 | FileCheck %s --check-prefix=ONE
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission -force-vector-width=1 \
; RUN:   -force-vector-interleave=0 -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=111 -pass-remarks=vplan-reduction-fission \
; RUN:   -pass-remarks-missed=vplan-reduction-fission -disable-output %s 2>&1 | FileCheck %s --check-prefix=EIGHT
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission -force-vector-width=1 \
; RUN:   -force-vector-interleave=0 -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=784 -pass-remarks=vplan-reduction-fission \
; RUN:   -pass-remarks-missed=vplan-reduction-fission -disable-output %s 2>&1 | FileCheck %s --check-prefix=FULL
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission -force-vector-width=4 \
; RUN:   -force-vector-interleave=1 -scalable-vectorization=always -hints-allow-reordering=false \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=112 -S %s -o %t.evl
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.evl -o /dev/null
;
; Each original acyclic path reaches the latch once, where the unconditional
; contribution streams are written. Includes serial and nested diamonds,
; guarded division and branch-local FP loads, simultaneous prev -> older state,
; branch predicates using retained state and distinct final current/next/IV
; exports. The final function keeps the already recognized header updates.
; The i32 contribution is shared by two sums; double stays ordered under both
; policies. No additional FP flags or helper/errno assumptions are introduced.
; Padded bytes = alignTo(4*C,8)+8*C: C=1/8/9/16/65 -> 16/96/112/192/784.
; The executable driver covers every N=0..65 plus invalid guards, both policies,
; scalar/vector tails, once/twice LV and independent original-order references.
; EVL receives separate uninstrumented RVV machine verification.

declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

; NINE: scalar-chunk-cfg.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 9, scratch bytes 112, producer live-outs 8, chunked schedule, trip bound 65
; NINE-SAME: scratch store bytes/iteration 12, scratch load bytes/iteration 12, producer reread bytes/iteration 0, duplicated producer instructions 0, producer state carries 3
; ONE: scalar-chunk-cfg.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 1, scratch bytes 16
; EIGHT: scalar-chunk-cfg.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 8, scratch bytes 96
; FULL: scalar-chunk-cfg.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; REJECT: scalar-chunk-cfg.c:12:3: scalar-IR reduction fission rejected: scalar-scratch-limit
; SCALAR-LABEL: define void @chunk_cfg_diamond(
; SCALAR: alloca [9 x i32]
; SCALAR: alloca [9 x double]
; SCALAR: %older.chunk.carry = phi i32 [ -11, %preheader ], [ %older.chunk.backedge, %scalar.fission.chunk.latch ]
; SCALAR: loop:
; SCALAR: %older = phi i32 [ %older.chunk.carry, %scalar.fission.producer.ph ], [ %prev, %latch ]
; SCALAR: br i1 %choose, label %left, label %right
; SCALAR: left:
; SCALAR: sdiv i32 840, %x
; SCALAR: right:
; SCALAR: load double, ptr %dp
; SCALAR: latch:
; SCALAR: store i32 %c
; SCALAR: store double %dc
; SCALAR: scalar.fission.consumer.ph:
; SCALAR-DAG: %older.chunk.backedge = phi i32 [ %prev, %latch ]
; SCALAR-DAG: %prev.fission.export = phi i32 [ %prev, %latch ]
; SCALAR-DAG: %state.next.fission.export = phi i32 [ %state.next, %latch ]
; SCALAR: ret void

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

; NINE: scalar-chunk-cfg.c:22:3: split scalar-IR reduction loop; {{.*}}scratch capacity 9, scratch bytes 112, producer live-outs 8, chunked schedule, trip bound 65
; NINE-SAME: scratch store bytes/iteration 12, scratch load bytes/iteration 12, producer reread bytes/iteration 0, duplicated producer instructions 0, producer state carries 3
; ONE: scalar-chunk-cfg.c:22:3: split scalar-IR reduction loop; {{.*}}scratch capacity 1, scratch bytes 16
; EIGHT: scalar-chunk-cfg.c:22:3: split scalar-IR reduction loop; {{.*}}scratch capacity 8, scratch bytes 96
; FULL: scalar-chunk-cfg.c:22:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; REJECT: scalar-chunk-cfg.c:22:3: scalar-IR reduction fission rejected: scalar-scratch-limit
; SCALAR-LABEL: define void @chunk_cfg_serial(
; SCALAR: alloca [9 x i32]
; SCALAR: alloca [9 x double]
; SCALAR: %older.chunk.carry = phi i32 [ -11, %preheader ], [ %older.chunk.backedge, %scalar.fission.chunk.latch ]
; SCALAR: loop:
; SCALAR: %older = phi i32 [ %older.chunk.carry, %scalar.fission.producer.ph ], [ %prev, %latch ]
; SCALAR: br i1 %choose, label %left, label %right
; SCALAR: left:
; SCALAR: sdiv i32 840, %x
; SCALAR: right:
; SCALAR: load double, ptr %dp
; SCALAR: latch:
; SCALAR: store i32 %c
; SCALAR: store double %dc
; SCALAR: scalar.fission.consumer.ph:
; SCALAR-DAG: %older.chunk.backedge = phi i32 [ %prev, %latch ]
; SCALAR-DAG: %prev.fission.export = phi i32 [ %prev, %latch ]
; SCALAR-DAG: %state.next.fission.export = phi i32 [ %state.next, %latch ]
; SCALAR: ret void

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

; NINE: scalar-chunk-cfg.c:32:3: split scalar-IR reduction loop; {{.*}}scratch capacity 9, scratch bytes 112, producer live-outs 8, chunked schedule, trip bound 65
; NINE-SAME: scratch store bytes/iteration 12, scratch load bytes/iteration 12, producer reread bytes/iteration 0, duplicated producer instructions 0, producer state carries 3
; ONE: scalar-chunk-cfg.c:32:3: split scalar-IR reduction loop; {{.*}}scratch capacity 1, scratch bytes 16
; EIGHT: scalar-chunk-cfg.c:32:3: split scalar-IR reduction loop; {{.*}}scratch capacity 8, scratch bytes 96
; FULL: scalar-chunk-cfg.c:32:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; REJECT: scalar-chunk-cfg.c:32:3: scalar-IR reduction fission rejected: scalar-scratch-limit
; SCALAR-LABEL: define void @chunk_cfg_nested(
; SCALAR: alloca [9 x i32]
; SCALAR: alloca [9 x double]
; SCALAR: %older.chunk.carry = phi i32 [ -11, %preheader ], [ %older.chunk.backedge, %scalar.fission.chunk.latch ]
; SCALAR: loop:
; SCALAR: %older = phi i32 [ %older.chunk.carry, %scalar.fission.producer.ph ], [ %prev, %latch ]
; SCALAR: br i1 %choose, label %left, label %right
; SCALAR: left:
; SCALAR: sdiv i32 840, %x
; SCALAR: right:
; SCALAR: load double, ptr %dp
; SCALAR: latch:
; SCALAR: store i32 %c
; SCALAR: store double %dc
; SCALAR: scalar.fission.consumer.ph:
; SCALAR-DAG: %older.chunk.backedge = phi i32 [ %prev, %latch ]
; SCALAR-DAG: %prev.fission.export = phi i32 [ %prev, %latch ]
; SCALAR-DAG: %state.next.fission.export = phi i32 [ %state.next, %latch ]
; SCALAR: ret void

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

; NINE: scalar-chunk-cfg.c:42:3: split scalar-IR reduction loop; {{.*}}scratch capacity 9, scratch bytes 112, producer live-outs 8, chunked schedule, trip bound 65
; NINE-SAME: scratch store bytes/iteration 12, scratch load bytes/iteration 12, producer reread bytes/iteration 0, duplicated producer instructions 0, producer state carries 3
; ONE: scalar-chunk-cfg.c:42:3: split scalar-IR reduction loop; {{.*}}scratch capacity 1, scratch bytes 16
; EIGHT: scalar-chunk-cfg.c:42:3: split scalar-IR reduction loop; {{.*}}scratch capacity 8, scratch bytes 96
; FULL: scalar-chunk-cfg.c:42:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; REJECT: scalar-chunk-cfg.c:42:3: scalar-IR reduction fission rejected: scalar-scratch-limit
; SCALAR-LABEL: define void @chunk_cfg_header(
; SCALAR: alloca [9 x i32]
; SCALAR: alloca [9 x double]
; SCALAR: %older.chunk.carry = phi i32 [ -11, %preheader ], [ %older.chunk.backedge, %scalar.fission.chunk.latch ]
; SCALAR: loop:
; SCALAR: %older = phi i32 [ %older.chunk.carry, %scalar.fission.producer.ph ], [ %prev, %latch ]
; SCALAR: br i1 %choose, label %left, label %right
; SCALAR: left:
; SCALAR: sdiv i32 840, %x
; SCALAR: right:
; SCALAR: load double, ptr %dp
; SCALAR: latch:
; SCALAR: store i32 %c
; SCALAR: store double %dc
; SCALAR: scalar.fission.consumer.ph:
; SCALAR-DAG: %older.chunk.backedge = phi i32 [ %prev, %latch ]
; SCALAR-DAG: %prev.fission.export = phi i32 [ %prev, %latch ]
; SCALAR-DAG: %state.next.fission.export = phi i32 [ %state.next, %latch ]
; SCALAR: ret void

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
