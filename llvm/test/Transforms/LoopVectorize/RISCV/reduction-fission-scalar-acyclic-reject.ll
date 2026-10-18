; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=259 -S %s | FileCheck %s
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-allow-fp-reordering \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=259 -S %s | FileCheck %s
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=259 \
; RUN:   -pass-remarks=vplan-reduction-fission -pass-remarks-missed=vplan-reduction-fission -disable-output %s 2>&1 | FileCheck %s --check-prefix=REASON
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -enable-vplan-reduction-fission \
; RUN:   -enable-vplan-native-path -pass-remarks=vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=259 \
; RUN:   -pass-remarks-missed=vplan-reduction-fission \
; RUN:   -S %s -o %t.cycle 2>%t.cycle.remarks
; RUN: FileCheck %s --check-prefix=CYCLE < %t.cycle.remarks
; RUN: FileCheck %s --check-prefix=CYCLEIR < %t.cycle
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=260 \
; RUN:   -S %s | FileCheck %s --check-prefix=EXPORT
;
; Generalized admission must not admit effects, feedback, partial-state exports,
; cycles or early exits. The two former larger-CFG compact rejections below now
; have one terminal update edge and accumulator-preserving bypasses. At 259
; bytes they reject for scratch; the 260-byte run requires their exact split.
; Loop::getStartLoc uses loop metadata or the preheader/header terminator,
; not the latch's debug location. Supply the original loop start at each
; preheader so every rejection retains its exact source location.

declare i32 @safe(i32) memory(none) nounwind willreturn speculatable
declare i32 @unsafe(i32) memory(read) nounwind willreturn speculatable

; REASON: scalar-acyclic-reject.c:12:3: scalar-IR reduction fission rejected: scalar-unsupported-cfg
; CHECK-LABEL: define i32 @reject_acyclic_early_exit(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
; CHECK-NOT: scalar.fission
; CHECK: }
define i32 @reject_acyclic_early_exit(ptr %a, i64 %n) !dbg !6 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !7
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @safe(i32 %x)
  br label %first.merge
right:
  %rc = xor i32 %x, 7
  br label %first.merge
first.merge:
  %first = phi i32 [%lc, %left], [%rc, %right]
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %left2, label %right2
left2:
  %pc = add i32 %first, 23
  %early = icmp eq i32 %x, 3
  br i1 %early, label %early.exit, label %latch
right2:
  %nc = sub i32 %first, 9
  br label %latch
latch:
  %c = phi i32 [%pc, %left2], [%nc, %right2]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !7
exit:
  ret i32 %update
early.exit:
  ret i32 0
bypass:
  ret i32 19
}

; The ordinary worklist only visits the internal natural loop. Explicit outer
; hints with the native worklist also exercise our acyclicity rejection for the
; original outer target, rather than requiring a remark for an unvisited loop.
; The outer loop metadata carries 22:3; the inner loop has its own 25:5 start.
; collectSupportedLoops selects only the explicitly hinted outer loop on the
; native path. Require its rejection and exclude any inner-loop fission remark.
; CYCLE-NOT: scalar-acyclic-reject.c:25:5:
; CYCLE: scalar-acyclic-reject.c:22:3: scalar-IR reduction fission rejected: scalar-unsupported-cfg
; CYCLE-NOT: scalar-acyclic-reject.c:25:5:
; CYCLEIR-LABEL: define i32 @reject_acyclic_internal_cycle(
; CYCLEIR-NOT: scalar.fission
; CYCLEIR: loop:
; CYCLEIR-NOT: scalar.fission
; CYCLEIR: %sum = phi i32 [ 19, %preheader ], [ %update, %latch ]
; CYCLEIR-NOT: scalar.fission
; CYCLEIR: br i1 %choose, label %left, label %right
; CYCLEIR-NOT: scalar.fission
; CYCLEIR: left2:
; CYCLEIR-NOT: scalar.fission
; CYCLEIR: %again = icmp eq i32 %x, 3
; CYCLEIR-NOT: scalar.fission
; CYCLEIR: br i1 %again, label %left2, label %{{[^, ]+}}
; CYCLEIR-NOT: scalar.fission
; CYCLEIR: latch:
; CYCLEIR-NOT: scalar.fission
; CYCLEIR: %update = add i32 %sum, %c
; CYCLEIR-NOT: scalar.fission
; CYCLEIR: br i1 %done, label %exit, label %loop
; CYCLEIR-NOT: scalar.fission
; CYCLEIR: ret i32
; CYCLEIR-NOT: scalar.fission
; CYCLEIR: }
; CHECK-LABEL: define i32 @reject_acyclic_internal_cycle(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
; CHECK-NOT: scalar.fission
; CHECK: }
define i32 @reject_acyclic_internal_cycle(ptr %a, i64 %n) !dbg !8 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !9
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @safe(i32 %x)
  br label %first.merge
