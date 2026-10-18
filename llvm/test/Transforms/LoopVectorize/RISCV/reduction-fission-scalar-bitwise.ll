; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission -force-vector-width=1 -force-vector-interleave=0 -force-target-max-scalar-interleave=1 -scalable-vectorization=off -vplan-reduction-fission-min-reductions=1000000 -vplan-reduction-fission-min-chain-depth=1000000 -vplan-reduction-fission-min-pressure-percent=1000000 -S %s | FileCheck %s --check-prefix=FULL
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission -force-vector-width=1 -force-vector-interleave=0 -force-target-max-scalar-interleave=1 -scalable-vectorization=off -vplan-reduction-fission-allow-fp-reordering -vplan-reduction-fission-max-scratch-bytes=112 -S %s | FileCheck %s --check-prefix=CHUNK
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission -force-vector-width=1 -force-vector-interleave=0 -force-target-max-scalar-interleave=1 -vplan-reduction-fission-max-scratch-bytes=15 -pass-remarks-missed=vplan-reduction-fission -S %s -o %t.minimum 2> %t.minimum.remarks
; RUN: FileCheck %s --check-prefix=SMALL < %t.minimum.remarks
; RUN: FileCheck %s --check-prefix=MIN --implicit-check-not=scalar.fission < %t.minimum
;
; Six direct bitwise recurrences, both operand orders, two shared streams.
; Retained state and original writes deliberately prevent producer reordering.
; The executable driver uses these exact originals and an unsigned C oracle.
; 4*C + padding to 8 + 8*C: C=1/9/65 costs 16/112/784 bytes.
; A 111-byte ceiling fits C=8 (96 bytes), not C=9. Compact P=0 has no access.
; No identity contributions, FP rewrite, profitability or extra alias promises.

