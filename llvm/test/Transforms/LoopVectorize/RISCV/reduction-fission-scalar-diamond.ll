; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -force-vector-width=4 \
; RUN:   -scalable-vectorization=always -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -pass-remarks=vplan-reduction-fission \
; RUN:   -S %s -o %t 2> %t.remarks
; RUN: FileCheck %s --check-prefix=EVL < %t
; RUN: FileCheck %s --check-prefix=REMARK < %t.remarks
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t -o /dev/null
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -force-vector-width=4 \
; RUN:   -scalable-vectorization=always -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-allow-fp-reordering \
; RUN:   -S %s | FileCheck %s --check-prefix=EVL
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -force-vector-width=4 \
; RUN:   -scalable-vectorization=always -hints-allow-reordering=false \
; RUN:   -tail-folding-policy=dont-fold-tail -enable-epilogue-vectorization=false \
; RUN:   -enable-vplan-reduction-fission -S %s -o %t.tail
; RUN: FileCheck %s --check-prefix=TAIL --implicit-check-not=llvm.vp. --implicit-check-not=llvm.experimental.get.vector.length < %t.tail
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.tail -o /dev/null
; RUN: opt -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -force-vector-width=1 -force-vector-interleave=0 -force-target-max-scalar-interleave=1 \
; RUN:   -scalable-vectorization=off -enable-vplan-reduction-fission \
; RUN:   -S %s | FileCheck %s --check-prefix=SCALAR
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=1044 -pass-remarks=vplan-reduction-fission \
; RUN:   -disable-output %s 2>&1 | FileCheck %s --check-prefix=LIMIT
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=1043 -pass-remarks-missed=vplan-reduction-fission -pass-remarks=vplan-reduction-fission \
; RUN:   -S %s 2>&1 | FileCheck %s --check-prefix=SMALL
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v \
; RUN:   -S %s | FileCheck %s --check-prefix=DISABLED --implicit-check-not=scalar.fission
;
; The scalar inspection RUN leaves the interleave hint unspecified (zero)
; while capping scalar interleaving at one. Explicit width=1/interleave=1
; would mark the original loop as already vectorized and skip early fission.
;
; One producer diamond, unconditional updates. No if-conversion or
; neutral contributions: x==0 must not execute the division, and x!=0 must
; not load fp (the executable fixture supplies null for all-nonzero inputs).
; The scalar helper has no vector mapping. Two integer accumulators share
; the merged SSA contribution; ordinary FP remains ordered under BOTH
; settings of the separate VPlan FP-reordering option.
;
; The host checker executes the explicit scalar-tail variant, probes each
; exact vector consumer, and compares original scalar IR including guards,
; branch sequences, aliases, tails, repeated calls and nested scratch reuse.
; Default EVL/VP is checked and code-generated only, not host-executed.
;
; REMARK: scalar-diamond.c:32:7: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044
; REMARK: scalar-diamond.c:32:7: scalar-IR fission producer VF 1
; REMARK: scalar-diamond.c:32:7: scalar-IR fission consumer VF vscale x 4
; REMARK: scalar-diamond.c:42:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1040
; REMARK: scalar-diamond.c:62:5: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; REMARK: scalar-diamond.c:62:5: scalar-IR fission producer VF 1
; REMARK: scalar-diamond.c:62:5: scalar-IR fission consumer VF vscale x 4
; LIMIT: scalar-diamond.c:32:7: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044
; At the old full-trip ceiling, the same diamond now uses bounded chunks.
; SMALL: scalar-diamond.c:32:7: split scalar-IR reduction loop; {{.*}}scratch capacity 64, scratch bytes 1024
; SMALL-LABEL: define void @scalar_diamond(
; SMALL: alloca [64 x i32]
; SMALL: alloca [64 x double]
; SMALL: alloca [64 x float]
; SMALL: scalar.fission.chunk:
; SMALL: ret void
; DISABLED-LABEL: define void @scalar_diamond(
; DISABLED: sdiv i32 840, %x
; DISABLED: ret void

declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

; EVL-LABEL: define void @scalar_diamond(
; EVL: alloca [65 x i32]
; EVL: alloca [65 x double]
; EVL: alloca [65 x float]
; EVL-NOT: alloca
; EVL: br i1 %enter, label %preheader, label %exit
; EVL: loop:
; EVL-NOT: phi i32
; EVL: br i1 %choose, label %left, label %right
; EVL: left:
; EVL: %q = sdiv i32 840, %x
; EVL: %lc = call i32 @scalar_helper(i32 %q)
; EVL: br label %latch
; EVL: right:
; EVL: %dx = load double, ptr %dp
; EVL: br label %latch
; EVL: latch:
; EVL: %c = phi i32 [ %lc, %left ], [ 17, %right ]
; EVL: %dc = phi double
; EVL: %fc = phi float
; EVL: store i32 %c
; EVL: store double %dc
; EVL: store float %fc
; EVL: br i1 %done, label %scalar.fission.consumer.ph, label %loop
; EVL: scalar.fission.consumer.ph:
; EVL: vector.body:
; EVL: [[AVL:%.*]] = phi i64 [ %n, %vector.ph ], [ [[AVL_NEXT:%.*]], %vector.body ]
; EVL: [[EVL:%.*]] = call i32 @llvm.experimental.get.vector.length.i64(i64 [[AVL]], i32 4, i1 true)
; EVL: [[C:%.*]] = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0({{.*}}i32 [[EVL]])
; EVL: [[D:%.*]] = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0({{.*}}i32 [[EVL]])
; EVL: [[F:%.*]] = call <vscale x 4 x float> @llvm.vp.load.nxv4f32.p0({{.*}}i32 [[EVL]])
; EVL-NOT: @llvm.vp.load
; EVL: add <vscale x 4 x i32> {{%.*}}, [[C]]
; EVL: add <vscale x 4 x i32> [[C]], {{%.*}}
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64(double {{%.*}}, <vscale x 4 x double> [[D]], <vscale x 4 x i1> splat (i1 true), i32 [[EVL]])
; EVL: call float @llvm.vp.reduce.fadd.nxv4f32(float {{%.*}}, <vscale x 4 x float> [[F]], <vscale x 4 x i1> splat (i1 true), i32 [[EVL]])
; EVL: [[STEP:%.*]] = zext i32 [[EVL]] to i64
; EVL: %current.iteration.next = add nuw i64 [[STEP]], %index
; EVL: [[AVL_NEXT]] = sub nuw i64 [[AVL]], [[STEP]]
; EVL: icmp eq i64 [[AVL_NEXT]], 0
; EVL: call i32 @llvm.vector.reduce.add.nxv4i32
; EVL: store i32 %v0, ptr %out
; EVL: store double %vd, ptr %dout
; EVL: store float %vf, ptr %fout
; EVL: ret void
;
; TAIL-LABEL: define void @scalar_diamond(
; TAIL: sdiv i32 840, %x
; TAIL: call i32 @scalar_helper
; TAIL: %c = phi i32
; TAIL: scalar.fission.consumer.ph:
; TAIL: vector.body:
; TAIL: load <vscale x 4 x i32>
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64
; TAIL: call float @llvm.vector.reduce.fadd.nxv4f32
; TAIL: scalar.fission.consumer.body:
; TAIL: add i32
; TAIL: fadd double
; TAIL: fadd float
; TAIL: ret void
;
; SCALAR-LABEL: define void @scalar_diamond(
; SCALAR: loop:
; SCALAR-NOT: %r0 = phi
; SCALAR: br i1 %choose, label %left, label %right
; SCALAR: left:
; SCALAR: sdiv i32 840, %x
; SCALAR: right:
; SCALAR: load double
; SCALAR: latch:
; SCALAR: %c = phi i32 [ %lc, %left ], [ 17, %right ]
; SCALAR: store i32 %c
; SCALAR: scalar.fission.consumer.body:
; SCALAR: %u0.consume = add i32 %r0.consume, %fission.contribution
; SCALAR: %u1.consume = add i32 %fission.contribution, %r1.consume
; SCALAR: %ud.consume = fadd double %rd.consume, %fission.contribution{{.*}}
; SCALAR: %uf.consume = fadd float %rf.consume, %fission.contribution{{.*}}
; SCALAR: br i1 %fission.consumer.done, label %exit{{.*}}, label %scalar.fission.consumer.body
; SCALAR: [[EXPORT:%.*]] = phi i32 [ %u0.consume, %scalar.fission.consumer.body ]
; SCALAR: %v0 = phi i32 [ 17, %entry ], [ [[EXPORT]], %exit.loopexit ]
; SCALAR: ret void
define void @scalar_diamond(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start) !dbg !4 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !7
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  %lf = fptrunc double %ld to float
  br label %latch
right:
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  %rfp = fptrunc double %rc to float
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [17, %right]
  %dc = phi double [%ld, %left], [%rc, %right]
  %fc = phi float [%lf, %left], [%rfp, %right]
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !7
exit:
  %v0 = phi i32 [17, %entry], [%u0, %latch]
  %v1 = phi i32 [-7, %entry], [%u1, %latch]
  %vd = phi double [%start, %entry], [%ud, %latch]
  %vf = phi float [%fstart, %entry], [%uf, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  store float %vf, ptr %fout
  ret void
}

; Analogous integer-only producer with different arm arithmetic, i64
; reductions and the opposite latch exit orientation. Both the header and
; latch updates execute exactly once, and their inputs are stored at the latch.
; EVL-LABEL: define void @diamond_arithmetic(
; EVL-COUNT-2: alloca [65 x i64]
; EVL-NOT: alloca
; EVL: scalar.fission.consumer.ph:
; EVL: call i64 @llvm.vector.reduce.add.nxv4i64
; EVL: ret void
; TAIL-LABEL: define void @diamond_arithmetic(
; TAIL-COUNT-2: alloca [65 x i64]
; TAIL-NOT: alloca
; TAIL: scalar.fission.consumer.ph:
; TAIL: call i64 @llvm.vector.reduce.add.nxv4i64
; TAIL: scalar.fission.consumer.body:
; TAIL: add i64
; TAIL: ret void
; SCALAR-LABEL: define void @diamond_arithmetic(
; SCALAR: %c = phi i64
; SCALAR: scalar.fission.consumer.body:
; SCALAR: %update.consume = add nuw nsw i64 %fission.contribution, %sum.consume
; SCALAR: %hupdate.consume = add nuw nsw i64 %hsum.consume, %fission.contribution{{.*}}
; SCALAR: br i1 %fission.consumer.done, label %scalar.fission.consumer.body, label %exit{{.*}}
; SCALAR: ret void
define void @diamond_arithmetic(ptr readonly %a, ptr %out, i64 %n, i32 %start) !dbg !8 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %initial = zext i32 %start to i64
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i64 [%initial, %preheader], [%update, %latch]
  %hsum = phi i64 [0, %preheader], [%hupdate, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %wide = zext i32 %x to i64
  %hupdate = add nuw nsw i64 %hsum, %wide
  %bit = and i32 %x, 1
  %choose = icmp ne i32 %bit, 0
  br i1 %choose, label %left, label %right, !dbg !9
left:
  %lc = mul nuw nsw i64 %wide, 13
  br label %latch
right:
  %shift = lshr i32 %x, 1
  %rc = zext i32 %shift to i64
  br label %latch
latch:
  %c = phi i64 [%lc, %left], [%rc, %right]
  %update = add nuw nsw i64 %c, %sum
  %next = add nuw i64 %iv, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit, !dbg !9
exit:
  %result = phi i64 [%initial, %entry], [%update, %latch]
  %hresult = phi i64 [0, %entry], [%hupdate, %latch]
  %combined = add i64 %result, %hresult
  store i64 %combined, ptr %out
  ret void
}


; A sibling consumer in an enclosing loop. Its initial values come from
; outer carried state, and each row exports results before the next producer.
; Entry scratch is overwritten, not multiplied by the outer iteration count.
; EVL-LABEL: define void @scalar_diamond_nested(
; EVL: alloca [65 x i32]
; EVL: alloca [65 x double]
; EVL-NOT: alloca
; EVL: outer:
; EVL: inner:
; EVL: br i1 %choose, label %left, label %right
; EVL: left:
; EVL: call i32 @scalar_helper
; EVL: right:
; EVL: sub i32 0, %salted
; EVL: latch:
; EVL: %c = phi i32
; EVL: store i32 %c
; EVL: store double %dc
; EVL: scalar.fission.consumer.ph:
; EVL: vector.body:
; EVL: [[NEVL:%.*]] = call i32 @llvm.experimental.get.vector.length.i64
; EVL: call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0({{.*}}i32 [[NEVL]])
; EVL: call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0({{.*}}i32 [[NEVL]])
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64(double {{%.*}}, <vscale x 4 x double> {{%.*}}, <vscale x 4 x i1> splat (i1 true), i32 [[NEVL]])
; EVL: call i32 @llvm.vector.reduce.add.nxv4i32
; EVL: row.exit:
; EVL: store i32
; EVL: store double
; EVL: ret void
; TAIL-LABEL: define void @scalar_diamond_nested(
; TAIL: call i32 @scalar_helper
; TAIL: %c = phi i32
; TAIL: scalar.fission.consumer.ph:
; TAIL: vector.body:
; TAIL: load <vscale x 4 x i32>
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64
; TAIL: scalar.fission.consumer.body:
; TAIL: add i32
; TAIL: fadd double
; TAIL: row.exit:
; TAIL: store i32
; TAIL: store double
; TAIL: ret void
; SCALAR-LABEL: define void @scalar_diamond_nested(
; SCALAR: %carry = phi i32
; SCALAR: latch:
; SCALAR: %c = phi i32
; SCALAR: scalar.fission.consumer.body:
; SCALAR: fadd double
; SCALAR: row.exit:
; SCALAR: %row.sum = phi i32 [ %update.consume, %scalar.fission.consumer.body ]
; SCALAR: %row.dsum = phi double [ %dupdate.consume, %scalar.fission.consumer.body ]
; SCALAR: ret void
define void @scalar_diamond_nested(ptr readonly %a, ptr readonly %fp, ptr %out,
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
  br label %inner
inner:
  %iv = phi i64 [0, %inner.ph], [%next, %latch]
  %sum = phi i32 [%carry, %inner.ph], [%update, %latch]
  %dsum = phi double [%dcarry, %inner.ph], [%dupdate, %latch]
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
  br label %latch
right:
  %rc = sub i32 0, %salted
  %rd = sitofp i32 %rc to double
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [%rc, %right]
  %dc = phi double [%ld, %left], [%rd, %right]
  %update = add i32 %sum, %c
  %dupdate = fadd double %dsum, %dc
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %row.exit, label %inner, !dbg !11
row.exit:
  %row.sum = phi i32 [%update, %latch]
  %row.dsum = phi double [%dupdate, %latch]
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
!1 = !DIFile(filename: "scalar-diamond.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = distinct !DISubprogram(name: "scalar_diamond", scope: !1, file: !1, line: 20, type: !5, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!5 = !DISubroutineType(types: !6)
!6 = !{}
!7 = !DILocation(line: 32, column: 7, scope: !4)
!8 = distinct !DISubprogram(name: "diamond_arithmetic", scope: !1, file: !1, line: 40, type: !5, scopeLine: 40, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!9 = !DILocation(line: 42, column: 3, scope: !8)
!10 = distinct !DISubprogram(name: "scalar_diamond_nested", scope: !1, file: !1, line: 50, type: !5, scopeLine: 50, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 62, column: 5, scope: !10)
