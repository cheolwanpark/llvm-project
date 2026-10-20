; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s
; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-allow-fp-reordering -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s
; RUN: opt -passes='function(scalar-fission),default<O3>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=FINAL
;
; Shared indices are rebuilt from the actual wrapping, nonzero-start IV, with
; its original casts and offsets. They are not ordinal indices or snapshots.
; CHECK-LABEL: define double @indices(
; CHECK: alloca [3 x double]
; CHECK-NOT: alloca
; CHECK: call void @llvm.lifetime.start
; CHECK: %i.chunk = phi i8 [ -3,
; CHECK: loop.consume:
; CHECK: %i.consume = phi i8 [ %i.chunk,
; CHECK: %wide.consume = zext i8 %i.consume to i64
; CHECK: %index.consume = add nuw i64 %wide.consume, %offset
; CHECK: %pa.consume = getelementptr inbounds double, ptr %a, i64 %index.consume
; CHECK: %pb.consume = getelementptr inbounds double, ptr %b, i64 %index.consume
; CHECK: %next.consume = add i8 %i.consume, 1
; CHECK: call void @llvm.lifetime.end
; FINAL-LABEL: define double @indices(
; FINAL: alloca [3 x double]
; FINAL-NOT: alloca
; FINAL: ret double

define double @indices(ptr %a, ptr %b, ptr %x, i64 %offset, i8 %end, double %seed) {
entry:
  br label %loop
loop:
  %i = phi i8 [-3, %entry], [%next, %loop]
  %s = phi double [%seed, %entry], [%u, %loop]
  %t = phi double [1.0, %entry], [%v, %loop]
  %wide = zext i8 %i to i64
  %index = add nuw i64 %wide, %offset
  %pa = getelementptr inbounds double, ptr %a, i64 %index
  %pb = getelementptr inbounds double, ptr %b, i64 %index
  %px = getelementptr double, ptr %x, i64 %wide
  %z = load double, ptr %px
  %f = fmul double %z, %z
  %av = load double, ptr %pa
  %bv = load double, ptr %pb
  %af = fmul double %f, %av
  %bf = fmul double %f, %bv
  %u = fadd double %s, %af
  %v = fadd double %t, %bf
  %next = add i8 %i, 1
  %more = icmp ne i8 %next, %end
  br i1 %more, label %loop, label %exit
exit:
  %r = phi double [%u, %loop]
  %q = phi double [%v, %loop]
  %total = fadd double %r, %q
  ret double %total
}

; Prune from the leaves: g is retained by h's store until h moves. f is a
; genuine computed boundary, and its load is not made available by pruning.
; CHECK-LABEL: define double @suffix(
; CHECK: alloca [3 x double]
; CHECK-NOT: alloca
; CHECK: %f = fmul double %x, %x
; CHECK-NOT: %g =
; CHECK-NOT: %h =
; CHECK-NOT: %dead =
; CHECK: loop.consume:
; CHECK: %g.consume = fmul nnan nsz double %f.scratch, %scale
; CHECK: %h.consume = fmul contract double %g.consume, %f.scratch
; CHECK: %u.consume = fadd {{(reassoc )?}}double %s.consume, %h.consume
; CHECK: %v.consume = fsub double %t.consume, %g.consume
; CHECK: %w.consume = fadd {{(reassoc )?}}double %t.consume, %h.consume

define double @suffix(ptr %a, i64 %n, double %scale, double %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s = phi double [%seed, %ph], [%u, %loop]
  %t = phi double [1.0, %ph], [%z, %loop]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p
  %f = fmul double %x, %x
  %g = fmul nnan nsz double %f, %scale
  %h = fmul contract double %g, %f
  %dead = fmul double %h, 5.0
  %u = fadd double %s, %h
  %v = fsub double %t, %g
  %w = fadd double %t, %h
  %wf = fadd double %w, %f
  %z = fadd double %v, %wf
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi double [%u, %loop]
  %q = phi double [%z, %loop]
  %total = fadd double %r, %q
  br label %done
done:
  %result = phi double [%seed, %entry], [%total, %exit]
  ret double %result
}

; A consumer-only value can have original multi-use, but a producer effect
; really retains its source. This also checks an unavailable operand: %x has
; no consumer definition and pruning must not introduce a read of it.
; CHECK-LABEL: define double @retained(
; CHECK-COUNT-2: alloca [3 x double]
; CHECK-NOT: alloca
; CHECK: %g = fmul double %f, %x
; CHECK: store double %g, ptr %out
; CHECK: loop.consume:
; CHECK-NOT: %g.consume =
; CHECK: %g.scratch = load double
; CHECK: %h.consume = fmul double %g.scratch, %f.scratch
; CHECK: ret double

define double @retained(ptr noalias %a, ptr noalias %out, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %s = phi double [0.0, %entry], [%u, %loop]
  %t = phi double [1.0, %entry], [%v, %loop]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p
  %f = fmul double %x, %x
  %g = fmul double %f, %x
  store double %g, ptr %out
  %h = fmul double %g, %f
  %u = fadd double %s, %h
  %v = fsub double %t, %g
  %next = add nuw i64 %i, 1
  %more = icmp ult i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi double [%u, %loop]
  %q = phi double [%v, %loop]
  %total = fadd double %r, %q
  ret double %total
}

; A loop load is not an invariant offset, even though the base pointer is.
; CHECK-LABEL: define double @loaded_index(
; CHECK: alloca [3 x double]
; CHECK: alloca [3 x i64]
; CHECK-NOT: alloca
; CHECK: %index = add i64 %offset, %i
; CHECK: store i64 %index,
; CHECK: loop.consume:
; CHECK-NOT: %index.consume =
; CHECK: %index.scratch = load i64
; CHECK: getelementptr double, ptr %b, i64 %index.scratch
; CHECK: ret double

define double @loaded_index(ptr %a, ptr %b, ptr %offsets, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %s = phi double [0.0, %entry], [%u, %loop]
  %t = phi double [1.0, %entry], [%v, %loop]
  %op = getelementptr i64, ptr %offsets, i64 %i
  %offset = load i64, ptr %op
  %index = add i64 %offset, %i
  %pa = getelementptr double, ptr %a, i64 %index
  %pb = getelementptr double, ptr %b, i64 %index
  %x = load double, ptr %pa
  %y = load double, ptr %pb
  %f = fmul double %x, %x
  %g = fmul double %f, %y
  %u = fadd double %s, %f
  %v = fsub double %t, %g
  %next = add nuw i64 %i, 1
  %more = icmp ult i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi double [%u, %loop]
  %q = phi double [%v, %loop]
  %total = fadd double %r, %q
  ret double %total
}

; Conditional definitions stay in their corresponding block. An existing
; result buffer remains producer-owned and supplies a dominating transfer.
; CHECK-LABEL: define double @conditional_buffer(
; CHECK-NOT: alloca
; CHECK: %f = fmul double %x, %x
; CHECK: store double %f, ptr %op
; CHECK-NOT: %g =
; CHECK: loop.consume:
; CHECK: %op.consume = getelementptr inbounds double, ptr %out, i64 %i.consume
; CHECK: %f.scratch = load double, ptr %op.consume
; CHECK: br i1 %take, label %then.consume, label %latch.consume
; CHECK: then.consume:
; CHECK: %g.consume = fmul nsz double %f.scratch, %scale
; CHECK: %u.consume = fadd {{(reassoc )?}}double %s.consume, %g.consume
; CHECK: %v.consume = fsub double %t.consume, %g.consume
; CHECK: ret double

define double @conditional_buffer(ptr noalias %a, ptr noalias %out, i64 %n, double %scale, i1 %take) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %latch]
  %s = phi double [0.0, %entry], [%sn, %latch]
  %t = phi double [1.0, %entry], [%tn, %latch]
  %p = getelementptr double, ptr %a, i64 %i
  %op = getelementptr inbounds double, ptr %out, i64 %i
  %x = load double, ptr %p
  %f = fmul double %x, %x
  store double %f, ptr %op
  br i1 %take, label %then, label %latch
then:
  %g = fmul nsz double %f, %scale
  %u = fadd double %s, %g
  %v = fsub double %t, %g
  br label %latch
latch:
  %sn = phi double [%s, %loop], [%u, %then]
  %tn = phi double [%t, %loop], [%v, %then]
  %next = add nuw i64 %i, 1
  %more = icmp ult i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi double [%sn, %latch]
  %q = phi double [%tn, %latch]
  %total = fadd double %r, %q
  ret double %total
}

; No effect retains %g here, but %x is unavailable in the consumer. Do not
; create a new input read just to prune this stream.
; CHECK-LABEL: define double @unavailable(
; CHECK-COUNT-2: alloca [3 x double]
; CHECK-NOT: alloca
; CHECK: %g = fmul double %f, %x
; CHECK: loop.consume:
; CHECK-NOT: %x.consume =
; CHECK-NOT: %g.consume =
; CHECK: %g.scratch = load double
; CHECK: ret double
define double @unavailable(ptr noalias %a, ptr noalias %out, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %s = phi double [0.0, %entry], [%u, %loop]
  %t = phi double [1.0, %entry], [%v, %loop]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p
  %f = fmul double %x, %x
  %g = fmul double %f, %x
  %h = fmul double %g, %f
  %u = fadd double %s, %h
  %v = fsub double %t, %g
  %next = add nuw i64 %i, 1
  %more = icmp ult i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi double [%u, %loop]
  %q = phi double [%v, %loop]
  %total = fadd double %r, %q
  ret double %total
}

; A shared add needed only on the taken path stays on that path. The byte IV
; crosses zero by wrapping; reconstruction keeps its cast, start and step.
; CHECK-LABEL: define double @conditional_indices(
; CHECK: alloca [3 x double]
; CHECK-NOT: alloca
; CHECK: loop.consume:
; CHECK-NOT: %index.consume =
; CHECK: br i1 %take.consume, label %then.consume, label %latch.consume
; CHECK: then.consume:
; CHECK: %index.consume = add nuw i64 %wide.consume, %offset
; CHECK: getelementptr inbounds double, ptr %a, i64 %index.consume
; CHECK: getelementptr inbounds double, ptr %b, i64 %index.consume
; CHECK: latch.consume:
; CHECK: %next.consume = add i8 %i.consume, 1
; CHECK: ret double

define double @conditional_indices(ptr %a, ptr %b, ptr %x, i64 %offset, i8 %end, double %seed) {
entry:
  br label %loop
loop:
  %i = phi i8 [-3, %entry], [%next, %latch]
  %s = phi double [%seed, %entry], [%sn, %latch]
  %t = phi double [1.0, %entry], [%tn, %latch]
  %wide = zext i8 %i to i64
  %px = getelementptr double, ptr %x, i64 %wide
  %z = load double, ptr %px
  %f = fmul double %z, %z
  %odd = and i8 %i, 1
  %take = icmp eq i8 %odd, 0
  br i1 %take, label %then, label %latch
then:
  %index = add nuw i64 %wide, %offset
  %pa = getelementptr inbounds double, ptr %a, i64 %index
  %pb = getelementptr inbounds double, ptr %b, i64 %index
  %av = load double, ptr %pa
  %bv = load double, ptr %pb
  %af = fmul double %f, %av
  %bf = fmul double %f, %bv
  %u = fadd double %s, %af
  %v = fadd double %t, %bf
  br label %latch
latch:
  %sn = phi double [%s, %loop], [%u, %then]
  %tn = phi double [%t, %loop], [%v, %then]
  %next = add i8 %i, 1
  %more = icmp ne i8 %next, %end
  br i1 %more, label %loop, label %exit
exit:
  %r = phi double [%sn, %latch]
  %q = phi double [%tn, %latch]
  %total = fadd double %r, %q
  ret double %total
}
