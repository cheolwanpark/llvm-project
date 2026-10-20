; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @minmax_full(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @minmax_compact(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @minmax_affine(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Three dependent contribution operations qualify the retained producer.
; Checks exercise standalone scalar fission and ordinary LV.
define void @minmax_full(ptr %a, ptr %mem, ptr %out, i64 %n, i32 %mode, i32 %seed) !dbg !10 {
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
  %b0 = phi i8 [ 13, %preheader ], [ %u.b0, %loop ]
  %b1 = phi i8 [ -27, %preheader ], [ %u.b1, %loop ]
  %q0 = phi i32 [ 17, %preheader ], [ %u.q0, %loop ]
  %q1 = phi i32 [ -7, %preheader ], [ %u.q1, %loop ]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %contribution.mix = mul i32 %state, 13
  %contribution.bias = add i32 %contribution.mix, 7
  %c = xor i32 %contribution.bias, %x
  %bc = trunc i32 %c to i8
  %wide.c = zext i32 %c to i64
  %wide.state = zext i32 %state to i64
  %high = shl i64 %wide.state, 32
  %dc = or i64 %high, %wide.c
  %state.next = mul i32 %state, %x
  %wp = getelementptr i32, ptr %mem, i64 %iv
  store i32 %state.next, ptr %wp, align 4
  %u.a0 = call i32 @llvm.smin.i32(i32 %a0, i32 %c) #0, !dbg !12
  %u.a1 = call i32 @llvm.smin.i32(i32 %c, i32 %a1) #0, !dbg !13
  %u.o0 = call i32 @llvm.smax.i32(i32 %o0, i32 %c) #0, !dbg !14
  %u.o1 = call i32 @llvm.smax.i32(i32 %c, i32 %o1) #0, !dbg !15
  %u.x0 = call i64 @llvm.umin.i64(i64 %x0, i64 %dc) #0, !dbg !16
  %u.x1 = call i64 @llvm.umax.i64(i64 %dc, i64 %x1) #0, !dbg !17
  %u.b0 = call i8 @llvm.umin.i8(i8 %bc, i8 %b0) #0, !dbg !18
  %u.b1 = call i8 @llvm.umax.i8(i8 %b1, i8 %bc) #0, !dbg !19
  %u.q0 = add i32 %q0, %c, !dbg !12
  %u.q1 = mul i32 %c, %q1, !dbg !13
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
  %out.b0 = phi i8 [ %u.b0, %loop ]
  %out.b1 = phi i8 [ %u.b1, %loop ]
  %out.q0 = phi i32 [ %u.q0, %loop ]
  %out.q1 = phi i32 [ %u.q1, %loop ]
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
  %z.b0 = zext i8 %out.b0 to i64
  %op.12 = getelementptr i64, ptr %out, i64 12
  store i64 %z.b0, ptr %op.12, align 8
  %z.b1 = zext i8 %out.b1 to i64
  %op.13 = getelementptr i64, ptr %out, i64 13
  store i64 %z.b1, ptr %op.13, align 8
  %z.q0 = zext i32 %out.q0 to i64
  %op.14 = getelementptr i64, ptr %out, i64 14
  store i64 %z.q0, ptr %op.14, align 8
  %z.q1 = zext i32 %out.q1 to i64
  %op.15 = getelementptr i64, ptr %out, i64 15
  store i64 %z.q1, ptr %op.15, align 8
  br label %exit
exit:
  ret void
}

define void @minmax_compact(ptr %a, ptr %mem, ptr %out, i64 %n, i32 %mode, i32 %seed) !dbg !20 {
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
  %b0 = phi i8 [ 13, %preheader ], [ %m.b0, %latch ]
  %b1 = phi i8 [ -27, %preheader ], [ %m.b1, %latch ]
  %q0 = phi i32 [ 17, %preheader ], [ %m.q0, %latch ]
  %q1 = phi i32 [ -7, %preheader ], [ %m.q1, %latch ]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %contribution.mix = mul i32 %state, 13
  %contribution.bias = add i32 %contribution.mix, 7
  %c = xor i32 %contribution.bias, %x
  %bc = trunc i32 %c to i8
  %wide.c = zext i32 %c to i64
  %wide.state = zext i32 %state to i64
  %high = shl i64 %wide.state, 32
  %dc = or i64 %high, %wide.c
  %state.next = mul i32 %state, %x
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
  %u.a0 = call i32 @llvm.smin.i32(i32 %a0, i32 %c) #0, !dbg !22
  %u.a1 = call i32 @llvm.smin.i32(i32 %c, i32 %a1) #0, !dbg !23
  %u.o0 = call i32 @llvm.smax.i32(i32 %o0, i32 %c) #0, !dbg !24
  %u.o1 = call i32 @llvm.smax.i32(i32 %c, i32 %o1) #0, !dbg !25
  %u.x0 = call i64 @llvm.umin.i64(i64 %x0, i64 %dc) #0, !dbg !26
  %u.x1 = call i64 @llvm.umax.i64(i64 %dc, i64 %x1) #0, !dbg !27
  %u.b0 = call i8 @llvm.umin.i8(i8 %bc, i8 %b0) #0, !dbg !28
  %u.b1 = call i8 @llvm.umax.i8(i8 %b1, i8 %bc) #0, !dbg !29
  %u.q0 = add i32 %q0, %c, !dbg !22
  %u.q1 = mul i32 %c, %q1, !dbg !23
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
  %m.b0 = phi i8 [ %u.b0, %left ], [ %b0, %right ]
  %m.b1 = phi i8 [ %u.b1, %left ], [ %b1, %right ]
  %m.q0 = phi i32 [ %u.q0, %left ], [ %q0, %right ]
  %m.q1 = phi i32 [ %u.q1, %left ], [ %q1, %right ]
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
  %out.b0 = phi i8 [ %m.b0, %latch ]
  %out.b1 = phi i8 [ %m.b1, %latch ]
  %out.q0 = phi i32 [ %m.q0, %latch ]
  %out.q1 = phi i32 [ %m.q1, %latch ]
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
  %z.b0 = zext i8 %out.b0 to i64
  %op.12 = getelementptr i64, ptr %out, i64 12
  store i64 %z.b0, ptr %op.12, align 8
  %z.b1 = zext i8 %out.b1 to i64
  %op.13 = getelementptr i64, ptr %out, i64 13
  store i64 %z.b1, ptr %op.13, align 8
  %z.q0 = zext i32 %out.q0 to i64
  %op.14 = getelementptr i64, ptr %out, i64 14
  store i64 %z.q0, ptr %op.14, align 8
  %z.q1 = zext i32 %out.q1 to i64
  %op.15 = getelementptr i64, ptr %out, i64 15
  store i64 %z.q1, ptr %op.15, align 8
  br label %exit
exit:
  ret void
}

define void @minmax_affine(ptr %a, ptr %mem, ptr %out, i64 %n, i32 %mode, i32 %seed) !dbg !30 {
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
  %b0 = phi i8 [ 13, %preheader ], [ %u.b0, %loop ]
  %b1 = phi i8 [ -27, %preheader ], [ %u.b1, %loop ]
  %q0 = phi i32 [ 17, %preheader ], [ %u.q0, %loop ]
  %q1 = phi i32 [ -7, %preheader ], [ %u.q1, %loop ]
  %distance = sub nuw nsw i64 %iv, 7
  %idx = udiv i64 %distance, 3
  %p = getelementptr i32, ptr %a, i64 %idx
  %x = load i32, ptr %p, align 4
  %contribution.mix = mul i32 %state, 13
  %contribution.bias = add i32 %contribution.mix, 7
  %c = xor i32 %contribution.bias, %x
  %bc = trunc i32 %c to i8
  %wide.c = zext i32 %c to i64
  %wide.state = zext i32 %state to i64
  %high = shl i64 %wide.state, 32
  %dc = or i64 %high, %wide.c
  %state.next = mul i32 %state, %x
  %wp = getelementptr i32, ptr %mem, i64 %idx
  store i32 %state.next, ptr %wp, align 4
  %u.a0 = call i32 @llvm.smin.i32(i32 %a0, i32 %c) #0, !dbg !32
  %u.a1 = call i32 @llvm.smin.i32(i32 %c, i32 %a1) #0, !dbg !33
  %u.o0 = call i32 @llvm.smax.i32(i32 %o0, i32 %c) #0, !dbg !34
  %u.o1 = call i32 @llvm.smax.i32(i32 %c, i32 %o1) #0, !dbg !35
  %u.x0 = call i64 @llvm.umin.i64(i64 %x0, i64 %dc) #0, !dbg !36
  %u.x1 = call i64 @llvm.umax.i64(i64 %dc, i64 %x1) #0, !dbg !37
  %u.b0 = call i8 @llvm.umin.i8(i8 %bc, i8 %b0) #0, !dbg !38
  %u.b1 = call i8 @llvm.umax.i8(i8 %b1, i8 %bc) #0, !dbg !39
  %u.q0 = add i32 %q0, %c, !dbg !32
  %u.q1 = mul i32 %c, %q1, !dbg !33
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
  %out.b0 = phi i8 [ %u.b0, %loop ]
  %out.b1 = phi i8 [ %u.b1, %loop ]
  %out.q0 = phi i32 [ %u.q0, %loop ]
  %out.q1 = phi i32 [ %u.q1, %loop ]
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
  %z.b0 = zext i8 %out.b0 to i64
  %op.12 = getelementptr i64, ptr %out, i64 12
  store i64 %z.b0, ptr %op.12, align 8
  %z.b1 = zext i8 %out.b1 to i64
  %op.13 = getelementptr i64, ptr %out, i64 13
  store i64 %z.b1, ptr %op.13, align 8
  %z.q0 = zext i32 %out.q0 to i64
  %op.14 = getelementptr i64, ptr %out, i64 14
  store i64 %z.q0, ptr %op.14, align 8
  %z.q1 = zext i32 %out.q1 to i64
  %op.15 = getelementptr i64, ptr %out, i64 15
  store i64 %z.q1, ptr %op.15, align 8
  br label %exit
exit:
  ret void
}

declare i32 @llvm.smin.i32(i32, i32)
declare i32 @llvm.smax.i32(i32, i32)
declare i64 @llvm.umin.i64(i64, i64)
declare i64 @llvm.umax.i64(i64, i64)
declare i8 @llvm.umin.i8(i8, i8)
declare i8 @llvm.umax.i8(i8, i8)
attributes #0 = { nounwind willreturn memory(none) }

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-minmax.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = !DISubroutineType(types: !5)
!5 = !{}
!10 = distinct !DISubprogram(name: "minmax_full", scope: !1, file: !1, line: 10, type: !4, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 12, column: 3, scope: !10)
!12 = !DILocation(line: 13, column: 5, scope: !10)
!13 = !DILocation(line: 14, column: 5, scope: !10)
!14 = !DILocation(line: 15, column: 5, scope: !10)
!15 = !DILocation(line: 16, column: 5, scope: !10)
!16 = !DILocation(line: 17, column: 5, scope: !10)
!17 = !DILocation(line: 18, column: 5, scope: !10)
!20 = distinct !DISubprogram(name: "minmax_compact", scope: !1, file: !1, line: 30, type: !4, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!21 = !DILocation(line: 32, column: 3, scope: !20)
!22 = !DILocation(line: 33, column: 5, scope: !20)
!23 = !DILocation(line: 34, column: 5, scope: !20)
!24 = !DILocation(line: 35, column: 5, scope: !20)
!25 = !DILocation(line: 36, column: 5, scope: !20)
!26 = !DILocation(line: 37, column: 5, scope: !20)
!27 = !DILocation(line: 38, column: 5, scope: !20)
!30 = distinct !DISubprogram(name: "minmax_affine", scope: !1, file: !1, line: 50, type: !4, scopeLine: 50, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!31 = !DILocation(line: 52, column: 3, scope: !30)
!32 = !DILocation(line: 53, column: 5, scope: !30)
!33 = !DILocation(line: 54, column: 5, scope: !30)
!34 = !DILocation(line: 55, column: 5, scope: !30)
!35 = !DILocation(line: 56, column: 5, scope: !30)
!36 = !DILocation(line: 57, column: 5, scope: !30)
!37 = !DILocation(line: 58, column: 5, scope: !30)
!18 = !DILocation(line: 19, column: 5, scope: !10)
!19 = !DILocation(line: 20, column: 5, scope: !10)
!28 = !DILocation(line: 39, column: 5, scope: !20)
!29 = !DILocation(line: 40, column: 5, scope: !20)
!38 = !DILocation(line: 59, column: 5, scope: !30)
!39 = !DILocation(line: 60, column: 5, scope: !30)
