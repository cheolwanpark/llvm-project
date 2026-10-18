; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=1044 \
; RUN:   -pass-remarks=vplan-reduction-fission -S %s -o %t.ll 2> %t.remarks
; RUN: FileCheck %s --check-prefix=IR < %t.ll
; RUN: FileCheck %s --check-prefix=SELECT < %t.remarks
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=1043 -pass-remarks=vplan-reduction-fission \
; RUN:   -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.budget 2> %t.budget.remarks
; RUN: FileCheck %s --check-prefix=BUDGET < %t.budget.remarks
; RUN: FileCheck %s --check-prefix=BUDGET-IR < %t.budget
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=147 -pass-remarks=vplan-reduction-fission \
; RUN:   -disable-output %s 2>&1 | FileCheck %s --check-prefix=PAD
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=19 -pass-remarks-missed=vplan-reduction-fission \
; RUN:   -S %s -o %t.reject 2> %t.reject.remarks
; RUN: FileCheck %s --check-prefix=MIN < %t.reject.remarks
; RUN: FileCheck %s --check-prefix=NONE --implicit-check-not=scalar.fission < %t.reject
;
; Direct ordered subtraction, mixed with addition sharing the integer stream.
; Preserve original loads, overwrites, loop-carried memory, final producer
; exports and exact participation. No negation/add normalization or FP flags.
; Three streams: 1044 padded bytes at capacity65, 20/148/256 at C=1/9/16.
; The canonical compact gate now chunks at ceiling 1043: C=64/1024 bytes.
; Ordered sub/fsub and empty forwarding stay exact. Affine control also uses
; bounded chunks with original termination/IV; 19 still cannot fit one entry.
; The mandatory host checker executes original/transformed/independent versions
; with entire-state comparisons, exact scalar stage probes, aliases and canaries.
; Flagged subtraction starts at4096 and consumes c&3, so both nowrap contracts
; hold for every executed input. Unflagged cases exercise modular subtraction.
; Forced scalar stages are deliberate; ordinary LV chooses stage VFs separately.
;
; SELECT: scalar-subtraction.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 1044
; SELECT: scalar-subtraction.c:12:3: scalar-IR fission producer VF 1
; SELECT: scalar-subtraction.c:12:3: scalar-IR fission consumer VF 1
; SELECT: scalar-subtraction.c:32:3: split scalar-IR reduction loop
; SELECT: scalar-subtraction.c:62:3: split scalar-IR reduction loop
; SELECT: scalar-subtraction.c:72:3: split scalar-IR reduction loop
; BUDGET: scalar-subtraction.c:32:3: split scalar-IR reduction loop; {{.*}}scratch capacity 64, scratch bytes 1024, producer live-outs 6, chunked schedule, trip bound 65
; BUDGET-SAME: scratch store bytes/iteration 16, scratch load bytes/iteration 16, producer reread bytes/iteration 0, duplicated producer instructions 0
; BUDGET: scalar-subtraction.c:32:3: scalar-IR fission producer VF 1
; BUDGET: scalar-subtraction.c:32:3: scalar-IR fission consumer VF 1
; BUDGET: scalar-subtraction.c:62:3: split scalar-IR reduction loop; {{.*}}scratch capacity 64, scratch bytes 1024
; BUDGET-IR-LABEL: define void @stores_compact(
; BUDGET-IR: alloca [64 x i32]
; BUDGET-IR: alloca [64 x double]
; BUDGET-IR: alloca [64 x float]
; BUDGET-IR: scalar.fission.chunk:
; BUDGET-IR: %fission.chunk.partial = icmp ult i64 %fission.chunk.remaining, 64
; BUDGET-IR: %fission.chunk.count = select i1 %fission.chunk.partial, i64 %fission.chunk.remaining, i64 64
; BUDGET-IR: %fission.participating = phi i64 [ 0, %scalar.fission.producer.ph ],
; BUDGET-IR: gate:
; BUDGET-IR: br label %left
; BUDGET-IR: scalar.fission.consumer.guard:
; BUDGET-IR: %fission.empty = icmp eq i64 %fission.participating.count, 0
; BUDGET-IR: scalar.fission.consumer.body:
; BUDGET-IR: %u0.consume = sub i32 %r0.consume,
; BUDGET-IR: %ud.consume = fsub double %rd.consume,
; BUDGET-IR: %uf.consume = fsub float %rf.consume,
; BUDGET-IR: %fission.chunk.next = add nuw i64 %fission.chunk.base, %fission.producer.completed
; BUDGET-IR-LABEL: define void @stores_affine(
; BUDGET-IR: alloca [64 x i32]
; BUDGET-IR: alloca [64 x double]
; BUDGET-IR: alloca [64 x float]
; BUDGET-IR: scalar.fission.chunk:
; BUDGET-IR-NOT: fission.chunk.remaining
; BUDGET-IR: %control = phi i64
; BUDGET-IR: %fission.producer.iv.next = phi i64 [ %control.next, %loop ]
; BUDGET-IR: scalar.fission.consumer.body:
; BUDGET-IR: %ud.consume = fsub double %rd.consume,
; BUDGET-IR: br i1 %fission.producer.continue, label %scalar.fission.chunk, label %producer.exit
; BUDGET-IR: ret void
; BUDGET-IR: }
; PAD: scalar-subtraction.c:42:3: split scalar-IR reduction loop; {{.*}}scratch capacity 8, scratch bytes 128
; MIN: scalar-subtraction.c:12:3: scalar-IR reduction fission rejected: scalar-scratch-limit
; MIN: scalar-subtraction.c:32:3: scalar-IR reduction fission rejected: scalar-scratch-limit
; NONE-LABEL: define void @stores_full(
; NONE: ret void
; IR-LABEL: define void @stores_full(
; IR: scalar.fission.consumer.body:
; IR: %u0.consume = sub i32 %r0.consume, {{%[-a-zA-Z0-9.]+}}, !dbg ![[LOC:[0-9]+]]
; IR: %u1.consume = add i32
; IR: %ud.consume = fsub double %rd.consume,
; IR: %uf.consume = fsub float %rf.consume,
; IR-LABEL: define void @stores_compact(
; IR: gate:
; IR: br label %left
; IR: %fission.empty = icmp eq i64
; IR: %ud.consume = fsub double %rd.consume,
; IR-LABEL: define void @stores_affine(
; IR: %fission.ordinal = phi i64
; IR: %control = phi i64
; IR: %fission.completed.count = phi i64
; IR: %u0.consume = sub i32 %r0.consume,
; IR-LABEL: define void @stores_flags(
; IR: %u0.consume = sub nuw nsw i32 %r0.consume,
; IR: ![[LOC]] = !DILocation(line: 13, column: 5,
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

define void @stores_full(ptr %a, ptr %fp, ptr %out, ptr %indices,
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
  %u0 = sub i32 %r0, %c, !dbg !30
  %u1 = add i32 %c, %r1, !dbg !31
  %ud = fsub double %rd, %dc, !dbg !32
  %uf = fsub float %rf, %fc, !dbg !33
  %write = xor i32 %x, 5
  store i32 %write, ptr %p, align 4
  %op = getelementptr i32, ptr %out, i64 %iv
  store i32 %c, ptr %op, align 4
  %seen = load i32, ptr %op, align 4
  store i32 0, ptr %op, align 4
  %future = add nuw i64 %iv, 1
  %future.p = getelementptr i32, ptr %a, i64 %future
  store i32 %seen, ptr %future.p, align 4
  store double %dc, ptr %dp, align 8
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

define void @stores_raw(ptr %a, ptr %fp, ptr %out, ptr %indices,
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
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %rf = phi float [%fstart, %preheader], [%uf, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %write = xor i32 %x, 5
  store i32 %write, ptr %p, align 4
  %op = getelementptr i32, ptr %out, i64 %iv
  store i32 %write, ptr %op, align 4
  %seen = load i32, ptr %op, align 4
  store i32 0, ptr %op, align 4
  %c = call i32 @scalar_helper(i32 %seen)
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %dc = fmul double %dx, 3.0
  %fc = fptrunc double %dc to float
  %u0 = sub i32 %r0, %c, !dbg !34
  %u1 = add i32 %c, %r1, !dbg !35
  %ud = fsub double %rd, %dc, !dbg !36
  %uf = fsub float %rf, %fc, !dbg !37
  %future = add nuw i64 %iv, 1
  %future.p = getelementptr i32, ptr %a, i64 %future
  store i32 %c, ptr %future.p, align 4
  store double %dc, ptr %dp, align 8
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %producer.exit, label %loop, !dbg !13
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

define void @stores_compact(ptr %a, ptr %fp, ptr %out, ptr %indices,
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
  br i1 %choose, label %gate, label %right, !dbg !15
gate:
  br label %left
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %ld = fmul double %dx, 3.0
  %lf = fptrunc double %ld to float
  %u0 = sub i32 %r0, %lc, !dbg !38
  %u1 = add i32 %lc, %r1, !dbg !39
  %ud = fsub double %rd, %ld, !dbg !40
  %uf = fsub float %rf, %lf, !dbg !41
  %write = xor i32 %x, 5
  store i32 %write, ptr %p, align 4
  %op = getelementptr i32, ptr %out, i64 %iv
  store i32 %lc, ptr %op, align 4
  %seen = load i32, ptr %op, align 4
  store i32 0, ptr %op, align 4
  store i32 %seen, ptr %p, align 4
  store double %ld, ptr %dp, align 8
  br label %latch
right:
  %rc = xor i32 %x, 7
  %bypass.op = getelementptr i32, ptr %out, i64 %iv
  store i32 %rc, ptr %bypass.op, align 4
  store i32 0, ptr %p, align 4
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

define void @stores_chunk(ptr %a, ptr %fp, ptr %out, ptr %indices,
                            ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !16 {
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
  %u0 = sub i32 %r0, %c, !dbg !42
  %u1 = add i32 %c, %r1, !dbg !43
  %ud = fsub double %rd, %dc, !dbg !44
  %uf = fsub float %rf, %fc, !dbg !45
  %write = xor i32 %x, 5
  store i32 %write, ptr %p, align 4
  %op = getelementptr i32, ptr %out, i64 %iv
  store i32 %c, ptr %op, align 4
  %seen = load i32, ptr %op, align 4
  store i32 0, ptr %op, align 4
  %future = add nuw i64 %iv, 1
  %future.p = getelementptr i32, ptr %a, i64 %future
  store i32 %seen, ptr %future.p, align 4
  store double %dc, ptr %dp, align 8
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
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

define void @stores_chunk_ne(ptr %a, ptr %fp, ptr %out, ptr %indices,
                            ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !18 {
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
  %u0 = sub i32 %r0, %c, !dbg !46
  %u1 = add i32 %c, %r1, !dbg !47
  %ud = fsub double %rd, %dc, !dbg !48
  %uf = fsub float %rf, %fc, !dbg !49
  %write = xor i32 %x, 5
  store i32 %write, ptr %p, align 4
  %op = getelementptr i32, ptr %out, i64 %iv
  store i32 %c, ptr %op, align 4
  %seen = load i32, ptr %op, align 4
  store i32 0, ptr %op, align 4
  %future = add nuw i64 %iv, 1
  %future.p = getelementptr i32, ptr %a, i64 %future
  store i32 %seen, ptr %future.p, align 4
  store double %dc, ptr %dp, align 8
  %next = add i64 %iv, 1
  %done = icmp ne i64 %next, %n
  br i1 %done, label %loop, label %producer.exit, !dbg !19
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

define void @stores_affine(ptr %a, ptr %fp, ptr %out, ptr %indices,
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
  br label %loop
loop:
  %control = phi i64 [7, %preheader], [%control.next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %rf = phi float [%fstart, %preheader], [%uf, %loop]
  %distance = sub nuw nsw i64 %control, 7
  %iv = lshr exact i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = call i32 @scalar_helper(i32 %x)
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %dc = fmul double %dx, 3.0
  %fc = fptrunc double %dc to float
  %u0 = sub i32 %r0, %c, !dbg !50
  %u1 = add i32 %c, %r1, !dbg !51
  %ud = fsub double %rd, %dc, !dbg !52
  %uf = fsub float %rf, %fc, !dbg !53
  %write = xor i32 %x, 5
  store i32 %write, ptr %p, align 4
  %op = getelementptr i32, ptr %out, i64 %iv
  store i32 %c, ptr %op, align 4
  %seen = load i32, ptr %op, align 4
  store i32 0, ptr %op, align 4
  %future = add nuw i64 %iv, 1
  %future.p = getelementptr i32, ptr %a, i64 %future
  store i32 %seen, ptr %future.p, align 4
  store double %dc, ptr %dp, align 8
  %next = add nuw i64 %iv, 1
  %control.next = add nuw nsw i64 %control, 2
  %done = icmp eq i64 %control.next, %limit
  br i1 %done, label %producer.exit, label %loop, !dbg !21
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

define void @stores_flags(ptr %a, ptr %fp, ptr %out, ptr %indices,
                            ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !22 {
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
  %r0 = phi i32 [4096, %preheader], [%u0, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %rf = phi float [%fstart, %preheader], [%uf, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %rawc = call i32 @scalar_helper(i32 %x)
  %c = and i32 %rawc, 3
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %dc = fmul double %dx, 3.0
  %fc = fptrunc double %dc to float
  %u0 = sub nuw nsw i32 %r0, %c, !dbg !54
  %u1 = add i32 %c, %r1, !dbg !55
  %ud = fsub double %rd, %dc, !dbg !56
  %uf = fsub float %rf, %fc, !dbg !57
  %write = xor i32 %x, 5
  store i32 %write, ptr %p, align 4
  %op = getelementptr i32, ptr %out, i64 %iv
  store i32 %c, ptr %op, align 4
  %seen = load i32, ptr %op, align 4
  store i32 0, ptr %op, align 4
  %future = add nuw i64 %iv, 1
  %future.p = getelementptr i32, ptr %a, i64 %future
  store i32 %seen, ptr %future.p, align 4
  store double %dc, ptr %dp, align 8
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %producer.exit, label %loop, !dbg !23
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
  %final.r0 = phi i32 [4096, %entry], [%out.r0, %producer.exit]
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

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-subtraction.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!5 = !DISubroutineType(types: !6)
!6 = !{}
!10 = distinct !DISubprogram(name: "stores_full", scope: !1, file: !1, line: 10, type: !5, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 12, column: 3, scope: !10)
!12 = distinct !DISubprogram(name: "stores_raw", scope: !1, file: !1, line: 20, type: !5, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 22, column: 3, scope: !12)
!14 = distinct !DISubprogram(name: "stores_compact", scope: !1, file: !1, line: 30, type: !5, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!15 = !DILocation(line: 32, column: 3, scope: !14)
!16 = distinct !DISubprogram(name: "stores_chunk", scope: !1, file: !1, line: 40, type: !5, scopeLine: 40, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!17 = !DILocation(line: 42, column: 3, scope: !16)
!18 = distinct !DISubprogram(name: "stores_chunk_ne", scope: !1, file: !1, line: 50, type: !5, scopeLine: 50, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!19 = !DILocation(line: 52, column: 3, scope: !18)
!20 = distinct !DISubprogram(name: "stores_affine", scope: !1, file: !1, line: 60, type: !5, scopeLine: 60, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!21 = !DILocation(line: 62, column: 3, scope: !20)
!22 = distinct !DISubprogram(name: "stores_flags", scope: !1, file: !1, line: 70, type: !5, scopeLine: 70, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!23 = !DILocation(line: 72, column: 3, scope: !22)
!30 = !DILocation(line: 13, column: 5, scope: !10)
!31 = !DILocation(line: 14, column: 5, scope: !10)
!32 = !DILocation(line: 15, column: 5, scope: !10)
!33 = !DILocation(line: 16, column: 5, scope: !10)
!34 = !DILocation(line: 23, column: 5, scope: !12)
!35 = !DILocation(line: 24, column: 5, scope: !12)
!36 = !DILocation(line: 25, column: 5, scope: !12)
!37 = !DILocation(line: 26, column: 5, scope: !12)
!38 = !DILocation(line: 33, column: 5, scope: !14)
!39 = !DILocation(line: 34, column: 5, scope: !14)
!40 = !DILocation(line: 35, column: 5, scope: !14)
!41 = !DILocation(line: 36, column: 5, scope: !14)
!42 = !DILocation(line: 43, column: 5, scope: !16)
!43 = !DILocation(line: 44, column: 5, scope: !16)
!44 = !DILocation(line: 45, column: 5, scope: !16)
!45 = !DILocation(line: 46, column: 5, scope: !16)
!46 = !DILocation(line: 53, column: 5, scope: !18)
!47 = !DILocation(line: 54, column: 5, scope: !18)
!48 = !DILocation(line: 55, column: 5, scope: !18)
!49 = !DILocation(line: 56, column: 5, scope: !18)
!50 = !DILocation(line: 63, column: 5, scope: !20)
!51 = !DILocation(line: 64, column: 5, scope: !20)
!52 = !DILocation(line: 65, column: 5, scope: !20)
!53 = !DILocation(line: 66, column: 5, scope: !20)
!54 = !DILocation(line: 73, column: 5, scope: !22)
!55 = !DILocation(line: 74, column: 5, scope: !22)
!56 = !DILocation(line: 75, column: 5, scope: !22)
!57 = !DILocation(line: 76, column: 5, scope: !22)
