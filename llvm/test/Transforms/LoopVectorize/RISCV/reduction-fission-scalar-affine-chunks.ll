; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @nc_offset(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @nc_stride(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @nc_down(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @nc_early(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @nc_current(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @nc_compact(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @nc_narrow(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

define void @nc_offset(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                     ptr %dout, i64 %n, i64 %begin, double %start) !dbg !10 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  %limit = add i64 %n, 7
  br label %loop, !dbg !11
loop:
  %iv = phi i64 [7, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %older = phi i32 [-11, %preheader], [%prev, %latch]
  %dstate = phi double [%start, %preheader], [%dnext, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %distance = sub i64 %iv, 7
  %index = udiv i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %state.next = add i32 %x, %older
  %dnext = fadd double %dstate, %dx
  br label %latch
latch:
  %raw = xor i32 %prev, %state.next
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dnext, %dstate
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add i64 %iv, 1
  %done = icmp eq i64 %next, %limit
  br i1 %done, label %producer.exit, label %loop, !dbg !11
producer.exit:
  %out.r0 = phi i32 [%u0, %latch]
  %out.r1 = phi i32 [%u1, %latch]
  %out.rd = phi double [%ud, %latch]
  %out.prev = phi i32 [%prev, %latch]
  %out.older = phi i32 [%older, %latch]
  %out.next = phi i32 [%state.next, %latch]
  %out.iv = phi i64 [%iv, %latch]
  %out.ivnext = phi i64 [%next, %latch]
  %out.dstate = phi double [%dstate, %latch]
  %out.dnext = phi double [%dnext, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  %o2 = getelementptr i32, ptr %out, i64 2
  %o3 = getelementptr i32, ptr %out, i64 3
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %out.r0, ptr %out, align 4
  store i32 %out.r1, ptr %o1, align 4
  store i32 %out.prev, ptr %o2, align 4
  store i32 %out.older, ptr %o3, align 4
  store i32 %out.next, ptr %o4, align 4
  %i1 = getelementptr i64, ptr %indices, i64 1
  store i64 %out.iv, ptr %indices, align 8
  store i64 %out.ivnext, ptr %i1, align 8
  %d1 = getelementptr double, ptr %dout, i64 1
  %d2 = getelementptr double, ptr %dout, i64 2
  store double %out.rd, ptr %dout, align 8
  store double %out.dstate, ptr %d1, align 8
  store double %out.dnext, ptr %d2, align 8
  ret void
bypass:
  ret void
}

define void @nc_stride(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                     ptr %dout, i64 %n, i64 %begin, double %start) !dbg !12 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  %span = mul i64 %n, 3
  %limit = add i64 %begin, %span
  br label %loop, !dbg !13
loop:
  %iv = phi i64 [%begin, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %older = phi i32 [-11, %preheader], [%prev, %latch]
  %dstate = phi double [%start, %preheader], [%dnext, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %distance = sub i64 %iv, %begin
  %index.next = udiv i64 %distance, 3
  %p = getelementptr i32, ptr %a, i64 %index.next
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %index.next
  %dx = load double, ptr %dp, align 8
  %state.next = add i32 %x, %older
  %dnext = fadd double %dstate, %dx
  br label %latch
latch:
  %raw = xor i32 %prev, %state.next
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dnext, %dstate
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add i64 %iv, 3
  %done = icmp ne i64 %limit, %next
  br i1 %done, label %loop, label %producer.exit, !dbg !13
producer.exit:
  %out.r0 = phi i32 [%u0, %latch]
  %out.r1 = phi i32 [%u1, %latch]
  %out.rd = phi double [%ud, %latch]
  %out.prev = phi i32 [%prev, %latch]
  %out.older = phi i32 [%older, %latch]
  %out.next = phi i32 [%state.next, %latch]
  %out.iv = phi i64 [%iv, %latch]
  %out.ivnext = phi i64 [%next, %latch]
  %out.dstate = phi double [%dstate, %latch]
  %out.dnext = phi double [%dnext, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  %o2 = getelementptr i32, ptr %out, i64 2
  %o3 = getelementptr i32, ptr %out, i64 3
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %out.r0, ptr %out, align 4
  store i32 %out.r1, ptr %o1, align 4
  store i32 %out.prev, ptr %o2, align 4
  store i32 %out.older, ptr %o3, align 4
  store i32 %out.next, ptr %o4, align 4
  %i1 = getelementptr i64, ptr %indices, i64 1
  store i64 %out.iv, ptr %indices, align 8
  store i64 %out.ivnext, ptr %i1, align 8
  %d1 = getelementptr double, ptr %dout, i64 1
  %d2 = getelementptr double, ptr %dout, i64 2
  store double %out.rd, ptr %dout, align 8
  store double %out.dstate, ptr %d1, align 8
  store double %out.dnext, ptr %d2, align 8
  ret void
bypass:
  ret void
}

define void @nc_down(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                     ptr %dout, i64 %n, i64 %begin, double %start) !dbg !14 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  %span = mul i64 %n, 3
  %limit = sub i64 %begin, %span
  br label %loop, !dbg !15
loop:
  %iv = phi i64 [%begin, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %older = phi i32 [-11, %preheader], [%prev, %latch]
  %dstate = phi double [%start, %preheader], [%dnext, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %distance = sub i64 %begin, %iv
  %current.iteration.next = udiv i64 %distance, 3
  %p = getelementptr i32, ptr %a, i64 %current.iteration.next
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %current.iteration.next
  %dx = load double, ptr %dp, align 8
  %state.next = add i32 %x, %older
  %dnext = fadd double %dstate, %dx
  br label %latch
latch:
  %raw = xor i32 %prev, %state.next
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dnext, %dstate
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = sub i64 %iv, 3
  %done = icmp ugt i64 %next, %limit
  br i1 %done, label %loop, label %producer.exit, !dbg !15
producer.exit:
  %out.r0 = phi i32 [%u0, %latch]
  %out.r1 = phi i32 [%u1, %latch]
  %out.rd = phi double [%ud, %latch]
  %out.prev = phi i32 [%prev, %latch]
  %out.older = phi i32 [%older, %latch]
  %out.next = phi i32 [%state.next, %latch]
  %out.iv = phi i64 [%iv, %latch]
  %out.ivnext = phi i64 [%next, %latch]
  %out.dstate = phi double [%dstate, %latch]
  %out.dnext = phi double [%dnext, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  %o2 = getelementptr i32, ptr %out, i64 2
  %o3 = getelementptr i32, ptr %out, i64 3
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %out.r0, ptr %out, align 4
  store i32 %out.r1, ptr %o1, align 4
  store i32 %out.prev, ptr %o2, align 4
  store i32 %out.older, ptr %o3, align 4
  store i32 %out.next, ptr %o4, align 4
  %i1 = getelementptr i64, ptr %indices, i64 1
  store i64 %out.iv, ptr %indices, align 8
  store i64 %out.ivnext, ptr %i1, align 8
  %d1 = getelementptr double, ptr %dout, i64 1
  %d2 = getelementptr double, ptr %dout, i64 2
  store double %out.rd, ptr %dout, align 8
  store double %out.dstate, ptr %d1, align 8
  store double %out.dnext, ptr %d2, align 8
  ret void
bypass:
  ret void
}

define void @nc_early(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                     ptr %dout, i64 %n, i64 %begin, double %start) !dbg !16 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  %span = mul i64 %n, 3
  %limit = add i64 %begin, %span
  br label %loop, !dbg !17
loop:
  %iv = phi i64 [%begin, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %older = phi i32 [-11, %preheader], [%prev, %latch]
  %dstate = phi double [%start, %preheader], [%dnext, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %distance = sub i64 %iv, %begin
  %index = udiv i64 %distance, 3
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %state.next = add i32 %x, %older
  %dnext = fadd double %dstate, %dx
  br label %latch
latch:
  %raw = xor i32 %prev, %state.next
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dnext, %dstate
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add i64 %iv, 3
  %done = icmp slt i64 %next, %limit
  br i1 %done, label %loop, label %producer.exit, !dbg !17
producer.exit:
  %out.r0 = phi i32 [%u0, %latch]
  %out.r1 = phi i32 [%u1, %latch]
  %out.rd = phi double [%ud, %latch]
  %out.prev = phi i32 [%prev, %latch]
  %out.older = phi i32 [%older, %latch]
  %out.next = phi i32 [%state.next, %latch]
  %out.iv = phi i64 [%iv, %latch]
  %out.ivnext = phi i64 [%next, %latch]
  %out.dstate = phi double [%dstate, %latch]
  %out.dnext = phi double [%dnext, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  %o2 = getelementptr i32, ptr %out, i64 2
  %o3 = getelementptr i32, ptr %out, i64 3
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %out.r0, ptr %out, align 4
  store i32 %out.r1, ptr %o1, align 4
  store i32 %out.prev, ptr %o2, align 4
  store i32 %out.older, ptr %o3, align 4
  store i32 %out.next, ptr %o4, align 4
  %i1 = getelementptr i64, ptr %indices, i64 1
  store i64 %out.iv, ptr %indices, align 8
  store i64 %out.ivnext, ptr %i1, align 8
  %d1 = getelementptr double, ptr %dout, i64 1
  %d2 = getelementptr double, ptr %dout, i64 2
  store double %out.rd, ptr %dout, align 8
  store double %out.dstate, ptr %d1, align 8
  store double %out.dnext, ptr %d2, align 8
  ret void
bypass:
  ret void
}

define void @nc_current(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                     ptr %dout, i64 %n, i64 %begin, double %start) !dbg !18 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  %limit = sub i64 %begin, %n
  br label %loop, !dbg !19
loop:
  %iv = phi i64 [%begin, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %older = phi i32 [-11, %preheader], [%prev, %latch]
  %dstate = phi double [%start, %preheader], [%dnext, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %index = sub i64 %begin, %iv
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %state.next = add i32 %x, %older
  %dnext = fadd double %dstate, %dx
  br label %latch
latch:
  %raw = xor i32 %prev, %state.next
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dnext, %dstate
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = sub i64 %iv, 1
  %done = icmp ne i64 %limit, %iv
  br i1 %done, label %loop, label %producer.exit, !dbg !19
producer.exit:
  %out.r0 = phi i32 [%u0, %latch]
  %out.r1 = phi i32 [%u1, %latch]
  %out.rd = phi double [%ud, %latch]
  %out.prev = phi i32 [%prev, %latch]
  %out.older = phi i32 [%older, %latch]
  %out.next = phi i32 [%state.next, %latch]
  %out.iv = phi i64 [%iv, %latch]
  %out.ivnext = phi i64 [%next, %latch]
  %out.dstate = phi double [%dstate, %latch]
  %out.dnext = phi double [%dnext, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  %o2 = getelementptr i32, ptr %out, i64 2
  %o3 = getelementptr i32, ptr %out, i64 3
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %out.r0, ptr %out, align 4
  store i32 %out.r1, ptr %o1, align 4
  store i32 %out.prev, ptr %o2, align 4
  store i32 %out.older, ptr %o3, align 4
  store i32 %out.next, ptr %o4, align 4
  %i1 = getelementptr i64, ptr %indices, i64 1
  store i64 %out.iv, ptr %indices, align 8
  store i64 %out.ivnext, ptr %i1, align 8
  %d1 = getelementptr double, ptr %dout, i64 1
  %d2 = getelementptr double, ptr %dout, i64 2
  store double %out.rd, ptr %dout, align 8
  store double %out.dstate, ptr %d1, align 8
  store double %out.dnext, ptr %d2, align 8
  ret void
bypass:
  ret void
}

define void @nc_compact(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                     ptr %dout, i64 %n, i64 %begin, double %start) !dbg !20 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  %span = mul i64 %n, 3
  %limit = sub i64 %begin, %span
  br label %loop, !dbg !21
loop:
  %iv = phi i64 [%begin, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %older = phi i32 [-11, %preheader], [%prev, %latch]
  %dstate = phi double [%start, %preheader], [%dnext, %latch]
  %r0 = phi i32 [17, %preheader], [%u0.merge, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1.merge, %latch]
  %rd = phi double [%start, %preheader], [%ud.merge, %latch]
  %distance = sub i64 %begin, %iv
  %index = udiv i64 %distance, 3
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %state.next = add i32 %x, %older
  %dnext = fadd double %dstate, %dx
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch
left:
  %raw = xor i32 %prev, %state.next
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dnext, %dstate
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  br label %latch
latch:
  %u0.merge = phi i32 [%u0, %left], [%r0, %loop]
  %u1.merge = phi i32 [%r1, %loop], [%u1, %left]
  %ud.merge = phi double [%ud, %left], [%rd, %loop]
  %next = sub i64 %iv, 3
  %done = icmp sge i64 %limit, %next
  br i1 %done, label %producer.exit, label %loop, !dbg !21
producer.exit:
  %out.r0 = phi i32 [%u0.merge, %latch]
  %out.r1 = phi i32 [%u1.merge, %latch]
  %out.rd = phi double [%ud.merge, %latch]
  %out.prev = phi i32 [%prev, %latch]
  %out.older = phi i32 [%older, %latch]
  %out.next = phi i32 [%state.next, %latch]
  %out.iv = phi i64 [%iv, %latch]
  %out.ivnext = phi i64 [%next, %latch]
  %out.dstate = phi double [%dstate, %latch]
  %out.dnext = phi double [%dnext, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  %o2 = getelementptr i32, ptr %out, i64 2
  %o3 = getelementptr i32, ptr %out, i64 3
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %out.r0, ptr %out, align 4
  store i32 %out.r1, ptr %o1, align 4
  store i32 %out.prev, ptr %o2, align 4
  store i32 %out.older, ptr %o3, align 4
  store i32 %out.next, ptr %o4, align 4
  %i1 = getelementptr i64, ptr %indices, i64 1
  store i64 %out.iv, ptr %indices, align 8
  store i64 %out.ivnext, ptr %i1, align 8
  %d1 = getelementptr double, ptr %dout, i64 1
  %d2 = getelementptr double, ptr %dout, i64 2
  store double %out.rd, ptr %dout, align 8
  store double %out.dstate, ptr %d1, align 8
  store double %out.dnext, ptr %d2, align 8
  ret void
bypass:
  ret void
}

define void @nc_narrow(ptr readonly %a, ptr readonly %fp, ptr %out, ptr %indices,
                     ptr %dout, i64 %n, i64 %begin, double %start) !dbg !22 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  %small.begin = trunc i64 %begin to i8
  %small.n = trunc i64 %n to i8
  %span = mul i8 %small.n, 3
  %limit = add i8 %small.begin, %span
  br label %loop, !dbg !23
loop:
  %iv = phi i8 [%small.begin, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %older = phi i32 [-11, %preheader], [%prev, %latch]
  %dstate = phi double [%start, %preheader], [%dnext, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %distance = sub i8 %iv, %small.begin
  %small.index = udiv i8 %distance, 3
  %index = zext i8 %small.index to i64
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %state.next = add i32 %x, %older
  %dnext = fadd double %dstate, %dx
  br label %latch
latch:
  %raw = xor i32 %prev, %state.next
  %c = call i32 @scalar_helper(i32 %raw)
  %dc = fsub double %dnext, %dstate
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %next = add i8 %iv, 3
  %done = icmp eq i8 %limit, %next
  br i1 %done, label %producer.exit, label %loop, !dbg !23
producer.exit:
  %out.r0 = phi i32 [%u0, %latch]
  %out.r1 = phi i32 [%u1, %latch]
  %out.rd = phi double [%ud, %latch]
  %out.prev = phi i32 [%prev, %latch]
  %out.older = phi i32 [%older, %latch]
  %out.next = phi i32 [%state.next, %latch]
  %out.iv = phi i8 [%iv, %latch]
  %out.ivnext = phi i8 [%next, %latch]
  %out.dstate = phi double [%dstate, %latch]
  %out.dnext = phi double [%dnext, %latch]
  %wide.iv = zext i8 %out.iv to i64
  %wide.next = zext i8 %out.ivnext to i64
  %o1 = getelementptr i32, ptr %out, i64 1
  %o2 = getelementptr i32, ptr %out, i64 2
  %o3 = getelementptr i32, ptr %out, i64 3
  %o4 = getelementptr i32, ptr %out, i64 4
  store i32 %out.r0, ptr %out, align 4
  store i32 %out.r1, ptr %o1, align 4
  store i32 %out.prev, ptr %o2, align 4
  store i32 %out.older, ptr %o3, align 4
  store i32 %out.next, ptr %o4, align 4
  %i1 = getelementptr i64, ptr %indices, i64 1
  store i64 %wide.iv, ptr %indices, align 8
  store i64 %wide.next, ptr %i1, align 8
  %d1 = getelementptr double, ptr %dout, i64 1
  %d2 = getelementptr double, ptr %dout, i64 2
  store double %out.rd, ptr %dout, align 8
  store double %out.dstate, ptr %d1, align 8
  store double %out.dnext, ptr %d2, align 8
  ret void
bypass:
  ret void
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-affine-chunks.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = !DISubroutineType(types: !5)
!5 = !{}
!10 = distinct !DISubprogram(name: "nc_offset", scope: !1, file: !1, line: 10, type: !4, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 12, column: 3, scope: !10)
!12 = distinct !DISubprogram(name: "nc_stride", scope: !1, file: !1, line: 20, type: !4, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 22, column: 3, scope: !12)
!14 = distinct !DISubprogram(name: "nc_down", scope: !1, file: !1, line: 30, type: !4, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!15 = !DILocation(line: 32, column: 3, scope: !14)
!16 = distinct !DISubprogram(name: "nc_early", scope: !1, file: !1, line: 40, type: !4, scopeLine: 40, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!17 = !DILocation(line: 42, column: 3, scope: !16)
!18 = distinct !DISubprogram(name: "nc_current", scope: !1, file: !1, line: 50, type: !4, scopeLine: 50, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!19 = !DILocation(line: 52, column: 3, scope: !18)
!20 = distinct !DISubprogram(name: "nc_compact", scope: !1, file: !1, line: 60, type: !4, scopeLine: 60, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!21 = !DILocation(line: 62, column: 3, scope: !20)
!22 = distinct !DISubprogram(name: "nc_narrow", scope: !1, file: !1, line: 70, type: !4, scopeLine: 70, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!23 = !DILocation(line: 72, column: 3, scope: !22)
