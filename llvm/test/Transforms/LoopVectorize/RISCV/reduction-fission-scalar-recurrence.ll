; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=4 -force-vector-interleave=1 \
; RUN:   -scalable-vectorization=always -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -pass-remarks=vplan-reduction-fission -S %s -o %t 2> %t.remarks
; RUN: FileCheck %s --check-prefix=EVL < %t
; RUN: FileCheck %s --check-prefix=REMARK < %t.remarks
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t -o /dev/null
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=4 -force-vector-interleave=1 \
; RUN:   -scalable-vectorization=always -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-allow-fp-reordering \
; RUN:   -tail-folding-policy=dont-fold-tail -enable-epilogue-vectorization=false -S %s -o %t.tail
; RUN: FileCheck %s --check-prefix=TAIL < %t.tail
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.tail -o /dev/null
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -S %s | FileCheck %s --check-prefix=SCALAR
;
; Retain producer state in its original CFG, with original arithmetic/flags.
; Three independent reductions share two streams. The first-order delay and
; mutually dependent two-delay recurrences must never move to the consumer.
; PHIs are interleaved, and the runtime-control sibling reverses their order.
; Scratch slots, stores, loads and independent accumulator updates can follow
; that PHI order. DAG checks allow either order while tying both typed loads
; to their scratch slots and the FP operand to its ordered reduction. Block
; labels bound consumer checks; producer state and FP operand order stay fixed.
; Reserved bytes also follow stream order, without padding the final stream:
; i32[65] then double[65] uses 260+4+520=784; recurrence_runtime reverses
; the streams and uses 520+260=780. Both still have capacity 65 and exactly
; 12 bytes stored plus 12 bytes loaded per completed iteration (24 total).
; Integer-first capacity boundaries 1/255/5461 remain 16/3064/65536 bytes.
; The execution checker compares actual split code, original IR and C formulas
; with exact counts, ordered FP, tails and enclosing-row scratch reuse.
; Formerly all these loops failed scalar-unsupported-recurrence.
;
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

