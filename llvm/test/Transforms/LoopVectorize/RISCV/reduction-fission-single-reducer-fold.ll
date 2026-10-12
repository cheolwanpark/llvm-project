; RUN: opt -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -force-vector-width=fission:2 -reduction-fission-filter=false -reduction-fission-stack-budget=64 -reduction-fission-tile-budget=4 -S %s -o %t.full
; RUN: FileCheck %s --check-prefix=FULL < %t.full
; RUN: opt -passes='loop-simplify,lcssa,loop-vectorize,verify' -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -riscv-v-vector-bits-min=128 -scalable-vectorization=on -verify-dom-info -verify-loop-info -verify-scev -force-vector-width=fission:2 -reduction-fission-filter=false -reduction-fission-stack-budget=8 -reduction-fission-tile-budget=8 -S %s -o %t.tile
; RUN: FileCheck %s --check-prefix=TILE < %t.tile
; RUN: llc -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -verify-machineinstrs %t.full -o - | FileCheck %s --check-prefix=ASM
; RUN: llc -mtriple=riscv64 -mattr=+v,+f,+d -mcpu=xiangshan-kunminghu -verify-machineinstrs %t.tile -o - | FileCheck %s --check-prefix=ASM

; One reducer can fold in both storage modes. Two reducers still retain
; separate EVL backedges, even though each generated loop has one PHI.

; ASM-LABEL: single:
; ASM: vse32.v
; ASM: vle32.v
; ASM-NOT: {{b(ne|eq|lt|ge)}}
; ASM: vredsum.vs
; ASM-LABEL: multiple:
; ASM: vse8.v
; ASM: vle8.v
; ASM: bnez
; ASM: vredsum.vs
; ASM: vle8.v
; ASM: bnez
; ASM: vredsum.vs

; FULL-LABEL: define i32 @single(
; FULL: alloca i32, i64 11
; FULL: fission.reduce.preheader:
; FULL-NOT: phi <vscale
; FULL-NOT: @llvm.experimental.get.vector.length
; FULL-NOT: br i1
; FULL: @llvm.vector.reduce.add
; TILE-LABEL: define i32 @single(
; TILE: alloca i32, i64 2
; TILE: fission.tile:
; TILE: phi i32 [ 37, %fission.allocate ], [ %{{.*}}, %fission.tile.latch ]
; TILE: fission.reduce.preheader:
; TILE-NOT: phi <vscale
; TILE-NOT: @llvm.experimental.get.vector.length
; TILE-NOT: br i1
; TILE: @llvm.vector.reduce.add

define i32 @single(ptr noalias readonly %a, i64 %n) vscale_range(2,1024) {
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
  %done = icmp eq i64 %inc, 11
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [37, %entry], [%update, %loop]
  ret i32 %result
}

; FULL-LABEL: define { i32, i32 } @multiple(
; FULL: fission.reduce.preheader:
; FULL: [[BODY0:vector.body[0-9]+]]:
; FULL: phi <vscale x 16 x i32>
; FULL: @llvm.experimental.get.vector.length
; FULL: br i1 %{{.*}}, label %{{.*}}, label %[[BODY0]]
; FULL: @llvm.vector.reduce.add
; FULL: fission.reduce.preheader{{[0-9]+}}:
; FULL: [[BODY1:vector.body[0-9]+]]:
; FULL: phi <vscale x 16 x i32>
; FULL: @llvm.experimental.get.vector.length
; FULL: br i1 %{{.*}}, label %{{.*}}, label %[[BODY1]]
; FULL: @llvm.vector.reduce.add
; TILE-LABEL: define { i32, i32 } @multiple(
; TILE: fission.reduce.preheader:
; TILE: [[BODY0:vector.body[0-9]+]]:
; TILE: phi <vscale x 16 x i32>
; TILE: @llvm.experimental.get.vector.length
; TILE: br i1 %{{.*}}, label %{{.*}}, label %[[BODY0]]
; TILE: @llvm.vector.reduce.add
; TILE: fission.reduce.preheader{{[0-9]+}}:
; TILE: [[BODY1:vector.body[0-9]+]]:
; TILE: phi <vscale x 16 x i32>
; TILE: @llvm.experimental.get.vector.length
; TILE: br i1 %{{.*}}, label %{{.*}}, label %[[BODY1]]
; TILE: @llvm.vector.reduce.add

define { i32, i32 } @multiple(ptr noalias readonly %a, i64 %n) vscale_range(2,1024) {
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
  %done = icmp eq i64 %inc, 11
  br i1 %done, label %exit, label %loop
exit:
  %rs = phi i32 [17, %entry], [%sn, %loop]
  %ru = phi i32 [29, %entry], [%un, %loop]
  %r0 = insertvalue { i32, i32 } poison, i32 %rs, 0
  %r1 = insertvalue { i32, i32 } %r0, i32 %ru, 1
  ret { i32, i32 } %r1
}
