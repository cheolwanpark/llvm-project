; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=1 -vplan-reduction-fission-force-accumulator-vf=2 \
; RUN:   -pass-remarks=vplan-reduction-fission -S %s -o %t.forward 2> %t.forward.remarks
; RUN: FileCheck %s --check-prefix=FORWARD < %t.forward
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.forward -o /dev/null
; RUN: FileCheck %s --check-prefix=REMARK < %t.forward.remarks
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=1 \
; RUN:   -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.reverse 2> %t.reverse.remarks
; RUN: FileCheck %s --check-prefix=REVERSE < %t.reverse
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.reverse -o /dev/null
; RUN: FileCheck %s --check-prefix=VF-LIMIT < %t.reverse.remarks
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-min-chain-depth=1000 -vplan-reduction-fission-min-reductions=1000 \
; RUN:   -vplan-reduction-fission-min-pressure-percent=1000 -S %s | FileCheck %s --check-prefix=AUTO
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=1 -vplan-reduction-fission-force-accumulator-vf=2 \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=519 -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.small 2> %t.small.remarks
; RUN: FileCheck %s --check-prefix=SMALL < %t.small
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.small -o /dev/null
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=1 -vplan-reduction-fission-force-accumulator-vf=2 \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=520 -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.capacity 2> %t.capacity.remarks
; RUN: FileCheck %s --check-prefix=CAPACITY < %t.capacity
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.capacity -o /dev/null
; RUN: FileCheck %s --check-prefix=LIMIT < %t.small.remarks

; Ordinary ordered fadds, with no reassociation or fission FP reordering.
; Exact bit patterns (including cancellation, signed zero and special values)
; are compared to separately compiled scalar IR by the host checker.
; The eight-field double group requires producer VF1. Its scratch-only
; consumer may use VF2; an illegal producer VF2 must still be rejected.

