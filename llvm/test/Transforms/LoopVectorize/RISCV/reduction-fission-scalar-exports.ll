; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -pass-remarks=vplan-reduction-fission \
; RUN:   -S %s -o %t.scalar 2> %t.scalar.remarks
; RUN: FileCheck %s --check-prefix=SCALAR --implicit-check-not='<vscale x' < %t.scalar
; RUN: FileCheck %s --check-prefix=SCALAR-REMARK < %t.scalar.remarks
; RUN: FileCheck %s --check-prefix=SELECTED < %t.scalar.remarks
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=4 -force-vector-interleave=1 \
; RUN:   -scalable-vectorization=always -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -pass-remarks=vplan-reduction-fission \
; RUN:   -S %s -o %t 2> %t.remarks
; RUN: FileCheck %s --check-prefix=VECTOR < %t
; RUN: FileCheck %s --check-prefix=REMARK < %t.remarks
; RUN: FileCheck %s --check-prefix=SELECTED < %t.remarks
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t -o /dev/null
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=4 -force-vector-interleave=1 \
; RUN:   -scalable-vectorization=always -hints-allow-reordering=false \
; RUN:   -tail-folding-policy=dont-fold-tail -enable-epilogue-vectorization=false \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-allow-fp-reordering \
; RUN:   -pass-remarks=vplan-reduction-fission -S %s -o %t.repeat 2> %t.repeat.remarks
; RUN: FileCheck %s --check-prefix=VECTOR < %t.repeat
; RUN: FileCheck %s --check-prefix=REMARK < %t.repeat.remarks
; RUN: FileCheck %s --check-prefix=SELECTED < %t.repeat.remarks
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.repeat -o /dev/null
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=1043 -pass-remarks-missed=vplan-reduction-fission -pass-remarks=vplan-reduction-fission \
; RUN:   -S %s -o %t.limit 2> %t.limit.remarks
; RUN: FileCheck %s --check-prefix=LIMIT < %t.limit.remarks
; RUN: FileCheck %s --check-prefix=LIMIT-IR < %t.limit
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.limit -o /dev/null
; RUN: opt -passes='loop-vectorize,verify<loops>' -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -force-vector-width=4 -force-vector-interleave=1 -scalable-vectorization=always \
; RUN:   -hints-allow-reordering=false -S %s | FileCheck %s --check-prefix=ORIGINAL \
; RUN:   --implicit-check-not=scalar.fission --implicit-check-not='<vscale x'
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=1 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -S %s | FileCheck %s --check-prefix=ORIGINAL \
; RUN:   --implicit-check-not=scalar.fission --implicit-check-not='<vscale x'
;
; IC=0 leaves interleaving unspecified for scalar fission dispatch; the target
; cap keeps the generated consumer scalar. Fixed VF=1 plus IC=1 means that
; vectorization and interleaving are both disabled in LoopVectorizeHints and
; must also prevent fission. The final RUN preserves that distinct contract.
; Each enabled scalar/vector RUN must select exactly the four original loops,
; including after repeated ordinary LV; stages are never new selections.
; SELECTED-COUNT-4: : split scalar-IR reduction loop;
; SELECTED-NOT: : split
;
; Actual final producer values, rather than the last compact contribution.
; Each function observes both reduction results, the final load/computation,
; current/next IVs and ordered float/double values. Two exit PHIs export c,
; requiring only one producer forwarding PHI. The scalar helper prevents the
; original loop and producer from vectorizing. It is called once, on exactly
; its original branch; its contract has no vector mapping or errno assumption.
; The compact inactive path has an invalid divisor and may have a null FP
; input. It exports its own final values even for N>0,P=0, without an add.
; check-reduction-fission.py executes single/repeated ordinary LV scalar-tail
; variants at fixed host vscales, against original IR AND independent C.
; EVL/VP is separately RVV machine verified, not executed on the host.
;
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

