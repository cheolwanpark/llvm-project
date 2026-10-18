; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' \
; RUN:   -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -force-vector-width=4 -scalable-vectorization=always -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -pass-remarks=vplan-reduction-fission \
; RUN:   -S %s -o %t 2> %t.remarks
; RUN: FileCheck %s --check-prefix=EVL < %t
; RUN: FileCheck %s --check-prefix=REMARK < %t.remarks
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t -o /dev/null
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' \
; RUN:   -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -force-vector-width=4 -scalable-vectorization=always -hints-allow-reordering=false \
; RUN:   -tail-folding-policy=dont-fold-tail -enable-epilogue-vectorization=false \
; RUN:   -enable-vplan-reduction-fission -S %s -o %t.tail
; RUN: FileCheck %s --check-prefix=TAIL --implicit-check-not=llvm.vp. --implicit-check-not=llvm.experimental.get.vector.length < %t.tail
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.tail -o /dev/null
;
; The inner producer cannot vectorize because the explicitly safe helper has
; no vector mapping. The consumer is a sibling inside the existing outer loop.
; Its initial values are outer carried values and its results are both stored
; and carried to the next row. Each row changes the producer's inputs, while
; reusing two entry scratch arrays. There is no noalias contract: row stores
; may affect a later row's inputs. Only the inner loop is split.
;
; The host checker compares the scalar-tail variant to this exact scalar IR,
; including repeated vector-consumer entry, zero/invalid guards and aliasing.
; Default EVL has independent IR checks and RVV machine verification only.
;
; REMARK: scalar-nested.c:22:5: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; REMARK: scalar-nested.c:22:5: scalar-IR fission producer VF 1
; REMARK: scalar-nested.c:22:5: scalar-IR fission consumer VF vscale x 4
;
; EVL-LABEL: define void @scalar_nested(
; EVL: alloca [65 x i32]
; EVL: alloca [65 x double]
; EVL-NOT: alloca
; EVL: br i1 %enter, label %outer.ph, label %exit
; EVL: outer:
; EVL: %carry = phi i32 [ 19, %outer.ph ], [ {{%.*}}, %row.exit ]
; EVL: %dcarry = phi double [ %start, %outer.ph ], [ {{%.*}}, %row.exit ]
; EVL: inner:
; EVL: call i32 @scalar_helper
; EVL: store i32
; EVL: store double
; EVL: scalar.fission.consumer.ph:
; EVL: vector.body:
; EVL: [[EVL:%.*]] = call i32 @llvm.experimental.get.vector.length.i64
; EVL: call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0({{.*}}i32 [[EVL]])
; EVL: call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0({{.*}}i32 [[EVL]])
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64(double {{%.*}}, <vscale x 4 x double> {{%.*}}, <vscale x 4 x i1> splat (i1 true), i32 [[EVL]])
; EVL: call i32 @llvm.vector.reduce.add.nxv4i32
; EVL: row.exit:
; EVL: store i32 {{%.*}}, ptr %dst
; EVL: store double {{%.*}}, ptr %ddst
; EVL: br i1 %rows.done, label %exit.loopexit, label %outer
; EVL: ret void
;
; TAIL-LABEL: define void @scalar_nested(
; TAIL: alloca [65 x i32]
; TAIL: alloca [65 x double]
; TAIL-NOT: alloca
; TAIL: outer:
; TAIL: inner:
; TAIL: call i32 @scalar_helper
; TAIL: scalar.fission.consumer.ph:
; TAIL: vector.body:
; TAIL: load <vscale x 4 x i32>
; TAIL: load <vscale x 4 x double>
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64
; TAIL: call i32 @llvm.vector.reduce.add.nxv4i32
; TAIL: scalar.fission.consumer.body:
; TAIL: add i32
; TAIL: fadd double
; TAIL: row.exit:
; TAIL: store i32 {{%.*}}, ptr %dst
; TAIL: store double {{%.*}}, ptr %ddst
; TAIL: ret void

declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

define void @scalar_nested(ptr readonly %a, ptr readonly %fp, ptr %out,
                           ptr %dout, i64 %rows, i64 %n, double %start) !dbg !4 {
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
  br label %inner
inner:
  %iv = phi i64 [0, %inner.ph], [%next, %inner]
  %sum = phi i32 [%carry, %inner.ph], [%update, %inner]
  %dsum = phi double [%dcarry, %inner.ph], [%dupdate, %inner]
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %salted = xor i32 %x, %salt
  %c = call i32 @scalar_helper(i32 %salted)
  %dp = getelementptr double, ptr %dbase, i64 %iv
  %dx = load double, ptr %dp, align 8
  %dc = fmul double %dx, 3.0
  %update = add i32 %sum, %c
  %dupdate = fadd double %dsum, %dc
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %row.exit, label %inner, !dbg !7
row.exit:
  %row.sum = phi i32 [%update, %inner]
  %row.dsum = phi double [%dupdate, %inner]
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

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-nested.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = distinct !DISubprogram(name: "scalar_nested", scope: !1, file: !1, line: 10, type: !5, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!5 = !DISubroutineType(types: !6)
!6 = !{}
!7 = !DILocation(line: 22, column: 5, scope: !4)
