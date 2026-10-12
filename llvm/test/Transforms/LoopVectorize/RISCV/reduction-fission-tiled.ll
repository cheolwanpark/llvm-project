; RUN: opt -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -force-vector-width=fission:2 -reduction-fission-filter=false -reduction-fission-stack-budget=32 -reduction-fission-tile-budget=16 -S %s -o %t
; RUN: FileCheck %s --implicit-check-not=@malloc --implicit-check-not=@free --implicit-check-not=.fission.trial < %t
; RUN: llc -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -verify-machineinstrs %t -o /dev/null

; An unbounded runtime count selects tiling even when n is 0, 1, K-1, K,
; K+1 or 2*K+3. The guard bypasses all phases at zero. Initial values are
; seeded outside the tile loop, then only scalar results cross tile boundaries.
target triple = "riscv64-unknown-linux-gnu"

; CHECK-LABEL: define i32 @dynamic(
; CHECK: entry:
; CHECK-NEXT: %fission.buffer = alloca i32, i64 4, align 4
; CHECK: br i1 %empty, label %exit, label %pre
; CHECK: @llvm.lifetime.start
; CHECK: fission.tile:
; CHECK: %fission.base = phi i64 [ 0, %fission.allocate ], [ %fission.base.next, %fission.tile.latch ]
; CHECK: phi i32 [ 37, %fission.allocate ], [ %{{.*}}, %fission.tile.latch ]
; CHECK: %fission.remaining = sub {{(nuw )?}}i64 %{{.*}}, %fission.base
; CHECK-NEXT: %fission.length = call i64 @llvm.umin.i64(i64 %fission.remaining, i64 4)
; CHECK: getelementptr i32, ptr %fission.buffer, i64 %index
; CHECK: @llvm.vp.store
; CHECK: fission.base.next = add nuw i64 %fission.base, %fission.length
; CHECK: br i1 %{{.*}}, label %fission.tile, label %fission.cleanup
; CHECK: fission.reduce.preheader:
; CHECK: @llvm.vector.reduce.add
; CHECK: fission.cleanup:
; CHECK: @llvm.lifetime.end
; CHECK: ret i32
define i32 @dynamic(ptr noalias readonly %a, i64 %n) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi i32 [37, %pre], [%update, %loop]
  %p = getelementptr inbounds nuw i32, ptr %a, i64 %i
  %x = load i32, ptr %p, align 4
  %v = xor i32 %x, 123
  %update = add i32 %sum, %v
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [37, %entry], [%update, %loop]
  ret i32 %result
}

; Shared physical i8 storage: capacity is 16, not 2 or 4 based on the two i32
; consumers. Decoding and the two reduction loops remain independent.
; CHECK-LABEL: define { i32, i32 } @shared(
; CHECK: alloca i8, i64 16, align 1
; CHECK-NOT: = alloca
; CHECK: phi i32 [ 17, %fission.allocate ], [ %{{.*}}, %fission.tile.latch ]
; CHECK: phi i32 [ 29, %fission.allocate ], [ %{{.*}}, %fission.tile.latch ]
; CHECK: @llvm.umin.i64(i64 %fission.remaining, i64 16)
; CHECK: @llvm.vp.store.nxv2i8
; CHECK: fission.reduce.preheader:
; CHECK: phi <vscale x 16 x i32>
; CHECK: sext <vscale x 16 x i8>
; CHECK: @llvm.vector.reduce.add
; CHECK: fission.reduce.preheader{{[0-9]+}}:
; CHECK: phi <vscale x 16 x i32>
; CHECK: zext <vscale x 16 x i8>
; CHECK: @llvm.vector.reduce.add
; CHECK: ret { i32, i32 }
define { i32, i32 } @shared(ptr noalias readonly %a, i64 %n) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %s = phi i32 [17, %pre], [%sn, %loop]
  %u = phi i32 [29, %pre], [%un, %loop]
  %p = getelementptr inbounds nuw i8, ptr %a, i64 %i
  %x = load i8, ptr %p, align 1
  %v = xor i8 %x, -128
  %sv = sext i8 %v to i32
  %uv = zext i8 %v to i32
  %sn = add i32 %s, %sv
  %un = add i32 %u, %uv
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %rs = phi i32 [17, %entry], [%sn, %loop]
  %ru = phi i32 [29, %entry], [%un, %loop]
  %r0 = insertvalue { i32, i32 } poison, i32 %rs, 0
  %r1 = insertvalue { i32, i32 } %r0, i32 %ru, 1
  ret { i32, i32 } %r1
}

