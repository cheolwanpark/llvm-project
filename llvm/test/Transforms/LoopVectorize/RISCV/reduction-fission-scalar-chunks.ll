; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=148 \
; RUN:   -pass-remarks=vplan-reduction-fission -S %s -o %t.scalar 2> %t.scalar.remarks
; RUN: FileCheck %s --check-prefix=SCALAR < %t.scalar
; RUN: FileCheck %s --check-prefix=REMARK < %t.scalar.remarks
; RUN: FileCheck %s --check-prefix=SVF < %t.scalar.remarks
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=4 -force-vector-interleave=1 \
; RUN:   -scalable-vectorization=always -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=148 \
; RUN:   -pass-remarks=vplan-reduction-fission -S %s -o %t.vector 2> %t.vector.remarks
; RUN: FileCheck %s --check-prefix=VECTOR < %t.vector
; RUN: FileCheck %s --check-prefix=VF < %t.vector.remarks
; RUN: FileCheck %s --check-prefix=REMARK < %t.vector.remarks
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.vector -o /dev/null
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=4 -force-vector-interleave=1 \
; RUN:   -scalable-vectorization=always -hints-allow-reordering=false \
; RUN:   -tail-folding-policy=dont-fold-tail -enable-epilogue-vectorization=false \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=148 \
; RUN:   -vplan-reduction-fission-allow-fp-reordering -pass-remarks=vplan-reduction-fission \
; RUN:   -S %s -o %t.repeat 2> %t.repeat.remarks
; RUN: FileCheck %s --check-prefix=VECTOR < %t.repeat
; RUN: FileCheck %s --check-prefix=REMARK < %t.repeat.remarks
; RUN: FileCheck %s --check-prefix=VF < %t.repeat.remarks
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.repeat -o /dev/null
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=19 -pass-remarks-missed=vplan-reduction-fission \
; RUN:   -S %s -o %t.reject 2> %t.reject.remarks
; RUN: FileCheck %s --check-prefix=REJECT < %t.reject.remarks
; RUN: FileCheck %s --check-prefix=UNCHANGED --implicit-check-not=scalar.fission < %t.reject
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=147 -pass-remarks=vplan-reduction-fission \
; RUN:   -disable-output %s 2>&1 | FileCheck %s --check-prefix=ALIGN
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=20 -pass-remarks=vplan-reduction-fission \
; RUN:   -disable-output %s 2>&1 | FileCheck %s --check-prefix=ROW
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=4084 -pass-remarks=vplan-reduction-fission \
; RUN:   -S %s -o %t.full 2> %t.full.remarks
; RUN: FileCheck %s --check-prefix=FULL < %t.full.remarks
; RUN: FileCheck %s --check-prefix=UNCHANGED --implicit-check-not=scalar.fission.chunk < %t.full
;
; Four analogous producers: EQ/NE exits, i64/i8 controls and an enclosing loop.
; The NE analogue has no no-wrap flags on its original global IV increment.
; Mixed streams are i32/double/float; the two integer reductions share c.
; Six producer values (seven exit operands) include actual global IVs.
; For C=9 size is 36 + 4 padding + 72 + 36 = 148; 147 admits C=8
; with 128 bytes. A single row needs 20 bytes, so 19 must still reject.
; Bounds are 65 except the narrow analogue, which executes through i8 255.
; Full-trip storage (1044/4084 bytes) and the ordered path remain when fit.
; The helper prevents original/producer vectorization without imposing a
; prerequisite on fission. The checker executes C=1,9,16, both FP policies,
; once/twice LV, vector consumers and scalar tails against IR and independent C.
; Scratch reuses entry allocations per chunk and per outer row, including when
; row stores alias future input. No input rereads or duplicated helper calls.
;
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