right:
  %rc = xor i32 %x, 7
  br label %first.merge
first.merge:
  %first = phi i32 [%lc, %left], [%rc, %right]
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %left2, label %right2
left2:
  %pc = add i32 %first, 23
  %again = icmp eq i32 %x, 3
  br i1 %again, label %left2, label %latch, !dbg !33, !llvm.loop !34
right2:
  %nc = sub i32 %first, 9
  br label %latch
latch:
  %c = phi i32 [%pc, %left2], [%nc, %right2]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !9, !llvm.loop !30
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-acyclic-reject.c:32:3: scalar-IR reduction fission rejected: scalar-unsupported-recurrence
; CHECK-LABEL: define i32 @reject_acyclic_predicate(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
; CHECK-NOT: scalar.fission
; CHECK: }
define i32 @reject_acyclic_predicate(ptr %a, i64 %n) !dbg !10 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !11
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %sum, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @safe(i32 %x)
  br label %first.merge
right:
  %rc = xor i32 %x, 7
  br label %first.merge
first.merge:
  %first = phi i32 [%lc, %left], [%rc, %right]
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %left2, label %right2
left2:
  %pc = add i32 %first, 23
  br label %latch
right2:
  %nc = sub i32 %first, 9
  br label %latch
latch:
  %c = phi i32 [%pc, %left2], [%nc, %right2]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !11
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-acyclic-reject.c:42:3: scalar-IR reduction fission rejected: scalar-unsupported-recurrence
; CHECK-LABEL: define i32 @reject_acyclic_contribution(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
; CHECK-NOT: scalar.fission
; CHECK: }
define i32 @reject_acyclic_contribution(ptr %a, i64 %n) !dbg !12 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !13
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @safe(i32 %x)
  br label %first.merge
right:
  %rc = xor i32 %x, 7
  br label %first.merge
first.merge:
  %first = phi i32 [%lc, %left], [%rc, %right]
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %left2, label %right2
left2:
  %pc = add i32 %first, %sum
  br label %latch
right2:
  %nc = sub i32 %first, 9
  br label %latch
latch:
  %c = phi i32 [%pc, %left2], [%nc, %right2]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !13
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-acyclic-reject.c:52:3: scalar-IR reduction fission rejected: scalar-reduction-feedback
; CHECK-LABEL: define i32 @reject_acyclic_result_feedback(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
; CHECK-NOT: scalar.fission
; CHECK: }
define i32 @reject_acyclic_result_feedback(ptr %a, i64 %n) !dbg !14 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !15
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @safe(i32 %x)
  br label %first.merge
right:
  %rc = xor i32 %x, 7
  br label %first.merge
first.merge:
  %first = phi i32 [%lc, %left], [%rc, %right]
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %left2, label %right2
left2:
  %pc = add i32 %first, 23
  br label %latch
right2:
  %nc = sub i32 %first, 9
  br label %latch
latch:
  %c = phi i32 [%pc, %left2], [%nc, %right2]
  %update = add i32 %sum, %c
  %observer = xor i32 %update, %x
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !15
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; Final latch-merged values are now legal exports. Keep this exact source
; function as a scratch rejection at 259 and a positive case at 260 bytes.
; Serial/nested mixed exports are executed by scalar-export-controls.ll.
; REASON: scalar-acyclic-reject.c:62:3: scalar-IR reduction fission rejected: scalar-scratch-limit
; CHECK-LABEL: define i32 @reject_acyclic_liveout(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
; CHECK-NOT: scalar.fission
; CHECK: }
; EXPORT-LABEL: define i32 @reject_acyclic_liveout(
; EXPORT: alloca [65 x i32]
; EXPORT: %c.fission.export = phi i32 [ %c, %latch ]
; EXPORT: %[[FINAL:.*]] = phi i32 [ %c.fission.export, %scalar.fission.consumer.body ]
; EXPORT: ret i32 %[[FINAL]]
define i32 @reject_acyclic_liveout(ptr %a, i64 %n) !dbg !16 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !17
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @safe(i32 %x)
  br label %first.merge
right:
  %rc = xor i32 %x, 7
  br label %first.merge
first.merge:
  %first = phi i32 [%lc, %left], [%rc, %right]
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %left2, label %right2
left2:
  %pc = add i32 %first, 23
  br label %latch
right2:
  %nc = sub i32 %first, 9
  br label %latch
latch:
  %c = phi i32 [%pc, %left2], [%nc, %right2]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !17
exit:
  ret i32 %c
bypass:
  ret i32 19
}

