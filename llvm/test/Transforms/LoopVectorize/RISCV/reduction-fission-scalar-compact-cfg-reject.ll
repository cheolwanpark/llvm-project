; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -pass-remarks-missed=vplan-reduction-fission \
; RUN:   -S %s -o %t.strict 2> %t.strict.remarks
; RUN: FileCheck %s --check-prefix=IR --implicit-check-not=scalar.fission < %t.strict
; RUN: FileCheck %s --check-prefix=REJECT < %t.strict.remarks
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-allow-fp-reordering \
; RUN:   -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.reordered 2> %t.reordered.remarks
; RUN: FileCheck %s --check-prefix=IR --implicit-check-not=scalar.fission < %t.reordered
; RUN: FileCheck %s --check-prefix=REJECT < %t.reordered.remarks
;
; Larger producer admission does not justify propagating updates to a later
; edge, conditional update exits, multiple update sites/streams or feedback.
; Every case otherwise has the same two bypass edges and bounded full-trip
; control, except the deliberately unproved bound/early-exit cases.
; Inherited compact/acyclic rejection and capacity tests also remain required.

declare i32 @unsafe(i32) memory(read) nounwind willreturn speculatable
declare double @llvm.experimental.constrained.fadd.f64(double, double, metadata, metadata)

; REJECT: scalar-compact-cfg-reject.c:12:3: scalar-IR reduction fission rejected: scalar-unsupported-recurrence
; IR-LABEL: define i32 @reject_cfg_nonterminal_update(
; IR: ret i32
define i32 @reject_cfg_nonterminal_update(ptr %a, i64 %n) !dbg !10 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !11
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %dispatch
left:
  %update = add i32 %sum, %x
  br label %bridge
bridge:
  br label %latch
dispatch:
  %parity = and i64 %iv, 1
  %odd = icmp ne i64 %parity, 0
  br i1 %odd, label %right, label %right1
right:
  br label %latch
right1:
  br label %latch
latch:
  %merged = phi i32 [%sum, %right1], [%update, %bridge], [%sum, %right]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !11
exit:
  %result = phi i32 [%merged, %latch]
  ret i32 %result
bypass:
  ret i32 19
}

; REJECT: scalar-compact-cfg-reject.c:22:3: scalar-IR reduction fission rejected: scalar-unsupported-recurrence
; IR-LABEL: define i32 @reject_cfg_conditional_update(
; IR: ret i32
define i32 @reject_cfg_conditional_update(ptr %a, i64 %n) !dbg !12 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !13
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %dispatch
left:
  %update = add i32 %sum, %x
  %keep = icmp sgt i32 %x, 3
  br i1 %keep, label %latch, label %post
post:
  br label %latch
dispatch:
  %parity = and i64 %iv, 1
  %odd = icmp ne i64 %parity, 0
  br i1 %odd, label %right, label %right1
right:
  br label %latch
right1:
  br label %latch
latch:
  %merged = phi i32 [%sum, %right1], [%update, %left], [%sum, %right], [%sum, %post]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !13
exit:
  %result = phi i32 [%merged, %latch]
  ret i32 %result
bypass:
  ret i32 19
}

; REJECT: scalar-compact-cfg-reject.c:32:3: scalar-IR reduction fission rejected: scalar-unsupported-recurrence
; IR-LABEL: define i32 @reject_cfg_multiple_updates(
; IR: ret i32
define i32 @reject_cfg_multiple_updates(ptr %a, i64 %n) !dbg !14 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !15
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %dispatch
left:
  %update = add i32 %sum, %x
  br label %latch
dispatch:
  %parity = and i64 %iv, 1
  %odd = icmp ne i64 %parity, 0
  br i1 %odd, label %right, label %right1
right:
  br label %latch
right1:
  %other = add i32 %sum, %x
  br label %latch
latch:
  %merged = phi i32 [%other, %right1], [%update, %left], [%sum, %right]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !15
exit:
  %result = phi i32 [%merged, %latch]
  ret i32 %result
bypass:
  ret i32 19
}

