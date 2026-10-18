; Parser fixtures from immutable t000016 output (253d69a79).
; compact_nested is the failing repeated-LV scalar-remainder output;
; compact_integer is the analogous direct scalar-remainder exit.
; Only debug/loop metadata and predecessor comments are omitted. These
; snapshots supplement the actual transformed/reference executable matrix;
; this file is read as text by reduction-fission-execution-checker.test.

define void @compact_nested(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout, i64 %rows, i64 %n, double %start) {
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

outer.ph:
  br label %outer

outer:
  %row = phi i64 [ 0, %outer.ph ], [ %row.next, %row.exit ]
  %carry = phi i32 [ 19, %outer.ph ], [ %row.sum, %row.exit ]
  %dcarry = phi double [ %start, %outer.ph ], [ %row.dsum, %row.exit ]
  %offset = mul nuw i64 %row, 65
  %base = getelementptr i32, ptr %a, i64 %offset
  %dbase = getelementptr double, ptr %fp, i64 %offset
  %salt = trunc i64 %row to i32
  br label %inner.ph

inner.ph:
  br label %inner

inner:
  %fission.participating = phi i64 [ 0, %inner.ph ], [ %fission.participating.merge, %latch ]
  %iv = phi i64 [ 0, %inner.ph ], [ %next, %latch ]
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %salted = xor i32 %x, %salt
  %bit = and i32 %x, 1
  %choose = icmp ne i32 %bit, 0
  br i1 %choose, label %left, label %right

left:
  %lc = call i32 @scalar_helper(i32 %salted)
  %dp = getelementptr double, ptr %dbase, i64 %iv
  %dx = load double, ptr %dp, align 8
  %ld = fmul double %dx, 3.000000e+00
  %fission.participating.next = add nuw i64 %fission.participating, 1
  %0 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %fission.participating
  store i32 %lc, ptr %0, align 4
  %1 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %fission.participating
  store double %ld, ptr %1, align 8
  br label %latch

right:
  %unused = xor i32 %x, 7
  br label %latch

latch:
  %fission.participating.merge = phi i64 [ %fission.participating, %right ], [ %fission.participating.next, %left ]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %scalar.fission.consumer.guard, label %inner

scalar.fission.consumer.guard:
  %fission.participating.merge.lcssa = phi i64 [ %fission.participating.merge, %latch ]
  %fission.participating.count = phi i64 [ %fission.participating.merge, %latch ]
  %fission.empty = icmp eq i64 %fission.participating.count, 0
  br i1 %fission.empty, label %scalar.fission.consumer.exit, label %scalar.fission.consumer.ph

scalar.fission.consumer.ph:
  %2 = call i64 @llvm.vscale.i64()
  %3 = shl nuw i64 %2, 2
  %min.iters.check = icmp ult i64 %fission.participating.merge.lcssa, %3
  br i1 %min.iters.check, label %scalar.ph, label %vector.ph

vector.ph:
  %4 = shl nuw i64 %2, 2
  %n.mod.vf = urem i64 %fission.participating.merge.lcssa, %4
  %n.vec = sub i64 %fission.participating.merge.lcssa, %n.mod.vf
  %5 = insertelement <vscale x 4 x i32> zeroinitializer, i32 %carry, i32 0
  br label %vector.body

vector.body:
  %index = phi i64 [ 0, %vector.ph ], [ %index.next, %vector.body ]
  %vec.phi = phi <vscale x 4 x i32> [ %5, %vector.ph ], [ %8, %vector.body ]
  %vec.phi3 = phi double [ %dcarry, %vector.ph ], [ %9, %vector.body ]
  %6 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %index
  %wide.load = load <vscale x 4 x i32>, ptr %6, align 4
  %7 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %index
  %wide.load4 = load <vscale x 4 x double>, ptr %7, align 8
  %8 = add <vscale x 4 x i32> %vec.phi, %wide.load
  %9 = call double @llvm.vector.reduce.fadd.nxv4f64(double %vec.phi3, <vscale x 4 x double> %wide.load4)
  %index.next = add nuw i64 %index, %4
  %10 = icmp eq i64 %index.next, %n.vec
  br i1 %10, label %middle.block, label %vector.body

middle.block:
  %.lcssa6 = phi <vscale x 4 x i32> [ %8, %vector.body ]
  %.lcssa = phi double [ %9, %vector.body ]
  %11 = call i32 @llvm.vector.reduce.add.nxv4i32(<vscale x 4 x i32> %.lcssa6)
  %cmp.n = icmp eq i64 %fission.participating.merge.lcssa, %n.vec
  br i1 %cmp.n, label %scalar.fission.consumer.loopexit, label %scalar.ph

scalar.ph:
  %bc.resume.val = phi i64 [ %n.vec, %middle.block ], [ 0, %scalar.fission.consumer.ph ]
  %bc.merge.rdx = phi i32 [ %11, %middle.block ], [ %carry, %scalar.fission.consumer.ph ]
  %bc.merge.rdx5 = phi double [ %.lcssa, %middle.block ], [ %dcarry, %scalar.fission.consumer.ph ]
  br label %scalar.fission.consumer.body

scalar.fission.consumer.body:
  %fission.consumer.iv = phi i64 [ %bc.resume.val, %scalar.ph ], [ %fission.consumer.next, %scalar.fission.consumer.body ]
  %sum.consume = phi i32 [ %bc.merge.rdx, %scalar.ph ], [ %update.consume, %scalar.fission.consumer.body ]
  %dsum.consume = phi double [ %bc.merge.rdx5, %scalar.ph ], [ %dupdate.consume, %scalar.fission.consumer.body ]
  %12 = getelementptr inbounds [65 x i32], ptr %scalar.fission.scratch, i32 0, i64 %fission.consumer.iv
  %fission.contribution = load i32, ptr %12, align 4
  %13 = getelementptr inbounds [65 x double], ptr %scalar.fission.scratch1, i32 0, i64 %fission.consumer.iv
  %fission.contribution2 = load double, ptr %13, align 8
  %update.consume = add i32 %sum.consume, %fission.contribution
  %dupdate.consume = fadd double %dsum.consume, %fission.contribution2
  %fission.consumer.next = add nuw i64 %fission.consumer.iv, 1
  %fission.consumer.more = icmp ne i64 %fission.consumer.next, %fission.participating.count
  br i1 %fission.consumer.more, label %scalar.fission.consumer.body, label %scalar.fission.consumer.loopexit.loopexit

scalar.fission.consumer.loopexit.loopexit:
  %update.consume.lcssa = phi i32 [ %update.consume, %scalar.fission.consumer.body ]
  %dupdate.consume.lcssa = phi double [ %dupdate.consume, %scalar.fission.consumer.body ]
  br label %scalar.fission.consumer.loopexit

scalar.fission.consumer.loopexit:
  %sum.lcssa = phi i32 [ %11, %middle.block ], [ %update.consume.lcssa, %scalar.fission.consumer.loopexit.loopexit ]
  %dsum.lcssa = phi double [ %.lcssa, %middle.block ], [ %dupdate.consume.lcssa, %scalar.fission.consumer.loopexit.loopexit ]
  br label %scalar.fission.consumer.exit

scalar.fission.consumer.exit:
  %sum.result = phi i32 [ %carry, %scalar.fission.consumer.guard ], [ %sum.lcssa, %scalar.fission.consumer.loopexit ]
  %dsum.result = phi double [ %dcarry, %scalar.fission.consumer.guard ], [ %dsum.lcssa, %scalar.fission.consumer.loopexit ]
  br label %row.exit

row.exit:
  %row.sum = phi i32 [ %sum.result, %scalar.fission.consumer.exit ]
  %row.dsum = phi double [ %dsum.result, %scalar.fission.consumer.exit ]
  %dst = getelementptr i32, ptr %out, i64 %row
  %ddst = getelementptr double, ptr %dout, i64 %row
  store i32 %row.sum, ptr %dst, align 4
  store double %row.dsum, ptr %ddst, align 8
  %row.next = add nuw i64 %row, 1
  %rows.done = icmp eq i64 %row.next, %rows
  br i1 %rows.done, label %exit.loopexit, label %outer

exit.loopexit:
  br label %exit

exit:
  ret void
}

