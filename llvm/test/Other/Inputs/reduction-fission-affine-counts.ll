; Retained t000025 real opt output, for the production Python checker only.
; It is not assembled: metadata/attribute definitions are intentionally omitted.
; Actual execution always transforms the original scalar-affine.ll with opt.

define void @affine_const(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) #1 !dbg !4 {
entry:
  %scalar.fission.scratch = alloca [65 x i32], align 4
  %scalar.fission.scratch1 = alloca [65 x double], align 8
  %scalar.fission.scratch2 = alloca [65 x float], align 4
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit

preheader:                                        ; preds = %entry
  %limit = add nuw nsw i64 %n, 7
  br label %loop, !dbg !7

loop:                                             ; preds = %latch, %preheader
  %fission.ordinal = phi i64 [ 0, %preheader ], [ %fission.completed, %latch ]
  %iv = phi i64 [ 7, %preheader ], [ %next, %latch ]
  %index = sub nuw nsw i64 %iv, 7
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !7

left:                                             ; preds = %loop
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge

right:                                            ; preds = %loop
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.000000e+00
  br label %first.merge

first.merge:                                      ; preds = %right, %left
  %first.c = phi i32 [ %lc, %left ], [ 17, %right ]
  %first.d = phi double [ %ld, %left ], [ %rc, %right ]
  %parity = and i64 %index, 1
  %second = icmp ne i64 %parity, 0
  br i1 %second, label %positive, label %negative

positive:                                         ; preds = %first.merge
  %pc = add i32 %first.c, 23
  %pd = fmul double %first.d, 5.000000e-01
  br label %latch

negative:                                         ; preds = %first.merge
  %nc = sub i32 %first.c, 9
  %nd = fmul double %first.d, -1.000000e+00
  br label %latch

latch:                                            ; preds = %negative, %positive
  %c = phi i32 [ %pc, %positive ], [ %nc, %negative ]
  %dc = phi double [ %pd, %positive ], [ %nd, %negative ]
  %fc = fptrunc double %dc to float
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %limit, %next
  %fission.completed = add nuw i64 %fission.ordinal, 1, !dbg !7
  %0 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %fission.ordinal, !dbg !7
  store i32 %c, ptr %0, align 4, !dbg !7
  %1 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %fission.ordinal, !dbg !7
  store double %dc, ptr %1, align 8, !dbg !7
  %2 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %fission.ordinal, !dbg !7
  store float %fc, ptr %2, align 4, !dbg !7
  br i1 %done, label %scalar.fission.consumer.ph, label %loop, !dbg !7, !llvm.loop !8

scalar.fission.consumer.ph:                       ; preds = %latch
  %fission.completed.count = phi i64 [ %fission.completed, %latch ]
  br label %vector.ph

vector.ph:                                        ; preds = %scalar.fission.consumer.ph
  br label %vector.body

vector.body:                                      ; preds = %vector.body, %vector.ph
  %index5 = phi i64 [ 0, %vector.ph ], [ %current.iteration.next, %vector.body ], !dbg !7
  %vec.phi = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 17, i32 0), %vector.ph ], [ %11, %vector.body ]
  %vec.phi6 = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 -7, i32 0), %vector.ph ], [ %12, %vector.body ]
  %vec.phi7 = phi double [ %start, %vector.ph ], [ %9, %vector.body ]
  %vec.phi8 = phi float [ %fstart, %vector.ph ], [ %10, %vector.body ]
  %avl = phi i64 [ %n, %vector.ph ], [ %avl.next, %vector.body ]
  %3 = call i32 @llvm.experimental.get.vector.length.i64(i64 %avl, i32 4, i1 true)
  %4 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %index5, !dbg !7
  %vp.op.load = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0(ptr align 4 %4, <vscale x 4 x i1> splat (i1 true), i32 %3), !dbg !7
  %5 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %index5, !dbg !7
  %vp.op.load9 = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0(ptr align 8 %5, <vscale x 4 x i1> splat (i1 true), i32 %3), !dbg !7
  %6 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %index5, !dbg !7
  %vp.op.load10 = call <vscale x 4 x float> @llvm.vp.load.nxv4f32.p0(ptr align 4 %6, <vscale x 4 x i1> splat (i1 true), i32 %3), !dbg !7
  %7 = add <vscale x 4 x i32> %vec.phi, %vp.op.load, !dbg !7
  %8 = add <vscale x 4 x i32> %vp.op.load, %vec.phi6, !dbg !7
  %9 = call double @llvm.vp.reduce.fadd.nxv4f64(double %vec.phi7, <vscale x 4 x double> %vp.op.load9, <vscale x 4 x i1> splat (i1 true), i32 %3)
  %10 = call float @llvm.vp.reduce.fadd.nxv4f32(float %vec.phi8, <vscale x 4 x float> %vp.op.load10, <vscale x 4 x i1> splat (i1 true), i32 %3)
  %11 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %7, <vscale x 4 x i32> %vec.phi, i32 %3)
  %12 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %8, <vscale x 4 x i32> %vec.phi6, i32 %3)
  %13 = zext i32 %3 to i64, !dbg !7
  %current.iteration.next = add nuw i64 %13, %index5, !dbg !7
  %avl.next = sub nuw i64 %avl, %13
  %14 = icmp eq i64 %avl.next, 0
  br i1 %14, label %middle.block, label %vector.body, !dbg !7, !llvm.loop !10

middle.block:                                     ; preds = %vector.body
  %15 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %11), !dbg !7
  %16 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %12), !dbg !7
  br label %exit.loopexit, !dbg !7

exit.loopexit:                                    ; preds = %middle.block
  br label %exit

exit:                                             ; preds = %exit.loopexit, %entry
  %v0 = phi i32 [ 17, %entry ], [ %15, %exit.loopexit ]
  %v1 = phi i32 [ -7, %entry ], [ %16, %exit.loopexit ]
  %vd = phi double [ %start, %entry ], [ %9, %exit.loopexit ]
  %vf = phi float [ %fstart, %entry ], [ %10, %exit.loopexit ]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out, align 4
  store i32 %v1, ptr %o1, align 4
  store double %vd, ptr %dout, align 8
  store float %vf, ptr %fout, align 4
  ret void
}

define void @affine_runtime(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) #1 !dbg !15 {
entry:
  %scalar.fission.scratch = alloca [65 x i32], align 4
  %scalar.fission.scratch1 = alloca [65 x double], align 8
  %scalar.fission.scratch2 = alloca [65 x float], align 4
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit

preheader:                                        ; preds = %entry
  %bits = and i64 %begin, 31
  %origin = add nuw nsw i64 %bits, 1
  %span = shl i64 %n, 1
  %limit = add nuw nsw i64 %origin, %span
  br label %loop, !dbg !16

loop:                                             ; preds = %latch, %preheader
  %fission.ordinal = phi i64 [ 0, %preheader ], [ %fission.completed, %latch ]
  %iv = phi i64 [ %origin, %preheader ], [ %next, %latch ]
  %distance = sub nuw nsw i64 %iv, %origin
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !16

left:                                             ; preds = %loop
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge

right:                                            ; preds = %loop
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.000000e+00
  br label %first.merge

first.merge:                                      ; preds = %right, %left
  %first.c = phi i32 [ %lc, %left ], [ 17, %right ]
  %first.d = phi double [ %ld, %left ], [ %rc, %right ]
  %parity = and i64 %index, 1
  %second = icmp ne i64 %parity, 0
  br i1 %second, label %positive, label %negative

positive:                                         ; preds = %first.merge
  %pc = add i32 %first.c, 23
  %pd = fmul double %first.d, 5.000000e-01
  br label %latch

negative:                                         ; preds = %first.merge
  %nc = sub i32 %first.c, 9
  %nd = fmul double %first.d, -1.000000e+00
  br label %latch

latch:                                            ; preds = %negative, %positive
  %c = phi i32 [ %pc, %positive ], [ %nc, %negative ]
  %dc = phi double [ %pd, %positive ], [ %nd, %negative ]
  %fc = fptrunc double %dc to float
  %next = add nuw nsw i64 %iv, 2
  %done = icmp ne i64 %next, %limit
  %fission.completed = add nuw i64 %fission.ordinal, 1, !dbg !16
  %0 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %fission.ordinal, !dbg !16
  store i32 %c, ptr %0, align 4, !dbg !16
  %1 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %fission.ordinal, !dbg !16
  store double %dc, ptr %1, align 8, !dbg !16
  %2 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %fission.ordinal, !dbg !16
  store float %fc, ptr %2, align 4, !dbg !16
  br i1 %done, label %loop, label %scalar.fission.consumer.ph, !dbg !16, !llvm.loop !17

scalar.fission.consumer.ph:                       ; preds = %latch
  %fission.completed.count = phi i64 [ %fission.completed, %latch ]
  %3 = add i64 %span, -2
  %4 = lshr i64 %3, 1
  %5 = add nuw i64 %4, 1
  br label %vector.ph

vector.ph:                                        ; preds = %scalar.fission.consumer.ph
  br label %vector.body

vector.body:                                      ; preds = %vector.body, %vector.ph
  %index5 = phi i64 [ 0, %vector.ph ], [ %current.iteration.next, %vector.body ], !dbg !16
  %vec.phi = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 17, i32 0), %vector.ph ], [ %14, %vector.body ]
  %vec.phi6 = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 -7, i32 0), %vector.ph ], [ %15, %vector.body ]
  %vec.phi7 = phi double [ %start, %vector.ph ], [ %12, %vector.body ]
  %vec.phi8 = phi float [ %fstart, %vector.ph ], [ %13, %vector.body ]
  %avl = phi i64 [ %5, %vector.ph ], [ %avl.next, %vector.body ]
  %6 = call i32 @llvm.experimental.get.vector.length.i64(i64 %avl, i32 4, i1 true)
  %7 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %index5, !dbg !16
  %vp.op.load = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0(ptr align 4 %7, <vscale x 4 x i1> splat (i1 true), i32 %6), !dbg !16
  %8 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %index5, !dbg !16
  %vp.op.load9 = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0(ptr align 8 %8, <vscale x 4 x i1> splat (i1 true), i32 %6), !dbg !16
  %9 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %index5, !dbg !16
  %vp.op.load10 = call <vscale x 4 x float> @llvm.vp.load.nxv4f32.p0(ptr align 4 %9, <vscale x 4 x i1> splat (i1 true), i32 %6), !dbg !16
  %10 = add <vscale x 4 x i32> %vec.phi, %vp.op.load, !dbg !16
  %11 = add <vscale x 4 x i32> %vp.op.load, %vec.phi6, !dbg !16
  %12 = call double @llvm.vp.reduce.fadd.nxv4f64(double %vec.phi7, <vscale x 4 x double> %vp.op.load9, <vscale x 4 x i1> splat (i1 true), i32 %6)
  %13 = call float @llvm.vp.reduce.fadd.nxv4f32(float %vec.phi8, <vscale x 4 x float> %vp.op.load10, <vscale x 4 x i1> splat (i1 true), i32 %6)
  %14 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %10, <vscale x 4 x i32> %vec.phi, i32 %6)
  %15 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %11, <vscale x 4 x i32> %vec.phi6, i32 %6)
  %16 = zext i32 %6 to i64, !dbg !16
  %current.iteration.next = add nuw i64 %16, %index5, !dbg !16
  %avl.next = sub nuw i64 %avl, %16
  %17 = icmp eq i64 %avl.next, 0
  br i1 %17, label %middle.block, label %vector.body, !dbg !16, !llvm.loop !18

