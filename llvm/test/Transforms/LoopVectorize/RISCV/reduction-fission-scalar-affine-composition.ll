; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission -force-vector-width=1 \
; RUN:   -force-vector-interleave=0 -force-target-max-scalar-interleave=1 -scalable-vectorization=off \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=112 -S %s | FileCheck %s
;
; Composition of original-control chunks with closed multiplication/bitwise
; recurrences, exact fneg, ordered subtraction, retained state and stores.
; Each write to the NEXT input feeds a later original iteration, including
; across chunk boundaries. Inputs and final outputs may alias. No noalias,
; fast-math, errno or endpoint-as-count assumption is introduced.
; The companion checker certifies actual transformed scalar/vector/tail IR.
; Mandatory host execution compares these exact originals and transformed
; paths against a nonchunked C oracle for C=1/8/9/16, both FP policies, LV1/LV2.
; Defined products use factors 0/1, preserving nuw and nsw on every prefix.
declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable

; CHECK-LABEL: define void @nc_mul_store(
; CHECK: alloca [9 x i32]
; CHECK: alloca [9 x double]
; CHECK: scalar.fission.chunk:
; CHECK-NOT: fission.chunk.remaining
; CHECK: fneg double %dx
; CHECK: store i32 %state.next, ptr %wp, align 4
; CHECK: store double %dc, ptr %dp, align 8
; CHECK: scalar.fission.consumer.ph:
; CHECK: scalar.fission.consumer.body:
; CHECK: %u0.consume = mul i32 %r0.consume,
; CHECK: %u1.consume = mul i32 {{%[-a-zA-Z$._0-9]+}}, %r1.consume
; CHECK: %ud.consume = fadd double %rd.consume,
; CHECK: br i1 %fission.producer.continue, label %scalar.fission.chunk, label %producer.exit
; CHECK: ret void
define void @nc_mul_store(ptr %a, ptr %fp, ptr %out, ptr %indices,
                     ptr %dout, i64 %n, i64 %begin, double %start) !dbg !100 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  %span = mul i64 %n, 3
  %limit = add i64 %begin, %span
  br label %loop, !dbg !101
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
  %dc = fneg double %dx, !dbg !101
  %wp = getelementptr i32, ptr %p, i64 1
  store i32 %state.next, ptr %wp, align 4
  store double %dc, ptr %dp, align 8
  %u0 = mul i32 %r0, %c, !dbg !101
  %u1 = mul i32 %c, %r1, !dbg !101
  %ud = fadd double %rd, %dc, !dbg !101
  %next = add i64 %iv, 3
  %done = icmp ne i64 %limit, %next
  br i1 %done, label %loop, label %producer.exit, !dbg !101
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

; CHECK-LABEL: define void @nc_bits_store(
; CHECK: alloca [9 x i32]
; CHECK: alloca [9 x double]
; CHECK: scalar.fission.chunk:
; CHECK-NOT: fission.chunk.remaining
; CHECK: fneg double %dx
; CHECK: store i32 %state.next, ptr %wp, align 4
; CHECK: store double %dc, ptr %dp, align 8
; CHECK: scalar.fission.consumer.ph:
; CHECK: scalar.fission.consumer.body:
; CHECK: %u0.consume = and i32 %r0.consume,
; CHECK: %u1.consume = xor i32 {{%[-a-zA-Z$._0-9]+}}, %r1.consume
; CHECK: %ud.consume = fadd double %rd.consume,
; CHECK: br i1 %fission.producer.continue, label %scalar.fission.chunk, label %producer.exit
; CHECK: ret void
define void @nc_bits_store(ptr %a, ptr %fp, ptr %out, ptr %indices,
                     ptr %dout, i64 %n, i64 %begin, double %start) !dbg !102 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  %span = mul i64 %n, 3
  %limit = sub i64 %begin, %span
  br label %loop, !dbg !103
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
  %dc = fneg double %dx, !dbg !103
  %wp = getelementptr i32, ptr %p, i64 1
  store i32 %state.next, ptr %wp, align 4
  store double %dc, ptr %dp, align 8
  %u0 = and i32 %r0, %c, !dbg !103
  %u1 = xor i32 %c, %r1, !dbg !103
  %ud = fadd double %rd, %dc, !dbg !103
  %next = sub i64 %iv, 3
  %done = icmp ugt i64 %next, %limit
  br i1 %done, label %loop, label %producer.exit, !dbg !103
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

; CHECK-LABEL: define void @nc_compact_bits_store(
; CHECK: alloca [9 x i32]
; CHECK: alloca [9 x double]
; CHECK: scalar.fission.chunk:
; CHECK-NOT: fission.chunk.remaining
; CHECK: fneg double %dx
; CHECK: store i32 %state.next, ptr %wp, align 4
; CHECK: store double %dc, ptr %dp, align 8
; CHECK: scalar.fission.consumer.ph:
; CHECK: scalar.fission.consumer.body:
; CHECK: %u0.consume = or i32 %r0.consume,
; CHECK: %u1.consume = xor i32 {{%[-a-zA-Z$._0-9]+}}, %r1.consume
; CHECK: %ud.consume = fadd double %rd.consume,
; CHECK: br i1 %fission.producer.continue, label %scalar.fission.chunk, label %producer.exit
; CHECK: ret void
define void @nc_compact_bits_store(ptr %a, ptr %fp, ptr %out, ptr %indices,
                     ptr %dout, i64 %n, i64 %begin, double %start) !dbg !104 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  %span = mul i64 %n, 3
  %limit = sub i64 %begin, %span
  br label %loop, !dbg !105
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
  %dc = fneg double %dx, !dbg !105
  %wp = getelementptr i32, ptr %p, i64 1
  store i32 %state.next, ptr %wp, align 4
  store double %dc, ptr %dp, align 8
  %u0 = or i32 %r0, %c, !dbg !105
  %u1 = xor i32 %c, %r1, !dbg !105
  %ud = fadd double %rd, %dc, !dbg !105
  br label %latch
latch:
  %u0.merge = phi i32 [%u0, %left], [%r0, %loop]
  %u1.merge = phi i32 [%r1, %loop], [%u1, %left]
  %ud.merge = phi double [%ud, %left], [%rd, %loop]
  %next = sub i64 %iv, 3
  %done = icmp sge i64 %limit, %next
  br i1 %done, label %producer.exit, label %loop, !dbg !105
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

; CHECK-LABEL: define void @nc_sub_store(
; CHECK: alloca [9 x i32]
; CHECK: alloca [9 x double]
; CHECK: scalar.fission.chunk:
; CHECK-NOT: fission.chunk.remaining
; CHECK: fneg double %dx
; CHECK: store i32 %state.next, ptr %wp, align 4
; CHECK: store double %dc, ptr %dp, align 8
; CHECK: scalar.fission.consumer.ph:
; CHECK: scalar.fission.consumer.body:
; CHECK: %u0.consume = sub i32 %r0.consume,
; CHECK: %u1.consume = add i32 {{%[-a-zA-Z$._0-9]+}}, %r1.consume
; CHECK: %ud.consume = fsub double %rd.consume,
; CHECK: br i1 %fission.producer.continue, label %scalar.fission.chunk, label %producer.exit
; CHECK: ret void
define void @nc_sub_store(ptr %a, ptr %fp, ptr %out, ptr %indices,
                     ptr %dout, i64 %n, i64 %begin, double %start) !dbg !106 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  %limit = sub i64 %begin, %n
  br label %loop, !dbg !107
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
  %dc = fneg double %dx, !dbg !107
  %wp = getelementptr i32, ptr %p, i64 1
  store i32 %state.next, ptr %wp, align 4
  store double %dc, ptr %dp, align 8
  %u0 = sub i32 %r0, %c, !dbg !107
  %u1 = add i32 %c, %r1, !dbg !107
  %ud = fsub double %rd, %dc, !dbg !107
  %next = sub i64 %iv, 1
  %done = icmp ne i64 %limit, %iv
  br i1 %done, label %loop, label %producer.exit, !dbg !107
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

; CHECK-LABEL: define void @nc_defined_store(
; CHECK: alloca [9 x i32]
; CHECK: alloca [9 x double]
; CHECK: scalar.fission.chunk:
; CHECK-NOT: fission.chunk.remaining
; CHECK: fneg double %dx
; CHECK: store i32 %state.next, ptr %wp, align 4
; CHECK: store double %dc, ptr %dp, align 8
; CHECK: scalar.fission.consumer.ph:
; CHECK: scalar.fission.consumer.body:
; CHECK: %u0.consume = mul nuw nsw i32 %r0.consume,
; CHECK: %u1.consume = mul nuw nsw i32 {{%[-a-zA-Z$._0-9]+}}, %r1.consume
; CHECK: %ud.consume = fadd double %rd.consume,
; CHECK: br i1 %fission.producer.continue, label %scalar.fission.chunk, label %producer.exit
; CHECK: ret void
define void @nc_defined_store(ptr %a, ptr %fp, ptr %out, ptr %indices,
                     ptr %dout, i64 %n, i64 %begin, double %start) !dbg !108 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  %limit = add i64 %n, 7
  br label %loop, !dbg !109
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
  %rawc = call i32 @scalar_helper(i32 %raw)
  %c = and i32 %rawc, 1
  %dc = fneg double %dx, !dbg !109
  %wp = getelementptr i32, ptr %p, i64 1
  store i32 %state.next, ptr %wp, align 4
  store double %dc, ptr %dp, align 8
  %u0 = mul nuw nsw i32 %r0, %c, !dbg !109
  %u1 = mul nuw nsw i32 %c, %r1, !dbg !109
  %ud = fadd double %rd, %dc, !dbg !109
  %next = add i64 %iv, 1
  %done = icmp eq i64 %next, %limit
  br i1 %done, label %producer.exit, label %loop, !dbg !109
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

; CHECK-LABEL: define void @nc_compact_mul_store(
; CHECK: alloca [9 x i32]
; CHECK: alloca [9 x double]
; CHECK: scalar.fission.chunk:
; CHECK-NOT: fission.chunk.remaining
; CHECK: fneg double %dx
; CHECK: store i32 %state.next, ptr %wp, align 4
; CHECK: store double %dc, ptr %dp, align 8
; CHECK: scalar.fission.consumer.ph:
; CHECK: scalar.fission.consumer.body:
; CHECK: %u0.consume = mul i32 %r0.consume,
; CHECK: %u1.consume = mul i32 {{%[-a-zA-Z$._0-9]+}}, %r1.consume
; CHECK: %ud.consume = fadd double %rd.consume,
; CHECK: br i1 %fission.producer.continue, label %scalar.fission.chunk, label %producer.exit
; CHECK: ret void
define void @nc_compact_mul_store(ptr %a, ptr %fp, ptr %out, ptr %indices,
                     ptr %dout, i64 %n, i64 %begin, double %start) !dbg !110 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  %span = mul i64 %n, 3
  %limit = sub i64 %begin, %span
  br label %loop, !dbg !111
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
  %dc = fneg double %dx, !dbg !111
  %wp = getelementptr i32, ptr %p, i64 1
  store i32 %state.next, ptr %wp, align 4
  store double %dc, ptr %dp, align 8
  %u0 = mul i32 %r0, %c, !dbg !111
  %u1 = mul i32 %c, %r1, !dbg !111
  %ud = fadd double %rd, %dc, !dbg !111
  br label %latch
latch:
  %u0.merge = phi i32 [%u0, %left], [%r0, %loop]
  %u1.merge = phi i32 [%r1, %loop], [%u1, %left]
  %ud.merge = phi double [%ud, %left], [%rd, %loop]
  %next = sub i64 %iv, 3
  %done = icmp sge i64 %limit, %next
  br i1 %done, label %producer.exit, label %loop, !dbg !111
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

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-affine-composition.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = !DISubroutineType(types: !5)
!5 = !{}
!100 = distinct !DISubprogram(name: "nc_mul_store", scope: !1, file: !1, line: 10, type: !4, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!101 = !DILocation(line: 12, column: 3, scope: !100)
!102 = distinct !DISubprogram(name: "nc_bits_store", scope: !1, file: !1, line: 30, type: !4, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!103 = !DILocation(line: 32, column: 3, scope: !102)
!104 = distinct !DISubprogram(name: "nc_compact_bits_store", scope: !1, file: !1, line: 50, type: !4, scopeLine: 50, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!105 = !DILocation(line: 52, column: 3, scope: !104)
!106 = distinct !DISubprogram(name: "nc_sub_store", scope: !1, file: !1, line: 70, type: !4, scopeLine: 70, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!107 = !DILocation(line: 72, column: 3, scope: !106)
!108 = distinct !DISubprogram(name: "nc_defined_store", scope: !1, file: !1, line: 90, type: !4, scopeLine: 90, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!109 = !DILocation(line: 92, column: 3, scope: !108)
!110 = distinct !DISubprogram(name: "nc_compact_mul_store", scope: !1, file: !1, line: 110, type: !4, scopeLine: 110, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!111 = !DILocation(line: 112, column: 3, scope: !110)
