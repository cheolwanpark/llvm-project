; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @compose_reject_feedback(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @compose_reject_volatile(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @compose_reject_atomic(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @compose_reject_control(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
declare i32 @scalar_helper(i32) nounwind willreturn speculatable memory(none)

define void @compose_reject_feedback(ptr %a, ptr %fp, ptr %out, ptr %indices,
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
  %wp = getelementptr i32, ptr %out, i64 %iv
  %feedback.i = xor i32 %r0, %r1
  %feedback.d = fcmp oeq double %rd, %start
  %feedback = select i1 %feedback.d, i32 %feedback.i, i32 0
  store i32 %feedback, ptr %wp, align 4
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
  %dc = fneg double %dx
  store double %dc, ptr %dp, align 8
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

define void @compose_reject_volatile(ptr %a, ptr %fp, ptr %out, ptr %indices,
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
  %wp = getelementptr i32, ptr %out, i64 %iv
  store volatile i32 %state.next, ptr %wp, align 4
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
  %dc = fneg double %dx
  store double %dc, ptr %dp, align 8
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

define void @compose_reject_atomic(ptr %a, ptr %fp, ptr %out, ptr %indices,
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
  %wp = getelementptr i32, ptr %out, i64 %iv
  store atomic i32 %state.next, ptr %wp monotonic, align 4
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
  %dc = fneg double %dx
  store double %dc, ptr %dp, align 8
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

define void @compose_reject_control(ptr %a, ptr %fp, ptr %out, ptr %indices,
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
  %wp = getelementptr i32, ptr %out, i64 %iv
  store i32 %state.next, ptr %wp, align 4
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
  %dc = fneg double %dx
  store double %dc, ptr %dp, align 8
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
  %next = add nuw i64 %iv, 2
  %done = icmp uge i64 %next, %n
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