; REASON: scalar-acyclic-reject.c:72:3: scalar-IR reduction fission rejected: scalar-unsupported-instruction
; CHECK-LABEL: define i32 @reject_acyclic_store(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
; CHECK-NOT: scalar.fission
; CHECK: }
define i32 @reject_acyclic_store(ptr %a, i64 %n) !dbg !18 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !19
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @safe(i32 %x)
  br label %first.merge
right:
  %rc = xor i32 %x, 7
  br label %first.merge
first.merge:
  %first = phi i32 [%lc, %left], [%rc, %right]
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %left2, label %right2
left2:
  %pc = add i32 %first, 23
  br label %latch
right2:
  store i32 %x, ptr %p
  %nc = sub i32 %first, 9
  br label %latch
latch:
  %c = phi i32 [%pc, %left2], [%nc, %right2]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !19
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-acyclic-reject.c:82:3: scalar-IR reduction fission rejected: scalar-unsafe-call
; CHECK-LABEL: define i32 @reject_acyclic_unsafe_call(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
; CHECK-NOT: scalar.fission
; CHECK: }
define i32 @reject_acyclic_unsafe_call(ptr %a, i64 %n) !dbg !20 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !21
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @unsafe(i32 %x)
  br label %first.merge
right:
  %rc = xor i32 %x, 7
  br label %first.merge
first.merge:
  %first = phi i32 [%lc, %left], [%rc, %right]
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %left2, label %right2
left2:
  %pc = add i32 %first, 23
  br label %latch
right2:
  %nc = sub i32 %first, 9
  br label %latch
latch:
  %c = phi i32 [%pc, %left2], [%nc, %right2]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !21
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-acyclic-reject.c:92:3: scalar-IR reduction fission rejected: scalar-unsupported-recurrence
; CHECK-LABEL: define i32 @reject_acyclic_header_update(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
; CHECK-NOT: scalar.fission
; CHECK: }
define i32 @reject_acyclic_header_update(ptr %a, i64 %n) !dbg !22 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !23
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %update = add i32 %sum, %x
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @safe(i32 %x)
  br label %first.merge
right:
  %rc = xor i32 %x, 7
  br label %first.merge
first.merge:
  %first = phi i32 [%lc, %left], [%rc, %right]
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %left2, label %right2
left2:
  %pc = add i32 %first, 23
  br label %latch
right2:
  %nc = sub i32 %first, 9
  br label %latch
latch:
  %c = phi i32 [%pc, %left2], [%nc, %right2]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !23
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-acyclic-reject.c:102:3: scalar-IR reduction fission rejected: scalar-unsupported-cfg
; CHECK-LABEL: define i32 @reject_acyclic_switch(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
; CHECK-NOT: scalar.fission
; CHECK: }
define i32 @reject_acyclic_switch(ptr %a, i64 %n) !dbg !24 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !25
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @safe(i32 %x)
  br label %first.merge
right:
  %rc = xor i32 %x, 7
  br label %first.merge
first.merge:
  %first = phi i32 [%lc, %left], [%rc, %right]
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  switch i1 %second, label %left2 [ i1 false, label %right2 ]
left2:
  %pc = add i32 %first, 23
  br label %latch
right2:
  %nc = sub i32 %first, 9
  br label %latch