; REMARK: scalar-recurrence.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; SCALAR-LABEL: define void @recurrence_first(
; SCALAR-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x i32]
; SCALAR-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x double]
; SCALAR-NOT: alloca
; SCALAR: %prev = phi i32
; SCALAR: %raw = xor i32 %prev, %x
; SCALAR-DAG: store i32 %c,
; SCALAR-DAG: store double %dc,
; SCALAR: scalar.fission.consumer.ph:
; SCALAR-LABEL: {{^}}scalar.fission.consumer.body:
; SCALAR-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 %fission.consumer.iv
; SCALAR-DAG: [[I_VALUE:%[-a-zA-Z$._0-9]+]] = load i32, ptr [[I_PTR]],
; SCALAR-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 %fission.consumer.iv
; SCALAR-DAG: [[D_VALUE:%[-a-zA-Z$._0-9]+]] = load double, ptr [[D_PTR]],
; SCALAR-DAG: %u0.consume = add i32 %r0.consume, [[I_VALUE]]
; SCALAR-DAG: %u1.consume = add i32 [[I_VALUE]], %r1.consume
; SCALAR-DAG: %ud.consume = fadd double %rd.consume, [[D_VALUE]]
; SCALAR: br i1
; SCALAR-LABEL: {{^}}exit:
; SCALAR: ret void
; EVL-LABEL: define void @recurrence_first(
; EVL-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x i32]
; EVL-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x double]
; EVL: %prev = phi i32
; EVL: store i32 %c,
; EVL: scalar.fission.consumer.ph:
; EVL-LABEL: {{^}}vector.body:
; EVL-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 [[V_INDEX:%[-a-zA-Z$._0-9]+]]
; EVL-DAG: [[I_VECTOR:%[-a-zA-Z$._0-9]+]] = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0(ptr align 4 [[I_PTR]],
; EVL-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 [[V_INDEX]]
; EVL-DAG: [[D_VECTOR:%[-a-zA-Z$._0-9]+]] = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0(ptr align 8 [[D_PTR]],
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64(double {{%[-a-zA-Z$._0-9]+}}, <vscale x 4 x double> [[D_VECTOR]]
; EVL: br i1
; EVL-LABEL: {{^}}middle.block:
; EVL: @llvm.vector.reduce.add.nxv4i32
; EVL: ret void
; TAIL-LABEL: define void @recurrence_first(
; TAIL-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x i32]
; TAIL-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x double]
; TAIL: %prev = phi i32
; TAIL: store i32 %c,
; TAIL: scalar.fission.consumer.ph:
; TAIL-LABEL: {{^}}vector.body:
; TAIL-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 [[V_INDEX:%[-a-zA-Z$._0-9]+]]
; TAIL-DAG: [[I_VECTOR:%[-a-zA-Z$._0-9]+]] = load <vscale x 4 x i32>, ptr [[I_PTR]],
; TAIL-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 [[V_INDEX]]
; TAIL-DAG: [[D_VECTOR:%[-a-zA-Z$._0-9]+]] = load <vscale x 4 x double>, ptr [[D_PTR]],
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64(double {{%[-a-zA-Z$._0-9]+}}, <vscale x 4 x double> [[D_VECTOR]]
; TAIL: br i1
; TAIL-LABEL: {{^}}middle.block:
; TAIL: @llvm.vector.reduce.add.nxv4i32
; TAIL-LABEL: {{^}}scalar.fission.consumer.body:
; TAIL-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 %fission.consumer.iv
; TAIL-DAG: [[I_VALUE:%[-a-zA-Z$._0-9]+]] = load i32, ptr [[I_PTR]],
; TAIL-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 %fission.consumer.iv
; TAIL-DAG: [[D_VALUE:%[-a-zA-Z$._0-9]+]] = load double, ptr [[D_PTR]],
; TAIL-DAG: %u0.consume = add i32 %r0.consume, [[I_VALUE]]
; TAIL-DAG: %u1.consume = add i32 [[I_VALUE]], %r1.consume
; TAIL-DAG: %ud.consume = fadd double %rd.consume, [[D_VALUE]]
; TAIL: br i1
; TAIL-LABEL: {{^}}exit:
; TAIL: ret void
define void @recurrence_first(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !12 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !13
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %prev = phi i32 [23, %preheader], [%x, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %dprev = phi double [-0.0, %preheader], [%dx, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %raw = xor i32 %prev, %x
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dx, %dprev
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !13
exit:
  %result0 = phi i32 [17, %entry], [%u0, %loop]
  %result1 = phi i32 [-7, %entry], [%u1, %loop]
  %resultd = phi double [%start, %entry], [%ud, %loop]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %result0, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

; REMARK: scalar-recurrence.c:22:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; SCALAR-LABEL: define void @recurrence_two(
; SCALAR-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x i32]
; SCALAR-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x double]
; SCALAR-NOT: alloca
; SCALAR: %prev = phi i32
; SCALAR: %raw = xor i32 %prev, %x
; SCALAR: %state.next = add {{(nuw nsw |nuw |nsw )?}}i32 %bounded, %older
; SCALAR-DAG: store i32 %c,
; SCALAR-DAG: store double %dc,
; SCALAR: scalar.fission.consumer.ph:
; SCALAR-LABEL: {{^}}scalar.fission.consumer.body:
; SCALAR-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 %fission.consumer.iv
; SCALAR-DAG: [[I_VALUE:%[-a-zA-Z$._0-9]+]] = load i32, ptr [[I_PTR]],
; SCALAR-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 %fission.consumer.iv
; SCALAR-DAG: [[D_VALUE:%[-a-zA-Z$._0-9]+]] = load double, ptr [[D_PTR]],
; SCALAR-DAG: %u0.consume = add i32 %r0.consume, [[I_VALUE]]
; SCALAR-DAG: %u1.consume = add i32 [[I_VALUE]], %r1.consume
; SCALAR-DAG: %ud.consume = fadd double %rd.consume, [[D_VALUE]]
; SCALAR: br i1
; SCALAR-LABEL: {{^}}exit:
; SCALAR: ret void
; EVL-LABEL: define void @recurrence_two(
; EVL-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x i32]
; EVL-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x double]
; EVL: %prev = phi i32
; EVL: store i32 %c,
; EVL: scalar.fission.consumer.ph:
; EVL-LABEL: {{^}}vector.body:
; EVL-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 [[V_INDEX:%[-a-zA-Z$._0-9]+]]
; EVL-DAG: [[I_VECTOR:%[-a-zA-Z$._0-9]+]] = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0(ptr align 4 [[I_PTR]],
; EVL-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 [[V_INDEX]]
; EVL-DAG: [[D_VECTOR:%[-a-zA-Z$._0-9]+]] = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0(ptr align 8 [[D_PTR]],
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64(double {{%[-a-zA-Z$._0-9]+}}, <vscale x 4 x double> [[D_VECTOR]]
; EVL: br i1
; EVL-LABEL: {{^}}middle.block:
; EVL: @llvm.vector.reduce.add.nxv4i32
; EVL: ret void
; TAIL-LABEL: define void @recurrence_two(
; TAIL-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x i32]
; TAIL-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x double]
; TAIL: %prev = phi i32
; TAIL: store i32 %c,
; TAIL: scalar.fission.consumer.ph:
; TAIL-LABEL: {{^}}vector.body:
; TAIL-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 [[V_INDEX:%[-a-zA-Z$._0-9]+]]
; TAIL-DAG: [[I_VECTOR:%[-a-zA-Z$._0-9]+]] = load <vscale x 4 x i32>, ptr [[I_PTR]],
; TAIL-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 [[V_INDEX]]
; TAIL-DAG: [[D_VECTOR:%[-a-zA-Z$._0-9]+]] = load <vscale x 4 x double>, ptr [[D_PTR]],
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64(double {{%[-a-zA-Z$._0-9]+}}, <vscale x 4 x double> [[D_VECTOR]]
; TAIL: br i1
; TAIL-LABEL: {{^}}middle.block:
; TAIL: @llvm.vector.reduce.add.nxv4i32
; TAIL-LABEL: {{^}}scalar.fission.consumer.body:
; TAIL-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 %fission.consumer.iv
; TAIL-DAG: [[I_VALUE:%[-a-zA-Z$._0-9]+]] = load i32, ptr [[I_PTR]],
; TAIL-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 %fission.consumer.iv
; TAIL-DAG: [[D_VALUE:%[-a-zA-Z$._0-9]+]] = load double, ptr [[D_PTR]],
; TAIL-DAG: %u0.consume = add i32 %r0.consume, [[I_VALUE]]
; TAIL-DAG: %u1.consume = add i32 [[I_VALUE]], %r1.consume
; TAIL-DAG: %ud.consume = fadd double %rd.consume, [[D_VALUE]]
; TAIL: br i1
; TAIL-LABEL: {{^}}exit:
; TAIL: ret void
define void @recurrence_two(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !22 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !23
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %prev = phi i32 [23, %preheader], [%state.next, %loop]
  %older = phi i32 [11, %preheader], [%prev, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %dolder = phi double [0.5, %preheader], [%dprev, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %raw = xor i32 %prev, %x
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dx, %dprev
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !23
exit:
  %result0 = phi i32 [17, %entry], [%u0, %loop]
  %result1 = phi i32 [-7, %entry], [%u1, %loop]
  %resultd = phi double [%start, %entry], [%ud, %loop]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %result0, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

; REMARK: scalar-recurrence.c:32:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; SCALAR-LABEL: define void @recurrence_affine(
; SCALAR-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x i32]
; SCALAR-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x double]
; SCALAR-NOT: alloca
; SCALAR: %prev = phi i32
; SCALAR: %raw = xor i32 %prev, %x
; SCALAR: %state.next = add {{(nuw nsw |nuw |nsw )?}}i32 %bounded, %older
; SCALAR-DAG: store i32 %c,
; SCALAR-DAG: store double %dc,
; SCALAR: scalar.fission.consumer.ph:
; SCALAR-LABEL: {{^}}scalar.fission.consumer.body:
; SCALAR-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 %fission.consumer.iv
; SCALAR-DAG: [[I_VALUE:%[-a-zA-Z$._0-9]+]] = load i32, ptr [[I_PTR]],
; SCALAR-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 %fission.consumer.iv
; SCALAR-DAG: [[D_VALUE:%[-a-zA-Z$._0-9]+]] = load double, ptr [[D_PTR]],
; SCALAR-DAG: %u0.consume = add i32 %r0.consume, [[I_VALUE]]
; SCALAR-DAG: %u1.consume = add i32 [[I_VALUE]], %r1.consume
; SCALAR-DAG: %ud.consume = fadd double %rd.consume, [[D_VALUE]]
; SCALAR: br i1
; SCALAR-LABEL: {{^}}exit:
; SCALAR: ret void
; EVL-LABEL: define void @recurrence_affine(
; EVL-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x i32]
; EVL-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x double]
; EVL: %prev = phi i32
; EVL: store i32 %c,
; EVL: scalar.fission.consumer.ph:
; EVL-LABEL: {{^}}vector.body:
; EVL-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 [[V_INDEX:%[-a-zA-Z$._0-9]+]]
; EVL-DAG: [[I_VECTOR:%[-a-zA-Z$._0-9]+]] = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0(ptr align 4 [[I_PTR]],
; EVL-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 [[V_INDEX]]
; EVL-DAG: [[D_VECTOR:%[-a-zA-Z$._0-9]+]] = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0(ptr align 8 [[D_PTR]],
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64(double {{%[-a-zA-Z$._0-9]+}}, <vscale x 4 x double> [[D_VECTOR]]
; EVL: br i1
; EVL-LABEL: {{^}}middle.block:
; EVL: @llvm.vector.reduce.add.nxv4i32
; EVL: ret void
; TAIL-LABEL: define void @recurrence_affine(
; TAIL-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x i32]
; TAIL-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x double]
; TAIL: %prev = phi i32
; TAIL: store i32 %c,
; TAIL: scalar.fission.consumer.ph:
; TAIL-LABEL: {{^}}vector.body:
; TAIL-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 [[V_INDEX:%[-a-zA-Z$._0-9]+]]
; TAIL-DAG: [[I_VECTOR:%[-a-zA-Z$._0-9]+]] = load <vscale x 4 x i32>, ptr [[I_PTR]],
; TAIL-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 [[V_INDEX]]
; TAIL-DAG: [[D_VECTOR:%[-a-zA-Z$._0-9]+]] = load <vscale x 4 x double>, ptr [[D_PTR]],
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64(double {{%[-a-zA-Z$._0-9]+}}, <vscale x 4 x double> [[D_VECTOR]]
; TAIL: br i1
; TAIL-LABEL: {{^}}middle.block:
; TAIL: @llvm.vector.reduce.add.nxv4i32
; TAIL-LABEL: {{^}}scalar.fission.consumer.body:
; TAIL-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 %fission.consumer.iv
; TAIL-DAG: [[I_VALUE:%[-a-zA-Z$._0-9]+]] = load i32, ptr [[I_PTR]],
; TAIL-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 %fission.consumer.iv
; TAIL-DAG: [[D_VALUE:%[-a-zA-Z$._0-9]+]] = load double, ptr [[D_PTR]],
; TAIL-DAG: %u0.consume = add i32 %r0.consume, [[I_VALUE]]
; TAIL-DAG: %u1.consume = add i32 [[I_VALUE]], %r1.consume
; TAIL-DAG: %ud.consume = fadd double %rd.consume, [[D_VALUE]]
; TAIL: br i1
; TAIL-LABEL: {{^}}exit:
; TAIL: ret void
define void @recurrence_affine(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !32 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  %span = mul nuw nsw i64 %n, 3
  %limit = add nuw nsw i64 %span, 7
  br label %loop, !dbg !33
loop:
  %iv = phi i64 [7, %preheader], [%next, %loop]
  %prev = phi i32 [23, %preheader], [%state.next, %loop]
  %older = phi i32 [11, %preheader], [%prev, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %dolder = phi double [0.5, %preheader], [%dprev, %loop]
  %distance = sub nuw nsw i64 %iv, 7
  %index = udiv i64 %distance, 3
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %raw = xor i32 %prev, %x
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dx, %dprev
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw nsw i64 %iv, 3
  %done = icmp uge i64 %next, %limit
  br i1 %done, label %exit, label %loop, !dbg !33
exit:
  %result0 = phi i32 [17, %entry], [%u0, %loop]
  %result1 = phi i32 [-7, %entry], [%u1, %loop]
  %resultd = phi double [%start, %entry], [%ud, %loop]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %result0, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

; REMARK: scalar-recurrence.c:42:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 780
; SCALAR-LABEL: define void @recurrence_runtime(
; SCALAR-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x i32]
; SCALAR-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x double]
; SCALAR-NOT: alloca
; SCALAR: %prev = phi i32
; SCALAR: %raw = xor i32 %prev, %x
; SCALAR: %state.next = add {{(nuw nsw |nuw |nsw )?}}i32 %bounded, %older
; SCALAR-DAG: store i32 %c,
; SCALAR-DAG: store double %dc,
; SCALAR: scalar.fission.consumer.ph:
; SCALAR-LABEL: {{^}}scalar.fission.consumer.body:
; SCALAR-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 %fission.consumer.iv
; SCALAR-DAG: [[I_VALUE:%[-a-zA-Z$._0-9]+]] = load i32, ptr [[I_PTR]],
; SCALAR-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 %fission.consumer.iv
; SCALAR-DAG: [[D_VALUE:%[-a-zA-Z$._0-9]+]] = load double, ptr [[D_PTR]],
; SCALAR-DAG: %u0.consume = add i32 %r0.consume, [[I_VALUE]]
; SCALAR-DAG: %u1.consume = add i32 [[I_VALUE]], %r1.consume
; SCALAR-DAG: %ud.consume = fadd double %rd.consume, [[D_VALUE]]
; SCALAR: br i1
; SCALAR-LABEL: {{^}}exit:
; SCALAR: ret void
; EVL-LABEL: define void @recurrence_runtime(
; EVL-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x i32]
; EVL-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x double]
; EVL: %prev = phi i32
; EVL: store i32 %c,
; EVL: scalar.fission.consumer.ph:
; EVL-LABEL: {{^}}vector.body:
; EVL-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 [[V_INDEX:%[-a-zA-Z$._0-9]+]]
; EVL-DAG: [[I_VECTOR:%[-a-zA-Z$._0-9]+]] = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0(ptr align 4 [[I_PTR]],
; EVL-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 [[V_INDEX]]
; EVL-DAG: [[D_VECTOR:%[-a-zA-Z$._0-9]+]] = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0(ptr align 8 [[D_PTR]],
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64(double {{%[-a-zA-Z$._0-9]+}}, <vscale x 4 x double> [[D_VECTOR]]
; EVL: br i1
; EVL-LABEL: {{^}}middle.block:
; EVL: @llvm.vector.reduce.add.nxv4i32
; EVL: ret void
; TAIL-LABEL: define void @recurrence_runtime(
; TAIL-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x i32]
; TAIL-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x double]
; TAIL: %prev = phi i32
; TAIL: store i32 %c,
; TAIL: scalar.fission.consumer.ph:
; TAIL-LABEL: {{^}}vector.body:
; TAIL-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 [[V_INDEX:%[-a-zA-Z$._0-9]+]]
; TAIL-DAG: [[I_VECTOR:%[-a-zA-Z$._0-9]+]] = load <vscale x 4 x i32>, ptr [[I_PTR]],
; TAIL-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 [[V_INDEX]]
; TAIL-DAG: [[D_VECTOR:%[-a-zA-Z$._0-9]+]] = load <vscale x 4 x double>, ptr [[D_PTR]],
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64(double {{%[-a-zA-Z$._0-9]+}}, <vscale x 4 x double> [[D_VECTOR]]
; TAIL: br i1
; TAIL-LABEL: {{^}}middle.block:
; TAIL: @llvm.vector.reduce.add.nxv4i32
; TAIL-LABEL: {{^}}scalar.fission.consumer.body:
; TAIL-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 %fission.consumer.iv
; TAIL-DAG: [[I_VALUE:%[-a-zA-Z$._0-9]+]] = load i32, ptr [[I_PTR]],
; TAIL-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 %fission.consumer.iv
; TAIL-DAG: [[D_VALUE:%[-a-zA-Z$._0-9]+]] = load double, ptr [[D_PTR]],
; TAIL-DAG: %u0.consume = add i32 %r0.consume, [[I_VALUE]]
; TAIL-DAG: %u1.consume = add i32 [[I_VALUE]], %r1.consume
; TAIL-DAG: %ud.consume = fadd double %rd.consume, [[D_VALUE]]
; TAIL: br i1
; TAIL-LABEL: {{^}}exit:
; TAIL: ret void
define void @recurrence_runtime(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !42 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  %origin = and i64 %begin, 255
  %span = shl nuw nsw i64 %n, 1
  %limit = add nuw nsw i64 %origin, %span
  br label %loop, !dbg !43
loop:
  %dolder = phi double [0.5, %preheader], [%dprev, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %older = phi i32 [11, %preheader], [%prev, %loop]
  %prev = phi i32 [23, %preheader], [%state.next, %loop]
  %iv = phi i64 [%origin, %preheader], [%next, %loop]
  %distance = sub nuw nsw i64 %iv, %origin
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %raw = xor i32 %prev, %x
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dx, %dprev
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw nsw i64 %iv, 2
  %done = icmp eq i64 %next, %limit
  br i1 %done, label %exit, label %loop, !dbg !43
exit:
  %result0 = phi i32 [17, %entry], [%u0, %loop]
  %result1 = phi i32 [-7, %entry], [%u1, %loop]
  %resultd = phi double [%start, %entry], [%ud, %loop]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %result0, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

; REMARK: scalar-recurrence.c:52:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; SCALAR-LABEL: define void @recurrence_branch(
; SCALAR-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x i32]
; SCALAR-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x double]
; SCALAR-NOT: alloca
; SCALAR: %prev = phi i32
; SCALAR: %raw = xor i32 %prev, %x
; SCALAR: %state.next = add {{(nuw nsw |nuw |nsw )?}}i32 %bounded, %older
; SCALAR-DAG: store i32 %c,
; SCALAR-DAG: store double %dc,
; SCALAR: scalar.fission.consumer.ph:
; SCALAR-LABEL: {{^}}scalar.fission.consumer.body:
; SCALAR-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 %fission.consumer.iv
; SCALAR-DAG: [[I_VALUE:%[-a-zA-Z$._0-9]+]] = load i32, ptr [[I_PTR]],
; SCALAR-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 %fission.consumer.iv
; SCALAR-DAG: [[D_VALUE:%[-a-zA-Z$._0-9]+]] = load double, ptr [[D_PTR]],
; SCALAR-DAG: %u0.consume = add i32 %r0.consume, [[I_VALUE]]
; SCALAR-DAG: %u1.consume = add i32 [[I_VALUE]], %r1.consume
; SCALAR-DAG: %ud.consume = fadd double %rd.consume, [[D_VALUE]]
; SCALAR: br i1
; SCALAR-LABEL: {{^}}exit:
; SCALAR: ret void
; EVL-LABEL: define void @recurrence_branch(
; EVL-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x i32]
; EVL-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x double]
; EVL: %prev = phi i32
; EVL: store i32 %c,
; EVL: scalar.fission.consumer.ph:
; EVL-LABEL: {{^}}vector.body:
; EVL-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 [[V_INDEX:%[-a-zA-Z$._0-9]+]]
; EVL-DAG: [[I_VECTOR:%[-a-zA-Z$._0-9]+]] = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0(ptr align 4 [[I_PTR]],
; EVL-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 [[V_INDEX]]
; EVL-DAG: [[D_VECTOR:%[-a-zA-Z$._0-9]+]] = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0(ptr align 8 [[D_PTR]],
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64(double {{%[-a-zA-Z$._0-9]+}}, <vscale x 4 x double> [[D_VECTOR]]
; EVL: br i1
; EVL-LABEL: {{^}}middle.block:
; EVL: @llvm.vector.reduce.add.nxv4i32
; EVL: ret void
; TAIL-LABEL: define void @recurrence_branch(
; TAIL-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x i32]
; TAIL-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x double]
; TAIL: %prev = phi i32
; TAIL: store i32 %c,
; TAIL: scalar.fission.consumer.ph:
; TAIL-LABEL: {{^}}vector.body:
; TAIL-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 [[V_INDEX:%[-a-zA-Z$._0-9]+]]
; TAIL-DAG: [[I_VECTOR:%[-a-zA-Z$._0-9]+]] = load <vscale x 4 x i32>, ptr [[I_PTR]],
; TAIL-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 [[V_INDEX]]
; TAIL-DAG: [[D_VECTOR:%[-a-zA-Z$._0-9]+]] = load <vscale x 4 x double>, ptr [[D_PTR]],
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64(double {{%[-a-zA-Z$._0-9]+}}, <vscale x 4 x double> [[D_VECTOR]]
; TAIL: br i1
; TAIL-LABEL: {{^}}middle.block:
; TAIL: @llvm.vector.reduce.add.nxv4i32
; TAIL-LABEL: {{^}}scalar.fission.consumer.body:
; TAIL-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 %fission.consumer.iv
; TAIL-DAG: [[I_VALUE:%[-a-zA-Z$._0-9]+]] = load i32, ptr [[I_PTR]],
; TAIL-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 %fission.consumer.iv
; TAIL-DAG: [[D_VALUE:%[-a-zA-Z$._0-9]+]] = load double, ptr [[D_PTR]],
; TAIL-DAG: %u0.consume = add i32 %r0.consume, [[I_VALUE]]
; TAIL-DAG: %u1.consume = add i32 [[I_VALUE]], %r1.consume
; TAIL-DAG: %ud.consume = fadd double %rd.consume, [[D_VALUE]]
; TAIL: br i1
; TAIL-LABEL: {{^}}exit:
; TAIL: ret void
define void @recurrence_branch(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !52 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !53
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %older = phi i32 [11, %preheader], [%prev, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %dolder = phi double [0.5, %preheader], [%dprev, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %raw = xor i32 %prev, %x
  %bit = and i32 %prev, 1
  %choose = icmp ne i32 %bit, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @scalar_helper(i32 %raw)
  br label %latch
right:
  %rc = xor i32 %raw, 7
  %scaled = fmul double %dx, 0.5
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [%rc, %right]
  %delta = phi double [%dx, %left], [%scaled, %right]
  %dc = fsub double %delta, %dprev
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !53
exit:
  %result0 = phi i32 [17, %entry], [%u0, %latch]
  %result1 = phi i32 [-7, %entry], [%u1, %latch]
  %resultd = phi double [%start, %entry], [%ud, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %result0, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

; REMARK: scalar-recurrence.c:62:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; SCALAR-LABEL: define void @recurrence_enclosing(
; SCALAR-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x i32]
; SCALAR-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x double]
; SCALAR-NOT: alloca
; SCALAR: %prev = phi i32
; SCALAR: %raw = xor i32 %prev, %x
; SCALAR: %state.next = add {{(nuw nsw |nuw |nsw )?}}i32 %bounded, %older
; SCALAR-DAG: store i32 %c,
; SCALAR-DAG: store double %dc,
; SCALAR: scalar.fission.consumer.ph:
; SCALAR-LABEL: {{^}}scalar.fission.consumer.body:
; SCALAR-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 %fission.consumer.iv
; SCALAR-DAG: [[I_VALUE:%[-a-zA-Z$._0-9]+]] = load i32, ptr [[I_PTR]],
; SCALAR-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 %fission.consumer.iv
; SCALAR-DAG: [[D_VALUE:%[-a-zA-Z$._0-9]+]] = load double, ptr [[D_PTR]],
; SCALAR-DAG: %u0.consume = add i32 %r0.consume, [[I_VALUE]]
; SCALAR-DAG: %u1.consume = add i32 [[I_VALUE]], %r1.consume
; SCALAR-DAG: %ud.consume = fadd double %rd.consume, [[D_VALUE]]
; SCALAR: br i1
; SCALAR-LABEL: {{^}}row.exit:
; SCALAR: ret void
; EVL-LABEL: define void @recurrence_enclosing(
; EVL-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x i32]
; EVL-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x double]
; EVL: %prev = phi i32
; EVL: store i32 %c,
; EVL: scalar.fission.consumer.ph:
; EVL-LABEL: {{^}}vector.body:
; EVL-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 [[V_INDEX:%[-a-zA-Z$._0-9]+]]
; EVL-DAG: [[I_VECTOR:%[-a-zA-Z$._0-9]+]] = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0(ptr align 4 [[I_PTR]],
; EVL-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 [[V_INDEX]]
; EVL-DAG: [[D_VECTOR:%[-a-zA-Z$._0-9]+]] = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0(ptr align 8 [[D_PTR]],
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64(double {{%[-a-zA-Z$._0-9]+}}, <vscale x 4 x double> [[D_VECTOR]]
; EVL: br i1
; EVL-LABEL: {{^}}middle.block:
; EVL: @llvm.vector.reduce.add.nxv4i32
; EVL: ret void
; TAIL-LABEL: define void @recurrence_enclosing(
; TAIL-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x i32]
; TAIL-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x double]
; TAIL: %prev = phi i32
; TAIL: store i32 %c,
; TAIL: scalar.fission.consumer.ph:
; TAIL-LABEL: {{^}}vector.body:
; TAIL-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 [[V_INDEX:%[-a-zA-Z$._0-9]+]]
; TAIL-DAG: [[I_VECTOR:%[-a-zA-Z$._0-9]+]] = load <vscale x 4 x i32>, ptr [[I_PTR]],
; TAIL-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 [[V_INDEX]]
; TAIL-DAG: [[D_VECTOR:%[-a-zA-Z$._0-9]+]] = load <vscale x 4 x double>, ptr [[D_PTR]],
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64(double {{%[-a-zA-Z$._0-9]+}}, <vscale x 4 x double> [[D_VECTOR]]
; TAIL: br i1
; TAIL-LABEL: {{^}}middle.block:
; TAIL: @llvm.vector.reduce.add.nxv4i32
; TAIL-LABEL: {{^}}scalar.fission.consumer.body:
; TAIL-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 %fission.consumer.iv
; TAIL-DAG: [[I_VALUE:%[-a-zA-Z$._0-9]+]] = load i32, ptr [[I_PTR]],
; TAIL-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 %fission.consumer.iv
; TAIL-DAG: [[D_VALUE:%[-a-zA-Z$._0-9]+]] = load double, ptr [[D_PTR]],
; TAIL-DAG: %u0.consume = add i32 %r0.consume, [[I_VALUE]]
; TAIL-DAG: %u1.consume = add i32 [[I_VALUE]], %r1.consume
; TAIL-DAG: %ud.consume = fadd double %rd.consume, [[D_VALUE]]
; TAIL: br i1
; TAIL-LABEL: {{^}}row.exit:
; TAIL: ret void
define void @recurrence_enclosing(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !62 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %rows.valid = icmp ule i64 %rows, 4
  %rows.nonzero = icmp ne i64 %rows, 0
  %rows.enter = and i1 %rows.valid, %rows.nonzero
  %all.enter = and i1 %enter, %rows.enter
  br i1 %all.enter, label %outer.ph, label %exit
outer.ph:
  br label %outer
outer:
  %row = phi i64 [0, %outer.ph], [%row.next, %row.exit]
  %carry0 = phi i32 [17, %outer.ph], [%v0, %row.exit]
  %carry1 = phi i32 [-7, %outer.ph], [%v1, %row.exit]
  %dcarry = phi double [%start, %outer.ph], [%vd, %row.exit]
  %base = mul nuw nsw i64 %row, 65
  br label %inner.ph
inner.ph:
  br label %inner, !dbg !63
inner:
  %iv = phi i64 [0, %inner.ph], [%next, %latch]
  %prev = phi i32 [23, %inner.ph], [%state.next, %latch]
  %older = phi i32 [11, %inner.ph], [%prev, %latch]
  %r0 = phi i32 [%carry0, %inner.ph], [%u0, %latch]
  %dprev = phi double [-0.0, %inner.ph], [%dstate.next, %latch]
  %r1 = phi i32 [%carry1, %inner.ph], [%u1, %latch]
  %rd = phi double [%dcarry, %inner.ph], [%ud, %latch]
  %dolder = phi double [0.5, %inner.ph], [%dprev, %latch]
  %index = add nuw nsw i64 %base, %iv
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %raw = xor i32 %prev, %x
  %bit = and i32 %prev, 1
  %choose = icmp ne i32 %bit, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @scalar_helper(i32 %raw)
  br label %latch
right:
  %rc = xor i32 %raw, 7
  %scaled = fmul double %dx, 0.5
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [%rc, %right]
  %delta = phi double [%dx, %left], [%scaled, %right]
  %dc = fsub double %delta, %dprev
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %row.exit, label %inner, !dbg !63
row.exit:
  %v0 = phi i32 [%u0, %latch]
  %v1 = phi i32 [%u1, %latch]
  %vd = phi double [%ud, %latch]
  store i32 %v0, ptr %out
  %row.o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v1, ptr %row.o1
  store double %vd, ptr %dout
  %row.next = add nuw nsw i64 %row, 1
  %row.done = icmp eq i64 %row.next, %rows
  br i1 %row.done, label %exit, label %outer
exit:
  %result0 = phi i32 [17, %entry], [%v0, %row.exit]
  %result1 = phi i32 [-7, %entry], [%v1, %row.exit]
  %resultd = phi double [%start, %entry], [%vd, %row.exit]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %result0, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

; REMARK: scalar-recurrence.c:72:3: split scalar-IR reduction loop; {{.*}}scratch capacity 1, scratch bytes 16
; SCALAR-LABEL: define void @recurrence_one(
; SCALAR-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [1 x i32]
; SCALAR-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [1 x double]
; SCALAR-NOT: alloca
; SCALAR: %prev = phi i32
; SCALAR: %raw = xor i32 %prev, %x
; SCALAR: %state.next = add {{(nuw nsw |nuw |nsw )?}}i32 %bounded, %older
; SCALAR-DAG: store i32 %c,
; SCALAR-DAG: store double %dc,
; SCALAR: scalar.fission.consumer.ph:
; SCALAR-LABEL: {{^}}scalar.fission.consumer.body:
; SCALAR-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [1 x i32], ptr [[I_SCRATCH]], i32 0, i64 %fission.consumer.iv
; SCALAR-DAG: [[I_VALUE:%[-a-zA-Z$._0-9]+]] = load i32, ptr [[I_PTR]],
; SCALAR-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [1 x double], ptr [[D_SCRATCH]], i32 0, i64 %fission.consumer.iv
; SCALAR-DAG: [[D_VALUE:%[-a-zA-Z$._0-9]+]] = load double, ptr [[D_PTR]],
; SCALAR-DAG: %u0.consume = add i32 %r0.consume, [[I_VALUE]]
; SCALAR-DAG: %u1.consume = add i32 [[I_VALUE]], %r1.consume
; SCALAR-DAG: %ud.consume = fadd double %rd.consume, [[D_VALUE]]
; SCALAR: br i1
; SCALAR-LABEL: {{^}}exit:
; SCALAR: ret void
define void @recurrence_one(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !72 {
entry:
  %valid = icmp ule i64 %n, 1
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !73
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %prev = phi i32 [23, %preheader], [%state.next, %loop]
  %older = phi i32 [11, %preheader], [%prev, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %dolder = phi double [0.5, %preheader], [%dprev, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %raw = xor i32 %prev, %x
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dx, %dprev
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !73
exit:
  %result0 = phi i32 [17, %entry], [%u0, %loop]
  %result1 = phi i32 [-7, %entry], [%u1, %loop]
  %resultd = phi double [%start, %entry], [%ud, %loop]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %result0, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

; REMARK: scalar-recurrence.c:82:3: split scalar-IR reduction loop; {{.*}}scratch capacity 255, scratch bytes 3064
; SCALAR-LABEL: define void @recurrence_255(
; SCALAR-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [255 x i32]
; SCALAR-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [255 x double]
; SCALAR-NOT: alloca
; SCALAR: %prev = phi i32
; SCALAR: %raw = xor i32 %prev, %x
; SCALAR: %state.next = add {{(nuw nsw |nuw |nsw )?}}i32 %bounded, %older
; SCALAR-DAG: store i32 %c,
; SCALAR-DAG: store double %dc,
; SCALAR: scalar.fission.consumer.ph:
; SCALAR-LABEL: {{^}}scalar.fission.consumer.body:
; SCALAR-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [255 x i32], ptr [[I_SCRATCH]], i32 0, i64 %fission.consumer.iv
; SCALAR-DAG: [[I_VALUE:%[-a-zA-Z$._0-9]+]] = load i32, ptr [[I_PTR]],
; SCALAR-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [255 x double], ptr [[D_SCRATCH]], i32 0, i64 %fission.consumer.iv
; SCALAR-DAG: [[D_VALUE:%[-a-zA-Z$._0-9]+]] = load double, ptr [[D_PTR]],
; SCALAR-DAG: %u0.consume = add i32 %r0.consume, [[I_VALUE]]
; SCALAR-DAG: %u1.consume = add i32 [[I_VALUE]], %r1.consume
; SCALAR-DAG: %ud.consume = fadd double %rd.consume, [[D_VALUE]]
; SCALAR: br i1
; SCALAR-LABEL: {{^}}exit:
; SCALAR: ret void
define void @recurrence_255(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !82 {
entry:
  %valid = icmp ule i64 %n, 255
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !83
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %prev = phi i32 [23, %preheader], [%state.next, %loop]
  %older = phi i32 [11, %preheader], [%prev, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %dolder = phi double [0.5, %preheader], [%dprev, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %raw = xor i32 %prev, %x
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dx, %dprev
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !83
exit:
  %result0 = phi i32 [17, %entry], [%u0, %loop]
  %result1 = phi i32 [-7, %entry], [%u1, %loop]
  %resultd = phi double [%start, %entry], [%ud, %loop]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %result0, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

; REMARK: scalar-recurrence.c:92:3: split scalar-IR reduction loop; {{.*}}scratch capacity 5461, scratch bytes 65536
; SCALAR-LABEL: define void @recurrence_limit(
; SCALAR-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [5461 x i32]
; SCALAR-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [5461 x double]
; SCALAR-NOT: alloca
; SCALAR: %prev = phi i32
; SCALAR: %raw = xor i32 %prev, %x
; SCALAR: %state.next = add {{(nuw nsw |nuw |nsw )?}}i32 %bounded, %older
; SCALAR-DAG: store i32 %c,
; SCALAR-DAG: store double %dc,
; SCALAR: scalar.fission.consumer.ph:
; SCALAR-LABEL: {{^}}scalar.fission.consumer.body:
; SCALAR-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [5461 x i32], ptr [[I_SCRATCH]], i32 0, i64 %fission.consumer.iv
; SCALAR-DAG: [[I_VALUE:%[-a-zA-Z$._0-9]+]] = load i32, ptr [[I_PTR]],
; SCALAR-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [5461 x double], ptr [[D_SCRATCH]], i32 0, i64 %fission.consumer.iv
; SCALAR-DAG: [[D_VALUE:%[-a-zA-Z$._0-9]+]] = load double, ptr [[D_PTR]],
; SCALAR-DAG: %u0.consume = add i32 %r0.consume, [[I_VALUE]]
; SCALAR-DAG: %u1.consume = add i32 [[I_VALUE]], %r1.consume
; SCALAR-DAG: %ud.consume = fadd double %rd.consume, [[D_VALUE]]
; SCALAR: br i1
; SCALAR-LABEL: {{^}}exit:
; SCALAR: ret void
define void @recurrence_limit(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !92 {
entry:
  %valid = icmp ule i64 %n, 5461
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !93
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %prev = phi i32 [23, %preheader], [%state.next, %loop]
  %older = phi i32 [11, %preheader], [%prev, %loop]
  %r0 = phi i32 [17, %preheader], [%u0, %loop]
  %dprev = phi double [-0.0, %preheader], [%dstate.next, %loop]
  %r1 = phi i32 [-7, %preheader], [%u1, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %dolder = phi double [0.5, %preheader], [%dprev, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %raw = xor i32 %prev, %x
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dx, %dprev
  %bounded = and i32 %x, 127
  %state.next = add nuw nsw i32 %bounded, %older
  %dstate.next = fsub double %dx, %dolder
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !93
exit:
  %result0 = phi i32 [17, %entry], [%u0, %loop]
  %result1 = phi i32 [-7, %entry], [%u1, %loop]
  %resultd = phi double [%start, %entry], [%ud, %loop]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %result0, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

; REMARK: scalar-recurrence.c:102:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; SCALAR-LABEL: define void @recurrence_first_affine(
; SCALAR-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x i32]
; SCALAR-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x double]
; SCALAR: %prev = phi i32
; SCALAR: br i1 %choose, label %left, label %right
; SCALAR-DAG: store i32 %c,
; SCALAR-DAG: store double %dc,
; SCALAR: scalar.fission.consumer.ph:
; SCALAR-LABEL: {{^}}scalar.fission.consumer.body:
; SCALAR-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 %fission.consumer.iv
; SCALAR-DAG: [[I_VALUE:%[-a-zA-Z$._0-9]+]] = load i32, ptr [[I_PTR]],
; SCALAR-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 %fission.consumer.iv
; SCALAR-DAG: [[D_VALUE:%[-a-zA-Z$._0-9]+]] = load double, ptr [[D_PTR]],
; SCALAR-DAG: %u0.consume = add i32 %r0.consume, [[I_VALUE]]
; SCALAR-DAG: %u1.consume = add i32 [[I_VALUE]], %r1.consume
; SCALAR-DAG: %ud.consume = fadd double %rd.consume, [[D_VALUE]]
; SCALAR: br i1
; SCALAR-LABEL: {{^}}exit:
; SCALAR: ret void
; EVL-LABEL: define void @recurrence_first_affine(
; EVL-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x i32]
; EVL-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x double]
; EVL: %prev = phi i32
; EVL: store i32 %c,
; EVL: scalar.fission.consumer.ph:
; EVL-LABEL: {{^}}vector.body:
; EVL-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 [[V_INDEX:%[-a-zA-Z$._0-9]+]]
; EVL-DAG: [[I_VECTOR:%[-a-zA-Z$._0-9]+]] = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0(ptr align 4 [[I_PTR]],
; EVL-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 [[V_INDEX]]
; EVL-DAG: [[D_VECTOR:%[-a-zA-Z$._0-9]+]] = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0(ptr align 8 [[D_PTR]],
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64(double {{%[-a-zA-Z$._0-9]+}}, <vscale x 4 x double> [[D_VECTOR]]
; EVL: br i1
; EVL-LABEL: {{^}}middle.block:
; EVL: @llvm.vector.reduce.add.nxv4i32
; EVL: ret void
; TAIL-LABEL: define void @recurrence_first_affine(
; TAIL-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x i32]
; TAIL-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x double]
; TAIL: %prev = phi i32
; TAIL: store i32 %c,
; TAIL: scalar.fission.consumer.ph:
; TAIL-LABEL: {{^}}vector.body:
; TAIL-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 [[V_INDEX:%[-a-zA-Z$._0-9]+]]
; TAIL-DAG: [[I_VECTOR:%[-a-zA-Z$._0-9]+]] = load <vscale x 4 x i32>, ptr [[I_PTR]],
; TAIL-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 [[V_INDEX]]
; TAIL-DAG: [[D_VECTOR:%[-a-zA-Z$._0-9]+]] = load <vscale x 4 x double>, ptr [[D_PTR]],
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64(double {{%[-a-zA-Z$._0-9]+}}, <vscale x 4 x double> [[D_VECTOR]]
; TAIL: br i1
; TAIL-LABEL: {{^}}middle.block:
; TAIL: @llvm.vector.reduce.add.nxv4i32
; TAIL-LABEL: {{^}}scalar.fission.consumer.body:
; TAIL-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 %fission.consumer.iv
; TAIL-DAG: [[I_VALUE:%[-a-zA-Z$._0-9]+]] = load i32, ptr [[I_PTR]],
; TAIL-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 %fission.consumer.iv
; TAIL-DAG: [[D_VALUE:%[-a-zA-Z$._0-9]+]] = load double, ptr [[D_PTR]],
; TAIL-DAG: %u0.consume = add i32 %r0.consume, [[I_VALUE]]
; TAIL-DAG: %u1.consume = add i32 [[I_VALUE]], %r1.consume
; TAIL-DAG: %ud.consume = fadd double %rd.consume, [[D_VALUE]]
; TAIL: br i1
; TAIL-LABEL: {{^}}exit:
; TAIL: ret void
define void @recurrence_first_affine(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !102 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  %origin = and i64 %begin, 255
  %span = shl nuw nsw i64 %n, 1
  %limit = add nuw nsw i64 %origin, %span
  br label %loop, !dbg !103
loop:
  %iv = phi i64 [%origin, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%x, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %dprev = phi double [-0.0, %preheader], [%dx, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %distance = sub nuw nsw i64 %iv, %origin
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %raw = xor i32 %prev, %x
  %bit = and i32 %prev, 1
  %choose = icmp ne i32 %bit, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @scalar_helper(i32 %raw)
  br label %latch
right:
  %rc = xor i32 %raw, 7
  %scaled = fmul double %dx, 0.5
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [%rc, %right]
  %delta = phi double [%dx, %left], [%scaled, %right]
  %dc = fsub double %delta, %dprev
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw nsw i64 %iv, 2
  %done = icmp eq i64 %next, %limit
  br i1 %done, label %exit, label %loop, !dbg !103
exit:
  %result0 = phi i32 [17, %entry], [%u0, %latch]
  %result1 = phi i32 [-7, %entry], [%u1, %latch]
  %resultd = phi double [%start, %entry], [%ud, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %result0, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

; REMARK: scalar-recurrence.c:112:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 784
; SCALAR-LABEL: define void @recurrence_first_enclosing(
; SCALAR-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x i32]
; SCALAR-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x double]
; SCALAR: %prev = phi i32
; SCALAR: br i1 %choose, label %left, label %right
; SCALAR-DAG: store i32 %c,
; SCALAR-DAG: store double %dc,
; SCALAR: scalar.fission.consumer.ph:
; SCALAR-LABEL: {{^}}scalar.fission.consumer.body:
; SCALAR-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 %fission.consumer.iv
; SCALAR-DAG: [[I_VALUE:%[-a-zA-Z$._0-9]+]] = load i32, ptr [[I_PTR]],
; SCALAR-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 %fission.consumer.iv
; SCALAR-DAG: [[D_VALUE:%[-a-zA-Z$._0-9]+]] = load double, ptr [[D_PTR]],
; SCALAR-DAG: %u0.consume = add i32 %r0.consume, [[I_VALUE]]
; SCALAR-DAG: %u1.consume = add i32 [[I_VALUE]], %r1.consume
; SCALAR-DAG: %ud.consume = fadd double %rd.consume, [[D_VALUE]]
; SCALAR: br i1
; SCALAR-LABEL: {{^}}row.exit:
; SCALAR: ret void
; EVL-LABEL: define void @recurrence_first_enclosing(
; EVL-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x i32]
; EVL-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x double]
; EVL: %prev = phi i32
; EVL: store i32 %c,
; EVL: scalar.fission.consumer.ph:
; EVL-LABEL: {{^}}vector.body:
; EVL-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 [[V_INDEX:%[-a-zA-Z$._0-9]+]]
; EVL-DAG: [[I_VECTOR:%[-a-zA-Z$._0-9]+]] = call <vscale x 4 x i32> @llvm.vp.load.nxv4i32.p0(ptr align 4 [[I_PTR]],
; EVL-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 [[V_INDEX]]
; EVL-DAG: [[D_VECTOR:%[-a-zA-Z$._0-9]+]] = call <vscale x 4 x double> @llvm.vp.load.nxv4f64.p0(ptr align 8 [[D_PTR]],
; EVL: call double @llvm.vp.reduce.fadd.nxv4f64(double {{%[-a-zA-Z$._0-9]+}}, <vscale x 4 x double> [[D_VECTOR]]
; EVL: br i1
; EVL-LABEL: {{^}}middle.block:
; EVL: @llvm.vector.reduce.add.nxv4i32
; EVL: ret void
; TAIL-LABEL: define void @recurrence_first_enclosing(
; TAIL-DAG: [[I_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x i32]
; TAIL-DAG: [[D_SCRATCH:%[-a-zA-Z$._0-9]+]] = alloca [65 x double]
; TAIL: %prev = phi i32
; TAIL: store i32 %c,
; TAIL: scalar.fission.consumer.ph:
; TAIL-LABEL: {{^}}vector.body:
; TAIL-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 [[V_INDEX:%[-a-zA-Z$._0-9]+]]
; TAIL-DAG: [[I_VECTOR:%[-a-zA-Z$._0-9]+]] = load <vscale x 4 x i32>, ptr [[I_PTR]],
; TAIL-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 [[V_INDEX]]
; TAIL-DAG: [[D_VECTOR:%[-a-zA-Z$._0-9]+]] = load <vscale x 4 x double>, ptr [[D_PTR]],
; TAIL: call double @llvm.vector.reduce.fadd.nxv4f64(double {{%[-a-zA-Z$._0-9]+}}, <vscale x 4 x double> [[D_VECTOR]]
; TAIL: br i1
; TAIL-LABEL: {{^}}middle.block:
; TAIL: @llvm.vector.reduce.add.nxv4i32
; TAIL-LABEL: {{^}}scalar.fission.consumer.body:
; TAIL-DAG: [[I_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x i32], ptr [[I_SCRATCH]], i32 0, i64 %fission.consumer.iv
; TAIL-DAG: [[I_VALUE:%[-a-zA-Z$._0-9]+]] = load i32, ptr [[I_PTR]],
; TAIL-DAG: [[D_PTR:%[-a-zA-Z$._0-9]+]] = getelementptr inbounds [65 x double], ptr [[D_SCRATCH]], i32 0, i64 %fission.consumer.iv
; TAIL-DAG: [[D_VALUE:%[-a-zA-Z$._0-9]+]] = load double, ptr [[D_PTR]],
; TAIL-DAG: %u0.consume = add i32 %r0.consume, [[I_VALUE]]
; TAIL-DAG: %u1.consume = add i32 [[I_VALUE]], %r1.consume
; TAIL-DAG: %ud.consume = fadd double %rd.consume, [[D_VALUE]]
; TAIL: br i1
; TAIL-LABEL: {{^}}row.exit:
; TAIL: ret void
define void @recurrence_first_enclosing(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %dout,
                                i64 %n, i64 %rows, double %start, i64 %begin) !dbg !112 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %rows.valid = icmp ule i64 %rows, 4
  %rows.nonzero = icmp ne i64 %rows, 0
  %rows.enter = and i1 %rows.valid, %rows.nonzero
  %all.enter = and i1 %enter, %rows.enter
  br i1 %all.enter, label %outer.ph, label %exit
outer.ph:
  br label %outer
outer:
  %row = phi i64 [0, %outer.ph], [%row.next, %row.exit]
  %carry0 = phi i32 [17, %outer.ph], [%v0, %row.exit]
  %carry1 = phi i32 [-7, %outer.ph], [%v1, %row.exit]
  %dcarry = phi double [%start, %outer.ph], [%vd, %row.exit]
  %base = mul nuw nsw i64 %row, 65
  br label %inner.ph
inner.ph:
  br label %inner, !dbg !113
inner:
  %iv = phi i64 [0, %inner.ph], [%next, %latch]
  %prev = phi i32 [23, %inner.ph], [%x, %latch]
  %r0 = phi i32 [%carry0, %inner.ph], [%u0, %latch]
  %dprev = phi double [-0.0, %inner.ph], [%dx, %latch]
  %r1 = phi i32 [%carry1, %inner.ph], [%u1, %latch]
  %rd = phi double [%dcarry, %inner.ph], [%ud, %latch]
  %index = add nuw nsw i64 %base, %iv
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %raw = xor i32 %prev, %x
  %bit = and i32 %prev, 1
  %choose = icmp ne i32 %bit, 0
  br i1 %choose, label %left, label %right
left:
  %lc = call i32 @scalar_helper(i32 %raw)
  br label %latch
right:
  %rc = xor i32 %raw, 7
  %scaled = fmul double %dx, 0.5
  br label %latch
latch:
  %c = phi i32 [%lc, %left], [%rc, %right]
  %delta = phi double [%dx, %left], [%scaled, %right]
  %dc = fsub double %delta, %dprev
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %row.exit, label %inner, !dbg !113
row.exit:
  %v0 = phi i32 [%u0, %latch]
  %v1 = phi i32 [%u1, %latch]
  %vd = phi double [%ud, %latch]
  store i32 %v0, ptr %out
  %row.o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v1, ptr %row.o1
  store double %vd, ptr %dout
  %row.next = add nuw nsw i64 %row, 1
  %row.done = icmp eq i64 %row.next, %rows
  br i1 %row.done, label %exit, label %outer
exit:
  %result0 = phi i32 [17, %entry], [%v0, %row.exit]
  %result1 = phi i32 [-7, %entry], [%v1, %row.exit]
  %resultd = phi double [%start, %entry], [%vd, %row.exit]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %result0, ptr %out
  store i32 %result1, ptr %o1
  store double %resultd, ptr %dout
  ret void
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-recurrence.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = !DISubroutineType(types: !5)
!5 = !{}
!12 = distinct !DISubprogram(name: "recurrence_first", scope: !1, file: !1, line: 12, type: !4, scopeLine: 12, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 12, column: 3, scope: !12)
!22 = distinct !DISubprogram(name: "recurrence_two", scope: !1, file: !1, line: 22, type: !4, scopeLine: 22, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!23 = !DILocation(line: 22, column: 3, scope: !22)
!32 = distinct !DISubprogram(name: "recurrence_affine", scope: !1, file: !1, line: 32, type: !4, scopeLine: 32, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!33 = !DILocation(line: 32, column: 3, scope: !32)
!42 = distinct !DISubprogram(name: "recurrence_runtime", scope: !1, file: !1, line: 42, type: !4, scopeLine: 42, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!43 = !DILocation(line: 42, column: 3, scope: !42)
!52 = distinct !DISubprogram(name: "recurrence_branch", scope: !1, file: !1, line: 52, type: !4, scopeLine: 52, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!53 = !DILocation(line: 52, column: 3, scope: !52)
!62 = distinct !DISubprogram(name: "recurrence_enclosing", scope: !1, file: !1, line: 62, type: !4, scopeLine: 62, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!63 = !DILocation(line: 62, column: 3, scope: !62)
!72 = distinct !DISubprogram(name: "recurrence_one", scope: !1, file: !1, line: 72, type: !4, scopeLine: 72, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!73 = !DILocation(line: 72, column: 3, scope: !72)
!82 = distinct !DISubprogram(name: "recurrence_255", scope: !1, file: !1, line: 82, type: !4, scopeLine: 82, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!83 = !DILocation(line: 82, column: 3, scope: !82)
!92 = distinct !DISubprogram(name: "recurrence_limit", scope: !1, file: !1, line: 92, type: !4, scopeLine: 92, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!93 = !DILocation(line: 92, column: 3, scope: !92)
!102 = distinct !DISubprogram(name: "recurrence_first_affine", scope: !1, file: !1, line: 102, type: !4, scopeLine: 102, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!103 = !DILocation(line: 102, column: 3, scope: !102)
!112 = distinct !DISubprogram(name: "recurrence_first_enclosing", scope: !1, file: !1, line: 112, type: !4, scopeLine: 112, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!113 = !DILocation(line: 112, column: 3, scope: !112)
