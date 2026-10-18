; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -force-vector-width=4 \
; RUN:   -scalable-vectorization=always -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -pass-remarks=vplan-reduction-fission \
; RUN:   -S %s -o %t 2> %t.remarks
; RUN: FileCheck %s --check-prefixes=EVL,ONCE < %t
; RUN: FileCheck %s --check-prefix=REMARK < %t.remarks
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t -o /dev/null
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -force-vector-width=4 \
; RUN:   -scalable-vectorization=always -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-allow-fp-reordering \
; RUN:   -S %s -o %t.repeat
; RUN: FileCheck %s --check-prefixes=EVL,REPEAT < %t.repeat
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.repeat -o /dev/null
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
; RUN:   -vplan-reduction-fission-min-reductions=1000000 \
; RUN:   -vplan-reduction-fission-min-chain-depth=1000000 \
; RUN:   -vplan-reduction-fission-min-pressure-percent=1000000 \
; RUN:   -S %s | FileCheck %s --check-prefix=SCALAR
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=1044 -pass-remarks=vplan-reduction-fission \
; RUN:   -disable-output %s 2>&1 | FileCheck %s --check-prefix=LIMIT
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=1043 -pass-remarks=vplan-reduction-fission -pass-remarks-missed=vplan-reduction-fission \
; RUN:   -S %s 2>&1 | FileCheck %s --check-prefix=SMALL
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v \
; RUN:   -S %s | FileCheck %s --check-prefix=DISABLED --implicit-check-not=scalar.fission
;
; Stable compaction for one shared participation arm. Before original iteration
; i, count <= i. Each participant stores at count and increments once for ALL
; reductions. Hence P <= N <= 65; only initialized [0,P) slots are consumed.
; P=0 exports starts without arithmetic. No neutral adds/inactive speculation.
; Full-trip checked capacity/byte ceiling and original producer control remain.
; Neither stage's vectorizability is required. Forced VFs are test policy.
; Host execution uses TAIL; EVL has RVV codegen coverage only.
; SCEV forwards the single-input count LCSSA PHI to its latch incoming value
; for the EVL trip count. The latch dominates the guard, vector preheader and
; consumer; both SSA values denote exactly P on that path. Check the linkage,
; not just the spelling of the exported count, and retain the P=0 result PHIs.
; A second LV invocation forms LCSSA for those forwarded uses: the producer
; merge is exported in the guard on the latch edge, and FP reductions are
; exported in middle.block on the vector.body edge. Capture these exact PHIs
; before using them in AVL and the result join. Integer scalar reductions are
; computed in middle.block, outside the vector loop, and need no extra PHI.
;
; REMARK: scalar-compact.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044
; REMARK: scalar-compact.c:12:3: scalar-IR fission producer VF 1
; REMARK: scalar-compact.c:12:3: scalar-IR fission consumer VF vscale x 4
; REMARK: scalar-compact.c:22:5: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044
; REMARK: scalar-compact.c:22:5: scalar-IR fission producer VF 1
; REMARK: scalar-compact.c:22:5: scalar-IR fission consumer VF vscale x 4
; REMARK: scalar-compact.c:32:7: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 520
; REMARK: scalar-compact.c:42:9: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; REMARK: scalar-compact.c:42:9: scalar-IR fission producer VF 1
; REMARK: scalar-compact.c:42:9: scalar-IR fission consumer VF vscale x 4
; LIMIT: scalar-compact.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044
; SMALL: scalar-compact.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 64, scratch bytes 1024
; DISABLED-LABEL: define void @compact_triangle(
; DISABLED: sdiv i32 840, %x
; DISABLED: ret void

declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

; SCALAR-LABEL: define void @compact_triangle(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR: alloca [65 x float]
; SCALAR-NOT: alloca
; SCALAR: loop:
; SCALAR: %fission.participating = phi i64
; SCALAR-NOT: %r0 = phi
; SCALAR: br i1 %choose, label %left, label %latch
; SCALAR: left:
; SCALAR: sdiv i32 840, %x
; SCALAR: call i32 @scalar_helper
; SCALAR: load double, ptr %dp
; SCALAR: %fission.participating.next = add nuw i64 %fission.participating, 1
; SCALAR: store i32 %lc,
; SCALAR: store double %dc,
; SCALAR: store float %fc,
; SCALAR: latch:
; SCALAR: %fission.participating.merge = phi i64
; SCALAR-NOT: %m0 = phi
; SCALAR: scalar.fission.consumer.guard:
; SCALAR: %fission.participating.count = phi i64 [ %fission.participating.merge, %latch ]
; SCALAR: %fission.empty = icmp eq i64 %fission.participating.count, 0
; SCALAR: br i1 %fission.empty, label %scalar.fission.consumer.exit, label %scalar.fission.consumer.ph
; SCALAR: scalar.fission.consumer.body:
; SCALAR: %u0.consume = add i32 %r0.consume, %fission.contribution
; SCALAR: %u1.consume = add i32 %fission.contribution, %r1.consume
; SCALAR: %ud.consume = fadd double %rd.consume, %fission.contribution{{.*}}
; SCALAR: %uf.consume = fadd float %rf.consume, %fission.contribution{{.*}}
; SCALAR: %fission.consumer.more = icmp ne i64 %fission.consumer.next, %fission.participating.count
; SCALAR: scalar.fission.consumer.exit:
; SCALAR: %r0.result = phi i32 [ 17, %scalar.fission.consumer.guard ], [ %r0.lcssa, %scalar.fission.consumer.loopexit ]
; SCALAR: %r1.result = phi i32 [ -7, %scalar.fission.consumer.guard ], [ %r1.lcssa, %scalar.fission.consumer.loopexit ]
; SCALAR: %rd.result = phi double [ %start, %scalar.fission.consumer.guard ], [ %rd.lcssa, %scalar.fission.consumer.loopexit ]
; SCALAR: %rf.result = phi float [ %fstart, %scalar.fission.consumer.guard ], [ %rf.lcssa, %scalar.fission.consumer.loopexit ]
; SCALAR: ret void
; EVL-LABEL: define void @compact_triangle(
; EVL: left:
; EVL: sdiv i32 840, %x
; EVL: call i32 @scalar_helper
; EVL: store i32 %lc,
; EVL: latch:
; EVL: [[P:%fission\.participating\.merge]] = phi i64 [ %fission.participating.next, %left ], [ %fission.participating, %loop ]
; EVL: scalar.fission.consumer.guard:
; REPEAT: [[FORWARDED_P:%fission\.participating\.merge\.lcssa]] = phi i64 [ [[P]], %latch ]{{$}}
; EVL: [[EXPORTED_P:%fission\.participating\.count]] = phi i64 [ [[P]], %latch ]
; EVL: %fission.empty = icmp eq i64 [[EXPORTED_P]], 0
; EVL: br i1 %fission.empty, label %scalar.fission.consumer.exit, label %scalar.fission.consumer.ph
; EVL: scalar.fission.consumer.ph:
; EVL: vector.body:
; ONCE: [[AVL:%.*]] = phi i64 [ [[P]], %vector.ph ], [ [[AVL_NEXT:%.*]], %vector.body ]
; REPEAT: [[AVL:%.*]] = phi i64 [ [[FORWARDED_P]], %vector.ph ], [ [[AVL_NEXT:%.*]], %vector.body ]
; EVL: [[EVL:%.*]] = call i32 @llvm.experimental.get.vector.length.i64(i64 [[AVL]], i32 4, i1 true)
; EVL: call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0({{.*}}i32 [[EVL]])
; EVL: call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0({{.*}}i32 [[EVL]])
; EVL: call <vscale x 4 x float> @llvm.vp.load.nxv4f32.p0({{.*}}i32 [[EVL]])
; EVL-NOT: @llvm.vp.load
; EVL: [[DR:%.*]] = call double @llvm.vp.reduce.fadd.nxv4f64(double {{%.*}}, <vscale x 4 x double> {{%.*}}, <vscale x 4 x i1> splat (i1 true), i32 [[EVL]])
; EVL: [[FR:%.*]] = call float @llvm.vp.reduce.fadd.nxv4f32(float {{%.*}}, <vscale x 4 x float> {{%.*}}, <vscale x 4 x i1> splat (i1 true), i32 [[EVL]])
; EVL: [[STEP:%.*]] = zext i32 [[EVL]] to i64
; EVL: [[AVL_NEXT]] = sub nuw i64 [[AVL]], [[STEP]]
; EVL: [[DONE:%.*]] = icmp eq i64 [[AVL_NEXT]], 0
; EVL: br i1 [[DONE]], label %middle.block, label %vector.body
; EVL: middle.block:
; REPEAT-DAG: [[DR_EXIT:%.*]] = phi double [ [[DR]], %vector.body ]{{$}}
; REPEAT-DAG: [[FR_EXIT:%.*]] = phi float [ [[FR]], %vector.body ]{{$}}
; EVL: [[I0:%.*]] = call i32 @llvm.vector.reduce.add.nxv4i32
; EVL: [[I1:%.*]] = call i32 @llvm.vector.reduce.add.nxv4i32
; EVL: br label %scalar.fission.consumer.loopexit
; EVL: scalar.fission.consumer.loopexit:
; EVL: br label %scalar.fission.consumer.exit
; EVL: scalar.fission.consumer.exit:
; EVL: %r0.result = phi i32 [ 17, %scalar.fission.consumer.guard ], [ [[I0]], %scalar.fission.consumer.loopexit ]
; EVL: %r1.result = phi i32 [ -7, %scalar.fission.consumer.guard ], [ [[I1]], %scalar.fission.consumer.loopexit ]
; ONCE: %rd.result = phi double [ %start, %scalar.fission.consumer.guard ], [ [[DR]], %scalar.fission.consumer.loopexit ]
; REPEAT: %rd.result = phi double [ %start, %scalar.fission.consumer.guard ], [ [[DR_EXIT]], %scalar.fission.consumer.loopexit ]
; ONCE: %rf.result = phi float [ %fstart, %scalar.fission.consumer.guard ], [ [[FR]], %scalar.fission.consumer.loopexit ]
; REPEAT: %rf.result = phi float [ %fstart, %scalar.fission.consumer.guard ], [ [[FR_EXIT]], %scalar.fission.consumer.loopexit ]
; EVL: ret void
; TAIL-LABEL: define void @compact_triangle(
; TAIL: scalar.fission.consumer.guard:
; TAIL: scalar.fission.consumer.ph:
; TAIL: vector.body:
; TAIL: load <vscale x 4 x i32>
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64
; TAIL: call float @llvm.vector.reduce.fadd.nxv4f32
; TAIL: scalar.fission.consumer.body:
; TAIL: fadd double
; TAIL: fadd float
; TAIL: scalar.fission.consumer.exit:
; TAIL: ret void

define void @compact_triangle(ptr readonly %a, ptr readonly %fp, ptr %out,
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
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %rf = phi float [%fstart, %preheader], [%mf, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch, !dbg !7
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dc = load double, ptr %dp, align 8
  %fc = fptrunc double %dc to float
  %u0 = add i32 %r0, %lc
  %u1 = add i32 %lc, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  br label %latch
latch:
  %m0 = phi i32 [%u0, %left], [%r0, %loop]
  %m1 = phi i32 [%u1, %left], [%r1, %loop]
  %md = phi double [%ud, %left], [%rd, %loop]
  %mf = phi float [%uf, %left], [%rf, %loop]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !7
exit:
  %v0 = phi i32 [17, %entry], [%m0, %latch]
  %v1 = phi i32 [-7, %entry], [%m1, %latch]
  %vd = phi double [%start, %entry], [%md, %latch]
  %vf = phi float [%fstart, %entry], [%mf, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  store float %vf, ptr %fout
  ret void
}

; SCALAR-LABEL: define void @compact_diamond(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR: alloca [65 x float]
; SCALAR-NOT: alloca
; SCALAR: loop:
; SCALAR: %fission.participating = phi i64
; SCALAR-NOT: %r0 = phi
; SCALAR: br i1 %choose, label %right, label %left
; SCALAR: left:
; SCALAR: sdiv i32 840, %x
; SCALAR: call i32 @scalar_helper
; SCALAR: load double, ptr %dp
; SCALAR: %fission.participating.next = add nuw i64 %fission.participating, 1
; SCALAR: store i32 %lc,
; SCALAR: store double %dc,
; SCALAR: store float %fc,
; SCALAR: latch:
; SCALAR: %fission.participating.merge = phi i64
; SCALAR-NOT: %m0 = phi
; SCALAR: scalar.fission.consumer.guard:
; SCALAR: %fission.participating.count = phi i64 [ %fission.participating.merge, %latch ]
; SCALAR: %fission.empty = icmp eq i64 %fission.participating.count, 0
; SCALAR: br i1 %fission.empty, label %scalar.fission.consumer.exit, label %scalar.fission.consumer.ph
; SCALAR: scalar.fission.consumer.body:
; SCALAR: %u0.consume = add i32 %r0.consume, %fission.contribution
; SCALAR: %u1.consume = add i32 %fission.contribution, %r1.consume
; SCALAR: %ud.consume = fadd double %rd.consume, %fission.contribution{{.*}}
; SCALAR: %uf.consume = fadd float %rf.consume, %fission.contribution{{.*}}
; SCALAR: %fission.consumer.more = icmp ne i64 %fission.consumer.next, %fission.participating.count
; SCALAR: scalar.fission.consumer.exit:
; SCALAR: %r0.result = phi i32 [ 17, %scalar.fission.consumer.guard ], [ %r0.lcssa, %scalar.fission.consumer.loopexit ]
; SCALAR: %r1.result = phi i32 [ -7, %scalar.fission.consumer.guard ], [ %r1.lcssa, %scalar.fission.consumer.loopexit ]
; SCALAR: %rd.result = phi double [ %start, %scalar.fission.consumer.guard ], [ %rd.lcssa, %scalar.fission.consumer.loopexit ]
; SCALAR: %rf.result = phi float [ %fstart, %scalar.fission.consumer.guard ], [ %rf.lcssa, %scalar.fission.consumer.loopexit ]
; SCALAR: ret void
; EVL-LABEL: define void @compact_diamond(
; EVL: left:
; EVL: sdiv i32 840, %x
; EVL: call i32 @scalar_helper
; EVL: store i32 %lc,
; EVL: latch:
; EVL: [[P:%fission\.participating\.merge]] = phi i64 [ %fission.participating, %right ], [ %fission.participating.next, %left ]
; EVL: scalar.fission.consumer.guard:
; REPEAT: [[FORWARDED_P:%fission\.participating\.merge\.lcssa]] = phi i64 [ [[P]], %latch ]{{$}}
; EVL: [[EXPORTED_P:%fission\.participating\.count]] = phi i64 [ [[P]], %latch ]
; EVL: %fission.empty = icmp eq i64 [[EXPORTED_P]], 0
; EVL: br i1 %fission.empty, label %scalar.fission.consumer.exit, label %scalar.fission.consumer.ph
; EVL: scalar.fission.consumer.ph:
; EVL: vector.body:
; ONCE: [[AVL:%.*]] = phi i64 [ [[P]], %vector.ph ], [ [[AVL_NEXT:%.*]], %vector.body ]
; REPEAT: [[AVL:%.*]] = phi i64 [ [[FORWARDED_P]], %vector.ph ], [ [[AVL_NEXT:%.*]], %vector.body ]
; EVL: [[EVL:%.*]] = call i32 @llvm.experimental.get.vector.length.i64(i64 [[AVL]], i32 4, i1 true)
; EVL: call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0({{.*}}i32 [[EVL]])
; EVL: call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0({{.*}}i32 [[EVL]])
; EVL: call <vscale x 4 x float> @llvm.vp.load.nxv4f32.p0({{.*}}i32 [[EVL]])
; EVL-NOT: @llvm.vp.load
; EVL: [[DR:%.*]] = call double @llvm.vp.reduce.fadd.nxv4f64(double {{%.*}}, <vscale x 4 x double> {{%.*}}, <vscale x 4 x i1> splat (i1 true), i32 [[EVL]])
; EVL: [[FR:%.*]] = call float @llvm.vp.reduce.fadd.nxv4f32(float {{%.*}}, <vscale x 4 x float> {{%.*}}, <vscale x 4 x i1> splat (i1 true), i32 [[EVL]])
; EVL: [[STEP:%.*]] = zext i32 [[EVL]] to i64
; EVL: [[AVL_NEXT]] = sub nuw i64 [[AVL]], [[STEP]]
; EVL: [[DONE:%.*]] = icmp eq i64 [[AVL_NEXT]], 0
; EVL: br i1 [[DONE]], label %middle.block, label %vector.body
; EVL: middle.block:
; REPEAT-DAG: [[DR_EXIT:%.*]] = phi double [ [[DR]], %vector.body ]{{$}}
; REPEAT-DAG: [[FR_EXIT:%.*]] = phi float [ [[FR]], %vector.body ]{{$}}
; EVL: [[I0:%.*]] = call i32 @llvm.vector.reduce.add.nxv4i32
; EVL: [[I1:%.*]] = call i32 @llvm.vector.reduce.add.nxv4i32
; EVL: br label %scalar.fission.consumer.loopexit
; EVL: scalar.fission.consumer.loopexit:
; EVL: br label %scalar.fission.consumer.exit
; EVL: scalar.fission.consumer.exit:
; EVL: %r0.result = phi i32 [ 17, %scalar.fission.consumer.guard ], [ [[I0]], %scalar.fission.consumer.loopexit ]
; EVL: %r1.result = phi i32 [ -7, %scalar.fission.consumer.guard ], [ [[I1]], %scalar.fission.consumer.loopexit ]
; ONCE: %rd.result = phi double [ %start, %scalar.fission.consumer.guard ], [ [[DR]], %scalar.fission.consumer.loopexit ]
; REPEAT: %rd.result = phi double [ %start, %scalar.fission.consumer.guard ], [ [[DR_EXIT]], %scalar.fission.consumer.loopexit ]
; ONCE: %rf.result = phi float [ %fstart, %scalar.fission.consumer.guard ], [ [[FR]], %scalar.fission.consumer.loopexit ]
; REPEAT: %rf.result = phi float [ %fstart, %scalar.fission.consumer.guard ], [ [[FR_EXIT]], %scalar.fission.consumer.loopexit ]
; EVL: ret void
; TAIL-LABEL: define void @compact_diamond(
; TAIL: scalar.fission.consumer.guard:
; TAIL: scalar.fission.consumer.ph:
; TAIL: vector.body:
; TAIL: load <vscale x 4 x i32>
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64
; TAIL: call float @llvm.vector.reduce.fadd.nxv4f32
; TAIL: scalar.fission.consumer.body:
; TAIL: fadd double
; TAIL: fadd float
; TAIL: scalar.fission.consumer.exit:
; TAIL: ret void

define void @compact_diamond(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start) !dbg !8 {
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
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %rf = phi float [%fstart, %preheader], [%mf, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp eq i32 %x, 0
  br i1 %choose, label %right, label %left, !dbg !9
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dc = load double, ptr %dp, align 8
  %fc = fptrunc double %dc to float
  %u0 = add i32 %r0, %lc
  %u1 = add i32 %lc, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  br label %latch
right:
  %unused = xor i32 %x, 7
  br label %latch
latch:
  %m0 = phi i32 [%u0, %left], [%r0, %right]
  %m1 = phi i32 [%u1, %left], [%r1, %right]
  %md = phi double [%ud, %left], [%rd, %right]
  %mf = phi float [%uf, %left], [%rf, %right]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !9
exit:
  %v0 = phi i32 [17, %entry], [%m0, %latch]
  %v1 = phi i32 [-7, %entry], [%m1, %latch]
  %vd = phi double [%start, %entry], [%md, %latch]
  %vf = phi float [%fstart, %entry], [%mf, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  store float %vf, ptr %fout
  ret void
}

; Analogous i64 reductions, wrap flags and reversed latch orientation.
; SCALAR-LABEL: define void @compact_integer(
; SCALAR: alloca [65 x i64]
; SCALAR-NOT: alloca
; SCALAR: left:
; SCALAR: store i64 %c,
; SCALAR: scalar.fission.consumer.body:
; SCALAR: %u.consume = add nuw nsw i64 %fission.contribution, %sum.consume
; SCALAR: %u2.consume = add nuw nsw i64 %sum2.consume, %fission.contribution
; SCALAR: scalar.fission.consumer.exit:
; SCALAR: ret void
; EVL-LABEL: define void @compact_integer(
; EVL: scalar.fission.consumer.guard:
; EVL: scalar.fission.consumer.ph:
; EVL: call i64 @llvm.vector.reduce.add.nxv4i64
; EVL: ret void
; TAIL-LABEL: define void @compact_integer(
; TAIL: scalar.fission.consumer.guard:
; TAIL: scalar.fission.consumer.ph:
; TAIL: call i64 @llvm.vector.reduce.add.nxv4i64
; TAIL: scalar.fission.consumer.body:
; TAIL: ret void
define void @compact_integer(ptr readonly %a, ptr %out, i64 %n, i32 %start) !dbg !10 {
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
  %sum = phi i64 [%initial, %preheader], [%m, %latch]
  %sum2 = phi i64 [0, %preheader], [%m2, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp eq i32 %x, 0
  br i1 %choose, label %latch, label %left, !dbg !11
left:
  %wide = zext i32 %x to i64
  %c = mul nuw nsw i64 %wide, 13
  %u = add nuw nsw i64 %c, %sum
  %u2 = add nuw nsw i64 %sum2, %c
  br label %latch
latch:
  %m = phi i64 [%sum, %loop], [%u, %left]
  %m2 = phi i64 [%sum2, %loop], [%u2, %left]
  %next = add nuw i64 %iv, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit, !dbg !11
exit:
  %result = phi i64 [%initial, %entry], [%m, %latch]
  %result2 = phi i64 [0, %entry], [%m2, %latch]
  %combined = add i64 %result, %result2
  store i64 %combined, ptr %out
  ret void
}

; Scratch resets per inner invocation; row stores may alias future inputs.
; SCALAR-LABEL: define void @compact_nested(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR-NOT: alloca
; SCALAR: inner:
; SCALAR: %fission.participating = phi i64 [ 0, %inner.ph ],
; SCALAR: left:
; SCALAR: call i32 @scalar_helper
; SCALAR: store i32 %lc,
; SCALAR: store double %ld,
; SCALAR: scalar.fission.consumer.guard:
; SCALAR: scalar.fission.consumer.exit:
; SCALAR: %sum.result = phi i32 [ %carry, %scalar.fission.consumer.guard ],
; SCALAR: %dsum.result = phi double [ %dcarry, %scalar.fission.consumer.guard ],
; SCALAR: row.exit:
; SCALAR: store i32
; SCALAR: store double
; SCALAR: ret void
; EVL-LABEL: define void @compact_nested(
; EVL: scalar.fission.consumer.guard:
; EVL: scalar.fission.consumer.ph:
; EVL: vector.body:
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64
; EVL: call i32 @llvm.vector.reduce.add.nxv4i32
; EVL: row.exit:
; EVL: ret void
; TAIL-LABEL: define void @compact_nested(
; TAIL: scalar.fission.consumer.guard:
; TAIL: scalar.fission.consumer.ph:
; TAIL: vector.body:
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64
; TAIL: scalar.fission.consumer.body:
; TAIL: row.exit:
; TAIL: ret void
define void @compact_nested(ptr readonly %a, ptr readonly %fp, ptr %out,
                                  ptr %dout, i64 %rows, i64 %n, double %start) !dbg !12 {
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
  %sum = phi i32 [%carry, %inner.ph], [%merged, %latch]
  %dsum = phi double [%dcarry, %inner.ph], [%dmerged, %latch]
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %salted = xor i32 %x, %salt
  %bit = and i32 %x, 1
  %choose = icmp ne i32 %bit, 0
  br i1 %choose, label %left, label %right, !dbg !13
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
  br i1 %done, label %row.exit, label %inner, !dbg !13
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

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-compact.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = distinct !DISubprogram(name: "compact_triangle", scope: !1, file: !1, line: 10, type: !5, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!5 = !DISubroutineType(types: !6)
!6 = !{}
!7 = !DILocation(line: 12, column: 3, scope: !4)
!8 = distinct !DISubprogram(name: "compact_diamond", scope: !1, file: !1, line: 20, type: !5, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!9 = !DILocation(line: 22, column: 5, scope: !8)
!10 = distinct !DISubprogram(name: "compact_integer", scope: !1, file: !1, line: 30, type: !5, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 32, column: 7, scope: !10)
!12 = distinct !DISubprogram(name: "compact_nested", scope: !1, file: !1, line: 40, type: !5, scopeLine: 40, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 42, column: 9, scope: !12)
