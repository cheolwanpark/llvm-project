; RUN: opt -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v,+f,+d -riscv-v-vector-bits-min=128 -scalable-vectorization=on -force-vector-width=fission:16 -force-vector-interleave=1 -verify-dom-info -verify-loop-info -verify-scev -S %s | FileCheck %s
; RUN: opt -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v,+f,+d -riscv-v-vector-bits-min=128 -scalable-vectorization=on -force-vector-width=fission:16 -force-vector-interleave=1 -reduction-fission-stack-budget=512 -verify-dom-info -verify-loop-info -verify-scev -S %s | FileCheck %s
; RUN: opt -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v,+f,+d -riscv-v-vector-bits-min=128 -scalable-vectorization=on -force-vector-width=fission:2 -force-vector-interleave=1 -reduction-fission-stack-budget=512 -verify-dom-info -verify-loop-info -verify-scev -data-layout='e-m:e-p:64:64-i8:8:128-i64:64-i128:128-n32:64-S128' -S %s | FileCheck %s --check-prefix=ALIGN
;
; Physical storage is independent of the logical reduction type and signedness.
; A 512-byte budget fits one byte buffer, including alignment, but neither an
; i32 buffer nor two byte buffers. Reducers remain separate after a single Map.

target triple = "riscv64-unknown-linux-gnu"

; CHECK-LABEL: define i32 @narrow_output(
; CHECK-NOT: = alloca
; CHECK-NOT: @malloc
; CHECK: xor <vscale x 16 x i8>
; CHECK: @llvm.vp.store.nxv16i8
; CHECK: getelementptr i8, ptr %out,
; CHECK: @llvm.vp.load.nxv16i8
; CHECK: zext <vscale x 16 x i8> {{.*}} to <vscale x 16 x i32>
; CHECK: @llvm.vector.reduce.add.nxv16i32
; CHECK: ret i32
define i32 @narrow_output(ptr noalias readonly %a, ptr noalias %out) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %sum = phi i32 [ 0, %preheader ], [ %next, %loop ]
  %p = getelementptr inbounds nuw i8, ptr %a, i64 %i
  %x = load i8, ptr %p, align 1
  %v = xor i8 %x, -128
  %op = getelementptr inbounds nuw i8, ptr %out, i64 %i
  store i8 %v, ptr %op, align 1
  %wide = zext i8 %v to i32
  %next = add i32 %sum, %wide
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 512
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %next, %loop ]
  ret i32 %result
}

; CHECK-LABEL: define i32 @narrow_scratch(
; CHECK-NOT: = alloca
; CHECK-NOT: @malloc
; CHECK: [[BUF:%.*]] = alloca i8, i64 512, align 1
; CHECK-NOT: = alloca
; CHECK-NOT: @malloc
; CHECK: xor <vscale x 16 x i8>
; CHECK: getelementptr i8, ptr [[BUF]],
; CHECK: @llvm.vp.store.nxv16i8
; CHECK: getelementptr i8, ptr [[BUF]],
; CHECK: @llvm.vp.load.nxv16i8
; CHECK: zext <vscale x 16 x i8> {{.*}} to <vscale x 16 x i32>
; CHECK: @llvm.vector.reduce.add.nxv16i32
; CHECK: ret i32
define i32 @narrow_scratch(ptr noalias readonly %a) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %sum = phi i32 [ 0, %preheader ], [ %next, %loop ]
  %p = getelementptr inbounds nuw i8, ptr %a, i64 %i
  %x = load i8, ptr %p, align 1
  %v = xor i8 %x, -128
  %wide = zext i8 %v to i32
  %next = add i32 %sum, %wide
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 512
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %next, %loop ]
  ret i32 %result
}