define void @compact_integer(ptr readonly %a, ptr %out, i64 %n, i32 %start) {
entry:
  %scalar.fission.scratch = alloca [65 x i64], align 8
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %initial = zext i32 %start to i64
  br i1 %enter, label %preheader, label %exit

preheader:
  br label %loop

loop:
  %fission.participating = phi i64 [ 0, %preheader ], [ %fission.participating.merge, %latch ]
  %iv = phi i64 [ 0, %preheader ], [ %next, %latch ]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp eq i32 %x, 0
  br i1 %choose, label %latch, label %left

left:
  %wide = zext i32 %x to i64
  %c = mul nuw nsw i64 %wide, 13
  %fission.participating.next = add nuw i64 %fission.participating, 1
  %0 = getelementptr inbounds [65 x i64], ptr %scalar.fission.scratch, i32 0, i64 %fission.participating
  store i64 %c, ptr %0, align 8
  br label %latch

latch:
  %fission.participating.merge = phi i64 [ %fission.participating.next, %left ], [ %fission.participating, %loop ]
  %next = add nuw i64 %iv, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %scalar.fission.consumer.guard

scalar.fission.consumer.guard:
  %fission.participating.count = phi i64 [ %fission.participating.merge, %latch ]
  %fission.empty = icmp eq i64 %fission.participating.count, 0
  br i1 %fission.empty, label %scalar.fission.consumer.exit, label %scalar.fission.consumer.ph

scalar.fission.consumer.ph:
  %1 = call i64 @llvm.vscale.i64()
  %2 = shl nuw i64 %1, 2
  %min.iters.check = icmp ult i64 %fission.participating.merge, %2
  br i1 %min.iters.check, label %scalar.ph, label %vector.ph

vector.ph:
  %3 = shl nuw i64 %1, 2
  %n.mod.vf = urem i64 %fission.participating.merge, %3
  %n.vec = sub i64 %fission.participating.merge, %n.mod.vf
  %4 = insertelement <vscale x 4 x i64> zeroinitializer, i64 %initial, i32 0
  br label %vector.body

vector.body:
  %index = phi i64 [ 0, %vector.ph ], [ %index.next, %vector.body ]
  %vec.phi = phi <vscale x 4 x i64> [ %4, %vector.ph ], [ %6, %vector.body ]
  %vec.phi1 = phi <vscale x 4 x i64> [ zeroinitializer, %vector.ph ], [ %7, %vector.body ]
  %5 = getelementptr inbounds [65 x i64], ptr %scalar.fission.scratch, i32 0, i64 %index
  %wide.load = load <vscale x 4 x i64>, ptr %5, align 8
  %6 = add <vscale x 4 x i64> %wide.load, %vec.phi
  %7 = add <vscale x 4 x i64> %vec.phi1, %wide.load
  %index.next = add nuw i64 %index, %3
  %8 = icmp eq i64 %index.next, %n.vec
  br i1 %8, label %middle.block, label %vector.body

middle.block:
  %9 = call i64 @llvm.vector.reduce.add.nxv4i64(<vscale x 4 x i64> %6)
  %10 = call i64 @llvm.vector.reduce.add.nxv4i64(<vscale x 4 x i64> %7)
  %cmp.n = icmp eq i64 %fission.participating.merge, %n.vec
  br i1 %cmp.n, label %scalar.fission.consumer.loopexit, label %scalar.ph

scalar.ph:
  %bc.resume.val = phi i64 [ %n.vec, %middle.block ], [ 0, %scalar.fission.consumer.ph ]
  %bc.merge.rdx = phi i64 [ %9, %middle.block ], [ %initial, %scalar.fission.consumer.ph ]
  %bc.merge.rdx2 = phi i64 [ %10, %middle.block ], [ 0, %scalar.fission.consumer.ph ]
  br label %scalar.fission.consumer.body

scalar.fission.consumer.body:
  %fission.consumer.iv = phi i64 [ %bc.resume.val, %scalar.ph ], [ %fission.consumer.next, %scalar.fission.consumer.body ]
  %sum.consume = phi i64 [ %bc.merge.rdx, %scalar.ph ], [ %u.consume, %scalar.fission.consumer.body ]
  %sum2.consume = phi i64 [ %bc.merge.rdx2, %scalar.ph ], [ %u2.consume, %scalar.fission.consumer.body ]
  %11 = getelementptr inbounds [65 x i64], ptr %scalar.fission.scratch, i32 0, i64 %fission.consumer.iv
  %fission.contribution = load i64, ptr %11, align 8
  %u.consume = add nuw nsw i64 %fission.contribution, %sum.consume
  %u2.consume = add nuw nsw i64 %sum2.consume, %fission.contribution
  %fission.consumer.next = add nuw i64 %fission.consumer.iv, 1
  %fission.consumer.more = icmp ne i64 %fission.consumer.next, %fission.participating.count
  br i1 %fission.consumer.more, label %scalar.fission.consumer.body, label %scalar.fission.consumer.loopexit

scalar.fission.consumer.loopexit:
  %sum.lcssa = phi i64 [ %u.consume, %scalar.fission.consumer.body ], [ %9, %middle.block ]
  %sum2.lcssa = phi i64 [ %u2.consume, %scalar.fission.consumer.body ], [ %10, %middle.block ]
  br label %scalar.fission.consumer.exit

scalar.fission.consumer.exit:
  %sum.result = phi i64 [ %initial, %scalar.fission.consumer.guard ], [ %sum.lcssa, %scalar.fission.consumer.loopexit ]
  %sum2.result = phi i64 [ 0, %scalar.fission.consumer.guard ], [ %sum2.lcssa, %scalar.fission.consumer.loopexit ]
  br label %exit.loopexit

exit.loopexit:
  %m.lcssa = phi i64 [ %sum.result, %scalar.fission.consumer.exit ]
  %m2.lcssa = phi i64 [ %sum2.result, %scalar.fission.consumer.exit ]
  br label %exit

exit:
  %result = phi i64 [ %initial, %entry ], [ %m.lcssa, %exit.loopexit ]
  %result2 = phi i64 [ 0, %entry ], [ %m2.lcssa, %exit.loopexit ]
  %combined = add i64 %result, %result2
  store i64 %combined, ptr %out, align 8
  ret void
}