middle.block:                                     ; preds = %vector.body
  %18 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %14), !dbg !16
  %19 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %15), !dbg !16
  br label %exit.loopexit, !dbg !16

exit.loopexit:                                    ; preds = %middle.block
  br label %exit

exit:                                             ; preds = %exit.loopexit, %entry
  %v0 = phi i32 [ 17, %entry ], [ %18, %exit.loopexit ]
  %v1 = phi i32 [ -7, %entry ], [ %19, %exit.loopexit ]
  %vd = phi double [ %start, %entry ], [ %12, %exit.loopexit ]
  %vf = phi float [ %fstart, %entry ], [ %13, %exit.loopexit ]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out, align 4
  store i32 %v1, ptr %o1, align 4
  store double %vd, ptr %dout, align 8
  store float %vf, ptr %fout, align 4
  ret void
}

define void @affine_unsigned(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) #1 !dbg !19 {
entry:
  %scalar.fission.scratch = alloca [65 x i32], align 4
  %scalar.fission.scratch1 = alloca [65 x double], align 8
  %scalar.fission.scratch2 = alloca [65 x float], align 4
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit

preheader:                                        ; preds = %entry
  %span = mul i64 %n, 3
  %limit = add nuw nsw i64 %span, 9
  br label %loop, !dbg !20

loop:                                             ; preds = %latch, %preheader
  %fission.ordinal = phi i64 [ 0, %preheader ], [ %fission.completed, %latch ]
  %iv = phi i64 [ 9, %preheader ], [ %next, %latch ]
  %distance = sub nuw nsw i64 %iv, 9
  %index = udiv i64 %distance, 3
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !20

left:                                             ; preds = %loop
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge

right:                                            ; preds = %loop
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.000000e+00
  br label %first.merge

first.merge:                                      ; preds = %right, %left
  %first.c = phi i32 [ %lc, %left ], [ 17, %right ]
  %first.d = phi double [ %ld, %left ], [ %rc, %right ]
  %parity = and i64 %index, 1
  %second = icmp ne i64 %parity, 0
  br i1 %second, label %positive, label %negative

positive:                                         ; preds = %first.merge
  %pc = add i32 %first.c, 23
  %pd = fmul double %first.d, 5.000000e-01
  br label %latch

negative:                                         ; preds = %first.merge
  %nc = sub i32 %first.c, 9
  %nd = fmul double %first.d, -1.000000e+00
  br label %latch

latch:                                            ; preds = %negative, %positive
  %c = phi i32 [ %pc, %positive ], [ %nc, %negative ]
  %dc = phi double [ %pd, %positive ], [ %nd, %negative ]
  %fc = fptrunc double %dc to float
  %next = add nuw nsw i64 %iv, 3
  %done = icmp ult i64 %next, %limit
  %fission.completed = add nuw i64 %fission.ordinal, 1, !dbg !20
  %0 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %fission.ordinal, !dbg !20
  store i32 %c, ptr %0, align 4, !dbg !20
  %1 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %fission.ordinal, !dbg !20
  store double %dc, ptr %1, align 8, !dbg !20
  %2 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %fission.ordinal, !dbg !20
  store float %fc, ptr %2, align 4, !dbg !20
  br i1 %done, label %loop, label %scalar.fission.consumer.ph, !dbg !20, !llvm.loop !21

scalar.fission.consumer.ph:                       ; preds = %latch
  %fission.completed.count = phi i64 [ %fission.completed, %latch ]
  %3 = add i64 %span, -3
  %4 = call i64 @llvm.umin.i64(i64 %3, i64 1)
  %5 = sub i64 %span, %4
  %6 = add i64 %5, -3
  %7 = udiv i64 %6, 3
  %8 = add i64 %4, %7
  %9 = add i64 %8, 1
  br label %vector.ph

vector.ph:                                        ; preds = %scalar.fission.consumer.ph
  br label %vector.body

vector.body:                                      ; preds = %vector.body, %vector.ph
  %index5 = phi i64 [ 0, %vector.ph ], [ %current.iteration.next, %vector.body ], !dbg !20
  %vec.phi = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 17, i32 0), %vector.ph ], [ %18, %vector.body ]
  %vec.phi6 = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 -7, i32 0), %vector.ph ], [ %19, %vector.body ]
  %vec.phi7 = phi double [ %start, %vector.ph ], [ %16, %vector.body ]
  %vec.phi8 = phi float [ %fstart, %vector.ph ], [ %17, %vector.body ]
  %avl = phi i64 [ %9, %vector.ph ], [ %avl.next, %vector.body ]
  %10 = call i32 @llvm.experimental.get.vector.length.i64(i64 %avl, i32 4, i1 true)
  %11 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %index5, !dbg !20
  %vp.op.load = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0(ptr align 4 %11, <vscale x 4 x i1> splat (i1 true), i32 %10), !dbg !20
  %12 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %index5, !dbg !20
  %vp.op.load9 = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0(ptr align 8 %12, <vscale x 4 x i1> splat (i1 true), i32 %10), !dbg !20
  %13 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %index5, !dbg !20
  %vp.op.load10 = call <vscale x 4 x float> @llvm.vp.load.nxv4f32.p0(ptr align 4 %13, <vscale x 4 x i1> splat (i1 true), i32 %10), !dbg !20
  %14 = add <vscale x 4 x i32> %vec.phi, %vp.op.load, !dbg !20
  %15 = add <vscale x 4 x i32> %vp.op.load, %vec.phi6, !dbg !20
  %16 = call double @llvm.vp.reduce.fadd.nxv4f64(double %vec.phi7, <vscale x 4 x double> %vp.op.load9, <vscale x 4 x i1> splat (i1 true), i32 %10)
  %17 = call float @llvm.vp.reduce.fadd.nxv4f32(float %vec.phi8, <vscale x 4 x float> %vp.op.load10, <vscale x 4 x i1> splat (i1 true), i32 %10)
  %18 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %14, <vscale x 4 x i32> %vec.phi, i32 %10)
  %19 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %15, <vscale x 4 x i32> %vec.phi6, i32 %10)
  %20 = zext i32 %10 to i64, !dbg !20
  %current.iteration.next = add i64 %20, %index5, !dbg !20
  %avl.next = sub nuw i64 %avl, %20
  %21 = icmp eq i64 %avl.next, 0
  br i1 %21, label %middle.block, label %vector.body, !dbg !20, !llvm.loop !22

middle.block:                                     ; preds = %vector.body
  %22 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %18), !dbg !20
  %23 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %19), !dbg !20
  br label %exit.loopexit, !dbg !20

exit.loopexit:                                    ; preds = %middle.block
  br label %exit

exit:                                             ; preds = %exit.loopexit, %entry
  %v0 = phi i32 [ 17, %entry ], [ %22, %exit.loopexit ]
  %v1 = phi i32 [ -7, %entry ], [ %23, %exit.loopexit ]
  %vd = phi double [ %start, %entry ], [ %16, %exit.loopexit ]
  %vf = phi float [ %fstart, %entry ], [ %17, %exit.loopexit ]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out, align 4
  store i32 %v1, ptr %o1, align 4
  store double %vd, ptr %dout, align 8
  store float %vf, ptr %fout, align 4
  ret void
}

define void @affine_signed(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) #1 !dbg !23 {
entry:
  %scalar.fission.scratch = alloca [65 x i32], align 4
  %scalar.fission.scratch1 = alloca [65 x double], align 8
  %scalar.fission.scratch2 = alloca [65 x float], align 4
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit

preheader:                                        ; preds = %entry
  %origin = or i64 %begin, -32
  %span = shl i64 %n, 1
  %limit = add i64 %origin, %span
  br label %loop, !dbg !24

loop:                                             ; preds = %latch, %preheader
  %fission.ordinal = phi i64 [ 0, %preheader ], [ %fission.completed, %latch ]
  %iv = phi i64 [ %origin, %preheader ], [ %next, %latch ]
  %distance = sub nsw i64 %iv, %origin
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !24

left:                                             ; preds = %loop
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge

right:                                            ; preds = %loop
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.000000e+00
  br label %first.merge

first.merge:                                      ; preds = %right, %left
  %first.c = phi i32 [ %lc, %left ], [ 17, %right ]
  %first.d = phi double [ %ld, %left ], [ %rc, %right ]
  %parity = and i64 %index, 1
  %second = icmp ne i64 %parity, 0
  br i1 %second, label %positive, label %negative

positive:                                         ; preds = %first.merge
  %pc = add i32 %first.c, 23
  %pd = fmul double %first.d, 5.000000e-01
  br label %latch

negative:                                         ; preds = %first.merge
  %nc = sub i32 %first.c, 9
  %nd = fmul double %first.d, -1.000000e+00
  br label %latch

latch:                                            ; preds = %negative, %positive
  %c = phi i32 [ %pc, %positive ], [ %nc, %negative ]
  %dc = phi double [ %pd, %positive ], [ %nd, %negative ]
  %fc = fptrunc double %dc to float
  %next = add nsw i64 %iv, 2
  %done = icmp sgt i64 %limit, %next
  %fission.completed = add nuw i64 %fission.ordinal, 1, !dbg !24
  %0 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %fission.ordinal, !dbg !24
  store i32 %c, ptr %0, align 4, !dbg !24
  %1 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %fission.ordinal, !dbg !24
  store double %dc, ptr %1, align 8, !dbg !24
  %2 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %fission.ordinal, !dbg !24
  store float %fc, ptr %2, align 4, !dbg !24
  br i1 %done, label %loop, label %scalar.fission.consumer.ph, !dbg !24, !llvm.loop !25

scalar.fission.consumer.ph:                       ; preds = %latch
  %fission.completed.count = phi i64 [ %fission.completed, %latch ]
  %3 = add nsw i64 %origin, 2
  %4 = call i64 @llvm.smax.i64(i64 %limit, i64 %3)
  %5 = sub i64 %4, %origin
  %6 = add i64 %5, -1
  %7 = lshr i64 %6, 1
  %8 = add nuw i64 %7, 1
  br label %vector.ph

vector.ph:                                        ; preds = %scalar.fission.consumer.ph
  br label %vector.body