; A preferred 16-byte allocation alignment does not align every byte access.
; ALIGN-LABEL: define { i32, i32 } @shared_decoding(
; ALIGN-NOT: = alloca
; ALIGN: [[ALIGNED:%.*]] = alloca i8, i64 512, align 16
; ALIGN-NOT: = alloca
; ALIGN-NOT: @malloc
; ALIGN: getelementptr i8, ptr [[ALIGNED]],
; ALIGN: @llvm.vp.store.nxv2i8{{.*}}ptr align 1
; ALIGN: @llvm.vector.reduce.add.nxv16i32
; ALIGN: @llvm.vector.reduce.add.nxv16i32
; ALIGN: ret { i32, i32 }
; CHECK-LABEL: define { i32, i32 } @shared_decoding(
; CHECK-NOT: = alloca
; CHECK-NOT: @malloc
; CHECK: [[SHARED:%.*]] = alloca i8, i64 512, align 1
; CHECK-NOT: = alloca
; CHECK-NOT: @malloc
; CHECK: xor <vscale x 16 x i8>
; CHECK: getelementptr i8, ptr [[SHARED]],
; CHECK: @llvm.vp.store.nxv16i8
; CHECK: phi <vscale x 16 x i32>
; CHECK: getelementptr i8, ptr [[SHARED]],
; CHECK: @llvm.vp.load.nxv16i8
; CHECK: sext <vscale x 16 x i8> {{.*}} to <vscale x 16 x i32>
; CHECK: @llvm.vector.reduce.add.nxv16i32
; CHECK: phi <vscale x 16 x i32>
; CHECK: getelementptr i8, ptr [[SHARED]],
; CHECK: @llvm.vp.load.nxv16i8
; CHECK: zext <vscale x 16 x i8> {{.*}} to <vscale x 16 x i32>
; CHECK: @llvm.vector.reduce.add.nxv16i32
; CHECK: ret { i32, i32 }
define { i32, i32 } @shared_decoding(ptr noalias readonly %a) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %sum = phi i32 [ 0, %preheader ], [ %next, %loop ]
  %sum2 = phi i32 [ 0, %preheader ], [ %next2, %loop ]
  %p = getelementptr inbounds nuw i8, ptr %a, i64 %i
  %x = load i8, ptr %p, align 1
  %v = xor i8 %x, -128
  %signed = sext i8 %v to i32
  %unsigned = zext i8 %v to i32
  %next = add i32 %sum, %signed
  %next2 = add i32 %sum2, %unsigned
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 512
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %next, %loop ]
  %result2 = phi i32 [ %next2, %loop ]
  %r0 = insertvalue { i32, i32 } poison, i32 %result, 0
  %r1 = insertvalue { i32, i32 } %r0, i32 %result2, 1
  ret { i32, i32 } %r1
}

; CHECK-LABEL: define i32 @wide_output(
; CHECK-NOT: = alloca
; CHECK-NOT: @malloc
; CHECK: @llvm.vp.store.nxv16i32
; CHECK: getelementptr i32, ptr %out,
; CHECK: @llvm.vp.load.nxv16i32
; CHECK: @llvm.vector.reduce.add.nxv16i32
; CHECK: ret i32
define i32 @wide_output(ptr noalias readonly %a, ptr noalias %out) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %sum = phi i32 [ 0, %preheader ], [ %next, %loop ]
  %p = getelementptr inbounds nuw i32, ptr %a, i64 %i
  %x = load i32, ptr %p, align 4
  %v = xor i32 %x, -128
  %op = getelementptr inbounds nuw i32, ptr %out, i64 %i
  store i32 %v, ptr %op, align 4
  %next = add i32 %sum, %v
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 512
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %next, %loop ]
  ret i32 %result
}

; CHECK-LABEL: define i32 @extended_input(
; CHECK-NOT: = alloca
; CHECK-NOT: @malloc
; CHECK: getelementptr i8, ptr %a,
; CHECK: @llvm.vp.load.nxv16i8
; CHECK: sext <vscale x 16 x i8> {{.*}} to <vscale x 16 x i32>
; CHECK: @llvm.vector.reduce.add.nxv16i32
; CHECK: ret i32
define i32 @extended_input(ptr noalias readonly %a) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %sum = phi i32 [ 0, %preheader ], [ %next, %loop ]
  %p = getelementptr inbounds nuw i8, ptr %a, i64 %i
  %x = load i8, ptr %p, align 1
  %wide = sext i8 %x to i32
  %next = add i32 %sum, %wide
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 512
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %next, %loop ]
  ret i32 %result
}

