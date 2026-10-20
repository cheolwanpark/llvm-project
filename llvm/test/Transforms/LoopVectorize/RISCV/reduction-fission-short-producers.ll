; RUN: opt -passes=scalar-fission -pass-remarks-output=%t.frontier.yaml -pass-remarks-filter=scalar-fission -disable-output %s
; RUN: FileCheck %s --check-prefix=FRONTIER < %t.frontier.yaml
; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @short_one(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @short_two(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @short_ordered(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @short_ordered_two(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @short_dependence(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; SCALAR-MIGRATION-LABEL: define {{.*}} @short_invariant(
; SCALAR-MIGRATION-NOT: scalar.fission
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
; FRONTIER: Name: Rejected
; FRONTIER: Function: short_one
; FRONTIER: Reason: producer-too-shallow
define void @short_one(ptr noalias readonly %a, ptr noalias %out, i64 %n) {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p, align 4
  %term = mul i32 %x, 3
  %update = add i32 %sum, %term
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  store i32 %update, ptr %out, align 4
  ret void
bypass:
  store i32 17, ptr %out, align 4
  ret void
}

; FRONTIER: Name: Rejected
; FRONTIER: Function: short_two
; FRONTIER: Reason: producer-too-shallow
define void @short_two(ptr noalias readonly %a, ptr noalias %out, i64 %n) {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %bits = phi i32 [23, %preheader], [%updated.bits, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p, align 4
  %term = mul i32 %x, 3
  %other = xor i32 %x, 7
  %update = add i32 %sum, %term
  %updated.bits = xor i32 %bits, %other
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  store i32 %update, ptr %out, align 4
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %updated.bits, ptr %o1, align 4
  ret void
bypass:
  store i32 17, ptr %out, align 4
  %b1 = getelementptr i32, ptr %out, i64 1
  store i32 23, ptr %b1, align 4
  ret void
}

; FRONTIER: Name: Rejected
; FRONTIER: Function: short_ordered
; FRONTIER: Reason: producer-too-shallow
define void @short_ordered(ptr noalias readonly %a, ptr noalias %out, i64 %n, double %start) {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi double [%start, %preheader], [%update, %loop]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p, align 8
  %term = fmul double %x, 2.0
  %update = fadd double %sum, %term
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  store double %update, ptr %out, align 8
  ret void
bypass:
  store double %start, ptr %out, align 8
  ret void
}

; FRONTIER: Name: Rejected
; FRONTIER: Function: short_ordered_two
; FRONTIER: Reason: producer-too-shallow
define void @short_ordered_two(ptr noalias readonly %a, ptr noalias %out, i64 %n, double %start) {
entry:
  %bounded = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %bounded, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %i = phi i64 [0, %preheader], [%next, %loop]
  %sum = phi double [%start, %preheader], [%update, %loop]
  %sum2 = phi double [-0.0, %preheader], [%update2, %loop]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p, align 8
  %term = fmul double %x, 2.0
  %other = fmul double %x, 3.0
  %update = fadd double %sum, %term
  %update2 = fadd double %sum2, %other
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  store double %update, ptr %out, align 8
  %o1 = getelementptr double, ptr %out, i64 1
  store double %update2, ptr %o1, align 8
  ret void
bypass:
  store double %start, ptr %out, align 8
  %b1 = getelementptr double, ptr %out, i64 1
  store double -0.0, ptr %b1, align 8
  ret void
}

; FRONTIER: Name: Rejected
; FRONTIER: Function: short_dependence
; FRONTIER: Reason: producer-too-shallow
define void @short_dependence(ptr %a, ptr noalias %out) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %sum = phi i32 [0, %entry], [%update, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %x = load i32, ptr %p, align 4
  %term = mul i32 %x, 3
  %update = add i32 %sum, %term
  %next = add nuw i64 %i, 1
  %q = getelementptr i32, ptr %a, i64 %next
  store i32 %term, ptr %q, align 4
  %done = icmp eq i64 %next, 65
  br i1 %done, label %exit, label %loop
exit:
  store i32 %update, ptr %out, align 4
  ret void
}

; FRONTIER: Name: Rejected
; FRONTIER: Function: short_invariant
; FRONTIER: Reason: no-computed-boundary
define void @short_invariant(i32 %x, ptr %out) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %sum = phi i32 [0, %entry], [%update, %loop]
  %term = mul i32 %x, 3
  %update = add i32 %sum, %term
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, 65
  br i1 %done, label %exit, label %loop
exit:
  store i32 %update, ptr %out, align 4
  ret void
}
