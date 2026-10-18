; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-force-producer-vf=2 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=4 -pass-remarks=vplan-reduction-fission -S %s -o \
; RUN:   %t 2> %t.remarks
; RUN: FileCheck %s < %t
; RUN: FileCheck %s --check-prefix=REMARK < %t.remarks
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t -o /dev/null
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-force-producer-vf=2 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=4 -tail-folding-policy=dont-fold-tail -S %s | \
; RUN:   FileCheck %s
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-force-producer-vf=2 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=4 -tail-folding-policy=must-fold-tail \
; RUN:   -force-tail-folding-style=data -S %s | FileCheck %s
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-force-producer-vf=4 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=2 -pass-remarks-missed=vplan-reduction-fission \
; RUN:   -S %s -o %t.reverse 2> %t.reverse.remarks
; RUN: FileCheck %s --check-prefix=REVERSE < %t.reverse
; RUN: FileCheck %s --check-prefix=VF-LIMIT < %t.reverse.remarks
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.reverse -o /dev/null
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-force-producer-vf=2 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=1 -S %s -o %t.ordered-reverse
; RUN: FileCheck %s --check-prefix=ORDERED-REVERSE < %t.ordered-reverse
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.ordered-reverse -o /dev/null
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-min-chain-depth=1000 \
; RUN:   -vplan-reduction-fission-min-reductions=1000 \
; RUN:   -vplan-reduction-fission-min-pressure-percent=1000 -S %s | FileCheck %s --check-prefix=AUTO
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-force-producer-vf=2 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=4 -vplan-reduction-fission-max-scratch-bytes=259 \
; RUN:   -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.small 2> %t.small.remarks
; RUN: FileCheck %s --check-prefix=SMALL --implicit-check-not=vector.fission --implicit-check-not=fission.scratch < %t.small
; RUN: FileCheck %s --check-prefix=LIMIT < %t.small.remarks
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-force-producer-vf=2 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=4 -vplan-reduction-fission-max-scratch-bytes=260 \
; RUN:   -S %s | FileCheck %s --check-prefix=CAPACITY
; RUN: opt -enable-scalar-reduction-fission=false -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=519 -S %s | FileCheck %s --check-prefix=CAPACITY
; RUN: opt -enable-scalar-reduction-fission=false -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=520 -S %s | FileCheck %s --check-prefix=DOUBLE-CAP
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-force-producer-vf=16 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=2 -S %s | FileCheck %s --check-prefix=WIDE
; RUN: opt -enable-scalar-reduction-fission=false -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=779 -pass-remarks-missed=vplan-reduction-fission \
; RUN:   -S %s -o %t.members-small 2> %t.members-small.remarks
; RUN: FileCheck %s --check-prefix=MEMBER-LIMIT < %t.members-small
; RUN: FileCheck %s --check-prefix=MEMBER-REJECT < %t.members-small.remarks
; RUN: opt -enable-scalar-reduction-fission=false -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=780 -S %s | FileCheck %s --check-prefix=MEMBER-CAP
;
; Complete AoS groups: every member participates, member zero has multiple
; uses, and the same contribution feeds two independent reductions. The host
; checker runs scalar references, guards the input's end, and counts entries
; to all four emitted stages. Bypasses must not read null input pointers.
; Canonical tail masks are removed only for full-chunk stages; scalar tails
; load individual members. WIDE checks RVV EMUL*NFIELDS at the producer VF.
; The ordered factor-3 case loads member one first: the group insertion
; address must be adjusted back to member zero before either stage/tail uses it.
; There are no input/output noalias promises; final output stores can alias input.
; The address slice for factor 3 contains a single-scalar replicate multiply.
; Factor 2's multiply simplifies to a VPInstruction shift; both must be legal.
; nxv4f64 is EMUL=4, so a factor-three double producer needs a narrower VF
; than the integer fixtures. Its reverse VF order remains a positive 2/1 case;
; the 4/2 request must report independent target illegality, not bypass it.

