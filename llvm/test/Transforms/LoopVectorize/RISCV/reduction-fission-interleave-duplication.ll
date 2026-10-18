; RUN: opt -enable-scalar-reduction-fission=false -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 -hints-allow-reordering=false \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-min-chain-depth=8 \
; RUN:   -vplan-reduction-fission-force-producer-vf=2 -vplan-reduction-fission-force-accumulator-vf=4 \
; RUN:   -pass-remarks=vplan-reduction-fission -S %s -o %t 2> %t.remarks
; RUN: FileCheck %s < %t
; RUN: FileCheck %s --check-prefix=REMARK < %t.remarks
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t -o /dev/null
; RUN: opt -enable-scalar-reduction-fission=false -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -force-vector-interleave=1 -hints-allow-reordering=false -enable-vplan-reduction-fission \
; RUN:   -vplan-reduction-fission-force-producer-vf=4 -vplan-reduction-fission-force-accumulator-vf=2 \
; RUN:   -S %s -o %t.reverse
; RUN: FileCheck %s --check-prefix=REVERSE < %t.reverse
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.reverse -o /dev/null
;
; A long producer uses member zero; a short consumer uses member one. Keeping
; the complete group in both stages intentionally reloads both original members.
; The host checker executes both vector groups and their independent scalar tails.
; REMARK: scratch capacity 65, scratch bytes 260, scratch store bytes/iteration 4, scratch load bytes/iteration 4, duplicated recipes {{[1-9][0-9]*}}, reread loads/iteration 2
; CHECK-LABEL: define void @interleave_reread(
; CHECK: vector.fission.producer.body:
; CHECK: load <vscale x 4 x i32>
; CHECK: @llvm.vector.deinterleave2.nxv4i32
; CHECK: scalar.fission.producer.body:
; CHECK: load i32
; CHECK: vector.fission.accumulator.body:
; CHECK: load <vscale x 8 x i32>
; CHECK: @llvm.vector.deinterleave2.nxv8i32
; CHECK: scalar.fission.accumulator.body:
; CHECK: getelementptr i8, ptr {{.*}}, i64 4
; CHECK: load i32
; REVERSE-LABEL: define void @interleave_reread(
; REVERSE: vector.fission.producer.body:
; REVERSE: @llvm.vector.deinterleave2.nxv8i32
; REVERSE: vector.fission.accumulator.body:
; REVERSE: @llvm.vector.deinterleave2.nxv4i32
define void @interleave_reread(ptr readonly %a, ptr %out, i64 %n) {
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
  %base = mul nuw i64 %i, 2
  %p0 = getelementptr i32, ptr %a, i64 %base
  %x0 = load i32, ptr %p0, align 4
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr i32, ptr %a, i64 %idx1
  %x1 = load i32, ptr %p1, align 4
  %c0 = mul i32 %x0, 3
  %c1 = xor i32 %c0, 5
  %c2 = mul i32 %c1, 7
  %c3 = xor i32 %c2, 9
  %c4 = mul i32 %c3, 11
  %c5 = xor i32 %c4, 13
  %c6 = mul i32 %c5, 15
  %c7 = xor i32 %c6, 17
  %c8 = mul i32 %c7, 19
  %c9 = xor i32 %c8, 21
  %term = mul i32 %c9, 23
  %update = add i32 %sum, %term
  %updated.bits = xor i32 %bits, %x1
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

; The same partition with a non-power-of-two stride. Both non-scratch members
; remain in the consumer, which rereads the complete group in its vector path.
; REMARK: scratch capacity 65, scratch bytes 260, scratch store bytes/iteration 4, scratch load bytes/iteration 4, duplicated recipes {{[1-9][0-9]*}}, reread loads/iteration 3
; CHECK-LABEL: define void @interleave3_reread(
; CHECK: vector.fission.producer.body:
; CHECK: @llvm.vector.deinterleave3.nxv6i32
; CHECK: scalar.fission.producer.body:
; CHECK: load i32
; CHECK: vector.fission.accumulator.body:
; CHECK: @llvm.vector.deinterleave3.nxv12i32
; CHECK: scalar.fission.accumulator.body:
; CHECK: getelementptr i8, ptr {{.*}}, i64 4
; CHECK: load i32
; CHECK: getelementptr i8, ptr {{.*}}, i64 8
; CHECK: load i32
; REVERSE-LABEL: define void @interleave3_reread(
; REVERSE: vector.fission.producer.body:
; REVERSE: @llvm.vector.deinterleave3.nxv12i32
; REVERSE: vector.fission.accumulator.body:
; REVERSE: @llvm.vector.deinterleave3.nxv6i32
define void @interleave3_reread(ptr readonly %a, ptr %out, i64 %n) {
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
  %base = mul nuw i64 %i, 3
  %p0 = getelementptr i32, ptr %a, i64 %base
  %x0 = load i32, ptr %p0, align 4
  %idx1 = add nuw i64 %base, 1
  %p1 = getelementptr i32, ptr %a, i64 %idx1
  %x1 = load i32, ptr %p1, align 4
  %idx2 = add nuw i64 %base, 2
  %p2 = getelementptr i32, ptr %a, i64 %idx2
  %x2 = load i32, ptr %p2, align 4
  %c0 = mul i32 %x0, 3
  %c1 = xor i32 %c0, 5
  %c2 = mul i32 %c1, 7
  %c3 = xor i32 %c2, 9
  %c4 = mul i32 %c3, 11
  %c5 = xor i32 %c4, 13
  %c6 = mul i32 %c5, 15
  %c7 = xor i32 %c6, 17
  %c8 = mul i32 %c7, 19
  %c9 = xor i32 %c8, 21
  %term = mul i32 %c9, 23
  %short = add i32 %x1, %x2
  %update = add i32 %sum, %term
  %updated.bits = xor i32 %bits, %short
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
