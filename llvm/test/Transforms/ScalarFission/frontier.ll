; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s -o %t
; RUN: FileCheck %s < %t
; RUN: opt -passes=scalar-fission -scalar-fission-chunk-capacity=3 -S %s -o %t.again
; RUN: diff %t %t.again
; RUN: opt -passes=scalar-fission -pass-remarks-output=%t.yaml -pass-remarks-filter=scalar-fission -disable-output %s
; RUN: FileCheck %s --check-prefix=GRAPH < %t.yaml
;
; Contribution identity is (closed state group, input value). These graphs
; distinguish graph membership from local use counts and early common cuts.

declare i32 @pure(i32) nounwind willreturn memory(none)
define { i32, i32 } @pair(i32 %x) nounwind willreturn memory(none) {
  %first = add i32 %x, 5
  %second = xor i32 %x, 13
  %a = insertvalue { i32, i32 } poison, i32 %first, 0
  %b = insertvalue { i32, i32 } %a, i32 %second, 1
  ret { i32, i32 } %b
}

; Two uses inside one slice count once; transfer the computed root.
; CHECK-LABEL: define i32 @reconvergent(
; CHECK-COUNT-1: alloca [3 x i32]
; CHECK-NOT: alloca
; CHECK: store i32 %root, ptr
; CHECK: loop.consume:
; CHECK: %root.scratch = load i32
; CHECK: ret i32
; GRAPH: Function: reconvergent
; GRAPH: Root: root
; GRAPH: Value: f
; GRAPH-NEXT: {{.*}}String: ', membership '
; GRAPH-NEXT: {{.*}}Membership: '1'
; GRAPH: Value: root
; GRAPH: Boundary: uncovered-root

define i32 @reconvergent(ptr %a, i64 %n, i32 %seed) {
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
  %left = add i32 %f, 7
  %right = xor i32 %f, 11
  %root = mul i32 %left, %right
  %u0 = add i32 %s0, %root
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

; Two contributions share f; both private suffixes stay in the consumer.
; CHECK-LABEL: define i32 @private_suffixes(
; CHECK-COUNT-1: alloca [3 x i32]
; CHECK-NOT: alloca
; CHECK: store i32 %f, ptr
; CHECK-NOT: %left =
; CHECK-NOT: %right =
; CHECK: loop.consume:
; CHECK: %f.scratch = load i32
; CHECK: ret i32
; GRAPH: Function: private_suffixes
; GRAPH: Value: f
; GRAPH-NEXT: {{.*}}String: ', membership '
; GRAPH-NEXT: {{.*}}Membership: '2'
; GRAPH: Boundary: last-shared

define i32 @private_suffixes(ptr %a, i64 %n, i32 %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s0 = phi i32 [%seed, %ph], [%u0, %loop]
  %s1 = phi i32 [%seed, %ph], [%u1, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %square = mul i32 %x, %x
  %bias = add i32 %square, 3
  %f = xor i32 %bias, 9
  %left = add i32 %f, 7
  %right = xor i32 %f, 11
  %u0 = add i32 %s0, %left
  %u1 = xor i32 %s1, %right
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r0 = phi i32 [%u0, %loop]
  %r1 = phi i32 [%u1, %loop]
  %result = xor i32 %r0, %r1
  br label %done
done:
  %answer = phi i32 [%seed, %entry], [%result, %exit]
  ret i32 %answer
}

; Repeated input within one group has one slice.
; CHECK-LABEL: define i32 @repeated_group_input(
; CHECK-COUNT-1: alloca [3 x i32]
; CHECK-NOT: alloca
; CHECK: store i32 %f, ptr
; CHECK: loop.consume:
; CHECK: %f.scratch = load i32
; CHECK: ret i32
; GRAPH: Function: repeated_group_input
; GRAPH: Root: f
; GRAPH: Value: f
; GRAPH-NEXT: {{.*}}String: ', membership '
; GRAPH-NEXT: {{.*}}Membership: '1'

define i32 @repeated_group_input(ptr %a, i64 %n, i32 %seed) {
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
  %update = add i32 %s0, %f
  %u0 = xor i32 %update, %f
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

; Same input across independent groups counts twice; direct roots use fallback.
; CHECK-LABEL: define i32 @direct_shared_root(
; CHECK-COUNT-1: alloca [3 x i32]
; CHECK-NOT: alloca
; CHECK: store i32 %f, ptr
; CHECK: loop.consume:
; CHECK: %f.scratch = load i32
; CHECK: ret i32
; GRAPH: Function: direct_shared_root
; GRAPH: StateGroup: '0'
; GRAPH: Root: f
; GRAPH: StateGroup: '1'
; GRAPH: Root: f
; GRAPH: Value: f
; GRAPH-NEXT: {{.*}}String: ', membership '
; GRAPH-NEXT: {{.*}}Membership: '2'
; GRAPH: Boundary: uncovered-root

define i32 @direct_shared_root(ptr %a, i64 %n, i32 %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s0 = phi i32 [%seed, %ph], [%u0, %loop]
  %s1 = phi i32 [%seed, %ph], [%u1, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %square = mul i32 %x, %x
  %bias = add i32 %square, 3
  %f = xor i32 %bias, 9
  %u0 = add i32 %s0, %f
  %u1 = xor i32 %s1, %f
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r0 = phi i32 [%u0, %loop]
  %r1 = phi i32 [%u1, %loop]
  %result = xor i32 %r0, %r1
  br label %done
done:
  %answer = phi i32 [%seed, %entry], [%result, %exit]
  ret i32 %answer
}

; Distinct inputs of one compound state have separate slices.
; CHECK-LABEL: define i32 @compound_group(
; CHECK-COUNT-1: alloca [3 x i32]
; CHECK-NOT: alloca
; CHECK: store i32 %f, ptr
; CHECK-NOT: %left =
; CHECK-NOT: %right =
; CHECK: loop.consume:
; CHECK: %f.scratch = load i32
; CHECK: ret i32
; GRAPH: Function: compound_group
; GRAPH: StateGroup: '0'
; GRAPH: Root: left
; GRAPH: StateGroup: '0'
; GRAPH: Root: right
; GRAPH: Value: f
; GRAPH-NEXT: {{.*}}String: ', membership '
; GRAPH-NEXT: {{.*}}Membership: '2'

define i32 @compound_group(ptr %a, i64 %n, i32 %seed) {
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
  %left = add i32 %f, 7
  %right = xor i32 %f, 11
  %update = add i32 %s0, %left
  %u0 = xor i32 %update, %right
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

; Overlapping coupled PHI closures merge; three inputs count three times.
; CHECK-LABEL: define i32 @coupled_group(
; CHECK-COUNT-1: alloca [3 x i32]
; CHECK-NOT: alloca
; CHECK: store i32 %f, ptr
; CHECK-NOT: %left =
; CHECK-NOT: %right =
; CHECK: loop.consume:
; CHECK: %f.scratch = load i32
; CHECK: ret i32
; GRAPH: Function: coupled_group
; GRAPH: Root: left
; GRAPH: StateGroup: '0'
; GRAPH: Root: right
; GRAPH: StateGroup: '0'
; GRAPH: Root: third
; GRAPH: Value: f
; GRAPH-NEXT: {{.*}}String: ', membership '
; GRAPH-NEXT: {{.*}}Membership: '3'

define i32 @coupled_group(ptr %a, i64 %n, i32 %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s0 = phi i32 [%seed, %ph], [%u0, %loop]
  %s1 = phi i32 [%seed, %ph], [%u1, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %square = mul i32 %x, %x
  %bias = add i32 %square, 3
  %f = xor i32 %bias, 9
  %left = add i32 %f, 7
  %right = xor i32 %f, 11
  %third = mul i32 %f, 5
  %mix = add i32 %s0, %s1
  %with.left = add i32 %mix, %left
  %u0 = xor i32 %with.left, %right
  %other = add i32 %s1, %s0
  %u1 = add i32 %other, %third
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r0 = phi i32 [%u0, %loop]
  %r1 = phi i32 [%u1, %loop]
  %result = xor i32 %r0, %r1
  br label %done
done:
  %answer = phi i32 [%seed, %entry], [%result, %exit]
  ret i32 %answer
}

; SHTools-shaped 4 -> 2 -> 1 frontier; never cut at mul87.
; CHECK-LABEL: define i32 @sharing_levels(
; CHECK-COUNT-2: alloca [3 x i32]
; CHECK-NOT: alloca
; CHECK: store i32 %mul89, ptr
; CHECK: store i32 %mul136, ptr
; CHECK: loop.consume:
; CHECK: %mul89.scratch = load i32
; CHECK: %mul136.scratch = load i32
; CHECK: ret i32
; GRAPH: Function: sharing_levels
; GRAPH: Value: mul87
; GRAPH-NEXT: {{.*}}String: ', membership '
; GRAPH-NEXT: {{.*}}Membership: '4'
; GRAPH-NEXT: {{.*}}String: ', boundary '
; GRAPH-NEXT: {{.*}}Boundary: ''
; GRAPH: Value: mul89
; GRAPH-NEXT: {{.*}}String: ', membership '
; GRAPH-NEXT: {{.*}}Membership: '2'
; GRAPH-NEXT: {{.*}}String: ', boundary '
; GRAPH-NEXT: {{.*}}Boundary: last-shared
; GRAPH: Value: mul136
; GRAPH-NEXT: {{.*}}String: ', membership '
; GRAPH-NEXT: {{.*}}Membership: '2'
; GRAPH-NEXT: {{.*}}String: ', boundary '
; GRAPH-NEXT: {{.*}}Boundary: last-shared

define i32 @sharing_levels(ptr %a, i64 %n, i32 %seed) {
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
  %mul87 = mul i32 %f, 13
  %mul89 = mul i32 %mul87, 7
  %mul136 = add i32 %mul87, 11
  %mul105 = add i32 %mul89, 3
  %other105 = xor i32 %mul89, 9
  %mul149 = add i32 %mul136, 5
  %other149 = xor i32 %mul136, 17
  %a0 = add i32 %s0, %mul105
  %a1 = xor i32 %a0, %other105
  %a2 = add i32 %a1, %mul149
  %u0 = xor i32 %a2, %other149
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

; Uncovered independent computed contribution retains its own result crossing.
; CHECK-LABEL: define i32 @independent_root(
; CHECK-COUNT-2: alloca [3 x i32]
; CHECK-NOT: alloca
; CHECK: store i32 %f, ptr
; CHECK: store i32 %separate, ptr
; CHECK: loop.consume:
; CHECK: %f.scratch = load i32
; CHECK: %separate.scratch = load i32
; CHECK: ret i32

define i32 @independent_root(ptr %a, i64 %n, i32 %seed) {
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
  %left = add i32 %f, 7
  %right = xor i32 %f, 11
  %separate1 = mul i32 %x, 13
  %separate2 = add i32 %separate1, 17
  %separate = xor i32 %separate2, 21
  %a0 = add i32 %s0, %left
  %a1 = xor i32 %a0, %right
  %u0 = add i32 %a1, %separate
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

; One covered branch does not cover the other operand; unsafe reread uses fallback.
; CHECK-LABEL: define i32 @partial_coverage(
; CHECK-COUNT-2: alloca [3 x i32]
; CHECK-NOT: alloca
; CHECK: store i32 %f, ptr
; CHECK: store i32 %right, ptr
; CHECK: loop.consume:
; CHECK: %f.scratch = load i32
; CHECK: %right.scratch = load i32
; CHECK: ret i32

define i32 @partial_coverage(ptr %a, i64 %n, i32 %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s0 = phi i32 [%seed, %ph], [%u0, %loop]
  %s1 = phi i32 [%seed, %ph], [%u1, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %square = mul i32 %x, %x
  %bias = add i32 %square, 3
  %f = xor i32 %bias, 9
  %left = add i32 %f, 7
  %unsafe = load i32, ptr %a
  %right = xor i32 %f, %unsafe
  store i32 %x, ptr %a
  %u0 = add i32 %s0, %left
  %u1 = xor i32 %s1, %right
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r0 = phi i32 [%u0, %loop]
  %r1 = phi i32 [%u1, %loop]
  %result = xor i32 %r0, %r1
  br label %done
done:
  %answer = phi i32 [%seed, %entry], [%result, %exit]
  ret i32 %answer
}

; Minimum depth applies to the whole producer, including a short contribution.
; CHECK-LABEL: define i32 @short_alongside_deep(
; CHECK-COUNT-2: alloca [3 x i32]
; CHECK-NOT: alloca
; CHECK: store i32 %f, ptr
; CHECK: store i32 %short, ptr
; CHECK-NOT: %left =
; CHECK-NOT: %right =
; CHECK: loop.consume:
; CHECK: %f.scratch = load i32
; CHECK: %short.scratch = load i32
; CHECK: ret i32

define i32 @short_alongside_deep(ptr %a, i64 %n, i32 %seed) {
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
  %left = add i32 %f, 7
  %right = xor i32 %f, 11
  %short = add i32 %x, 17
  %a0 = add i32 %s0, %left
  %a1 = xor i32 %a0, %right
  %u0 = add i32 %a1, %short
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

; Freeze executes once in the producer at its original point.
; CHECK-LABEL: define i32 @freeze_boundary(
; CHECK-COUNT-1: alloca [3 x i32]
; CHECK-NOT: alloca
; CHECK: store i32 %frozen, ptr
; CHECK-NOT: %left =
; CHECK-NOT: %right =
; CHECK: loop.consume:
; CHECK: %frozen.scratch = load i32
; CHECK: ret i32

define i32 @freeze_boundary(ptr %a, i64 %n, i32 %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s0 = phi i32 [%seed, %ph], [%u0, %loop]
  %s1 = phi i32 [%seed, %ph], [%u1, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %square = mul i32 %x, %x
  %bias = add i32 %square, 3
  %f = xor i32 %bias, 9
  %frozen = freeze i32 %f
  %left = add i32 %frozen, 7
  %right = xor i32 %frozen, 11
  %u0 = add i32 %s0, %left
  %u1 = xor i32 %s1, %right
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r0 = phi i32 [%u0, %loop]
  %r1 = phi i32 [%u1, %loop]
  %result = xor i32 %r0, %r1
  br label %done
done:
  %answer = phi i32 [%seed, %entry], [%result, %exit]
  ret i32 %answer
}

; Each scalar result needs its own transfer; sibling membership is not coverage.
; CHECK-LABEL: define i32 @aggregate_results(
; CHECK-COUNT-2: alloca [3 x i32]
; CHECK-NOT: alloca
; CHECK: store i32 %first, ptr
; CHECK: store i32 %second, ptr
; CHECK: loop.consume:
; CHECK: %first.scratch = load i32
; CHECK: %second.scratch = load i32
; CHECK: ret i32

define i32 @aggregate_results(ptr %a, i64 %n, i32 %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s0 = phi i32 [%seed, %ph], [%u0, %loop]
  %s1 = phi i32 [%seed, %ph], [%u1, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %square = mul i32 %x, %x
  %bias = add i32 %square, 3
  %f = xor i32 %bias, 9
  %aggregate = call { i32, i32 } @pair(i32 %f)
  %first = extractvalue { i32, i32 } %aggregate, 0
  %second = extractvalue { i32, i32 } %aggregate, 1
  %u0 = add i32 %s0, %first
  %u1 = xor i32 %s1, %second
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r0 = phi i32 [%u0, %loop]
  %r1 = phi i32 [%u1, %loop]
  %result = xor i32 %r0, %r1
  br label %done
done:
  %answer = phi i32 [%seed, %entry], [%result, %exit]
  ret i32 %answer
}

; A computed PHI root has no private recipe after the merge. Transfer its
; result after all producer PHIs, retaining lazy execution of both arms.
; CHECK-LABEL: define i32 @computed_phi(
; CHECK-COUNT-1: alloca [3 x i32]
; CHECK-NOT: alloca
; CHECK: %root = phi i32
; CHECK: store i32 %root, ptr
; CHECK: loop.consume:
; CHECK: merge.consume:
; CHECK: %root.scratch = load i32
; CHECK: %u.consume = add i32 %s.consume, %root.scratch
; CHECK: ret i32
; GRAPH: Function: computed_phi
; GRAPH: Root: root
; GRAPH: Value: root
; GRAPH: Boundary: uncovered-root
; GRAPH: Transfer: scratch

define i32 @computed_phi(ptr %a, i64 %n, i32 %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %merge]
  %s = phi i32 [%seed, %ph], [%u, %merge]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p
  %odd = and i32 %x, 1
  %take = icmp ne i32 %odd, 0
  br i1 %take, label %left, label %right
left:
  %square = mul i32 %x, %x
  %bias = add i32 %square, 3
  %first = xor i32 %bias, 9
  br label %merge
right:
  %product = mul i32 %x, 13
  %shift = add i32 %product, 17
  %second = xor i32 %shift, 21
  br label %merge
merge:
  %root = phi i32 [%first, %left], [%second, %right]
  %u = add i32 %s, %root
  %next = add nuw i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi i32 [%u, %merge]
  br label %done
done:
  %answer = phi i32 [%seed, %entry], [%r, %exit]
  ret i32 %answer
}