; The Map keeps both original inductions. Owned storage uses j; the borrowed
; stream has start a+3 and position base+j, unrelated to the stepped Map IV.
; CHECK-LABEL: define i32 @mixed(
; CHECK: alloca i32, i64 4
; CHECK: getelementptr i8, ptr %a, i64 12
; CHECK: phi i64 [ 5, %fission.allocate ],
; CHECK: phi i64 [ 3, %fission.allocate ],
; CHECK: getelementptr i32, ptr %fission.buffer, i64 %index
; CHECK: fission.reduce.preheader:
; CHECK: add nuw i64 %fission.base, %index{{[0-9]+}}
; CHECK: @llvm.vp.load.nxv16i32
; CHECK: @llvm.vector.reduce.add
; CHECK: fission.reduce.preheader{{[0-9]+}}:
; CHECK: getelementptr i32, ptr %fission.buffer, i64 %index{{[0-9]+}}
; CHECK: @llvm.vector.reduce.add
; CHECK: ret i32
define i32 @mixed(ptr noalias readonly %a, ptr noalias readonly %b, i64 %n) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %iter = phi i64 [0, %pre], [%next, %loop]
  %i = phi i64 [5, %pre], [%inc, %loop]
  %j = phi i64 [3, %pre], [%jn, %loop]
  %s = phi i32 [11, %pre], [%sn, %loop]
  %u = phi i32 [23, %pre], [%un, %loop]
  %p = getelementptr inbounds nuw i32, ptr %a, i64 %j
  %x = load i32, ptr %p, align 4
  %q = getelementptr i32, ptr %b, i64 %i
  %y = load i32, ptr %q, align 4
  %v = xor i32 %y, 99
  %sn = add i32 %s, %x
  %un = add i32 %u, %v
  %inc = add i64 %i, 2
  %jn = add nuw i64 %j, 1
  %next = add nuw i64 %iter, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %rs = phi i32 [11, %entry], [%sn, %loop]
  %ru = phi i32 [23, %entry], [%un, %loop]
  %result = add i32 %rs, %ru
  ret i32 %result
}
; CHECK-LABEL: define float @reassoc_fp(
; CHECK: alloca float, i64 4
; CHECK: fission.tile:
; CHECK: phi float [ %init, %fission.allocate ], [ %{{.*}}, %fission.tile.latch ]
; CHECK: fmul reassoc
; CHECK: fission.reduce.preheader:
; CHECK: @llvm.vector.reduce.fadd
; CHECK: ret float
define float @reassoc_fp(ptr noalias readonly %a, i64 %n, float %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi float [%init, %pre], [%update, %loop]
  %p = getelementptr inbounds nuw float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %v = fmul reassoc float %x, %x
  %update = fadd reassoc float %sum, %v
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%init, %entry], [%update, %loop]
  ret float %result
}


