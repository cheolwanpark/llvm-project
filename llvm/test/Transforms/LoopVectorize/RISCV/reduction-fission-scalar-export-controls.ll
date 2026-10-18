; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=1044 \
; RUN:   -pass-remarks=vplan-reduction-fission -S %s -o %t.scalar 2> %t.scalar.remarks
; RUN: FileCheck %s --check-prefix=SCALAR < %t.scalar
; RUN: FileCheck %s --check-prefix=SCALAR-REMARK < %t.scalar.remarks
; RUN: FileCheck %s --check-prefix=SELECTED < %t.scalar.remarks
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=4 -force-vector-interleave=1 \
; RUN:   -scalable-vectorization=always -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=1044 \
; RUN:   -pass-remarks=vplan-reduction-fission -S %s -o %t.vector 2> %t.vector.remarks
; RUN: FileCheck %s --check-prefix=VECTOR < %t.vector
; RUN: FileCheck %s --check-prefix=REMARK < %t.vector.remarks
; RUN: FileCheck %s --check-prefix=SELECTED < %t.vector.remarks
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.vector -o /dev/null
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=4 -force-vector-interleave=1 \
; RUN:   -scalable-vectorization=always -hints-allow-reordering=false \
; RUN:   -tail-folding-policy=dont-fold-tail -enable-epilogue-vectorization=false \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-allow-fp-reordering \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=1044 \
; RUN:   -pass-remarks=vplan-reduction-fission -S %s -o %t.repeat 2> %t.repeat.remarks
; RUN: FileCheck %s --check-prefix=VECTOR < %t.repeat
; RUN: FileCheck %s --check-prefix=REMARK < %t.repeat.remarks
; RUN: FileCheck %s --check-prefix=SELECTED < %t.repeat.remarks
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.repeat -o /dev/null
; RUN: opt -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -force-vector-width=1 -force-vector-interleave=0 -force-target-max-scalar-interleave=1 \
; RUN:   -scalable-vectorization=off -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=1043 -pass-remarks-missed=vplan-reduction-fission \
; RUN:   -S %s -o %t.limit 2> %t.limit.remarks
; RUN: FileCheck %s --check-prefix=LIMIT < %t.limit.remarks
; RUN: FileCheck %s --check-prefix=UNCHANGED --implicit-check-not=scalar.fission < %t.limit
;
; SELECTED-COUNT-8: : split scalar-IR reduction loop;
; SELECTED-NOT: : split
;
; Final dominating exports depend on latch-edge SSA availability, not the
; original induction's start/step/test or the number of acyclic diamonds.
; All eight cases have exactly N iterations and require the full 1044-byte
; capacity. The 1043-byte run must reject, never change chunk admission.
; The executable contract checks original IR and independent C under separate
; strict/reordered settings, with actual vector/tail/producer/empty-path probes.
; It includes zero entry, one iteration, all P=0..65, final inactive iterations,
; duplicate users, mixed types, aliases and enclosing-loop scratch reuse.
;
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

