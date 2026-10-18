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
; RUN:   -S %s -o %t.repeat
; RUN: FileCheck %s --check-prefix=EVL < %t.repeat
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
; RUN:   -S %s | FileCheck %s --check-prefix=SCALAR
;
; Serial/nested/asymmetric producers retain every branch, PHI and operation.
; Division on the zero arm and FP loads with null all-division inputs would be
; invalid. Four reductions share three slots. No original-loop vectorizability
; requirement: scalar_helper has no vector mapping. The execution checker runs
; actual transformed stages and tails, after one and two LV invocations.
;
; REMARK: scalar-acyclic.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044
; REMARK: scalar-acyclic.c:12:3: scalar-IR fission producer VF 1
; REMARK: scalar-acyclic.c:12:3: scalar-IR fission consumer VF vscale x 4
; REMARK: scalar-acyclic.c:22:5: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044
; REMARK: scalar-acyclic.c:22:5: scalar-IR fission producer VF 1
; REMARK: scalar-acyclic.c:22:5: scalar-IR fission consumer VF vscale x 4
; REMARK: scalar-acyclic.c:42:9: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044
; REMARK: scalar-acyclic.c:42:9: scalar-IR fission producer VF 1
; REMARK: scalar-acyclic.c:42:9: scalar-IR fission consumer VF vscale x 4
; REMARK: scalar-acyclic.c:32:7: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; REMARK: scalar-acyclic.c:32:7: scalar-IR fission producer VF 1
; REMARK: scalar-acyclic.c:32:7: scalar-IR fission consumer VF vscale x 4

declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

