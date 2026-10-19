; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -pass-remarks=vplan-reduction-fission \
; RUN:   -S %s -o %t 2> %t.remarks
; RUN: FileCheck %s < %t
; RUN: FileCheck %s --check-prefix=REMARK < %t.remarks
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t -o /dev/null
; RUN: opt -enable-scalar-reduction-fission=false -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-min-chain-depth=1000 -vplan-reduction-fission-min-reductions=1000 \
; RUN:   -vplan-reduction-fission-min-pressure-percent=1000 -S %s | FileCheck %s
; RUN: opt -enable-scalar-reduction-fission=false -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=1 -vplan-reduction-fission-force-accumulator-vf=4 \
; RUN:   -S %s | FileCheck %s
; RUN: opt -enable-scalar-reduction-fission=false -passes=loop-vectorize -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=259 -S %s \
; RUN:   | FileCheck %s --check-prefix=REJECT --implicit-check-not=vector.fission --implicit-check-not=fission.scratch
; RUN: opt -enable-scalar-reduction-fission=false -passes=loop-vectorize -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-max-scratch-bytes=260 -S %s | FileCheck %s --check-prefix=BOUND
; RUN: opt -enable-scalar-reduction-fission=false -passes=loop-vectorize -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -hints-allow-reordering=false -S %s \
; RUN:   | FileCheck %s --check-prefix=REJECT --implicit-check-not=vector.fission --implicit-check-not=fission.scratch
; RUN: opt -enable-scalar-reduction-fission=false -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-max-scalable-vf-multiplier=1 -pass-remarks=vplan-reduction-fission \
; RUN:   -S %s -o %t.limited 2> %t.limited.remarks
; RUN: FileCheck %s < %t.limited
; RUN: FileCheck %s --check-prefix=LIMITED < %t.limited.remarks
;
; Explicit fission now accepts one or two short, low-pressure producers, with
; no pressure/FP cost win required. The depth flag is a cut preference and the
; old reduction/pressure minima are compatibility no-ops. These functions are
; also executed against scalar IR by utils/check-reduction-fission.py.
; Scratch capacity is 65, execution uses guarded N, and each stage owns a tail.
; LIMITED-COUNT-2: producer VF vscale x 4, accumulator VF vscale x 4
; LIMITED-COUNT-2: producer VF vscale x 2, accumulator VF vscale x 2
; REMARK: split reduction loop: baseline VF {{.*}}, producer VF {{.*}}, accumulator VF {{.*}}, trip count bounded-runtime, scratch capacity 65, scratch bytes 260
; REMARK-SAME: scratch store bytes/iteration 4, scratch load bytes/iteration 4, duplicated recipes 0, reread loads/iteration 0
; REMARK: reduction sum: ordered, reordering permission: IR
; REJECT-LABEL: define void @short_one(
; REJECT: ret void
; BOUND-LABEL: define void @short_one(
; BOUND: alloca [65 x i32]
; BOUND: vector.fission.producer.body:
; BOUND: vector.fission.accumulator.body:
; BOUND-LABEL: define void @short_two(
; BOUND-NOT: fission
; BOUND: ret void
;
; CHECK-LABEL: define void @short_one(
; CHECK: alloca [65 x i32]
; CHECK: vector.fission.producer.body:
; CHECK: mul <vscale x
; CHECK: scalar.fission.producer.body:
; CHECK: vector.fission.accumulator.body:
; CHECK: @llvm.vector.reduce.add.
; CHECK: scalar.fission.accumulator.body:
; CHECK: vector.fission.done:
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

; CHECK-LABEL: define void @short_two(
; CHECK-COUNT-2: alloca [65 x i32]
; CHECK: vector.fission.producer.body:
; CHECK: scalar.fission.producer.body:
; CHECK: vector.fission.accumulator.body:
; CHECK: @llvm.vector.reduce.add.
; CHECK: @llvm.vector.reduce.xor.
; CHECK: scalar.fission.accumulator.body:
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

; These are ordered, ordinary FP operations, with no reassociation permission.
; CHECK-LABEL: define void @short_ordered(
; CHECK: alloca [65 x double]
; CHECK: vector.fission.producer.body:
; CHECK: fmul <vscale x
; CHECK: scalar.fission.producer.body:
; CHECK: vector.fission.accumulator.body:
; CHECK: call double @llvm.vector.reduce.fadd.
; CHECK: scalar.fission.accumulator.body:
; CHECK: fadd double
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

; CHECK-LABEL: define void @short_ordered_two(
; CHECK-COUNT-2: alloca [65 x double]
; CHECK: vector.fission.producer.body:
; CHECK: scalar.fission.producer.body:
; CHECK: vector.fission.accumulator.body:
; CHECK-COUNT-2: call double @llvm.vector.reduce.fadd.
; CHECK: scalar.fission.accumulator.body:
; CHECK-COUNT-2: fadd double
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

; Real loop-carried memory flow is still a rejection even with one short sum.
; CHECK-LABEL: define void @short_dependence(
; CHECK-NOT: fission
; CHECK: ret void
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

; A reduction of an invariant does not justify filling a per-iteration array.
; CHECK-LABEL: define void @short_invariant(
; CHECK-NOT: fission
; CHECK: ret void
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