; REMARK: scalar-export-controls.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; REMARK: scalar-export-controls.c:12:3: scalar-IR fission producer VF 1
; REMARK: scalar-export-controls.c:12:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-REMARK: scalar-export-controls.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; SCALAR-REMARK: scalar-export-controls.c:12:3: scalar-IR fission producer VF 1
; SCALAR-REMARK: scalar-export-controls.c:12:3: scalar-IR fission consumer VF 1
; LIMIT: scalar-export-controls.c:12:3: scalar-IR reduction fission rejected: scalar-scratch-limit
; UNCHANGED-LABEL: define void @export_offset(
; UNCHANGED: ret void
; SCALAR-LABEL: define void @export_offset(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR: alloca [65 x float]
; SCALAR-NOT: alloca
; SCALAR: %iv = phi i64 [ 7, %preheader ]
; SCALAR: %done = icmp
; SCALAR: scalar.fission.consumer.{{guard|ph}}:
; SCALAR-DAG: %x.fission.export = phi i32 [ %x, %loop ]
; SCALAR-DAG: %c.fission.export = phi i32 [ %c, %loop ]
; SCALAR-DAG: %iv.fission.export = phi i64 [ %iv, %loop ]
; SCALAR-DAG: %next.fission.export = phi i64 [ %next, %loop ]
; SCALAR-DAG: %dc.fission.export = phi double [ %dc, %loop ]
; SCALAR-DAG: %fc.fission.export = phi float [ %fc, %loop ]
; SCALAR: %out.c.copy = phi i32 [ %c.fission.export,
; SCALAR: ret void
; VECTOR-LABEL: define void @export_offset(
; VECTOR: scalar.fission.consumer.ph:
; VECTOR: vector.body:
; VECTOR: call i32 @llvm.vector.reduce.add.nxv4i32
; VECTOR: ret void
define void @export_offset(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                            ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !10 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %inner.enter, label %preheader, label %exit
preheader:
  %limit = add nuw nsw i64 %n, 7
  br label %loop, !dbg !11
loop:
  %iv = phi i64 [7, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %rf = phi float [%fstart, %preheader], [%uf, %loop]
  %index = sub nuw nsw i64 %iv, 7
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %c = call i32 @scalar_helper(i32 %x)
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %dc = fmul double %dx, 3.0
  %fc = fptrunc double %dc to float
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %limit
  br i1 %done, label %producer.exit, label %loop, !dbg !11
producer.exit:
  %out.x = phi i32 [%x, %loop]
  %out.c = phi i32 [%c, %loop]
  %out.c.copy = phi i32 [%c, %loop]
  %out.iv = phi i64 [%iv, %loop]
  %out.next = phi i64 [%next, %loop]
  %out.dc = phi double [%dc, %loop]
  %out.fc = phi float [%fc, %loop]
  %out.r0 = phi i32 [%u0, %loop]
  %out.r1 = phi i32 [%u1, %loop]
  %out.rd = phi double [%ud, %loop]
  %out.rf = phi float [%uf, %loop]
  br label %exit
exit:
  %final.x = phi i32 [-99, %entry], [%out.x, %producer.exit]
  %final.c = phi i32 [-101, %entry], [%out.c, %producer.exit]
  %final.c.copy = phi i32 [-101, %entry], [%out.c.copy, %producer.exit]
  %final.iv = phi i64 [-1, %entry], [%out.iv, %producer.exit]
  %final.next = phi i64 [0, %entry], [%out.next, %producer.exit]
  %final.dc = phi double [-0.0, %entry], [%out.dc, %producer.exit]
  %final.fc = phi float [-0.0, %entry], [%out.fc, %producer.exit]
  %final.r0 = phi i32 [17, %entry], [%out.r0, %producer.exit]
  %final.r1 = phi i32 [-7, %entry], [%out.r1, %producer.exit]
  %final.rd = phi double [%start, %entry], [%out.rd, %producer.exit]
  %final.rf = phi float [%fstart, %entry], [%out.rf, %producer.exit]
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %final.r0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %final.r1, ptr %o1, align 4
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %final.x, ptr %o2, align 4
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %final.c, ptr %o3, align 4
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %final.c.copy, ptr %o4, align 4
  %indices0 = getelementptr i64, ptr %indices, i64 0
  store i64 %final.iv, ptr %indices0, align 8
  %indices1 = getelementptr i64, ptr %indices, i64 1
  store i64 %final.next, ptr %indices1, align 8
  %dout0 = getelementptr double, ptr %dout, i64 0
  store double %final.rd, ptr %dout0, align 8
  %dout1 = getelementptr double, ptr %dout, i64 1
  store double %final.dc, ptr %dout1, align 8
  %fout0 = getelementptr float, ptr %fout, i64 0
  store float %final.rf, ptr %fout0, align 4
  %fout1 = getelementptr float, ptr %fout, i64 1
  store float %final.fc, ptr %fout1, align 4
  ret void
}

; REMARK: scalar-export-controls.c:22:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; REMARK: scalar-export-controls.c:22:3: scalar-IR fission producer VF 1
; REMARK: scalar-export-controls.c:22:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-REMARK: scalar-export-controls.c:22:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; SCALAR-REMARK: scalar-export-controls.c:22:3: scalar-IR fission producer VF 1
; SCALAR-REMARK: scalar-export-controls.c:22:3: scalar-IR fission consumer VF 1
; LIMIT: scalar-export-controls.c:22:3: scalar-IR reduction fission rejected: scalar-scratch-limit
; UNCHANGED-LABEL: define void @export_stride(
; UNCHANGED: ret void
; SCALAR-LABEL: define void @export_stride(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR: alloca [65 x float]
; SCALAR-NOT: alloca
; SCALAR: %iv = phi i64 [ 7, %preheader ]
; SCALAR: %done = icmp
; SCALAR: scalar.fission.consumer.{{guard|ph}}:
; SCALAR-DAG: %x.fission.export = phi i32 [ %x, %latch ]
; SCALAR-DAG: %c.fission.export = phi i32 [ %c, %latch ]
; SCALAR-DAG: %iv.fission.export = phi i64 [ %iv, %latch ]
; SCALAR-DAG: %next.fission.export = phi i64 [ %next, %latch ]
; SCALAR-DAG: %dc.fission.export = phi double [ %dc, %latch ]
; SCALAR-DAG: %fc.fission.export = phi float [ %fc, %latch ]
; SCALAR: %out.c.copy = phi i32 [ %c.fission.export,
; SCALAR: ret void
; VECTOR-LABEL: define void @export_stride(
; VECTOR: scalar.fission.consumer.ph:
; VECTOR: vector.body:
; VECTOR: call i32 @llvm.vector.reduce.add.nxv4i32
; VECTOR: ret void
define void @export_stride(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                            ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !12 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %inner.enter, label %preheader, label %exit
preheader:
  %span = shl nuw nsw i64 %n, 1
  %limit = add nuw nsw i64 %span, 7
  br label %loop, !dbg !13
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
  br i1 %choose, label %left, label %right, !dbg !13
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %ld = fmul double %dx, 3.0
  %lf = fptrunc double %ld to float
  br label %latch
right:
  %rc = xor i32 %x, 7
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [%rc, %right]
  %dc = phi double [%ld, %left], [-0.0, %right]
  %fc = phi float [%lf, %left], [-0.0, %right]
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  %next = add nuw nsw i64 %iv, 2
  %done = icmp uge i64 %next, %limit
  br i1 %done, label %producer.exit, label %loop, !dbg !13
producer.exit:
  %out.x = phi i32 [%x, %latch]
  %out.c = phi i32 [%c, %latch]
  %out.c.copy = phi i32 [%c, %latch]
  %out.iv = phi i64 [%iv, %latch]
  %out.next = phi i64 [%next, %latch]
  %out.dc = phi double [%dc, %latch]
  %out.fc = phi float [%fc, %latch]
  %out.r0 = phi i32 [%u0, %latch]
  %out.r1 = phi i32 [%u1, %latch]
  %out.rd = phi double [%ud, %latch]
  %out.rf = phi float [%uf, %latch]
  br label %exit
exit:
  %final.x = phi i32 [-99, %entry], [%out.x, %producer.exit]
  %final.c = phi i32 [-101, %entry], [%out.c, %producer.exit]
  %final.c.copy = phi i32 [-101, %entry], [%out.c.copy, %producer.exit]
  %final.iv = phi i64 [-1, %entry], [%out.iv, %producer.exit]
  %final.next = phi i64 [0, %entry], [%out.next, %producer.exit]
  %final.dc = phi double [-0.0, %entry], [%out.dc, %producer.exit]
  %final.fc = phi float [-0.0, %entry], [%out.fc, %producer.exit]
  %final.r0 = phi i32 [17, %entry], [%out.r0, %producer.exit]
  %final.r1 = phi i32 [-7, %entry], [%out.r1, %producer.exit]
  %final.rd = phi double [%start, %entry], [%out.rd, %producer.exit]
  %final.rf = phi float [%fstart, %entry], [%out.rf, %producer.exit]
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %final.r0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %final.r1, ptr %o1, align 4
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %final.x, ptr %o2, align 4
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %final.c, ptr %o3, align 4
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %final.c.copy, ptr %o4, align 4
  %indices0 = getelementptr i64, ptr %indices, i64 0
  store i64 %final.iv, ptr %indices0, align 8
  %indices1 = getelementptr i64, ptr %indices, i64 1
  store i64 %final.next, ptr %indices1, align 8
  %dout0 = getelementptr double, ptr %dout, i64 0
  store double %final.rd, ptr %dout0, align 8
  %dout1 = getelementptr double, ptr %dout, i64 1
  store double %final.dc, ptr %dout1, align 8
  %fout0 = getelementptr float, ptr %fout, i64 0
  store float %final.rf, ptr %fout0, align 4
  %fout1 = getelementptr float, ptr %fout, i64 1
  store float %final.fc, ptr %fout1, align 4
  ret void
}

; REMARK: scalar-export-controls.c:32:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; REMARK: scalar-export-controls.c:32:3: scalar-IR fission producer VF 1
; REMARK: scalar-export-controls.c:32:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-REMARK: scalar-export-controls.c:32:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; SCALAR-REMARK: scalar-export-controls.c:32:3: scalar-IR fission producer VF 1
; SCALAR-REMARK: scalar-export-controls.c:32:3: scalar-IR fission consumer VF 1
; LIMIT: scalar-export-controls.c:32:3: scalar-IR reduction fission rejected: scalar-scratch-limit
; UNCHANGED-LABEL: define void @export_down(
; UNCHANGED: ret void
; SCALAR-LABEL: define void @export_down(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR: alloca [65 x float]
; SCALAR-NOT: alloca
; SCALAR: %iv = phi i64 [ 137, %preheader ]
; SCALAR: %done = icmp
; SCALAR: scalar.fission.consumer.{{guard|ph}}:
; SCALAR-DAG: %x.fission.export = phi i32 [ %x, %latch ]
; SCALAR-DAG: %c.fission.export = phi i32 [ %c, %latch ]
; SCALAR-DAG: %iv.fission.export = phi i64 [ %iv, %latch ]
; SCALAR-DAG: %next.fission.export = phi i64 [ %next, %latch ]
; SCALAR-DAG: %dc.fission.export = phi double [ %dc, %latch ]
; SCALAR-DAG: %fc.fission.export = phi float [ %fc, %latch ]
; SCALAR: %out.c.copy = phi i32 [ %c.fission.export,
; SCALAR: ret void
; VECTOR-LABEL: define void @export_down(
; VECTOR: scalar.fission.consumer.ph:
; VECTOR: vector.body:
; VECTOR: call i32 @llvm.vector.reduce.add.nxv4i32
; VECTOR: ret void
define void @export_down(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                            ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !14 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %inner.enter, label %preheader, label %exit
preheader:
  %span = shl nuw nsw i64 %n, 1
  %limit = sub nuw nsw i64 137, %span
  br label %loop, !dbg !15
loop:
  %iv = phi i64 [137, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %distance = sub nuw nsw i64 137, %iv
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !15
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %ld = fmul double %dx, 3.0
  %lf = fptrunc double %ld to float
  br label %latch
right:
  %rc = xor i32 %x, 7
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [%rc, %right]
  %dc = phi double [%ld, %left], [-0.0, %right]
  %fc = phi float [%lf, %left], [-0.0, %right]
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  %next = add nsw i64 %iv, -2
  %done = icmp sle i64 %next, %limit
  br i1 %done, label %producer.exit, label %loop, !dbg !15
producer.exit:
  %out.x = phi i32 [%x, %latch]
  %out.c = phi i32 [%c, %latch]
  %out.c.copy = phi i32 [%c, %latch]
  %out.iv = phi i64 [%iv, %latch]
  %out.next = phi i64 [%next, %latch]
  %out.dc = phi double [%dc, %latch]
  %out.fc = phi float [%fc, %latch]
  %out.r0 = phi i32 [%u0, %latch]
  %out.r1 = phi i32 [%u1, %latch]
  %out.rd = phi double [%ud, %latch]
  %out.rf = phi float [%uf, %latch]
  br label %exit
exit:
  %final.x = phi i32 [-99, %entry], [%out.x, %producer.exit]
  %final.c = phi i32 [-101, %entry], [%out.c, %producer.exit]
  %final.c.copy = phi i32 [-101, %entry], [%out.c.copy, %producer.exit]
  %final.iv = phi i64 [-1, %entry], [%out.iv, %producer.exit]
  %final.next = phi i64 [0, %entry], [%out.next, %producer.exit]
  %final.dc = phi double [-0.0, %entry], [%out.dc, %producer.exit]
  %final.fc = phi float [-0.0, %entry], [%out.fc, %producer.exit]
  %final.r0 = phi i32 [17, %entry], [%out.r0, %producer.exit]
  %final.r1 = phi i32 [-7, %entry], [%out.r1, %producer.exit]
  %final.rd = phi double [%start, %entry], [%out.rd, %producer.exit]
  %final.rf = phi float [%fstart, %entry], [%out.rf, %producer.exit]
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %final.r0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %final.r1, ptr %o1, align 4
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %final.x, ptr %o2, align 4
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %final.c, ptr %o3, align 4
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %final.c.copy, ptr %o4, align 4
  %indices0 = getelementptr i64, ptr %indices, i64 0
  store i64 %final.iv, ptr %indices0, align 8
  %indices1 = getelementptr i64, ptr %indices, i64 1
  store i64 %final.next, ptr %indices1, align 8
  %dout0 = getelementptr double, ptr %dout, i64 0
  store double %final.rd, ptr %dout0, align 8
  %dout1 = getelementptr double, ptr %dout, i64 1
  store double %final.dc, ptr %dout1, align 8
  %fout0 = getelementptr float, ptr %fout, i64 0
  store float %final.rf, ptr %fout0, align 4
  %fout1 = getelementptr float, ptr %fout, i64 1
  store float %final.fc, ptr %fout1, align 4
  ret void
}

; REMARK: scalar-export-controls.c:42:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; REMARK: scalar-export-controls.c:42:3: scalar-IR fission producer VF 1
; REMARK: scalar-export-controls.c:42:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-REMARK: scalar-export-controls.c:42:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; SCALAR-REMARK: scalar-export-controls.c:42:3: scalar-IR fission producer VF 1
; SCALAR-REMARK: scalar-export-controls.c:42:3: scalar-IR fission consumer VF 1
; LIMIT: scalar-export-controls.c:42:3: scalar-IR reduction fission rejected: scalar-scratch-limit
; UNCHANGED-LABEL: define void @export_current(
; UNCHANGED: ret void
; SCALAR-LABEL: define void @export_current(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR: alloca [65 x float]
; SCALAR-NOT: alloca
; SCALAR: %iv = phi i64 [ 7, %preheader ]
; SCALAR: %done = icmp
; SCALAR: scalar.fission.consumer.{{guard|ph}}:
; SCALAR-DAG: %x.fission.export = phi i32 [ %x, %loop ]
; SCALAR-DAG: %c.fission.export = phi i32 [ %c, %loop ]
; SCALAR-DAG: %iv.fission.export = phi i64 [ %iv, %loop ]
; SCALAR-DAG: %next.fission.export = phi i64 [ %next, %loop ]
; SCALAR-DAG: %dc.fission.export = phi double [ %dc, %loop ]
; SCALAR-DAG: %fc.fission.export = phi float [ %fc, %loop ]
; SCALAR: %out.c.copy = phi i32 [ %c.fission.export,
; SCALAR: ret void
; VECTOR-LABEL: define void @export_current(
; VECTOR: scalar.fission.consumer.ph:
; VECTOR: vector.body:
; VECTOR: call i32 @llvm.vector.reduce.add.nxv4i32
; VECTOR: ret void
define void @export_current(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                            ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !16 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %inner.enter, label %preheader, label %exit
preheader:
  %span = shl nuw nsw i64 %n, 1
  %limit = add nuw nsw i64 %span, 5
  br label %loop, !dbg !17
loop:
  %iv = phi i64 [7, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %rf = phi float [%fstart, %preheader], [%uf, %loop]
  %distance = sub nuw nsw i64 %iv, 7
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %c = call i32 @scalar_helper(i32 %x)
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %dc = fmul double %dx, 3.0
  %fc = fptrunc double %dc to float
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  %next = add nuw nsw i64 %iv, 2
  %done = icmp uge i64 %iv, %limit
  br i1 %done, label %producer.exit, label %loop, !dbg !17
producer.exit:
  %out.x = phi i32 [%x, %loop]
  %out.c = phi i32 [%c, %loop]
  %out.c.copy = phi i32 [%c, %loop]
  %out.iv = phi i64 [%iv, %loop]
  %out.next = phi i64 [%next, %loop]
  %out.dc = phi double [%dc, %loop]
  %out.fc = phi float [%fc, %loop]
  %out.r0 = phi i32 [%u0, %loop]
  %out.r1 = phi i32 [%u1, %loop]
  %out.rd = phi double [%ud, %loop]
  %out.rf = phi float [%uf, %loop]
  br label %exit
exit:
  %final.x = phi i32 [-99, %entry], [%out.x, %producer.exit]
  %final.c = phi i32 [-101, %entry], [%out.c, %producer.exit]
  %final.c.copy = phi i32 [-101, %entry], [%out.c.copy, %producer.exit]
  %final.iv = phi i64 [-1, %entry], [%out.iv, %producer.exit]
  %final.next = phi i64 [0, %entry], [%out.next, %producer.exit]
  %final.dc = phi double [-0.0, %entry], [%out.dc, %producer.exit]
  %final.fc = phi float [-0.0, %entry], [%out.fc, %producer.exit]
  %final.r0 = phi i32 [17, %entry], [%out.r0, %producer.exit]
  %final.r1 = phi i32 [-7, %entry], [%out.r1, %producer.exit]
  %final.rd = phi double [%start, %entry], [%out.rd, %producer.exit]
  %final.rf = phi float [%fstart, %entry], [%out.rf, %producer.exit]
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %final.r0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %final.r1, ptr %o1, align 4
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %final.x, ptr %o2, align 4
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %final.c, ptr %o3, align 4
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %final.c.copy, ptr %o4, align 4
  %indices0 = getelementptr i64, ptr %indices, i64 0
  store i64 %final.iv, ptr %indices0, align 8
  %indices1 = getelementptr i64, ptr %indices, i64 1
  store i64 %final.next, ptr %indices1, align 8
  %dout0 = getelementptr double, ptr %dout, i64 0
  store double %final.rd, ptr %dout0, align 8
  %dout1 = getelementptr double, ptr %dout, i64 1
  store double %final.dc, ptr %dout1, align 8
  %fout0 = getelementptr float, ptr %fout, i64 0
  store float %final.rf, ptr %fout0, align 4
  %fout1 = getelementptr float, ptr %fout, i64 1
  store float %final.fc, ptr %fout1, align 4
  ret void
}

; REMARK: scalar-export-controls.c:52:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; REMARK: scalar-export-controls.c:52:3: scalar-IR fission producer VF 1
; REMARK: scalar-export-controls.c:52:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-REMARK: scalar-export-controls.c:52:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; SCALAR-REMARK: scalar-export-controls.c:52:3: scalar-IR fission producer VF 1
; SCALAR-REMARK: scalar-export-controls.c:52:3: scalar-IR fission consumer VF 1
; LIMIT: scalar-export-controls.c:52:3: scalar-IR reduction fission rejected: scalar-scratch-limit
; UNCHANGED-LABEL: define void @export_affine_compact(
; UNCHANGED: ret void
; SCALAR-LABEL: define void @export_affine_compact(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR: alloca [65 x float]
; SCALAR-NOT: alloca
; SCALAR: %iv = phi i64 [ 7, %preheader ]
; SCALAR: %done = icmp
; SCALAR: scalar.fission.consumer.{{guard|ph}}:
; SCALAR-DAG: %x.fission.export = phi i32 [ %x, %latch ]
; SCALAR-DAG: %c.fission.export = phi i32 [ %c, %latch ]
; SCALAR-DAG: %iv.fission.export = phi i64 [ %iv, %latch ]
; SCALAR-DAG: %next.fission.export = phi i64 [ %next, %latch ]
; SCALAR-DAG: %dc.fission.export = phi double [ %dc, %latch ]
; SCALAR-DAG: %fc.fission.export = phi float [ %fc, %latch ]
; SCALAR: %out.c.copy = phi i32 [ %c.fission.export,
; SCALAR: ret void
; VECTOR-LABEL: define void @export_affine_compact(
; VECTOR: scalar.fission.consumer.ph:
; VECTOR: vector.body:
; VECTOR: call i32 @llvm.vector.reduce.add.nxv4i32
; VECTOR: ret void
define void @export_affine_compact(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                            ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !18 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %inner.enter, label %preheader, label %exit
preheader:
  %span = shl nuw nsw i64 %n, 1
  %limit = add nuw nsw i64 %span, 7
  br label %loop, !dbg !19
loop:
  %iv = phi i64 [7, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %rf = phi float [%fstart, %preheader], [%mf, %latch]
  %distance = sub nuw nsw i64 %iv, 7
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !19
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %ld = fmul double %dx, 3.0
  %lf = fptrunc double %ld to float
  %u0 = add i32 %r0, %lc
  %u1 = add i32 %lc, %r1
  %ud = fadd double %rd, %ld
  %uf = fadd float %rf, %lf
  br label %latch
right:
  %rc = xor i32 %x, 7
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [%rc, %right]
  %dc = phi double [%ld, %left], [-0.0, %right]
  %fc = phi float [%lf, %left], [-0.0, %right]
  %m0 = phi i32 [%u0, %left], [%r0, %right]
  %m1 = phi i32 [%u1, %left], [%r1, %right]
  %md = phi double [%ud, %left], [%rd, %right]
  %mf = phi float [%uf, %left], [%rf, %right]
  %next = add nuw nsw i64 %iv, 2
  %done = icmp uge i64 %next, %limit
  br i1 %done, label %producer.exit, label %loop, !dbg !19
producer.exit:
  %out.x = phi i32 [%x, %latch]
  %out.c = phi i32 [%c, %latch]
  %out.c.copy = phi i32 [%c, %latch]
  %out.iv = phi i64 [%iv, %latch]
  %out.next = phi i64 [%next, %latch]
  %out.dc = phi double [%dc, %latch]
  %out.fc = phi float [%fc, %latch]
  %out.r0 = phi i32 [%m0, %latch]
  %out.r1 = phi i32 [%m1, %latch]
  %out.rd = phi double [%md, %latch]
  %out.rf = phi float [%mf, %latch]
  br label %exit
exit:
  %final.x = phi i32 [-99, %entry], [%out.x, %producer.exit]
  %final.c = phi i32 [-101, %entry], [%out.c, %producer.exit]
  %final.c.copy = phi i32 [-101, %entry], [%out.c.copy, %producer.exit]
  %final.iv = phi i64 [-1, %entry], [%out.iv, %producer.exit]
  %final.next = phi i64 [0, %entry], [%out.next, %producer.exit]
  %final.dc = phi double [-0.0, %entry], [%out.dc, %producer.exit]
  %final.fc = phi float [-0.0, %entry], [%out.fc, %producer.exit]
  %final.r0 = phi i32 [17, %entry], [%out.r0, %producer.exit]
  %final.r1 = phi i32 [-7, %entry], [%out.r1, %producer.exit]
  %final.rd = phi double [%start, %entry], [%out.rd, %producer.exit]
  %final.rf = phi float [%fstart, %entry], [%out.rf, %producer.exit]
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %final.r0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %final.r1, ptr %o1, align 4
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %final.x, ptr %o2, align 4
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %final.c, ptr %o3, align 4
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %final.c.copy, ptr %o4, align 4
  %indices0 = getelementptr i64, ptr %indices, i64 0
  store i64 %final.iv, ptr %indices0, align 8
  %indices1 = getelementptr i64, ptr %indices, i64 1
  store i64 %final.next, ptr %indices1, align 8
  %dout0 = getelementptr double, ptr %dout, i64 0
  store double %final.rd, ptr %dout0, align 8
  %dout1 = getelementptr double, ptr %dout, i64 1
  store double %final.dc, ptr %dout1, align 8
  %fout0 = getelementptr float, ptr %fout, i64 0
  store float %final.rf, ptr %fout0, align 4
  %fout1 = getelementptr float, ptr %fout, i64 1
  store float %final.fc, ptr %fout1, align 4
  ret void
}

; REMARK: scalar-export-controls.c:62:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; REMARK: scalar-export-controls.c:62:3: scalar-IR fission producer VF 1
; REMARK: scalar-export-controls.c:62:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-REMARK: scalar-export-controls.c:62:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; SCALAR-REMARK: scalar-export-controls.c:62:3: scalar-IR fission producer VF 1
; SCALAR-REMARK: scalar-export-controls.c:62:3: scalar-IR fission consumer VF 1
; LIMIT: scalar-export-controls.c:62:3: scalar-IR reduction fission rejected: scalar-scratch-limit
; UNCHANGED-LABEL: define void @export_serial(
; UNCHANGED: ret void
; SCALAR-LABEL: define void @export_serial(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR: alloca [65 x float]
; SCALAR-NOT: alloca
; SCALAR: %iv = phi i64 [ 7, %preheader ]
; SCALAR: %done = icmp
; SCALAR: scalar.fission.consumer.{{guard|ph}}:
; SCALAR-DAG: %x.fission.export = phi i32 [ %x, %latch ]
; SCALAR-DAG: %c.fission.export = phi i32 [ %c, %latch ]
; SCALAR-DAG: %iv.fission.export = phi i64 [ %iv, %latch ]
; SCALAR-DAG: %next.fission.export = phi i64 [ %next, %latch ]
; SCALAR-DAG: %dc.fission.export = phi double [ %dc, %latch ]
; SCALAR-DAG: %fc.fission.export = phi float [ %fc, %latch ]
; SCALAR: %out.c.copy = phi i32 [ %c.fission.export,
; SCALAR: ret void
; VECTOR-LABEL: define void @export_serial(
; VECTOR: scalar.fission.consumer.ph:
; VECTOR: vector.body:
; VECTOR: call i32 @llvm.vector.reduce.add.nxv4i32
; VECTOR: ret void
define void @export_serial(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                            ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !20 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %inner.enter, label %preheader, label %exit
preheader:
  %span = shl nuw nsw i64 %n, 1
  %limit = add nuw nsw i64 %span, 7
  br label %loop, !dbg !21
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
  br i1 %choose, label %left, label %right, !dbg !21
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %ld = fmul double %dx, 3.0
  br label %first.merge
right:
  %rc = xor i32 %x, 7
  br label %first.merge
first.merge:
  %first.c = phi i32 [%lc, %left], [%rc, %right]
  %first.dc = phi double [%ld, %left], [-0.0, %right]
  %parity = and i64 %index, 1
  %odd = icmp ne i64 %parity, 0
  br i1 %odd, label %positive, label %negative
positive:
  %pc = add i32 %first.c, 23
  %pd = fmul double %first.dc, 0.5
  br label %latch
negative:
  %nc = xor i32 %first.c, -1
  %nd = fmul double %first.dc, -1.0
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
  %done = icmp uge i64 %next, %limit
  br i1 %done, label %producer.exit, label %loop, !dbg !21
producer.exit:
  %out.x = phi i32 [%x, %latch]
  %out.c = phi i32 [%c, %latch]
  %out.c.copy = phi i32 [%c, %latch]
  %out.iv = phi i64 [%iv, %latch]
  %out.next = phi i64 [%next, %latch]
  %out.dc = phi double [%dc, %latch]
  %out.fc = phi float [%fc, %latch]
  %out.r0 = phi i32 [%u0, %latch]
  %out.r1 = phi i32 [%u1, %latch]
  %out.rd = phi double [%ud, %latch]
  %out.rf = phi float [%uf, %latch]
  br label %exit
exit:
  %final.x = phi i32 [-99, %entry], [%out.x, %producer.exit]
  %final.c = phi i32 [-101, %entry], [%out.c, %producer.exit]
  %final.c.copy = phi i32 [-101, %entry], [%out.c.copy, %producer.exit]
  %final.iv = phi i64 [-1, %entry], [%out.iv, %producer.exit]
  %final.next = phi i64 [0, %entry], [%out.next, %producer.exit]
  %final.dc = phi double [-0.0, %entry], [%out.dc, %producer.exit]
  %final.fc = phi float [-0.0, %entry], [%out.fc, %producer.exit]
  %final.r0 = phi i32 [17, %entry], [%out.r0, %producer.exit]
  %final.r1 = phi i32 [-7, %entry], [%out.r1, %producer.exit]
  %final.rd = phi double [%start, %entry], [%out.rd, %producer.exit]
  %final.rf = phi float [%fstart, %entry], [%out.rf, %producer.exit]
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %final.r0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %final.r1, ptr %o1, align 4
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %final.x, ptr %o2, align 4
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %final.c, ptr %o3, align 4
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %final.c.copy, ptr %o4, align 4
  %indices0 = getelementptr i64, ptr %indices, i64 0
  store i64 %final.iv, ptr %indices0, align 8
  %indices1 = getelementptr i64, ptr %indices, i64 1
  store i64 %final.next, ptr %indices1, align 8
  %dout0 = getelementptr double, ptr %dout, i64 0
  store double %final.rd, ptr %dout0, align 8
  %dout1 = getelementptr double, ptr %dout, i64 1
  store double %final.dc, ptr %dout1, align 8
  %fout0 = getelementptr float, ptr %fout, i64 0
  store float %final.rf, ptr %fout0, align 4
  %fout1 = getelementptr float, ptr %fout, i64 1
  store float %final.fc, ptr %fout1, align 4
  ret void
}

; REMARK: scalar-export-controls.c:72:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; REMARK: scalar-export-controls.c:72:3: scalar-IR fission producer VF 1
; REMARK: scalar-export-controls.c:72:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-REMARK: scalar-export-controls.c:72:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; SCALAR-REMARK: scalar-export-controls.c:72:3: scalar-IR fission producer VF 1
; SCALAR-REMARK: scalar-export-controls.c:72:3: scalar-IR fission consumer VF 1
; LIMIT: scalar-export-controls.c:72:3: scalar-IR reduction fission rejected: scalar-scratch-limit
; UNCHANGED-LABEL: define void @export_acyclic_nested(
; UNCHANGED: ret void
; SCALAR-LABEL: define void @export_acyclic_nested(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR: alloca [65 x float]
; SCALAR-NOT: alloca
; SCALAR: %iv = phi i64 [ 7, %preheader ]
; SCALAR: %done = icmp
; SCALAR: scalar.fission.consumer.{{guard|ph}}:
; SCALAR-DAG: %x.fission.export = phi i32 [ %x, %latch ]
; SCALAR-DAG: %c.fission.export = phi i32 [ %c, %latch ]
; SCALAR-DAG: %iv.fission.export = phi i64 [ %iv, %latch ]
; SCALAR-DAG: %next.fission.export = phi i64 [ %next, %latch ]
; SCALAR-DAG: %dc.fission.export = phi double [ %dc, %latch ]
; SCALAR-DAG: %fc.fission.export = phi float [ %fc, %latch ]
; SCALAR: %out.c.copy = phi i32 [ %c.fission.export,
; SCALAR: ret void
; VECTOR-LABEL: define void @export_acyclic_nested(
; VECTOR: scalar.fission.consumer.ph:
; VECTOR: vector.body:
; VECTOR: call i32 @llvm.vector.reduce.add.nxv4i32
; VECTOR: ret void
define void @export_acyclic_nested(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                            ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !22 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %inner.enter, label %preheader, label %exit
preheader:
  %span = shl nuw nsw i64 %n, 1
  %limit = add nuw nsw i64 %span, 7
  br label %loop, !dbg !23
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
  br i1 %choose, label %left, label %right, !dbg !23
left:
  %q = sdiv i32 840, %x
  %raw.c = call i32 @scalar_helper(i32 %q)
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %ld = fmul double %dx, 3.0
  %lf = fptrunc double %ld to float
  %odd = icmp sgt i32 %x, 5
  br i1 %odd, label %inner.left, label %inner.right
inner.left:
  %pc = add i32 %raw.c, 23
  br label %left.merge
inner.right:
  %nc = xor i32 %raw.c, -1
  br label %left.merge
left.merge:
  %lc = phi i32 [%pc, %inner.left], [%nc, %inner.right]
  br label %latch
right:
  %rc = xor i32 %x, 7
  br label %latch
latch:
  %c = phi i32 [%lc, %left.merge], [%rc, %right]
  %dc = phi double [%ld, %left.merge], [-0.0, %right]
  %fc = phi float [%lf, %left.merge], [-0.0, %right]
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  %next = add nuw nsw i64 %iv, 2
  %done = icmp uge i64 %next, %limit
  br i1 %done, label %producer.exit, label %loop, !dbg !23
producer.exit:
  %out.x = phi i32 [%x, %latch]
  %out.c = phi i32 [%c, %latch]
  %out.c.copy = phi i32 [%c, %latch]
  %out.iv = phi i64 [%iv, %latch]
  %out.next = phi i64 [%next, %latch]
  %out.dc = phi double [%dc, %latch]
  %out.fc = phi float [%fc, %latch]
  %out.r0 = phi i32 [%u0, %latch]
  %out.r1 = phi i32 [%u1, %latch]
  %out.rd = phi double [%ud, %latch]
  %out.rf = phi float [%uf, %latch]
  br label %exit
exit:
  %final.x = phi i32 [-99, %entry], [%out.x, %producer.exit]
  %final.c = phi i32 [-101, %entry], [%out.c, %producer.exit]
  %final.c.copy = phi i32 [-101, %entry], [%out.c.copy, %producer.exit]
  %final.iv = phi i64 [-1, %entry], [%out.iv, %producer.exit]
  %final.next = phi i64 [0, %entry], [%out.next, %producer.exit]
  %final.dc = phi double [-0.0, %entry], [%out.dc, %producer.exit]
  %final.fc = phi float [-0.0, %entry], [%out.fc, %producer.exit]
  %final.r0 = phi i32 [17, %entry], [%out.r0, %producer.exit]
  %final.r1 = phi i32 [-7, %entry], [%out.r1, %producer.exit]
  %final.rd = phi double [%start, %entry], [%out.rd, %producer.exit]
  %final.rf = phi float [%fstart, %entry], [%out.rf, %producer.exit]
  %o0 = getelementptr i32, ptr %out, i64 0
  store i32 %final.r0, ptr %o0, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %final.r1, ptr %o1, align 4
  %o2 = getelementptr i32, ptr %out, i64 2
  store i32 %final.x, ptr %o2, align 4
  %o3 = getelementptr i32, ptr %out, i64 3
  store i32 %final.c, ptr %o3, align 4
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %final.c.copy, ptr %o4, align 4
  %indices0 = getelementptr i64, ptr %indices, i64 0
  store i64 %final.iv, ptr %indices0, align 8
  %indices1 = getelementptr i64, ptr %indices, i64 1
  store i64 %final.next, ptr %indices1, align 8
  %dout0 = getelementptr double, ptr %dout, i64 0
  store double %final.rd, ptr %dout0, align 8
  %dout1 = getelementptr double, ptr %dout, i64 1
  store double %final.dc, ptr %dout1, align 8
  %fout0 = getelementptr float, ptr %fout, i64 0
  store float %final.rf, ptr %fout0, align 4
  %fout1 = getelementptr float, ptr %fout, i64 1
  store float %final.fc, ptr %fout1, align 4
  ret void
}

; REMARK: scalar-export-controls.c:82:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; REMARK: scalar-export-controls.c:82:3: scalar-IR fission producer VF 1
; REMARK: scalar-export-controls.c:82:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-REMARK: scalar-export-controls.c:82:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; SCALAR-REMARK: scalar-export-controls.c:82:3: scalar-IR fission producer VF 1
; SCALAR-REMARK: scalar-export-controls.c:82:3: scalar-IR fission consumer VF 1
; LIMIT: scalar-export-controls.c:82:3: scalar-IR reduction fission rejected: scalar-scratch-limit
; UNCHANGED-LABEL: define void @export_enclosing(
; UNCHANGED: ret void
; SCALAR-LABEL: define void @export_enclosing(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR: alloca [65 x float]
; SCALAR-NOT: alloca
; SCALAR: %iv = phi i64 [ 7, %inner.ph ]
; SCALAR: %done = icmp
; SCALAR: scalar.fission.consumer.{{guard|ph}}:
; SCALAR-DAG: %x.fission.export = phi i32 [ %x, %latch ]
; SCALAR-DAG: %c.fission.export = phi i32 [ %c, %latch ]
; SCALAR-DAG: %iv.fission.export = phi i64 [ %iv, %latch ]
; SCALAR-DAG: %next.fission.export = phi i64 [ %next, %latch ]
; SCALAR-DAG: %dc.fission.export = phi double [ %dc, %latch ]
; SCALAR-DAG: %fc.fission.export = phi float [ %fc, %latch ]
; SCALAR: %out.c.copy = phi i32 [ %c.fission.export,
; SCALAR: ret void
; VECTOR-LABEL: define void @export_enclosing(
; VECTOR: scalar.fission.consumer.ph:
; VECTOR: vector.body:
; VECTOR: call i32 @llvm.vector.reduce.add.nxv4i32
; VECTOR: ret void
define void @export_enclosing(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                            ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !24 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  %rows.valid = icmp ule i64 %rows, 4
  %rows.nonzero = icmp ne i64 %rows, 0
  %rows.enter = and i1 %rows.valid, %rows.nonzero
  %enter = and i1 %rows.enter, %inner.enter
  br i1 %enter, label %outer.ph, label %exit
outer.ph:
  br label %outer
outer:
  %row = phi i64 [0, %outer.ph], [%row.next, %row.exit]
  %carry = phi i32 [17, %outer.ph], [%out.r0, %row.exit]
  %carry1 = phi i32 [-7, %outer.ph], [%out.r1, %row.exit]
  %dcarry = phi double [%start, %outer.ph], [%out.rd, %row.exit]
  %fcarry = phi float [%fstart, %outer.ph], [%out.rf, %row.exit]
  %salt = phi i32 [3, %outer.ph], [%out.c, %row.exit]
  %offset = mul nuw i64 %row, 65
  %base = getelementptr i32, ptr %a, i64 %offset
  %dbase = getelementptr double, ptr %fp, i64 %offset
  br label %inner.ph
inner.ph:
  %span = shl nuw nsw i64 %n, 1
  %limit = add nuw nsw i64 %span, 7
  br label %inner, !dbg !25
inner:
  %iv = phi i64 [7, %inner.ph], [%next, %latch]
  %r0 = phi i32 [%carry, %inner.ph], [%m0, %latch]
  %r1 = phi i32 [%carry1, %inner.ph], [%m1, %latch]
  %rd = phi double [%dcarry, %inner.ph], [%md, %latch]
  %rf = phi float [%fcarry, %inner.ph], [%mf, %latch]
  %distance = sub nuw nsw i64 %iv, 7
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %base, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !25
left:
  %q = sdiv i32 840, %x
  %salted = xor i32 %q, %salt
  %lc = call i32 @scalar_helper(i32 %salted)
  %dp = getelementptr double, ptr %dbase, i64 %index
  %dx = load double, ptr %dp, align 8
  %ld = fmul double %dx, 3.0
  %lf = fptrunc double %ld to float
  %u0 = add i32 %r0, %lc
  %u1 = add i32 %lc, %r1
  %ud = fadd double %rd, %ld
  %uf = fadd float %rf, %lf
  br label %latch
right:
  %rc = xor i32 %x, 7
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [%rc, %right]
  %dc = phi double [%ld, %left], [-0.0, %right]
  %fc = phi float [%lf, %left], [-0.0, %right]
  %m0 = phi i32 [%u0, %left], [%r0, %right]
  %m1 = phi i32 [%u1, %left], [%r1, %right]
  %md = phi double [%ud, %left], [%rd, %right]
  %mf = phi float [%uf, %left], [%rf, %right]
  %next = add nuw nsw i64 %iv, 2
  %done = icmp uge i64 %next, %limit
  br i1 %done, label %row.exit, label %inner, !dbg !25
row.exit:
  %out.x = phi i32 [%x, %latch]
  %out.c = phi i32 [%c, %latch]
  %out.c.copy = phi i32 [%c, %latch]
  %out.iv = phi i64 [%iv, %latch]
  %out.next = phi i64 [%next, %latch]
  %out.dc = phi double [%dc, %latch]
  %out.fc = phi float [%fc, %latch]
  %out.r0 = phi i32 [%m0, %latch]
  %out.r1 = phi i32 [%m1, %latch]
  %out.rd = phi double [%md, %latch]
  %out.rf = phi float [%mf, %latch]
  %oi = mul nuw i64 %row, 5
  %di = mul nuw i64 %row, 2
  %o0 = getelementptr i32, ptr %out, i64 %oi
  store i32 %out.r0, ptr %o0, align 4
  %oi1 = add nuw i64 %oi, 1
  %o1 = getelementptr i32, ptr %out, i64 %oi1
  store i32 %out.r1, ptr %o1, align 4
  %oi2 = add nuw i64 %oi, 2
  %o2 = getelementptr i32, ptr %out, i64 %oi2
  store i32 %out.x, ptr %o2, align 4
  %oi3 = add nuw i64 %oi, 3
  %o3 = getelementptr i32, ptr %out, i64 %oi3
  store i32 %out.c, ptr %o3, align 4
  %oi4 = add nuw i64 %oi, 4
  %o4 = getelementptr i32, ptr %out, i64 %oi4
  store i32 %out.c.copy, ptr %o4, align 4
  %indices0 = getelementptr i64, ptr %indices, i64 %di
  store i64 %out.iv, ptr %indices0, align 8
  %di.next = add nuw i64 %di, 1
  %indices1 = getelementptr i64, ptr %indices, i64 %di.next
  store i64 %out.next, ptr %indices1, align 8
  %dout0 = getelementptr double, ptr %dout, i64 %di
  store double %out.rd, ptr %dout0, align 8
  %dout1 = getelementptr double, ptr %dout, i64 %di.next
  store double %out.dc, ptr %dout1, align 8
  %fout0 = getelementptr float, ptr %fout, i64 %di
  store float %out.rf, ptr %fout0, align 4
  %fout1 = getelementptr float, ptr %fout, i64 %di.next
  store float %out.fc, ptr %fout1, align 4
  %row.next = add nuw i64 %row, 1
  %rows.done = icmp eq i64 %row.next, %rows
  br i1 %rows.done, label %exit, label %outer
exit:
  ret void
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-export-controls.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!5 = !DISubroutineType(types: !6)
!6 = !{}
!10 = distinct !DISubprogram(name: "export_offset", scope: !1, file: !1, line: 10, type: !5, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 12, column: 3, scope: !10)
!12 = distinct !DISubprogram(name: "export_stride", scope: !1, file: !1, line: 20, type: !5, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 22, column: 3, scope: !12)
!14 = distinct !DISubprogram(name: "export_down", scope: !1, file: !1, line: 30, type: !5, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!15 = !DILocation(line: 32, column: 3, scope: !14)
!16 = distinct !DISubprogram(name: "export_current", scope: !1, file: !1, line: 40, type: !5, scopeLine: 40, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!17 = !DILocation(line: 42, column: 3, scope: !16)
!18 = distinct !DISubprogram(name: "export_affine_compact", scope: !1, file: !1, line: 50, type: !5, scopeLine: 50, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!19 = !DILocation(line: 52, column: 3, scope: !18)
!20 = distinct !DISubprogram(name: "export_serial", scope: !1, file: !1, line: 60, type: !5, scopeLine: 60, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!21 = !DILocation(line: 62, column: 3, scope: !20)
!22 = distinct !DISubprogram(name: "export_acyclic_nested", scope: !1, file: !1, line: 70, type: !5, scopeLine: 70, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!23 = !DILocation(line: 72, column: 3, scope: !22)
!24 = distinct !DISubprogram(name: "export_enclosing", scope: !1, file: !1, line: 80, type: !5, scopeLine: 80, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!25 = !DILocation(line: 82, column: 3, scope: !24)