vector.body:                                      ; preds = %vector.body, %vector.ph
  %index5 = phi i64 [ 0, %vector.ph ], [ %current.iteration.next, %vector.body ], !dbg !24
  %vec.phi = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 17, i32 0), %vector.ph ], [ %17, %vector.body ]
  %vec.phi6 = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 -7, i32 0), %vector.ph ], [ %18, %vector.body ]
  %vec.phi7 = phi double [ %start, %vector.ph ], [ %15, %vector.body ]
  %vec.phi8 = phi float [ %fstart, %vector.ph ], [ %16, %vector.body ]
  %avl = phi i64 [ %8, %vector.ph ], [ %avl.next, %vector.body ]
  %9 = call i32 @llvm.experimental.get.vector.length.i64(i64 %avl, i32 4, i1 true)
  %10 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %index5, !dbg !24
  %vp.op.load = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0(ptr align 4 %10, <vscale x 4 x i1> splat (i1 true), i32 %9), !dbg !24
  %11 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %index5, !dbg !24
  %vp.op.load9 = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0(ptr align 8 %11, <vscale x 4 x i1> splat (i1 true), i32 %9), !dbg !24
  %12 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %index5, !dbg !24
  %vp.op.load10 = call <vscale x 4 x float> @llvm.vp.load.nxv4f32.p0(ptr align 4 %12, <vscale x 4 x i1> splat (i1 true), i32 %9), !dbg !24
  %13 = add <vscale x 4 x i32> %vec.phi, %vp.op.load, !dbg !24
  %14 = add <vscale x 4 x i32> %vp.op.load, %vec.phi6, !dbg !24
  %15 = call double @llvm.vp.reduce.fadd.nxv4f64(double %vec.phi7, <vscale x 4 x double> %vp.op.load9, <vscale x 4 x i1> splat (i1 true), i32 %9)
  %16 = call float @llvm.vp.reduce.fadd.nxv4f32(float %vec.phi8, <vscale x 4 x float> %vp.op.load10, <vscale x 4 x i1> splat (i1 true), i32 %9)
  %17 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %13, <vscale x 4 x i32> %vec.phi, i32 %9)
  %18 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %14, <vscale x 4 x i32> %vec.phi6, i32 %9)
  %19 = zext i32 %9 to i64, !dbg !24
  %current.iteration.next = add i64 %19, %index5, !dbg !24
  %avl.next = sub nuw i64 %avl, %19
  %20 = icmp eq i64 %avl.next, 0
  br i1 %20, label %middle.block, label %vector.body, !dbg !24, !llvm.loop !26

middle.block:                                     ; preds = %vector.body
  %21 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %17), !dbg !24
  %22 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %18), !dbg !24
  br label %exit.loopexit, !dbg !24

exit.loopexit:                                    ; preds = %middle.block
  br label %exit

exit:                                             ; preds = %exit.loopexit, %entry
  %v0 = phi i32 [ 17, %entry ], [ %21, %exit.loopexit ]
  %v1 = phi i32 [ -7, %entry ], [ %22, %exit.loopexit ]
  %vd = phi double [ %start, %entry ], [ %15, %exit.loopexit ]
  %vf = phi float [ %fstart, %entry ], [ %16, %exit.loopexit ]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out, align 4
  store i32 %v1, ptr %o1, align 4
  store double %vd, ptr %dout, align 8
  store float %vf, ptr %fout, align 4
  ret void
}

define void @affine_down(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) #1 !dbg !27 {
entry:
  %scalar.fission.scratch = alloca [65 x i32], align 4
  %scalar.fission.scratch1 = alloca [65 x double], align 8
  %scalar.fission.scratch2 = alloca [65 x float], align 4
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit

preheader:                                        ; preds = %entry
  %span = mul nuw nsw i64 %n, 3
  %limit = sub nuw nsw i64 201, %span
  br label %loop, !dbg !28

loop:                                             ; preds = %latch, %preheader
  %fission.ordinal = phi i64 [ 0, %preheader ], [ %fission.completed, %latch ]
  %iv = phi i64 [ 201, %preheader ], [ %next, %latch ]
  %distance = sub nuw nsw i64 201, %iv
  %index = udiv i64 %distance, 3
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !28

left:                                             ; preds = %loop
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge

right:                                            ; preds = %loop
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.000000e+00
  br label %first.merge

first.merge:                                      ; preds = %right, %left
  %first.c = phi i32 [ %lc, %left ], [ 17, %right ]
  %first.d = phi double [ %ld, %left ], [ %rc, %right ]
  %parity = and i64 %index, 1
  %second = icmp ne i64 %parity, 0
  br i1 %second, label %positive, label %negative

positive:                                         ; preds = %first.merge
  %pc = add i32 %first.c, 23
  %pd = fmul double %first.d, 5.000000e-01
  br label %latch

negative:                                         ; preds = %first.merge
  %nc = sub i32 %first.c, 9
  %nd = fmul double %first.d, -1.000000e+00
  br label %latch

latch:                                            ; preds = %negative, %positive
  %c = phi i32 [ %pc, %positive ], [ %nc, %negative ]
  %dc = phi double [ %pd, %positive ], [ %nd, %negative ]
  %fc = fptrunc double %dc to float
  %next = sub nuw nsw i64 %iv, 3
  %done = icmp ugt i64 %next, %limit
  %fission.completed = add i64 %fission.ordinal, 1, !dbg !28
  %0 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %fission.ordinal, !dbg !28
  store i32 %c, ptr %0, align 4, !dbg !28
  %1 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %fission.ordinal, !dbg !28
  store double %dc, ptr %1, align 8, !dbg !28
  %2 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %fission.ordinal, !dbg !28
  store float %fc, ptr %2, align 4, !dbg !28
  br i1 %done, label %loop, label %scalar.fission.consumer.ph, !dbg !28, !llvm.loop !29

scalar.fission.consumer.ph:                       ; preds = %latch
  %fission.completed.count = phi i64 [ %fission.completed, %latch ]
  br label %vector.ph

vector.ph:                                        ; preds = %scalar.fission.consumer.ph
  br label %vector.body

vector.body:                                      ; preds = %vector.body, %vector.ph
  %index5 = phi i64 [ 0, %vector.ph ], [ %current.iteration.next, %vector.body ], !dbg !28
  %vec.phi = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 17, i32 0), %vector.ph ], [ %11, %vector.body ]
  %vec.phi6 = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 -7, i32 0), %vector.ph ], [ %12, %vector.body ]
  %vec.phi7 = phi double [ %start, %vector.ph ], [ %9, %vector.body ]
  %vec.phi8 = phi float [ %fstart, %vector.ph ], [ %10, %vector.body ]
  %avl = phi i64 [ %fission.completed, %vector.ph ], [ %avl.next, %vector.body ]
  %3 = call i32 @llvm.experimental.get.vector.length.i64(i64 %avl, i32 4, i1 true)
  %4 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %index5, !dbg !28
  %vp.op.load = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0(ptr align 4 %4, <vscale x 4 x i1> splat (i1 true), i32 %3), !dbg !28
  %5 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %index5, !dbg !28
  %vp.op.load9 = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0(ptr align 8 %5, <vscale x 4 x i1> splat (i1 true), i32 %3), !dbg !28
  %6 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %index5, !dbg !28
  %vp.op.load10 = call <vscale x 4 x float> @llvm.vp.load.nxv4f32.p0(ptr align 4 %6, <vscale x 4 x i1> splat (i1 true), i32 %3), !dbg !28
  %7 = add <vscale x 4 x i32> %vec.phi, %vp.op.load, !dbg !28
  %8 = add <vscale x 4 x i32> %vp.op.load, %vec.phi6, !dbg !28
  %9 = call double @llvm.vp.reduce.fadd.nxv4f64(double %vec.phi7, <vscale x 4 x double> %vp.op.load9, <vscale x 4 x i1> splat (i1 true), i32 %3)
  %10 = call float @llvm.vp.reduce.fadd.nxv4f32(float %vec.phi8, <vscale x 4 x float> %vp.op.load10, <vscale x 4 x i1> splat (i1 true), i32 %3)
  %11 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %7, <vscale x 4 x i32> %vec.phi, i32 %3)
  %12 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %8, <vscale x 4 x i32> %vec.phi6, i32 %3)
  %13 = zext i32 %3 to i64, !dbg !28
  %current.iteration.next = add i64 %13, %index5, !dbg !28
  %avl.next = sub nuw i64 %avl, %13
  %14 = icmp eq i64 %avl.next, 0
  br i1 %14, label %middle.block, label %vector.body, !dbg !28, !llvm.loop !30

middle.block:                                     ; preds = %vector.body
  %15 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %11), !dbg !28
  %16 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %12), !dbg !28
  br label %exit.loopexit, !dbg !28

exit.loopexit:                                    ; preds = %middle.block
  br label %exit

exit:                                             ; preds = %exit.loopexit, %entry
  %v0 = phi i32 [ 17, %entry ], [ %15, %exit.loopexit ]
  %v1 = phi i32 [ -7, %entry ], [ %16, %exit.loopexit ]
  %vd = phi double [ %start, %entry ], [ %9, %exit.loopexit ]
  %vf = phi float [ %fstart, %entry ], [ %10, %exit.loopexit ]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out, align 4
  store i32 %v1, ptr %o1, align 4
  store double %vd, ptr %dout, align 8
  store float %vf, ptr %fout, align 4
  ret void
}

define void @affine_signed_down(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) #1 !dbg !31 {
entry:
  %scalar.fission.scratch = alloca [65 x i32], align 4
  %scalar.fission.scratch1 = alloca [65 x double], align 8
  %scalar.fission.scratch2 = alloca [65 x float], align 4
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit

preheader:                                        ; preds = %entry
  %bits = and i64 %begin, 31
  %origin = sub nsw i64 %bits, 17
  %span = shl i64 %n, 1
  %limit = sub i64 %origin, %span
  br label %loop, !dbg !32

loop:                                             ; preds = %latch, %preheader
  %fission.ordinal = phi i64 [ 0, %preheader ], [ %fission.completed, %latch ]
  %iv = phi i64 [ %origin, %preheader ], [ %next, %latch ]
  %distance = sub nsw i64 %origin, %iv
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !32

left:                                             ; preds = %loop
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  %bit = and i32 %x, 2
  %second = icmp ne i32 %bit, 0
  br i1 %second, label %positive, label %negative

positive:                                         ; preds = %left
  %pc = add i32 %lc, 23
  %pd = fmul double %ld, 5.000000e-01
  br label %inner.merge

negative:                                         ; preds = %left
  %nc = sub i32 %lc, 9
  %nd = fmul double %ld, -1.000000e+00
  br label %inner.merge

inner.merge:                                      ; preds = %negative, %positive
  %inner.c = phi i32 [ %pc, %positive ], [ %nc, %negative ]
  %inner.d = phi double [ %pd, %positive ], [ %nd, %negative ]
  br label %latch

right:                                            ; preds = %loop
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.000000e+00
  br label %latch

