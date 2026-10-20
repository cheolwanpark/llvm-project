; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -pass-remarks-output=%t.yaml -pass-remarks-filter=scalar-fission -S %s -o %t
; RUN: FileCheck %s < %t
; RUN: FileCheck %s --check-prefix=DEPTH < %t.yaml
;
; Depth is the longest genuine data chain in the final retained producer.

; Data computations have unit weight; wrappers have zero weight.
; CHECK-LABEL: define i32 @one_operation(
; CHECK-NOT: scalar.fission
; CHECK: ret i32

define i32 @one_operation(ptr %a, i64 %n, i32 %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s0 = phi i32 [%seed, %ph], [%u0, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %f = mul i32 %x, %x
  %u0 = add i32 %s0, %f
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r0 = phi i32 [%u0, %loop]
  br label %done
done:
  %answer = phi i32 [%seed, %entry], [%r0, %exit]
  ret i32 %answer
}

; DEPTH: Name: Rejected
; DEPTH-NEXT: Function: one_operation
; DEPTH: Reason: producer-too-shallow
; DEPTH: ProducerDepth: '1'

; Data computations have unit weight; wrappers have zero weight.
; CHECK-LABEL: define i32 @two_operations(
; CHECK-NOT: scalar.fission
; CHECK: ret i32

define i32 @two_operations(ptr %a, i64 %n, i32 %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s0 = phi i32 [%seed, %ph], [%u0, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %square = mul i32 %x, %x
  %f = add i32 %square, 7
  %u0 = add i32 %s0, %f
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r0 = phi i32 [%u0, %loop]
  br label %done
done:
  %answer = phi i32 [%seed, %entry], [%r0, %exit]
  ret i32 %answer
}

; DEPTH: Name: Rejected
; DEPTH-NEXT: Function: two_operations
; DEPTH: Reason: producer-too-shallow
; DEPTH: ProducerDepth: '2'

; Data computations have unit weight; wrappers have zero weight.
; CHECK-LABEL: define i32 @three_operations(
; CHECK: store i32 %f, ptr
; CHECK: loop.consume:
; CHECK: %f.scratch = load i32
; CHECK: ret i32

define i32 @three_operations(ptr %a, i64 %n, i32 %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s0 = phi i32 [%seed, %ph], [%u0, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %square = mul i32 %x, %x
  %bias = add i32 %square, 3
  %f = xor i32 %bias, 9
  %u0 = add i32 %s0, %f
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r0 = phi i32 [%u0, %loop]
  br label %done
done:
  %answer = phi i32 [%seed, %entry], [%r0, %exit]
  ret i32 %answer
}

; DEPTH: Name: Selected
; DEPTH-NEXT: Function: three_operations
; DEPTH: ProducerDepth: '3'

; Data computations have unit weight; wrappers have zero weight.
; CHECK-LABEL: define i32 @casts_and_addresses(
; CHECK-NOT: scalar.fission
; CHECK: ret i32

define i32 @casts_and_addresses(ptr %a, i64 %n, i32 %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s0 = phi i32 [%seed, %ph], [%u0, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %wide = zext i32 %x to i64
  %square = mul i64 %wide, %wide
  %narrow = trunc i64 %square to i32
  %wider = zext i32 %narrow to i64
  %sum = add i64 %wider, 7
  %f = trunc i64 %sum to i32
  %u0 = add i32 %s0, %f
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r0 = phi i32 [%u0, %loop]
  br label %done
done:
  %answer = phi i32 [%seed, %entry], [%r0, %exit]
  ret i32 %answer
}

; DEPTH: Name: Rejected
; DEPTH-NEXT: Function: casts_and_addresses
; DEPTH: Reason: producer-too-shallow
; DEPTH: ProducerDepth: '2'

; Three parallel multiplies have depth one.
; CHECK-LABEL: define i32 @parallel_work(
; CHECK-NOT: scalar.fission
; CHECK: ret i32

define i32 @parallel_work(ptr %a, i64 %n, i32 %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s0 = phi i32 [%seed, %ph], [%u0, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %a1 = mul i32 %x, 3
  %a2 = mul i32 %x, 7
  %a3 = mul i32 %x, 11
  %v1 = add i32 %s0, %a1
  %v2 = xor i32 %v1, %a2
  %u0 = add i32 %v2, %a3
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r0 = phi i32 [%u0, %loop]
  br label %done
done:
  %answer = phi i32 [%seed, %entry], [%r0, %exit]
  ret i32 %answer
}

; DEPTH: Name: Rejected
; DEPTH-NEXT: Function: parallel_work
; DEPTH: Reason: producer-too-shallow
; DEPTH: ProducerDepth: '1'

; A retained control chain cannot increase data depth.
; CHECK-LABEL: define i32 @control_does_not_count(
; CHECK-NOT: scalar.fission
; CHECK: ret i32

define i32 @control_does_not_count(ptr %a, i64 %n, i32 %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s0 = phi i32 [%seed, %ph], [%u0, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %f = mul i32 %x, %x
  %control1 = mul i64 %i, 13
  %control2 = xor i64 %control1, 7
  %control3 = add i64 %control2, 19
  %u0 = add i32 %s0, %f
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %control3, %n
  br i1 %more, label %loop, label %exit
exit:
  %r0 = phi i32 [%u0, %loop]
  br label %done
done:
  %answer = phi i32 [%seed, %entry], [%r0, %exit]
  ret i32 %answer
}

; DEPTH: Name: Rejected
; DEPTH-NEXT: Function: control_does_not_count
; DEPTH: Reason: producer-too-shallow
; DEPTH: ProducerDepth: '1'

; A depth-three initial frontier can shrink below the gate after valid FMul
; cleanup. Removed private work must not count toward final producer depth.
; CHECK-LABEL: define double @cleanup_becomes_shallow(
; CHECK-NOT: scalar.fission
; CHECK: ret double
; DEPTH: Name: Rejected
; DEPTH-NEXT: Function: cleanup_becomes_shallow
; DEPTH: Reason: producer-too-shallow
; DEPTH: ProducerDepth: '2'
define double @cleanup_becomes_shallow(ptr %a, i64 %n, double %scale) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %s = phi double [0.0, %entry], [%u, %loop]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p
  %square = fmul double %x, %x
  %f = fadd double %square, 3.0
  %g = fmul double %f, %scale
  %h = fmul double %g, %f
  %v = fadd double %s, %h
  %w = fadd double %v, %g
  %u = fadd double %w, %f
  %next = add i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %result = phi double [%u, %loop]
  ret double %result
}

; Raw loads and invariant/address-only inputs retain their separate legality
; rejection. They cannot manufacture a depth-zero computed producer.
; CHECK-LABEL: define i32 @raw_load(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
; DEPTH: Name: Rejected
; DEPTH-NEXT: Function: raw_load
; DEPTH: Reason: no-computed-boundary
; DEPTH: ProducerDepth: '0'
define i32 @raw_load(ptr %a, i64 %n, i32 %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s0 = phi i32 [%seed, %ph], [%u0, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %u0 = add i32 %s0, %x
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r0 = phi i32 [%u0, %loop]
  br label %done
done:
  %answer = phi i32 [%seed, %entry], [%r0, %exit]
  ret i32 %answer
}


define i32 @very_expensive_named_call(i32 %x) nounwind willreturn memory(none) {
  %product = mul i32 %x, 13
  %f = add i32 %product, 5
  ret i32 %f
}

; Call names imply no internal depth; invariant trees do not form a cut.
; CHECK-LABEL: define i32 @opaque_call_is_one(
; CHECK-NOT: scalar.fission
; CHECK: ret i32

define i32 @opaque_call_is_one(ptr %a, i64 %n, i32 %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s0 = phi i32 [%seed, %ph], [%u0, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %f = call i32 @very_expensive_named_call(i32 %x)
  %u0 = add i32 %s0, %f
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r0 = phi i32 [%u0, %loop]
  br label %done
done:
  %answer = phi i32 [%seed, %entry], [%r0, %exit]
  ret i32 %answer
}

; DEPTH: Name: Rejected
; DEPTH-NEXT: Function: opaque_call_is_one
; DEPTH: Reason: producer-too-shallow
; DEPTH: ProducerDepth: '1'

; Call names imply no internal depth; invariant trees do not form a cut.
; CHECK-LABEL: define i32 @opaque_call_chain(
; CHECK: store i32 %f, ptr
; CHECK: loop.consume:
; CHECK: %f.scratch = load i32
; CHECK: ret i32

define i32 @opaque_call_chain(ptr %a, i64 %n, i32 %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s0 = phi i32 [%seed, %ph], [%u0, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %first = call i32 @very_expensive_named_call(i32 %x)
  %second = call i32 @very_expensive_named_call(i32 %first)
  %f = call i32 @very_expensive_named_call(i32 %second)
  %u0 = add i32 %s0, %f
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r0 = phi i32 [%u0, %loop]
  br label %done
done:
  %answer = phi i32 [%seed, %entry], [%r0, %exit]
  ret i32 %answer
}

; DEPTH: Name: Selected
; DEPTH-NEXT: Function: opaque_call_chain
; DEPTH: ProducerDepth: '3'

; Call names imply no internal depth; invariant trees do not form a cut.
; CHECK-LABEL: define i32 @invariant_arithmetic(
; CHECK-NOT: scalar.fission
; CHECK: ret i32

define i32 @invariant_arithmetic(ptr %a, i64 %n, i32 %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s0 = phi i32 [%seed, %ph], [%u0, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %product = mul i32 %seed, 13
  %bias = add i32 %product, 7
  %f = xor i32 %bias, 9
  %u0 = add i32 %s0, %f
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r0 = phi i32 [%u0, %loop]
  br label %done
done:
  %answer = phi i32 [%seed, %entry], [%r0, %exit]
  ret i32 %answer
}

; DEPTH: Name: Rejected
; DEPTH-NEXT: Function: invariant_arithmetic
; DEPTH: Reason: no-computed-boundary
; DEPTH: ProducerDepth: '0'

; A shared, load-dependent address is not reconstructible from an IV alone.
; Its transfer remains computed, but none of its arithmetic can satisfy the
; producer data-depth gate. The two data computations would live in the consumer.
; CHECK-LABEL: define double @address_stream_is_zero(
; CHECK-NOT: scalar.fission
; CHECK: ret double
; DEPTH: Name: Rejected
; DEPTH-NEXT: Function: address_stream_is_zero
; DEPTH: Reason: producer-too-shallow
; DEPTH: ProducerDepth: '0'
define double @address_stream_is_zero(ptr %a, ptr %b, ptr %offsets, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %s = phi double [0.0, %entry], [%u, %loop]
  %t = phi double [1.0, %entry], [%v, %loop]
  %op = getelementptr i64, ptr %offsets, i64 %i
  %offset = load i64, ptr %op
  %product = mul i64 %offset, 13
  %bias = add i64 %product, 7
  %index = xor i64 %bias, 9
  %pa = getelementptr double, ptr %a, i64 %index
  %pb = getelementptr double, ptr %b, i64 %index
  %x = load double, ptr %pa
  %y = load double, ptr %pb
  %f = fmul double %x, %x
  %g = fmul double %y, %y
  %u = fadd double %s, %f
  %v = fadd double %t, %g
  %next = add i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi double [%u, %loop]
  %q = phi double [%v, %loop]
  %result = fadd double %r, %q
  ret double %result
}

; A cast of the original IV is reconstructed. Its recurrence arithmetic must
; not create a computed scratch boundary, as in the OpenLB preparation helper.
; CHECK-LABEL: define i32 @iv_only(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
; DEPTH: Name: Rejected
; DEPTH-NEXT: Function: iv_only
; DEPTH: Reason: no-computed-boundary
; DEPTH: ProducerDepth: '0'
define i32 @iv_only(ptr %a, i64 %n, i32 %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s = phi i32 [%seed, %ph], [%u, %loop]
  %f = trunc i64 %i to i32
  %u = add i32 %s, %f
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi i32 [%u, %loop]
  br label %done
done:
  %answer = phi i32 [%seed, %entry], [%r, %exit]
  ret i32 %answer
}

; Predicates entering the state-dependent graph participate in slice membership,
; but a control-only contribution must not become a depth-three data producer.
; CHECK-LABEL: define i32 @internal_control(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
; DEPTH: Name: Rejected
; DEPTH-NEXT: Function: internal_control
; DEPTH: Reason: producer-too-shallow
; DEPTH: ProducerDepth: '0'
define i32 @internal_control(ptr %a, i64 %n, i32 %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s = phi i32 [%seed, %ph], [%u, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %control1 = mul i32 %x, 13
  %control2 = add i32 %control1, 7
  %predicate = icmp ugt i32 %control2, 19
  %sum = add i32 %s, 1
  %u = select i1 %predicate, i32 %sum, i32 %s
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi i32 [%u, %loop]
  br label %done
done:
  %answer = phi i32 [%seed, %entry], [%r, %exit]
  ret i32 %answer
}
