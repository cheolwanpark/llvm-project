; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=16 \
; RUN:   -pass-remarks=vplan-reduction-fission -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.strict 2> %t.strict.remarks
; RUN: FileCheck %s  < %t.strict
; RUN: FileCheck %s --check-prefix=REASON < %t.strict.remarks
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=16 \
; RUN:   -vplan-reduction-fission-allow-fp-reordering -pass-remarks=vplan-reduction-fission -pass-remarks-missed=vplan-reduction-fission \
; RUN:   -S %s -o %t.reordered 2> %t.reordered.remarks
; RUN: FileCheck %s  < %t.reordered
; RUN: FileCheck %s --check-prefix=REASON < %t.reordered.remarks
;
; One padded mixed slot fits. Affine control now uses the fallback, keeping
; original control and empty-participation bypasses. Other closure/effect/FP
; and unavailable-bound rejection checks remain.
; These siblings share the positive compact CFG; no benchmark input is changed.
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable
declare i32 @unsafe(i32) nounwind willreturn
declare double @llvm.experimental.constrained.fsub.f64(double, double, metadata, metadata)


; REASON: scalar-compact-chunks-reject.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 1, scratch bytes 16
; CHECK-LABEL: define void @compact_chunk_reject_affine(
; CHECK: alloca [1 x i32]
; CHECK: alloca [1 x double]
; CHECK: scalar.fission.chunk:
; CHECK: %fission.producer.continue = phi i1
; CHECK: %fission.consumer.count = freeze i64 %fission.participating.count
; CHECK: ret void
define void @compact_chunk_reject_affine(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                      ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !10 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  %limit = add nuw i64 %n, 7
  br label %loop, !dbg !11
loop:
  %iv = phi i64 [7, %preheader], [%next, %latch]
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
  %done = icmp eq i64 %next, %limit
  br i1 %done, label %producer.exit, label %loop
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

; The reversed exit has no admitted finite count; this proof fails before
; chunk scheduling checks the exit polarity. Unsupported control below has
; its own, independent scalar-unsupported-exit assertion.
; REASON: scalar-compact-chunks-reject.c:22:3: scalar-IR reduction fission rejected: non-constant-trip-count
; CHECK-LABEL: define void @compact_chunk_reject_reverse_equality(
; CHECK-NOT: scalar.fission
; CHECK: ret void
define void @compact_chunk_reject_reverse_equality(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
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
  br i1 %done, label %loop, label %producer.exit
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

; REASON: scalar-compact-chunks-reject.c:32:3: scalar-IR reduction fission rejected: scalar-unsupported-exit
; CHECK-LABEL: define void @compact_chunk_reject_unsupported_control(
; CHECK-NOT: scalar.fission
; CHECK: ret void
define void @compact_chunk_reject_unsupported_control(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
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
  %masked = and i64 %next, 127
  %done = icmp eq i64 %masked, %n
  br i1 %done, label %producer.exit, label %loop
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

; REASON: scalar-compact-chunks-reject.c:42:3: scalar-IR reduction fission rejected: scalar-unsafe-call
; CHECK-LABEL: define void @compact_chunk_reject_unsafe_call(
; CHECK-NOT: scalar.fission
; CHECK: ret void
define void @compact_chunk_reject_unsafe_call(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
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
  %c = call i32 @unsafe(i32 %raw)
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
  br i1 %done, label %producer.exit, label %loop
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

; REASON: scalar-compact-chunks-reject.c:52:3: scalar-IR reduction fission rejected: scalar-non-simple-load
; CHECK-LABEL: define void @compact_chunk_reject_volatile(
; CHECK-NOT: scalar.fission
; CHECK: ret void
define void @compact_chunk_reject_volatile(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                      ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !18 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !19
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
  %dx = load volatile double, ptr %dp, align 8
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
  br i1 %done, label %producer.exit, label %loop
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

; REASON: scalar-compact-chunks-reject.c:62:3: scalar-IR reduction fission rejected: scalar-unsupported-instruction
; CHECK-LABEL: define void @compact_chunk_reject_store(
; CHECK-NOT: scalar.fission
; CHECK: ret void
define void @compact_chunk_reject_store(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                      ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !20 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !21
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
  store i32 %x, ptr %out, align 4
  br label %latch
latch:
  %m0 = phi i32 [%r0, %right], [%u0, %left]
  %m1 = phi i32 [%r1, %right], [%u1, %left]
  %md = phi double [%rd, %right], [%ud, %left]
  %last.dc = phi double [%start, %right], [%dc, %left]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %producer.exit, label %loop
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

; REASON: scalar-compact-chunks-reject.c:72:3: scalar-IR reduction fission rejected: scalar-strict-fp
; CHECK-LABEL: define void @compact_chunk_reject_strictfp(
; CHECK-NOT: scalar.fission
; CHECK: ret void
define void @compact_chunk_reject_strictfp(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                      ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) strictfp !dbg !22 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !23
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
  br i1 %done, label %producer.exit, label %loop
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

; REASON: scalar-compact-chunks-reject.c:82:3: scalar-IR reduction fission rejected: scalar-strict-fp
; CHECK-LABEL: define void @compact_chunk_reject_constrained(
; CHECK-NOT: scalar.fission
; CHECK: ret void
define void @compact_chunk_reject_constrained(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                      ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !24 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !25
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
  %dc = call double @llvm.experimental.constrained.fsub.f64(double %dx, double %as.double, metadata !"round.dynamic", metadata !"fpexcept.strict")
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
  br i1 %done, label %producer.exit, label %loop
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

; REASON: scalar-compact-chunks-reject.c:92:3: scalar-IR reduction fission rejected: scalar-unsupported-recurrence
; CHECK-LABEL: define void @compact_chunk_reject_feedback(
; CHECK: %r0 = phi i32
; CHECK: %r1 = phi i32
; CHECK: %rd = phi double
; CHECK: ret void
define void @compact_chunk_reject_feedback(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                      ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !26 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !27
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %older = phi i32 [-11, %preheader], [%prev, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %observed = add i32 %r0, %r1
  %observed.fp = fptoui double %rd to i32
  %observed.all = add i32 %observed, %observed.fp
  %state.next = add i32 %x, %observed.all
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
  br i1 %done, label %producer.exit, label %loop
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

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, producer: "fission test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-compact-chunks-reject.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!5 = !DISubroutineType(types: !6)
!6 = !{}
!26 = distinct !DISubprogram(name: "compact_chunk_reject_feedback", scope: !1, file: !1, line: 90, type: !5, scopeLine: 90, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!27 = !DILocation(line: 92, column: 3, scope: !26)
!24 = distinct !DISubprogram(name: "compact_chunk_reject_constrained", scope: !1, file: !1, line: 80, type: !5, scopeLine: 80, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!25 = !DILocation(line: 82, column: 3, scope: !24)
!22 = distinct !DISubprogram(name: "compact_chunk_reject_strictfp", scope: !1, file: !1, line: 70, type: !5, scopeLine: 70, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!23 = !DILocation(line: 72, column: 3, scope: !22)
!20 = distinct !DISubprogram(name: "compact_chunk_reject_store", scope: !1, file: !1, line: 60, type: !5, scopeLine: 60, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!21 = !DILocation(line: 62, column: 3, scope: !20)
!18 = distinct !DISubprogram(name: "compact_chunk_reject_volatile", scope: !1, file: !1, line: 50, type: !5, scopeLine: 50, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!19 = !DILocation(line: 52, column: 3, scope: !18)
!16 = distinct !DISubprogram(name: "compact_chunk_reject_unsafe_call", scope: !1, file: !1, line: 40, type: !5, scopeLine: 40, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!17 = !DILocation(line: 42, column: 3, scope: !16)
!14 = distinct !DISubprogram(name: "compact_chunk_reject_unsupported_control", scope: !1, file: !1, line: 30, type: !5, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!15 = !DILocation(line: 32, column: 3, scope: !14)
!12 = distinct !DISubprogram(name: "compact_chunk_reject_reverse_equality", scope: !1, file: !1, line: 20, type: !5, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 22, column: 3, scope: !12)
!10 = distinct !DISubprogram(name: "compact_chunk_reject_affine", scope: !1, file: !1, line: 10, type: !5, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 12, column: 3, scope: !10)
