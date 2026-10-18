; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=1 -vplan-reduction-fission-force-accumulator-vf=2 \
; RUN:   -vplan-reduction-fission-min-chain-depth=16 -pass-remarks=vplan-reduction-fission -S %s -o %t.forward 2> %t.forward.remarks
; RUN: FileCheck %s --check-prefix=FORWARD < %t.forward
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.forward -o /dev/null
; RUN: FileCheck %s --check-prefix=REMARK < %t.forward.remarks
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=1 \
; RUN:   -vplan-reduction-fission-min-chain-depth=16 -S %s -o %t.reverse 2> %t.reverse.remarks
; RUN: FileCheck %s --check-prefix=REVERSE < %t.reverse
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.reverse -o /dev/null
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=1 -vplan-reduction-fission-force-accumulator-vf=2 \
; RUN:   -vplan-reduction-fission-min-chain-depth=16 -vplan-reduction-fission-max-scratch-bytes=259 -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.small 2> %t.small.remarks
; RUN: FileCheck %s --check-prefix=SMALL < %t.small
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.small -o /dev/null
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=1 -vplan-reduction-fission-force-accumulator-vf=2 \
; RUN:   -vplan-reduction-fission-min-chain-depth=16 -vplan-reduction-fission-max-scratch-bytes=260 -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.capacity 2> %t.capacity.remarks
; RUN: FileCheck %s --check-prefix=CAPACITY < %t.capacity
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.capacity -o /dev/null
; RUN: FileCheck %s --check-prefix=LIMIT < %t.small.remarks
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=4 -vplan-reduction-fission-force-accumulator-vf=1 \
; RUN:   -vplan-reduction-fission-min-chain-depth=16 -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.bad-producer 2> %t.bad-producer.remarks
; RUN: FileCheck %s --check-prefix=REJECT < %t.bad-producer
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.bad-producer -o /dev/null
; RUN: FileCheck %s --check-prefix=VF-LIMIT < %t.bad-producer.remarks
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=1 -vplan-reduction-fission-force-accumulator-vf=4 \
; RUN:   -vplan-reduction-fission-min-chain-depth=16 -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.bad-consumer 2> %t.bad-consumer.remarks
; RUN: FileCheck %s --check-prefix=REJECT < %t.bad-consumer
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.bad-consumer -o /dev/null
; RUN: FileCheck %s --check-prefix=VF-LIMIT < %t.bad-consumer.remarks

; Long arithmetic on member zero and short XORs of all other members
; retain the full group in both vector stages. Depth selects this cut; it
; does not veto other fission. No contribution arithmetic is duplicated, only the
; complete group and its address slice. VF4 is illegal in either stage.