; REMARK: scalar-exports.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; REMARK: scalar-exports.c:12:3: scalar-IR fission producer VF 1
; REMARK: scalar-exports.c:12:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-REMARK: scalar-exports.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; SCALAR-REMARK: scalar-exports.c:12:3: scalar-IR fission producer VF 1
; SCALAR-REMARK: scalar-exports.c:12:3: scalar-IR fission consumer VF 1
; Canonical single-block and compact export loops chunk at the old limit.
; The unconditional multi-block producer retains its storage rejection.
; LIMIT: scalar-exports.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 64, scratch bytes 1024, producer live-outs 6, chunked schedule
; LIMIT-IR-LABEL: define void @export_unconditional(
; LIMIT-IR: alloca [64 x i32]
; LIMIT-IR: alloca [64 x double]
; LIMIT-IR: alloca [64 x float]
; LIMIT-IR: ret void
; SCALAR-LABEL: define void @export_unconditional(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR: alloca [65 x float]
; SCALAR-NOT: alloca
; SCALAR: call i32 @scalar_helper
; SCALAR: scalar.fission.consumer.ph:
; SCALAR-DAG: %x.fission.export = phi i32 [ %x, %loop ]
; SCALAR-DAG: %c.fission.export = phi i32 [ %c, %loop ]
; SCALAR-DAG: %iv.fission.export = phi i64 [ %iv, %loop ]
; SCALAR-DAG: %next.fission.export = phi i64 [ %next, %loop ]
; SCALAR-DAG: %dc.fission.export = phi double [ %dc, %loop ]
; SCALAR-DAG: %fc.fission.export = phi float [ %fc, %loop ]
; SCALAR: producer.exit:
; SCALAR: %out.x = phi i32 [ %x.fission.export, %scalar.fission.consumer.body ]
; SCALAR: %out.c = phi i32 [ %c.fission.export, %scalar.fission.consumer.body ]
; SCALAR: %out.c.copy = phi i32 [ %c.fission.export, %scalar.fission.consumer.body ]
; SCALAR: %out.iv = phi i64 [ %iv.fission.export, %scalar.fission.consumer.body ]
; SCALAR: %out.next = phi i64 [ %next.fission.export, %scalar.fission.consumer.body ]
; SCALAR: %out.dc = phi double [ %dc.fission.export, %scalar.fission.consumer.body ]
; SCALAR: %out.fc = phi float [ %fc.fission.export, %scalar.fission.consumer.body ]
; SCALAR: ret void
; VECTOR-LABEL: define void @export_unconditional(
; VECTOR: scalar.fission.consumer.ph:
; VECTOR: vector.ph:
; VECTOR: vector.body:
; VECTOR: call i32 @llvm.vector.reduce.add.nxv4i32
; VECTOR: store i32
; VECTOR: ret void
; ORIGINAL-LABEL: define void @export_unconditional(
; ORIGINAL: call i32 @scalar_helper
; ORIGINAL: ret void
define void @export_unconditional(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                            ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !10 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %inner.enter, label %preheader, label %exit
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

; REMARK: scalar-exports.c:22:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; REMARK: scalar-exports.c:22:3: scalar-IR fission producer VF 1
; REMARK: scalar-exports.c:22:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-REMARK: scalar-exports.c:22:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; SCALAR-REMARK: scalar-exports.c:22:3: scalar-IR fission producer VF 1
; SCALAR-REMARK: scalar-exports.c:22:3: scalar-IR fission consumer VF 1
; LIMIT: scalar-exports.c:22:3: scalar-IR reduction fission rejected: scalar-scratch-limit
; LIMIT-IR-LABEL: define void @export_diamond(
; LIMIT-IR-NOT: scalar.fission
; LIMIT-IR: ret void
; SCALAR-LABEL: define void @export_diamond(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR: alloca [65 x float]
; SCALAR-NOT: alloca
; SCALAR: call i32 @scalar_helper
; SCALAR: scalar.fission.consumer.ph:
; SCALAR-DAG: %x.fission.export = phi i32 [ %x, %latch ]
; SCALAR-DAG: %c.fission.export = phi i32 [ %c, %latch ]
; SCALAR-DAG: %iv.fission.export = phi i64 [ %iv, %latch ]
; SCALAR-DAG: %next.fission.export = phi i64 [ %next, %latch ]
; SCALAR-DAG: %dc.fission.export = phi double [ %dc, %latch ]
; SCALAR-DAG: %fc.fission.export = phi float [ %fc, %latch ]
; SCALAR: producer.exit:
; SCALAR: %out.x = phi i32 [ %x.fission.export, %scalar.fission.consumer.body ]
; SCALAR: %out.c = phi i32 [ %c.fission.export, %scalar.fission.consumer.body ]
; SCALAR: %out.c.copy = phi i32 [ %c.fission.export, %scalar.fission.consumer.body ]
; SCALAR: %out.iv = phi i64 [ %iv.fission.export, %scalar.fission.consumer.body ]
; SCALAR: %out.next = phi i64 [ %next.fission.export, %scalar.fission.consumer.body ]
; SCALAR: %out.dc = phi double [ %dc.fission.export, %scalar.fission.consumer.body ]
; SCALAR: %out.fc = phi float [ %fc.fission.export, %scalar.fission.consumer.body ]
; SCALAR: ret void
; VECTOR-LABEL: define void @export_diamond(
; VECTOR: scalar.fission.consumer.ph:
; VECTOR: vector.ph:
; VECTOR: vector.body:
; VECTOR: call i32 @llvm.vector.reduce.add.nxv4i32
; VECTOR: store i32
; VECTOR: ret void
; ORIGINAL-LABEL: define void @export_diamond(
; ORIGINAL: call i32 @scalar_helper
; ORIGINAL: ret void
define void @export_diamond(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                            ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !12 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %inner.enter, label %preheader, label %exit
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
  %dp = getelementptr double, ptr %fp, i64 %iv
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
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
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

; REMARK: scalar-exports.c:32:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; REMARK: scalar-exports.c:32:3: scalar-IR fission producer VF 1
; REMARK: scalar-exports.c:32:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-REMARK: scalar-exports.c:32:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; SCALAR-REMARK: scalar-exports.c:32:3: scalar-IR fission producer VF 1
; SCALAR-REMARK: scalar-exports.c:32:3: scalar-IR fission consumer VF 1
; Compact export storage at ceiling 1043 now uses C=64/B=1024, preserving the
; six final producer values even on empty chunks and a final inactive path.
; LIMIT: scalar-exports.c:32:3: split scalar-IR reduction loop; {{.*}}scratch capacity 64, scratch bytes 1024, producer live-outs 6, chunked schedule
; LIMIT: scalar-exports.c:32:3: scalar-IR fission producer VF 1
; LIMIT: scalar-exports.c:32:3: scalar-IR fission consumer VF vscale x 2
; LIMIT-IR-LABEL: define void @export_compact(
; LIMIT-IR: alloca [64 x i32]
; LIMIT-IR: alloca [64 x double]
; LIMIT-IR: alloca [64 x float]
; LIMIT-IR: %fission.participating = phi i64 [ 0, %scalar.fission.producer.ph ], [ %fission.participating.merge, %latch ]
; LIMIT-IR: scalar.fission.consumer.guard:
; LIMIT-IR-DAG: %x.fission.export = phi i32 [ %x, %latch ]
; LIMIT-IR-DAG: %c.fission.export = phi i32 [ %c, %latch ]
; LIMIT-IR-DAG: %iv.fission.export = phi i64 [ %iv, %latch ]
; LIMIT-IR-DAG: %next.fission.export = phi i64 [ %next, %latch ]
; LIMIT-IR-DAG: %dc.fission.export = phi double [ %dc, %latch ]
; LIMIT-IR-DAG: %fc.fission.export = phi float [ %fc, %latch ]
; LIMIT-IR: %fission.empty = icmp eq i64 %fission.participating.count, 0
; LIMIT-IR: scalar.fission.consumer.exit:
; LIMIT-IR: %rd.result = phi double [ %rd.chunk.carry, %scalar.fission.consumer.guard ],
; LIMIT-IR: producer.exit:
; LIMIT-IR-DAG: %out.iv = phi i64 [ %iv.fission.export, %scalar.fission.chunk.latch ]
; LIMIT-IR-DAG: %out.next = phi i64 [ %next.fission.export, %scalar.fission.chunk.latch ]
; LIMIT-IR: ret void
; SCALAR-LABEL: define void @export_compact(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR: alloca [65 x float]
; SCALAR-NOT: alloca
; SCALAR: call i32 @scalar_helper
; SCALAR: scalar.fission.consumer.guard:
; SCALAR-DAG: %x.fission.export = phi i32 [ %x, %latch ]
; SCALAR-DAG: %c.fission.export = phi i32 [ %c, %latch ]
; SCALAR-DAG: %iv.fission.export = phi i64 [ %iv, %latch ]
; SCALAR-DAG: %next.fission.export = phi i64 [ %next, %latch ]
; SCALAR-DAG: %dc.fission.export = phi double [ %dc, %latch ]
; SCALAR-DAG: %fc.fission.export = phi float [ %fc, %latch ]
; SCALAR: producer.exit:
; SCALAR: %out.x = phi i32 [ %x.fission.export, %scalar.fission.consumer.exit ]
; SCALAR: %out.c = phi i32 [ %c.fission.export, %scalar.fission.consumer.exit ]
; SCALAR: %out.c.copy = phi i32 [ %c.fission.export, %scalar.fission.consumer.exit ]
; SCALAR: %out.iv = phi i64 [ %iv.fission.export, %scalar.fission.consumer.exit ]
; SCALAR: %out.next = phi i64 [ %next.fission.export, %scalar.fission.consumer.exit ]
; SCALAR: %out.dc = phi double [ %dc.fission.export, %scalar.fission.consumer.exit ]
; SCALAR: %out.fc = phi float [ %fc.fission.export, %scalar.fission.consumer.exit ]
; SCALAR: ret void
; VECTOR-LABEL: define void @export_compact(
; VECTOR: scalar.fission.consumer.guard:
; VECTOR: scalar.fission.consumer.ph:
; VECTOR: vector.body:
; VECTOR: call i32 @llvm.vector.reduce.add.nxv4i32
; VECTOR: store i32
; VECTOR: ret void
; ORIGINAL-LABEL: define void @export_compact(
; ORIGINAL: call i32 @scalar_helper
; ORIGINAL: ret void
define void @export_compact(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                            ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !14 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %inner.enter, label %preheader, label %exit
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
  br i1 %choose, label %left, label %right, !dbg !15
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %dp = getelementptr double, ptr %fp, i64 %iv
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
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %producer.exit, label %loop, !dbg !15
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

; REMARK: scalar-exports.c:42:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; REMARK: scalar-exports.c:42:3: scalar-IR fission producer VF 1
; REMARK: scalar-exports.c:42:3: scalar-IR fission consumer VF vscale x 4
; SCALAR-REMARK: scalar-exports.c:42:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; SCALAR-REMARK: scalar-exports.c:42:3: scalar-IR fission producer VF 1
; SCALAR-REMARK: scalar-exports.c:42:3: scalar-IR fission consumer VF 1
; The same canonical compact schedule is reused independently in every row.
; LIMIT: scalar-exports.c:42:3: split scalar-IR reduction loop; {{.*}}scratch capacity 64, scratch bytes 1024, producer live-outs 6, chunked schedule
; LIMIT: scalar-exports.c:42:3: scalar-IR fission producer VF 1
; LIMIT: scalar-exports.c:42:3: scalar-IR fission consumer VF vscale x 2
; LIMIT-IR-LABEL: define void @export_nested(
; LIMIT-IR: alloca [64 x i32]
; LIMIT-IR: alloca [64 x double]
; LIMIT-IR: alloca [64 x float]
; LIMIT-IR: scalar.fission.consumer.guard:
; LIMIT-IR: %fission.empty = icmp eq i64 %fission.participating.count, 0
; LIMIT-IR: scalar.fission.consumer.exit:
; LIMIT-IR: %rd.result = phi double [ %rd.chunk.carry, %scalar.fission.consumer.guard ],
; LIMIT-IR: row.exit:
; LIMIT-IR-DAG: %out.iv = phi i64 [ %iv.fission.export, %scalar.fission.chunk.latch ]
; LIMIT-IR-DAG: %out.next = phi i64 [ %next.fission.export, %scalar.fission.chunk.latch ]
; LIMIT-IR: ret void
; SCALAR-LABEL: define void @export_nested(
; SCALAR: alloca [65 x i32]
; SCALAR: alloca [65 x double]
; SCALAR: alloca [65 x float]
; SCALAR-NOT: alloca
; SCALAR: call i32 @scalar_helper
; SCALAR: scalar.fission.consumer.guard:
; SCALAR-DAG: %x.fission.export = phi i32 [ %x, %latch ]
; SCALAR-DAG: %c.fission.export = phi i32 [ %c, %latch ]
; SCALAR-DAG: %iv.fission.export = phi i64 [ %iv, %latch ]
; SCALAR-DAG: %next.fission.export = phi i64 [ %next, %latch ]
; SCALAR-DAG: %dc.fission.export = phi double [ %dc, %latch ]
; SCALAR-DAG: %fc.fission.export = phi float [ %fc, %latch ]
; SCALAR: row.exit:
; SCALAR: %out.x = phi i32 [ %x.fission.export, %scalar.fission.consumer.exit ]
; SCALAR: %out.c = phi i32 [ %c.fission.export, %scalar.fission.consumer.exit ]
; SCALAR: %out.c.copy = phi i32 [ %c.fission.export, %scalar.fission.consumer.exit ]
; SCALAR: %out.iv = phi i64 [ %iv.fission.export, %scalar.fission.consumer.exit ]
; SCALAR: %out.next = phi i64 [ %next.fission.export, %scalar.fission.consumer.exit ]
; SCALAR: %out.dc = phi double [ %dc.fission.export, %scalar.fission.consumer.exit ]
; SCALAR: %out.fc = phi float [ %fc.fission.export, %scalar.fission.consumer.exit ]
; SCALAR: ret void
; VECTOR-LABEL: define void @export_nested(
; VECTOR: scalar.fission.consumer.guard:
; VECTOR: scalar.fission.consumer.ph:
; VECTOR: vector.body:
; VECTOR: call i32 @llvm.vector.reduce.add.nxv4i32
; VECTOR: store i32
; VECTOR: ret void
; ORIGINAL-LABEL: define void @export_nested(
; ORIGINAL: call i32 @scalar_helper
; ORIGINAL: ret void
define void @export_nested(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                            ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !16 {
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
  br label %inner
inner:
  %iv = phi i64 [0, %inner.ph], [%next, %latch]
  %r0 = phi i32 [%carry, %inner.ph], [%m0, %latch]
  %r1 = phi i32 [%carry1, %inner.ph], [%m1, %latch]
  %rd = phi double [%dcarry, %inner.ph], [%md, %latch]
  %rf = phi float [%fcarry, %inner.ph], [%mf, %latch]
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !17
left:
  %q = sdiv i32 840, %x
  %salted = xor i32 %q, %salt
  %lc = call i32 @scalar_helper(i32 %salted)
  %dp = getelementptr double, ptr %dbase, i64 %iv
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
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %row.exit, label %inner, !dbg !17
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
!1 = !DIFile(filename: "scalar-exports.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!5 = !DISubroutineType(types: !6)
!6 = !{}
!10 = distinct !DISubprogram(name: "export_unconditional", scope: !1, file: !1, line: 10, type: !5, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 12, column: 3, scope: !10)
!12 = distinct !DISubprogram(name: "export_diamond", scope: !1, file: !1, line: 20, type: !5, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 22, column: 3, scope: !12)
!14 = distinct !DISubprogram(name: "export_compact", scope: !1, file: !1, line: 30, type: !5, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!15 = !DILocation(line: 32, column: 3, scope: !14)
!16 = distinct !DISubprogram(name: "export_nested", scope: !1, file: !1, line: 40, type: !5, scopeLine: 40, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!17 = !DILocation(line: 42, column: 3, scope: !16)