latch:                                            ; preds = %right, %inner.merge
  %c = phi i32 [ %inner.c, %inner.merge ], [ 17, %right ]
  %dc = phi double [ %inner.d, %inner.merge ], [ %rc, %right ]
  %fc = fptrunc double %dc to float
  %next = add nsw i64 %iv, -2
  %done = icmp sge i64 %limit, %next
  %fission.completed = add nuw i64 %fission.ordinal, 1, !dbg !32
  %0 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %fission.ordinal, !dbg !32
  store i32 %c, ptr %0, align 4, !dbg !32
  %1 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %fission.ordinal, !dbg !32
  store double %dc, ptr %1, align 8, !dbg !32
  %2 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %fission.ordinal, !dbg !32
  store float %fc, ptr %2, align 4, !dbg !32
  br i1 %done, label %scalar.fission.consumer.ph, label %loop, !dbg !32, !llvm.loop !33

scalar.fission.consumer.ph:                       ; preds = %latch
  %fission.completed.count = phi i64 [ %fission.completed, %latch ]
  %3 = add nsw i64 %bits, -19
  %4 = call i64 @llvm.smin.i64(i64 %limit, i64 %3)
  %5 = sub i64 %bits, %4
  %6 = add i64 %5, -18
  %7 = lshr i64 %6, 1
  %8 = add nuw i64 %7, 1
  br label %vector.ph

vector.ph:                                        ; preds = %scalar.fission.consumer.ph
  br label %vector.body

vector.body:                                      ; preds = %vector.body, %vector.ph
  %index5 = phi i64 [ 0, %vector.ph ], [ %current.iteration.next, %vector.body ], !dbg !32
  %vec.phi = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 17, i32 0), %vector.ph ], [ %17, %vector.body ]
  %vec.phi6 = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 -7, i32 0), %vector.ph ], [ %18, %vector.body ]
  %vec.phi7 = phi double [ %start, %vector.ph ], [ %15, %vector.body ]
  %vec.phi8 = phi float [ %fstart, %vector.ph ], [ %16, %vector.body ]
  %avl = phi i64 [ %8, %vector.ph ], [ %avl.next, %vector.body ]
  %9 = call i32 @llvm.experimental.get.vector.length.i64(i64 %avl, i32 4, i1 true)
  %10 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %index5, !dbg !32
  %vp.op.load = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0(ptr align 4 %10, <vscale x 4 x i1> splat (i1 true), i32 %9), !dbg !32
  %11 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %index5, !dbg !32
  %vp.op.load9 = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0(ptr align 8 %11, <vscale x 4 x i1> splat (i1 true), i32 %9), !dbg !32
  %12 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %index5, !dbg !32
  %vp.op.load10 = call <vscale x 4 x float> @llvm.vp.load.nxv4f32.p0(ptr align 4 %12, <vscale x 4 x i1> splat (i1 true), i32 %9), !dbg !32
  %13 = add <vscale x 4 x i32> %vec.phi, %vp.op.load, !dbg !32
  %14 = add <vscale x 4 x i32> %vp.op.load, %vec.phi6, !dbg !32
  %15 = call double @llvm.vp.reduce.fadd.nxv4f64(double %vec.phi7, <vscale x 4 x double> %vp.op.load9, <vscale x 4 x i1> splat (i1 true), i32 %9)
  %16 = call float @llvm.vp.reduce.fadd.nxv4f32(float %vec.phi8, <vscale x 4 x float> %vp.op.load10, <vscale x 4 x i1> splat (i1 true), i32 %9)
  %17 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %13, <vscale x 4 x i32> %vec.phi, i32 %9)
  %18 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %14, <vscale x 4 x i32> %vec.phi6, i32 %9)
  %19 = zext i32 %9 to i64, !dbg !32
  %current.iteration.next = add i64 %19, %index5, !dbg !32
  %avl.next = sub nuw i64 %avl, %19
  %20 = icmp eq i64 %avl.next, 0
  br i1 %20, label %middle.block, label %vector.body, !dbg !32, !llvm.loop !34

middle.block:                                     ; preds = %vector.body
  %21 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %17), !dbg !32
  %22 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %18), !dbg !32
  br label %exit.loopexit, !dbg !32

exit.loopexit:                                    ; preds = %middle.block
  br label %exit

exit:                                             ; preds = %exit.loopexit, %entry
  %v0 = phi i32 [ 17, %entry ], [ %21, %exit.loopexit ]
  %v1 = phi i32 [ -7, %entry ], [ %22, %exit.loopexit ]
  %vd = phi double [ %start, %entry ], [ %15, %exit.loopexit ]
  %vf = phi float [ %fstart, %entry ], [ %16, %exit.loopexit ]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out, align 4
  store i32 %v1, ptr %o1, align 4
  store double %vd, ptr %dout, align 8
  store float %vf, ptr %fout, align 4
  ret void
}

define void @affine_compact(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) #1 !dbg !35 {
entry:
  %scalar.fission.scratch = alloca [65 x i32], align 4
  %scalar.fission.scratch1 = alloca [65 x double], align 8
  %scalar.fission.scratch2 = alloca [65 x float], align 4
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit

preheader:                                        ; preds = %entry
  %span = shl nuw nsw i64 %n, 1
  %limit = sub nuw nsw i64 137, %span
  br label %loop, !dbg !36

loop:                                             ; preds = %latch, %preheader
  %fission.participating = phi i64 [ 0, %preheader ], [ %fission.participating.merge, %latch ]
  %iv = phi i64 [ 137, %preheader ], [ %next, %latch ]
  %distance = sub nuw nsw i64 137, %iv
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch, !dbg !36

left:                                             ; preds = %loop
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %dp = getelementptr double, ptr %fp, i64 %index
  %dc = load double, ptr %dp, align 8
  %fc = fptrunc double %dc to float
  %fission.participating.next = add nuw i64 %fission.participating, 1
  %0 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %fission.participating
  store i32 %lc, ptr %0, align 4
  %1 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %fission.participating
  store double %dc, ptr %1, align 8
  %2 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %fission.participating
  store float %fc, ptr %2, align 4
  br label %latch

latch:                                            ; preds = %left, %loop
  %fission.participating.merge = phi i64 [ %fission.participating.next, %left ], [ %fission.participating, %loop ]
  %next = sub nuw nsw i64 %iv, 2
  %done = icmp eq i64 %limit, %next
  br i1 %done, label %scalar.fission.consumer.guard, label %loop, !dbg !36, !llvm.loop !37

scalar.fission.consumer.guard:                    ; preds = %latch
  %fission.participating.count = phi i64 [ %fission.participating.merge, %latch ]
  %fission.empty = icmp eq i64 %fission.participating.count, 0
  br i1 %fission.empty, label %scalar.fission.consumer.exit, label %scalar.fission.consumer.ph

scalar.fission.consumer.ph:                       ; preds = %scalar.fission.consumer.guard
  br label %vector.ph

vector.ph:                                        ; preds = %scalar.fission.consumer.ph
  br label %vector.body

vector.body:                                      ; preds = %vector.body, %vector.ph
  %index5 = phi i64 [ 0, %vector.ph ], [ %current.iteration.next, %vector.body ], !dbg !36
  %vec.phi = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 17, i32 0), %vector.ph ], [ %11, %vector.body ]
  %vec.phi6 = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 -7, i32 0), %vector.ph ], [ %12, %vector.body ]
  %vec.phi7 = phi double [ %start, %vector.ph ], [ %9, %vector.body ]
  %vec.phi8 = phi float [ %fstart, %vector.ph ], [ %10, %vector.body ]
  %avl = phi i64 [ %fission.participating.merge, %vector.ph ], [ %avl.next, %vector.body ]
  %3 = call i32 @llvm.experimental.get.vector.length.i64(i64 %avl, i32 4, i1 true)
  %4 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %index5, !dbg !36
  %vp.op.load = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0(ptr align 4 %4, <vscale x 4 x i1> splat (i1 true), i32 %3), !dbg !36
  %5 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %index5, !dbg !36
  %vp.op.load9 = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0(ptr align 8 %5, <vscale x 4 x i1> splat (i1 true), i32 %3), !dbg !36
  %6 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %index5, !dbg !36
  %vp.op.load10 = call <vscale x 4 x float> @llvm.vp.load.nxv4f32.p0(ptr align 4 %6, <vscale x 4 x i1> splat (i1 true), i32 %3), !dbg !36
  %7 = add <vscale x 4 x i32> %vec.phi, %vp.op.load, !dbg !36
  %8 = add <vscale x 4 x i32> %vp.op.load, %vec.phi6, !dbg !36
  %9 = call double @llvm.vp.reduce.fadd.nxv4f64(double %vec.phi7, <vscale x 4 x double> %vp.op.load9, <vscale x 4 x i1> splat (i1 true), i32 %3)
  %10 = call float @llvm.vp.reduce.fadd.nxv4f32(float %vec.phi8, <vscale x 4 x float> %vp.op.load10, <vscale x 4 x i1> splat (i1 true), i32 %3)
  %11 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %7, <vscale x 4 x i32> %vec.phi, i32 %3)
  %12 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %8, <vscale x 4 x i32> %vec.phi6, i32 %3)
  %13 = zext i32 %3 to i64, !dbg !36
  %current.iteration.next = add i64 %13, %index5, !dbg !36
  %avl.next = sub nuw i64 %avl, %13
  %14 = icmp eq i64 %avl.next, 0
  br i1 %14, label %middle.block, label %vector.body, !dbg !36, !llvm.loop !38

middle.block:                                     ; preds = %vector.body
  %15 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %11), !dbg !36
  %16 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %12), !dbg !36
  br label %scalar.fission.consumer.loopexit, !dbg !36

scalar.fission.consumer.loopexit:                 ; preds = %middle.block
  br label %scalar.fission.consumer.exit

scalar.fission.consumer.exit:                     ; preds = %scalar.fission.consumer.loopexit, %scalar.fission.consumer.guard
  %r0.result = phi i32 [ 17, %scalar.fission.consumer.guard ], [ %15, %scalar.fission.consumer.loopexit ]
  %r1.result = phi i32 [ -7, %scalar.fission.consumer.guard ], [ %16, %scalar.fission.consumer.loopexit ]
  %rd.result = phi double [ %start, %scalar.fission.consumer.guard ], [ %9, %scalar.fission.consumer.loopexit ]
  %rf.result = phi float [ %fstart, %scalar.fission.consumer.guard ], [ %10, %scalar.fission.consumer.loopexit ]
  br label %exit.loopexit

exit.loopexit:                                    ; preds = %scalar.fission.consumer.exit
  %m0.lcssa = phi i32 [ %r0.result, %scalar.fission.consumer.exit ]
  %m1.lcssa = phi i32 [ %r1.result, %scalar.fission.consumer.exit ]
  %md.lcssa = phi double [ %rd.result, %scalar.fission.consumer.exit ]
  %mf.lcssa = phi float [ %rf.result, %scalar.fission.consumer.exit ]
  br label %exit

