; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=260 \
; RUN:   -S %s | FileCheck %s --check-prefix=FIT
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=260 \
; RUN:   -vplan-reduction-fission-allow-fp-reordering -S %s | FileCheck %s --check-prefix=FIT
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=259 -S %s | FileCheck %s --check-prefix=BELOW
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=3 -S %s | FileCheck %s --check-prefix=TINY --implicit-check-not=scalar.fission
;
; One module exercises affine full-trip counts, an acyclic cross edge and a
; canonical chunk controller. Both canonical loops can use N-base scheduling.
; 260 fits 65 i32s exactly; 259 chunks all three at capacity 64 (256 bytes).
; The affine loop carries original control; canonical loops retain N-base. Three bytes cannot hold one
; i32 slot, so all three reject there. The executable checker compares fresh LV1/LV2 output with original
; IR and an independent C sum, including every N through 66, narrow capacity
; boundaries, bypasses, output aliases and exact producer/vector/tail/chunk
; counts. Both separate FP option settings are retained.
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

; FIT-LABEL: define void @integration_affine(
; FIT: alloca [65 x i32]
; FIT-NOT: scalar.fission.chunk
; FIT: %fission.ordinal = phi i64
; FIT: %iv = phi i64 [ 7, %preheader ]
; FIT: %next = add {{(nuw )?}}i64 %iv, 2
; FIT: %done = icmp eq i64 %next, %limit
; FIT: %fission.completed = add {{(nuw )?}}i64 %fission.ordinal, 1
; FIT: %fission.completed.count = phi i64
; FIT: scalar.fission.consumer.body:
; FIT: ret void
; BELOW-LABEL: define void @integration_affine(
; BELOW: alloca [64 x i32]
; BELOW: scalar.fission.chunk:
; BELOW: %fission.producer.continue = phi i1
; BELOW: br i1 %fission.producer.continue, label %scalar.fission.chunk
; BELOW: ret void
; TINY-LABEL: define void @integration_affine(
; TINY: ret void
define void @integration_affine(ptr readonly %a, ptr %out, i64 %n, i32 %start) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  %span = shl nuw i64 %n, 1
  %limit = add nuw i64 %span, 7
  br label %loop
loop:
  %iv = phi i64 [7, %preheader], [%next, %loop]
  %sum = phi i32 [%start, %preheader], [%update, %loop]
  %distance = sub nuw i64 %iv, 7
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %arg = xor i32 %x, 7
  %c = call i32 @scalar_helper(i32 %arg)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 2
  %done = icmp eq i64 %next, %limit
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%start, %entry], [%update, %loop]
  store i32 %result, ptr %out
  ret void
}

; This was the arm-cross-edge rejection in scalar-diamond-reject.ll. Keep the
; cross edge and an analogous unsupported arm cycle there; execute this case.
; FIT-LABEL: define void @integration_cross_edge(
; FIT: alloca [65 x i32]
; FIT-NOT: scalar.fission.chunk
; FIT: left:
; FIT: br label %right
; FIT: right:
; FIT: %first = phi i32 [ %lc, %left ], [ %x, %loop ]
; FIT: latch:
; FIT: store i32 %c
; FIT: scalar.fission.consumer.body:
; FIT: ret void
; BELOW-LABEL: define void @integration_cross_edge(
; BELOW: alloca [64 x i32], align 4
; BELOW: scalar.fission.chunk:
; BELOW: %fission.chunk.remaining = sub {{(nuw )?}}i64 %n, %fission.chunk.base
; BELOW: %fission.chunk.count = select i1 %fission.chunk.partial, i64 %fission.chunk.remaining, i64 64
; BELOW: %iv = phi i64 [ %fission.chunk.base, %scalar.fission.producer.ph ], [ %next, %latch ]
; BELOW: br i1 %choose, label %left, label %right
; BELOW: left:
; BELOW: %lc = mul i32 %x, 3
; BELOW: br label %right
; BELOW: right:
; BELOW: %first = phi i32 [ %lc, %left ], [ %x, %loop ]
; BELOW: %c = call i32 @scalar_helper(i32 %arg)
; BELOW: br label %latch
; BELOW: latch:
; BELOW: store i32 %c
; BELOW: br i1 %fission.producer.more, label %loop, label %scalar.fission.consumer.ph
; BELOW: scalar.fission.chunk.latch:
; BELOW: ret void
; TINY-LABEL: define void @integration_cross_edge(
; TINY: ret void
define void @integration_cross_edge(ptr readonly %a, ptr %out, i64 %n, i32 %start) {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %sum = phi i32 [%start, %preheader], [%update, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right
left:
  %lc = mul i32 %x, 3
  br label %right
right:
  %first = phi i32 [%lc, %left], [%x, %loop]
  %arg = xor i32 %first, 7
  %c = call i32 @scalar_helper(i32 %arg)
  br label %latch
latch:
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%start, %entry], [%update, %latch]
  store i32 %result, ptr %out
  ret void
}

; FIT-LABEL: define void @integration_chunk(
; FIT: alloca [65 x i32]
; FIT: scalar.fission.chunk:
; FIT: %fission.chunk.remaining = sub {{(nuw )?}}i64 %n, %fission.chunk.base
; FIT: %fission.chunk.count = select i1 %fission.chunk.partial, i64 %fission.chunk.remaining, i64 65
; FIT: %fission.producer.ordinal = phi i64
; FIT: scalar.fission.chunk.latch:
; FIT: ret void
; BELOW-LABEL: define void @integration_chunk(
; BELOW: alloca [64 x i32]
; BELOW: scalar.fission.chunk:
; BELOW: i64 64
; BELOW: ret void
; TINY-LABEL: define void @integration_chunk(
; TINY: ret void
define void @integration_chunk(ptr readonly %a, ptr %out, i64 %n, i32 %start) {
entry:
  %valid = icmp ule i64 %n, 255
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [%start, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %arg = xor i32 %x, 7
  %c = call i32 @scalar_helper(i32 %arg)
  %update = add i32 %sum, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%start, %entry], [%update, %loop]
  store i32 %result, ptr %out
  ret void
}