latch:
  %c = phi i32 [%pc, %left2], [%nc, %right2]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !25
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; Canonical terminal participation now chunks at C=64/B=256 (259 ceiling).
; REASON: scalar-acyclic-reject.c:112:3: split scalar-IR reduction loop; {{.*}}scratch capacity 64, scratch bytes 256
; CHECK-LABEL: define i32 @reject_acyclic_conditional_serial(
; CHECK: alloca [64 x i32]
; CHECK: scalar.fission.chunk:
; CHECK: scalar.fission.consumer.guard:
; CHECK: scalar.fission.consumer.exit:
; CHECK: ret i32
; EXPORT-LABEL: define i32 @reject_acyclic_conditional_serial(
; EXPORT: left2:
; EXPORT: %fission.participating.next = add nuw i64 %fission.participating, 1
; EXPORT: store i32 %first,
; EXPORT: br label %latch
; EXPORT: scalar.fission.consumer.guard:
; EXPORT: %fission.empty = icmp eq i64 %fission.participating.count, 0
; EXPORT: ret i32
define i32 @reject_acyclic_conditional_serial(ptr %a, i64 %n) !dbg !26 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !27
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @safe(i32 %x)
  br label %first.merge
right:
  %rc = xor i32 %x, 7
  br label %first.merge
first.merge:
  %first = phi i32 [%lc, %left], [%rc, %right]
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %left2, label %right2
left2:
  %pc = add i32 %sum, %first
  br label %latch
right2:
  %nc = sub i32 %first, 9
  br label %latch
latch:
  %merged = phi i32 [%pc, %left2], [%sum, %right2]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !27
exit:
  ret i32 %merged
bypass:
  ret i32 19
}

; Canonical terminal participation now chunks at C=64/B=256 (259 ceiling).
; REASON: scalar-acyclic-reject.c:122:3: split scalar-IR reduction loop; {{.*}}scratch capacity 64, scratch bytes 256
; CHECK-LABEL: define i32 @reject_acyclic_conditional_nested(
; CHECK: alloca [64 x i32]
; CHECK: scalar.fission.chunk:
; CHECK: scalar.fission.consumer.guard:
; CHECK: scalar.fission.consumer.exit:
; CHECK: ret i32
; EXPORT-LABEL: define i32 @reject_acyclic_conditional_nested(
; EXPORT: active.merge:
; EXPORT: %active = phi i32
; EXPORT: %fission.participating.next = add nuw i64 %fission.participating, 1
; EXPORT: store i32 %active,
; EXPORT: br label %latch
; EXPORT: scalar.fission.consumer.guard:
; EXPORT: %fission.empty = icmp eq i64 %fission.participating.count, 0
; EXPORT: ret i32
define i32 @reject_acyclic_conditional_nested(ptr %a, i64 %n) !dbg !28 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !29
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch
left:
  %lc = call i32 @safe(i32 %x)
  br label %first.merge
first.merge:
  %first = phi i32 [%lc, %left]
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %left2, label %right2
left2:
  %pc = add i32 %first, 23
  br label %active.merge
right2:
  %nc = sub i32 %first, 9
  br label %active.merge
active.merge:
  %active = phi i32 [%pc, %left2], [%nc, %right2]
  %update = add i32 %sum, %active
  br label %latch
latch:
  %merged = phi i32 [%update, %active.merge], [%sum, %loop]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !29
exit:
  ret i32 %merged
bypass:
  ret i32 19
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-acyclic-reject.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = !DISubroutineType(types: !5)
!5 = !{}
!6 = distinct !DISubprogram(name: "reject_acyclic_early_exit", scope: !1, file: !1, line: 10, type: !4, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!7 = !DILocation(line: 12, column: 3, scope: !6)
!8 = distinct !DISubprogram(name: "reject_acyclic_internal_cycle", scope: !1, file: !1, line: 20, type: !4, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!9 = !DILocation(line: 22, column: 3, scope: !8)
!10 = distinct !DISubprogram(name: "reject_acyclic_predicate", scope: !1, file: !1, line: 30, type: !4, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 32, column: 3, scope: !10)
!12 = distinct !DISubprogram(name: "reject_acyclic_contribution", scope: !1, file: !1, line: 40, type: !4, scopeLine: 40, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 42, column: 3, scope: !12)
!14 = distinct !DISubprogram(name: "reject_acyclic_result_feedback", scope: !1, file: !1, line: 50, type: !4, scopeLine: 50, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!15 = !DILocation(line: 52, column: 3, scope: !14)
!16 = distinct !DISubprogram(name: "reject_acyclic_liveout", scope: !1, file: !1, line: 60, type: !4, scopeLine: 60, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!17 = !DILocation(line: 62, column: 3, scope: !16)
!18 = distinct !DISubprogram(name: "reject_acyclic_store", scope: !1, file: !1, line: 70, type: !4, scopeLine: 70, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!19 = !DILocation(line: 72, column: 3, scope: !18)
!20 = distinct !DISubprogram(name: "reject_acyclic_unsafe_call", scope: !1, file: !1, line: 80, type: !4, scopeLine: 80, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!21 = !DILocation(line: 82, column: 3, scope: !20)
!22 = distinct !DISubprogram(name: "reject_acyclic_header_update", scope: !1, file: !1, line: 90, type: !4, scopeLine: 90, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!23 = !DILocation(line: 92, column: 3, scope: !22)
!24 = distinct !DISubprogram(name: "reject_acyclic_switch", scope: !1, file: !1, line: 100, type: !4, scopeLine: 100, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!25 = !DILocation(line: 102, column: 3, scope: !24)
!26 = distinct !DISubprogram(name: "reject_acyclic_conditional_serial", scope: !1, file: !1, line: 110, type: !4, scopeLine: 110, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!27 = !DILocation(line: 112, column: 3, scope: !26)
!28 = distinct !DISubprogram(name: "reject_acyclic_conditional_nested", scope: !1, file: !1, line: 120, type: !4, scopeLine: 120, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!29 = !DILocation(line: 122, column: 3, scope: !28)
!30 = distinct !{!30, !9, !31, !32}
!31 = !{!"llvm.loop.vectorize.enable", i1 true}
!32 = !{!"llvm.loop.vectorize.width", i32 2}
!33 = !DILocation(line: 25, column: 5, scope: !8)
!34 = distinct !{!34, !33}