exit:                                             ; preds = %exit.loopexit, %entry
  %v0 = phi i32 [ 17, %entry ], [ %m0.lcssa, %exit.loopexit ]
  %v1 = phi i32 [ -7, %entry ], [ %m1.lcssa, %exit.loopexit ]
  %vd = phi double [ %start, %entry ], [ %md.lcssa, %exit.loopexit ]
  %vf = phi float [ %fstart, %entry ], [ %mf.lcssa, %exit.loopexit ]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out, align 4
  store i32 %v1, ptr %o1, align 4
  store double %vd, ptr %dout, align 8
  store float %vf, ptr %fout, align 4
  ret void
}

define void @affine_enclosing(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout, i64 %rows, i64 %n, double %start) #1 !dbg !39 {
entry:
  %scalar.fission.scratch = alloca [65 x i32], align 4
  %scalar.fission.scratch1 = alloca [65 x double], align 8
  %rows.valid = icmp ule i64 %rows, 4
  %rows.nonzero = icmp ne i64 %rows, 0
  %rows.enter = and i1 %rows.valid, %rows.nonzero
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  %enter = and i1 %rows.enter, %inner.enter
  br i1 %enter, label %outer.ph, label %exit

outer.ph:                                         ; preds = %entry
  %0 = shl i64 %n, 1
  %1 = add i64 %0, 5
  br label %outer

outer:                                            ; preds = %row.exit, %outer.ph
  %row = phi i64 [ 0, %outer.ph ], [ %row.next, %row.exit ]
  %carry = phi i32 [ 19, %outer.ph ], [ %20, %row.exit ]
  %dcarry = phi double [ %start, %outer.ph ], [ %16, %row.exit ]
  %2 = add i64 %1, %row
  %3 = add i64 %row, 7
  %smax = call i64 @llvm.smax.i64(i64 %2, i64 %3)
  %4 = mul nsw i64 %row, -1
  %5 = add i64 %4, -6
  %6 = add i64 %smax, %5
  %7 = lshr i64 %6, 1
  %8 = add nuw i64 %7, 1
  %offset = mul nuw i64 %row, 65
  %base = getelementptr i32, ptr %a, i64 %offset
  %dbase = getelementptr double, ptr %fp, i64 %offset
  %salt = trunc i64 %row to i32
  br label %inner.ph

inner.ph:                                         ; preds = %outer
  %origin = add nuw nsw i64 %row, 5
  %span = shl i64 %n, 1
  %limit = add i64 %origin, %span
  br label %inner, !dbg !40

inner:                                            ; preds = %latch, %inner.ph
  %fission.ordinal = phi i64 [ 0, %inner.ph ], [ %fission.completed, %latch ]
  %iv = phi i64 [ %origin, %inner.ph ], [ %next, %latch ]
  %distance = sub nuw nsw i64 %iv, %origin
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %base, i64 %index
  %x = load i32, ptr %p, align 4
  %salted = xor i32 %x, %salt
  %bit = and i32 %x, 1
  %choose = icmp ne i32 %bit, 0
  br i1 %choose, label %left, label %right, !dbg !40

left:                                             ; preds = %inner
  %lc = call i32 @scalar_helper(i32 %salted)
  %dp = getelementptr double, ptr %dbase, i64 %index
  %dx = load double, ptr %dp, align 8
  %ld = fmul double %dx, 3.000000e+00
  br label %first.merge

right:                                            ; preds = %inner
  %rc = sub i32 0, %salted
  %rd = sitofp i32 %rc to double
  br label %first.merge

first.merge:                                      ; preds = %right, %left
  %first.c = phi i32 [ %lc, %left ], [ %rc, %right ]
  %first.d = phi double [ %ld, %left ], [ %rd, %right ]
  %parity = and i64 %index, 1
  %second = icmp ne i64 %parity, 0
  br i1 %second, label %adjust, label %latch

adjust:                                           ; preds = %first.merge
  %ac = xor i32 %first.c, 37
  %ad = fmul double %first.d, 5.000000e-01
  br label %latch

latch:                                            ; preds = %adjust, %first.merge
  %c = phi i32 [ %first.c, %first.merge ], [ %ac, %adjust ]
  %dc = phi double [ %first.d, %first.merge ], [ %ad, %adjust ]
  %next = add nuw nsw i64 %iv, 2
  %done = icmp slt i64 %next, %limit
  %fission.completed = add nuw i64 %fission.ordinal, 1, !dbg !40
  %9 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %fission.ordinal, !dbg !40
  store i32 %c, ptr %9, align 4, !dbg !40
  %10 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %fission.ordinal, !dbg !40
  store double %dc, ptr %10, align 8, !dbg !40
  br i1 %done, label %inner, label %scalar.fission.consumer.ph, !dbg !40, !llvm.loop !41

scalar.fission.consumer.ph:                       ; preds = %latch
  %fission.completed.count = phi i64 [ %fission.completed, %latch ]
  br label %vector.ph

vector.ph:                                        ; preds = %scalar.fission.consumer.ph
  %11 = insertelement <vscale x 4 x i32> zeroinitializer, i32 %carry, i32 0
  br label %vector.body

vector.body:                                      ; preds = %vector.body, %vector.ph
  %index3 = phi i64 [ 0, %vector.ph ], [ %current.iteration.next, %vector.body ], !dbg !40
  %vec.phi = phi <vscale x 4 x i32> [ %11, %vector.ph ], [ %17, %vector.body ]
  %vec.phi4 = phi double [ %dcarry, %vector.ph ], [ %16, %vector.body ]
  %avl = phi i64 [ %8, %vector.ph ], [ %avl.next, %vector.body ]
  %12 = call i32 @llvm.experimental.get.vector.length.i64(i64 %avl, i32 4, i1 true)
  %13 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %index3, !dbg !40
  %vp.op.load = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0(ptr align 4 %13, <vscale x 4 x i1> splat (i1 true), i32 %12), !dbg !40
  %14 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %index3, !dbg !40
  %vp.op.load5 = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0(ptr align 8 %14, <vscale x 4 x i1> splat (i1 true), i32 %12), !dbg !40
  %15 = add <vscale x 4 x i32> %vec.phi, %vp.op.load, !dbg !40
  %16 = call double @llvm.vp.reduce.fadd.nxv4f64(double %vec.phi4, <vscale x 4 x double> %vp.op.load5, <vscale x 4 x i1> splat (i1 true), i32 %12)
  %17 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %15, <vscale x 4 x i32> %vec.phi, i32 %12)
  %18 = zext i32 %12 to i64, !dbg !40
  %current.iteration.next = add i64 %18, %index3, !dbg !40
  %avl.next = sub nuw i64 %avl, %18
  %19 = icmp eq i64 %avl.next, 0
  br i1 %19, label %middle.block, label %vector.body, !dbg !40, !llvm.loop !42

middle.block:                                     ; preds = %vector.body
  %20 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %17), !dbg !40
  br label %row.exit, !dbg !40

row.exit:                                         ; preds = %middle.block
  %dst = getelementptr i32, ptr %out, i64 %row
  %ddst = getelementptr double, ptr %dout, i64 %row
  store i32 %20, ptr %dst, align 4
  store double %16, ptr %ddst, align 8
  %row.next = add nuw i64 %row, 1
  %rows.done = icmp eq i64 %row.next, %rows
  br i1 %rows.done, label %exit.loopexit, label %outer

exit.loopexit:                                    ; preds = %row.exit
  br label %exit

exit:                                             ; preds = %exit.loopexit, %entry
  ret void
}

define void @affine_wrap(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) #1 !dbg !43 {
entry:
  %scalar.fission.scratch = alloca [65 x i32], align 4
  %scalar.fission.scratch1 = alloca [65 x double], align 8
  %scalar.fission.scratch2 = alloca [65 x float], align 4
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit

preheader:                                        ; preds = %entry
  %span = shl i64 %n, 1
  %limit = add i64 %begin, %span
  br label %loop, !dbg !44

loop:                                             ; preds = %latch, %preheader
  %fission.ordinal = phi i64 [ 0, %preheader ], [ %fission.completed, %latch ]
  %iv = phi i64 [ %begin, %preheader ], [ %next, %latch ]
  %distance = sub i64 %iv, %begin
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !44

left:                                             ; preds = %loop
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge

right:                                            ; preds = %loop
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.000000e+00
  br label %first.merge

first.merge:                                      ; preds = %right, %left
  %first.c = phi i32 [ %lc, %left ], [ 17, %right ]
  %first.d = phi double [ %ld, %left ], [ %rc, %right ]
  %parity = and i64 %index, 1
  %second = icmp ne i64 %parity, 0
  br i1 %second, label %positive, label %negative

positive:                                         ; preds = %first.merge
  %pc = add i32 %first.c, 23
  %pd = fmul double %first.d, 5.000000e-01
  br label %latch

negative:                                         ; preds = %first.merge
  %nc = sub i32 %first.c, 9
  %nd = fmul double %first.d, -1.000000e+00
  br label %latch

latch:                                            ; preds = %negative, %positive
  %c = phi i32 [ %pc, %positive ], [ %nc, %negative ]
  %dc = phi double [ %pd, %positive ], [ %nd, %negative ]
  %fc = fptrunc double %dc to float
  %next = add i64 %iv, 2
  %done = icmp eq i64 %limit, %next
  %fission.completed = add nuw i64 %fission.ordinal, 1, !dbg !44
  %0 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %fission.ordinal, !dbg !44
  store i32 %c, ptr %0, align 4, !dbg !44
  %1 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %fission.ordinal, !dbg !44
  store double %dc, ptr %1, align 8, !dbg !44
  %2 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %fission.ordinal, !dbg !44
  store float %fc, ptr %2, align 4, !dbg !44
  br i1 %done, label %scalar.fission.consumer.ph, label %loop, !dbg !44, !llvm.loop !45

scalar.fission.consumer.ph:                       ; preds = %latch
  %fission.completed.count = phi i64 [ %fission.completed, %latch ]
  %3 = add i64 %span, -2
  %4 = lshr i64 %3, 1
  %5 = add nuw i64 %4, 1
  br label %vector.ph

vector.ph:                                        ; preds = %scalar.fission.consumer.ph
  br label %vector.body