; REMARK: scalar-chunks.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 9, scratch bytes 148, producer live-outs 6, chunked schedule, trip bound 65
; REMARK-SAME: , scratch store bytes/iteration 16, scratch load bytes/iteration 16, producer reread bytes/iteration 0, duplicated producer instructions 0
; SVF: scalar-chunks.c:12:3: scalar-IR fission producer VF 1
; SVF: scalar-chunks.c:12:3: scalar-IR fission consumer VF 1
; VF: scalar-chunks.c:12:3: scalar-IR fission producer VF 1
; VF: scalar-chunks.c:12:3: scalar-IR fission consumer VF vscale x 4
; REJECT: scalar-chunks.c:12:3: scalar-IR reduction fission rejected: scalar-scratch-limit
; ALIGN: scalar-chunks.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 8, scratch bytes 128, producer live-outs 6, chunked schedule
; ROW: scalar-chunks.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 1, scratch bytes 20, producer live-outs 6, chunked schedule
; FULL: scalar-chunks.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; UNCHANGED-LABEL: define void @chunk_mixed(
; UNCHANGED: ret void
; SCALAR-LABEL: define void @chunk_mixed(
; SCALAR: alloca [9 x i32]
; SCALAR: alloca [9 x double]
; SCALAR: alloca [9 x float]
; SCALAR-NOT: alloca
; SCALAR: scalar.fission.chunk:
; SCALAR: %fission.chunk.base = phi i64 [ 0,
; SCALAR-DAG: %r0.chunk.carry = phi i32
; SCALAR-DAG: %r1.chunk.carry = phi i32
; SCALAR-DAG: %rd.chunk.carry = phi double
; SCALAR-DAG: %rf.chunk.carry = phi float
; SCALAR: %fission.chunk.remaining = sub nuw i64
; SCALAR: %fission.chunk.partial = icmp ult i64 %fission.chunk.remaining, 9
; SCALAR: %fission.chunk.count = select i1 %fission.chunk.partial, i64 %fission.chunk.remaining, i64 9
; SCALAR: scalar.fission.producer.ph:
; SCALAR: %fission.producer.ordinal = phi i64 [ 0, %scalar.fission.producer.ph ]
; SCALAR: call i32 @scalar_helper
; SCALAR: %fission.producer.next = add nuw i64 %fission.producer.ordinal, 1
; SCALAR: %fission.producer.more = icmp ne i64 %fission.producer.next, %fission.chunk.count
; SCALAR: br i1 %fission.producer.more, label %{{loop|inner}}, label %scalar.fission.consumer.ph
; SCALAR: scalar.fission.consumer.ph:
; SCALAR-DAG: %c.fission.export = phi i32
; SCALAR-DAG: %dc.fission.export = phi double
; SCALAR-DAG: %fc.fission.export = phi float
; SCALAR: scalar.fission.consumer.body:
; SCALAR-DAG: %r0.consume = phi i32 [ %r0.chunk.carry, %scalar.fission.consumer.ph ]
; SCALAR-DAG: %rd.consume = phi double [ %rd.chunk.carry, %scalar.fission.consumer.ph ]
; SCALAR: %u0.consume = add i32 %r0.consume,
; SCALAR: %u1.consume = add i32
; SCALAR: %ud.consume = fadd double %rd.consume,
; SCALAR: %uf.consume = fadd float %rf.consume,
; SCALAR: %fission.consumer.more = icmp ne i64 %fission.consumer.next, %fission.chunk.count
; SCALAR: br i1 %fission.consumer.more, label %scalar.fission.consumer.body, label %scalar.fission.chunk.latch
; SCALAR: scalar.fission.chunk.latch:
; SCALAR-DAG: %r0.chunk.result = phi i32 [ %u0.consume, %scalar.fission.consumer.body ]
; SCALAR-DAG: %r1.chunk.result = phi i32 [ %u1.consume, %scalar.fission.consumer.body ]
; SCALAR-DAG: %rd.chunk.result = phi double [ %ud.consume, %scalar.fission.consumer.body ]
; SCALAR-DAG: %rf.chunk.result = phi float [ %uf.consume, %scalar.fission.consumer.body ]
; SCALAR: %fission.chunk.next = add nuw i64 %fission.chunk.base, %fission.chunk.count
; SCALAR: br i1 %fission.chunk.more, label %scalar.fission.chunk,
; SCALAR: ret void
; VECTOR-LABEL: define void @chunk_mixed(
; VECTOR: scalar.fission.chunk:
; VECTOR: scalar.fission.consumer.ph:
; VECTOR: vector.body:
; VECTOR: call i32 @llvm.vector.reduce.add.nxv4i32
; VECTOR: scalar.fission.chunk.latch:
; VECTOR: ret void
define void @chunk_mixed(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
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

; REMARK: scalar-chunks.c:22:3: split scalar-IR reduction loop; {{.*}}scratch capacity 9, scratch bytes 148, producer live-outs 6, chunked schedule, trip bound 255
; REMARK-SAME: , scratch store bytes/iteration 16, scratch load bytes/iteration 16, producer reread bytes/iteration 0, duplicated producer instructions 0
; SVF: scalar-chunks.c:22:3: scalar-IR fission producer VF 1
; SVF: scalar-chunks.c:22:3: scalar-IR fission consumer VF 1
; VF: scalar-chunks.c:22:3: scalar-IR fission producer VF 1
; VF: scalar-chunks.c:22:3: scalar-IR fission consumer VF vscale x 4
; REJECT: scalar-chunks.c:22:3: scalar-IR reduction fission rejected: scalar-scratch-limit
; ALIGN: scalar-chunks.c:22:3: split scalar-IR reduction loop; {{.*}}scratch capacity 8, scratch bytes 128, producer live-outs 6, chunked schedule
; ROW: scalar-chunks.c:22:3: split scalar-IR reduction loop; {{.*}}scratch capacity 1, scratch bytes 20, producer live-outs 6, chunked schedule
; FULL: scalar-chunks.c:22:3: split scalar-IR reduction loop; {{.*}}scratch capacity 255, scratch bytes 4084, producer live-outs 6
; UNCHANGED-LABEL: define void @chunk_narrow(
; UNCHANGED: ret void
; SCALAR-LABEL: define void @chunk_narrow(
; SCALAR: alloca [9 x i32]
; SCALAR: alloca [9 x double]
; SCALAR: alloca [9 x float]
; SCALAR-NOT: alloca
; SCALAR: scalar.fission.chunk:
; SCALAR: %fission.chunk.base = phi i8 [ 0,
; SCALAR-DAG: %r0.chunk.carry = phi i32
; SCALAR-DAG: %r1.chunk.carry = phi i32
; SCALAR-DAG: %rd.chunk.carry = phi double
; SCALAR-DAG: %rf.chunk.carry = phi float
; SCALAR: %fission.chunk.remaining = sub nuw i8
; SCALAR: %fission.chunk.partial = icmp ult i8 %fission.chunk.remaining, 9
; SCALAR: %fission.chunk.count = select i1 %fission.chunk.partial, i8 %fission.chunk.remaining, i8 9
; SCALAR: scalar.fission.producer.ph:
; SCALAR: %fission.producer.ordinal = phi i8 [ 0, %scalar.fission.producer.ph ]
; SCALAR: call i32 @scalar_helper
; SCALAR: %fission.producer.next = add nuw i8 %fission.producer.ordinal, 1
; SCALAR: %fission.producer.more = icmp ne i8 %fission.producer.next, %fission.chunk.count
; SCALAR: br i1 %fission.producer.more, label %{{loop|inner}}, label %scalar.fission.consumer.ph
; SCALAR: scalar.fission.consumer.ph:
; SCALAR-DAG: %c.fission.export = phi i32
; SCALAR-DAG: %dc.fission.export = phi double
; SCALAR-DAG: %fc.fission.export = phi float
; SCALAR: scalar.fission.consumer.body:
; SCALAR-DAG: %r0.consume = phi i32 [ %r0.chunk.carry, %scalar.fission.consumer.ph ]
; SCALAR-DAG: %rd.consume = phi double [ %rd.chunk.carry, %scalar.fission.consumer.ph ]
; SCALAR: %u0.consume = add i32 %r0.consume,
; SCALAR: %u1.consume = add i32
; SCALAR: %ud.consume = fadd double %rd.consume,
; SCALAR: %uf.consume = fadd float %rf.consume,
; SCALAR: %fission.consumer.more = icmp ne i8 %fission.consumer.next, %fission.chunk.count
; SCALAR: br i1 %fission.consumer.more, label %scalar.fission.consumer.body, label %scalar.fission.chunk.latch
; SCALAR: scalar.fission.chunk.latch:
; SCALAR-DAG: %r0.chunk.result = phi i32 [ %u0.consume, %scalar.fission.consumer.body ]
; SCALAR-DAG: %r1.chunk.result = phi i32 [ %u1.consume, %scalar.fission.consumer.body ]
; SCALAR-DAG: %rd.chunk.result = phi double [ %ud.consume, %scalar.fission.consumer.body ]
; SCALAR-DAG: %rf.chunk.result = phi float [ %uf.consume, %scalar.fission.consumer.body ]
; SCALAR: %fission.chunk.next = add nuw i8 %fission.chunk.base, %fission.chunk.count
; SCALAR: br i1 %fission.chunk.more, label %scalar.fission.chunk,
; SCALAR: ret void
; VECTOR-LABEL: define void @chunk_narrow(
; VECTOR: scalar.fission.chunk:
; VECTOR: scalar.fission.consumer.ph:
; VECTOR: vector.body:
; VECTOR: call i32 @llvm.vector.reduce.add.nxv4i32
; VECTOR: scalar.fission.chunk.latch:
; VECTOR: ret void
define void @chunk_narrow(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                            ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !12 {
entry:
  %n8 = trunc i64 %n to i8
  %valid = icmp ule i8 %n8, 255
  %nonzero = icmp ne i8 %n8, 0
  %count.valid = icmp ule i64 %n, 255
  %count.enter = and i1 %valid, %nonzero
  %inner.enter = and i1 %count.valid, %count.enter
  %fstart = fptrunc double %start to float
  br i1 %inner.enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i8 [0, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %rf = phi float [%fstart, %preheader], [%uf, %loop]
  %wide = zext i8 %iv to i64
  %p = getelementptr i32, ptr %a, i64 %wide
  %x = load i32, ptr %p, align 4
  %c = call i32 @scalar_helper(i32 %x)
  %dp = getelementptr double, ptr %fp, i64 %wide
  %dx = load double, ptr %dp, align 8
  %dc = fmul double %dx, 3.0
  %fc = fptrunc double %dc to float
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  %next = add nuw i8 %iv, 1
  %wide.next = zext i8 %next to i64
  %done = icmp eq i8 %next, %n8
  br i1 %done, label %producer.exit, label %loop, !dbg !13
producer.exit:
  %out.x = phi i32 [%x, %loop]
  %out.c = phi i32 [%c, %loop]
  %out.c.copy = phi i32 [%c, %loop]
  %out.iv = phi i64 [%wide, %loop]
  %out.next = phi i64 [%wide.next, %loop]
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

; REMARK: scalar-chunks.c:32:3: split scalar-IR reduction loop; {{.*}}scratch capacity 9, scratch bytes 148, producer live-outs 6, chunked schedule, trip bound 65
; REMARK-SAME: , scratch store bytes/iteration 16, scratch load bytes/iteration 16, producer reread bytes/iteration 0, duplicated producer instructions 0
; SVF: scalar-chunks.c:32:3: scalar-IR fission producer VF 1
; SVF: scalar-chunks.c:32:3: scalar-IR fission consumer VF 1
; VF: scalar-chunks.c:32:3: scalar-IR fission producer VF 1
; VF: scalar-chunks.c:32:3: scalar-IR fission consumer VF vscale x 4
; REJECT: scalar-chunks.c:32:3: scalar-IR reduction fission rejected: scalar-scratch-limit
; ALIGN: scalar-chunks.c:32:3: split scalar-IR reduction loop; {{.*}}scratch capacity 8, scratch bytes 128, producer live-outs 6, chunked schedule
; ROW: scalar-chunks.c:32:3: split scalar-IR reduction loop; {{.*}}scratch capacity 1, scratch bytes 20, producer live-outs 6, chunked schedule
; FULL: scalar-chunks.c:32:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; UNCHANGED-LABEL: define void @chunk_ne(
; UNCHANGED: ret void
; SCALAR-LABEL: define void @chunk_ne(
; SCALAR: alloca [9 x i32]
; SCALAR: alloca [9 x double]
; SCALAR: alloca [9 x float]
; SCALAR-NOT: alloca
; SCALAR: scalar.fission.chunk:
; SCALAR: %fission.chunk.base = phi i64 [ 0,
; SCALAR-DAG: %r0.chunk.carry = phi i32
; SCALAR-DAG: %r1.chunk.carry = phi i32
; SCALAR-DAG: %rd.chunk.carry = phi double
; SCALAR-DAG: %rf.chunk.carry = phi float
; SCALAR: %fission.chunk.remaining = sub nuw i64
; SCALAR: %fission.chunk.partial = icmp ult i64 %fission.chunk.remaining, 9
; SCALAR: %fission.chunk.count = select i1 %fission.chunk.partial, i64 %fission.chunk.remaining, i64 9
; SCALAR: scalar.fission.producer.ph:
; SCALAR: %fission.producer.ordinal = phi i64 [ 0, %scalar.fission.producer.ph ]
; SCALAR: call i32 @scalar_helper
; SCALAR: %fission.producer.next = add nuw i64 %fission.producer.ordinal, 1
; SCALAR: %fission.producer.more = icmp ne i64 %fission.producer.next, %fission.chunk.count
; SCALAR: br i1 %fission.producer.more, label %{{loop|inner}}, label %scalar.fission.consumer.ph
; SCALAR: scalar.fission.consumer.ph:
; SCALAR-DAG: %c.fission.export = phi i32
; SCALAR-DAG: %dc.fission.export = phi double
; SCALAR-DAG: %fc.fission.export = phi float
; SCALAR: scalar.fission.consumer.body:
; SCALAR-DAG: %r0.consume = phi i32 [ %r0.chunk.carry, %scalar.fission.consumer.ph ]
; SCALAR-DAG: %rd.consume = phi double [ %rd.chunk.carry, %scalar.fission.consumer.ph ]
; SCALAR: %u0.consume = add i32 %r0.consume,
; SCALAR: %u1.consume = add i32
; SCALAR: %ud.consume = fadd double %rd.consume,
; SCALAR: %uf.consume = fadd float %rf.consume,
; SCALAR: %fission.consumer.more = icmp ne i64 %fission.consumer.next, %fission.chunk.count
; SCALAR: br i1 %fission.consumer.more, label %scalar.fission.consumer.body, label %scalar.fission.chunk.latch
; SCALAR: scalar.fission.chunk.latch:
; SCALAR-DAG: %r0.chunk.result = phi i32 [ %u0.consume, %scalar.fission.consumer.body ]
; SCALAR-DAG: %r1.chunk.result = phi i32 [ %u1.consume, %scalar.fission.consumer.body ]
; SCALAR-DAG: %rd.chunk.result = phi double [ %ud.consume, %scalar.fission.consumer.body ]
; SCALAR-DAG: %rf.chunk.result = phi float [ %uf.consume, %scalar.fission.consumer.body ]
; SCALAR: %fission.chunk.next = add nuw i64 %fission.chunk.base, %fission.chunk.count
; SCALAR: br i1 %fission.chunk.more, label %scalar.fission.chunk,
; SCALAR: ret void
; VECTOR-LABEL: define void @chunk_ne(
; VECTOR: scalar.fission.chunk:
; VECTOR: scalar.fission.consumer.ph:
; VECTOR: vector.body:
; VECTOR: call i32 @llvm.vector.reduce.add.nxv4i32
; VECTOR: scalar.fission.chunk.latch:
; VECTOR: ret void
define void @chunk_ne(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
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
  %next = add i64 %iv, 1
  %done = icmp ne i64 %next, %n
  br i1 %done, label %loop, label %producer.exit, !dbg !15
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

; REMARK: scalar-chunks.c:42:3: split scalar-IR reduction loop; {{.*}}scratch capacity 9, scratch bytes 148, producer live-outs 6, chunked schedule, trip bound 65
; REMARK-SAME: , scratch store bytes/iteration 16, scratch load bytes/iteration 16, producer reread bytes/iteration 0, duplicated producer instructions 0
; SVF: scalar-chunks.c:42:3: scalar-IR fission producer VF 1
; SVF: scalar-chunks.c:42:3: scalar-IR fission consumer VF 1
; VF: scalar-chunks.c:42:3: scalar-IR fission producer VF 1
; VF: scalar-chunks.c:42:3: scalar-IR fission consumer VF vscale x 4
; REJECT: scalar-chunks.c:42:3: scalar-IR reduction fission rejected: scalar-scratch-limit
; ALIGN: scalar-chunks.c:42:3: split scalar-IR reduction loop; {{.*}}scratch capacity 8, scratch bytes 128, producer live-outs 6, chunked schedule
; ROW: scalar-chunks.c:42:3: split scalar-IR reduction loop; {{.*}}scratch capacity 1, scratch bytes 20, producer live-outs 6, chunked schedule
; FULL: scalar-chunks.c:42:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044, producer live-outs 6
; UNCHANGED-LABEL: define void @chunk_nested(
; UNCHANGED: ret void
; SCALAR-LABEL: define void @chunk_nested(
; SCALAR: alloca [9 x i32]
; SCALAR: alloca [9 x double]
; SCALAR: alloca [9 x float]
; SCALAR-NOT: alloca
; SCALAR: scalar.fission.chunk:
; SCALAR: %fission.chunk.base = phi i64 [ 0,
; SCALAR-DAG: %r0.chunk.carry = phi i32
; SCALAR-DAG: %r1.chunk.carry = phi i32
; SCALAR-DAG: %rd.chunk.carry = phi double
; SCALAR-DAG: %rf.chunk.carry = phi float
; SCALAR: %fission.chunk.remaining = sub nuw i64
; SCALAR: %fission.chunk.partial = icmp ult i64 %fission.chunk.remaining, 9
; SCALAR: %fission.chunk.count = select i1 %fission.chunk.partial, i64 %fission.chunk.remaining, i64 9
; SCALAR: scalar.fission.producer.ph:
; SCALAR: %fission.producer.ordinal = phi i64 [ 0, %scalar.fission.producer.ph ]
; SCALAR: call i32 @scalar_helper
; SCALAR: %fission.producer.next = add nuw i64 %fission.producer.ordinal, 1
; SCALAR: %fission.producer.more = icmp ne i64 %fission.producer.next, %fission.chunk.count
; SCALAR: br i1 %fission.producer.more, label %{{loop|inner}}, label %scalar.fission.consumer.ph
; SCALAR: scalar.fission.consumer.ph:
; SCALAR-DAG: %c.fission.export = phi i32
; SCALAR-DAG: %dc.fission.export = phi double
; SCALAR-DAG: %fc.fission.export = phi float
; SCALAR: scalar.fission.consumer.body:
; SCALAR-DAG: %r0.consume = phi i32 [ %r0.chunk.carry, %scalar.fission.consumer.ph ]
; SCALAR-DAG: %rd.consume = phi double [ %rd.chunk.carry, %scalar.fission.consumer.ph ]
; SCALAR: %u0.consume = add i32 %r0.consume,
; SCALAR: %u1.consume = add i32
; SCALAR: %ud.consume = fadd double %rd.consume,
; SCALAR: %uf.consume = fadd float %rf.consume,
; SCALAR: %fission.consumer.more = icmp ne i64 %fission.consumer.next, %fission.chunk.count
; SCALAR: br i1 %fission.consumer.more, label %scalar.fission.consumer.body, label %scalar.fission.chunk.latch
; SCALAR: scalar.fission.chunk.latch:
; SCALAR-DAG: %r0.chunk.result = phi i32 [ %u0.consume, %scalar.fission.consumer.body ]
; SCALAR-DAG: %r1.chunk.result = phi i32 [ %u1.consume, %scalar.fission.consumer.body ]
; SCALAR-DAG: %rd.chunk.result = phi double [ %ud.consume, %scalar.fission.consumer.body ]
; SCALAR-DAG: %rf.chunk.result = phi float [ %uf.consume, %scalar.fission.consumer.body ]
; SCALAR: %fission.chunk.next = add nuw i64 %fission.chunk.base, %fission.chunk.count
; SCALAR: br i1 %fission.chunk.more, label %scalar.fission.chunk,
; SCALAR: ret void
; VECTOR-LABEL: define void @chunk_nested(
; VECTOR: scalar.fission.chunk:
; VECTOR: scalar.fission.consumer.ph:
; VECTOR: vector.body:
; VECTOR: call i32 @llvm.vector.reduce.add.nxv4i32
; VECTOR: scalar.fission.chunk.latch:
; VECTOR: ret void
define void @chunk_nested(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
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
  %iv = phi i64 [0, %inner.ph], [%next, %inner]
  %r0 = phi i32 [%carry, %inner.ph], [%u0, %inner]
  %r1 = phi i32 [%carry1, %inner.ph], [%u1, %inner]
  %rd = phi double [%dcarry, %inner.ph], [%ud, %inner]
  %rf = phi float [%fcarry, %inner.ph], [%uf, %inner]
  %p = getelementptr i32, ptr %base, i64 %iv
  %x = load i32, ptr %p, align 4
  %salted = xor i32 %x, %salt
  %c = call i32 @scalar_helper(i32 %salted)
  %dp = getelementptr double, ptr %dbase, i64 %iv
  %dx = load double, ptr %dp, align 8
  %dc = fmul double %dx, 3.0
  %fc = fptrunc double %dc to float
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %row.exit, label %inner, !dbg !17
row.exit:
  %out.x = phi i32 [%x, %inner]
  %out.c = phi i32 [%c, %inner]
  %out.c.copy = phi i32 [%c, %inner]
  %out.iv = phi i64 [%iv, %inner]
  %out.next = phi i64 [%next, %inner]
  %out.dc = phi double [%dc, %inner]
  %out.fc = phi float [%fc, %inner]
  %out.r0 = phi i32 [%u0, %inner]
  %out.r1 = phi i32 [%u1, %inner]
  %out.rd = phi double [%ud, %inner]
  %out.rf = phi float [%uf, %inner]
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
!1 = !DIFile(filename: "scalar-chunks.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!5 = !DISubroutineType(types: !6)
!6 = !{}
!10 = distinct !DISubprogram(name: "chunk_mixed", scope: !1, file: !1, line: 10, type: !5, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 12, column: 3, scope: !10)
!12 = distinct !DISubprogram(name: "chunk_narrow", scope: !1, file: !1, line: 20, type: !5, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 22, column: 3, scope: !12)
!14 = distinct !DISubprogram(name: "chunk_ne", scope: !1, file: !1, line: 30, type: !5, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!15 = !DILocation(line: 32, column: 3, scope: !14)
!16 = distinct !DISubprogram(name: "chunk_nested", scope: !1, file: !1, line: 40, type: !5, scopeLine: 40, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!17 = !DILocation(line: 42, column: 3, scope: !16)
; REMARK-NOT: : split
; FULL-NOT: chunked schedule
