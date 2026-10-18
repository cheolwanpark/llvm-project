; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -enable-vplan-reduction-fission -pass-remarks=vplan-reduction-fission -pass-remarks-missed=vplan-reduction-fission \
; RUN:   -S %s -o %t 2> %t.remarks
; RUN: FileCheck %s --check-prefixes=CHECK,COUNT < %t
; RUN: FileCheck %s --check-prefix=REASON < %t.remarks
; RUN: FileCheck %s --check-prefix=FINITE < %t.remarks
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=18446744073709551615 \
; RUN:   -S %s | FileCheck %s --check-prefixes=OVERFLOW,COUNT
;
; Failure of the early path leaves original IR for normal LV. The checks
; prohibit new scalar-IR scratch for rejected functions while permitting ordinary
; vectorization. Historical reject_unbounded and reject_liveout are positives.
;
declare i32 @safe(i32) memory(none) nounwind willreturn speculatable
declare i32 @side_effect(i32) nounwind willreturn
declare i32 @throwing(i32) memory(none) willreturn speculatable
declare i32 @nonterminating(i32) memory(none) nounwind speculatable
declare i32 @nonspeculatable(i32) memory(none) nounwind willreturn
declare i32 @convergent_call(i32) memory(none) nounwind willreturn speculatable convergent
declare i32 @readonly_call(i32) memory(read) nounwind willreturn speculatable
declare i32 @noduplicate_call(i32) memory(none) nounwind willreturn speculatable noduplicate
declare double @llvm.experimental.constrained.fadd.f64(double, double, metadata, metadata)

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-reject.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = distinct !DISubprogram(name: "reject_side_effect", scope: !1, file: !1, line: 10, type: !5, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!5 = !DISubroutineType(types: !6)
!6 = !{}
!7 = !DILocation(line: 12, column: 3, scope: !4)

; REASON: scalar-reject.c:12:3: scalar-IR reduction fission rejected: scalar-unsafe-call
; CHECK-LABEL: define i32 @reject_side_effect(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_side_effect(ptr %a, i64 %n) !dbg !4 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @side_effect(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !7
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsafe-call
; CHECK-LABEL: define i32 @reject_throwing(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_throwing(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @throwing(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsafe-call
; CHECK-LABEL: define i32 @reject_nonterminating(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_nonterminating(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @nonterminating(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsafe-call
; CHECK-LABEL: define i32 @reject_nonspeculatable(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_nonspeculatable(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @nonspeculatable(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsafe-call
; CHECK-LABEL: define i32 @reject_convergent_call(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_convergent_call(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @convergent_call(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsafe-call
; CHECK-LABEL: define i32 @reject_readonly_call(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_readonly_call(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @readonly_call(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsafe-call
; CHECK-LABEL: define i32 @reject_noduplicate_call(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_noduplicate_call(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @noduplicate_call(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsupported-recurrence
; CHECK-LABEL: define i32 @reject_feedback(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_feedback(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @safe(i32 %sum)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-reduction-feedback
; CHECK-LABEL: define i32 @reject_update_feedback(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_update_feedback(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  %feedback = xor i32 %update, %x
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-strict-fp
; CHECK-LABEL: define i32 @reject_strictfp(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_strictfp(ptr %a, i64 %n) strictfp {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; Despite its historical name, this is finite: on the entering edge unsigned
; 1 <= N <= UINT64_MAX. Starting at zero and exiting when next==N executes
; exactly N iterations; the last next is N, never a wrapped zero. SCEV's
; backedge count is N-1 and its unsigned maximum plus one is representable.
; Whole-trip N*4 bytes cannot fit, but checked chunk planning can. With an
; unlimited byte option, the signed-positive alloca-index bound still limits
; capacity to floor(INT64_MAX/4), not UINT64_MAX rows or wrapped storage.
; This is IR/analysis coverage; huge N and huge allocations are not executed.
; FINITE: scalar-reject.c:32:3: split scalar-IR reduction loop; {{.*}}scratch capacity 16384, scratch bytes 65536, producer live-outs 0, chunked schedule, trip bound 18446744073709551615
; CHECK-LABEL: define i32 @reject_unbounded(
; OVERFLOW-LABEL: define i32 @reject_unbounded(
; CHECK: alloca {{\[}}[[CAP:16384]] x i32]
; OVERFLOW: alloca {{\[}}[[CAP:2305843009213693951]] x i32]
; COUNT-NOT: alloca
; COUNT: scalar.fission.chunk:
; COUNT: %fission.chunk.base = phi i64 [ 0, %preheader ], [ %fission.chunk.next, %scalar.fission.chunk.latch ]
; COUNT: %sum.chunk.carry = phi i32 [ 19, %preheader ], [ [[RESULT:%[-a-zA-Z$._0-9]+]], %scalar.fission.chunk.latch ]
; COUNT: %fission.chunk.remaining = sub {{(nuw )?}}i64 %n, %fission.chunk.base
; COUNT: %fission.chunk.partial = icmp ult i64 %fission.chunk.remaining, [[CAP]]
; COUNT: %fission.chunk.count = select i1 %fission.chunk.partial, i64 %fission.chunk.remaining, i64 [[CAP]]
; COUNT: scalar.fission.consumer.ph:
; COUNT: vector.ph:
; COUNT: [[SEED:%[-a-zA-Z$._0-9]+]] = insertelement <vscale x [[VF:[1-9][0-9]*]] x i32> zeroinitializer, i32 %sum.chunk.carry, i32 0
; COUNT: vector.body:
; COUNT: [[ACC:%[-a-zA-Z$._0-9]+]] = phi <vscale x [[VF]] x i32> [ [[SEED]], %vector.ph ], [ [[VRESULT:%[-a-zA-Z$._0-9]+]], %vector.body ]
; COUNT: [[EVL:%[-a-zA-Z$._0-9]+]] = call i32 @llvm.experimental.get.vector.length.i64(
; COUNT: [[LOAD:%[-a-zA-Z$._0-9]+]] = call <vscale x [[VF]] x i32> @llvm.vp.load.nxv[[VF]]i32.p0(
; COUNT: [[ADD:%[-a-zA-Z$._0-9]+]] = add <vscale x [[VF]] x i32> [[ACC]], [[LOAD]]
; COUNT: [[VRESULT]] = call <vscale x [[VF]] x i32> @llvm.vp.merge.nxv[[VF]]i32(<vscale x [[VF]] x i1> splat (i1 true), <vscale x [[VF]] x i32> [[ADD]], <vscale x [[VF]] x i32> [[ACC]], i32 [[EVL]])
; COUNT: br i1 {{%[-a-zA-Z$._0-9]+}}, label %middle.block, label %vector.body
; COUNT: middle.block:
; COUNT-NEXT: [[RESULT]] = call i32 @llvm.vector.reduce.add.nxv[[VF]]i32(<vscale x [[VF]] x i32> [[VRESULT]])
; COUNT-NEXT: br label %scalar.fission.chunk.latch
; COUNT: scalar.fission.chunk.latch:
; COUNT: %fission.chunk.next = add {{(nuw )?}}i64 %fission.chunk.base, %fission.chunk.count
; COUNT: %fission.chunk.more = icmp ne i64 %fission.chunk.next, %n
; COUNT: br i1 %fission.chunk.more, label %scalar.fission.chunk, label %exit
; COUNT: exit:
; COUNT-NEXT: %update.lcssa = phi i32 [ [[RESULT]], %scalar.fission.chunk.latch ]
; COUNT-NEXT: ret i32 %update.lcssa
define i32 @reject_unbounded(ptr %a, i64 %n) !dbg !10 {
entry:
  %valid = icmp ule i64 %n, -1
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !11
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; Historical reject_liveout now exports the actual final load through LCSSA.
; Its return value and zero-entry result remain checked; other rejections stay.
; CHECK-LABEL: define i32 @reject_liveout(
; CHECK: alloca [65 x i32]
; CHECK: scalar.fission.consumer.ph:
; CHECK: ret i32
define i32 @reject_liveout(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %x
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsupported-recurrence
; CHECK-LABEL: define i32 @reject_old_accumulator_liveout(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_old_accumulator_liveout(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %sum
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-non-simple-load
; CHECK-LABEL: define i32 @reject_volatile_load(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_volatile_load(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load volatile i32, ptr %p, align 4
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-non-simple-load
; CHECK-LABEL: define i32 @reject_atomic_load(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_atomic_load(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load atomic i32, ptr %p monotonic, align 4
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; Historical reject_write is now positive: %x is independent of the extracted
; accumulator, and both its load and self-store remain ordered in the producer.
; Unsupported stores remain explicitly rejected in scalar-stores-reject.ll.
; FINITE: scalar-reject.c:52:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 260
; CHECK-LABEL: define i32 @reject_write(
; CHECK: alloca [65 x i32]
; CHECK: store i32 %x, ptr %p
; CHECK: scalar.fission.consumer.ph:
; CHECK: ret i32
define i32 @reject_write(ptr %a, i64 %n) !dbg !12 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  store i32 %x, ptr %p
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !13
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsupported-exit
; CHECK-LABEL: define i32 @reject_unsupported_exit(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_unsupported_exit(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i32 %c, 0
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-unsafe-call
; CHECK-LABEL: define i32 @reject_operand_bundle(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_operand_bundle(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @safe(i32 %x) [ "deopt"(i32 0) ]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; Historical reject_other_recurrence is now a direct XOR positive. The safe
; helper stays in the producer and the exact XOR update moves to the consumer.
; CHECK-LABEL: define i32 @reject_other_recurrence(
; CHECK: alloca [65 x i32]
; CHECK: call i32 @safe(
; CHECK: scalar.fission.consumer.ph:
; CHECK: xor
; CHECK: ret i32
define i32 @reject_other_recurrence(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @safe(i32 %x)
  %update = xor i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; REASON: scalar-IR reduction fission rejected: scalar-strict-fp
; CHECK-LABEL: define i32 @reject_constrained(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_constrained(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  %fp = call double @llvm.experimental.constrained.fadd.f64(double 1.0, double 2.0, metadata !"round.dynamic", metadata !"fpexcept.strict")
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

; Multiple exits and participating-iteration control need a separate CFG path.
; REASON: scalar-IR reduction fission rejected: scalar-unsupported-cfg
; CHECK-LABEL: define i32 @reject_early_exit(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_early_exit(ptr %a) {
entry:
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %latch]
  %sum = phi i32 [19, %entry], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %stop = icmp eq i32 %x, 0
  br i1 %stop, label %early, label %latch
latch:
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, 65
  br i1 %done, label %exit, label %loop
early:
  ret i32 %sum
exit:
  ret i32 %update
}

; A count outside uint64_t is rejected before multiplying element sizes.
; REASON: scalar-IR reduction fission rejected: trip-count-overflow
; CHECK-LABEL: define i32 @reject_trip_overflow(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
define i32 @reject_trip_overflow(i32 %x) {
entry:
  br label %loop
loop:
  %iv = phi i128 [0, %entry], [%next, %loop]
  %sum = phi i32 [19, %entry], [%update, %loop]
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i128 %iv, 1
  %done = icmp eq i128 %next, 18446744073709551616
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
}

; An available final producer export must still be independent of reduction
; state. Exporting a computation of the final update does not bypass feedback
; rejection, even though both results have well-formed LCSSA exit edges.
; REASON: scalar-reject.c:42:3: scalar-IR reduction fission rejected: scalar-reduction-feedback
; CHECK-LABEL: define void @reject_reduction_derived_export(
; CHECK-NOT: scalar.fission
; CHECK: store i32
; CHECK: store i32
; CHECK: ret void
define void @reject_reduction_derived_export(ptr %a, ptr %out, i64 %n) !dbg !8 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [19, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @safe(i32 %x)
  %update = add i32 %sum, %c
  %last = xor i32 %update, %x
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !9
exit:
  %result = phi i32 [%update, %loop]
  %producer = phi i32 [%last, %loop]
  store i32 %result, ptr %out
  %other = getelementptr i32, ptr %out, i64 1
  store i32 %producer, ptr %other
  ret void
bypass:
  ret void
}

!8 = distinct !DISubprogram(name: "reject_reduction_derived_export", scope: !1, file: !1, line: 40, type: !5, scopeLine: 40, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!9 = !DILocation(line: 42, column: 3, scope: !8)

!10 = distinct !DISubprogram(name: "reject_unbounded", scope: !1, file: !1, line: 30, type: !5, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 32, column: 3, scope: !10)
!12 = distinct !DISubprogram(name: "reject_write", scope: !1, file: !1, line: 50, type: !5, scopeLine: 50, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 52, column: 3, scope: !12)
