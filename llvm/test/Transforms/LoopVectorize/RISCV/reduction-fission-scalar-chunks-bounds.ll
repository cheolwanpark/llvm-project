; RUN: split-file %s %t
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -pass-remarks=vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=36 -S %t/narrow.ll 2>&1 | FileCheck %s --check-prefix=NARROW
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -pass-remarks=vplan-reduction-fission \
; RUN:   -S %t/large.ll 2>&1 | FileCheck %s --check-prefix=LARGE
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -pass-remarks=vplan-reduction-fission \
; RUN:   -S %t/index16.ll 2>&1 | FileCheck %s --check-prefix=INDEX
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -enable-vplan-reduction-fission -pass-remarks-missed=vplan-reduction-fission \
; RUN:   -S %t/index8.ll 2>&1 | FileCheck %s --check-prefix=ROW --implicit-check-not=scalar.fission
;
; Exact finite trip counts remain required. Narrow all-ones N=255 is
; representable; 28 complete C=9 chunks finish with count=3 and next=255.
; A huge exact trip count exercises checked multiplication and binary search,
; rather than overflowing a full-trip allocation or increasing the ceiling.
; Restricted alloca index widths also cap capacity: with a signed-positive
; 16-bit byte offset, 8191 i32 rows fit, 8192 do not. One i1024 row cannot fit
; the signed-positive 8-bit byte range, even under the default byte ceiling.
; These are scalar IR/analysis regressions, not executable huge-trip tests.

; NARROW: scratch capacity 9, scratch bytes 36, producer live-outs 0, chunked schedule, trip bound 255
; NARROW-LABEL: define i32 @narrow_max(
; NARROW: alloca [9 x i32]
; NARROW: %fission.chunk.remaining = sub nuw i8 -1, %fission.chunk.base
; NARROW: %fission.chunk.count = select i1 %fission.chunk.partial, i8 %fission.chunk.remaining, i8 9
; NARROW: %iv = phi i8 [ %fission.chunk.base, %scalar.fission.producer.ph ]
; NARROW: %fission.chunk.next = add nuw i8 %fission.chunk.base, %fission.chunk.count
; NARROW: %fission.chunk.more = icmp ne i8 %fission.chunk.next, -1
; NARROW: ret i32
;
; LARGE: scratch capacity 16384, scratch bytes 65536, producer live-outs 0, chunked schedule, trip bound 18446744073709551615
; LARGE-LABEL: define i32 @finite_large(
; LARGE: alloca [16384 x i32]
; LARGE-NOT: alloca
; LARGE: %fission.chunk.remaining = sub nuw i64 -1, %fission.chunk.base
; LARGE: %fission.chunk.next = add nuw i64 %fission.chunk.base, %fission.chunk.count
; LARGE: ret i32
;
; INDEX: scratch capacity 8191, scratch bytes 32764, producer live-outs 0, chunked schedule, trip bound 16385
; INDEX-LABEL: define i32 @limited_index(
; INDEX: alloca [8191 x i32]
; INDEX: %fission.producer.index = trunc i32 %fission.producer.ordinal to i16
; INDEX: getelementptr inbounds [8191 x i32], ptr %scalar.fission.scratch, i32 0, i16 %fission.producer.index
; INDEX: ret i32
;
; ROW: scalar-IR reduction fission rejected: scalar-scratch-limit
; ROW-LABEL: define i1024 @row_cannot_fit(
; ROW: ret i1024

;--- narrow.ll
define i32 @narrow_max() {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i8 [0, %preheader], [%next, %loop]
  %r = phi i32 [17, %preheader], [%u, %loop]
  %c = zext i8 %iv to i32
  %u = add i32 %r, %c
  %next = add nuw i8 %iv, 1
  %done = icmp eq i8 %next, -1
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%u, %loop]
  ret i32 %result
}

;--- large.ll
define i32 @finite_large() {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %r = phi i32 [17, %preheader], [%u, %loop]
  %c = trunc i64 %iv to i32
  %u = add i32 %r, %c
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, -1
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%u, %loop]
  ret i32 %result
}

;--- index16.ll
target datalayout = "e-p:64:64:64:16-i64:64-n32:64-S128"
define i32 @limited_index() {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i32 [0, %preheader], [%next, %loop]
  %r = phi i32 [17, %preheader], [%u, %loop]
  %u = add i32 %r, %iv
  %next = add nuw i32 %iv, 1
  %done = icmp eq i32 %next, 16385
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%u, %loop]
  ret i32 %result
}

;--- index8.ll
target datalayout = "e-p:64:64:64:8-i64:64-n32:64-S128"
define i1024 @row_cannot_fit() {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i8 [0, %preheader], [%next, %loop]
  %r = phi i1024 [17, %preheader], [%u, %loop]
  %c = zext i8 %iv to i1024
  %u = add i1024 %r, %c
  %next = add nuw i8 %iv, 1
  %done = icmp eq i8 %next, 2
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i1024 [%u, %loop]
  ret i1024 %result
}
