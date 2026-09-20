; RUN: opt -passes='default<O2>,verify' -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v,+f,+d -riscv-v-vector-bits-min=128 -force-vector-width=fission:2 -scalable-vectorization=on -force-vector-interleave=1 -disable-loop-unrolling -vectorize-slp=false -S %s -o %t
; RUN: opt -passes='print<loops>' -disable-output %t 2>&1 | FileCheck %s --check-prefix=LOOPS
; RUN: FileCheck %s --check-prefix=IR < %t
; RUN: llc -mcpu=xiangshan-kunminghu -mattr=+v,+f,+d -verify-machineinstrs -stop-before=riscv-vl-optimizer %t -o %t.mir
; RUN: llc -mcpu=xiangshan-kunminghu -mattr=+v,+f,+d -verify-machineinstrs -start-after=riscv-vl-optimizer %t.mir -o %t.s
; RUN: FileCheck %s --check-prefix=ASM --implicit-check-not=vs8r.v --implicit-check-not=vl8r.v < %t.s
; RUN: FileCheck %s --check-prefix=HEADERS < %t.s
;
; Sharing a normalized expression among eight accumulators shares only one
; 31-element buffer. Full O2 and codegen must keep all eight m8 reducers.
; LOOPS-COUNT-9: Loop at depth 1
; LOOPS-NOT: Loop at depth
; HEADERS-COUNT-9: Inner Loop Header
; HEADERS-NOT: Inner Loop Header
; IR-LABEL: define void @shared_eight(
; IR: alloca [31 x float]
; IR-NOT: alloca
; IR: phi <vscale x 16 x float>
; IR: @llvm.experimental.get.vector.length
; IR: br i1 %{{.*}}, label %{{.*}}, label %{{.*}}
; IR: @llvm.vector.reduce.fadd.nxv16f32
; IR: phi <vscale x 16 x float>
; IR: @llvm.experimental.get.vector.length
; IR: br i1 %{{.*}}, label %{{.*}}, label %{{.*}}
; IR: @llvm.vector.reduce.fadd.nxv16f32
; IR: phi <vscale x 16 x float>
; IR: @llvm.experimental.get.vector.length
; IR: br i1 %{{.*}}, label %{{.*}}, label %{{.*}}
; IR: @llvm.vector.reduce.fadd.nxv16f32
; IR: phi <vscale x 16 x float>
; IR: @llvm.experimental.get.vector.length
; IR: br i1 %{{.*}}, label %{{.*}}, label %{{.*}}
; IR: @llvm.vector.reduce.fadd.nxv16f32
; IR: phi <vscale x 16 x float>
; IR: @llvm.experimental.get.vector.length
; IR: br i1 %{{.*}}, label %{{.*}}, label %{{.*}}
; IR: @llvm.vector.reduce.fadd.nxv16f32
; IR: phi <vscale x 16 x float>
; IR: @llvm.experimental.get.vector.length
; IR: br i1 %{{.*}}, label %{{.*}}, label %{{.*}}
; IR: @llvm.vector.reduce.fadd.nxv16f32
; IR: phi <vscale x 16 x float>
; IR: @llvm.experimental.get.vector.length
; IR: br i1 %{{.*}}, label %{{.*}}, label %{{.*}}
; IR: @llvm.vector.reduce.fadd.nxv16f32
; IR: phi <vscale x 16 x float>
; IR: @llvm.experimental.get.vector.length
; IR: br i1 %{{.*}}, label %{{.*}}, label %{{.*}}
; IR: @llvm.vector.reduce.fadd.nxv16f32
; IR: ret void
; ASM-LABEL: shared_eight:
; ASM: .LBB{{[0-9_]+}}:
; ASM: vsetvli {{.*}}, e32, m8
; ASM: bnez
; ASM: vfredusum.vs
; ASM: .LBB{{[0-9_]+}}:
; ASM: vsetvli {{.*}}, e32, m8
; ASM: bnez
; ASM: vfredusum.vs
; ASM: .LBB{{[0-9_]+}}:
; ASM: vsetvli {{.*}}, e32, m8
; ASM: bnez
; ASM: vfredusum.vs
; ASM: .LBB{{[0-9_]+}}:
; ASM: vsetvli {{.*}}, e32, m8
; ASM: bnez
; ASM: vfredusum.vs
; ASM: .LBB{{[0-9_]+}}:
; ASM: vsetvli {{.*}}, e32, m8
; ASM: bnez
; ASM: vfredusum.vs
; ASM: .LBB{{[0-9_]+}}:
; ASM: vsetvli {{.*}}, e32, m8
; ASM: bnez
; ASM: vfredusum.vs
; ASM: .LBB{{[0-9_]+}}:
; ASM: vsetvli {{.*}}, e32, m8
; ASM: bnez
; ASM: vfredusum.vs
; ASM: .LBB{{[0-9_]+}}:
; ASM: vsetvli {{.*}}, e32, m8
; ASM: bnez
; ASM: vfredusum.vs
; ASM: ret

target triple = "riscv64-unknown-linux-gnu"
define void @shared_eight(ptr noalias readonly %a, ptr noalias readonly %b, ptr noalias %out) #0 {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%inc, %loop]
  %s0 = phi float [0.0, %entry], [%n0, %loop]
  %s1 = phi float [1.0, %entry], [%n1, %loop]
  %s2 = phi float [2.0, %entry], [%n2, %loop]
  %s3 = phi float [3.0, %entry], [%n3, %loop]
  %s4 = phi float [4.0, %entry], [%n4, %loop]
  %s5 = phi float [5.0, %entry], [%n5, %loop]
  %s6 = phi float [6.0, %entry], [%n6, %loop]
  %s7 = phi float [7.0, %entry], [%n7, %loop]
  %pa = getelementptr float, ptr %a, i64 %i
  %pb = getelementptr float, ptr %b, i64 %i
  %x = load float, ptr %pa, align 4
  %y = load float, ptr %pb, align 4
  %p = fmul fast float %x, %x
  %q = fmul fast float %y, %y
  %v0 = fadd fast float %s0, %p
  %n0 = fadd fast float %v0, %q
  %v1 = fadd fast float %s1, %q
  %n1 = fadd fast float %v1, %p
  %v2 = fadd fast float %s2, %p
  %n2 = fadd fast float %v2, %q
  %v3 = fadd fast float %s3, %q
  %n3 = fadd fast float %v3, %p
  %v4 = fadd fast float %s4, %p
  %n4 = fadd fast float %v4, %q
  %v5 = fadd fast float %s5, %q
  %n5 = fadd fast float %v5, %p
  %v6 = fadd fast float %s6, %p
  %n6 = fadd fast float %v6, %q
  %v7 = fadd fast float %s7, %q
  %n7 = fadd fast float %v7, %p
  %inc = add nuw i64 %i, 1
  %done = icmp eq i64 %inc, 31
  br i1 %done, label %exit, label %loop
exit:
  %r0 = phi float [%n0, %loop]
  %r1 = phi float [%n1, %loop]
  %r2 = phi float [%n2, %loop]
  %r3 = phi float [%n3, %loop]
  %r4 = phi float [%n4, %loop]
  %r5 = phi float [%n5, %loop]
  %r6 = phi float [%n6, %loop]
  %r7 = phi float [%n7, %loop]
  %o0 = getelementptr float, ptr %out, i64 0
  store float %r0, ptr %o0
  %o1 = getelementptr float, ptr %out, i64 1
  store float %r1, ptr %o1
  %o2 = getelementptr float, ptr %out, i64 2
  store float %r2, ptr %o2
  %o3 = getelementptr float, ptr %out, i64 3
  store float %r3, ptr %o3
  %o4 = getelementptr float, ptr %out, i64 4
  store float %r4, ptr %o4
  %o5 = getelementptr float, ptr %out, i64 5
  store float %r5, ptr %o5
  %o6 = getelementptr float, ptr %out, i64 6
  store float %r6, ptr %o6
  %o7 = getelementptr float, ptr %out, i64 7
  store float %r7, ptr %o7
  ret void
}
attributes #0 = { vscale_range(2,1024) }
