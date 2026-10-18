; RUN: opt -passes='loop-simplify,lcssa,print<scalar-evolution>' -disable-output \
; RUN:   -mtriple=riscv64 -mattr=+v %s 2> %t.scev
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -force-vector-width=4 \
; RUN:   -scalable-vectorization=always -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -pass-remarks=vplan-reduction-fission \
; RUN:   -pass-remarks-missed=vplan-reduction-fission -pass-remarks-analysis=vplan-reduction-fission \
; RUN:   -S %s -o %t 2> %t.remarks
; RUN: FileCheck %s --check-prefix=EVL < %t
; RUN: FileCheck %s --check-prefix=REMARK < %t.remarks
; RUN: FileCheck %s --check-prefix=BOUND < %t.remarks
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
; RUN:   -vplan-reduction-fission-min-reductions=1000000 \
; RUN:   -vplan-reduction-fission-min-chain-depth=1000000 \
; RUN:   -vplan-reduction-fission-min-pressure-percent=1000000 \
; RUN:   -S %s | FileCheck %s --check-prefix=SCALAR
;
; Nonzero and strided integer controls. Retain the original producer's integer
; operations (allowing removal of poison-generating nowrap flags), predicate,
; operand order, branch polarity and entry guard. Scratch uses a
; private ordinal; the consumer counts completed contributions. Runtime starts
; are independent of n and bounded by visible IR, never fixture knowledge.
; The compact triangle retains its separate participation proof and P=0 bypass.
; No new FP assumptions. Actual transformed-path execution checks original IR,
; independent C formulas, and exact producer/control and vector/tail visits
; after one and two ordinary vectorizer invocations.

declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