; REMARK: interleave.c:10:5: split reduction loop: baseline VF {{.*}}, producer VF vscale x 2, accumulator VF vscale x 4, trip count bounded-runtime, scratch capacity 65, scratch bytes 260
; REMARK-SAME: scratch store bytes/iteration 4, scratch load bytes/iteration 4, duplicated recipes 0, reread loads/iteration 0
; CHECK-LABEL: define void @interleave2(
; CHECK: alloca [65 x i32]
; CHECK: vector.fission.producer.body:
; CHECK: load <vscale x 4 x i32>
; CHECK: @llvm.vector.deinterleave2.nxv4
; CHECK: store <vscale x 2 x i32>
; CHECK: scalar.fission.producer.body:
; CHECK: load i32, ptr {{.*}}, align 4
; CHECK: getelementptr i8, ptr {{.*}}, i64 4
; CHECK: load i32, ptr {{.*}}, align 4
; CHECK: vector.fission.accumulator.body:
; CHECK: load <vscale x 4 x i32>
; CHECK: @llvm.vector.reduce.add.
; CHECK: scalar.fission.accumulator.body:
; CHECK: add i32
; REVERSE-LABEL: define void @interleave2(
; REVERSE: vector.fission.producer.body:
; REVERSE: load <vscale x 8 x i32>
; REVERSE: vector.fission.accumulator.body:
; REVERSE: load <vscale x 2 x i32>
; AUTO-LABEL: define void @interleave2(
; AUTO: vector.fission.producer.body:
; AUTO: vector.fission.accumulator.body:
; SMALL-LABEL: define void @interleave2(
; SMALL: ret void
; CAPACITY-LABEL: define void @interleave2(
; CAPACITY: alloca [65 x i32]
; CAPACITY: vector.fission.producer.body:
; LIMIT: interleave.c:10:5: reduction fission rejected: scratch byte limit exceeded
define void @interleave2(ptr readonly %a, ptr %out, i64 %n) !dbg !5 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !6
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
  br i1 %done, label %exit, label %loop, !dbg !6
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

; REMARK: interleave.c:30:5: split reduction loop: baseline VF {{.*}}, producer VF vscale x 2, accumulator VF vscale x 4, trip count bounded-runtime, scratch capacity 65, scratch bytes 260
; REMARK-SAME: scratch store bytes/iteration 4, scratch load bytes/iteration 4, duplicated recipes 0, reread loads/iteration 0
; CHECK-LABEL: define void @interleave3(
; CHECK: alloca [65 x i32]
; CHECK: vector.fission.producer.body:
; CHECK: load <vscale x 6 x i32>
; CHECK: @llvm.vector.deinterleave3.nxv6
; CHECK: store <vscale x 2 x i32>
; CHECK: scalar.fission.producer.body:
; CHECK: load i32, ptr {{.*}}, align 4
; CHECK: getelementptr i8, ptr {{.*}}, i64 4
; CHECK: load i32, ptr {{.*}}, align 4
; CHECK: getelementptr i8, ptr {{.*}}, i64 8
; CHECK: load i32, ptr {{.*}}, align 4
; CHECK: vector.fission.accumulator.body:
; CHECK: load <vscale x 4 x i32>
; CHECK: @llvm.vector.reduce.add.
; CHECK: scalar.fission.accumulator.body:
; CHECK: add i32
; REVERSE-LABEL: define void @interleave3(
; REVERSE: vector.fission.producer.body:
; REVERSE: load <vscale x 12 x i32>
; REVERSE: vector.fission.accumulator.body:
; REVERSE: load <vscale x 2 x i32>
; AUTO-LABEL: define void @interleave3(
; AUTO: vector.fission.producer.body:
; AUTO: vector.fission.accumulator.body:
; SMALL-LABEL: define void @interleave3(
; SMALL: ret void
; CAPACITY-LABEL: define void @interleave3(
; CAPACITY: alloca [65 x i32]
; CAPACITY: vector.fission.producer.body:
define void @interleave3(ptr readonly %a, ptr %out, i64 %n) !dbg !7 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !8
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
  br i1 %done, label %exit, label %loop, !dbg !8
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

; REMARK: interleave.c:50:5: split reduction loop: baseline VF {{.*}}, producer VF vscale x 2, accumulator VF vscale x 4, trip count bounded-runtime, scratch capacity 65, scratch bytes 520
; REMARK-SAME: scratch store bytes/iteration 8, scratch load bytes/iteration 8, duplicated recipes 0, reread loads/iteration 0
; CHECK-LABEL: define void @interleave2_ordered(
; CHECK: alloca [65 x double]
; CHECK: vector.fission.producer.body:
; CHECK: load <vscale x 4 x double>
; CHECK: @llvm.vector.deinterleave2.nxv4
; CHECK: store <vscale x 2 x double>
; CHECK: scalar.fission.producer.body:
; CHECK: load double, ptr {{.*}}, align 8
; CHECK: getelementptr i8, ptr {{.*}}, i64 8
; CHECK: load double, ptr {{.*}}, align 8
; CHECK: vector.fission.accumulator.body:
; CHECK: load <vscale x 4 x double>
; CHECK: @llvm.vector.reduce.fadd.
; CHECK: scalar.fission.accumulator.body:
; CHECK: fadd double
; REVERSE-LABEL: define void @interleave2_ordered(
; REVERSE: vector.fission.producer.body:
; REVERSE: load <vscale x 8 x double>
; REVERSE: vector.fission.accumulator.body:
; REVERSE: load <vscale x 2 x double>
; AUTO-LABEL: define void @interleave2_ordered(
; AUTO: vector.fission.producer.body:
; AUTO: vector.fission.accumulator.body:
; SMALL-LABEL: define void @interleave2_ordered(
; SMALL: ret void
; CAPACITY-LABEL: define void @interleave2_ordered(
; CAPACITY-NOT: fission
; CAPACITY: ret void
; DOUBLE-CAP-LABEL: define void @interleave2_ordered(
; DOUBLE-CAP: alloca [65 x double]
; DOUBLE-CAP: vector.fission.producer.body:
define void @interleave2_ordered(ptr readonly %a, ptr %out, i64 %n, double %start) !dbg !9 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !10
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
  br i1 %done, label %exit, label %loop, !dbg !10
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

; REMARK: interleave.c:70:5: split reduction loop: baseline VF {{.*}}, producer VF vscale x 2, accumulator VF vscale x 4, trip count bounded-runtime, scratch capacity 65, scratch bytes 520
; REMARK-SAME: scratch store bytes/iteration 8, scratch load bytes/iteration 8, duplicated recipes 0, reread loads/iteration 0
; CHECK-LABEL: define void @interleave3_ordered(
; CHECK: alloca [65 x double]
; CHECK: vector.fission.producer.body:
; CHECK: load <vscale x 6 x double>
; CHECK: @llvm.vector.deinterleave3.nxv6
; CHECK: store <vscale x 2 x double>
; CHECK: scalar.fission.producer.body:
; CHECK: load double, ptr {{.*}}, align 8
; CHECK: getelementptr i8, ptr {{.*}}, i64 8
; CHECK: load double, ptr {{.*}}, align 8
; CHECK: getelementptr i8, ptr {{.*}}, i64 16
; CHECK: load double, ptr {{.*}}, align 8
; CHECK: vector.fission.accumulator.body:
; CHECK: load <vscale x 4 x double>
; CHECK: @llvm.vector.reduce.fadd.
; CHECK: scalar.fission.accumulator.body:
; CHECK: fadd double
; ORDERED-REVERSE-LABEL: define void @interleave3_ordered(
; ORDERED-REVERSE: vector.fission.producer.body:
; ORDERED-REVERSE: load <vscale x 6 x double>
; ORDERED-REVERSE: vector.fission.accumulator.body:
; ORDERED-REVERSE: load <vscale x 1 x double>
; VF-LIMIT: interleave.c:70:5: reduction fission rejected: forced-stage-vf-not-legal
; AUTO-LABEL: define void @interleave3_ordered(
; AUTO: vector.fission.producer.body:
; AUTO: vector.fission.accumulator.body:
; SMALL-LABEL: define void @interleave3_ordered(
; SMALL: ret void
; CAPACITY-LABEL: define void @interleave3_ordered(
; CAPACITY-NOT: fission
; CAPACITY: ret void
; DOUBLE-CAP-LABEL: define void @interleave3_ordered(
; DOUBLE-CAP: alloca [65 x double]
; DOUBLE-CAP: vector.fission.producer.body:
; WIDE-LABEL: define void @interleave3_ordered(
; WIDE-NOT: fission
; WIDE: ret void
define void @interleave3_ordered(ptr readonly %a, ptr %out, i64 %n, double %start) !dbg !11 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !12
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi double [%start, %preheader], [%update, %loop]
  %bits = phi double [-0.0, %preheader], [%updated.bits, %loop]
  %base = mul nuw i64 %i, 3
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr double, ptr %a, i64 %idx1
  %x1 = load double, ptr %p1, align 8
  %idx2 = add nuw i64 %base, 2
  %p2 = getelementptr double, ptr %a, i64 %idx2
  %x2 = load double, ptr %p2, align 8
  %p0 = getelementptr double, ptr %a, i64 %base
  %x0 = load double, ptr %p0, align 8
  %scaled = fmul double %x0, 2.0
  %shared = fadd double %scaled, %x0
  %pair = fsub double %shared, %x1
  %term = fadd double %pair, %x2
  %update = fadd double %sum, %term
  %updated.bits = fadd double %bits, %term
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !12
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

; Direct multi-result scratch frontiers, one slot per original member.
; REMARK: interleave.c:90:5: split reduction loop: baseline VF {{.*}}, producer VF vscale x 2, accumulator VF vscale x 4, trip count bounded-runtime, scratch capacity 65, scratch bytes 520
; REMARK-SAME: scratch store bytes/iteration 8, scratch load bytes/iteration 8, duplicated recipes 0, reread loads/iteration 0
; CHECK-LABEL: define void @interleave2_members(
; CHECK-COUNT-2: alloca [65 x i32]
; CHECK: vector.fission.producer.body:
; CHECK: @llvm.vector.deinterleave2.nxv4i32
; CHECK-COUNT-2: store <vscale x 2 x i32>
; CHECK: scalar.fission.producer.body:
; CHECK: vector.fission.accumulator.body:
; CHECK-COUNT-2: load <vscale x 4 x i32>
; CHECK: scalar.fission.accumulator.body:
; REVERSE-LABEL: define void @interleave2_members(
; REVERSE: vector.fission.producer.body:
; REVERSE: @llvm.vector.deinterleave2.nxv8i32
; REVERSE: vector.fission.accumulator.body:
; REVERSE-COUNT-2: load <vscale x 2 x i32>
; AUTO-LABEL: define void @interleave2_members(
; AUTO: vector.fission.producer.body:
; AUTO: vector.fission.accumulator.body:
; SMALL-LABEL: define void @interleave2_members(
; SMALL: ret void
; CAPACITY-LABEL: define void @interleave2_members(
; CAPACITY-NOT: fission
; CAPACITY: ret void
; DOUBLE-CAP-LABEL: define void @interleave2_members(
; DOUBLE-CAP-COUNT-2: alloca [65 x i32]
; DOUBLE-CAP: vector.fission.producer.body:
define void @interleave2_members(ptr readonly %a, ptr %out, i64 %n) !dbg !13 {
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
  %base = mul nuw i64 %i, 2
  %p0 = getelementptr i32, ptr %a, i64 %base
  %x0 = load i32, ptr %p0, align 4
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr i32, ptr %a, i64 %idx1
  %x1 = load i32, ptr %p1, align 4
  %u0 = add i32 %r0, %x0
  %u1 = xor i32 %r1, %x1
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

; Direct multi-result scratch frontiers, one slot per original member.
; REMARK: interleave.c:110:5: split reduction loop: baseline VF {{.*}}, producer VF vscale x 2, accumulator VF vscale x 4, trip count bounded-runtime, scratch capacity 65, scratch bytes 780
; REMARK-SAME: scratch store bytes/iteration 12, scratch load bytes/iteration 12, duplicated recipes 0, reread loads/iteration 0
; CHECK-LABEL: define void @interleave3_members(
; CHECK-COUNT-3: alloca [65 x i32]
; CHECK: vector.fission.producer.body:
; CHECK: @llvm.vector.deinterleave3.nxv6i32
; CHECK-COUNT-3: store <vscale x 2 x i32>
; CHECK: scalar.fission.producer.body:
; CHECK: vector.fission.accumulator.body:
; CHECK-COUNT-3: load <vscale x 4 x i32>
; CHECK: scalar.fission.accumulator.body:
; REVERSE-LABEL: define void @interleave3_members(
; REVERSE: vector.fission.producer.body:
; REVERSE: @llvm.vector.deinterleave3.nxv12i32
; REVERSE: vector.fission.accumulator.body:
; REVERSE-COUNT-3: load <vscale x 2 x i32>
; AUTO-LABEL: define void @interleave3_members(
; AUTO: vector.fission.producer.body:
; AUTO: vector.fission.accumulator.body:
; SMALL-LABEL: define void @interleave3_members(
; SMALL: ret void
; CAPACITY-LABEL: define void @interleave3_members(
; CAPACITY-NOT: fission
; CAPACITY: ret void
; DOUBLE-CAP-LABEL: define void @interleave3_members(
; DOUBLE-CAP-NOT: fission
; DOUBLE-CAP: ret void
; MEMBER-LIMIT-LABEL: define void @interleave3_members(
; MEMBER-LIMIT-NOT: fission
; MEMBER-LIMIT: ret void
; MEMBER-REJECT: interleave.c:110:5: reduction fission rejected: scratch byte limit exceeded
; MEMBER-CAP-LABEL: define void @interleave3_members(
; MEMBER-CAP-COUNT-3: alloca [65 x i32]
; MEMBER-CAP: vector.fission.producer.body:
; MEMBER-CAP: vector.fission.accumulator.body:
define void @interleave3_members(ptr readonly %a, ptr %out, i64 %n) !dbg !15 {
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
  %base = mul nuw i64 %i, 3
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
  ret void
bypass:
  %b0 = getelementptr i32, ptr %out, i64 0
  store i32 17, ptr %b0, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  %b2 = getelementptr i32, ptr %out, i64 2
  store i32 29, ptr %b2, align 4
  ret void
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2}
!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "interleave.c", directory: "/")
!2 = !{i32 2, !"Debug Info Version", i32 3}
!3 = !DISubroutineType(types: !4)
!4 = !{null}
!5 = distinct !DISubprogram(name: "interleave2", scope: !1, file: !1, line: 10, type: !3, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!6 = !DILocation(line: 10, column: 5, scope: !5)
!7 = distinct !DISubprogram(name: "interleave3", scope: !1, file: !1, line: 30, type: !3, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!8 = !DILocation(line: 30, column: 5, scope: !7)
!9 = distinct !DISubprogram(name: "interleave2_ordered", scope: !1, file: !1, line: 50, type: !3, scopeLine: 50, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!10 = !DILocation(line: 50, column: 5, scope: !9)
!11 = distinct !DISubprogram(name: "interleave3_ordered", scope: !1, file: !1, line: 70, type: !3, scopeLine: 70, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!12 = !DILocation(line: 70, column: 5, scope: !11)
!13 = distinct !DISubprogram(name: "interleave2_members", scope: !1, file: !1, line: 90, type: !3, scopeLine: 90, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!14 = !DILocation(line: 90, column: 5, scope: !13)
!15 = distinct !DISubprogram(name: "interleave3_members", scope: !1, file: !1, line: 110, type: !3, scopeLine: 110, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!16 = !DILocation(line: 110, column: 5, scope: !15)
