; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=16 \
; RUN:   -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.strict 2> %t.strict.remarks
; RUN: FileCheck %s --implicit-check-not=scalar.fission < %t.strict
; RUN: FileCheck %s --check-prefix=REASON < %t.strict.remarks
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=16 \
; RUN:   -vplan-reduction-fission-allow-fp-reordering -pass-remarks-missed=vplan-reduction-fission \
; RUN:   -S %s -o %t.reordered 2> %t.reordered.remarks
; RUN: FileCheck %s --implicit-check-not=scalar.fission < %t.reordered
; RUN: FileCheck %s --check-prefix=REASON < %t.reordered.remarks
;
; One slot fits. Chunk scheduling still requires the exact canonical equality
; count and polarity, and cannot weaken producer closure, effect or FP rules.
; These siblings share the positive compact CFG; no benchmark input is changed.
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable
declare i32 @unsafe(i32) nounwind willreturn
declare double @llvm.experimental.constrained.fsub.f64(double, double, metadata, metadata)


; REASON: scalar-IR reduction fission rejected: scalar-scratch-limit
; CHECK-LABEL: define void @compact_chunk_reject_affine(
; CHECK: ret void
define void @compact_chunk_reject_affine(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                      ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  %limit = add nuw i64 %n, 7
  br label %loop
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

; REASON: scalar-IR reduction fission rejected: scalar-unsupported-exit
; CHECK-LABEL: define void @compact_chunk_reject_reverse_equality(
; CHECK: ret void
define void @compact_chunk_reject_reverse_equality(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                      ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  br label %loop
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

; REASON: scalar-IR reduction fission rejected: scalar-unsupported-exit
; CHECK-LABEL: define void @compact_chunk_reject_unsupported_control(
; CHECK: ret void
define void @compact_chunk_reject_unsupported_control(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                      ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  br label %loop
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

; REASON: scalar-IR reduction fission rejected: scalar-unsafe-call
; CHECK-LABEL: define void @compact_chunk_reject_unsafe_call(
; CHECK: ret void
define void @compact_chunk_reject_unsafe_call(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                      ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  br label %loop
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

; REASON: scalar-IR reduction fission rejected: scalar-non-simple-load
; CHECK-LABEL: define void @compact_chunk_reject_volatile(
; CHECK: ret void
define void @compact_chunk_reject_volatile(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                      ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  br label %loop
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

; REASON: scalar-IR reduction fission rejected: scalar-unsupported-instruction
; CHECK-LABEL: define void @compact_chunk_reject_store(
; CHECK: ret void
define void @compact_chunk_reject_store(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                      ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  br label %loop
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

; REASON: scalar-IR reduction fission rejected: scalar-strict-fp
; CHECK-LABEL: define void @compact_chunk_reject_strictfp(
; CHECK: ret void
define void @compact_chunk_reject_strictfp(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                      ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) strictfp {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  br label %loop
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

; REASON: scalar-IR reduction fission rejected: scalar-strict-fp
; CHECK-LABEL: define void @compact_chunk_reject_constrained(
; CHECK: ret void
define void @compact_chunk_reject_constrained(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                      ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  br label %loop
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

; REASON: scalar-IR reduction fission rejected: scalar-unsupported-recurrence
; CHECK-LABEL: define void @compact_chunk_reject_feedback(
; CHECK: %r0 = phi i32
; CHECK: %r1 = phi i32
; CHECK: %rd = phi double
; CHECK: ret void
define void @compact_chunk_reject_feedback(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                      ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  br label %loop
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
