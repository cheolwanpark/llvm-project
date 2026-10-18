; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -pass-remarks-missed=vplan-reduction-fission -pass-remarks=vplan-reduction-fission \
; RUN:   -S %s -o %t 2> %t.remarks
; RUN: FileCheck %s  < %t
; RUN: FileCheck %s --check-prefix=REASON < %t.remarks
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-allow-fp-reordering \
; RUN:   -S %s | FileCheck %s
;
; Integration: producer exports make the first feedback/export fixtures
; safely splittable. Their original IR is preserved. Only closed r1/rd (and
; r0 in the state-export sibling) move; every observed r0 remains in place.
; These are negative checks for illegal extraction, not whole-loop rejection.
; Original/transformed/independent comparisons also cover these exact functions.
; Effects, strictfp, constrained FP, incompatible streams and bounds still reject.
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable
declare i32 @effect(i32) nounwind willreturn
declare double @llvm.experimental.constrained.fsub.f64(double, double, metadata, metadata)

; REASON: scalar-recurrence.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; CHECK-LABEL: define void @recurrence_phi_feedback(
; CHECK: %prev = phi i32
; CHECK: %r0 = phi i32
; CHECK: scalar.fission.consumer.body:
; CHECK-NOT: %r0.consume =
; CHECK: %r1.consume = phi i32
; CHECK: %rd.consume = phi double
; CHECK: ret void
define void @recurrence_phi_feedback(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !20 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !21
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %prev = phi i32 [23, %preheader], [%state.next, %loop]
  %older = phi i32 [11, %preheader], [%prev, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %dolder = phi double [0.5, %preheader], [%dprev, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %raw = xor i32 %r0, %x
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dx, %dprev
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !21
exit:
  %result0 = phi i32 [17, %entry], [%u0, %loop]
  %result1 = phi i32 [-7, %entry], [%u1, %loop]
  %resultd = phi double [%start, %entry], [%ud, %loop]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %result0, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

; REASON: scalar-recurrence.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; CHECK-LABEL: define void @recurrence_update_feedback(
; CHECK: %prev = phi i32
; CHECK: %r0 = phi i32
; CHECK: scalar.fission.consumer.body:
; CHECK-NOT: %r0.consume =
; CHECK: %r1.consume = phi i32
; CHECK: %rd.consume = phi double
; CHECK: ret void
define void @recurrence_update_feedback(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !22 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !23
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %prev = phi i32 [23, %preheader], [%u0, %loop]
  %older = phi i32 [11, %preheader], [%prev, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %dolder = phi double [0.5, %preheader], [%dprev, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %raw = xor i32 %prev, %x
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dx, %dprev
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !23
exit:
  %result0 = phi i32 [17, %entry], [%u0, %loop]
  %result1 = phi i32 [-7, %entry], [%u1, %loop]
  %resultd = phi double [%start, %entry], [%ud, %loop]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %result0, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

; REASON: scalar-recurrence.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; CHECK-LABEL: define void @recurrence_other_reduction(
; CHECK: %prev = phi i32
; CHECK: %r0 = phi i32
; CHECK: scalar.fission.consumer.body:
; CHECK-NOT: %r0.consume =
; CHECK: %r1.consume = phi i32
; CHECK: %rd.consume = phi double
; CHECK: ret void
define void @recurrence_other_reduction(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !24 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !25
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %prev = phi i32 [23, %preheader], [%state.next, %loop]
  %older = phi i32 [11, %preheader], [%prev, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %dolder = phi double [0.5, %preheader], [%dprev, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %raw = xor i32 %prev, %x
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dx, %dprev
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %u0 = add i32 %r0, %c
  %u1 = add i32 %u0, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !25
exit:
  %result0 = phi i32 [17, %entry], [%u0, %loop]
  %result1 = phi i32 [-7, %entry], [%u1, %loop]
  %resultd = phi double [%start, %entry], [%ud, %loop]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %result0, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

; REASON: scalar-recurrence.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; CHECK-LABEL: define void @recurrence_address_feedback(
; CHECK: %prev = phi i32
; CHECK: %r0 = phi i32
; CHECK: scalar.fission.consumer.body:
; CHECK-NOT: %r0.consume =
; CHECK: %r1.consume = phi i32
; CHECK: %rd.consume = phi double
; CHECK: ret void
define void @recurrence_address_feedback(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !26 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !27
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %prev = phi i32 [23, %preheader], [%state.next, %loop]
  %older = phi i32 [11, %preheader], [%prev, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %dolder = phi double [0.5, %preheader], [%dprev, %loop]
  %feedback.index = zext i32 %r0 to i64
  %p = getelementptr i32, ptr %a, i64 %feedback.index
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %raw = xor i32 %prev, %x
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dx, %dprev
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !27
exit:
  %result0 = phi i32 [17, %entry], [%u0, %loop]
  %result1 = phi i32 [-7, %entry], [%u1, %loop]
  %resultd = phi double [%start, %entry], [%ud, %loop]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %result0, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

; REASON: scalar-recurrence.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; CHECK-LABEL: define void @recurrence_predicate_feedback(
; CHECK: %prev = phi i32
; CHECK: %r0 = phi i32
; CHECK: scalar.fission.consumer.body:
; CHECK-NOT: %r0.consume =
; CHECK: %r1.consume = phi i32
; CHECK: %rd.consume = phi double
; CHECK: ret void
define void @recurrence_predicate_feedback(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !28 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !29
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %older = phi i32 [11, %preheader], [%prev, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %dolder = phi double [0.5, %preheader], [%dprev, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %raw = xor i32 %prev, %x
  %bit = and i32 %r0, 1
  %choose = icmp ne i32 %bit, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @scalar_helper(i32 %raw)
  br label %latch
right:
  %rc = xor i32 %raw, 7
  %scaled = fmul double %dx, 0.5
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [%rc, %right]
  %delta = phi double [%dx, %left], [%scaled, %right]
  %dc = fsub double %delta, %dprev
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !29
exit:
  %result0 = phi i32 [17, %entry], [%u0, %latch]
  %result1 = phi i32 [-7, %entry], [%u1, %latch]
  %resultd = phi double [%start, %entry], [%ud, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %result0, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

; REASON: scalar-recurrence.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; CHECK-LABEL: define void @recurrence_partial_export(
; CHECK: %prev = phi i32
; CHECK: %r0 = phi i32
; CHECK: scalar.fission.consumer.body:
; CHECK-NOT: %r0.consume =
; CHECK: %r1.consume = phi i32
; CHECK: %rd.consume = phi double
; CHECK: %partial.exit = phi i32
; CHECK: %partial = add i32 %result0, %partial.exit
; CHECK: store i32 %partial, ptr %out
; CHECK: ret void
define void @recurrence_partial_export(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !30 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !31
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %prev = phi i32 [23, %preheader], [%state.next, %loop]
  %older = phi i32 [11, %preheader], [%prev, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %dolder = phi double [0.5, %preheader], [%dprev, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %raw = xor i32 %prev, %x
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dx, %dprev
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !31
exit:
  %result0 = phi i32 [17, %entry], [%u0, %loop]
  %result1 = phi i32 [-7, %entry], [%u1, %loop]
  %resultd = phi double [%start, %entry], [%ud, %loop]
  ; Export the pre-update accumulator; entry bypass uses its initial value.
  %partial.exit = phi i32 [17, %entry], [%r0, %loop]
  %o1 = getelementptr i32, ptr %out, i64 1
  %partial = add i32 %result0, %partial.exit
  store i32 %partial, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

; REASON: scalar-recurrence.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; CHECK-LABEL: define void @recurrence_state_export(
; CHECK: %prev = phi i32
; CHECK: scalar.fission.consumer.body:
; CHECK: %r1.consume = phi i32
; CHECK: %rd.consume = phi double
; CHECK: %state.exit = phi i32
; CHECK: %state.export = add i32 %result0, %state.exit
; CHECK: store i32 %state.export, ptr %out
; CHECK: ret void
define void @recurrence_state_export(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !32 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !33
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %prev = phi i32 [23, %preheader], [%state.next, %loop]
  %older = phi i32 [11, %preheader], [%prev, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %dolder = phi double [0.5, %preheader], [%dprev, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %raw = xor i32 %prev, %x
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dx, %dprev
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !33
exit:
  %result0 = phi i32 [17, %entry], [%u0, %loop]
  %result1 = phi i32 [-7, %entry], [%u1, %loop]
  %resultd = phi double [%start, %entry], [%ud, %loop]
  ; Retained producer state is observable even without an entered iteration.
  %state.exit = phi i32 [23, %entry], [%prev, %loop]
  %o1 = getelementptr i32, ptr %out, i64 1
  %state.export = add i32 %result0, %state.exit
  store i32 %state.export, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

; REASON: scalar-recurrence.c:12:3: scalar-IR reduction fission rejected: scalar-unsupported-instruction
; CHECK-LABEL: define void @recurrence_store(
; CHECK-NOT: scalar.fission
; CHECK: ret void
define void @recurrence_store(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !34 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !35
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %prev = phi i32 [23, %preheader], [%state.next, %loop]
  %older = phi i32 [11, %preheader], [%prev, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %dolder = phi double [0.5, %preheader], [%dprev, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  store i32 %x, ptr %p
  %raw = xor i32 %prev, %x
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dx, %dprev
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !35
exit:
  %result0 = phi i32 [17, %entry], [%u0, %loop]
  %result1 = phi i32 [-7, %entry], [%u1, %loop]
  %resultd = phi double [%start, %entry], [%ud, %loop]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %result0, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

; REASON: scalar-recurrence.c:12:3: scalar-IR reduction fission rejected: scalar-unsafe-call
; CHECK-LABEL: define void @recurrence_call(
; CHECK-NOT: scalar.fission
; CHECK: ret void
define void @recurrence_call(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !36 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !37
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %prev = phi i32 [23, %preheader], [%state.next, %loop]
  %older = phi i32 [11, %preheader], [%prev, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %dolder = phi double [0.5, %preheader], [%dprev, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %effect = call i32 @effect(i32 %x)
  %raw = xor i32 %prev, %x
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dx, %dprev
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !37
exit:
  %result0 = phi i32 [17, %entry], [%u0, %loop]
  %result1 = phi i32 [-7, %entry], [%u1, %loop]
  %resultd = phi double [%start, %entry], [%ud, %loop]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %result0, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

; REASON: scalar-recurrence.c:12:3: scalar-IR reduction fission rejected: {{non-constant-trip-count|scalar-scratch-limit}}
; CHECK-LABEL: define void @recurrence_unbounded(
; CHECK-NOT: scalar.fission
; CHECK: ret void
define void @recurrence_unbounded(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !38 {
entry:
  %valid = icmp ne i64 %n, 0
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !39
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %prev = phi i32 [23, %preheader], [%state.next, %loop]
  %older = phi i32 [11, %preheader], [%prev, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %dolder = phi double [0.5, %preheader], [%dprev, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %raw = xor i32 %prev, %x
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dx, %dprev
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !39
exit:
  %result0 = phi i32 [17, %entry], [%u0, %loop]
  %result1 = phi i32 [-7, %entry], [%u1, %loop]
  %resultd = phi double [%start, %entry], [%ud, %loop]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %result0, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

; REASON: scalar-recurrence.c:12:3: scalar-IR reduction fission rejected: scalar-scratch-limit
; CHECK-LABEL: define void @recurrence_over_capacity(
; CHECK-NOT: scalar.fission
; CHECK: ret void
define void @recurrence_over_capacity(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !40 {
entry:
  %valid = icmp ule i64 %n, 5462
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !41
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %prev = phi i32 [23, %preheader], [%state.next, %loop]
  %older = phi i32 [11, %preheader], [%prev, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %dolder = phi double [0.5, %preheader], [%dprev, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %raw = xor i32 %prev, %x
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dx, %dprev
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !41
exit:
  %result0 = phi i32 [17, %entry], [%u0, %loop]
  %result1 = phi i32 [-7, %entry], [%u1, %loop]
  %resultd = phi double [%start, %entry], [%ud, %loop]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %result0, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

; REASON: scalar-recurrence.c:12:3: scalar-IR reduction fission rejected: scalar-strict-fp
; CHECK-LABEL: define void @recurrence_strict(
; CHECK-NOT: scalar.fission
; CHECK: ret void
define void @recurrence_strict(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) strictfp !dbg !42 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !43
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %prev = phi i32 [23, %preheader], [%state.next, %loop]
  %older = phi i32 [11, %preheader], [%prev, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %dolder = phi double [0.5, %preheader], [%dprev, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %raw = xor i32 %prev, %x
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dx, %dprev
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !43
exit:
  %result0 = phi i32 [17, %entry], [%u0, %loop]
  %result1 = phi i32 [-7, %entry], [%u1, %loop]
  %resultd = phi double [%start, %entry], [%ud, %loop]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %result0, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

; REASON: scalar-recurrence.c:12:3: scalar-IR reduction fission rejected: scalar-strict-fp
; CHECK-LABEL: define void @recurrence_constrained(
; CHECK-NOT: scalar.fission
; CHECK: ret void
define void @recurrence_constrained(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !44 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !45
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %prev = phi i32 [23, %preheader], [%state.next, %loop]
  %older = phi i32 [11, %preheader], [%prev, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %dolder = phi double [0.5, %preheader], [%dprev, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %raw = xor i32 %prev, %x
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = call double @llvm.experimental.constrained.fsub.f64(double %dx, double %dprev, metadata !"round.dynamic", metadata !"fpexcept.strict")
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !45
exit:
  %result0 = phi i32 [17, %entry], [%u0, %loop]
  %result1 = phi i32 [-7, %entry], [%u1, %loop]
  %resultd = phi double [%start, %entry], [%ud, %loop]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %result0, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

; A producer-local delay alongside a compact reduction is deliberately outside
; this extension. Existing compact tests still cover their original contract.
; A split must extract at least one supported add/fadd accumulator.
; REASON: scalar-recurrence.c:12:3: scalar-IR reduction fission rejected: scalar-unsupported-recurrence
; CHECK-LABEL: define void @recurrence_no_extractable(
; CHECK-NOT: scalar.fission
; CHECK: ret void
define void @recurrence_no_extractable(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !46 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !47
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %prev = phi i32 [23, %preheader], [%state.next, %loop]
  %older = phi i32 [11, %preheader], [%prev, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %dolder = phi double [0.5, %preheader], [%dprev, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %raw = xor i32 %prev, %x
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dx, %dprev
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %u0 = xor i32 %r0, %c
  %u1 = xor i32 %c, %r1
  %ud = fsub double %rd, %dc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !47
exit:
  %result0 = phi i32 [17, %entry], [%u0, %loop]
  %result1 = phi i32 [-7, %entry], [%u1, %loop]
  %resultd = phi double [%start, %entry], [%ud, %loop]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %result0, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-recurrence.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = !DISubroutineType(types: !5)
!5 = !{}

!20 = distinct !DISubprogram(name: "recurrence_phi_feedback", scope: !1, file: !1, line: 12, type: !4, scopeLine: 12, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!21 = !DILocation(line: 12, column: 3, scope: !20)
!22 = distinct !DISubprogram(name: "recurrence_update_feedback", scope: !1, file: !1, line: 12, type: !4, scopeLine: 12, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!23 = !DILocation(line: 12, column: 3, scope: !22)
!24 = distinct !DISubprogram(name: "recurrence_other_reduction", scope: !1, file: !1, line: 12, type: !4, scopeLine: 12, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!25 = !DILocation(line: 12, column: 3, scope: !24)
!26 = distinct !DISubprogram(name: "recurrence_address_feedback", scope: !1, file: !1, line: 12, type: !4, scopeLine: 12, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!27 = !DILocation(line: 12, column: 3, scope: !26)
!28 = distinct !DISubprogram(name: "recurrence_predicate_feedback", scope: !1, file: !1, line: 12, type: !4, scopeLine: 12, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!29 = !DILocation(line: 12, column: 3, scope: !28)
!30 = distinct !DISubprogram(name: "recurrence_partial_export", scope: !1, file: !1, line: 12, type: !4, scopeLine: 12, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!31 = !DILocation(line: 12, column: 3, scope: !30)
!32 = distinct !DISubprogram(name: "recurrence_state_export", scope: !1, file: !1, line: 12, type: !4, scopeLine: 12, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!33 = !DILocation(line: 12, column: 3, scope: !32)
!34 = distinct !DISubprogram(name: "recurrence_store", scope: !1, file: !1, line: 12, type: !4, scopeLine: 12, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!35 = !DILocation(line: 12, column: 3, scope: !34)
!36 = distinct !DISubprogram(name: "recurrence_call", scope: !1, file: !1, line: 12, type: !4, scopeLine: 12, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!37 = !DILocation(line: 12, column: 3, scope: !36)
!38 = distinct !DISubprogram(name: "recurrence_unbounded", scope: !1, file: !1, line: 12, type: !4, scopeLine: 12, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!39 = !DILocation(line: 12, column: 3, scope: !38)
!40 = distinct !DISubprogram(name: "recurrence_over_capacity", scope: !1, file: !1, line: 12, type: !4, scopeLine: 12, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!41 = !DILocation(line: 12, column: 3, scope: !40)
!42 = distinct !DISubprogram(name: "recurrence_strict", scope: !1, file: !1, line: 12, type: !4, scopeLine: 12, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!43 = !DILocation(line: 12, column: 3, scope: !42)
!44 = distinct !DISubprogram(name: "recurrence_constrained", scope: !1, file: !1, line: 12, type: !4, scopeLine: 12, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!45 = !DILocation(line: 12, column: 3, scope: !44)
!46 = distinct !DISubprogram(name: "recurrence_no_extractable", scope: !1, file: !1, line: 12, type: !4, scopeLine: 12, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!47 = !DILocation(line: 12, column: 3, scope: !46)
