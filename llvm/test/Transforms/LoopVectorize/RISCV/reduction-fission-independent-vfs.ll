; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=8 \
; RUN:   -pass-remarks=vplan-reduction-fission -S %s -o %t 2> %t.remarks
; RUN: FileCheck %s < %t
; RUN: FileCheck %s --check-prefix=REMARK < %t.remarks
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t -o /dev/null
; RUN: opt -enable-scalar-reduction-fission=false -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-force-producer-vf=4 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=8 -S %s \
; RUN:   -pass-remarks-missed=vplan-reduction-fission -o %t.reject 2> %t.reject.remarks
; RUN: FileCheck %s --check-prefix=REJECT --implicit-check-not=vector.fission --implicit-check-not=fission.scratch < %t.reject
; RUN: FileCheck %s --check-prefix=REJECT-REMARK < %t.reject.remarks
; RUN: opt -enable-scalar-reduction-fission=false -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-force-producer-vf=1 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=8 -S %s \
; RUN:   | FileCheck %s --check-prefix=REJECT --implicit-check-not=vector.fission --implicit-check-not=fission.scratch
; RUN: opt -enable-scalar-reduction-fission=false -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-force-producer-vf=2 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=8 -vplan-reduction-fission-max-scratch-bytes=259 -S %s \
; RUN:   | FileCheck %s --check-prefix=REJECT --implicit-check-not=vector.fission --implicit-check-not=fission.scratch
; RUN: opt -enable-scalar-reduction-fission=false -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-force-producer-vf=2 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=8 -vplan-reduction-fission-max-scratch-bytes=260 -S %s \
; RUN:   | FileCheck %s
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -S %s -o %t.baseline
; RUN: FileCheck %s --check-prefix=BASE --implicit-check-not=vector.fission --implicit-check-not=fission.scratch < %t.baseline
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.baseline -o /dev/null
; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -enable-vplan-reduction-fission=false -S %s -o %t.disabled
; RUN: diff %t.baseline %t.disabled
; RUN: opt -enable-scalar-reduction-fission=false -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-force-producer-vf=2 \
; RUN:   -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.producer-only 2> %t.producer-only.remarks
; RUN: FileCheck %s --check-prefix=REJECT --implicit-check-not=vector.fission --implicit-check-not=fission.scratch < %t.producer-only
; RUN: FileCheck %s --check-prefix=INVALID-PAIR < %t.producer-only.remarks
; RUN: opt -enable-scalar-reduction-fission=false -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-force-accumulator-vf=8 \
; RUN:   -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.accumulator-only 2> %t.accumulator-only.remarks
; RUN: FileCheck %s --check-prefix=REJECT --implicit-check-not=vector.fission --implicit-check-not=fission.scratch < %t.accumulator-only
; RUN: FileCheck %s --check-prefix=INVALID-PAIR < %t.accumulator-only.remarks
; RUN: opt -enable-scalar-reduction-fission=false -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-force-producer-vf=3 -vplan-reduction-fission-force-accumulator-vf=8 \
; RUN:   -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.non-power-of-two 2> %t.non-power-of-two.remarks
; RUN: FileCheck %s --check-prefix=REJECT --implicit-check-not=vector.fission --implicit-check-not=fission.scratch < %t.non-power-of-two
; RUN: FileCheck %s --check-prefix=INVALID-PAIR < %t.non-power-of-two.remarks
;
; Scalable VFABI 'x' derives the VF from the widest vector argument or return
; element, using 128 bits. i32(i32) would require nxv4, regardless of the vector
; declaration's width. i32(i64), and i32(i32, i64), correctly describe nxv2.
; The consumers have no calls and are legal at nxv8. Intersecting both legal
; sets would discard nxv8. Forced nxv1/nxv4 producers fail signature legality.
; Ordinary planning must also cost these valid mappings without any forced VF
; or fission, and fission-disabled output must equal the default output.
;
; REMARK: independent-vfs.c:10:5: split reduction loop: baseline VF {{.*}}, producer VF vscale x 2, accumulator VF vscale x 8, trip count constant, scratch capacity 65, scratch bytes 260
; REMARK-SAME: scratch store bytes/iteration 4, scratch load bytes/iteration 4, duplicated recipes 0, reread loads/iteration 0
; INVALID-PAIR: independent-vfs.c:10:5: reduction fission rejected: invalid-forced-stage-vf-pair
; INVALID-PAIR: independent-vfs.c:30:7: reduction fission rejected: invalid-forced-stage-vf-pair
; REJECT-REMARK: independent-vfs.c:10:5: reduction fission rejected: forced-stage-vf-not-legal
; REJECT-REMARK: independent-vfs.c:30:7: reduction fission rejected: forced-stage-vf-not-legal
; CHECK-LABEL: define void @independent_vfs(
; CHECK: alloca [65 x i32]
; CHECK: vector.fission.producer.body:
; CHECK: load <vscale x 2 x i64>
; CHECK: call <vscale x 2 x i32> @vecfoo(<vscale x 2 x i64>
; CHECK: store <vscale x 2 x i32>
; CHECK: scalar.fission.producer.body:
; CHECK: call i32 @foo(i64
; CHECK: vector.fission.accumulator.body:
; CHECK: load <vscale x 8 x i32>
; CHECK: @llvm.vector.reduce.add.nxv8i32
; CHECK: scalar.fission.accumulator.body:
; REJECT-LABEL: define void @independent_vfs(
; REJECT: ret void
; BASE-LABEL: define void @independent_vfs(
; BASE: call <vscale x 2 x i32> @vecfoo(<vscale x 2 x i64>
; BASE: ret void
define void @independent_vfs(ptr noalias readonly %a, ptr noalias %out) !dbg !5 {
entry:
  br label %loop, !dbg !6
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %sum = phi i32 [0, %entry], [%update, %loop]
  %p = getelementptr i64, ptr %a, i64 %i
  %x = load i64, ptr %p, align 8
  %term = call i32 @foo(i64 %x) #0, !dbg !6
  %update = add i32 %sum, %term
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, 65
  br i1 %done, label %exit, label %loop, !dbg !6
exit:
  store i32 %update, ptr %out, align 4
  ret void
}

; Analogous two-argument mapping, with the widest vector argument last.
; This bounded version also executes zero/small counts, independent tails and
; the original out-of-bound bypass in utils/check-reduction-fission.py.
; REMARK: independent-vfs.c:30:7: split reduction loop: baseline VF {{.*}}, producer VF vscale x 2, accumulator VF vscale x 8, trip count bounded-runtime, scratch capacity 65, scratch bytes 260
; REMARK-SAME: scratch store bytes/iteration 4, scratch load bytes/iteration 4, duplicated recipes 0, reread loads/iteration 0
; CHECK-LABEL: define void @independent_vfs_bounded(
; CHECK: alloca [65 x i32]
; CHECK: vector.fission.producer.body:
; CHECK: call <vscale x 2 x i32> @vecbar(<vscale x 2 x i32> {{.*}}, <vscale x 2 x i64>
; CHECK: store <vscale x 2 x i32>
; CHECK: scalar.fission.producer.body:
; CHECK: call i32 @bar(i32 {{.*}}, i64
; CHECK: vector.fission.accumulator.body:
; CHECK: load <vscale x 8 x i32>
; CHECK: @llvm.vector.reduce.xor.nxv8i32
; CHECK: scalar.fission.accumulator.body:
; REJECT-LABEL: define void @independent_vfs_bounded(
; REJECT: ret void
; BASE-LABEL: define void @independent_vfs_bounded(
; BASE: call <vscale x 2 x i32> @vecbar(<vscale x 2 x i32> {{.*}}, <vscale x 2 x i64>
; BASE: ret void
define void @independent_vfs_bounded(ptr noalias readonly %a, ptr noalias %out, i64 %n) !dbg !7 {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !8
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %bits = phi i32 [23, %preheader], [%update, %loop]
  %p = getelementptr i64, ptr %a, i64 %i
  %x = load i64, ptr %p, align 8
  %lo = trunc i64 %x to i32
  %term = call i32 @bar(i32 %lo, i64 %x) #1, !dbg !8
  %update = xor i32 %bits, %term
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !8
exit:
  store i32 %update, ptr %out, align 4
  ret void
bypass:
  store i32 23, ptr %out, align 4
  ret void
}

declare i32 @foo(i64) nounwind willreturn speculatable memory(none)
declare <vscale x 2 x i32> @vecfoo(<vscale x 2 x i64>) nounwind willreturn speculatable memory(none)
declare i32 @bar(i32, i64) nounwind willreturn speculatable memory(none)
declare <vscale x 2 x i32> @vecbar(<vscale x 2 x i32>, <vscale x 2 x i64>) nounwind willreturn speculatable memory(none)
attributes #0 = { "vector-function-abi-variant"="_ZGVrNxv_foo(vecfoo)" }
attributes #1 = { "vector-function-abi-variant"="_ZGVrNxvv_bar(vecbar)" }

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2}
!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "independent-vfs.c", directory: "/")
!2 = !{i32 2, !"Debug Info Version", i32 3}
!3 = !DISubroutineType(types: !4)
!4 = !{null}
!5 = distinct !DISubprogram(name: "independent_vfs", scope: !1, file: !1, line: 1, type: !3, scopeLine: 1, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!6 = !DILocation(line: 10, column: 5, scope: !5)
!7 = distinct !DISubprogram(name: "independent_vfs_bounded", scope: !1, file: !1, line: 20, type: !3, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!8 = !DILocation(line: 30, column: 7, scope: !7)