; Buffers belong to the function entry, while lifetimes delimit each source
; invocation inside outer. Distinct output elements receive each final scalar.
; CHECK-LABEL: define void @nested(
; CHECK: entry:
; CHECK-NEXT: %fission.buffer = alloca i32, i64 4
; CHECK-NOT: = alloca
; CHECK: outer:
; CHECK-NOT: = alloca
; CHECK: @llvm.lifetime.start
; CHECK: fission.tile:
; CHECK-NOT: = alloca
; CHECK: fission.cleanup:
; CHECK: @llvm.lifetime.end
; CHECK: store i32
; CHECK: br i1 %last, label %exit.loopexit, label %outer
; CHECK: ret void
define void @nested(ptr noalias readonly %a, ptr noalias %out, i64 %n, i64 %repeats) {
entry:
  %empty = icmp eq i64 %repeats, 0
  br i1 %empty, label %exit, label %outer
outer:
  %row = phi i64 [0, %entry], [%row.next, %finish]
  %zero = icmp eq i64 %n, 0
  br i1 %zero, label %finish, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi i32 [37, %pre], [%update, %loop]
  %p = getelementptr inbounds nuw i32, ptr %a, i64 %i
  %x = load i32, ptr %p, align 4
  %v = xor i32 %x, 123
  %update = add i32 %sum, %v
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %finish, label %loop
finish:
  %r = phi i32 [37, %outer], [%update, %loop]
  %dest = getelementptr i32, ptr %out, i64 %row
  store i32 %r, ptr %dest, align 4
  %row.next = add nuw i64 %row, 1
  %last = icmp eq i64 %row.next, %repeats
  br i1 %last, label %exit, label %outer
exit:
  ret void
}

; The optional fmuladd contraction can still materialize its rounded product;
; tiling neither recovers the contraction nor gives strict fma this permission.
; CHECK-LABEL: define float @fmuladd(
; CHECK: alloca float, i64 4
; CHECK: phi float [ %init, %fission.allocate ], [ %{{.*}}, %fission.tile.latch ]
; CHECK: fmul reassoc <vscale x 2 x float>
; CHECK-NOT: fmul fast
; CHECK: fission.reduce.preheader:
; CHECK: fadd reassoc <vscale x 16 x float>
; CHECK: call reassoc float @llvm.vector.reduce.fadd
; CHECK: ret float

define float @fmuladd(ptr noalias readonly %a, i64 %n, float %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %sum = phi float [%init, %pre], [%update, %loop]
  %p = getelementptr inbounds nuw float, ptr %a, i64 %i
  %x = load float, ptr %p, align 4
  %update = call reassoc float @llvm.fmuladd.f32(float %x, float %x, float %sum)
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%init, %entry], [%update, %loop]
  ret float %result
}

declare float @llvm.fmuladd.f32(float, float, float)

; A supported select needs an identity contribution and scalar restoration for
; an all-skipped exceptional initializer. Freeze once before the first tile.
; CHECK-LABEL: define float @selected_contribution(
; CHECK: alloca float, i64 4
; CHECK: fission.allocate:
; CHECK: %fission.initial = freeze float %init
; CHECK: fission.tile:
; CHECK: phi float [ %fission.initial, %fission.allocate ], [ %fission.result.special, %fission.tile.latch ]
; CHECK: select <vscale x 2 x i1>
; CHECK: fission.reduce.preheader:
; CHECK-NOT: freeze
; CHECK: fadd reassoc arcp contract afn <vscale x 16 x float>
; CHECK: @llvm.vector.reduce.fadd
; CHECK: @llvm.is.fpclass.f32
; CHECK: %fission.result.special = select i1 %{{.*}}, float %fission.carry1,
; CHECK: ret float

define float @selected_contribution(ptr noalias readonly %a, ptr noalias readonly %flags, i64 %n, float %init) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %exit, label %pre
pre:
  br label %loop
loop:
  %i = phi i64 [0, %pre], [%inc, %loop]
  %acc = phi float [%init, %pre], [%next, %loop]
  %pa = getelementptr float, ptr %a, i64 %i
  %pf = getelementptr i8, ptr %flags, i64 %i
  %x = load float, ptr %pa, align 4
  %flag = load i8, ptr %pf, align 1
  %active = icmp ne i8 %flag, 0
  %sum = fadd fast float %acc, %x
  %next = select i1 %active, float %sum, float %acc
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  %result = phi float [%init, %entry], [%next, %loop]
  ret float %result
}
