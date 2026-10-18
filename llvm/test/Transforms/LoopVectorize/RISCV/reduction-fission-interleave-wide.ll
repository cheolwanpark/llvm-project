; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 \
; RUN:   -pass-remarks=vplan-reduction-fission -S %s -o %t.forward 2> %t.forward.remarks
; RUN: FileCheck %s --check-prefix=FORWARD < %t.forward
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.forward -o /dev/null
; RUN: FileCheck %s --check-prefix=REMARK < %t.forward.remarks
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=1 \
; RUN:    -S %s -o %t.reverse 2> %t.reverse.remarks
; RUN: FileCheck %s --check-prefix=REVERSE < %t.reverse
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.reverse -o /dev/null
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=4 -vplan-reduction-fission-force-accumulator-vf=2 \
; RUN:   -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.four 2> %t.four.remarks
; RUN: FileCheck %s --check-prefix=FOUR < %t.four
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.four -o /dev/null
; RUN: FileCheck %s --check-prefix=VF-LIMIT < %t.four.remarks
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-min-chain-depth=1000 -vplan-reduction-fission-min-reductions=1000 \
; RUN:   -vplan-reduction-fission-min-pressure-percent=1000 -S %s | FileCheck %s --check-prefix=AUTO
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=259 -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.term-small 2> %t.term-small.remarks
; RUN: FileCheck %s --check-prefix=TERM-SMALL < %t.term-small
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.term-small -o /dev/null
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=260 -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.term-cap 2> %t.term-cap.remarks
; RUN: FileCheck %s --check-prefix=TERM-CAP < %t.term-cap
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.term-cap -o /dev/null
; RUN: FileCheck %s --check-prefix=TERM-LIMIT < %t.term-small.remarks
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=1039 -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.m4-small 2> %t.m4-small.remarks
; RUN: FileCheck %s --check-prefix=M4-SMALL < %t.m4-small
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.m4-small -o /dev/null
; RUN: FileCheck %s --check-prefix=M4-LIMIT < %t.m4-small.remarks
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=1040 -S %s -o %t.m4-cap 2> %t.m4-cap.remarks
; RUN: FileCheck %s --check-prefix=M4-CAP < %t.m4-cap
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.m4-cap -o /dev/null
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=1299 -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.m5-small 2> %t.m5-small.remarks
; RUN: FileCheck %s --check-prefix=M5-SMALL < %t.m5-small
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.m5-small -o /dev/null
; RUN: FileCheck %s --check-prefix=M5-LIMIT < %t.m5-small.remarks
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=1300 -S %s -o %t.m5-cap 2> %t.m5-cap.remarks
; RUN: FileCheck %s --check-prefix=M5-CAP < %t.m5-cap
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.m5-cap -o /dev/null
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=1559 -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.m6-small 2> %t.m6-small.remarks
; RUN: FileCheck %s --check-prefix=M6-SMALL < %t.m6-small
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.m6-small -o /dev/null
; RUN: FileCheck %s --check-prefix=M6-LIMIT < %t.m6-small.remarks
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=1560 -S %s -o %t.m6-cap 2> %t.m6-cap.remarks
; RUN: FileCheck %s --check-prefix=M6-CAP < %t.m6-cap
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.m6-cap -o /dev/null
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=1819 -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.m7-small 2> %t.m7-small.remarks
; RUN: FileCheck %s --check-prefix=M7-SMALL < %t.m7-small
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.m7-small -o /dev/null
; RUN: FileCheck %s --check-prefix=M7-LIMIT < %t.m7-small.remarks
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=1820 -S %s -o %t.m7-cap 2> %t.m7-cap.remarks
; RUN: FileCheck %s --check-prefix=M7-CAP < %t.m7-cap
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.m7-cap -o /dev/null
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=2079 -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.m8-small 2> %t.m8-small.remarks
; RUN: FileCheck %s --check-prefix=M8-SMALL < %t.m8-small
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.m8-small -o /dev/null
; RUN: FileCheck %s --check-prefix=M8-LIMIT < %t.m8-small.remarks
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=2080 -S %s -o %t.m8-cap 2> %t.m8-cap.remarks
; RUN: FileCheck %s --check-prefix=M8-CAP < %t.m8-cap
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.m8-cap -o /dev/null

; Complete homogeneous forward simple-load groups of every supported larger
; factor. The last member is loaded first. Computed contributions use member
; zero repeatedly; direct member frontiers include a repeated last-member
; reduction, which must share its slot. No noalias or fast-math assumptions.
; The checker executes all four stages, policies and legal VF orders.
; i32 member VF2 is M1; VF4 is M2. Only factor four permits group VF4.
; A scratch-only consumer can independently select VF4 for every factor.