; EVL-LABEL: define void @acyclic_serial(
; EVL: alloca [65 x i32]
; EVL: alloca [65 x double]
; EVL: alloca [65 x float]
; EVL-NOT: alloca
; EVL: loop:
; EVL: br i1 %choose, label %left, label %right
; EVL: left:
; EVL: sdiv i32 840, %x
; EVL: call i32 @scalar_helper
; EVL: latch:
; EVL: store i32 %c
; EVL: store double %dc
; EVL: store float %fc
; EVL: scalar.fission.consumer.ph:
; EVL: vector.body:
; EVL: [[SAVL:%.*]] = phi i64 [ %n, %vector.ph ], [ [[SNEXT:%.*]], %vector.body ]
; EVL: [[SEVL:%.*]] = call i32 @llvm.experimental.get.vector.length.i64(i64 [[SAVL]], i32 4, i1 true)
; EVL: call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0({{.*}}i32 [[SEVL]])
; EVL: [[SD:%.*]] = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0({{.*}}i32 [[SEVL]])
; EVL: [[SF:%.*]] = call <vscale x 4 x float> @llvm.vp.load.nxv4f32.p0({{.*}}i32 [[SEVL]])
; EVL-NOT: @llvm.vp.load
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64(double {{%.*}}, <vscale x 4 x double> [[SD]], <vscale x 4 x i1> splat (i1 true), i32 [[SEVL]])
; EVL: call float @llvm.vp.reduce.fadd.nxv4f32(float {{%.*}}, <vscale x 4 x float> [[SF]], <vscale x 4 x i1> splat (i1 true), i32 [[SEVL]])
; EVL: [[SSTEP:%.*]] = zext i32 [[SEVL]] to i64
; EVL: [[SNEXT]] = sub nuw i64 [[SAVL]], [[SSTEP]]
; EVL: icmp eq i64 [[SNEXT]], 0
; EVL: call i32 @llvm.vector.reduce.add.nxv4i32
; EVL: ret void
; TAIL-LABEL: define void @acyclic_serial(
; TAIL: alloca [65 x i32]
; TAIL: alloca [65 x double]
; TAIL: alloca [65 x float]
; TAIL-NOT: alloca
; TAIL: loop:
; TAIL: br i1 %choose, label %left, label %right
; TAIL: left:
; TAIL: sdiv i32 840, %x
; TAIL: call i32 @scalar_helper
; TAIL: latch:
; TAIL: store i32 %c
; TAIL: store double %dc
; TAIL: store float %fc
; TAIL: scalar.fission.consumer.ph:
; TAIL: vector.body:
; TAIL: load <vscale x 4 x i32>
; TAIL: load <vscale x 4 x double>
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64
; TAIL: call i32 @llvm.vector.reduce.add.nxv4i32
; TAIL: scalar.fission.consumer.body:
; TAIL: fadd double
; TAIL: ret void
; SCALAR-LABEL: define void @acyclic_serial(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR: alloca [65 x float]
; SCALAR-NOT: alloca
; SCALAR: loop:
; SCALAR: br i1 %choose, label %left, label %right
; SCALAR: left:
; SCALAR: sdiv i32 840, %x
; SCALAR: call i32 @scalar_helper
; SCALAR: latch:
; SCALAR: store i32 %c
; SCALAR: store double %dc
; SCALAR: store float %fc
; SCALAR: scalar.fission.consumer.ph:
; SCALAR: %u0.consume = add i32 %r0.consume, %fission.contribution
; SCALAR: %u1.consume = add i32 %fission.contribution, %r1.consume
; SCALAR: %ud.consume = fadd double %rd.consume, %fission.contribution{{.*}}
; SCALAR: %uf.consume = fadd float %rf.consume, %fission.contribution{{.*}}
; SCALAR: ret void
define void @acyclic_serial(ptr readonly %a, ptr readonly %fp, ptr %out,
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
  br label %first.merge
right:
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  br label %first.merge
first.merge:
  %first.c = phi i32 [%lc, %left], [17, %right]
  %first.d = phi double [%ld, %left], [%rc, %right]
  %parity = and i64 %iv, 1
  %second = icmp ne i64 %parity, 0
  br i1 %second, label %positive, label %negative
positive:
  %pc = add i32 %first.c, 23
  %pd = fmul double %first.d, 0.5
  br label %latch
negative:
  %nc = sub i32 %first.c, 9
  %nd = fmul double %first.d, -1.0
  br label %latch
latch:
  %c = phi i32 [%pc, %positive], [%nc, %negative]
  %dc = phi double [%pd, %positive], [%nd, %negative]
  %fc = fptrunc double %dc to float
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

; Inner diamond only visited on the nonzero arm.
; EVL-LABEL: define void @acyclic_nested(
; EVL: alloca [65 x i32]
; EVL: alloca [65 x double]
; EVL: alloca [65 x float]
; EVL-NOT: alloca
; EVL: loop:
; EVL: br i1 %choose, label %left, label %right
; EVL: left:
; EVL: sdiv i32 840, %x
; EVL: call i32 @scalar_helper
; EVL: latch:
; EVL: store i32 %c
; EVL: store double %dc
; EVL: store float %fc
; EVL: scalar.fission.consumer.ph:
; EVL: vector.body:
; EVL: [[NAVL:%.*]] = phi i64 [ %n, %vector.ph ], [ [[NNEXT:%.*]], %vector.body ]
; EVL: [[NEVL:%.*]] = call i32 @llvm.experimental.get.vector.length.i64(i64 [[NAVL]], i32 4, i1 true)
; EVL: call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0({{.*}}i32 [[NEVL]])
; EVL: [[ND:%.*]] = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0({{.*}}i32 [[NEVL]])
; EVL: [[NF:%.*]] = call <vscale x 4 x float> @llvm.vp.load.nxv4f32.p0({{.*}}i32 [[NEVL]])
; EVL-NOT: @llvm.vp.load
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64(double {{%.*}}, <vscale x 4 x double> [[ND]], <vscale x 4 x i1> splat (i1 true), i32 [[NEVL]])
; EVL: call float @llvm.vp.reduce.fadd.nxv4f32(float {{%.*}}, <vscale x 4 x float> [[NF]], <vscale x 4 x i1> splat (i1 true), i32 [[NEVL]])
; EVL: [[NSTEP:%.*]] = zext i32 [[NEVL]] to i64
; EVL: [[NNEXT]] = sub nuw i64 [[NAVL]], [[NSTEP]]
; EVL: icmp eq i64 [[NNEXT]], 0
; EVL: call i32 @llvm.vector.reduce.add.nxv4i32
; EVL: ret void
; TAIL-LABEL: define void @acyclic_nested(
; TAIL: alloca [65 x i32]
; TAIL: alloca [65 x double]
; TAIL: alloca [65 x float]
; TAIL-NOT: alloca
; TAIL: loop:
; TAIL: br i1 %choose, label %left, label %right
; TAIL: left:
; TAIL: sdiv i32 840, %x
; TAIL: call i32 @scalar_helper
; TAIL: latch:
; TAIL: store i32 %c
; TAIL: store double %dc
; TAIL: store float %fc
; TAIL: scalar.fission.consumer.ph:
; TAIL: vector.body:
; TAIL: load <vscale x 4 x i32>
; TAIL: load <vscale x 4 x double>
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64
; TAIL: call i32 @llvm.vector.reduce.add.nxv4i32
; TAIL: scalar.fission.consumer.body:
; TAIL: fadd double
; TAIL: ret void
; SCALAR-LABEL: define void @acyclic_nested(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR: alloca [65 x float]
; SCALAR-NOT: alloca
; SCALAR: loop:
; SCALAR: br i1 %choose, label %left, label %right
; SCALAR: left:
; SCALAR: sdiv i32 840, %x
; SCALAR: call i32 @scalar_helper
; SCALAR: latch:
; SCALAR: store i32 %c
; SCALAR: store double %dc
; SCALAR: store float %fc
; SCALAR: scalar.fission.consumer.ph:
; SCALAR: %u0.consume = add i32 %r0.consume, %fission.contribution
; SCALAR: %u1.consume = add i32 %fission.contribution, %r1.consume
; SCALAR: %ud.consume = fadd double %rd.consume, %fission.contribution{{.*}}
; SCALAR: %uf.consume = fadd float %rf.consume, %fission.contribution{{.*}}
; SCALAR: ret void
define void @acyclic_nested(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start) !dbg !10 {
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
  br i1 %choose, label %left, label %right, !dbg !11
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %positive, label %negative
positive:
  %pc = add i32 %lc, 23
  %pd = fmul double %ld, 0.5
  br label %inner.merge
negative:
  %nc = sub i32 %lc, 9
  %nd = fmul double %ld, -1.0
  br label %inner.merge
inner.merge:
  %inner.c = phi i32 [%pc, %positive], [%nc, %negative]
  %inner.d = phi double [%pd, %positive], [%nd, %negative]
  br label %latch
right:
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  br label %latch
latch:
  %c = phi i32 [%inner.c, %inner.merge], [17, %right]
  %dc = phi double [%inner.d, %inner.merge], [%rc, %right]
  %fc = fptrunc double %dc to float
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !11
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

; Asymmetric nested branches with three distinct latch predecessors.
; EVL-LABEL: define void @acyclic_three_way(
; EVL: alloca [65 x i32]
; EVL: alloca [65 x double]
; EVL: alloca [65 x float]
; EVL-NOT: alloca
; EVL: loop:
; EVL: br i1 %choose, label %left, label %right
; EVL: left:
; EVL: sdiv i32 840, %x
; EVL: call i32 @scalar_helper
; EVL: latch:
; EVL: store i32 %c
; EVL: store double %dc
; EVL: store float %fc
; EVL: scalar.fission.consumer.ph:
; EVL: vector.body:
; EVL: [[WAVL:%.*]] = phi i64 [ %n, %vector.ph ], [ [[WNEXT:%.*]], %vector.body ]
; EVL: [[WEVL:%.*]] = call i32 @llvm.experimental.get.vector.length.i64(i64 [[WAVL]], i32 4, i1 true)
; EVL: call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0({{.*}}i32 [[WEVL]])
; EVL: [[WD:%.*]] = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0({{.*}}i32 [[WEVL]])
; EVL: [[WF:%.*]] = call <vscale x 4 x float> @llvm.vp.load.nxv4f32.p0({{.*}}i32 [[WEVL]])
; EVL-NOT: @llvm.vp.load
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64(double {{%.*}}, <vscale x 4 x double> [[WD]], <vscale x 4 x i1> splat (i1 true), i32 [[WEVL]])
; EVL: call float @llvm.vp.reduce.fadd.nxv4f32(float {{%.*}}, <vscale x 4 x float> [[WF]], <vscale x 4 x i1> splat (i1 true), i32 [[WEVL]])
; EVL: [[WSTEP:%.*]] = zext i32 [[WEVL]] to i64
; EVL: [[WNEXT]] = sub nuw i64 [[WAVL]], [[WSTEP]]
; EVL: icmp eq i64 [[WNEXT]], 0
; EVL: call i32 @llvm.vector.reduce.add.nxv4i32
; EVL: ret void
; TAIL-LABEL: define void @acyclic_three_way(
; TAIL: alloca [65 x i32]
; TAIL: alloca [65 x double]
; TAIL: alloca [65 x float]
; TAIL-NOT: alloca
; TAIL: loop:
; TAIL: br i1 %choose, label %left, label %right
; TAIL: left:
; TAIL: sdiv i32 840, %x
; TAIL: call i32 @scalar_helper
; TAIL: latch:
; TAIL: store i32 %c
; TAIL: store double %dc
; TAIL: store float %fc
; TAIL: scalar.fission.consumer.ph:
; TAIL: vector.body:
; TAIL: load <vscale x 4 x i32>
; TAIL: load <vscale x 4 x double>
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64
; TAIL: call i32 @llvm.vector.reduce.add.nxv4i32
; TAIL: scalar.fission.consumer.body:
; TAIL: fadd double
; TAIL: ret void
; SCALAR-LABEL: define void @acyclic_three_way(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR: alloca [65 x float]
; SCALAR-NOT: alloca
; SCALAR: loop:
; SCALAR: br i1 %choose, label %left, label %right
; SCALAR: left:
; SCALAR: sdiv i32 840, %x
; SCALAR: call i32 @scalar_helper
; SCALAR: latch:
; SCALAR: store i32 %c
; SCALAR: store double %dc
; SCALAR: store float %fc
; SCALAR: scalar.fission.consumer.ph:
; SCALAR: %u0.consume = add i32 %r0.consume, %fission.contribution
; SCALAR: %u1.consume = add i32 %fission.contribution, %r1.consume
; SCALAR: %ud.consume = fadd double %rd.consume, %fission.contribution{{.*}}
; SCALAR: %uf.consume = fadd float %rf.consume, %fission.contribution{{.*}}
; SCALAR: ret void
define void @acyclic_three_way(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start) !dbg !12 {
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
  br i1 %choose, label %left, label %right, !dbg !13
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %positive, label %negative
positive:
  %pc = add i32 %lc, 23
  %pd = fmul double %ld, 0.5
  br label %latch
negative:
  %nc = sub i32 %lc, 9
  %nd = fmul double %ld, -1.0
  br label %latch
right:
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  br label %latch
latch:
  %c = phi i32 [%pc, %positive], [%nc, %negative], [17, %right]
  %dc = phi double [%pd, %positive], [%nd, %negative], [%rc, %right]
  %fc = fptrunc double %dc to float
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !13
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

; Serial diamond/triangle inside a real enclosing loop.
; EVL-LABEL: define void @acyclic_enclosing(
; EVL: alloca [65 x i32]
; EVL: alloca [65 x double]
; EVL-NOT: alloca
; EVL: inner:
; EVL: br i1 %choose, label %left, label %right
; EVL: left:
; EVL: call i32 @scalar_helper
; EVL: latch:
; EVL: store i32 %c
; EVL: store double %dc
; EVL: scalar.fission.consumer.ph:
; EVL: vector.body:
; EVL: [[EAVL:%.*]] = phi i64 [ %n, %vector.ph ], [ [[ENEXT:%.*]], %vector.body ]
; EVL: [[EEVL:%.*]] = call i32 @llvm.experimental.get.vector.length.i64(i64 [[EAVL]], i32 4, i1 true)
; EVL: call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0({{.*}}i32 [[EEVL]])
; EVL: [[ED:%.*]] = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0({{.*}}i32 [[EEVL]])
; EVL-NOT: @llvm.vp.load
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64(double {{%.*}}, <vscale x 4 x double> [[ED]], <vscale x 4 x i1> splat (i1 true), i32 [[EEVL]])
; EVL: [[ESTEP:%.*]] = zext i32 [[EEVL]] to i64
; EVL: [[ENEXT]] = sub nuw i64 [[EAVL]], [[ESTEP]]
; EVL: icmp eq i64 [[ENEXT]], 0
; EVL: call i32 @llvm.vector.reduce.add.nxv4i32
; EVL: row.exit:
; EVL: store i32
; EVL: store double
; EVL: ret void
; TAIL-LABEL: define void @acyclic_enclosing(
; TAIL: alloca [65 x i32]
; TAIL: alloca [65 x double]
; TAIL-NOT: alloca
; TAIL: inner:
; TAIL: br i1 %choose, label %left, label %right
; TAIL: left:
; TAIL: call i32 @scalar_helper
; TAIL: latch:
; TAIL: store i32 %c
; TAIL: store double %dc
; TAIL: scalar.fission.consumer.ph:
; TAIL: vector.body:
; TAIL: load <vscale x 4 x i32>
; TAIL: load <vscale x 4 x double>
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64
; TAIL: call i32 @llvm.vector.reduce.add.nxv4i32
; TAIL: scalar.fission.consumer.body:
; TAIL: fadd double
; TAIL: row.exit:
; TAIL: store i32
; TAIL: store double
; TAIL: ret void
; SCALAR-LABEL: define void @acyclic_enclosing(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR-NOT: alloca
; SCALAR: inner:
; SCALAR: br i1 %choose, label %left, label %right
; SCALAR: left:
; SCALAR: call i32 @scalar_helper
; SCALAR: latch:
; SCALAR: store i32 %c
; SCALAR: store double %dc
; SCALAR: scalar.fission.consumer.ph:
; SCALAR: %update.consume = add i32 %sum.consume, %fission.contribution
; SCALAR: %dupdate.consume = fadd double %dsum.consume, %fission.contribution{{.*}}
; SCALAR: row.exit:
; SCALAR: store i32
; SCALAR: store double
; SCALAR: ret void
define void @acyclic_enclosing(ptr readonly %a, ptr readonly %fp, ptr %out,
                                  ptr %dout, i64 %rows, i64 %n, double %start) !dbg !8 {
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
  br i1 %choose, label %left, label %right, !dbg !9
left:
  %lc = call i32 @scalar_helper(i32 %salted)
  %dp = getelementptr double, ptr %dbase, i64 %iv
  %dx = load double, ptr %dp, align 8
  %ld = fmul double %dx, 3.0
  br label %first.merge
right:
  %rc = sub i32 0, %salted
  %rd = sitofp i32 %rc to double
  br label %first.merge
first.merge:
  %first.c = phi i32 [%lc, %left], [%rc, %right]
  %first.d = phi double [%ld, %left], [%rd, %right]
  %parity = and i64 %iv, 1
  %second = icmp ne i64 %parity, 0
  br i1 %second, label %adjust, label %latch
adjust:
  %ac = xor i32 %first.c, 37
  %ad = fmul double %first.d, 0.5
  br label %latch
latch:
  %c = phi i32 [%first.c, %first.merge], [%ac, %adjust]
  %dc = phi double [%first.d, %first.merge], [%ad, %adjust]
  %update = add i32 %sum, %c
  %dupdate = fadd double %dsum, %dc
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %row.exit, label %inner, !dbg !9
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

; Former cross-edge rejection, preserved as a positive regression.
; EVL-LABEL: define i32 @acyclic_cross_edge(
; EVL: scalar.fission.consumer.ph:
; EVL: ret i32
; TAIL-LABEL: define i32 @acyclic_cross_edge(
; TAIL: scalar.fission.consumer.ph:
; TAIL: ret i32
; SCALAR-LABEL: define i32 @acyclic_cross_edge(
; SCALAR: br label %right
; SCALAR: store i32 %c
; SCALAR: scalar.fission.consumer.body:
; SCALAR: ret i32
define i32 @acyclic_cross_edge(ptr %a, i64 %n) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [19, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = mul i32 %x, 3
  br label %right
right:
  %rc = xor i32 %x, 7
  br label %latch
latch:
  %c = phi i32 [%rc, %right]
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %update
bypass:
  ret i32 19
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-acyclic.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = distinct !DISubprogram(name: "acyclic_serial", scope: !1, file: !1, line: 10, type: !5, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!5 = !DISubroutineType(types: !6)
!6 = !{}
!7 = !DILocation(line: 12, column: 3, scope: !4)
!8 = distinct !DISubprogram(name: "acyclic_enclosing", scope: !1, file: !1, line: 30, type: !5, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!9 = !DILocation(line: 32, column: 7, scope: !8)
!10 = distinct !DISubprogram(name: "acyclic_nested", scope: !1, file: !1, line: 20, type: !5, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 22, column: 5, scope: !10)
!12 = distinct !DISubprogram(name: "acyclic_three_way", scope: !1, file: !1, line: 40, type: !5, scopeLine: 40, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 42, column: 9, scope: !12)