vector.body:                                      ; preds = %vector.body, %vector.ph
  %index5 = phi i64 [ 0, %vector.ph ], [ %current.iteration.next, %vector.body ], !dbg !44
  %vec.phi = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 17, i32 0), %vector.ph ], [ %14, %vector.body ]
  %vec.phi6 = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 -7, i32 0), %vector.ph ], [ %15, %vector.body ]
  %vec.phi7 = phi double [ %start, %vector.ph ], [ %12, %vector.body ]
  %vec.phi8 = phi float [ %fstart, %vector.ph ], [ %13, %vector.body ]
  %avl = phi i64 [ %5, %vector.ph ], [ %avl.next, %vector.body ]
  %6 = call i32 @llvm.experimental.get.vector.length.i64(i64 %avl, i32 4, i1 true)
  %7 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %index5, !dbg !44
  %vp.op.load = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0(ptr align 4 %7, <vscale x 4 x i1> splat (i1 true), i32 %6), !dbg !44
  %8 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %index5, !dbg !44
  %vp.op.load9 = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0(ptr align 8 %8, <vscale x 4 x i1> splat (i1 true), i32 %6), !dbg !44
  %9 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %index5, !dbg !44
  %vp.op.load10 = call <vscale x 4 x float> @llvm.vp.load.nxv4f32.p0(ptr align 4 %9, <vscale x 4 x i1> splat (i1 true), i32 %6), !dbg !44
  %10 = add <vscale x 4 x i32> %vec.phi, %vp.op.load, !dbg !44
  %11 = add <vscale x 4 x i32> %vp.op.load, %vec.phi6, !dbg !44
  %12 = call double @llvm.vp.reduce.fadd.nxv4f64(double %vec.phi7, <vscale x 4 x double> %vp.op.load9, <vscale x 4 x i1> splat (i1 true), i32 %6)
  %13 = call float @llvm.vp.reduce.fadd.nxv4f32(float %vec.phi8, <vscale x 4 x float> %vp.op.load10, <vscale x 4 x i1> splat (i1 true), i32 %6)
  %14 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %10, <vscale x 4 x i32> %vec.phi, i32 %6)
  %15 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %11, <vscale x 4 x i32> %vec.phi6, i32 %6)
  %16 = zext i32 %6 to i64, !dbg !44
  %current.iteration.next = add nuw i64 %16, %index5, !dbg !44
  %avl.next = sub nuw i64 %avl, %16
  %17 = icmp eq i64 %avl.next, 0
  br i1 %17, label %middle.block, label %vector.body, !dbg !44, !llvm.loop !46

middle.block:                                     ; preds = %vector.body
  %18 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %14), !dbg !44
  %19 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %15), !dbg !44
  br label %exit.loopexit, !dbg !44

exit.loopexit:                                    ; preds = %middle.block
  br label %exit

exit:                                             ; preds = %exit.loopexit, %entry
  %v0 = phi i32 [ 17, %entry ], [ %18, %exit.loopexit ]
  %v1 = phi i32 [ -7, %entry ], [ %19, %exit.loopexit ]
  %vd = phi double [ %start, %entry ], [ %12, %exit.loopexit ]
  %vf = phi float [ %fstart, %entry ], [ %13, %exit.loopexit ]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out, align 4
  store i32 %v1, ptr %o1, align 4
  store double %vd, ptr %dout, align 8
  store float %vf, ptr %fout, align 4
  ret void
}

define void @affine_current(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) #1 !dbg !47 {
entry:
  %scalar.fission.scratch = alloca [65 x i32], align 4
  %scalar.fission.scratch1 = alloca [65 x double], align 8
  %scalar.fission.scratch2 = alloca [65 x float], align 4
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit

preheader:                                        ; preds = %entry
  %last = sub nuw nsw i64 %n, 1
  %span = shl nuw nsw i64 %last, 1
  %limit = add nuw nsw i64 %span, 7
  br label %loop, !dbg !48

loop:                                             ; preds = %latch, %preheader
  %fission.ordinal = phi i64 [ 0, %preheader ], [ %fission.completed, %latch ]
  %iv = phi i64 [ 7, %preheader ], [ %next, %latch ]
  %distance = sub nuw nsw i64 %iv, 7
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !48

left:                                             ; preds = %loop
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge

right:                                            ; preds = %loop
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.000000e+00
  br label %first.merge

first.merge:                                      ; preds = %right, %left
  %first.c = phi i32 [ %lc, %left ], [ 17, %right ]
  %first.d = phi double [ %ld, %left ], [ %rc, %right ]
  %parity = and i64 %index, 1
  %second = icmp ne i64 %parity, 0
  br i1 %second, label %positive, label %negative

positive:                                         ; preds = %first.merge
  %pc = add i32 %first.c, 23
  %pd = fmul double %first.d, 5.000000e-01
  br label %latch

negative:                                         ; preds = %first.merge
  %nc = sub i32 %first.c, 9
  %nd = fmul double %first.d, -1.000000e+00
  br label %latch

latch:                                            ; preds = %negative, %positive
  %c = phi i32 [ %pc, %positive ], [ %nc, %negative ]
  %dc = phi double [ %pd, %positive ], [ %nd, %negative ]
  %fc = fptrunc double %dc to float
  %next = add nuw nsw i64 %iv, 2
  %done = icmp uge i64 %iv, %limit
  %fission.completed = add nuw i64 %fission.ordinal, 1, !dbg !48
  %0 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %fission.ordinal, !dbg !48
  store i32 %c, ptr %0, align 4, !dbg !48
  %1 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %fission.ordinal, !dbg !48
  store double %dc, ptr %1, align 8, !dbg !48
  %2 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %fission.ordinal, !dbg !48
  store float %fc, ptr %2, align 4, !dbg !48
  br i1 %done, label %scalar.fission.consumer.ph, label %loop, !dbg !48, !llvm.loop !49

scalar.fission.consumer.ph:                       ; preds = %latch
  %fission.completed.count = phi i64 [ %fission.completed, %latch ]
  %3 = shl i64 %n, 1
  %4 = add i64 %3, -1
  %5 = lshr i64 %4, 1
  %6 = add nuw i64 %5, 1
  br label %vector.ph

vector.ph:                                        ; preds = %scalar.fission.consumer.ph
  br label %vector.body

vector.body:                                      ; preds = %vector.body, %vector.ph
  %index5 = phi i64 [ 0, %vector.ph ], [ %current.iteration.next, %vector.body ], !dbg !48
  %vec.phi = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 17, i32 0), %vector.ph ], [ %15, %vector.body ]
  %vec.phi6 = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 -7, i32 0), %vector.ph ], [ %16, %vector.body ]
  %vec.phi7 = phi double [ %start, %vector.ph ], [ %13, %vector.body ]
  %vec.phi8 = phi float [ %fstart, %vector.ph ], [ %14, %vector.body ]
  %avl = phi i64 [ %6, %vector.ph ], [ %avl.next, %vector.body ]
  %7 = call i32 @llvm.experimental.get.vector.length.i64(i64 %avl, i32 4, i1 true)
  %8 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %index5, !dbg !48
  %vp.op.load = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0(ptr align 4 %8, <vscale x 4 x i1> splat (i1 true), i32 %7), !dbg !48
  %9 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %index5, !dbg !48
  %vp.op.load9 = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0(ptr align 8 %9, <vscale x 4 x i1> splat (i1 true), i32 %7), !dbg !48
  %10 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %index5, !dbg !48
  %vp.op.load10 = call <vscale x 4 x float> @llvm.vp.load.nxv4f32.p0(ptr align 4 %10, <vscale x 4 x i1> splat (i1 true), i32 %7), !dbg !48
  %11 = add <vscale x 4 x i32> %vec.phi, %vp.op.load, !dbg !48
  %12 = add <vscale x 4 x i32> %vp.op.load, %vec.phi6, !dbg !48
  %13 = call double @llvm.vp.reduce.fadd.nxv4f64(double %vec.phi7, <vscale x 4 x double> %vp.op.load9, <vscale x 4 x i1> splat (i1 true), i32 %7)
  %14 = call float @llvm.vp.reduce.fadd.nxv4f32(float %vec.phi8, <vscale x 4 x float> %vp.op.load10, <vscale x 4 x i1> splat (i1 true), i32 %7)
  %15 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %11, <vscale x 4 x i32> %vec.phi, i32 %7)
  %16 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %12, <vscale x 4 x i32> %vec.phi6, i32 %7)
  %17 = zext i32 %7 to i64, !dbg !48
  %current.iteration.next = add nuw i64 %17, %index5, !dbg !48
  %avl.next = sub nuw i64 %avl, %17
  %18 = icmp eq i64 %avl.next, 0
  br i1 %18, label %middle.block, label %vector.body, !dbg !48, !llvm.loop !50

middle.block:                                     ; preds = %vector.body
  %19 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %15), !dbg !48
  %20 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %16), !dbg !48
  br label %exit.loopexit, !dbg !48

exit.loopexit:                                    ; preds = %middle.block
  br label %exit

exit:                                             ; preds = %exit.loopexit, %entry
  %v0 = phi i32 [ 17, %entry ], [ %19, %exit.loopexit ]
  %v1 = phi i32 [ -7, %entry ], [ %20, %exit.loopexit ]
  %vd = phi double [ %start, %entry ], [ %13, %exit.loopexit ]
  %vf = phi float [ %fstart, %entry ], [ %14, %exit.loopexit ]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out, align 4
  store i32 %v1, ptr %o1, align 4
  store double %vd, ptr %dout, align 8
  store float %vf, ptr %fout, align 4
  ret void
}

define void @affine_unsigned_early(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) #1 !dbg !51 {
entry:
  %scalar.fission.scratch = alloca [65 x i32], align 4
  %scalar.fission.scratch1 = alloca [65 x double], align 8
  %scalar.fission.scratch2 = alloca [65 x float], align 4
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit

preheader:                                        ; preds = %entry
  %span = mul i64 %n, 3
  %limit = add i64 %begin, %span
  br label %loop, !dbg !52

loop:                                             ; preds = %latch, %preheader
  %fission.ordinal = phi i64 [ 0, %preheader ], [ %fission.completed, %latch ]
  %iv = phi i64 [ %begin, %preheader ], [ %next, %latch ]
  %distance = sub i64 %iv, %begin
  %index = udiv i64 %distance, 3
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !52

left:                                             ; preds = %loop
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge

right:                                            ; preds = %loop
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.000000e+00
  br label %first.merge

first.merge:                                      ; preds = %right, %left
  %first.c = phi i32 [ %lc, %left ], [ 17, %right ]
  %first.d = phi double [ %ld, %left ], [ %rc, %right ]
  %parity = and i64 %index, 1
  %second = icmp ne i64 %parity, 0
  br i1 %second, label %positive, label %negative

positive:                                         ; preds = %first.merge
  %pc = add i32 %first.c, 23
  %pd = fmul double %first.d, 5.000000e-01
  br label %latch

negative:                                         ; preds = %first.merge
  %nc = sub i32 %first.c, 9
  %nd = fmul double %first.d, -1.000000e+00
  br label %latch

latch:                                            ; preds = %negative, %positive
  %c = phi i32 [ %pc, %positive ], [ %nc, %negative ]
  %dc = phi double [ %pd, %positive ], [ %nd, %negative ]
  %fc = fptrunc double %dc to float
  %next = add i64 %iv, 3
  %done = icmp ult i64 %next, %limit
  %fission.completed = add i64 %fission.ordinal, 1, !dbg !52
  %0 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %fission.ordinal, !dbg !52
  store i32 %c, ptr %0, align 4, !dbg !52
  %1 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %fission.ordinal, !dbg !52
  store double %dc, ptr %1, align 8, !dbg !52
  %2 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %fission.ordinal, !dbg !52
  store float %fc, ptr %2, align 4, !dbg !52
  br i1 %done, label %loop, label %scalar.fission.consumer.ph, !dbg !52, !llvm.loop !53