; FORWARD-LABEL: define void @interleave4(
; FORWARD-COUNT-1: alloca [65 x i32]
; FORWARD: vector.fission.producer.body:
; FORWARD: @llvm.vector.deinterleave4.nxv8
; FORWARD-COUNT-1: store <vscale x 2 x i32>
; FORWARD: scalar.fission.producer.body:
; FORWARD: load i32
; FORWARD: vector.fission.accumulator.body:
; FORWARD: @llvm.vector.reduce.add.
; FORWARD: scalar.fission.accumulator.body:
; FORWARD: add i32
; REVERSE-LABEL: define void @interleave4(
; REVERSE-COUNT-1: alloca [65 x i32]
; REVERSE: vector.fission.producer.body:
; REVERSE: @llvm.vector.deinterleave4.nxv8
; REVERSE-COUNT-1: store <vscale x 2 x i32>
; REVERSE: scalar.fission.producer.body:
; REVERSE: load i32
; REVERSE: vector.fission.accumulator.body:
; REVERSE: @llvm.vector.reduce.add.
; REVERSE: scalar.fission.accumulator.body:
; REVERSE: add i32
; FOUR-LABEL: define void @interleave4(
; FOUR-COUNT-1: alloca [65 x i32]
; FOUR: vector.fission.producer.body:
; FOUR: @llvm.vector.deinterleave4.nxv16
; FOUR-COUNT-1: store <vscale x 4 x i32>
; FOUR: scalar.fission.producer.body:
; FOUR: load i32
; FOUR: vector.fission.accumulator.body:
; FOUR: @llvm.vector.reduce.add.
; FOUR: scalar.fission.accumulator.body:
; FOUR: add i32
; AUTO-LABEL: define void @interleave4(
; AUTO: vector.fission.producer.body:
; AUTO: vector.fission.accumulator.body:
; REMARK: interleave-wide.c:10:5: split reduction loop: baseline VF {{.*}}, producer VF vscale x 2, accumulator VF vscale x 4, trip count bounded-runtime, scratch capacity 65, scratch bytes 260
; REMARK-SAME: scratch store bytes/iteration 4, scratch load bytes/iteration 4, duplicated recipes 0, reread loads/iteration 0
; TERM-SMALL-LABEL: define void @interleave4(
; TERM-SMALL-NOT: fission
; TERM-SMALL: ret void
; TERM-LIMIT: interleave-wide.c:10:5: reduction fission rejected: scratch byte limit exceeded
; TERM-CAP-LABEL: define void @interleave4(
; TERM-CAP: alloca [65 x i32]
; TERM-CAP: vector.fission.producer.body:
define void @interleave4(ptr readonly %a, ptr %out, i64 %n) !dbg !5 {
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
  %base = mul nuw i64 %i, 4
  %idx3 = add nuw i64 %base, 3
  %p3 = getelementptr i32, ptr %a, i64 %idx3
  %x3 = load i32, ptr %p3, align 4
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
  %term1 = add i32 %shared, %x1
  %term2 = xor i32 %term1, %x2
  %term3 = add i32 %term2, %x3
  %u0 = add i32 %r0, %term3
  %u1 = xor i32 %r1, %term3
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

; FORWARD-LABEL: define void @interleave4_members(
; FORWARD-COUNT-4: alloca [65 x i32]
; FORWARD: vector.fission.producer.body:
; FORWARD: @llvm.vector.deinterleave4.nxv8
; FORWARD-COUNT-4: store <vscale x 2 x i32>
; FORWARD: scalar.fission.producer.body:
; FORWARD: load i32
; FORWARD: vector.fission.accumulator.body:
; FORWARD: @llvm.vector.reduce.add.
; FORWARD: scalar.fission.accumulator.body:
; FORWARD: add i32
; REVERSE-LABEL: define void @interleave4_members(
; REVERSE-COUNT-4: alloca [65 x i32]
; REVERSE: vector.fission.producer.body:
; REVERSE: @llvm.vector.deinterleave4.nxv8
; REVERSE-COUNT-4: store <vscale x 2 x i32>
; REVERSE: scalar.fission.producer.body:
; REVERSE: load i32
; REVERSE: vector.fission.accumulator.body:
; REVERSE: @llvm.vector.reduce.add.
; REVERSE: scalar.fission.accumulator.body:
; REVERSE: add i32
; FOUR-LABEL: define void @interleave4_members(
; FOUR-COUNT-4: alloca [65 x i32]
; FOUR: vector.fission.producer.body:
; FOUR: @llvm.vector.deinterleave4.nxv16
; FOUR-COUNT-4: store <vscale x 4 x i32>
; FOUR: scalar.fission.producer.body:
; FOUR: load i32
; FOUR: vector.fission.accumulator.body:
; FOUR: @llvm.vector.reduce.add.
; FOUR: scalar.fission.accumulator.body:
; FOUR: add i32
; AUTO-LABEL: define void @interleave4_members(
; AUTO: vector.fission.producer.body:
; AUTO: vector.fission.accumulator.body:
; REMARK: interleave-wide.c:30:5: split reduction loop: baseline VF {{.*}}, producer VF vscale x 2, accumulator VF vscale x 4, trip count bounded-runtime, scratch capacity 65, scratch bytes 1040
; REMARK-SAME: scratch store bytes/iteration 16, scratch load bytes/iteration 16, duplicated recipes 0, reread loads/iteration 0
; M4-SMALL-LABEL: define void @interleave4_members(
; M4-SMALL-NOT: fission
; M4-SMALL: ret void
; M4-LIMIT: interleave-wide.c:30:5: reduction fission rejected: scratch byte limit exceeded
; M4-CAP-LABEL: define void @interleave4_members(
; M4-CAP-COUNT-4: alloca [65 x i32]
; M4-CAP: vector.fission.producer.body:
; M4-CAP: vector.fission.accumulator.body:
define void @interleave4_members(ptr readonly %a, ptr %out, i64 %n) !dbg !7 {
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
  %r2 = phi i32 [29, %preheader], [%u2, %loop]
  %r3 = phi i32 [35, %preheader], [%u3, %loop]
  %r4 = phi i32 [41, %preheader], [%u4, %loop]
  %base = mul nuw i64 %i, 4
  %idx3 = add nuw i64 %base, 3
  %p3 = getelementptr i32, ptr %a, i64 %idx3
  %x3 = load i32, ptr %p3, align 4
  %p0 = getelementptr i32, ptr %a, i64 %base
  %x0 = load i32, ptr %p0, align 4
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr i32, ptr %a, i64 %idx1
  %x1 = load i32, ptr %p1, align 4
  %idx2 = add nuw i64 %base, 2
  %p2 = getelementptr i32, ptr %a, i64 %idx2
  %x2 = load i32, ptr %p2, align 4
  %u0 = add i32 %r0, %x0
  %u1 = xor i32 %r1, %x1
  %u2 = add i32 %r2, %x2
  %u3 = xor i32 %r3, %x3
  %u4 = add i32 %r4, %x3
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !8
exit:
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %u0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %u1, ptr %o1, align 4
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %u2, ptr %o2, align 4
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %u3, ptr %o3, align 4
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %u4, ptr %o4, align 4
  ret void
bypass:
  %b0 = getelementptr i32, ptr %out, i64 0
  store i32 17, ptr %b0, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  %b2 = getelementptr i32, ptr %out, i64 2
  store i32 29, ptr %b2, align 4
  %b3 = getelementptr i32, ptr %out, i64 3
  store i32 35, ptr %b3, align 4
  %b4 = getelementptr i32, ptr %out, i64 4
  store i32 41, ptr %b4, align 4
  ret void
}

; FORWARD-LABEL: define void @interleave5(
; FORWARD-COUNT-1: alloca [65 x i32]
; FORWARD: vector.fission.producer.body:
; FORWARD: @llvm.vector.deinterleave5.nxv10
; FORWARD-COUNT-1: store <vscale x 2 x i32>
; FORWARD: scalar.fission.producer.body:
; FORWARD: load i32
; FORWARD: vector.fission.accumulator.body:
; FORWARD: @llvm.vector.reduce.add.
; FORWARD: scalar.fission.accumulator.body:
; FORWARD: add i32
; REVERSE-LABEL: define void @interleave5(
; REVERSE-COUNT-1: alloca [65 x i32]
; REVERSE: vector.fission.producer.body:
; REVERSE: @llvm.vector.deinterleave5.nxv10
; REVERSE-COUNT-1: store <vscale x 2 x i32>
; REVERSE: scalar.fission.producer.body:
; REVERSE: load i32
; REVERSE: vector.fission.accumulator.body:
; REVERSE: @llvm.vector.reduce.add.
; REVERSE: scalar.fission.accumulator.body:
; REVERSE: add i32
; AUTO-LABEL: define void @interleave5(
; AUTO: vector.fission.producer.body:
; AUTO: vector.fission.accumulator.body:
; REMARK: interleave-wide.c:50:5: split reduction loop: baseline VF {{.*}}, producer VF vscale x 2, accumulator VF vscale x 4, trip count bounded-runtime, scratch capacity 65, scratch bytes 260
; REMARK-SAME: scratch store bytes/iteration 4, scratch load bytes/iteration 4, duplicated recipes 0, reread loads/iteration 0
; FOUR-LABEL: define void @interleave5(
; FOUR-NOT: fission
; FOUR: ret void
; VF-LIMIT: interleave-wide.c:50:5: reduction fission rejected: forced-stage-vf-not-legal
; TERM-SMALL-LABEL: define void @interleave5(
; TERM-SMALL-NOT: fission
; TERM-SMALL: ret void
; TERM-LIMIT: interleave-wide.c:50:5: reduction fission rejected: scratch byte limit exceeded
; TERM-CAP-LABEL: define void @interleave5(
; TERM-CAP: alloca [65 x i32]
; TERM-CAP: vector.fission.producer.body:
define void @interleave5(ptr readonly %a, ptr %out, i64 %n) !dbg !9 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !10
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
  %scaled = mul i32 %x0, 3
  %shared = xor i32 %scaled, %x0
  %term1 = add i32 %shared, %x1
  %term2 = xor i32 %term1, %x2
  %term3 = add i32 %term2, %x3
  %term4 = xor i32 %term3, %x4
  %u0 = add i32 %r0, %term4
  %u1 = xor i32 %r1, %term4
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !10
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

; FORWARD-LABEL: define void @interleave5_members(
; FORWARD-COUNT-5: alloca [65 x i32]
; FORWARD: vector.fission.producer.body:
; FORWARD: @llvm.vector.deinterleave5.nxv10
; FORWARD-COUNT-5: store <vscale x 2 x i32>
; FORWARD: scalar.fission.producer.body:
; FORWARD: load i32
; FORWARD: vector.fission.accumulator.body:
; FORWARD: @llvm.vector.reduce.add.
; FORWARD: scalar.fission.accumulator.body:
; FORWARD: add i32
; REVERSE-LABEL: define void @interleave5_members(
; REVERSE-COUNT-5: alloca [65 x i32]
; REVERSE: vector.fission.producer.body:
; REVERSE: @llvm.vector.deinterleave5.nxv10
; REVERSE-COUNT-5: store <vscale x 2 x i32>
; REVERSE: scalar.fission.producer.body:
; REVERSE: load i32
; REVERSE: vector.fission.accumulator.body:
; REVERSE: @llvm.vector.reduce.add.
; REVERSE: scalar.fission.accumulator.body:
; REVERSE: add i32
; AUTO-LABEL: define void @interleave5_members(
; AUTO: vector.fission.producer.body:
; AUTO: vector.fission.accumulator.body:
; REMARK: interleave-wide.c:70:5: split reduction loop: baseline VF {{.*}}, producer VF vscale x 2, accumulator VF vscale x 4, trip count bounded-runtime, scratch capacity 65, scratch bytes 1300
; REMARK-SAME: scratch store bytes/iteration 20, scratch load bytes/iteration 20, duplicated recipes 0, reread loads/iteration 0
; FOUR-LABEL: define void @interleave5_members(
; FOUR-NOT: fission
; FOUR: ret void
; VF-LIMIT: interleave-wide.c:70:5: reduction fission rejected: forced-stage-vf-not-legal
; M5-SMALL-LABEL: define void @interleave5_members(
; M5-SMALL-NOT: fission
; M5-SMALL: ret void
; M5-LIMIT: interleave-wide.c:70:5: reduction fission rejected: scratch byte limit exceeded
; M5-CAP-LABEL: define void @interleave5_members(
; M5-CAP-COUNT-5: alloca [65 x i32]
; M5-CAP: vector.fission.producer.body:
; M5-CAP: vector.fission.accumulator.body:
define void @interleave5_members(ptr readonly %a, ptr %out, i64 %n) !dbg !11 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !12
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [23, %preheader], [%u1, %loop]
  %r2 = phi i32 [29, %preheader], [%u2, %loop]
  %r3 = phi i32 [35, %preheader], [%u3, %loop]
  %r4 = phi i32 [41, %preheader], [%u4, %loop]
  %r5 = phi i32 [47, %preheader], [%u5, %loop]
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
  %u0 = add i32 %r0, %x0
  %u1 = xor i32 %r1, %x1
  %u2 = add i32 %r2, %x2
  %u3 = xor i32 %r3, %x3
  %u4 = add i32 %r4, %x4
  %u5 = xor i32 %r5, %x4
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !12
exit:
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %u0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %u1, ptr %o1, align 4
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %u2, ptr %o2, align 4
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %u3, ptr %o3, align 4
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %u4, ptr %o4, align 4
  %o5 = getelementptr i32, ptr %out, i64 5
  store i32 %u5, ptr %o5, align 4
  ret void
bypass:
  %b0 = getelementptr i32, ptr %out, i64 0
  store i32 17, ptr %b0, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  %b2 = getelementptr i32, ptr %out, i64 2
  store i32 29, ptr %b2, align 4
  %b3 = getelementptr i32, ptr %out, i64 3
  store i32 35, ptr %b3, align 4
  %b4 = getelementptr i32, ptr %out, i64 4
  store i32 41, ptr %b4, align 4
  %b5 = getelementptr i32, ptr %out, i64 5
  store i32 47, ptr %b5, align 4
  ret void
}

; FORWARD-LABEL: define void @interleave6(
; FORWARD-COUNT-1: alloca [65 x i32]
; FORWARD: vector.fission.producer.body:
; FORWARD: @llvm.vector.deinterleave6.nxv12
; FORWARD-COUNT-1: store <vscale x 2 x i32>
; FORWARD: scalar.fission.producer.body:
; FORWARD: load i32
; FORWARD: vector.fission.accumulator.body:
; FORWARD: @llvm.vector.reduce.add.
; FORWARD: scalar.fission.accumulator.body:
; FORWARD: add i32
; REVERSE-LABEL: define void @interleave6(
; REVERSE-COUNT-1: alloca [65 x i32]
; REVERSE: vector.fission.producer.body:
; REVERSE: @llvm.vector.deinterleave6.nxv12
; REVERSE-COUNT-1: store <vscale x 2 x i32>
; REVERSE: scalar.fission.producer.body:
; REVERSE: load i32
; REVERSE: vector.fission.accumulator.body:
; REVERSE: @llvm.vector.reduce.add.
; REVERSE: scalar.fission.accumulator.body:
; REVERSE: add i32
; AUTO-LABEL: define void @interleave6(
; AUTO: vector.fission.producer.body:
; AUTO: vector.fission.accumulator.body:
; REMARK: interleave-wide.c:90:5: split reduction loop: baseline VF {{.*}}, producer VF vscale x 2, accumulator VF vscale x 4, trip count bounded-runtime, scratch capacity 65, scratch bytes 260
; REMARK-SAME: scratch store bytes/iteration 4, scratch load bytes/iteration 4, duplicated recipes 0, reread loads/iteration 0
; FOUR-LABEL: define void @interleave6(
; FOUR-NOT: fission
; FOUR: ret void
; VF-LIMIT: interleave-wide.c:90:5: reduction fission rejected: forced-stage-vf-not-legal
; TERM-SMALL-LABEL: define void @interleave6(
; TERM-SMALL-NOT: fission
; TERM-SMALL: ret void
; TERM-LIMIT: interleave-wide.c:90:5: reduction fission rejected: scratch byte limit exceeded
; TERM-CAP-LABEL: define void @interleave6(
; TERM-CAP: alloca [65 x i32]
; TERM-CAP: vector.fission.producer.body:
define void @interleave6(ptr readonly %a, ptr %out, i64 %n) !dbg !13 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !14
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [23, %preheader], [%u1, %loop]
  %base = mul nuw i64 %i, 6
  %idx5 = add nuw i64 %base, 5
  %p5 = getelementptr i32, ptr %a, i64 %idx5
  %x5 = load i32, ptr %p5, align 4
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
  %scaled = mul i32 %x0, 3
  %shared = xor i32 %scaled, %x0
  %term1 = add i32 %shared, %x1
  %term2 = xor i32 %term1, %x2
  %term3 = add i32 %term2, %x3
  %term4 = xor i32 %term3, %x4
  %term5 = add i32 %term4, %x5
  %u0 = add i32 %r0, %term5
  %u1 = xor i32 %r1, %term5
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !14
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

; FORWARD-LABEL: define void @interleave6_members(
; FORWARD-COUNT-6: alloca [65 x i32]
; FORWARD: vector.fission.producer.body:
; FORWARD: @llvm.vector.deinterleave6.nxv12
; FORWARD-COUNT-6: store <vscale x 2 x i32>
; FORWARD: scalar.fission.producer.body:
; FORWARD: load i32
; FORWARD: vector.fission.accumulator.body:
; FORWARD: @llvm.vector.reduce.add.
; FORWARD: scalar.fission.accumulator.body:
; FORWARD: add i32
; REVERSE-LABEL: define void @interleave6_members(
; REVERSE-COUNT-6: alloca [65 x i32]
; REVERSE: vector.fission.producer.body:
; REVERSE: @llvm.vector.deinterleave6.nxv12
; REVERSE-COUNT-6: store <vscale x 2 x i32>
; REVERSE: scalar.fission.producer.body:
; REVERSE: load i32
; REVERSE: vector.fission.accumulator.body:
; REVERSE: @llvm.vector.reduce.add.
; REVERSE: scalar.fission.accumulator.body:
; REVERSE: add i32
; AUTO-LABEL: define void @interleave6_members(
; AUTO: vector.fission.producer.body:
; AUTO: vector.fission.accumulator.body:
; REMARK: interleave-wide.c:110:5: split reduction loop: baseline VF {{.*}}, producer VF vscale x 2, accumulator VF vscale x 4, trip count bounded-runtime, scratch capacity 65, scratch bytes 1560
; REMARK-SAME: scratch store bytes/iteration 24, scratch load bytes/iteration 24, duplicated recipes 0, reread loads/iteration 0
; FOUR-LABEL: define void @interleave6_members(
; FOUR-NOT: fission
; FOUR: ret void
; VF-LIMIT: interleave-wide.c:110:5: reduction fission rejected: forced-stage-vf-not-legal
; M6-SMALL-LABEL: define void @interleave6_members(
; M6-SMALL-NOT: fission
; M6-SMALL: ret void
; M6-LIMIT: interleave-wide.c:110:5: reduction fission rejected: scratch byte limit exceeded
; M6-CAP-LABEL: define void @interleave6_members(
; M6-CAP-COUNT-6: alloca [65 x i32]
; M6-CAP: vector.fission.producer.body:
; M6-CAP: vector.fission.accumulator.body:
define void @interleave6_members(ptr readonly %a, ptr %out, i64 %n) !dbg !15 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !16
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [23, %preheader], [%u1, %loop]
  %r2 = phi i32 [29, %preheader], [%u2, %loop]
  %r3 = phi i32 [35, %preheader], [%u3, %loop]
  %r4 = phi i32 [41, %preheader], [%u4, %loop]
  %r5 = phi i32 [47, %preheader], [%u5, %loop]
  %r6 = phi i32 [53, %preheader], [%u6, %loop]
  %base = mul nuw i64 %i, 6
  %idx5 = add nuw i64 %base, 5
  %p5 = getelementptr i32, ptr %a, i64 %idx5
  %x5 = load i32, ptr %p5, align 4
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
  %u0 = add i32 %r0, %x0
  %u1 = xor i32 %r1, %x1
  %u2 = add i32 %r2, %x2
  %u3 = xor i32 %r3, %x3
  %u4 = add i32 %r4, %x4
  %u5 = xor i32 %r5, %x5
  %u6 = add i32 %r6, %x5
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !16
exit:
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %u0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %u1, ptr %o1, align 4
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %u2, ptr %o2, align 4
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %u3, ptr %o3, align 4
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %u4, ptr %o4, align 4
  %o5 = getelementptr i32, ptr %out, i64 5
  store i32 %u5, ptr %o5, align 4
  %o6 = getelementptr i32, ptr %out, i64 6
  store i32 %u6, ptr %o6, align 4
  ret void
bypass:
  %b0 = getelementptr i32, ptr %out, i64 0
  store i32 17, ptr %b0, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  %b2 = getelementptr i32, ptr %out, i64 2
  store i32 29, ptr %b2, align 4
  %b3 = getelementptr i32, ptr %out, i64 3
  store i32 35, ptr %b3, align 4
  %b4 = getelementptr i32, ptr %out, i64 4
  store i32 41, ptr %b4, align 4
  %b5 = getelementptr i32, ptr %out, i64 5
  store i32 47, ptr %b5, align 4
  %b6 = getelementptr i32, ptr %out, i64 6
  store i32 53, ptr %b6, align 4
  ret void
}

; FORWARD-LABEL: define void @interleave7(
; FORWARD-COUNT-1: alloca [65 x i32]
; FORWARD: vector.fission.producer.body:
; FORWARD: @llvm.vector.deinterleave7.nxv14
; FORWARD-COUNT-1: store <vscale x 2 x i32>
; FORWARD: scalar.fission.producer.body:
; FORWARD: load i32
; FORWARD: vector.fission.accumulator.body:
; FORWARD: @llvm.vector.reduce.add.
; FORWARD: scalar.fission.accumulator.body:
; FORWARD: add i32
; REVERSE-LABEL: define void @interleave7(
; REVERSE-COUNT-1: alloca [65 x i32]
; REVERSE: vector.fission.producer.body:
; REVERSE: @llvm.vector.deinterleave7.nxv14
; REVERSE-COUNT-1: store <vscale x 2 x i32>
; REVERSE: scalar.fission.producer.body:
; REVERSE: load i32
; REVERSE: vector.fission.accumulator.body:
; REVERSE: @llvm.vector.reduce.add.
; REVERSE: scalar.fission.accumulator.body:
; REVERSE: add i32
; AUTO-LABEL: define void @interleave7(
; AUTO: vector.fission.producer.body:
; AUTO: vector.fission.accumulator.body:
; REMARK: interleave-wide.c:130:5: split reduction loop: baseline VF {{.*}}, producer VF vscale x 2, accumulator VF vscale x 4, trip count bounded-runtime, scratch capacity 65, scratch bytes 260
; REMARK-SAME: scratch store bytes/iteration 4, scratch load bytes/iteration 4, duplicated recipes 0, reread loads/iteration 0
; FOUR-LABEL: define void @interleave7(
; FOUR-NOT: fission
; FOUR: ret void
; VF-LIMIT: interleave-wide.c:130:5: reduction fission rejected: forced-stage-vf-not-legal
; TERM-SMALL-LABEL: define void @interleave7(
; TERM-SMALL-NOT: fission
; TERM-SMALL: ret void
; TERM-LIMIT: interleave-wide.c:130:5: reduction fission rejected: scratch byte limit exceeded
; TERM-CAP-LABEL: define void @interleave7(
; TERM-CAP: alloca [65 x i32]
; TERM-CAP: vector.fission.producer.body:
define void @interleave7(ptr readonly %a, ptr %out, i64 %n) !dbg !17 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !18
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [23, %preheader], [%u1, %loop]
  %base = mul nuw i64 %i, 7
  %idx6 = add nuw i64 %base, 6
  %p6 = getelementptr i32, ptr %a, i64 %idx6
  %x6 = load i32, ptr %p6, align 4
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
  %scaled = mul i32 %x0, 3
  %shared = xor i32 %scaled, %x0
  %term1 = add i32 %shared, %x1
  %term2 = xor i32 %term1, %x2
  %term3 = add i32 %term2, %x3
  %term4 = xor i32 %term3, %x4
  %term5 = add i32 %term4, %x5
  %term6 = xor i32 %term5, %x6
  %u0 = add i32 %r0, %term6
  %u1 = xor i32 %r1, %term6
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !18
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

; FORWARD-LABEL: define void @interleave7_members(
; FORWARD-COUNT-7: alloca [65 x i32]
; FORWARD: vector.fission.producer.body:
; FORWARD: @llvm.vector.deinterleave7.nxv14
; FORWARD-COUNT-7: store <vscale x 2 x i32>
; FORWARD: scalar.fission.producer.body:
; FORWARD: load i32
; FORWARD: vector.fission.accumulator.body:
; FORWARD: @llvm.vector.reduce.add.
; FORWARD: scalar.fission.accumulator.body:
; FORWARD: add i32
; REVERSE-LABEL: define void @interleave7_members(
; REVERSE-COUNT-7: alloca [65 x i32]
; REVERSE: vector.fission.producer.body:
; REVERSE: @llvm.vector.deinterleave7.nxv14
; REVERSE-COUNT-7: store <vscale x 2 x i32>
; REVERSE: scalar.fission.producer.body:
; REVERSE: load i32
; REVERSE: vector.fission.accumulator.body:
; REVERSE: @llvm.vector.reduce.add.
; REVERSE: scalar.fission.accumulator.body:
; REVERSE: add i32
; AUTO-LABEL: define void @interleave7_members(
; AUTO: vector.fission.producer.body:
; AUTO: vector.fission.accumulator.body:
; REMARK: interleave-wide.c:150:5: split reduction loop: baseline VF {{.*}}, producer VF vscale x 2, accumulator VF vscale x 4, trip count bounded-runtime, scratch capacity 65, scratch bytes 1820
; REMARK-SAME: scratch store bytes/iteration 28, scratch load bytes/iteration 28, duplicated recipes 0, reread loads/iteration 0
; FOUR-LABEL: define void @interleave7_members(
; FOUR-NOT: fission
; FOUR: ret void
; VF-LIMIT: interleave-wide.c:150:5: reduction fission rejected: forced-stage-vf-not-legal
; M7-SMALL-LABEL: define void @interleave7_members(
; M7-SMALL-NOT: fission
; M7-SMALL: ret void
; M7-LIMIT: interleave-wide.c:150:5: reduction fission rejected: scratch byte limit exceeded
; M7-CAP-LABEL: define void @interleave7_members(
; M7-CAP-COUNT-7: alloca [65 x i32]
; M7-CAP: vector.fission.producer.body:
; M7-CAP: vector.fission.accumulator.body:
define void @interleave7_members(ptr readonly %a, ptr %out, i64 %n) !dbg !19 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !20
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [23, %preheader], [%u1, %loop]
  %r2 = phi i32 [29, %preheader], [%u2, %loop]
  %r3 = phi i32 [35, %preheader], [%u3, %loop]
  %r4 = phi i32 [41, %preheader], [%u4, %loop]
  %r5 = phi i32 [47, %preheader], [%u5, %loop]
  %r6 = phi i32 [53, %preheader], [%u6, %loop]
  %r7 = phi i32 [59, %preheader], [%u7, %loop]
  %base = mul nuw i64 %i, 7
  %idx6 = add nuw i64 %base, 6
  %p6 = getelementptr i32, ptr %a, i64 %idx6
  %x6 = load i32, ptr %p6, align 4
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
  %u0 = add i32 %r0, %x0
  %u1 = xor i32 %r1, %x1
  %u2 = add i32 %r2, %x2
  %u3 = xor i32 %r3, %x3
  %u4 = add i32 %r4, %x4
  %u5 = xor i32 %r5, %x5
  %u6 = add i32 %r6, %x6
  %u7 = xor i32 %r7, %x6
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !20
exit:
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %u0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %u1, ptr %o1, align 4
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %u2, ptr %o2, align 4
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %u3, ptr %o3, align 4
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %u4, ptr %o4, align 4
  %o5 = getelementptr i32, ptr %out, i64 5
  store i32 %u5, ptr %o5, align 4
  %o6 = getelementptr i32, ptr %out, i64 6
  store i32 %u6, ptr %o6, align 4
  %o7 = getelementptr i32, ptr %out, i64 7
  store i32 %u7, ptr %o7, align 4
  ret void
bypass:
  %b0 = getelementptr i32, ptr %out, i64 0
  store i32 17, ptr %b0, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  %b2 = getelementptr i32, ptr %out, i64 2
  store i32 29, ptr %b2, align 4
  %b3 = getelementptr i32, ptr %out, i64 3
  store i32 35, ptr %b3, align 4
  %b4 = getelementptr i32, ptr %out, i64 4
  store i32 41, ptr %b4, align 4
  %b5 = getelementptr i32, ptr %out, i64 5
  store i32 47, ptr %b5, align 4
  %b6 = getelementptr i32, ptr %out, i64 6
  store i32 53, ptr %b6, align 4
  %b7 = getelementptr i32, ptr %out, i64 7
  store i32 59, ptr %b7, align 4
  ret void
}

; FORWARD-LABEL: define void @interleave8(
; FORWARD-COUNT-1: alloca [65 x i32]
; FORWARD: vector.fission.producer.body:
; FORWARD: @llvm.vector.deinterleave8.nxv16
; FORWARD-COUNT-1: store <vscale x 2 x i32>
; FORWARD: scalar.fission.producer.body:
; FORWARD: load i32
; FORWARD: vector.fission.accumulator.body:
; FORWARD: @llvm.vector.reduce.add.
; FORWARD: scalar.fission.accumulator.body:
; FORWARD: add i32
; REVERSE-LABEL: define void @interleave8(
; REVERSE-COUNT-1: alloca [65 x i32]
; REVERSE: vector.fission.producer.body:
; REVERSE: @llvm.vector.deinterleave8.nxv16
; REVERSE-COUNT-1: store <vscale x 2 x i32>
; REVERSE: scalar.fission.producer.body:
; REVERSE: load i32
; REVERSE: vector.fission.accumulator.body:
; REVERSE: @llvm.vector.reduce.add.
; REVERSE: scalar.fission.accumulator.body:
; REVERSE: add i32
; AUTO-LABEL: define void @interleave8(
; AUTO: vector.fission.producer.body:
; AUTO: vector.fission.accumulator.body:
; REMARK: interleave-wide.c:170:5: split reduction loop: baseline VF {{.*}}, producer VF vscale x 2, accumulator VF vscale x 4, trip count bounded-runtime, scratch capacity 65, scratch bytes 260
; REMARK-SAME: scratch store bytes/iteration 4, scratch load bytes/iteration 4, duplicated recipes 0, reread loads/iteration 0
; FOUR-LABEL: define void @interleave8(
; FOUR-NOT: fission
; FOUR: ret void
; VF-LIMIT: interleave-wide.c:170:5: reduction fission rejected: forced-stage-vf-not-legal
; TERM-SMALL-LABEL: define void @interleave8(
; TERM-SMALL-NOT: fission
; TERM-SMALL: ret void
; TERM-LIMIT: interleave-wide.c:170:5: reduction fission rejected: scratch byte limit exceeded
; TERM-CAP-LABEL: define void @interleave8(
; TERM-CAP: alloca [65 x i32]
; TERM-CAP: vector.fission.producer.body:
define void @interleave8(ptr readonly %a, ptr %out, i64 %n) !dbg !21 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !22
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
  %scaled = mul i32 %x0, 3
  %shared = xor i32 %scaled, %x0
  %term1 = add i32 %shared, %x1
  %term2 = xor i32 %term1, %x2
  %term3 = add i32 %term2, %x3
  %term4 = xor i32 %term3, %x4
  %term5 = add i32 %term4, %x5
  %term6 = xor i32 %term5, %x6
  %term7 = add i32 %term6, %x7
  %u0 = add i32 %r0, %term7
  %u1 = xor i32 %r1, %term7
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !22
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

; FORWARD-LABEL: define void @interleave8_members(
; FORWARD-COUNT-8: alloca [65 x i32]
; FORWARD: vector.fission.producer.body:
; FORWARD: @llvm.vector.deinterleave8.nxv16
; FORWARD-COUNT-8: store <vscale x 2 x i32>
; FORWARD: scalar.fission.producer.body:
; FORWARD: load i32
; FORWARD: vector.fission.accumulator.body:
; FORWARD: @llvm.vector.reduce.add.
; FORWARD: scalar.fission.accumulator.body:
; FORWARD: add i32
; REVERSE-LABEL: define void @interleave8_members(
; REVERSE-COUNT-8: alloca [65 x i32]
; REVERSE: vector.fission.producer.body:
; REVERSE: @llvm.vector.deinterleave8.nxv16
; REVERSE-COUNT-8: store <vscale x 2 x i32>
; REVERSE: scalar.fission.producer.body:
; REVERSE: load i32
; REVERSE: vector.fission.accumulator.body:
; REVERSE: @llvm.vector.reduce.add.
; REVERSE: scalar.fission.accumulator.body:
; REVERSE: add i32
; AUTO-LABEL: define void @interleave8_members(
; AUTO: vector.fission.producer.body:
; AUTO: vector.fission.accumulator.body:
; REMARK: interleave-wide.c:190:5: split reduction loop: baseline VF {{.*}}, producer VF vscale x 2, accumulator VF vscale x 4, trip count bounded-runtime, scratch capacity 65, scratch bytes 2080
; REMARK-SAME: scratch store bytes/iteration 32, scratch load bytes/iteration 32, duplicated recipes 0, reread loads/iteration 0
; FOUR-LABEL: define void @interleave8_members(
; FOUR-NOT: fission
; FOUR: ret void
; VF-LIMIT: interleave-wide.c:190:5: reduction fission rejected: forced-stage-vf-not-legal
; M8-SMALL-LABEL: define void @interleave8_members(
; M8-SMALL-NOT: fission
; M8-SMALL: ret void
; M8-LIMIT: interleave-wide.c:190:5: reduction fission rejected: scratch byte limit exceeded
; M8-CAP-LABEL: define void @interleave8_members(
; M8-CAP-COUNT-8: alloca [65 x i32]
; M8-CAP: vector.fission.producer.body:
; M8-CAP: vector.fission.accumulator.body:
define void @interleave8_members(ptr readonly %a, ptr %out, i64 %n) !dbg !23 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !24
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [23, %preheader], [%u1, %loop]
  %r2 = phi i32 [29, %preheader], [%u2, %loop]
  %r3 = phi i32 [35, %preheader], [%u3, %loop]
  %r4 = phi i32 [41, %preheader], [%u4, %loop]
  %r5 = phi i32 [47, %preheader], [%u5, %loop]
  %r6 = phi i32 [53, %preheader], [%u6, %loop]
  %r7 = phi i32 [59, %preheader], [%u7, %loop]
  %r8 = phi i32 [65, %preheader], [%u8, %loop]
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
  %u0 = add i32 %r0, %x0
  %u1 = xor i32 %r1, %x1
  %u2 = add i32 %r2, %x2
  %u3 = xor i32 %r3, %x3
  %u4 = add i32 %r4, %x4
  %u5 = xor i32 %r5, %x5
  %u6 = add i32 %r6, %x6
  %u7 = xor i32 %r7, %x7
  %u8 = add i32 %r8, %x7
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !24
exit:
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %u0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %u1, ptr %o1, align 4
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %u2, ptr %o2, align 4
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %u3, ptr %o3, align 4
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %u4, ptr %o4, align 4
  %o5 = getelementptr i32, ptr %out, i64 5
  store i32 %u5, ptr %o5, align 4
  %o6 = getelementptr i32, ptr %out, i64 6
  store i32 %u6, ptr %o6, align 4
  %o7 = getelementptr i32, ptr %out, i64 7
  store i32 %u7, ptr %o7, align 4
  %o8 = getelementptr i32, ptr %out, i64 8
  store i32 %u8, ptr %o8, align 4
  ret void
bypass:
  %b0 = getelementptr i32, ptr %out, i64 0
  store i32 17, ptr %b0, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  %b2 = getelementptr i32, ptr %out, i64 2
  store i32 29, ptr %b2, align 4
  %b3 = getelementptr i32, ptr %out, i64 3
  store i32 35, ptr %b3, align 4
  %b4 = getelementptr i32, ptr %out, i64 4
  store i32 41, ptr %b4, align 4
  %b5 = getelementptr i32, ptr %out, i64 5
  store i32 47, ptr %b5, align 4
  %b6 = getelementptr i32, ptr %out, i64 6
  store i32 53, ptr %b6, align 4
  %b7 = getelementptr i32, ptr %out, i64 7
  store i32 59, ptr %b7, align 4
  %b8 = getelementptr i32, ptr %out, i64 8
  store i32 65, ptr %b8, align 4
  ret void
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2}
!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "interleave-wide.c", directory: "/")
!2 = !{i32 2, !"Debug Info Version", i32 3}
!3 = !DISubroutineType(types: !4)
!4 = !{null}
!5 = distinct !DISubprogram(name: "interleave4", scope: !1, file: !1, line: 10, type: !3, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!6 = !DILocation(line: 10, column: 5, scope: !5)
!7 = distinct !DISubprogram(name: "interleave4_members", scope: !1, file: !1, line: 30, type: !3, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!8 = !DILocation(line: 30, column: 5, scope: !7)
!9 = distinct !DISubprogram(name: "interleave5", scope: !1, file: !1, line: 50, type: !3, scopeLine: 50, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!10 = !DILocation(line: 50, column: 5, scope: !9)
!11 = distinct !DISubprogram(name: "interleave5_members", scope: !1, file: !1, line: 70, type: !3, scopeLine: 70, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!12 = !DILocation(line: 70, column: 5, scope: !11)
!13 = distinct !DISubprogram(name: "interleave6", scope: !1, file: !1, line: 90, type: !3, scopeLine: 90, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!14 = !DILocation(line: 90, column: 5, scope: !13)
!15 = distinct !DISubprogram(name: "interleave6_members", scope: !1, file: !1, line: 110, type: !3, scopeLine: 110, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!16 = !DILocation(line: 110, column: 5, scope: !15)
!17 = distinct !DISubprogram(name: "interleave7", scope: !1, file: !1, line: 130, type: !3, scopeLine: 130, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!18 = !DILocation(line: 130, column: 5, scope: !17)
!19 = distinct !DISubprogram(name: "interleave7_members", scope: !1, file: !1, line: 150, type: !3, scopeLine: 150, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!20 = !DILocation(line: 150, column: 5, scope: !19)
!21 = distinct !DISubprogram(name: "interleave8", scope: !1, file: !1, line: 170, type: !3, scopeLine: 170, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!22 = !DILocation(line: 170, column: 5, scope: !21)
!23 = distinct !DISubprogram(name: "interleave8_members", scope: !1, file: !1, line: 190, type: !3, scopeLine: 190, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!24 = !DILocation(line: 190, column: 5, scope: !23)