; The second output can alias out with a negative offset, overwriting values
; saved by earlier Map iterations. Input remains disjoint to exclude recurrence.
; CHECK-LABEL: define i32 @alias_output(
; CHECK-NOT: = alloca
; CHECK-NOT: @malloc
; CHECK: [[ALIASBUF:%.*]] = alloca i8, i64 512, align 1
; CHECK-NOT: = alloca
; CHECK-NOT: @malloc
; CHECK: getelementptr i8, ptr [[ALIASBUF]],
; CHECK: @llvm.vp.store.nxv16i8
; CHECK: getelementptr i8, ptr [[ALIASBUF]],
; CHECK: @llvm.vp.load.nxv16i8
; CHECK: zext <vscale x 16 x i8>
; CHECK: @llvm.vector.reduce.add.nxv16i32
; CHECK: ret i32
define i32 @alias_output(ptr noalias readonly %a, ptr %out, ptr %other) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %sum = phi i32 [ 0, %preheader ], [ %next, %loop ]
  %p = getelementptr inbounds nuw i8, ptr %a, i64 %i
  %x = load i8, ptr %p, align 1
  %v = xor i8 %x, -128
  %op = getelementptr inbounds nuw i8, ptr %out, i64 %i
  store i8 %v, ptr %op, align 1
  %qp = getelementptr inbounds nuw i8, ptr %other, i64 %i
  store i8 0, ptr %qp, align 1
  %wide = zext i8 %v to i32
  %next = add i32 %sum, %wide
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 512
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %next, %loop ]
  ret i32 %result
}

; Only alternate iterations store out, but every iteration contributes.
; Conditional stream borrowing remains disabled. Flattening the reduction keeps
; its exact byte encoding, with complete coverage in owned scratch.
; CHECK-LABEL: define i32 @conditional_output(
; CHECK-NOT: = alloca
; CHECK-NOT: @malloc
; CHECK: [[CONDBUF:%.*]] = alloca i8, i64 512, align 1
; CHECK-NOT: = alloca
; CHECK-NOT: @malloc
; CHECK: getelementptr i8, ptr [[CONDBUF]],
; CHECK: @llvm.vp.store.nxv16i8
; CHECK: getelementptr i8, ptr [[CONDBUF]],
; CHECK: @llvm.vp.load.nxv16i8
; CHECK: zext <vscale x 16 x i8>
; CHECK: @llvm.vector.reduce.add.nxv16i32
; CHECK: ret i32
define i32 @conditional_output(ptr noalias readonly %a, ptr noalias %out) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %latch ]
  %sum = phi i32 [ 0, %preheader ], [ %next, %latch ]
  %p = getelementptr inbounds nuw i8, ptr %a, i64 %i
  %x = load i8, ptr %p, align 1
  %v = xor i8 %x, -128
  %bit = and i64 %i, 1
  %active = icmp eq i64 %bit, 0
  br i1 %active, label %store, label %latch
store:
  %op = getelementptr inbounds nuw i8, ptr %out, i64 %i
  store i8 %v, ptr %op, align 1
  br label %latch
latch:
  %wide = zext i8 %v to i32
  %next = add i32 %sum, %wide
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 512
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %next, %latch ]
  ret i32 %result
}

; sext to i16 followed by zext to i32 is not sext i8 to i32.
; CHECK-LABEL: define i32 @mixed_extension_chain(
; CHECK-NOT: = alloca
; CHECK-NOT: @malloc
; CHECK: alloca i8, i64 512, align 1
; CHECK-NOT: = alloca
; CHECK-NOT: @malloc
; CHECK: @llvm.vp.store.nxv16i8
; CHECK: @llvm.vp.load.nxv16i8
; CHECK: sext <vscale x 16 x i8> {{.*}} to <vscale x 16 x i16>
; CHECK: zext <vscale x 16 x i16> {{.*}} to <vscale x 16 x i32>
; CHECK: @llvm.vector.reduce.add.nxv16i32
; CHECK: ret i32
define i32 @mixed_extension_chain(ptr noalias readonly %a) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %sum = phi i32 [ 0, %preheader ], [ %next, %loop ]
  %p = getelementptr inbounds nuw i8, ptr %a, i64 %i
  %x = load i8, ptr %p, align 1
  %v = xor i8 %x, -128
  %middle = sext i8 %v to i16
  %wide = zext i16 %middle to i32
  %next = add i32 %sum, %wide
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 512
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %next, %loop ]
  ret i32 %result
}