; REJECT: scalar-compact-cfg-reject.c:42:3: scalar-IR reduction fission rejected: scalar-incompatible-participation
; IR-LABEL: define i32 @reject_cfg_different_participation(
; IR: ret i32
define i32 @reject_cfg_different_participation(ptr %a, i64 %n) !dbg !16 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !17
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %sum2 = phi i32 [7, %preheader], [%merged2, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %dispatch
left:
  %update = add i32 %sum, %x
  br label %latch
dispatch:
  %parity = and i64 %iv, 1
  %odd = icmp ne i64 %parity, 0
  br i1 %odd, label %right, label %right1
right:
  br label %latch
right1:
  %other = add i32 %sum2, %x
  br label %latch
latch:
  %merged = phi i32 [%sum, %right1], [%update, %left], [%sum, %right]
  %merged2 = phi i32 [%other, %right1], [%sum2, %left], [%sum2, %right]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !17
exit:
  %result = phi i32 [%merged, %latch]
  %result2 = phi i32 [%merged2, %latch]
  %combined = add i32 %result, %result2
  ret i32 %combined
bypass:
  ret i32 26
}

; REJECT: scalar-compact-cfg-reject.c:52:3: scalar-IR reduction fission rejected: scalar-reduction-feedback
; IR-LABEL: define i32 @reject_cfg_predicate_feedback(
; IR: ret i32
define i32 @reject_cfg_predicate_feedback(ptr %a, i64 %n) !dbg !18 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !19
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %sum, 0
  br i1 %choose, label %left, label %dispatch
left:
  %update = add i32 %sum, %x
  br label %latch
dispatch:
  %parity = and i64 %iv, 1
  %odd = icmp ne i64 %parity, 0
  br i1 %odd, label %right, label %right1
right:
  br label %latch
right1:
  br label %latch
latch:
  %merged = phi i32 [%sum, %right1], [%update, %left], [%sum, %right]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !19
exit:
  %result = phi i32 [%merged, %latch]
  ret i32 %result
bypass:
  ret i32 19
}

; REJECT: scalar-compact-cfg-reject.c:62:3: scalar-IR reduction fission rejected: scalar-reduction-feedback
; IR-LABEL: define i32 @reject_cfg_contribution_feedback(
; IR: ret i32
define i32 @reject_cfg_contribution_feedback(ptr %a, i64 %n) !dbg !20 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !21
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %dispatch
left:
  %feedback = xor i32 %x, %sum
  %update = add i32 %sum, %feedback
  br label %latch
dispatch:
  %parity = and i64 %iv, 1
  %odd = icmp ne i64 %parity, 0
  br i1 %odd, label %right, label %right1
right:
  br label %latch
right1:
  br label %latch
latch:
  %merged = phi i32 [%sum, %right1], [%update, %left], [%sum, %right]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !21
exit:
  %result = phi i32 [%merged, %latch]
  ret i32 %result
bypass:
  ret i32 19
}

; REJECT: scalar-compact-cfg-reject.c:72:3: scalar-IR reduction fission rejected: scalar-reduction-feedback
; IR-LABEL: define i32 @reject_cfg_double_accumulator_operand(
; IR: ret i32
define i32 @reject_cfg_double_accumulator_operand(ptr %a, i64 %n) !dbg !22 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !23
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %dispatch
left:
  %update = add i32 %sum, %sum
  br label %latch
dispatch:
  %parity = and i64 %iv, 1
  %odd = icmp ne i64 %parity, 0
  br i1 %odd, label %right, label %right1
right:
  br label %latch
right1:
  br label %latch
latch:
  %merged = phi i32 [%sum, %right1], [%update, %left], [%sum, %right]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !23
exit:
  %result = phi i32 [%merged, %latch]
  ret i32 %result
bypass:
  ret i32 19
}

; REJECT: scalar-compact-cfg-reject.c:82:3: scalar-IR reduction fission rejected: scalar-unsupported-recurrence
; IR-LABEL: define i32 @reject_cfg_changed_bypass(
; IR: ret i32
define i32 @reject_cfg_changed_bypass(ptr %a, i64 %n) !dbg !24 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !25
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %dispatch
left:
  %update = add i32 %sum, %x
  br label %latch
dispatch:
  %parity = and i64 %iv, 1
  %odd = icmp ne i64 %parity, 0
  br i1 %odd, label %right, label %right1
right:
  br label %latch
right1:
  %changed = xor i32 %sum, 1
  br label %latch
latch:
  %merged = phi i32 [%changed, %right1], [%update, %left], [%sum, %right]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !25
exit:
  %result = phi i32 [%merged, %latch]
  ret i32 %result
bypass:
  ret i32 19
}

; REJECT: scalar-compact-cfg-reject.c:92:3: scalar-IR reduction fission rejected: scalar-unsupported-instruction
; IR-LABEL: define i32 @reject_cfg_bypass_store(
; IR: ret i32
define i32 @reject_cfg_bypass_store(ptr %a, i64 %n) !dbg !26 {
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
  br i1 %choose, label %left, label %dispatch
left:
  %update = add i32 %sum, %x
  br label %latch
dispatch:
  %parity = and i64 %iv, 1
  %odd = icmp ne i64 %parity, 0
  br i1 %odd, label %right, label %right1
right:
  br label %latch
right1:
  store i32 %x, ptr %p, align 4
  br label %latch
latch:
  %merged = phi i32 [%sum, %right1], [%update, %left], [%sum, %right]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !27
exit:
  %result = phi i32 [%merged, %latch]
  ret i32 %result
bypass:
  ret i32 19
}

; REJECT: scalar-compact-cfg-reject.c:102:3: scalar-IR reduction fission rejected: scalar-unsafe-call
; IR-LABEL: define i32 @reject_cfg_bypass_effect(
; IR: ret i32
define i32 @reject_cfg_bypass_effect(ptr %a, i64 %n) !dbg !28 {
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
  br i1 %choose, label %left, label %dispatch
left:
  %update = add i32 %sum, %x
  br label %latch
dispatch:
  %parity = and i64 %iv, 1
  %odd = icmp ne i64 %parity, 0
  br i1 %odd, label %right, label %right1
right:
  br label %latch
right1:
  %effect = call i32 @unsafe(i32 %x)
  br label %latch
latch:
  %merged = phi i32 [%sum, %right1], [%update, %left], [%sum, %right]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !29
exit:
  %result = phi i32 [%merged, %latch]
  ret i32 %result
bypass:
  ret i32 19
}

; REJECT: scalar-compact-cfg-reject.c:112:3: scalar-IR reduction fission rejected: scalar-strict-fp
; IR-LABEL: define i32 @reject_cfg_strictfp(
; IR: ret i32
define i32 @reject_cfg_strictfp(ptr %a, i64 %n) strictfp !dbg !30 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !31
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %dispatch
left:
  %update = add i32 %sum, %x
  br label %latch
dispatch:
  %parity = and i64 %iv, 1
  %odd = icmp ne i64 %parity, 0
  br i1 %odd, label %right, label %right1
right:
  br label %latch
right1:
  br label %latch
latch:
  %merged = phi i32 [%sum, %right1], [%update, %left], [%sum, %right]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !31
exit:
  %result = phi i32 [%merged, %latch]
  ret i32 %result
bypass:
  ret i32 19
}

; REJECT: scalar-compact-cfg-reject.c:122:3: scalar-IR reduction fission rejected: scalar-strict-fp
; IR-LABEL: define i32 @reject_cfg_constrained(
; IR: ret i32
define i32 @reject_cfg_constrained(ptr %a, i64 %n) !dbg !32 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !33
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %dispatch
left:
  %update = add i32 %sum, %x
  br label %latch
dispatch:
  %parity = and i64 %iv, 1
  %odd = icmp ne i64 %parity, 0
  br i1 %odd, label %right, label %right1
right:
  br label %latch
right1:
  %strict = call double @llvm.experimental.constrained.fadd.f64(double 0.0, double 1.0, metadata !"round.dynamic", metadata !"fpexcept.strict")
  br label %latch
latch:
  %merged = phi i32 [%sum, %right1], [%update, %left], [%sum, %right]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !33
exit:
  %result = phi i32 [%merged, %latch]
  ret i32 %result
bypass:
  ret i32 19
}

; REJECT: scalar-compact-cfg-reject.c:132:3: scalar-IR reduction fission rejected: {{non-constant-trip-count|scalar-scratch-limit}}
; IR-LABEL: define i32 @reject_cfg_unproved_bound(
; IR: ret i32
define i32 @reject_cfg_unproved_bound(ptr %a, i64 %n) !dbg !34 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 true, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !35
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %dispatch
left:
  %update = add i32 %sum, %x
  br label %latch
dispatch:
  %parity = and i64 %iv, 1
  %odd = icmp ne i64 %parity, 0
  br i1 %odd, label %right, label %right1
right:
  br label %latch
right1:
  br label %latch
latch:
  %merged = phi i32 [%sum, %right1], [%update, %left], [%sum, %right]
  %next = add i64 %iv, 2
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !35
exit:
  %result = phi i32 [%merged, %latch]
  ret i32 %result
bypass:
  ret i32 19
}

; REJECT: scalar-compact-cfg-reject.c:142:3: scalar-IR reduction fission rejected: scalar-unsupported-cfg
; IR-LABEL: define i32 @reject_cfg_early_exit(
; IR: ret i32
define i32 @reject_cfg_early_exit(ptr %a, i64 %n) !dbg !36 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !37
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%merged, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %dispatch
left:
  %update = add i32 %sum, %x
  br label %latch
dispatch:
  %parity = and i64 %iv, 1
  %odd = icmp ne i64 %parity, 0
  br i1 %odd, label %right, label %right1
right:
  br label %latch
right1:
  %escape = icmp eq i64 %iv, 2
  br i1 %escape, label %early, label %latch
latch:
  %merged = phi i32 [%sum, %right1], [%update, %left], [%sum, %right]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !37
exit:
  %result = phi i32 [%merged, %latch]
  ret i32 %result
early:
  ret i32 23
bypass:
  ret i32 19
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-compact-cfg-reject.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!5 = !DISubroutineType(types: !6)
!6 = !{}
!10 = distinct !DISubprogram(name: "reject_cfg_nonterminal_update", scope: !1, file: !1, line: 10, type: !5, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 12, column: 3, scope: !10)
!12 = distinct !DISubprogram(name: "reject_cfg_conditional_update", scope: !1, file: !1, line: 20, type: !5, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 22, column: 3, scope: !12)
!14 = distinct !DISubprogram(name: "reject_cfg_multiple_updates", scope: !1, file: !1, line: 30, type: !5, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!15 = !DILocation(line: 32, column: 3, scope: !14)
!16 = distinct !DISubprogram(name: "reject_cfg_different_participation", scope: !1, file: !1, line: 40, type: !5, scopeLine: 40, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!17 = !DILocation(line: 42, column: 3, scope: !16)
!18 = distinct !DISubprogram(name: "reject_cfg_predicate_feedback", scope: !1, file: !1, line: 50, type: !5, scopeLine: 50, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!19 = !DILocation(line: 52, column: 3, scope: !18)
!20 = distinct !DISubprogram(name: "reject_cfg_contribution_feedback", scope: !1, file: !1, line: 60, type: !5, scopeLine: 60, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!21 = !DILocation(line: 62, column: 3, scope: !20)
!22 = distinct !DISubprogram(name: "reject_cfg_double_accumulator_operand", scope: !1, file: !1, line: 70, type: !5, scopeLine: 70, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!23 = !DILocation(line: 72, column: 3, scope: !22)
!24 = distinct !DISubprogram(name: "reject_cfg_changed_bypass", scope: !1, file: !1, line: 80, type: !5, scopeLine: 80, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!25 = !DILocation(line: 82, column: 3, scope: !24)
!26 = distinct !DISubprogram(name: "reject_cfg_bypass_store", scope: !1, file: !1, line: 90, type: !5, scopeLine: 90, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!27 = !DILocation(line: 92, column: 3, scope: !26)
!28 = distinct !DISubprogram(name: "reject_cfg_bypass_effect", scope: !1, file: !1, line: 100, type: !5, scopeLine: 100, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!29 = !DILocation(line: 102, column: 3, scope: !28)
!30 = distinct !DISubprogram(name: "reject_cfg_strictfp", scope: !1, file: !1, line: 110, type: !5, scopeLine: 110, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!31 = !DILocation(line: 112, column: 3, scope: !30)
!32 = distinct !DISubprogram(name: "reject_cfg_constrained", scope: !1, file: !1, line: 120, type: !5, scopeLine: 120, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!33 = !DILocation(line: 122, column: 3, scope: !32)
!34 = distinct !DISubprogram(name: "reject_cfg_unproved_bound", scope: !1, file: !1, line: 130, type: !5, scopeLine: 130, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!35 = !DILocation(line: 132, column: 3, scope: !34)
!36 = distinct !DISubprogram(name: "reject_cfg_early_exit", scope: !1, file: !1, line: 140, type: !5, scopeLine: 140, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!37 = !DILocation(line: 142, column: 3, scope: !36)