; FORWARD-LABEL: define void @interleave4_ordered(
; FORWARD-COUNT-1: alloca [65 x double]
; FORWARD: vector.fission.producer.body:
; FORWARD: @llvm.vector.deinterleave4.nxv4
; FORWARD-COUNT-1: store <vscale x 1 x double>
; FORWARD: scalar.fission.producer.body:
; FORWARD: load double
; FORWARD: vector.fission.accumulator.body:
; FORWARD: @llvm.vector.reduce.fadd.
; FORWARD: scalar.fission.accumulator.body:
; FORWARD: fadd double
; REVERSE-LABEL: define void @interleave4_ordered(
; REVERSE-COUNT-1: alloca [65 x double]
; REVERSE: vector.fission.producer.body:
; REVERSE: @llvm.vector.deinterleave4.nxv8
; REVERSE-COUNT-1: store <vscale x 2 x double>
; REVERSE: scalar.fission.producer.body:
; REVERSE: load double
; REVERSE: vector.fission.accumulator.body:
; REVERSE: @llvm.vector.reduce.fadd.
; REVERSE: scalar.fission.accumulator.body:
; REVERSE: fadd double
; AUTO-LABEL: define void @interleave4_ordered(
; AUTO: vector.fission.producer.body:
; AUTO: vector.fission.accumulator.body:
; REMARK: interleave-wide-ordered.c:10:5: split reduction loop: baseline VF {{.*}}, producer VF vscale x 1, accumulator VF vscale x 2, trip count bounded-runtime, scratch capacity 65, scratch bytes 520
; REMARK-SAME: scratch store bytes/iteration 8, scratch load bytes/iteration 8, duplicated recipes 0, reread loads/iteration 0
; SMALL-LABEL: define void @interleave4_ordered(
; SMALL-NOT: fission
; SMALL: ret void
; LIMIT: interleave-wide-ordered.c:10:5: reduction fission rejected: scratch byte limit exceeded
; CAPACITY-LABEL: define void @interleave4_ordered(
; CAPACITY: alloca [65 x double]
; CAPACITY: vector.fission.producer.body:
define void @interleave4_ordered(ptr readonly %a, ptr %out, i64 %n, double %start) !dbg !5 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !6
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi double [%start, %preheader], [%u0, %loop]
  %r1 = phi double [-0.0, %preheader], [%u1, %loop]
  %base = mul nuw i64 %i, 4
  %idx3 = add nuw i64 %base, 3
  %p3 = getelementptr double, ptr %a, i64 %idx3
  %x3 = load double, ptr %p3, align 8
  %p0 = getelementptr double, ptr %a, i64 %base
  %x0 = load double, ptr %p0, align 8
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr double, ptr %a, i64 %idx1
  %x1 = load double, ptr %p1, align 8
  %idx2 = add nuw i64 %base, 2
  %p2 = getelementptr double, ptr %a, i64 %idx2
  %x2 = load double, ptr %p2, align 8
  %scaled = fmul double %x0, 2.0
  %shared = fadd double %scaled, %x0
  %term1 = fsub double %shared, %x1
  %term2 = fadd double %term1, %x2
  %term3 = fsub double %term2, %x3
  %u0 = fadd double %r0, %term3
  %u1 = fadd double %r1, %term3
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !6
exit:
  %o0 = getelementptr double, ptr %out, i64 0
  store double %u0, ptr %o0, align 8
  %o1 = getelementptr double, ptr %out, i64 1
  store double %u1, ptr %o1, align 8
  ret void
bypass:
  %b0 = getelementptr double, ptr %out, i64 0
  store double %start, ptr %b0, align 8
  %b1 = getelementptr double, ptr %out, i64 1
  store double -0.0, ptr %b1, align 8
  ret void
}

; FORWARD-LABEL: define void @interleave8_ordered(
; FORWARD-COUNT-1: alloca [65 x double]
; FORWARD: vector.fission.producer.body:
; FORWARD: @llvm.vector.deinterleave8.nxv8
; FORWARD-COUNT-1: store <vscale x 1 x double>
; FORWARD: scalar.fission.producer.body:
; FORWARD: load double
; FORWARD: vector.fission.accumulator.body:
; FORWARD: @llvm.vector.reduce.fadd.
; FORWARD: scalar.fission.accumulator.body:
; FORWARD: fadd double
; AUTO-LABEL: define void @interleave8_ordered(
; AUTO: vector.fission.producer.body:
; AUTO: vector.fission.accumulator.body:
; REMARK: interleave-wide-ordered.c:30:5: split reduction loop: baseline VF {{.*}}, producer VF vscale x 1, accumulator VF vscale x 2, trip count bounded-runtime, scratch capacity 65, scratch bytes 520
; REMARK-SAME: scratch store bytes/iteration 8, scratch load bytes/iteration 8, duplicated recipes 0, reread loads/iteration 0
; REVERSE-LABEL: define void @interleave8_ordered(
; REVERSE-NOT: fission
; REVERSE: ret void
; VF-LIMIT: interleave-wide-ordered.c:30:5: reduction fission rejected: forced-stage-vf-not-legal
; SMALL-LABEL: define void @interleave8_ordered(
; SMALL-NOT: fission
; SMALL: ret void
; LIMIT: interleave-wide-ordered.c:30:5: reduction fission rejected: scratch byte limit exceeded
; CAPACITY-LABEL: define void @interleave8_ordered(
; CAPACITY: alloca [65 x double]
; CAPACITY: vector.fission.producer.body:
define void @interleave8_ordered(ptr readonly %a, ptr %out, i64 %n, double %start) !dbg !7 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass, !dbg !8
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi double [%start, %preheader], [%u0, %loop]
  %r1 = phi double [-0.0, %preheader], [%u1, %loop]
  %base = mul nuw i64 %i, 8
  %idx7 = add nuw i64 %base, 7
  %p7 = getelementptr double, ptr %a, i64 %idx7
  %x7 = load double, ptr %p7, align 8
  %p0 = getelementptr double, ptr %a, i64 %base
  %x0 = load double, ptr %p0, align 8
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr double, ptr %a, i64 %idx1
  %x1 = load double, ptr %p1, align 8
  %idx2 = add nuw i64 %base, 2
  %p2 = getelementptr double, ptr %a, i64 %idx2
  %x2 = load double, ptr %p2, align 8
  %idx3 = add nuw i64 %base, 3
  %p3 = getelementptr double, ptr %a, i64 %idx3
  %x3 = load double, ptr %p3, align 8
  %idx4 = add nuw i64 %base, 4
  %p4 = getelementptr double, ptr %a, i64 %idx4
  %x4 = load double, ptr %p4, align 8
  %idx5 = add nuw i64 %base, 5
  %p5 = getelementptr double, ptr %a, i64 %idx5
  %x5 = load double, ptr %p5, align 8
  %idx6 = add nuw i64 %base, 6
  %p6 = getelementptr double, ptr %a, i64 %idx6
  %x6 = load double, ptr %p6, align 8
  %scaled = fmul double %x0, 2.0
  %shared = fadd double %scaled, %x0
  %term1 = fsub double %shared, %x1
  %term2 = fadd double %term1, %x2
  %term3 = fsub double %term2, %x3
  %term4 = fadd double %term3, %x4
  %term5 = fsub double %term4, %x5
  %term6 = fadd double %term5, %x6
  %term7 = fsub double %term6, %x7
  %u0 = fadd double %r0, %term7
  %u1 = fadd double %r1, %term7
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !8
exit:
  %o0 = getelementptr double, ptr %out, i64 0
  store double %u0, ptr %o0, align 8
  %o1 = getelementptr double, ptr %out, i64 1
  store double %u1, ptr %o1, align 8
  ret void
bypass:
  %b0 = getelementptr double, ptr %out, i64 0
  store double %start, ptr %b0, align 8
  %b1 = getelementptr double, ptr %out, i64 1
  store double -0.0, ptr %b1, align 8
  ret void
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2}
!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "interleave-wide-ordered.c", directory: "/")
!2 = !{i32 2, !"Debug Info Version", i32 3}
!3 = !DISubroutineType(types: !4)
!4 = !{null}
!5 = distinct !DISubprogram(name: "interleave4_ordered", scope: !1, file: !1, line: 10, type: !3, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!6 = !DILocation(line: 10, column: 5, scope: !5)
!7 = distinct !DISubprogram(name: "interleave8_ordered", scope: !1, file: !1, line: 30, type: !3, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!8 = !DILocation(line: 30, column: 5, scope: !7)
