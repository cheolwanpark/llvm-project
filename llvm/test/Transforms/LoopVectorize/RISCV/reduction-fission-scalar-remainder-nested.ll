; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @nested(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Original IR retained; checks exercise standalone scalar fission and ordinary LV.
define void @nested(ptr noalias readonly %a, ptr noalias %out, i64 %count) {
entry:
  br label %outer
outer:
  %j = phi i64 [ 0, %entry ], [ %jn, %inner.exit ]
  %offset = mul i64 %j, 257
  %base = getelementptr i32, ptr %a, i64 %offset
  %dst = getelementptr i32, ptr %out, i64 %j
  br label %inner.ph
inner.ph:
  br label %inner
inner:
  %i = phi i64 [ 0, %inner.ph ], [ %next, %inner ]
  %r0 = phi i32 [ 1, %inner.ph ], [ %n0, %inner ]
  %r1 = phi i32 [ 2, %inner.ph ], [ %n1, %inner ]
  %r2 = phi i32 [ 3, %inner.ph ], [ %n2, %inner ]
  %r3 = phi i32 [ 4, %inner.ph ], [ %n3, %inner ]
  %r4 = phi i32 [ 5, %inner.ph ], [ %n4, %inner ]
  %p = getelementptr i32, ptr %base, i64 %i
  %x = load i32, ptr %p
  %c1 = mul i32 %x, 3
  %c2 = add i32 %c1, 7
  %c3 = xor i32 %c2, 11
  %c4 = mul i32 %c3, 13
  %n0 = add i32 %r0, %c4
  %n1 = xor i32 %r1, %c4
  %n2 = or i32 %r2, %c4
  %n3 = and i32 %r3, %c4
  %n4 = add i32 %r4, %c4
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, 257
  br i1 %done, label %inner.exit, label %inner
inner.exit:
  %s0 = add i32 %n0, %n1
  %s1 = add i32 %s0, %n2
  %s2 = add i32 %s1, %n3
  %s3 = add i32 %s2, %n4
  store i32 %s3, ptr %dst
  %jn = add nuw i64 %j, 1
  %end = icmp eq i64 %jn, %count
  br i1 %end, label %exit, label %outer
exit:
  ret void
}