; Distinct values of the same type need distinct buffers: both contents survive
; the entire Map phase, even though the reducers execute sequentially.
; CHECK-LABEL: define { i32, i32 } @distinct_values(
; CHECK-NOT: = alloca
; CHECK-NOT: @malloc
; CHECK: [[B0:%.*]] = {{(alloca i8, i64 512, align 1|call noalias ptr @malloc\(i64 %[^)]+\))}}
; CHECK: [[B1:%.*]] = {{(alloca i8, i64 512, align 1|call noalias ptr @malloc\(i64 %[^)]+\))}}
; CHECK-NOT: = alloca
; CHECK-NOT: @malloc
; CHECK-DAG: getelementptr i8, ptr [[B0]],
; CHECK-DAG: getelementptr i8, ptr [[B1]],
; CHECK: @llvm.vp.store.nxv16i8
; CHECK: phi <vscale x 16 x i32>
; CHECK: @llvm.vp.load.nxv16i8
; CHECK: sext <vscale x 16 x i8>
; CHECK: @llvm.vector.reduce.add.nxv16i32
; CHECK: phi <vscale x 16 x i32>
; CHECK: @llvm.vp.load.nxv16i8
; CHECK: zext <vscale x 16 x i8>
; CHECK: @llvm.vector.reduce.add.nxv16i32
; CHECK: ret { i32, i32 }
define { i32, i32 } @distinct_values(ptr noalias readonly %a) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %sum = phi i32 [ 0, %preheader ], [ %next, %loop ]
  %sum2 = phi i32 [ 0, %preheader ], [ %next2, %loop ]
  %p = getelementptr inbounds nuw i8, ptr %a, i64 %i
  %x = load i8, ptr %p, align 1
  %v = xor i8 %x, -128
  %w = add i8 %x, 1
  %signed = sext i8 %v to i32
  %unsigned = zext i8 %w to i32
  %next = add i32 %sum, %signed
  %next2 = add i32 %sum2, %unsigned
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 512
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %next, %loop ]
  %result2 = phi i32 [ %next2, %loop ]
  %r0 = insertvalue { i32, i32 } poison, i32 %result, 0
  %r1 = insertvalue { i32, i32 } %r0, i32 %result2, 1
  ret { i32, i32 } %r1
}

; Both terms already have byte outputs. Normalization must keep these streams
; instead of materializing the equivalent widened sum in new scratch.
; CHECK-LABEL: define i32 @normalized_outputs(
; CHECK-NOT: = alloca
; CHECK-NOT: @malloc
; CHECK: @llvm.vp.store.nxv16i8
; CHECK: @llvm.vp.store.nxv16i8
; CHECK: phi <vscale x 16 x i32>
; CHECK: @llvm.vp.load.nxv16i8
; CHECK: zext <vscale x 16 x i8>
; CHECK: @llvm.vp.load.nxv16i8
; CHECK: sext <vscale x 16 x i8>
; CHECK: @llvm.vector.reduce.add.nxv16i32
; CHECK: ret i32
define i32 @normalized_outputs(ptr noalias readonly %a, ptr noalias %out0, ptr noalias %out1) {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %i = phi i64 [ 0, %preheader ], [ %inc, %loop ]
  %sum = phi i32 [ 0, %preheader ], [ %next, %loop ]
  %p = getelementptr inbounds nuw i8, ptr %a, i64 %i
  %x = load i8, ptr %p, align 1
  %v = xor i8 %x, -128
  %w = add i8 %x, 1
  %op0 = getelementptr inbounds nuw i8, ptr %out0, i64 %i
  %op1 = getelementptr inbounds nuw i8, ptr %out1, i64 %i
  store i8 %v, ptr %op0, align 1
  store i8 %w, ptr %op1, align 1
  %unsigned = zext i8 %v to i32
  %signed = sext i8 %w to i32
  %partial = add i32 %sum, %unsigned
  %next = add i32 %partial, %signed
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 512
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [ %next, %loop ]
  ret i32 %result
}
