; RUN: opt -scalable-vectorization=always -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 -S %s -o %t.isolated
; RUN: FileCheck %s --check-prefix=ISOLATED --implicit-check-not=scalar.fission.scratch < %t.isolated
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.isolated -o /dev/null
; RUN: opt -scalable-vectorization=always -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 -vplan-reduction-fission-max-scratch-bytes=520 -S %s -o %t.exact
; RUN: FileCheck %s --check-prefix=EXACT < %t.exact
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.exact -o /dev/null
; RUN: opt -scalable-vectorization=always -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 -pass-remarks=vplan-reduction-fission -pass-remarks-missed=vplan-reduction-fission -S %s -o %t 2> %t.remarks
; RUN: FileCheck %s --check-prefixes=DEFAULT,ONCE < %t
; RUN: FileCheck %s --check-prefix=REMARK < %t.remarks
; RUN: FileCheck %s --check-prefix=SELECTED < %t.remarks
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t -o /dev/null
; RUN: opt -scalable-vectorization=always -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 -vplan-reduction-fission-allow-fp-reordering -pass-remarks=vplan-reduction-fission -S %s -o %t.repeat 2> %t.repeat.remarks
; RUN: FileCheck %s --check-prefixes=DEFAULT,REPEAT < %t.repeat
; RUN: FileCheck %s --check-prefix=SELECTED < %t.repeat.remarks
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.repeat -o /dev/null
; RUN: opt -scalable-vectorization=always -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 -tail-folding-policy=dont-fold-tail -enable-epilogue-vectorization=false -S %s -o %t.tail
; RUN: FileCheck %s --check-prefix=TAIL < %t.tail
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.tail -o /dev/null
; RUN: opt -scalable-vectorization=always -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 -tail-folding-policy=dont-fold-tail -enable-epilogue-vectorization=false -pass-remarks=vplan-reduction-fission -S %s -o %t.tail.repeat 2> %t.tail.repeat.remarks
; RUN: FileCheck %s --check-prefix=TAIL < %t.tail.repeat
; RUN: FileCheck %s --check-prefix=SELECTED < %t.tail.repeat.remarks
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.tail.repeat -o /dev/null
; RUN: opt -scalable-vectorization=always -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 -vplan-reduction-fission-max-scratch-bytes=519 -pass-remarks=vplan-reduction-fission -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.limit 2> %t.limit.remarks
; RUN: FileCheck %s --check-prefix=LIMIT < %t.limit
; RUN: FileCheck %s --check-prefix=LIMIT-REMARK < %t.limit.remarks
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.limit -o /dev/null
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 -force-target-max-scalar-interleave=1 -scalable-vectorization=off -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=519 -S %s -o %t.limit.scalar
; RUN: FileCheck %s --check-prefix=LIMIT-SCALAR < %t.limit.scalar
;
; One module enters both paths through default dispatch. A sum/xor AoS
; candidate fails early recurrence legality, then reaches VPlan interleave
; planning with intact analyses. The ordered two-sum AoS loop is eligible for
; both paths and must take the early split exactly once. The nested compact
; stream retains outer feedback and reuses bounded scratch once per row.
; Volatile input rejects early splitting and ordinary LV.
;
; The compact hint fixes ordinary VF4 for its count-provenance checker.
; Ordinary LV selects both overlapping AoS stage VFs; executable probes use
; their actual source-located stage remarks. The identical candidate below
; also takes VPlan fission when the early path is explicitly disabled.
; Explicit VPlan stage widths apply only after early rejection. No scalar-path
; isolation flag is present in the default RUNs. The fallback's followup_all deliberately permits
; another LV invocation: persistent stage provenance must prevent new fission.
; With default EVL/VP, the second LV turns both scalar tails into VF4 vector
; loops, even when fewer than VF4 lanes remain. Their old body.middle blocks
; only forward control. With dont-fold-tail, any additional vector loop uses
; full chunks and a scalar remainder. The checker accounts for each emitted
; loop and its participating lanes, separately from the original four stages.
; Actual transformed execution is in check-reduction-fission.py under both FP
; option settings, single/repeated LV and all default fixed vscales.
;
; REMARK: dispatch.c:10:5: scalar-IR reduction fission rejected: scalar-unsupported-recurrence
; REMARK: dispatch.c:10:5: split reduction loop: baseline VF {{.*}}, producer VF vscale x 2, accumulator VF vscale x 4, trip count bounded-runtime, scratch capacity 65, scratch bytes 260
; REMARK-SAME: scratch store bytes/iteration 4, scratch load bytes/iteration 4, duplicated recipes 0, reread loads/iteration 0
; REMARK: dispatch.c:20:5: scalar-IR reduction fission rejected: scalar-unsupported-recurrence
; REMARK: dispatch.c:20:5: split reduction loop: baseline VF {{.*}}, producer VF vscale x 2, accumulator VF vscale x 4, trip count bounded-runtime, scratch capacity 65, scratch bytes 260
; REMARK: dispatch.c:30:5: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 520
; REMARK-DAG: dispatch.c:30:5: scalar-IR fission producer VF vscale x {{[1-9][0-9]*}}
; REMARK-DAG: dispatch.c:30:5: scalar-IR fission consumer VF vscale x {{[1-9][0-9]*}}
; REMARK: dispatch.c:50:5: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; REMARK-DAG: dispatch.c:50:5: scalar-IR fission producer VF 1
; REMARK-DAG: dispatch.c:50:5: scalar-IR fission consumer VF vscale x 4
; REMARK: dispatch.c:70:5: scalar-IR reduction fission rejected: scalar-non-simple-load
;
; Four original targets, even on repeated LV. No stage/helper is a fifth.
; SELECTED-COUNT-4: : split
; SELECTED-NOT: : split
;
; DEFAULT-LABEL: define void @interleave2(
; DEFAULT: alloca [65 x i32]
; DEFAULT-NOT: scalar.fission.scratch
; DEFAULT: vector.fission.producer.body:
; DEFAULT: @llvm.vector.deinterleave2.
; ONCE: scalar.fission.producer.body:
; REPEAT: vector.body{{[0-9]*}}:
; REPEAT: @llvm.experimental.get.vector.length.i64(i64 {{.*}}, i32 4, i1 true)
; REPEAT: @llvm.vp.store.nxv4i32
; REPEAT: scalar.fission.producer.body.middle:
; DEFAULT: vector.fission.accumulator.body:
; DEFAULT: @llvm.vector.reduce.add.
; ONCE: scalar.fission.accumulator.body:
; REPEAT: vector.body{{[0-9]*}}:
; REPEAT: @llvm.vp.load.nxv4i32
; REPEAT: @llvm.vector.reduce.add.nxv4i32
; REPEAT: scalar.fission.accumulator.body.middle:
; DEFAULT-NOT: scalar.fission.scratch
; DEFAULT-LABEL: define void @interleave3(
; DEFAULT: alloca [65 x i32]
; DEFAULT: vector.fission.producer.body:
; DEFAULT: @llvm.vector.deinterleave3.
; ONCE: scalar.fission.producer.body:
; REPEAT: vector.body{{[0-9]*}}:
; REPEAT: @llvm.experimental.get.vector.length.i64(i64 {{.*}}, i32 4, i1 true)
; REPEAT: @llvm.vp.store.nxv4i32
; REPEAT: scalar.fission.producer.body.middle:
; DEFAULT: vector.fission.accumulator.body:
; ONCE: scalar.fission.accumulator.body:
; REPEAT: vector.body{{[0-9]*}}:
; REPEAT: @llvm.vp.load.nxv4i32
; REPEAT: @llvm.vector.reduce.add.nxv4i32
; REPEAT: scalar.fission.accumulator.body.middle:
; DEFAULT-LABEL: define void @interleave2_ordered(
; DEFAULT: alloca [65 x double]
; DEFAULT-NOT: vector.fission.producer.body:
; DEFAULT: scalar.fission.consumer.ph:
; DEFAULT: @llvm.vp.reduce.fadd.nxv{{[1-9][0-9]*}}f64
; DEFAULT: @llvm.vp.reduce.fadd.nxv{{[1-9][0-9]*}}f64
; DEFAULT-NOT: vector.fission.accumulator.body:
; DEFAULT-LABEL: define void @compact_nested(
; DEFAULT: alloca [65 x i32]
; DEFAULT: alloca [65 x double]
; DEFAULT: fission.participating = phi i64
; DEFAULT: fission.participating.merge = phi i64
; DEFAULT: scalar.fission.consumer.guard:
; DEFAULT: scalar.fission.consumer.ph:
; DEFAULT: @llvm.vp.reduce.fadd.nxv4f64
; DEFAULT-LABEL: define i32 @dispatch_reject(
; DEFAULT-NOT: fission
; DEFAULT: load volatile i32
; DEFAULT-NOT: fission
; DEFAULT: ret i32
; DEFAULT-LABEL: define i32 @dispatch_marked(
; DEFAULT-NOT: fission.scratch
; DEFAULT: vector.body:
; DEFAULT: @llvm.vector.reduce.add.nxv4i32
; DEFAULT-NOT: fission.scratch
; DEFAULT: ret i32
; DEFAULT: !{!"llvm.loop.reduction_fission.stage"}
;
; TAIL-LABEL: define void @interleave2(
; TAIL: vector.fission.producer.body:
; TAIL: vector.fission.accumulator.body:
; TAIL-LABEL: define void @interleave3(
; TAIL: vector.fission.producer.body:
; TAIL: vector.fission.accumulator.body:
; TAIL-LABEL: define void @interleave2_ordered(
; TAIL: scalar.fission.consumer.ph:
; TAIL: @llvm.vector.reduce.fadd.nxv{{[1-9][0-9]*}}f64
; TAIL: @llvm.vector.reduce.fadd.nxv{{[1-9][0-9]*}}f64
; TAIL: scalar.fission.consumer.body:
; TAIL-LABEL: define void @compact_nested(
; TAIL: fission.participating.count = phi i64
; TAIL: @llvm.vector.reduce.fadd.nxv4f64
; TAIL: scalar.fission.consumer.body:
;
; At 519 bytes, both VPlan fallbacks still use 260 bytes. The ordered
; single-block producer now uses C=64/B=512 instead of rejecting its 520-byte
; full-trip allocation. Only the oversized compact CFG retains rejection.
; Check the scalar schedule separately so ordinary LV cannot hide its exact
; global IV, local scratch ordinal, partial count, and ordered carry edges.
; LIMIT-LABEL: define void @interleave2(
; LIMIT: alloca [65 x i32]
; LIMIT-NOT: scalar.fission.scratch
; LIMIT: vector.fission.producer.body:
; LIMIT: vector.fission.accumulator.body:
; LIMIT-LABEL: define void @interleave3(
; LIMIT: alloca [65 x i32]
; LIMIT-NOT: scalar.fission.scratch
; LIMIT: vector.fission.producer.body:
; LIMIT: vector.fission.accumulator.body:
; LIMIT-LABEL: define void @interleave2_ordered(
; LIMIT: alloca [64 x double]
; LIMIT-NOT: alloca
; LIMIT: scalar.fission.chunk:
; LV can fold the single-input chunk-result PHIs. Capture the carried values
; and prove they are the matching ordered updates on the consumer exit edge.
; LIMIT-DAG: %sum.chunk.carry = phi double [ %start, %preheader ], [ [[SUM_RESULT:%[-a-zA-Z$._0-9]+]], %scalar.fission.chunk.latch ]
; LIMIT-DAG: %bits.chunk.carry = phi double [ -0.000000e+00, %preheader ], [ [[BITS_RESULT:%[-a-zA-Z$._0-9]+]], %scalar.fission.chunk.latch ]
; LIMIT: %fission.chunk.remaining = sub {{(nuw )?}}i64 %n, %fission.chunk.base
; LIMIT: %fission.chunk.partial = icmp ult i64 %fission.chunk.remaining, 64
; LIMIT: %fission.chunk.count = select i1 %fission.chunk.partial, i64 %fission.chunk.remaining, i64 64
; LIMIT: scalar.fission.consumer.ph:
; LIMIT: [[CONSUMER_BODY:vector.body[0-9]*]]:
; LIMIT: [[SUM_ACC:%[-a-zA-Z$._0-9]+]] = phi double [ %sum.chunk.carry, %[[CONSUMER_PH:vector.ph[0-9]*]] ], [ [[SUM_RESULT]], %[[CONSUMER_BODY]] ]
; LIMIT: [[BITS_ACC:%[-a-zA-Z$._0-9]+]] = phi double [ %bits.chunk.carry, %[[CONSUMER_PH]] ], [ [[BITS_RESULT]], %[[CONSUMER_BODY]] ]
; LIMIT: [[SUM_RESULT]] = call double @llvm.vp.reduce.fadd.nxv{{[1-9][0-9]*}}f64(double [[SUM_ACC]],
; LIMIT: [[BITS_RESULT]] = call double @llvm.vp.reduce.fadd.nxv{{[1-9][0-9]*}}f64(double [[BITS_ACC]],
; LIMIT: br i1 {{%[-a-zA-Z$._0-9]+}}, label %[[CONSUMER_MIDDLE:middle.block[0-9]*]], label %[[CONSUMER_BODY]]
; LIMIT: [[CONSUMER_MIDDLE]]:
; LIMIT-NEXT: br label %scalar.fission.chunk.latch
; LIMIT: scalar.fission.chunk.latch:
; LIMIT: %fission.chunk.next = add {{(nuw )?}}i64 %fission.chunk.base, %fission.chunk.count
; LIMIT: %fission.chunk.more = icmp ne i64 %fission.chunk.next, %n
; LIMIT: br i1 %fission.chunk.more, label %scalar.fission.chunk, label %exit
; LIMIT: exit:
; LIMIT-NEXT: %update.lcssa = phi double [ [[SUM_RESULT]], %scalar.fission.chunk.latch ]
; LIMIT-NEXT: %updated.bits.lcssa = phi double [ [[BITS_RESULT]], %scalar.fission.chunk.latch ]
; LIMIT: store double %update.lcssa, ptr %out, align 8
; LIMIT: store double %updated.bits.lcssa, ptr %o1, align 8
; LIMIT-LABEL: define void @compact_nested(
; LIMIT-NOT: fission.scratch
; LIMIT: ret void
; LIMIT-REMARK: dispatch.c:10:5: split reduction loop: {{.*}}scratch capacity 65, scratch bytes 260
; LIMIT-REMARK: dispatch.c:20:5: split reduction loop: {{.*}}scratch capacity 65, scratch bytes 260
; LIMIT-REMARK: dispatch.c:30:5: split scalar-IR reduction loop; {{.*}}scratch capacity 64, scratch bytes 512, producer live-outs 0, chunked schedule, trip bound 65
; LIMIT-REMARK-SAME: scratch store bytes/iteration 8, scratch load bytes/iteration 8, producer reread bytes/iteration 0, duplicated producer instructions 0
; LIMIT-REMARK-DAG: dispatch.c:30:5: scalar-IR fission producer VF vscale x {{[1-9][0-9]*}}
; LIMIT-REMARK-DAG: dispatch.c:30:5: scalar-IR fission consumer VF vscale x {{[1-9][0-9]*}}
; LIMIT-REMARK: dispatch.c:50:5: scalar-IR reduction fission rejected: scalar-scratch-limit
;
; LIMIT-SCALAR-LABEL: define void @interleave2_ordered(
; LIMIT-SCALAR: alloca [64 x double]
; LIMIT-SCALAR: scalar.fission.chunk:
; LIMIT-SCALAR: %fission.chunk.base = phi i64 [ 0, %preheader ], [ %fission.chunk.next, %scalar.fission.chunk.latch ]
; LIMIT-SCALAR-DAG: %sum.chunk.carry = phi double [ %start, %preheader ], [ %sum.chunk.result, %scalar.fission.chunk.latch ]
; LIMIT-SCALAR-DAG: %bits.chunk.carry = phi double [ -0.000000e+00, %preheader ], [ %bits.chunk.result, %scalar.fission.chunk.latch ]
; LIMIT-SCALAR: %fission.chunk.remaining = sub nuw i64 %n, %fission.chunk.base
; LIMIT-SCALAR: %fission.chunk.count = select i1 %fission.chunk.partial, i64 %fission.chunk.remaining, i64 64
; LIMIT-SCALAR: loop:
; LIMIT-SCALAR-DAG: %fission.producer.ordinal = phi i64 [ 0, %scalar.fission.producer.ph ], [ %fission.producer.next, %loop ]
; LIMIT-SCALAR-DAG: %i = phi i64 [ %fission.chunk.base, %scalar.fission.producer.ph ], [ %next, %loop ]
; LIMIT-SCALAR: getelementptr inbounds [64 x double], ptr %scalar.fission.scratch, i32 0, i64 %fission.producer.ordinal
; LIMIT-SCALAR: store double %term,
; LIMIT-SCALAR: %fission.producer.more = icmp ne i64 %fission.producer.next, %fission.chunk.count
; LIMIT-SCALAR: scalar.fission.consumer.body:
; LIMIT-SCALAR-DAG: %sum.consume = phi double [ %sum.chunk.carry, %scalar.fission.consumer.ph ]
; LIMIT-SCALAR-DAG: %bits.consume = phi double [ %bits.chunk.carry, %scalar.fission.consumer.ph ]
; LIMIT-SCALAR: %update.consume = fadd double %sum.consume,
; LIMIT-SCALAR: %updated.bits.consume = fadd double %bits.consume,
; LIMIT-SCALAR: %fission.consumer.more = icmp ne i64 %fission.consumer.next, %fission.chunk.count
; LIMIT-SCALAR: scalar.fission.chunk.latch:
; LIMIT-SCALAR-DAG: %sum.chunk.result = phi double [ %update.consume, %scalar.fission.consumer.body ]
; LIMIT-SCALAR-DAG: %bits.chunk.result = phi double [ %updated.bits.consume, %scalar.fission.consumer.body ]
; LIMIT-SCALAR: ret void
;
; EXACT-LABEL: define void @interleave2(
; EXACT: alloca [65 x i32]
; EXACT-LABEL: define void @interleave3(
; EXACT: alloca [65 x i32]
; EXACT-LABEL: define void @interleave2_ordered(
; EXACT: alloca [65 x double]
; EXACT: scalar.fission.consumer.ph:
; EXACT-LABEL: define void @compact_nested(
; EXACT-NOT: fission.scratch
; EXACT: ret void
;
; A marked stage remains eligible for ordinary LV, but never for either
; fission path, even when follow-up hints explicitly enable vectorization.

; ISOLATED-LABEL: define void @interleave2(
; ISOLATED: vector.fission.producer.body:
; ISOLATED: vector.fission.accumulator.body:
; ISOLATED-LABEL: define void @interleave3(
; ISOLATED: vector.fission.producer.body:
; ISOLATED: vector.fission.accumulator.body:
; ISOLATED-LABEL: define void @interleave2_ordered(
; ISOLATED: alloca [65 x double]
; ISOLATED: vector.fission.producer.body:
; ISOLATED: @llvm.vector.deinterleave2.nxv4f64
; ISOLATED: vector.fission.accumulator.body:
; ISOLATED: @llvm.vector.reduce.fadd.nxv4f64
; ISOLATED-LABEL: define void @compact_nested(
; ISOLATED-NOT: fission.scratch
; ISOLATED: ret void
;
declare i32 @scalar_helper(i32) nounwind willreturn speculatable memory(none)

define void @interleave2(ptr readonly %a, ptr %out, i64 %n) !dbg !4 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %bits = phi i32 [23, %preheader], [%updated.bits, %loop]
  %base = mul nuw i64 %i, 2
  %p0 = getelementptr i32, ptr %a, i64 %base
  %x0 = load i32, ptr %p0, align 4
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr i32, ptr %a, i64 %idx1
  %x1 = load i32, ptr %p1, align 4
  %scaled = mul i32 %x0, 3
  %shared = xor i32 %scaled, %x0
  %pair = sub i32 %shared, %x1
  %term = mul i32 %pair, 7
  %update = add i32 %sum, %term
  %updated.bits = xor i32 %bits, %term
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !7, !llvm.loop !30
exit:
  store i32 %update, ptr %out, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %updated.bits, ptr %o1, align 4
  ret void
bypass:
  store i32 17, ptr %out, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  ret void
}

define void @interleave3(ptr readonly %a, ptr %out, i64 %n) !dbg !14 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %bits = phi i32 [23, %preheader], [%updated.bits, %loop]
  %base = mul nuw i64 %i, 3
  %p0 = getelementptr i32, ptr %a, i64 %base
  %x0 = load i32, ptr %p0, align 4
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr i32, ptr %a, i64 %idx1
  %x1 = load i32, ptr %p1, align 4
  %idx2 = add nuw i64 %base, 2
  %p2 = getelementptr i32, ptr %a, i64 %idx2
  %x2 = load i32, ptr %p2, align 4
  %scaled = mul i32 %x0, 3
  %shared = xor i32 %scaled, %x0
  %pair = sub i32 %shared, %x1
  %term = add i32 %pair, %x2
  %update = add i32 %sum, %term
  %updated.bits = xor i32 %bits, %term
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !15, !llvm.loop !30
exit:
  store i32 %update, ptr %out, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %updated.bits, ptr %o1, align 4
  ret void
bypass:
  store i32 17, ptr %out, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  ret void
}

define void @interleave2_ordered(ptr readonly %a, ptr %out, i64 %n, double %start) !dbg !8 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi double [%start, %preheader], [%update, %loop]
  %bits = phi double [-0.0, %preheader], [%updated.bits, %loop]
  %base = mul nuw i64 %i, 2
  %p0 = getelementptr double, ptr %a, i64 %base
  %x0 = load double, ptr %p0, align 8
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr double, ptr %a, i64 %idx1
  %x1 = load double, ptr %p1, align 8
  %scaled = fmul double %x0, 2.0
  %shared = fadd double %scaled, %x0
  %pair = fsub double %shared, %x1
  %term = fmul double %pair, 3.0
  %update = fadd double %sum, %term
  %updated.bits = fadd double %bits, %term
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !9, !llvm.loop !20
exit:
  store double %update, ptr %out, align 8
  %o1 = getelementptr double, ptr %out, i64 1
  store double %updated.bits, ptr %o1, align 8
  ret void
bypass:
  store double %start, ptr %out, align 8
  %b1 = getelementptr double, ptr %out, i64 1
  store double -0.0, ptr %b1, align 8
  ret void
}

define void @compact_nested(ptr readonly %a, ptr readonly %fp, ptr %out,
                                  ptr %dout, i64 %rows, i64 %n, double %start) !dbg !10 {
entry:
  %rows.valid = icmp ule i64 %rows, 4
  %rows.nonzero = icmp ne i64 %rows, 0
  %rows.enter = and i1 %rows.valid, %rows.nonzero
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  %enter = and i1 %rows.enter, %inner.enter
  br i1 %enter, label %outer.ph, label %exit
outer.ph:
  br label %outer
outer:
  %row = phi i64 [0, %outer.ph], [%row.next, %row.exit]
  %carry = phi i32 [19, %outer.ph], [%row.sum, %row.exit]
  %dcarry = phi double [%start, %outer.ph], [%row.dsum, %row.exit]
  %offset = mul nuw i64 %row, 65
  %base = getelementptr i32, ptr %a, i64 %offset
  %dbase = getelementptr double, ptr %fp, i64 %offset
  %salt = trunc i64 %row to i32
  br label %inner.ph
inner.ph:
  br label %inner, !dbg !11
inner:
  %iv = phi i64 [0, %inner.ph], [%next, %latch]
  %sum = phi i32 [%carry, %inner.ph], [%merged, %latch]
  %dsum = phi double [%dcarry, %inner.ph], [%dmerged, %latch]
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %salted = xor i32 %x, %salt
  %bit = and i32 %x, 1
  %choose = icmp ne i32 %bit, 0
  br i1 %choose, label %left, label %right, !dbg !11
left:
  %lc = call i32 @scalar_helper(i32 %salted)
  %dp = getelementptr double, ptr %dbase, i64 %iv
  %dx = load double, ptr %dp, align 8
  %ld = fmul double %dx, 3.0
  %update = add i32 %sum, %lc
  %dupdate = fadd double %dsum, %ld
  br label %latch
right:
  %unused = xor i32 %x, 7
  br label %latch
latch:
  %merged = phi i32 [%update, %left], [%sum, %right]
  %dmerged = phi double [%dupdate, %left], [%dsum, %right]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %row.exit, label %inner, !dbg !11, !llvm.loop !23
row.exit:
  %row.sum = phi i32 [%merged, %latch]
  %row.dsum = phi double [%dmerged, %latch]
  %dst = getelementptr i32, ptr %out, i64 %row
  %ddst = getelementptr double, ptr %dout, i64 %row
  store i32 %row.sum, ptr %dst
  store double %row.dsum, ptr %ddst
  %row.next = add nuw i64 %row, 1
  %rows.done = icmp eq i64 %row.next, %rows
  br i1 %rows.done, label %exit, label %outer
exit:
  ret void
}

define i32 @dispatch_reject(ptr %a, i64 %n) !dbg !12 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load volatile i32, ptr %p
  %update = add i32 %sum, %x
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !13
exit:
  ret i32 %update
bypass:
  ret i32 17
}

define i32 @dispatch_marked(ptr %a, i64 %n) !dbg !16 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %update = add i32 %sum, %x
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !17, !llvm.loop !40
exit:
  ret i32 %update
bypass:
  ret i32 17
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "dispatch.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = distinct !DISubprogram(name: "interleave2", scope: !1, file: !1, line: 10, type: !5, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!5 = !DISubroutineType(types: !6)
!6 = !{}
!7 = !DILocation(line: 10, column: 5, scope: !4)
!8 = distinct !DISubprogram(name: "interleave2_ordered", scope: !1, file: !1, line: 30, type: !5, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!9 = !DILocation(line: 30, column: 5, scope: !8)
!10 = distinct !DISubprogram(name: "compact_nested", scope: !1, file: !1, line: 50, type: !5, scopeLine: 50, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 50, column: 5, scope: !10)
!12 = distinct !DISubprogram(name: "dispatch_reject", scope: !1, file: !1, line: 70, type: !5, scopeLine: 70, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 70, column: 5, scope: !12)
!20 = distinct !{!20, !32}
!21 = !{!"llvm.loop.vectorize.width", i32 4}
!22 = !{!"llvm.loop.vectorize.scalable.enable", i1 true}
!30 = distinct !{!30, !31}
!31 = !{!"llvm.loop.vectorize.followup_all", !32, !21, !22}
!32 = !{!"llvm.loop.vectorize.enable", i1 true}
!14 = distinct !DISubprogram(name: "interleave3", scope: !1, file: !1, line: 20, type: !5, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!15 = !DILocation(line: 20, column: 5, scope: !14)
!16 = distinct !DISubprogram(name: "dispatch_marked", scope: !1, file: !1, line: 80, type: !5, scopeLine: 80, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!17 = !DILocation(line: 80, column: 5, scope: !16)
!40 = distinct !{!40, !41, !21, !22, !32, !31}
!41 = !{!"llvm.loop.reduction_fission.stage"}
!23 = distinct !{!23, !21, !22}