; REMARK: scalar-affine.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044
; REMARK: scalar-affine.c:12:3: scalar-IR fission producer VF 1
; REMARK: scalar-affine.c:12:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-LABEL: define void @affine_const(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR: alloca [65 x float]
; SCALAR-NOT: alloca
; SCALAR: %fission.ordinal = phi i64 [ 0, %preheader ]
; SCALAR: %iv = phi i64 [ 7, %preheader ]
; SCALAR: %next = add nuw nsw i64 %iv, 1
; SCALAR: %done = icmp eq i64 %limit, %next
; SCALAR: %fission.completed.count = phi i64 [ %fission.completed, %latch ]
; SCALAR: scalar.fission.consumer.body:
; SCALAR: %fission.consumer.next = add nuw i64 %fission.consumer.iv, 1
; SCALAR: %fission.consumer.more = icmp ne i64 %fission.consumer.next, %fission.
; SCALAR: ret void
; EVL-LABEL: define void @affine_const(
; EVL: %next = add nuw nsw i64 %iv, 1
; EVL: %done = icmp eq i64 %limit, %next
; EVL: scalar.fission.consumer.ph:
; EVL: vector.body:
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64
; EVL: call i32 @llvm.vector.reduce.add.nxv4i32
; EVL: ret void
; TAIL-LABEL: define void @affine_const(
; TAIL: %next = add nuw nsw i64 %iv, 1
; TAIL: %done = icmp eq i64 %limit, %next
; TAIL: scalar.fission.consumer.ph:
; TAIL: vector.body:
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64
; TAIL: call i32 @llvm.vector.reduce.add.nxv4i32
; TAIL: ret void
define void @affine_const(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) !dbg !6 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  %limit = add nuw nsw i64 %n, 7
  br label %loop, !dbg !7
loop:
  %iv = phi i64 [7, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %index = sub nuw nsw i64 %iv, 7
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !7
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge
right:
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  br label %first.merge
first.merge:
  %first.c = phi i32 [%lc, %left], [17, %right]
  %first.d = phi double [%ld, %left], [%rc, %right]
  %parity = and i64 %index, 1
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
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %limit, %next
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

; REMARK: scalar-affine.c:22:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044
; REMARK: scalar-affine.c:22:3: scalar-IR fission producer VF 1
; REMARK: scalar-affine.c:22:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-LABEL: define void @affine_runtime(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR: alloca [65 x float]
; SCALAR-NOT: alloca
; SCALAR: %fission.ordinal = phi i64 [ 0, %preheader ]
; SCALAR: %iv = phi i64 [ %origin, %preheader ]
; SCALAR: %next = add nuw nsw i64 %iv, 2
; SCALAR: %done = icmp ne i64 %next, %limit
; SCALAR: %fission.completed.count = phi i64 [ %fission.completed, %latch ]
; SCALAR: scalar.fission.consumer.body:
; SCALAR: %fission.consumer.next = add nuw i64 %fission.consumer.iv, 1
; SCALAR: %fission.consumer.more = icmp ne i64 %fission.consumer.next, %fission.
; SCALAR: ret void
; EVL-LABEL: define void @affine_runtime(
; EVL: %span = shl i64 %n, 1
; EVL: %next = add nuw nsw i64 %iv, 2
; EVL: %done = icmp ne i64 %next, %limit
; EVL: scalar.fission.consumer.ph:
; EVL: [[SPAN_MINUS_TWO:%.*]] = add i64 %span, -2
; EVL-NEXT: [[HALF:%.*]] = lshr i64 [[SPAN_MINUS_TWO]], 1
; EVL-NEXT: [[COUNT:%.*]] = add nuw i64 [[HALF]], 1
; EVL: vector.body:
; EVL: %avl = phi i64 [ [[COUNT]], %vector.ph ]
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64
; EVL: call i32 @llvm.vector.reduce.add.nxv4i32
; EVL: ret void
; TAIL-LABEL: define void @affine_runtime(
; TAIL: %next = add nuw nsw i64 %iv, 2
; TAIL: %done = icmp ne i64 %next, %limit
; TAIL: scalar.fission.consumer.ph:
; TAIL: vector.body:
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64
; TAIL: call i32 @llvm.vector.reduce.add.nxv4i32
; TAIL: ret void
define void @affine_runtime(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) !dbg !8 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  %bits = and i64 %begin, 31
  %origin = add nuw nsw i64 %bits, 1
  %span = shl nuw nsw i64 %n, 1
  %limit = add nuw nsw i64 %origin, %span
  br label %loop, !dbg !9
loop:
  %iv = phi i64 [%origin, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %distance = sub nuw nsw i64 %iv, %origin
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !9
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge
right:
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  br label %first.merge
first.merge:
  %first.c = phi i32 [%lc, %left], [17, %right]
  %first.d = phi double [%ld, %left], [%rc, %right]
  %parity = and i64 %index, 1
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
  %next = add nuw nsw i64 %iv, 2
  %done = icmp ne i64 %next, %limit
  br i1 %done, label %loop, label %exit, !dbg !9
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

; BOUND: scalar-affine.c:32:3: scalar-IR admission passed; control {{.*}}; exact backedges {{.*}}; constant maximum {{.*}}; guarded exact {{.*}}; ordinary count proof {{.*}}; ordinary admission {{non-constant-trip-count|trip-count-overflow|scalar-scratch-limit}}; equality witness {{.*}}; guarded witness {{.*}}; witness backedge bound 64
; REMARK: scalar-affine.c:32:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044
; REMARK: scalar-affine.c:32:3: scalar-IR fission producer VF 1
; REMARK: scalar-affine.c:32:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-LABEL: define void @affine_unsigned(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR: alloca [65 x float]
; SCALAR-NOT: alloca
; SCALAR: %fission.ordinal = phi i64 [ 0, %preheader ]
; SCALAR: %iv = phi i64 [ 9, %preheader ]
; SCALAR: %next = add nuw nsw i64 %iv, 3
; SCALAR: %done = icmp ult i64 %next, %limit
; SCALAR: %fission.completed.count = phi i64 [ %fission.completed, %latch ]
; SCALAR: scalar.fission.consumer.body:
; SCALAR: %fission.consumer.next = add nuw i64 %fission.consumer.iv, 1
; SCALAR: %fission.consumer.more = icmp ne i64 %fission.consumer.next, %fission.
; SCALAR: ret void
; EVL-LABEL: define void @affine_unsigned(
; EVL: %next = add nuw nsw i64 %iv, 3
; EVL: %done = icmp ult i64 %next, %limit
; EVL: scalar.fission.consumer.ph:
; EVL: vector.body:
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64
; EVL: call i32 @llvm.vector.reduce.add.nxv4i32
; EVL: ret void
; TAIL-LABEL: define void @affine_unsigned(
; TAIL: %next = add nuw nsw i64 %iv, 3
; TAIL: %done = icmp ult i64 %next, %limit
; TAIL: scalar.fission.consumer.ph:
; TAIL: vector.body:
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64
; TAIL: call i32 @llvm.vector.reduce.add.nxv4i32
; TAIL: ret void
define void @affine_unsigned(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) !dbg !10 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  %span = mul nuw nsw i64 %n, 3
  %limit = add nuw nsw i64 %span, 9
  br label %loop, !dbg !11
loop:
  %iv = phi i64 [9, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %distance = sub nuw nsw i64 %iv, 9
  %index = udiv i64 %distance, 3
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !11
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge
right:
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  br label %first.merge
first.merge:
  %first.c = phi i32 [%lc, %left], [17, %right]
  %first.d = phi double [%ld, %left], [%rc, %right]
  %parity = and i64 %index, 1
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
  %next = add nuw nsw i64 %iv, 3
  %done = icmp ult i64 %next, %limit
  br i1 %done, label %loop, label %exit, !dbg !11
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

; BOUND: scalar-affine.c:42:3: scalar-IR admission passed; control {{.*}}; exact backedges {{.*}}; constant maximum {{.*}}; guarded exact {{.*}}; ordinary count proof {{.*}}; ordinary admission {{non-constant-trip-count|trip-count-overflow|scalar-scratch-limit}}; equality witness {{.*}}; guarded witness {{.*}}; witness backedge bound 64
; REMARK: scalar-affine.c:42:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044
; REMARK: scalar-affine.c:42:3: scalar-IR fission producer VF 1
; REMARK: scalar-affine.c:42:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-LABEL: define void @affine_signed(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR: alloca [65 x float]
; SCALAR-NOT: alloca
; SCALAR: %fission.ordinal = phi i64 [ 0, %preheader ]
; SCALAR: %iv = phi i64 [ %origin, %preheader ]
; SCALAR: %next = add nsw i64 %iv, 2
; SCALAR: %done = icmp sgt i64 %limit, %next
; SCALAR: %fission.completed.count = phi i64 [ %fission.completed, %latch ]
; SCALAR: scalar.fission.consumer.body:
; SCALAR: %fission.consumer.next = add nuw i64 %fission.consumer.iv, 1
; SCALAR: %fission.consumer.more = icmp ne i64 %fission.consumer.next, %fission.
; SCALAR: ret void
; EVL-LABEL: define void @affine_signed(
; EVL: %next = add nsw i64 %iv, 2
; EVL: %done = icmp sgt i64 %limit, %next
; EVL: scalar.fission.consumer.ph:
; EVL: vector.body:
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64
; EVL: call i32 @llvm.vector.reduce.add.nxv4i32
; EVL: ret void
; TAIL-LABEL: define void @affine_signed(
; TAIL: %next = add nsw i64 %iv, 2
; TAIL: %done = icmp sgt i64 %limit, %next
; TAIL: scalar.fission.consumer.ph:
; TAIL: vector.body:
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64
; TAIL: call i32 @llvm.vector.reduce.add.nxv4i32
; TAIL: ret void
define void @affine_signed(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) !dbg !12 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  %origin = or i64 %begin, -32
  %span = shl nuw nsw i64 %n, 1
  %limit = add nsw i64 %origin, %span
  br label %loop, !dbg !13
loop:
  %iv = phi i64 [%origin, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %distance = sub nsw i64 %iv, %origin
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !13
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge
right:
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  br label %first.merge
first.merge:
  %first.c = phi i32 [%lc, %left], [17, %right]
  %first.d = phi double [%ld, %left], [%rc, %right]
  %parity = and i64 %index, 1
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
  %next = add nsw i64 %iv, 2
  %done = icmp sgt i64 %limit, %next
  br i1 %done, label %loop, label %exit, !dbg !13
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

; BOUND: scalar-affine.c:52:3: scalar-IR admission passed; control {{.*}}; exact backedges {{.*}}; constant maximum {{.*}}; guarded exact {{.*}}; ordinary count proof {{.*}}; ordinary admission {{non-constant-trip-count|trip-count-overflow|scalar-scratch-limit}}; equality witness {{.*}}; guarded witness {{.*}}; witness backedge bound 64
; REMARK: scalar-affine.c:52:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044
; REMARK: scalar-affine.c:52:3: scalar-IR fission producer VF 1
; REMARK: scalar-affine.c:52:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-LABEL: define void @affine_down(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR: alloca [65 x float]
; SCALAR-NOT: alloca
; SCALAR: %fission.ordinal = phi i64 [ 0, %preheader ]
; SCALAR: %iv = phi i64 [ 201, %preheader ]
; SCALAR: %next = sub nuw nsw i64 %iv, 3
; SCALAR: %done = icmp ugt i64 %next, %limit
; SCALAR: %fission.completed.count = phi i64 [ %fission.completed, %latch ]
; SCALAR: scalar.fission.consumer.body:
; SCALAR: %fission.consumer.next = add nuw i64 %fission.consumer.iv, 1
; SCALAR: %fission.consumer.more = icmp ne i64 %fission.consumer.next, %fission.
; SCALAR: ret void
; EVL-LABEL: define void @affine_down(
; EVL: %next = sub nuw nsw i64 %iv, 3
; EVL: %done = icmp ugt i64 %next, %limit
; EVL: scalar.fission.consumer.ph:
; EVL: vector.body:
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64
; EVL: call i32 @llvm.vector.reduce.add.nxv4i32
; EVL: ret void
; TAIL-LABEL: define void @affine_down(
; TAIL: %next = sub nuw nsw i64 %iv, 3
; TAIL: %done = icmp ugt i64 %next, %limit
; TAIL: scalar.fission.consumer.ph:
; TAIL: vector.body:
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64
; TAIL: call i32 @llvm.vector.reduce.add.nxv4i32
; TAIL: ret void
define void @affine_down(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) !dbg !14 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  %span = mul nuw nsw i64 %n, 3
  %limit = sub nuw nsw i64 201, %span
  br label %loop, !dbg !15
loop:
  %iv = phi i64 [201, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %distance = sub nuw nsw i64 201, %iv
  %index = udiv i64 %distance, 3
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !15
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge
right:
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  br label %first.merge
first.merge:
  %first.c = phi i32 [%lc, %left], [17, %right]
  %first.d = phi double [%ld, %left], [%rc, %right]
  %parity = and i64 %index, 1
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
  %next = sub nuw nsw i64 %iv, 3
  %done = icmp ugt i64 %next, %limit
  br i1 %done, label %loop, label %exit, !dbg !15
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

; BOUND: scalar-affine.c:62:3: scalar-IR admission passed; control {{.*}}; exact backedges {{.*}}; constant maximum {{.*}}; guarded exact {{.*}}; ordinary count proof {{.*}}; ordinary admission {{non-constant-trip-count|trip-count-overflow|scalar-scratch-limit}}; equality witness {{.*}}; guarded witness {{.*}}; witness backedge bound 64
; REMARK: scalar-affine.c:62:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044
; REMARK: scalar-affine.c:62:3: scalar-IR fission producer VF 1
; REMARK: scalar-affine.c:62:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-LABEL: define void @affine_signed_down(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR: alloca [65 x float]
; SCALAR-NOT: alloca
; SCALAR: %fission.ordinal = phi i64 [ 0, %preheader ]
; SCALAR: %iv = phi i64 [ %origin, %preheader ]
; SCALAR: %next = add nsw i64 %iv, -2
; SCALAR: %done = icmp sge i64 %limit, %next
; SCALAR: %fission.completed.count = phi i64 [ %fission.completed, %latch ]
; SCALAR: scalar.fission.consumer.body:
; SCALAR: %fission.consumer.next = add nuw i64 %fission.consumer.iv, 1
; SCALAR: %fission.consumer.more = icmp ne i64 %fission.consumer.next, %fission.
; SCALAR: ret void
; EVL-LABEL: define void @affine_signed_down(
; EVL: %next = add nsw i64 %iv, -2
; EVL: %done = icmp sge i64 %limit, %next
; EVL: scalar.fission.consumer.ph:
; EVL: vector.body:
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64
; EVL: call i32 @llvm.vector.reduce.add.nxv4i32
; EVL: ret void
; TAIL-LABEL: define void @affine_signed_down(
; TAIL: %next = add nsw i64 %iv, -2
; TAIL: %done = icmp sge i64 %limit, %next
; TAIL: scalar.fission.consumer.ph:
; TAIL: vector.body:
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64
; TAIL: call i32 @llvm.vector.reduce.add.nxv4i32
; TAIL: ret void
define void @affine_signed_down(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) !dbg !16 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  %bits = and i64 %begin, 31
  %origin = sub nsw i64 %bits, 17
  %span = shl nuw nsw i64 %n, 1
  %limit = sub nsw i64 %origin, %span
  br label %loop, !dbg !17
loop:
  %iv = phi i64 [%origin, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %distance = sub nsw i64 %origin, %iv
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !17
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
  %dp = getelementptr double, ptr %fp, i64 %index
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
  %next = add nsw i64 %iv, -2
  %done = icmp sge i64 %limit, %next
  br i1 %done, label %exit, label %loop, !dbg !17
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

; REMARK: scalar-affine.c:72:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044
; REMARK: scalar-affine.c:72:3: scalar-IR fission producer VF 1
; REMARK: scalar-affine.c:72:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-LABEL: define void @affine_compact(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR: alloca [65 x float]
; SCALAR-NOT: alloca
; SCALAR: %fission.participating = phi i64 [ 0, %preheader ]
; SCALAR: %iv = phi i64 [ 137, %preheader ]
; SCALAR: %next = sub nuw nsw i64 %iv, 2
; SCALAR: %done = icmp eq i64 %limit, %next
; SCALAR: %fission.empty = icmp eq i64 %fission.participating.count, 0
; SCALAR: scalar.fission.consumer.body:
; SCALAR: %fission.consumer.next = add nuw i64 %fission.consumer.iv, 1
; SCALAR: %fission.consumer.more = icmp ne i64 %fission.consumer.next, %fission.
; SCALAR: ret void
; EVL-LABEL: define void @affine_compact(
; EVL: %next = sub nuw nsw i64 %iv, 2
; EVL: %done = icmp eq i64 %limit, %next
; EVL: scalar.fission.consumer.ph:
; EVL: vector.body:
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64
; EVL: call i32 @llvm.vector.reduce.add.nxv4i32
; EVL: ret void
; TAIL-LABEL: define void @affine_compact(
; TAIL: %next = sub nuw nsw i64 %iv, 2
; TAIL: %done = icmp eq i64 %limit, %next
; TAIL: scalar.fission.consumer.ph:
; TAIL: vector.body:
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64
; TAIL: call i32 @llvm.vector.reduce.add.nxv4i32
; TAIL: ret void
define void @affine_compact(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) !dbg !18 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  %span = shl nuw nsw i64 %n, 1
  %limit = sub nuw nsw i64 137, %span
  br label %loop, !dbg !19
loop:
  %iv = phi i64 [137, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %rf = phi float [%fstart, %preheader], [%mf, %latch]
  %distance = sub nuw nsw i64 137, %iv
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch, !dbg !19
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %dp = getelementptr double, ptr %fp, i64 %index
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
  %next = sub nuw nsw i64 %iv, 2
  %done = icmp eq i64 %limit, %next
  br i1 %done, label %exit, label %loop, !dbg !19
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

; BOUND: scalar-affine.c:82:3: scalar-IR admission passed; control {{.*}}; exact backedges {{.*}}; constant maximum {{.*}}; guarded exact {{.*}}; ordinary count proof {{.*}}; ordinary admission {{non-constant-trip-count|trip-count-overflow|scalar-scratch-limit}}; equality witness {{.*}}; guarded witness {{.*}}; witness backedge bound 64
; REMARK: scalar-affine.c:82:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; REMARK: scalar-affine.c:82:3: scalar-IR fission producer VF 1
; REMARK: scalar-affine.c:82:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-LABEL: define void @affine_enclosing(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR-NOT: alloca
; SCALAR: %fission.ordinal = phi i64 [ 0, %inner.ph ]
; SCALAR: %iv = phi i64 [ %origin, %inner.ph ]
; SCALAR: scalar.fission.consumer.ph:
; SCALAR: row.exit:
; SCALAR: store i32
; SCALAR: store double
; SCALAR: ret void
; EVL-LABEL: define void @affine_enclosing(
; EVL: alloca [65 x i32]
; EVL: alloca [65 x double]
; EVL-NOT: alloca
; EVL: %fission.ordinal = phi i64 [ 0, %inner.ph ]
; EVL: %iv = phi i64 [ %origin, %inner.ph ]
; EVL: scalar.fission.consumer.ph:
; EVL: row.exit:
; EVL: store i32
; EVL: store double
; EVL: ret void
; TAIL-LABEL: define void @affine_enclosing(
; TAIL: alloca [65 x i32]
; TAIL: alloca [65 x double]
; TAIL-NOT: alloca
; TAIL: %fission.ordinal = phi i64 [ 0, %inner.ph ]
; TAIL: %iv = phi i64 [ %origin, %inner.ph ]
; TAIL: scalar.fission.consumer.ph:
; TAIL: row.exit:
; TAIL: store i32
; TAIL: store double
; TAIL: ret void
define void @affine_enclosing(ptr readonly %a, ptr readonly %fp, ptr %out,
                                  ptr %dout, i64 %rows, i64 %n, double %start) !dbg !20 {
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
  %origin = add nuw nsw i64 %row, 5
  %span = shl nuw nsw i64 %n, 1
  %limit = add nuw nsw i64 %origin, %span
  br label %inner, !dbg !21
inner:
  %iv = phi i64 [%origin, %inner.ph], [%next, %latch]
  %sum = phi i32 [%carry, %inner.ph], [%update, %latch]
  %dsum = phi double [%dcarry, %inner.ph], [%dupdate, %latch]
  %distance = sub nuw nsw i64 %iv, %origin
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %base, i64 %index
  %x = load i32, ptr %p, align 4
  %salted = xor i32 %x, %salt
  %bit = and i32 %x, 1
  %choose = icmp ne i32 %bit, 0
  br i1 %choose, label %left, label %right, !dbg !21
left:
  %lc = call i32 @scalar_helper(i32 %salted)
  %dp = getelementptr double, ptr %dbase, i64 %index
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
  %parity = and i64 %index, 1
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
  %next = add nuw nsw i64 %iv, 2
  %done = icmp slt i64 %next, %limit
  br i1 %done, label %inner, label %row.exit, !dbg !21
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

; Modular control arithmetic is retained too. A completely unconstrained runtime
; start may wrap, while the ordinal never wraps. No new nowrap flags on control.
; REMARK: scalar-affine.c:92:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044
; REMARK: scalar-affine.c:92:3: scalar-IR fission producer VF 1
; REMARK: scalar-affine.c:92:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-LABEL: define void @affine_wrap(
; SCALAR: %fission.ordinal = phi i64 [ 0, %preheader ]
; SCALAR: %iv = phi i64 [ %begin, %preheader ]
; SCALAR: %next = add i64 %iv, 2
; SCALAR: %done = icmp eq i64 %limit, %next
; SCALAR: %fission.completed.count = phi i64 [ %fission.completed, %latch ]
; SCALAR: %fission.consumer.next = add nuw i64 %fission.consumer.iv, 1
; SCALAR: ret void
; EVL-LABEL: define void @affine_wrap(
; EVL: %next = add i64 %iv, 2
; EVL: scalar.fission.consumer.ph:
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64
; EVL: call i32 @llvm.vector.reduce.add.nxv4i32
; EVL: ret void
; TAIL-LABEL: define void @affine_wrap(
; TAIL: %next = add i64 %iv, 2
; TAIL: scalar.fission.consumer.ph:
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64
; TAIL: call i32 @llvm.vector.reduce.add.nxv4i32
; TAIL: ret void
define void @affine_wrap(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) !dbg !22 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  %span = shl nuw nsw i64 %n, 1
  %limit = add i64 %begin, %span
  br label %loop, !dbg !23
loop:
  %iv = phi i64 [%begin, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %distance = sub i64 %iv, %begin
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !23
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge
right:
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  br label %first.merge
first.merge:
  %first.c = phi i32 [%lc, %left], [17, %right]
  %first.d = phi double [%ld, %left], [%rc, %right]
  %parity = and i64 %index, 1
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
  %next = add i64 %iv, 2
  %done = icmp eq i64 %limit, %next
  br i1 %done, label %exit, label %loop, !dbg !23
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

; Testing the current IV, rather than its increment, still completes N trips.
; REMARK: scalar-affine.c:102:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044
; REMARK: scalar-affine.c:102:3: scalar-IR fission producer VF 1
; REMARK: scalar-affine.c:102:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-LABEL: define void @affine_current(
; SCALAR: %fission.ordinal = phi i64 [ 0, %preheader ]
; SCALAR: %next = add nuw nsw i64 %iv, 2
; SCALAR: %done = icmp uge i64 %iv, %limit
; SCALAR: %fission.completed.count = phi i64 [ %fission.completed, %latch ]
; SCALAR: %fission.consumer.next = add nuw i64 %fission.consumer.iv, 1
; SCALAR: ret void
; EVL-LABEL: define void @affine_current(
; EVL: %done = icmp uge i64 %iv, %limit
; EVL: scalar.fission.consumer.ph:
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64
; EVL: call i32 @llvm.vector.reduce.add.nxv4i32
; EVL: ret void
; TAIL-LABEL: define void @affine_current(
; TAIL: %done = icmp uge i64 %iv, %limit
; TAIL: scalar.fission.consumer.ph:
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64
; TAIL: call i32 @llvm.vector.reduce.add.nxv4i32
; TAIL: ret void
define void @affine_current(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) !dbg !24 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  %last = sub nuw nsw i64 %n, 1
  %span = shl nuw nsw i64 %last, 1
  %limit = add nuw nsw i64 %span, 7
  br label %loop, !dbg !25
loop:
  %iv = phi i64 [7, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %distance = sub nuw nsw i64 %iv, 7
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !25
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge
right:
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  br label %first.merge
first.merge:
  %first.c = phi i32 [%lc, %left], [17, %right]
  %first.d = phi double [%ld, %left], [%rc, %right]
  %parity = and i64 %index, 1
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
  %next = add nuw nsw i64 %iv, 2
  %done = icmp uge i64 %iv, %limit
  br i1 %done, label %exit, label %loop, !dbg !25
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

; Analogous modular relational controls: equality at n-1 is only an upper
; bound on backedges. Depending on the start, comparison signedness and
; wrapping, these execute fewer than n iterations. The consumer MUST use
; the actual completed count, never n or the equality witness. Original
; arithmetic has no nowrap flags. Host comparisons include the early exits.

; REMARK: scalar-affine.c:112:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044
; REMARK: scalar-affine.c:112:3: scalar-IR fission producer VF 1
; REMARK: scalar-affine.c:112:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-LABEL: define void @affine_unsigned_early(
; SCALAR: alloca [65 x i32]
; SCALAR: %fission.ordinal = phi i64 [ 0, %preheader ]
; SCALAR: %next = add i64 %iv, 3
; SCALAR: %done = icmp ult i64 %next, %limit
; SCALAR: scalar.fission.consumer.ph:
; SCALAR: %fission.completed.count = phi i64 [ %fission.completed, %latch ]
; SCALAR: ret void
; EVL-LABEL: define void @affine_unsigned_early(
; EVL: alloca [65 x i32]
; EVL: %fission.ordinal = phi i64 [ 0, %preheader ]
; EVL: %next = add i64 %iv, 3
; EVL: %done = icmp ult i64 %next, %limit
; EVL: scalar.fission.consumer.ph:
; EVL: vector.body:
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64
; EVL: ret void
; TAIL-LABEL: define void @affine_unsigned_early(
; TAIL: alloca [65 x i32]
; TAIL: %fission.ordinal = phi i64 [ 0, %preheader ]
; TAIL: %next = add i64 %iv, 3
; TAIL: %done = icmp ult i64 %next, %limit
; TAIL: scalar.fission.consumer.ph:
; TAIL: vector.body:
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64
; TAIL: ret void
define void @affine_unsigned_early(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) !dbg !26 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  %span = mul i64 %n, 3
  %limit = add i64 %begin, %span
  br label %loop, !dbg !27
loop:
  %iv = phi i64 [%begin, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %distance = sub i64 %iv, %begin
  %index = udiv i64 %distance, 3
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !27
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge
right:
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  br label %first.merge
first.merge:
  %first.c = phi i32 [%lc, %left], [17, %right]
  %first.d = phi double [%ld, %left], [%rc, %right]
  %parity = and i64 %index, 1
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
  %next = add i64 %iv, 3
  %done = icmp ult i64 %next, %limit
  br i1 %done, label %loop, label %exit, !dbg !27
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

; REMARK: scalar-affine.c:122:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044
; REMARK: scalar-affine.c:122:3: scalar-IR fission producer VF 1
; REMARK: scalar-affine.c:122:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-LABEL: define void @affine_signed_early(
; SCALAR: alloca [65 x i32]
; SCALAR: %fission.ordinal = phi i64 [ 0, %preheader ]
; SCALAR: %next = add i64 %iv, 3
; SCALAR: %done = icmp slt i64 %next, %limit
; SCALAR: scalar.fission.consumer.ph:
; SCALAR: %fission.completed.count = phi i64 [ %fission.completed, %latch ]
; SCALAR: ret void
; EVL-LABEL: define void @affine_signed_early(
; EVL: alloca [65 x i32]
; EVL: %fission.ordinal = phi i64 [ 0, %preheader ]
; EVL: %next = add i64 %iv, 3
; EVL: %done = icmp slt i64 %next, %limit
; EVL: scalar.fission.consumer.ph:
; EVL: vector.body:
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64
; EVL: ret void
; TAIL-LABEL: define void @affine_signed_early(
; TAIL: alloca [65 x i32]
; TAIL: %fission.ordinal = phi i64 [ 0, %preheader ]
; TAIL: %next = add i64 %iv, 3
; TAIL: %done = icmp slt i64 %next, %limit
; TAIL: scalar.fission.consumer.ph:
; TAIL: vector.body:
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64
; TAIL: ret void
define void @affine_signed_early(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) !dbg !28 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  %span = mul i64 %n, 3
  %limit = add i64 %begin, %span
  br label %loop, !dbg !29
loop:
  %iv = phi i64 [%begin, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %distance = sub i64 %iv, %begin
  %index = udiv i64 %distance, 3
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !29
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge
right:
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  br label %first.merge
first.merge:
  %first.c = phi i32 [%lc, %left], [17, %right]
  %first.d = phi double [%ld, %left], [%rc, %right]
  %parity = and i64 %index, 1
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
  %next = add i64 %iv, 3
  %done = icmp slt i64 %next, %limit
  br i1 %done, label %loop, label %exit, !dbg !29
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

; REMARK: scalar-affine.c:132:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044
; REMARK: scalar-affine.c:132:3: scalar-IR fission producer VF 1
; REMARK: scalar-affine.c:132:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-LABEL: define void @affine_down_early(
; SCALAR: alloca [65 x i32]
; SCALAR: %fission.ordinal = phi i64 [ 0, %preheader ]
; SCALAR: %next = sub i64 %iv, 3
; SCALAR: %done = icmp ugt i64 %next, %limit
; SCALAR: scalar.fission.consumer.ph:
; SCALAR: %fission.completed.count = phi i64 [ %fission.completed, %latch ]
; SCALAR: ret void
; EVL-LABEL: define void @affine_down_early(
; EVL: alloca [65 x i32]
; EVL: %fission.ordinal = phi i64 [ 0, %preheader ]
; EVL: %next = sub i64 %iv, 3
; EVL: %done = icmp ugt i64 %next, %limit
; EVL: scalar.fission.consumer.ph:
; EVL: vector.body:
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64
; EVL: ret void
; TAIL-LABEL: define void @affine_down_early(
; TAIL: alloca [65 x i32]
; TAIL: %fission.ordinal = phi i64 [ 0, %preheader ]
; TAIL: %next = sub i64 %iv, 3
; TAIL: %done = icmp ugt i64 %next, %limit
; TAIL: scalar.fission.consumer.ph:
; TAIL: vector.body:
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64
; TAIL: ret void
define void @affine_down_early(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) !dbg !30 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  %span = mul i64 %n, 3
  %limit = sub i64 %begin, %span
  br label %loop, !dbg !31
loop:
  %iv = phi i64 [%begin, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %distance = sub i64 %begin, %iv
  %index = udiv i64 %distance, 3
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !31
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge
right:
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  br label %first.merge
first.merge:
  %first.c = phi i32 [%lc, %left], [17, %right]
  %first.d = phi double [%ld, %left], [%rc, %right]
  %parity = and i64 %index, 1
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
  %next = sub i64 %iv, 3
  %done = icmp ugt i64 %next, %limit
  br i1 %done, label %loop, label %exit, !dbg !31
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

; REMARK: scalar-affine.c:142:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044
; REMARK: scalar-affine.c:142:3: scalar-IR fission producer VF 1
; REMARK: scalar-affine.c:142:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-LABEL: define void @affine_signed_down_early(
; SCALAR: alloca [65 x i32]
; SCALAR: %fission.ordinal = phi i64 [ 0, %preheader ]
; SCALAR: %next = sub i64 %iv, 3
; SCALAR: %done = icmp sgt i64 %next, %limit
; SCALAR: scalar.fission.consumer.ph:
; SCALAR: %fission.completed.count = phi i64 [ %fission.completed, %latch ]
; SCALAR: ret void
; EVL-LABEL: define void @affine_signed_down_early(
; EVL: alloca [65 x i32]
; EVL: %fission.ordinal = phi i64 [ 0, %preheader ]
; EVL: %next = sub i64 %iv, 3
; EVL: %done = icmp sgt i64 %next, %limit
; EVL: scalar.fission.consumer.ph:
; EVL: vector.body:
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64
; EVL: ret void
; TAIL-LABEL: define void @affine_signed_down_early(
; TAIL: alloca [65 x i32]
; TAIL: %fission.ordinal = phi i64 [ 0, %preheader ]
; TAIL: %next = sub i64 %iv, 3
; TAIL: %done = icmp sgt i64 %next, %limit
; TAIL: scalar.fission.consumer.ph:
; TAIL: vector.body:
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64
; TAIL: ret void
define void @affine_signed_down_early(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) !dbg !32 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  %span = mul i64 %n, 3
  %limit = sub i64 %begin, %span
  br label %loop, !dbg !33
loop:
  %iv = phi i64 [%begin, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %distance = sub i64 %begin, %iv
  %index = udiv i64 %distance, 3
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !33
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge
right:
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  br label %first.merge
first.merge:
  %first.c = phi i32 [%lc, %left], [17, %right]
  %first.d = phi double [%ld, %left], [%rc, %right]
  %parity = and i64 %index, 1
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
  %next = sub i64 %iv, 3
  %done = icmp sgt i64 %next, %limit
  br i1 %done, label %loop, label %exit, !dbg !33
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

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-affine.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = !DISubroutineType(types: !5)
!5 = !{}
!6 = distinct !DISubprogram(name: "affine_const", scope: !1, file: !1, line: 10, type: !4, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!7 = !DILocation(line: 12, column: 3, scope: !6)
!8 = distinct !DISubprogram(name: "affine_runtime", scope: !1, file: !1, line: 20, type: !4, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!9 = !DILocation(line: 22, column: 3, scope: !8)
!10 = distinct !DISubprogram(name: "affine_unsigned", scope: !1, file: !1, line: 30, type: !4, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 32, column: 3, scope: !10)
!12 = distinct !DISubprogram(name: "affine_signed", scope: !1, file: !1, line: 40, type: !4, scopeLine: 40, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 42, column: 3, scope: !12)
!14 = distinct !DISubprogram(name: "affine_down", scope: !1, file: !1, line: 50, type: !4, scopeLine: 50, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!15 = !DILocation(line: 52, column: 3, scope: !14)
!16 = distinct !DISubprogram(name: "affine_signed_down", scope: !1, file: !1, line: 60, type: !4, scopeLine: 60, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!17 = !DILocation(line: 62, column: 3, scope: !16)
!18 = distinct !DISubprogram(name: "affine_compact", scope: !1, file: !1, line: 70, type: !4, scopeLine: 70, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!19 = !DILocation(line: 72, column: 3, scope: !18)
!20 = distinct !DISubprogram(name: "affine_enclosing", scope: !1, file: !1, line: 80, type: !4, scopeLine: 80, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!21 = !DILocation(line: 82, column: 3, scope: !20)
!22 = distinct !DISubprogram(name: "affine_wrap", scope: !1, file: !1, line: 90, type: !4, scopeLine: 90, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!23 = !DILocation(line: 92, column: 3, scope: !22)
!24 = distinct !DISubprogram(name: "affine_current", scope: !1, file: !1, line: 100, type: !4, scopeLine: 100, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!25 = !DILocation(line: 102, column: 3, scope: !24)
!26 = distinct !DISubprogram(name: "affine_unsigned_early", scope: !1, file: !1, line: 110, type: !4, scopeLine: 110, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!27 = !DILocation(line: 112, column: 3, scope: !26)
!28 = distinct !DISubprogram(name: "affine_signed_early", scope: !1, file: !1, line: 120, type: !4, scopeLine: 120, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!29 = !DILocation(line: 122, column: 3, scope: !28)
!30 = distinct !DISubprogram(name: "affine_down_early", scope: !1, file: !1, line: 130, type: !4, scopeLine: 130, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!31 = !DILocation(line: 132, column: 3, scope: !30)
!32 = distinct !DISubprogram(name: "affine_signed_down_early", scope: !1, file: !1, line: 140, type: !4, scopeLine: 140, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!33 = !DILocation(line: 142, column: 3, scope: !32)