; FORWARD-LABEL: define void @interleave5_reread(
; FORWARD-COUNT-1: alloca [65 x i32]
; FORWARD: vector.fission.producer.body:
; FORWARD: @llvm.vector.deinterleave5.nxv5
; FORWARD-COUNT-1: store <vscale x 1 x i32>
; FORWARD: scalar.fission.producer.body:
; FORWARD: load i32
; FORWARD: vector.fission.accumulator.body:
; FORWARD: @llvm.vector.deinterleave5.nxv10
; FORWARD: @llvm.vector.reduce.add.
; FORWARD: scalar.fission.accumulator.body:
; FORWARD: add i32
; REVERSE-LABEL: define void @interleave5_reread(
; REVERSE-COUNT-1: alloca [65 x i32]
; REVERSE: vector.fission.producer.body:
; REVERSE: @llvm.vector.deinterleave5.nxv10
; REVERSE-COUNT-1: store <vscale x 2 x i32>
; REVERSE: scalar.fission.producer.body:
; REVERSE: load i32
; REVERSE: vector.fission.accumulator.body:
; REVERSE: @llvm.vector.deinterleave5.nxv5
; REVERSE: @llvm.vector.reduce.add.
; REVERSE: scalar.fission.accumulator.body:
; REVERSE: add i32
; REMARK: interleave-wide-reread.c:10:5: split reduction loop: baseline VF {{.*}}, producer VF vscale x 1, accumulator VF vscale x 2, trip count bounded-runtime, scratch capacity 65, scratch bytes 260
; REMARK-SAME: scratch store bytes/iteration 4, scratch load bytes/iteration 4, duplicated recipes {{[1-9][0-9]*}}, reread loads/iteration 5
; SMALL-LABEL: define void @interleave5_reread(
; SMALL-NOT: fission
; SMALL: ret void
; LIMIT: interleave-wide-reread.c:10:5: reduction fission rejected: scratch byte limit exceeded
; CAPACITY-LABEL: define void @interleave5_reread(
; CAPACITY: alloca [65 x i32]
; CAPACITY: vector.fission.producer.body:
; REJECT-LABEL: define void @interleave5_reread(
; REJECT-NOT: fission
; REJECT: ret void
; VF-LIMIT: interleave-wide-reread.c:10:5: reduction fission rejected: forced-stage-vf-not-legal
define void @interleave5_reread(ptr readonly %a, ptr %out, i64 %n) !dbg !5 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !6
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [23, %preheader], [%u1, %loop]
  %base = mul nuw i64 %i, 5
  %idx4 = add nuw i64 %base, 4
  %p4 = getelementptr i32, ptr %a, i64 %idx4
  %x4 = load i32, ptr %p4, align 4
  %p0 = getelementptr i32, ptr %a, i64 %base
  %x0 = load i32, ptr %p0, align 4
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr i32, ptr %a, i64 %idx1
  %x1 = load i32, ptr %p1, align 4
  %idx2 = add nuw i64 %base, 2
  %p2 = getelementptr i32, ptr %a, i64 %idx2
  %x2 = load i32, ptr %p2, align 4
  %idx3 = add nuw i64 %base, 3
  %p3 = getelementptr i32, ptr %a, i64 %idx3
  %x3 = load i32, ptr %p3, align 4
  %c0 = mul i32 %x0, 3
  %c1 = xor i32 %c0, 5
  %c2 = mul i32 %c1, 7
  %c3 = xor i32 %c2, 9
  %c4 = mul i32 %c3, 11
  %c5 = xor i32 %c4, 13
  %c6 = mul i32 %c5, 15
  %c7 = xor i32 %c6, 17
  %c8 = mul i32 %c7, 19
  %c9 = xor i32 %c8, 21
  %c10 = mul i32 %c9, 23
  %c11 = xor i32 %c10, 25
  %c12 = mul i32 %c11, 27
  %c13 = xor i32 %c12, 29
  %c14 = mul i32 %c13, 31
  %c15 = xor i32 %c14, 33
  %c16 = mul i32 %c15, 35
  %c17 = xor i32 %c16, 37
  %c18 = mul i32 %c17, 39
  %c19 = xor i32 %c18, 41
  %c20 = mul i32 %c19, 43
  %short2 = xor i32 %x1, %x2
  %short3 = xor i32 %short2, %x3
  %short4 = xor i32 %short3, %x4
  %u0 = add i32 %r0, %c20
  %u1 = xor i32 %r1, %short4
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !6
exit:
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %u0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %u1, ptr %o1, align 4
  ret void
bypass:
  %b0 = getelementptr i32, ptr %out, i64 0
  store i32 17, ptr %b0, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  ret void
}

; FORWARD-LABEL: define void @interleave8_reread(
; FORWARD-COUNT-1: alloca [65 x i32]
; FORWARD: vector.fission.producer.body:
; FORWARD: @llvm.vector.deinterleave8.nxv8
; FORWARD-COUNT-1: store <vscale x 1 x i32>
; FORWARD: scalar.fission.producer.body:
; FORWARD: load i32
; FORWARD: vector.fission.accumulator.body:
; FORWARD: @llvm.vector.deinterleave8.nxv16
; FORWARD: @llvm.vector.reduce.add.
; FORWARD: scalar.fission.accumulator.body:
; FORWARD: add i32
; REVERSE-LABEL: define void @interleave8_reread(
; REVERSE-COUNT-1: alloca [65 x i32]
; REVERSE: vector.fission.producer.body:
; REVERSE: @llvm.vector.deinterleave8.nxv16
; REVERSE-COUNT-1: store <vscale x 2 x i32>
; REVERSE: scalar.fission.producer.body:
; REVERSE: load i32
; REVERSE: vector.fission.accumulator.body:
; REVERSE: @llvm.vector.deinterleave8.nxv8
; REVERSE: @llvm.vector.reduce.add.
; REVERSE: scalar.fission.accumulator.body:
; REVERSE: add i32
; REMARK: interleave-wide-reread.c:30:5: split reduction loop: baseline VF {{.*}}, producer VF vscale x 1, accumulator VF vscale x 2, trip count bounded-runtime, scratch capacity 65, scratch bytes 260
; REMARK-SAME: scratch store bytes/iteration 4, scratch load bytes/iteration 4, duplicated recipes {{[1-9][0-9]*}}, reread loads/iteration 8
; SMALL-LABEL: define void @interleave8_reread(
; SMALL-NOT: fission
; SMALL: ret void
; LIMIT: interleave-wide-reread.c:30:5: reduction fission rejected: scratch byte limit exceeded
; CAPACITY-LABEL: define void @interleave8_reread(
; CAPACITY: alloca [65 x i32]
; CAPACITY: vector.fission.producer.body:
; REJECT-LABEL: define void @interleave8_reread(
; REJECT-NOT: fission
; REJECT: ret void
; VF-LIMIT: interleave-wide-reread.c:30:5: reduction fission rejected: forced-stage-vf-not-legal
define void @interleave8_reread(ptr readonly %a, ptr %out, i64 %n) !dbg !7 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !8
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [23, %preheader], [%u1, %loop]
  %base = mul nuw i64 %i, 8
  %idx7 = add nuw i64 %base, 7
  %p7 = getelementptr i32, ptr %a, i64 %idx7
  %x7 = load i32, ptr %p7, align 4
  %p0 = getelementptr i32, ptr %a, i64 %base
  %x0 = load i32, ptr %p0, align 4
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr i32, ptr %a, i64 %idx1
  %x1 = load i32, ptr %p1, align 4
  %idx2 = add nuw i64 %base, 2
  %p2 = getelementptr i32, ptr %a, i64 %idx2
  %x2 = load i32, ptr %p2, align 4
  %idx3 = add nuw i64 %base, 3
  %p3 = getelementptr i32, ptr %a, i64 %idx3
  %x3 = load i32, ptr %p3, align 4
  %idx4 = add nuw i64 %base, 4
  %p4 = getelementptr i32, ptr %a, i64 %idx4
  %x4 = load i32, ptr %p4, align 4
  %idx5 = add nuw i64 %base, 5
  %p5 = getelementptr i32, ptr %a, i64 %idx5
  %x5 = load i32, ptr %p5, align 4
  %idx6 = add nuw i64 %base, 6
  %p6 = getelementptr i32, ptr %a, i64 %idx6
  %x6 = load i32, ptr %p6, align 4
  %c0 = mul i32 %x0, 3
  %c1 = xor i32 %c0, 5
  %c2 = mul i32 %c1, 7
  %c3 = xor i32 %c2, 9
  %c4 = mul i32 %c3, 11
  %c5 = xor i32 %c4, 13
  %c6 = mul i32 %c5, 15
  %c7 = xor i32 %c6, 17
  %c8 = mul i32 %c7, 19
  %c9 = xor i32 %c8, 21
  %c10 = mul i32 %c9, 23
  %c11 = xor i32 %c10, 25
  %c12 = mul i32 %c11, 27
  %c13 = xor i32 %c12, 29
  %c14 = mul i32 %c13, 31
  %c15 = xor i32 %c14, 33
  %c16 = mul i32 %c15, 35
  %c17 = xor i32 %c16, 37
  %c18 = mul i32 %c17, 39
  %c19 = xor i32 %c18, 41
  %c20 = mul i32 %c19, 43
  %short2 = xor i32 %x1, %x2
  %short3 = xor i32 %short2, %x3
  %short4 = xor i32 %short3, %x4
  %short5 = xor i32 %short4, %x5
  %short6 = xor i32 %short5, %x6
  %short7 = xor i32 %short6, %x7
  %u0 = add i32 %r0, %c20
  %u1 = xor i32 %r1, %short7
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !8
exit:
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %u0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %u1, ptr %o1, align 4
  ret void
bypass:
  %b0 = getelementptr i32, ptr %out, i64 0
  store i32 17, ptr %b0, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  ret void
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2}
!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "interleave-wide-reread.c", directory: "/")
!2 = !{i32 2, !"Debug Info Version", i32 3}
!3 = !DISubroutineType(types: !4)
!4 = !{null}
!5 = distinct !DISubprogram(name: "interleave5_reread", scope: !1, file: !1, line: 10, type: !3, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!6 = !DILocation(line: 10, column: 5, scope: !5)
!7 = distinct !DISubprogram(name: "interleave8_reread", scope: !1, file: !1, line: 30, type: !3, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!8 = !DILocation(line: 30, column: 5, scope: !7)
