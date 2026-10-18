; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -force-vector-width=4 \
; RUN:   -scalable-vectorization=always -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -pass-remarks=vplan-reduction-fission \
; RUN:   -S %s -o %t 2> %t.remarks
; RUN: FileCheck %s < %t
; RUN: FileCheck %s --check-prefix=REMARK < %t.remarks
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t -o /dev/null
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<loops>,verify<scalar-evolution>' \
; RUN:   -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -force-vector-width=4 -scalable-vectorization=always -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -S %s | FileCheck %s
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' \
; RUN:   -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -force-vector-width=4 -scalable-vectorization=always -hints-allow-reordering=false \
; RUN:   -tail-folding-policy=dont-fold-tail -enable-epilogue-vectorization=false \
; RUN:   -enable-vplan-reduction-fission -S %s -o %t.tail
; RUN: FileCheck %s --check-prefix=TAIL --implicit-check-not=llvm.vp. --implicit-check-not=llvm.experimental.get.vector.length < %t.tail
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.tail -o /dev/null
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' \
; RUN:   -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -force-vector-width=4 -scalable-vectorization=off -hints-allow-reordering=false \
; RUN:   -tail-folding-policy=dont-fold-tail -enable-epilogue-vectorization=false \
; RUN:   -enable-vplan-reduction-fission -S %s | FileCheck %s --check-prefix=FIXED
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=260 \
; RUN:   -pass-remarks=vplan-reduction-fission -disable-output %s 2>&1 | FileCheck %s --check-prefix=LIMIT
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=259 \
; RUN:   -pass-remarks-missed=vplan-reduction-fission -S %s 2>&1 | FileCheck %s --check-prefix=TOOSMALL
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -S %s | FileCheck %s --check-prefix=DISABLED --implicit-check-not=scalar.fission
;
; The helper has no vector-function mapping, and its body is not available to
; opt. Its explicit contract, not its name, permits fission. No chain-depth,
; pressure, minimum-reduction-count or whole-loop vectorizability gate applies.
; The forced normal LV width makes the consumer assertion deterministic; the
; producer remains scalar. Default RVV LV folds the tail using EVL/VP, so its
; active count, masked loads, inactive-lane preservation and ordered FP are
; checked explicitly. Scalar-remainder checks live in the separate supported
; dont-fold-tail variant, which the fixed-vscale host checker executes. Both
; variants retain RVV machine verification; host execution is not RVV execution.
;
; REMARK: scalar-ir.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 260
; REMARK: scalar-ir.c:12:3: scalar-IR fission producer VF 1
; REMARK: scalar-ir.c:12:3: scalar-IR fission consumer VF vscale x 4
; LIMIT: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 260
; TOOSMALL: scalar-IR reduction fission rejected: scalar-scratch-limit
; TOOSMALL-LABEL: define void @scalar_helper_sum(
; TOOSMALL-NOT: scalar.fission
; TOOSMALL: ret void
; DISABLED-LABEL: define void @scalar_helper_sum(
; DISABLED: call i32 @scalar_helper
; DISABLED: ret void
;
; CHECK-LABEL: define void @scalar_helper_sum(
; CHECK: alloca [65 x i32]
; CHECK: br i1 %enter, label %preheader, label %exit
; CHECK: loop:
; CHECK: call i32 @scalar_helper
; CHECK: store i32
; CHECK: scalar.fission.consumer.ph:
; CHECK: vector.body:
; CHECK: [[INDEX:%.*]] = phi i64 [ 0, %vector.ph ], [ [[INDEX_NEXT:%.*]], %vector.body ]
; CHECK: [[ACC:%.*]] = phi <vscale x 4 x i32>
; CHECK: [[AVL:%.*]] = phi i64 [ %n, %vector.ph ], [ [[AVL_NEXT:%.*]], %vector.body ]
; CHECK: [[EVL:%.*]] = call i32 @llvm.experimental.get.vector.length.i64(i64 [[AVL]], i32 4, i1 true)
; CHECK: [[LOAD:%.*]] = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0(ptr align 4 {{%.*}}, <vscale x 4 x i1> splat (i1 true), i32 [[EVL]])
; CHECK: [[ADD:%.*]] = add <vscale x 4 x i32> [[ACC]], [[LOAD]]
; CHECK: call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> [[ADD]], <vscale x 4 x i32> [[ACC]], i32 [[EVL]])
; CHECK: [[STEP:%.*]] = zext i32 [[EVL]] to i64
; CHECK: [[INDEX_NEXT]] = add nuw i64 [[STEP]], [[INDEX]]
; CHECK: [[AVL_NEXT]] = sub nuw i64 [[AVL]], [[STEP]]
; CHECK: [[DONE:%.*]] = icmp eq i64 [[AVL_NEXT]], 0
; CHECK: br i1 [[DONE]], label %middle.block, label %vector.body
; CHECK: call i32 @llvm.vector.reduce.add.nxv4i32
; CHECK-NOT: scalar.fission.consumer.body:
; CHECK: store i32 %result, ptr %out
; CHECK: ret void
;
; TAIL-LABEL: define void @scalar_helper_sum(
; TAIL: alloca [65 x i32]
; TAIL: br i1 %enter, label %preheader, label %exit
; TAIL: call i32 @scalar_helper
; TAIL: scalar.fission.consumer.ph:
; TAIL: vector.body:
; TAIL: load <vscale x 4 x i32>
; TAIL: call i32 @llvm.vector.reduce.add.nxv4i32
; TAIL: scalar.fission.consumer.body:
; TAIL: add i32
; TAIL: store i32 %result, ptr %out
; TAIL: ret void

declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

define void @scalar_helper_sum(ptr readonly %a, ptr %out, i64 %n, i32 %start) !dbg !4 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [%start, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @scalar_helper(i32 %x)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !7
exit:
  %result = phi i32 [%start, %entry], [%update, %loop]
  store i32 %result, ptr %out
  ret void
}

; Same shape with an arithmetic producer and a different integer width. The
; two stages may both vectorize, with independently selected tail handling.
; CHECK-LABEL: define void @arithmetic_sum(
; CHECK: alloca [65 x i64]
; CHECK: mul <vscale x 4 x i64>
; CHECK: scalar.fission.consumer.ph:
; CHECK: call i64 @llvm.vector.reduce.add.nxv4i64
; CHECK: ret void
; TAIL-LABEL: define void @arithmetic_sum(
; TAIL: alloca [65 x i64]
; TAIL: mul <vscale x 4 x i64>
; TAIL: scalar.fission.consumer.ph:
; TAIL: call i64 @llvm.vector.reduce.add.nxv4i64
; TAIL: scalar.fission.consumer.body:
; TAIL: add i64
; TAIL: ret void
define void @arithmetic_sum(ptr readonly %a, ptr %out, i64 %n, i32 %start) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %initial = zext i32 %start to i64
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i64 [%initial, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %wide = zext i32 %x to i64
  %mul = mul i64 %wide, 13
  %c = xor i64 %mul, 7
  %update = add i64 %c, %sum
  %next = add nuw i64 %iv, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %result = phi i64 [%initial, %entry], [%update, %loop]
  store i64 %result, ptr %out
  ret void
}

; Four reductions, three independent contributions; the two i32 sums share a
; scratch slot. Initial values and operand order differ. FP is always ordered
; here, even if the separate VPlan-only FP-reordering experiment is enabled.
; CHECK-LABEL: define void @scalar_mixed(
; CHECK-COUNT-1: alloca [65 x i32]
; CHECK: alloca [65 x double]
; CHECK: alloca [65 x float]
; CHECK-NOT: alloca
; CHECK: br i1 %enter, label %preheader, label %exit
; CHECK: call i32 @scalar_helper
; CHECK: scalar.fission.consumer.ph:
; CHECK: vector.body:
; CHECK: [[DACC:%.*]] = phi double [ %start, %vector.ph ], [ [[DADD:%.*]], %vector.body ]
; CHECK: [[FACC:%.*]] = phi float [ %fstart, %vector.ph ], [ [[FADD:%.*]], %vector.body ]
; CHECK: [[MAVL:%.*]] = phi i64 [ %n, %vector.ph ], [ [[MAVL_NEXT:%.*]], %vector.body ]
; CHECK: [[MEVL:%.*]] = call i32 @llvm.experimental.get.vector.length.i64(i64 [[MAVL]], i32 4, i1 true)
; CHECK: [[SHARED:%.*]] = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0(ptr align 4 {{%.*}}, <vscale x 4 x i1> splat (i1 true), i32 [[MEVL]])
; CHECK: [[DLOAD:%.*]] = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0(ptr align 8 {{%.*}}, <vscale x 4 x i1> splat (i1 true), i32 [[MEVL]])
; CHECK: [[FLOAD:%.*]] = call <vscale x 4 x float> @llvm.vp.load.nxv4f32.p0(ptr align 4 {{%.*}}, <vscale x 4 x i1> splat (i1 true), i32 [[MEVL]])
; CHECK-NOT: @llvm.vp.load
; CHECK: add <vscale x 4 x i32> {{%.*}}, [[SHARED]]
; CHECK: add <vscale x 4 x i32> [[SHARED]], {{%.*}}
; No fast-math flags: the scalar accumulator is the first operand each time.
; CHECK: [[DADD]] = call double @llvm.vp.reduce.fadd.nxv4f64(double [[DACC]], <vscale x 4 x double> [[DLOAD]], <vscale x 4 x i1> splat (i1 true), i32 [[MEVL]])
; CHECK: [[FADD]] = call float @llvm.vp.reduce.fadd.nxv4f32(float [[FACC]], <vscale x 4 x float> [[FLOAD]], <vscale x 4 x i1> splat (i1 true), i32 [[MEVL]])
; CHECK: [[MSTEP:%.*]] = zext i32 [[MEVL]] to i64
; CHECK: %current.iteration.next = add nuw i64 [[MSTEP]], %index
; CHECK: [[MAVL_NEXT]] = sub nuw i64 [[MAVL]], [[MSTEP]]
; CHECK: icmp eq i64 [[MAVL_NEXT]], 0
; CHECK: store i32 %v0, ptr %out
; CHECK: store i32 %v1, ptr %o1
; CHECK: store double %vd, ptr %dout
; CHECK: store float %vf, ptr %fout
; CHECK: ret void
;
; TAIL-LABEL: define void @scalar_mixed(
; TAIL: alloca [65 x i32]
; TAIL: alloca [65 x double]
; TAIL: alloca [65 x float]
; TAIL-NOT: alloca
; TAIL: call i32 @scalar_helper
; TAIL: scalar.fission.consumer.ph:
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64
; TAIL: call float @llvm.vector.reduce.fadd.nxv4f32
; TAIL: scalar.fission.consumer.body:
; TAIL: fadd double
; TAIL: fadd float
; TAIL: store double %vd, ptr %dout
; TAIL: store float %vf, ptr %fout
; TAIL: ret void
define void @scalar_mixed(ptr readonly %a, ptr readonly %fp, ptr %out,
                          ptr %dout, ptr %fout, i64 %n, double %start) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %rf = phi float [%fstart, %preheader], [%uf, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @scalar_helper(i32 %x)
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %dc = fmul double %dx, 3.0
  %fc = fptrunc double %dc to float
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %v0 = phi i32 [17, %entry], [%u0, %loop]
  %v1 = phi i32 [-7, %entry], [%u1, %loop]
  %vd = phi double [%start, %entry], [%ud, %loop]
  %vf = phi float [%fstart, %entry], [%uf, %loop]
  store i32 %v0, ptr %out
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  store float %vf, ptr %fout
  ret void
}

; Constant bound, one iteration, and a narrow unsigned scratch index. Indices
; 128..199 must be zero-extended, never sign-extended by GEP.
; CHECK-LABEL: define i32 @narrow_constant(
; CHECK: alloca [200 x i32]
; CHECK: zext i8 %iv to i64
; CHECK: scalar.fission.consumer.ph:
; CHECK: ret i32
; FIXED-LABEL: define i32 @narrow_constant(
; FIXED: alloca [200 x i32]
; FIXED: call i32 @llvm.vector.reduce.add.v4i32
; FIXED: ret i32
define i32 @narrow_constant(i32 %x) {
entry:
  br label %loop
loop:
  %iv = phi i8 [0, %entry], [%next, %loop]
  %sum = phi i32 [9, %entry], [%update, %loop]
  %index = zext i8 %iv to i32
  %v = xor i32 %x, %index
  %c = call i32 @scalar_helper(i32 %v)
  %update = add i32 %sum, %c
  %next = add i8 %iv, 1
  %done = icmp eq i8 %next, -56
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
}

; CHECK-LABEL: define i32 @one_iteration(
; CHECK: alloca [1 x i32]
; CHECK: scalar.fission.consumer.body:
; CHECK: ret i32
define i32 @one_iteration(i32 %x) {
entry:
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %loop]
  %sum = phi i32 [19, %entry], [%update, %loop]
  %c = call i32 @scalar_helper(i32 %x)
  %update = add i32 %sum, %c
  %next = add i64 %iv, 1
  %done = icmp eq i64 %next, 1
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-ir.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = distinct !DISubprogram(name: "scalar_helper_sum", scope: !1, file: !1, line: 10, type: !5, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!5 = !DISubroutineType(types: !6)
!6 = !{}
!7 = !DILocation(line: 12, column: 3, scope: !4)