scalar.fission.consumer.ph:                       ; preds = %latch
  %fission.completed.count = phi i64 [ %fission.completed, %latch ]
  br label %vector.ph

vector.ph:                                        ; preds = %scalar.fission.consumer.ph
  br label %vector.body

vector.body:                                      ; preds = %vector.body, %vector.ph
  %index5 = phi i64 [ 0, %vector.ph ], [ %current.iteration.next, %vector.body ], !dbg !52
  %vec.phi = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 17, i32 0), %vector.ph ], [ %11, %vector.body ]
  %vec.phi6 = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 -7, i32 0), %vector.ph ], [ %12, %vector.body ]
  %vec.phi7 = phi double [ %start, %vector.ph ], [ %9, %vector.body ]
  %vec.phi8 = phi float [ %fstart, %vector.ph ], [ %10, %vector.body ]
  %avl = phi i64 [ %fission.completed, %vector.ph ], [ %avl.next, %vector.body ]
  %3 = call i32 @llvm.experimental.get.vector.length.i64(i64 %avl, i32 4, i1 true)
  %4 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %index5, !dbg !52
  %vp.op.load = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0(ptr align 4 %4, <vscale x 4 x i1> splat (i1 true), i32 %3), !dbg !52
  %5 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %index5, !dbg !52
  %vp.op.load9 = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0(ptr align 8 %5, <vscale x 4 x i1> splat (i1 true), i32 %3), !dbg !52
  %6 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %index5, !dbg !52
  %vp.op.load10 = call <vscale x 4 x float> @llvm.vp.load.nxv4f32.p0(ptr align 4 %6, <vscale x 4 x i1> splat (i1 true), i32 %3), !dbg !52
  %7 = add <vscale x 4 x i32> %vec.phi, %vp.op.load, !dbg !52
  %8 = add <vscale x 4 x i32> %vp.op.load, %vec.phi6, !dbg !52
  %9 = call double @llvm.vp.reduce.fadd.nxv4f64(double %vec.phi7, <vscale x 4 x double> %vp.op.load9, <vscale x 4 x i1> splat (i1 true), i32 %3)
  %10 = call float @llvm.vp.reduce.fadd.nxv4f32(float %vec.phi8, <vscale x 4 x float> %vp.op.load10, <vscale x 4 x i1> splat (i1 true), i32 %3)
  %11 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %7, <vscale x 4 x i32> %vec.phi, i32 %3)
  %12 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %8, <vscale x 4 x i32> %vec.phi6, i32 %3)
  %13 = zext i32 %3 to i64, !dbg !52
  %current.iteration.next = add i64 %13, %index5, !dbg !52
  %avl.next = sub nuw i64 %avl, %13
  %14 = icmp eq i64 %avl.next, 0
  br i1 %14, label %middle.block, label %vector.body, !dbg !52, !llvm.loop !54

middle.block:                                     ; preds = %vector.body
  %15 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %11), !dbg !52
  %16 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %12), !dbg !52
  br label %exit.loopexit, !dbg !52

exit.loopexit:                                    ; preds = %middle.block
  br label %exit

exit:                                             ; preds = %exit.loopexit, %entry
  %v0 = phi i32 [ 17, %entry ], [ %15, %exit.loopexit ]
  %v1 = phi i32 [ -7, %entry ], [ %16, %exit.loopexit ]
  %vd = phi double [ %start, %entry ], [ %9, %exit.loopexit ]
  %vf = phi float [ %fstart, %entry ], [ %10, %exit.loopexit ]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out, align 4
  store i32 %v1, ptr %o1, align 4
  store double %vd, ptr %dout, align 8
  store float %vf, ptr %fout, align 4
  ret void
}

define void @affine_signed_early(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) #1 !dbg !55 {
entry:
  %scalar.fission.scratch = alloca [65 x i32], align 4
  %scalar.fission.scratch1 = alloca [65 x double], align 8
  %scalar.fission.scratch2 = alloca [65 x float], align 4
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit

preheader:                                        ; preds = %entry
  %span = mul i64 %n, 3
  %limit = add i64 %begin, %span
  br label %loop, !dbg !56

loop:                                             ; preds = %latch, %preheader
  %fission.ordinal = phi i64 [ 0, %preheader ], [ %fission.completed, %latch ]
  %iv = phi i64 [ %begin, %preheader ], [ %next, %latch ]
  %distance = sub i64 %iv, %begin
  %index = udiv i64 %distance, 3
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !56

left:                                             ; preds = %loop
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge

right:                                            ; preds = %loop
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.000000e+00
  br label %first.merge

first.merge:                                      ; preds = %right, %left
  %first.c = phi i32 [ %lc, %left ], [ 17, %right ]
  %first.d = phi double [ %ld, %left ], [ %rc, %right ]
  %parity = and i64 %index, 1
  %second = icmp ne i64 %parity, 0
  br i1 %second, label %positive, label %negative

positive:                                         ; preds = %first.merge
  %pc = add i32 %first.c, 23
  %pd = fmul double %first.d, 5.000000e-01
  br label %latch

negative:                                         ; preds = %first.merge
  %nc = sub i32 %first.c, 9
  %nd = fmul double %first.d, -1.000000e+00
  br label %latch

latch:                                            ; preds = %negative, %positive
  %c = phi i32 [ %pc, %positive ], [ %nc, %negative ]
  %dc = phi double [ %pd, %positive ], [ %nd, %negative ]
  %fc = fptrunc double %dc to float
  %next = add i64 %iv, 3
  %done = icmp slt i64 %next, %limit
  %fission.completed = add i64 %fission.ordinal, 1, !dbg !56
  %0 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %fission.ordinal, !dbg !56
  store i32 %c, ptr %0, align 4, !dbg !56
  %1 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %fission.ordinal, !dbg !56
  store double %dc, ptr %1, align 8, !dbg !56
  %2 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %fission.ordinal, !dbg !56
  store float %fc, ptr %2, align 4, !dbg !56
  br i1 %done, label %loop, label %scalar.fission.consumer.ph, !dbg !56, !llvm.loop !57

scalar.fission.consumer.ph:                       ; preds = %latch
  %fission.completed.count = phi i64 [ %fission.completed, %latch ]
  br label %vector.ph

vector.ph:                                        ; preds = %scalar.fission.consumer.ph
  br label %vector.body

vector.body:                                      ; preds = %vector.body, %vector.ph
  %index5 = phi i64 [ 0, %vector.ph ], [ %current.iteration.next, %vector.body ], !dbg !56
  %vec.phi = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 17, i32 0), %vector.ph ], [ %11, %vector.body ]
  %vec.phi6 = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 -7, i32 0), %vector.ph ], [ %12, %vector.body ]
  %vec.phi7 = phi double [ %start, %vector.ph ], [ %9, %vector.body ]
  %vec.phi8 = phi float [ %fstart, %vector.ph ], [ %10, %vector.body ]
  %avl = phi i64 [ %fission.completed, %vector.ph ], [ %avl.next, %vector.body ]
  %3 = call i32 @llvm.experimental.get.vector.length.i64(i64 %avl, i32 4, i1 true)
  %4 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %index5, !dbg !56
  %vp.op.load = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0(ptr align 4 %4, <vscale x 4 x i1> splat (i1 true), i32 %3), !dbg !56
  %5 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %index5, !dbg !56
  %vp.op.load9 = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0(ptr align 8 %5, <vscale x 4 x i1> splat (i1 true), i32 %3), !dbg !56
  %6 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %index5, !dbg !56
  %vp.op.load10 = call <vscale x 4 x float> @llvm.vp.load.nxv4f32.p0(ptr align 4 %6, <vscale x 4 x i1> splat (i1 true), i32 %3), !dbg !56
  %7 = add <vscale x 4 x i32> %vec.phi, %vp.op.load, !dbg !56
  %8 = add <vscale x 4 x i32> %vp.op.load, %vec.phi6, !dbg !56
  %9 = call double @llvm.vp.reduce.fadd.nxv4f64(double %vec.phi7, <vscale x 4 x double> %vp.op.load9, <vscale x 4 x i1> splat (i1 true), i32 %3)
  %10 = call float @llvm.vp.reduce.fadd.nxv4f32(float %vec.phi8, <vscale x 4 x float> %vp.op.load10, <vscale x 4 x i1> splat (i1 true), i32 %3)
  %11 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %7, <vscale x 4 x i32> %vec.phi, i32 %3)
  %12 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %8, <vscale x 4 x i32> %vec.phi6, i32 %3)
  %13 = zext i32 %3 to i64, !dbg !56
  %current.iteration.next = add i64 %13, %index5, !dbg !56
  %avl.next = sub nuw i64 %avl, %13
  %14 = icmp eq i64 %avl.next, 0
  br i1 %14, label %middle.block, label %vector.body, !dbg !56, !llvm.loop !58

middle.block:                                     ; preds = %vector.body
  %15 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %11), !dbg !56
  %16 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %12), !dbg !56
  br label %exit.loopexit, !dbg !56

exit.loopexit:                                    ; preds = %middle.block
  br label %exit

exit:                                             ; preds = %exit.loopexit, %entry
  %v0 = phi i32 [ 17, %entry ], [ %15, %exit.loopexit ]
  %v1 = phi i32 [ -7, %entry ], [ %16, %exit.loopexit ]
  %vd = phi double [ %start, %entry ], [ %9, %exit.loopexit ]
  %vf = phi float [ %fstart, %entry ], [ %10, %exit.loopexit ]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out, align 4
  store i32 %v1, ptr %o1, align 4
  store double %vd, ptr %dout, align 8
  store float %vf, ptr %fout, align 4
  ret void
}

define void @affine_down_early(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) #1 !dbg !59 {
entry:
  %scalar.fission.scratch = alloca [65 x i32], align 4
  %scalar.fission.scratch1 = alloca [65 x double], align 8
  %scalar.fission.scratch2 = alloca [65 x float], align 4
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit

preheader:                                        ; preds = %entry
  %span = mul i64 %n, 3
  %limit = sub i64 %begin, %span
  br label %loop, !dbg !60

loop:                                             ; preds = %latch, %preheader
  %fission.ordinal = phi i64 [ 0, %preheader ], [ %fission.completed, %latch ]
  %iv = phi i64 [ %begin, %preheader ], [ %next, %latch ]
  %distance = sub i64 %begin, %iv
  %index = udiv i64 %distance, 3
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !60

left:                                             ; preds = %loop
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge

right:                                            ; preds = %loop
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.000000e+00
  br label %first.merge

first.merge:                                      ; preds = %right, %left
  %first.c = phi i32 [ %lc, %left ], [ 17, %right ]
  %first.d = phi double [ %ld, %left ], [ %rc, %right ]
  %parity = and i64 %index, 1
  %second = icmp ne i64 %parity, 0
  br i1 %second, label %positive, label %negative

positive:                                         ; preds = %first.merge
  %pc = add i32 %first.c, 23
  %pd = fmul double %first.d, 5.000000e-01
  br label %latch