; MIN-LABEL: define void @bitwise_full(
; MIN: %u.a0 = and i32 %a0, %c
; MIN: %u.x1 = xor i64 %dc, %x1
; MIN: ret void
; FULL-LABEL: define void @bitwise_full(
; FULL: alloca [65 x i32]
; FULL: alloca [65 x i64]
; FULL-NOT: alloca
; FULL: store i32 %state.next, ptr %wp
; FULL: scalar.fission.consumer.body:
; FULL: %u.a0.consume = and i32 %a0.consume, {{%[-a-zA-Z$._0-9]+}}
; FULL: %u.a1.consume = and i32 {{%[-a-zA-Z$._0-9]+}}, %a1.consume
; FULL: %u.o0.consume = or i32 %o0.consume, {{%[-a-zA-Z$._0-9]+}}
; FULL: %u.o1.consume = or i32 {{%[-a-zA-Z$._0-9]+}}, %o1.consume
; FULL: %u.x0.consume = xor i64 %x0.consume, {{%[-a-zA-Z$._0-9]+}}
; FULL: %u.x1.consume = xor i64 {{%[-a-zA-Z$._0-9]+}}, %x1.consume
; FULL: ret void
; CHUNK-LABEL: define void @bitwise_full(
; CHUNK: alloca [9 x i32]
; CHUNK: alloca [9 x i64]
; CHUNK-NOT: alloca
; CHUNK: scalar.fission.chunk:
; CHUNK: %a0.chunk.carry = phi i32 [ -251691430, %preheader ]
; CHUNK: store i32 %state.next, ptr %wp
; CHUNK: scalar.fission.consumer.body:
; CHUNK: %u.a0.consume = and i32 %a0.consume, {{%[-a-zA-Z$._0-9]+}}
; CHUNK: %u.a1.consume = and i32 {{%[-a-zA-Z$._0-9]+}}, %a1.consume
; CHUNK: %u.o0.consume = or i32 %o0.consume, {{%[-a-zA-Z$._0-9]+}}
; CHUNK: %u.o1.consume = or i32 {{%[-a-zA-Z$._0-9]+}}, %o1.consume
; CHUNK: %u.x0.consume = xor i64 %x0.consume, {{%[-a-zA-Z$._0-9]+}}
; CHUNK: %u.x1.consume = xor i64 {{%[-a-zA-Z$._0-9]+}}, %x1.consume
; CHUNK: ret void
; SMALL: scalar-bitwise.c:12:3: scalar-IR reduction fission rejected: scalar-scratch-limit
define void @bitwise_full(ptr %a, ptr %mem, ptr %out, i64 %n, i32 %mode, i32 %seed) !dbg !10 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !11
loop:
  %iv = phi i64 [ 0, %preheader ], [ %next, %loop ]
  %state = phi i32 [ %seed, %preheader ], [ %state.next, %loop ]
  %a0 = phi i32 [ -251691430, %preheader ], [ %u.a0, %loop ]
  %a1 = phi i32 [ 1515890085, %preheader ], [ %u.a1, %loop ]
  %o0 = phi i32 [ 324508639, %preheader ], [ %u.o0, %loop ]
  %o1 = phi i32 [ 610839776, %preheader ], [ %u.o1, %loop ]
  %x0 = phi i64 [ 81985529216486895, %preheader ], [ %u.x0, %loop ]
  %x1 = phi i64 [ -81985529216486896, %preheader ], [ %u.x1, %loop ]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = xor i32 %state, %x
  %wide.c = zext i32 %c to i64
  %wide.state = zext i32 %state to i64
  %high = shl i64 %wide.state, 32
  %dc = or i64 %high, %wide.c
  %state.next = add i32 %state, %x
  %wp = getelementptr i32, ptr %mem, i64 %iv
  store i32 %state.next, ptr %wp, align 4
  %u.a0 = and i32 %a0, %c, !dbg !12
  %u.a1 = and i32 %c, %a1, !dbg !13
  %u.o0 = or i32 %o0, %c, !dbg !14
  %u.o1 = or i32 %c, %o1, !dbg !15
  %u.x0 = xor i64 %x0, %dc, !dbg !16
  %u.x1 = xor i64 %dc, %x1, !dbg !17
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %producer.exit, label %loop, !dbg !11
producer.exit:
  %out.a0 = phi i32 [ %u.a0, %loop ]
  %out.a1 = phi i32 [ %u.a1, %loop ]
  %out.o0 = phi i32 [ %u.o0, %loop ]
  %out.o1 = phi i32 [ %u.o1, %loop ]
  %out.x0 = phi i64 [ %u.x0, %loop ]
  %out.x1 = phi i64 [ %u.x1, %loop ]
  %out.state = phi i32 [ %state, %loop ]
  %out.state.next = phi i32 [ %state.next, %loop ]
  %out.c = phi i32 [ %c, %loop ]
  %out.dc = phi i64 [ %dc, %loop ]
  %out.iv = phi i64 [ %iv, %loop ]
  %out.next = phi i64 [ %next, %loop ]
  %z.a0 = zext i32 %out.a0 to i64
  %op.0 = getelementptr i64, ptr %out, i64 0
  store i64 %z.a0, ptr %op.0, align 8
  %z.a1 = zext i32 %out.a1 to i64
  %op.1 = getelementptr i64, ptr %out, i64 1
  store i64 %z.a1, ptr %op.1, align 8
  %z.o0 = zext i32 %out.o0 to i64
  %op.2 = getelementptr i64, ptr %out, i64 2
  store i64 %z.o0, ptr %op.2, align 8
  %z.o1 = zext i32 %out.o1 to i64
  %op.3 = getelementptr i64, ptr %out, i64 3
  store i64 %z.o1, ptr %op.3, align 8
  %op.4 = getelementptr i64, ptr %out, i64 4
  store i64 %out.x0, ptr %op.4, align 8
  %op.5 = getelementptr i64, ptr %out, i64 5
  store i64 %out.x1, ptr %op.5, align 8
  %z.state = zext i32 %out.state to i64
  %op.6 = getelementptr i64, ptr %out, i64 6
  store i64 %z.state, ptr %op.6, align 8
  %z.state.next = zext i32 %out.state.next to i64
  %op.7 = getelementptr i64, ptr %out, i64 7
  store i64 %z.state.next, ptr %op.7, align 8
  %z.c = zext i32 %out.c to i64
  %op.8 = getelementptr i64, ptr %out, i64 8
  store i64 %z.c, ptr %op.8, align 8
  %op.9 = getelementptr i64, ptr %out, i64 9
  store i64 %out.dc, ptr %op.9, align 8
  %op.10 = getelementptr i64, ptr %out, i64 10
  store i64 %out.iv, ptr %op.10, align 8
  %op.11 = getelementptr i64, ptr %out, i64 11
  store i64 %out.next, ptr %op.11, align 8
  br label %exit
exit:
  ret void
}

; MIN-LABEL: define void @bitwise_compact(
; MIN: %u.a0 = and i32 %a0, %c
; MIN: %u.x1 = xor i64 %dc, %x1
; MIN: ret void
; FULL-LABEL: define void @bitwise_compact(
; FULL: alloca [65 x i32]
; FULL: alloca [65 x i64]
; FULL-NOT: alloca
; FULL: store i32 %state.next, ptr %wp
; FULL: scalar.fission.consumer.body:
; FULL: %u.a0.consume = and i32 %a0.consume, {{%[-a-zA-Z$._0-9]+}}
; FULL: %u.a1.consume = and i32 {{%[-a-zA-Z$._0-9]+}}, %a1.consume
; FULL: %u.o0.consume = or i32 %o0.consume, {{%[-a-zA-Z$._0-9]+}}
; FULL: %u.o1.consume = or i32 {{%[-a-zA-Z$._0-9]+}}, %o1.consume
; FULL: %u.x0.consume = xor i64 %x0.consume, {{%[-a-zA-Z$._0-9]+}}
; FULL: %u.x1.consume = xor i64 {{%[-a-zA-Z$._0-9]+}}, %x1.consume
; FULL: ret void
; CHUNK-LABEL: define void @bitwise_compact(
; CHUNK: alloca [9 x i32]
; CHUNK: alloca [9 x i64]
; CHUNK-NOT: alloca
; CHUNK: scalar.fission.chunk:
; CHUNK: %a0.chunk.carry = phi i32 [ -251691430, %preheader ]
; CHUNK: store i32 %state.next, ptr %wp
; CHUNK: scalar.fission.consumer.body:
; CHUNK: %u.a0.consume = and i32 %a0.consume, {{%[-a-zA-Z$._0-9]+}}
; CHUNK: %u.a1.consume = and i32 {{%[-a-zA-Z$._0-9]+}}, %a1.consume
; CHUNK: %u.o0.consume = or i32 %o0.consume, {{%[-a-zA-Z$._0-9]+}}
; CHUNK: %u.o1.consume = or i32 {{%[-a-zA-Z$._0-9]+}}, %o1.consume
; CHUNK: %u.x0.consume = xor i64 %x0.consume, {{%[-a-zA-Z$._0-9]+}}
; CHUNK: %u.x1.consume = xor i64 {{%[-a-zA-Z$._0-9]+}}, %x1.consume
; CHUNK: ret void
; SMALL: scalar-bitwise.c:32:3: scalar-IR reduction fission rejected: scalar-scratch-limit
define void @bitwise_compact(ptr %a, ptr %mem, ptr %out, i64 %n, i32 %mode, i32 %seed) !dbg !20 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !21
loop:
  %iv = phi i64 [ 0, %preheader ], [ %next, %latch ]
  %state = phi i32 [ %seed, %preheader ], [ %state.next, %latch ]
  %a0 = phi i32 [ -251691430, %preheader ], [ %m.a0, %latch ]
  %a1 = phi i32 [ 1515890085, %preheader ], [ %m.a1, %latch ]
  %o0 = phi i32 [ 324508639, %preheader ], [ %m.o0, %latch ]
  %o1 = phi i32 [ 610839776, %preheader ], [ %m.o1, %latch ]
  %x0 = phi i64 [ 81985529216486895, %preheader ], [ %m.x0, %latch ]
  %x1 = phi i64 [ -81985529216486896, %preheader ], [ %m.x1, %latch ]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %c = xor i32 %state, %x
  %wide.c = zext i32 %c to i64
  %wide.state = zext i32 %state to i64
  %high = shl i64 %wide.state, 32
  %dc = or i64 %high, %wide.c
  %state.next = add i32 %state, %x
  %wp = getelementptr i32, ptr %mem, i64 %iv
  store i32 %state.next, ptr %wp, align 4
  %odd = and i64 %iv, 1
  %alternating = icmp ne i64 %odd, 0
  %first = icmp eq i64 %iv, 0
  %last.idx = sub i64 %n, 1
  %last = icmp eq i64 %iv, %last.idx
  %ends = or i1 %first, %last
  %period = urem i64 %iv, 18
  %active.block = icmp uge i64 %period, 9
  %state.bit = and i32 %state, 8
  %state.active = icmp ne i32 %state.bit, 0
  %is0 = icmp eq i32 %mode, 0
  %is2 = icmp eq i32 %mode, 2
  %is3 = icmp eq i32 %mode, 3
  %is4 = icmp eq i32 %mode, 4
  %is5 = icmp eq i32 %mode, 5
  %is6 = icmp eq i32 %mode, 6
  %is7 = icmp eq i32 %mode, 7
  %s7 = select i1 %is7, i1 %ends, i1 false
  %s6 = select i1 %is6, i1 %state.active, i1 %s7
  %s5 = select i1 %is5, i1 %active.block, i1 %s6
  %s4 = select i1 %is4, i1 %last, i1 %s5
  %s3 = select i1 %is3, i1 %first, i1 %s4
  %s2 = select i1 %is2, i1 %alternating, i1 %s3
  %active = or i1 %is0, %s2
  br i1 %active, label %left, label %right
left:
  %u.a0 = and i32 %a0, %c, !dbg !22
  %u.a1 = and i32 %c, %a1, !dbg !23
  %u.o0 = or i32 %o0, %c, !dbg !24
  %u.o1 = or i32 %c, %o1, !dbg !25
  %u.x0 = xor i64 %x0, %dc, !dbg !26
  %u.x1 = xor i64 %dc, %x1, !dbg !27
  br label %latch
right:
  br label %latch
latch:
  %m.a0 = phi i32 [ %u.a0, %left ], [ %a0, %right ]
  %m.a1 = phi i32 [ %u.a1, %left ], [ %a1, %right ]
  %m.o0 = phi i32 [ %u.o0, %left ], [ %o0, %right ]
  %m.o1 = phi i32 [ %u.o1, %left ], [ %o1, %right ]
  %m.x0 = phi i64 [ %u.x0, %left ], [ %x0, %right ]
  %m.x1 = phi i64 [ %u.x1, %left ], [ %x1, %right ]
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %producer.exit, label %loop, !dbg !21
producer.exit:
  %out.a0 = phi i32 [ %m.a0, %latch ]
  %out.a1 = phi i32 [ %m.a1, %latch ]
  %out.o0 = phi i32 [ %m.o0, %latch ]
  %out.o1 = phi i32 [ %m.o1, %latch ]
  %out.x0 = phi i64 [ %m.x0, %latch ]
  %out.x1 = phi i64 [ %m.x1, %latch ]
  %out.state = phi i32 [ %state, %latch ]
  %out.state.next = phi i32 [ %state.next, %latch ]
  %out.c = phi i32 [ %c, %latch ]
  %out.dc = phi i64 [ %dc, %latch ]
  %out.iv = phi i64 [ %iv, %latch ]
  %out.next = phi i64 [ %next, %latch ]
  %z.a0 = zext i32 %out.a0 to i64
  %op.0 = getelementptr i64, ptr %out, i64 0
  store i64 %z.a0, ptr %op.0, align 8
  %z.a1 = zext i32 %out.a1 to i64
  %op.1 = getelementptr i64, ptr %out, i64 1
  store i64 %z.a1, ptr %op.1, align 8
  %z.o0 = zext i32 %out.o0 to i64
  %op.2 = getelementptr i64, ptr %out, i64 2
  store i64 %z.o0, ptr %op.2, align 8
  %z.o1 = zext i32 %out.o1 to i64
  %op.3 = getelementptr i64, ptr %out, i64 3
  store i64 %z.o1, ptr %op.3, align 8
  %op.4 = getelementptr i64, ptr %out, i64 4
  store i64 %out.x0, ptr %op.4, align 8
  %op.5 = getelementptr i64, ptr %out, i64 5
  store i64 %out.x1, ptr %op.5, align 8
  %z.state = zext i32 %out.state to i64
  %op.6 = getelementptr i64, ptr %out, i64 6
  store i64 %z.state, ptr %op.6, align 8
  %z.state.next = zext i32 %out.state.next to i64
  %op.7 = getelementptr i64, ptr %out, i64 7
  store i64 %z.state.next, ptr %op.7, align 8
  %z.c = zext i32 %out.c to i64
  %op.8 = getelementptr i64, ptr %out, i64 8
  store i64 %z.c, ptr %op.8, align 8
  %op.9 = getelementptr i64, ptr %out, i64 9
  store i64 %out.dc, ptr %op.9, align 8
  %op.10 = getelementptr i64, ptr %out, i64 10
  store i64 %out.iv, ptr %op.10, align 8
  %op.11 = getelementptr i64, ptr %out, i64 11
  store i64 %out.next, ptr %op.11, align 8
  br label %exit
exit:
  ret void
}

; MIN-LABEL: define void @bitwise_affine(
; MIN: %u.a0 = and i32 %a0, %c
; MIN: %u.x1 = xor i64 %dc, %x1
; MIN: ret void
; FULL-LABEL: define void @bitwise_affine(
; FULL: alloca [65 x i32]
; FULL: alloca [65 x i64]
; FULL-NOT: alloca
; FULL: store i32 %state.next, ptr %wp
; FULL: scalar.fission.consumer.body:
; FULL: %u.a0.consume = and i32 %a0.consume, {{%[-a-zA-Z$._0-9]+}}
; FULL: %u.a1.consume = and i32 {{%[-a-zA-Z$._0-9]+}}, %a1.consume
; FULL: %u.o0.consume = or i32 %o0.consume, {{%[-a-zA-Z$._0-9]+}}
; FULL: %u.o1.consume = or i32 {{%[-a-zA-Z$._0-9]+}}, %o1.consume
; FULL: %u.x0.consume = xor i64 %x0.consume, {{%[-a-zA-Z$._0-9]+}}
; FULL: %u.x1.consume = xor i64 {{%[-a-zA-Z$._0-9]+}}, %x1.consume
; FULL: ret void
; CHUNK-LABEL: define void @bitwise_affine(
; CHUNK: alloca [9 x i32]
; CHUNK: alloca [9 x i64]
; CHUNK: scalar.fission.chunk:
; CHUNK-NOT: fission.chunk.remaining
; CHUNK: %fission.chunk.base = phi i64 [ 7, %preheader ], [ %fission.producer.iv.next, %scalar.fission.chunk.latch ]
; CHUNK: %next = add{{( nuw)?( nsw)?}} i64 %iv, 3
; CHUNK: %done = icmp eq i64 %next, %limit
; CHUNK: %fission.producer.iv.next = phi i64 [ %next, %loop ]
; CHUNK: scalar.fission.consumer.body:
; CHUNK: %u.x0.consume = xor i64 %x0.consume,
; CHUNK: br i1 %fission.producer.continue, label %scalar.fission.chunk, label %producer.exit
; CHUNK: ret void
; SMALL: scalar-bitwise.c:52:3: scalar-IR reduction fission rejected: scalar-scratch-limit
define void @bitwise_affine(ptr %a, ptr %mem, ptr %out, i64 %n, i32 %mode, i32 %seed) !dbg !30 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  %span = mul nuw nsw i64 %n, 3
  %limit = add nuw nsw i64 %span, 7
  br label %loop, !dbg !31
loop:
  %iv = phi i64 [ 7, %preheader ], [ %next, %loop ]
  %state = phi i32 [ %seed, %preheader ], [ %state.next, %loop ]
  %a0 = phi i32 [ -251691430, %preheader ], [ %u.a0, %loop ]
  %a1 = phi i32 [ 1515890085, %preheader ], [ %u.a1, %loop ]
  %o0 = phi i32 [ 324508639, %preheader ], [ %u.o0, %loop ]
  %o1 = phi i32 [ 610839776, %preheader ], [ %u.o1, %loop ]
  %x0 = phi i64 [ 81985529216486895, %preheader ], [ %u.x0, %loop ]
  %x1 = phi i64 [ -81985529216486896, %preheader ], [ %u.x1, %loop ]
  %distance = sub nuw nsw i64 %iv, 7
  %idx = udiv i64 %distance, 3
  %p = getelementptr i32, ptr %a, i64 %idx
  %x = load i32, ptr %p, align 4
  %c = xor i32 %state, %x
  %wide.c = zext i32 %c to i64
  %wide.state = zext i32 %state to i64
  %high = shl i64 %wide.state, 32
  %dc = or i64 %high, %wide.c
  %state.next = add i32 %state, %x
  %wp = getelementptr i32, ptr %mem, i64 %idx
  store i32 %state.next, ptr %wp, align 4
  %u.a0 = and i32 %a0, %c, !dbg !32
  %u.a1 = and i32 %c, %a1, !dbg !33
  %u.o0 = or i32 %o0, %c, !dbg !34
  %u.o1 = or i32 %c, %o1, !dbg !35
  %u.x0 = xor i64 %x0, %dc, !dbg !36
  %u.x1 = xor i64 %dc, %x1, !dbg !37
  %next = add nuw nsw i64 %iv, 3
  %done = icmp eq i64 %next, %limit
  br i1 %done, label %producer.exit, label %loop, !dbg !31
producer.exit:
  %out.a0 = phi i32 [ %u.a0, %loop ]
  %out.a1 = phi i32 [ %u.a1, %loop ]
  %out.o0 = phi i32 [ %u.o0, %loop ]
  %out.o1 = phi i32 [ %u.o1, %loop ]
  %out.x0 = phi i64 [ %u.x0, %loop ]
  %out.x1 = phi i64 [ %u.x1, %loop ]
  %out.state = phi i32 [ %state, %loop ]
  %out.state.next = phi i32 [ %state.next, %loop ]
  %out.c = phi i32 [ %c, %loop ]
  %out.dc = phi i64 [ %dc, %loop ]
  %out.iv = phi i64 [ %iv, %loop ]
  %out.next = phi i64 [ %next, %loop ]
  %z.a0 = zext i32 %out.a0 to i64
  %op.0 = getelementptr i64, ptr %out, i64 0
  store i64 %z.a0, ptr %op.0, align 8
  %z.a1 = zext i32 %out.a1 to i64
  %op.1 = getelementptr i64, ptr %out, i64 1
  store i64 %z.a1, ptr %op.1, align 8
  %z.o0 = zext i32 %out.o0 to i64
  %op.2 = getelementptr i64, ptr %out, i64 2
  store i64 %z.o0, ptr %op.2, align 8
  %z.o1 = zext i32 %out.o1 to i64
  %op.3 = getelementptr i64, ptr %out, i64 3
  store i64 %z.o1, ptr %op.3, align 8
  %op.4 = getelementptr i64, ptr %out, i64 4
  store i64 %out.x0, ptr %op.4, align 8
  %op.5 = getelementptr i64, ptr %out, i64 5
  store i64 %out.x1, ptr %op.5, align 8
  %z.state = zext i32 %out.state to i64
  %op.6 = getelementptr i64, ptr %out, i64 6
  store i64 %z.state, ptr %op.6, align 8
  %z.state.next = zext i32 %out.state.next to i64
  %op.7 = getelementptr i64, ptr %out, i64 7
  store i64 %z.state.next, ptr %op.7, align 8
  %z.c = zext i32 %out.c to i64
  %op.8 = getelementptr i64, ptr %out, i64 8
  store i64 %z.c, ptr %op.8, align 8
  %op.9 = getelementptr i64, ptr %out, i64 9
  store i64 %out.dc, ptr %op.9, align 8
  %op.10 = getelementptr i64, ptr %out, i64 10
  store i64 %out.iv, ptr %op.10, align 8
  %op.11 = getelementptr i64, ptr %out, i64 11
  store i64 %out.next, ptr %op.11, align 8
  br label %exit
exit:
  ret void
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-bitwise.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = !DISubroutineType(types: !5)
!5 = !{}
!10 = distinct !DISubprogram(name: "bitwise_full", scope: !1, file: !1, line: 10, type: !4, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 12, column: 3, scope: !10)
!12 = !DILocation(line: 13, column: 5, scope: !10)
!13 = !DILocation(line: 14, column: 5, scope: !10)
!14 = !DILocation(line: 15, column: 5, scope: !10)
!15 = !DILocation(line: 16, column: 5, scope: !10)
!16 = !DILocation(line: 17, column: 5, scope: !10)
!17 = !DILocation(line: 18, column: 5, scope: !10)
!20 = distinct !DISubprogram(name: "bitwise_compact", scope: !1, file: !1, line: 30, type: !4, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!21 = !DILocation(line: 32, column: 3, scope: !20)
!22 = !DILocation(line: 33, column: 5, scope: !20)
!23 = !DILocation(line: 34, column: 5, scope: !20)
!24 = !DILocation(line: 35, column: 5, scope: !20)
!25 = !DILocation(line: 36, column: 5, scope: !20)
!26 = !DILocation(line: 37, column: 5, scope: !20)
!27 = !DILocation(line: 38, column: 5, scope: !20)
!30 = distinct !DISubprogram(name: "bitwise_affine", scope: !1, file: !1, line: 50, type: !4, scopeLine: 50, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!31 = !DILocation(line: 52, column: 3, scope: !30)
!32 = !DILocation(line: 53, column: 5, scope: !30)
!33 = !DILocation(line: 54, column: 5, scope: !30)
!34 = !DILocation(line: 55, column: 5, scope: !30)
!35 = !DILocation(line: 56, column: 5, scope: !30)
!36 = !DILocation(line: 57, column: 5, scope: !30)
!37 = !DILocation(line: 58, column: 5, scope: !30)