negative:                                         ; preds = %first.merge
  %nc = sub i32 %first.c, 9
  %nd = fmul double %first.d, -1.000000e+00
  br label %latch

latch:                                            ; preds = %negative, %positive
  %c = phi i32 [ %pc, %positive ], [ %nc, %negative ]
  %dc = phi double [ %pd, %positive ], [ %nd, %negative ]
  %fc = fptrunc double %dc to float
  %next = sub i64 %iv, 3
  %done = icmp ugt i64 %next, %limit
  %fission.completed = add i64 %fission.ordinal, 1, !dbg !60
  %0 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %fission.ordinal, !dbg !60
  store i32 %c, ptr %0, align 4, !dbg !60
  %1 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %fission.ordinal, !dbg !60
  store double %dc, ptr %1, align 8, !dbg !60
  %2 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %fission.ordinal, !dbg !60
  store float %fc, ptr %2, align 4, !dbg !60
  br i1 %done, label %loop, label %scalar.fission.consumer.ph, !dbg !60, !llvm.loop !61

scalar.fission.consumer.ph:                       ; preds = %latch
  %fission.completed.count = phi i64 [ %fission.completed, %latch ]
  br label %vector.ph

vector.ph:                                        ; preds = %scalar.fission.consumer.ph
  br label %vector.body

vector.body:                                      ; preds = %vector.body, %vector.ph
  %index5 = phi i64 [ 0, %vector.ph ], [ %current.iteration.next, %vector.body ], !dbg !60
  %vec.phi = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 17, i32 0), %vector.ph ], [ %11, %vector.body ]
  %vec.phi6 = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 -7, i32 0), %vector.ph ], [ %12, %vector.body ]
  %vec.phi7 = phi double [ %start, %vector.ph ], [ %9, %vector.body ]
  %vec.phi8 = phi float [ %fstart, %vector.ph ], [ %10, %vector.body ]
  %avl = phi i64 [ %fission.completed, %vector.ph ], [ %avl.next, %vector.body ]
  %3 = call i32 @llvm.experimental.get.vector.length.i64(i64 %avl, i32 4, i1 true)
  %4 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %index5, !dbg !60
  %vp.op.load = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0(ptr align 4 %4, <vscale x 4 x i1> splat (i1 true), i32 %3), !dbg !60
  %5 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %index5, !dbg !60
  %vp.op.load9 = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0(ptr align 8 %5, <vscale x 4 x i1> splat (i1 true), i32 %3), !dbg !60
  %6 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %index5, !dbg !60
  %vp.op.load10 = call <vscale x 4 x float> @llvm.vp.load.nxv4f32.p0(ptr align 4 %6, <vscale x 4 x i1> splat (i1 true), i32 %3), !dbg !60
  %7 = add <vscale x 4 x i32> %vec.phi, %vp.op.load, !dbg !60
  %8 = add <vscale x 4 x i32> %vp.op.load, %vec.phi6, !dbg !60
  %9 = call double @llvm.vp.reduce.fadd.nxv4f64(double %vec.phi7, <vscale x 4 x double> %vp.op.load9, <vscale x 4 x i1> splat (i1 true), i32 %3)
  %10 = call float @llvm.vp.reduce.fadd.nxv4f32(float %vec.phi8, <vscale x 4 x float> %vp.op.load10, <vscale x 4 x i1> splat (i1 true), i32 %3)
  %11 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %7, <vscale x 4 x i32> %vec.phi, i32 %3)
  %12 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %8, <vscale x 4 x i32> %vec.phi6, i32 %3)
  %13 = zext i32 %3 to i64, !dbg !60
  %current.iteration.next = add i64 %13, %index5, !dbg !60
  %avl.next = sub nuw i64 %avl, %13
  %14 = icmp eq i64 %avl.next, 0
  br i1 %14, label %middle.block, label %vector.body, !dbg !60, !llvm.loop !62

middle.block:                                     ; preds = %vector.body
  %15 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %11), !dbg !60
  %16 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %12), !dbg !60
  br label %exit.loopexit, !dbg !60

exit.loopexit:                                    ; preds = %middle.block
  br label %exit

exit:                                             ; preds = %exit.loopexit, %entry
  %v0 = phi i32 [ 17, %entry ], [ %15, %exit.loopexit ]
  %v1 = phi i32 [ -7, %entry ], [ %16, %exit.loopexit ]
  %vd = phi double [ %start, %entry ], [ %9, %exit.loopexit ]
  %vf = phi float [ %fstart, %entry ], [ %10, %exit.loopexit ]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out, align 4
  store i32 %v1, ptr %o1, align 4
  store double %vd, ptr %dout, align 8
  store float %vf, ptr %fout, align 4
  ret void
}

define void @affine_signed_down_early(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) #1 !dbg !63 {
entry:
  %scalar.fission.scratch = alloca [65 x i32], align 4
  %scalar.fission.scratch1 = alloca [65 x double], align 8
  %scalar.fission.scratch2 = alloca [65 x float], align 4
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit

preheader:                                        ; preds = %entry
  %span = mul i64 %n, 3
  %limit = sub i64 %begin, %span
  br label %loop, !dbg !64

loop:                                             ; preds = %latch, %preheader
  %fission.ordinal = phi i64 [ 0, %preheader ], [ %fission.completed, %latch ]
  %iv = phi i64 [ %begin, %preheader ], [ %next, %latch ]
  %distance = sub i64 %begin, %iv
  %index = udiv i64 %distance, 3
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !64

left:                                             ; preds = %loop
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge

right:                                            ; preds = %loop
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.000000e+00
  br label %first.merge

first.merge:                                      ; preds = %right, %left
  %first.c = phi i32 [ %lc, %left ], [ 17, %right ]
  %first.d = phi double [ %ld, %left ], [ %rc, %right ]
  %parity = and i64 %index, 1
  %second = icmp ne i64 %parity, 0
  br i1 %second, label %positive, label %negative

positive:                                         ; preds = %first.merge
  %pc = add i32 %first.c, 23
  %pd = fmul double %first.d, 5.000000e-01
  br label %latch

negative:                                         ; preds = %first.merge
  %nc = sub i32 %first.c, 9
  %nd = fmul double %first.d, -1.000000e+00
  br label %latch

latch:                                            ; preds = %negative, %positive
  %c = phi i32 [ %pc, %positive ], [ %nc, %negative ]
  %dc = phi double [ %pd, %positive ], [ %nd, %negative ]
  %fc = fptrunc double %dc to float
  %next = sub i64 %iv, 3
  %done = icmp sgt i64 %next, %limit
  %fission.completed = add i64 %fission.ordinal, 1, !dbg !64
  %0 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %fission.ordinal, !dbg !64
  store i32 %c, ptr %0, align 4, !dbg !64
  %1 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %fission.ordinal, !dbg !64
  store double %dc, ptr %1, align 8, !dbg !64
  %2 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %fission.ordinal, !dbg !64
  store float %fc, ptr %2, align 4, !dbg !64
  br i1 %done, label %loop, label %scalar.fission.consumer.ph, !dbg !64, !llvm.loop !65

scalar.fission.consumer.ph:                       ; preds = %latch
  %fission.completed.count = phi i64 [ %fission.completed, %latch ]
  br label %vector.ph

vector.ph:                                        ; preds = %scalar.fission.consumer.ph
  br label %vector.body

vector.body:                                      ; preds = %vector.body, %vector.ph
  %index5 = phi i64 [ 0, %vector.ph ], [ %current.iteration.next, %vector.body ], !dbg !64
  %vec.phi = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 17, i32 0), %vector.ph ], [ %11, %vector.body ]
  %vec.phi6 = phi <vscale x 4 x i32> [ insertelement (<vscale x 4 x i32> zeroinitializer, i32 -7, i32 0), %vector.ph ], [ %12, %vector.body ]
  %vec.phi7 = phi double [ %start, %vector.ph ], [ %9, %vector.body ]
  %vec.phi8 = phi float [ %fstart, %vector.ph ], [ %10, %vector.body ]
  %avl = phi i64 [ %fission.completed, %vector.ph ], [ %avl.next, %vector.body ]
  %3 = call i32 @llvm.experimental.get.vector.length.i64(i64 %avl, i32 4, i1 true)
  %4 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %index5, !dbg !64
  %vp.op.load = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0(ptr align 4 %4, <vscale x 4 x i1> splat (i1 true), i32 %3), !dbg !64
  %5 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %index5, !dbg !64
  %vp.op.load9 = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0(ptr align 8 %5, <vscale x 4 x i1> splat (i1 true), i32 %3), !dbg !64
  %6 = getelementptr inbounds [65 x float], ptr %scalar.fission.scratch2, i32 0, i64 %index5, !dbg !64
  %vp.op.load10 = call <vscale x 4 x float> @llvm.vp.load.nxv4f32.p0(ptr align 4 %6, <vscale x 4 x i1> splat (i1 true), i32 %3), !dbg !64
  %7 = add <vscale x 4 x i32> %vec.phi, %vp.op.load, !dbg !64
  %8 = add <vscale x 4 x i32> %vp.op.load, %vec.phi6, !dbg !64
  %9 = call double @llvm.vp.reduce.fadd.nxv4f64(double %vec.phi7, <vscale x 4 x double> %vp.op.load9, <vscale x 4 x i1> splat (i1 true), i32 %3)
  %10 = call float @llvm.vp.reduce.fadd.nxv4f32(float %vec.phi8, <vscale x 4 x float> %vp.op.load10, <vscale x 4 x i1> splat (i1 true), i32 %3)
  %11 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %7, <vscale x 4 x i32> %vec.phi, i32 %3)
  %12 = call <vscale x 4 x i32> @llvm.vp.merge.nxv4i32(<vscale x 4 x i1> splat (i1 true), <vscale x 4 x i32> %8, <vscale x 4 x i32> %vec.phi6, i32 %3)
  %13 = zext i32 %3 to i64, !dbg !64
  %current.iteration.next = add i64 %13, %index5, !dbg !64
  %avl.next = sub nuw i64 %avl, %13
  %14 = icmp eq i64 %avl.next, 0
  br i1 %14, label %middle.block, label %vector.body, !dbg !64, !llvm.loop !66

middle.block:                                     ; preds = %vector.body
  %15 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %11), !dbg !64
  %16 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %12), !dbg !64
  br label %exit.loopexit, !dbg !64

exit.loopexit:                                    ; preds = %middle.block
  br label %exit

exit:                                             ; preds = %exit.loopexit, %entry
  %v0 = phi i32 [ 17, %entry ], [ %15, %exit.loopexit ]
  %v1 = phi i32 [ -7, %entry ], [ %16, %exit.loopexit ]
  %vd = phi double [ %start, %entry ], [ %9, %exit.loopexit ]
  %vf = phi float [ %fstart, %entry ], [ %10, %exit.loopexit ]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out, align 4
  store i32 %v1, ptr %o1, align 4
  store double %vd, ptr %dout, align 8
  store float %vf, ptr %fout, align 4
  ret void
}
