; RUN: opt -passes='default<O2>,verify' -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v,+f,+d -riscv-v-vector-bits-min=128 -force-vector-width=fission:2 -scalable-vectorization=on -force-vector-interleave=1 -disable-loop-unrolling -vectorize-slp=false -S %s -o %t
; RUN: opt -passes='print<loops>' -disable-output %t 2>&1 | FileCheck %s --check-prefix=LOOPS
; RUN: FileCheck %s --check-prefix=IR < %t
; RUN: llc -mcpu=xiangshan-kunminghu -mattr=+v,+f,+d -verify-machineinstrs -stop-before=riscv-vl-optimizer %t -o %t.mir
; RUN: llc -mcpu=xiangshan-kunminghu -mattr=+v,+f,+d -verify-machineinstrs -start-after=riscv-vl-optimizer %t.mir -o - | FileCheck %s --check-prefix=ASM --implicit-check-not=vs8r.v --implicit-check-not=vl8r.v
; RUN: opt -passes='default<O2>,verify' -mtriple=riscv64 -mcpu=xiangshan-kunminghu -mattr=+v,+f,+d -riscv-v-vector-bits-min=128 -force-vector-width=16 -scalable-vectorization=on -force-vector-interleave=1 -disable-loop-unrolling -vectorize-slp=false -S %s -o %t.normal
; RUN: opt -passes='print<loops>' -disable-output %t.normal 2>&1 | FileCheck %s --check-prefix=NORMAL --allow-empty
;
; N=31 is below the minimum VLMAX (32 f32 elements at VF16, VLEN128).
; Each reducer must retain a real EVL-controlled backedge after full O2,
; finish its m8 accumulation and collapse before the next reducer starts.
; The ordinary short loop may still fold. Map uses its independent VF2.
;
; LOOPS-COUNT-9: Loop at depth 1
; LOOPS-NOT: Loop at depth
; NORMAL-NOT: Loop at depth
; IR-LABEL: define void @eight_accumulators(
; IR-COUNT-8: alloca [31 x float]
; IR-NOT: alloca
; IR: phi <vscale x 16 x float>
; IR: @llvm.experimental.get.vector.length.i64
; IR: br i1 %{{.*}}, label %{{.*}}, label %{{.*}}
; IR: @llvm.vector.reduce.fadd.nxv16f32
; IR: phi <vscale x 16 x float>
; IR: @llvm.experimental.get.vector.length.i64
; IR: br i1 %{{.*}}, label %{{.*}}, label %{{.*}}
; IR: @llvm.vector.reduce.fadd.nxv16f32
; IR: phi <vscale x 16 x float>
; IR: @llvm.experimental.get.vector.length.i64
; IR: br i1 %{{.*}}, label %{{.*}}, label %{{.*}}
; IR: @llvm.vector.reduce.fadd.nxv16f32
; IR: phi <vscale x 16 x float>
; IR: @llvm.experimental.get.vector.length.i64
; IR: br i1 %{{.*}}, label %{{.*}}, label %{{.*}}
; IR: @llvm.vector.reduce.fadd.nxv16f32
; IR: phi <vscale x 16 x float>
; IR: @llvm.experimental.get.vector.length.i64
; IR: br i1 %{{.*}}, label %{{.*}}, label %{{.*}}
; IR: @llvm.vector.reduce.fadd.nxv16f32
; IR: phi <vscale x 16 x float>
; IR: @llvm.experimental.get.vector.length.i64
; IR: br i1 %{{.*}}, label %{{.*}}, label %{{.*}}
; IR: @llvm.vector.reduce.fadd.nxv16f32
; IR: phi <vscale x 16 x float>
; IR: @llvm.experimental.get.vector.length.i64
; IR: br i1 %{{.*}}, label %{{.*}}, label %{{.*}}
; IR: @llvm.vector.reduce.fadd.nxv16f32
; IR: phi <vscale x 16 x float>
; IR: @llvm.experimental.get.vector.length.i64
; IR: br i1 %{{.*}}, label %{{.*}}, label %{{.*}}
; IR: @llvm.vector.reduce.fadd.nxv16f32
; IR: ret void
; ASM-LABEL: eight_accumulators:
; ASM: .LBB{{[0-9_]+}}:{{.*}}
; ASM: vsetvli {{.*}}, e32, m8
; ASM: bnez
; ASM: vfredusum.vs
; ASM: .LBB{{[0-9_]+}}:{{.*}}
; ASM: vsetvli {{.*}}, e32, m8
; ASM: bnez
; ASM: vfredusum.vs
; ASM: .LBB{{[0-9_]+}}:{{.*}}
; ASM: vsetvli {{.*}}, e32, m8
; ASM: bnez
; ASM: vfredusum.vs
; ASM: .LBB{{[0-9_]+}}:{{.*}}
; ASM: vsetvli {{.*}}, e32, m8
; ASM: bnez
; ASM: vfredusum.vs
; ASM: .LBB{{[0-9_]+}}:{{.*}}
; ASM: vsetvli {{.*}}, e32, m8
; ASM: bnez
; ASM: vfredusum.vs
; ASM: .LBB{{[0-9_]+}}:{{.*}}
; ASM: vsetvli {{.*}}, e32, m8
; ASM: bnez
; ASM: vfredusum.vs
; ASM: .LBB{{[0-9_]+}}:{{.*}}
; ASM: vsetvli {{.*}}, e32, m8
; ASM: bnez
; ASM: vfredusum.vs
; ASM: .LBB{{[0-9_]+}}:{{.*}}
; ASM: vsetvli {{.*}}, e32, m8
; ASM: bnez
; ASM: vfredusum.vs
; ASM: ret

target triple = "riscv64-unknown-linux-gnu"

define void @eight_accumulators(ptr noalias %a, ptr noalias %b, ptr noalias %out) #0 {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%inc, %loop]
  %s0 = phi float [0.0, %entry], [%n0, %loop]
  %s1 = phi float [0.0, %entry], [%n1, %loop]
  %s2 = phi float [0.0, %entry], [%n2, %loop]
  %s3 = phi float [0.0, %entry], [%n3, %loop]
  %s4 = phi float [0.0, %entry], [%n4, %loop]
  %s5 = phi float [0.0, %entry], [%n5, %loop]
  %s6 = phi float [0.0, %entry], [%n6, %loop]
  %s7 = phi float [0.0, %entry], [%n7, %loop]
  %j0 = add i64 %i, 0
  %p0 = getelementptr float, ptr %a, i64 %j0
  %q0 = getelementptr float, ptr %b, i64 %j0
  %x0 = load float, ptr %p0, align 4
  %y0 = load float, ptr %q0, align 4
  %t0 = fadd fast float %s0, %x0
  %n0 = fadd fast float %t0, %y0
  %j1 = add i64 %i, 32
  %p1 = getelementptr float, ptr %a, i64 %j1
  %q1 = getelementptr float, ptr %b, i64 %j1
  %x1 = load float, ptr %p1, align 4
  %y1 = load float, ptr %q1, align 4
  %t1 = fadd fast float %s1, %x1
  %n1 = fadd fast float %t1, %y1
  %j2 = add i64 %i, 64
  %p2 = getelementptr float, ptr %a, i64 %j2
  %q2 = getelementptr float, ptr %b, i64 %j2
  %x2 = load float, ptr %p2, align 4
  %y2 = load float, ptr %q2, align 4
  %t2 = fadd fast float %s2, %x2
  %n2 = fadd fast float %t2, %y2
  %j3 = add i64 %i, 96
  %p3 = getelementptr float, ptr %a, i64 %j3
  %q3 = getelementptr float, ptr %b, i64 %j3
  %x3 = load float, ptr %p3, align 4
  %y3 = load float, ptr %q3, align 4
  %t3 = fadd fast float %s3, %x3
  %n3 = fadd fast float %t3, %y3
  %j4 = add i64 %i, 128
  %p4 = getelementptr float, ptr %a, i64 %j4
  %q4 = getelementptr float, ptr %b, i64 %j4
  %x4 = load float, ptr %p4, align 4
  %y4 = load float, ptr %q4, align 4
  %t4 = fadd fast float %s4, %x4
  %n4 = fadd fast float %t4, %y4
  %j5 = add i64 %i, 160
  %p5 = getelementptr float, ptr %a, i64 %j5
  %q5 = getelementptr float, ptr %b, i64 %j5
  %x5 = load float, ptr %p5, align 4
  %y5 = load float, ptr %q5, align 4
  %t5 = fadd fast float %s5, %x5
  %n5 = fadd fast float %t5, %y5
  %j6 = add i64 %i, 192
  %p6 = getelementptr float, ptr %a, i64 %j6
  %q6 = getelementptr float, ptr %b, i64 %j6
  %x6 = load float, ptr %p6, align 4
  %y6 = load float, ptr %q6, align 4
  %t6 = fadd fast float %s6, %x6
  %n6 = fadd fast float %t6, %y6
  %j7 = add i64 %i, 224
  %p7 = getelementptr float, ptr %a, i64 %j7
  %q7 = getelementptr float, ptr %b, i64 %j7
  %x7 = load float, ptr %p7, align 4
  %y7 = load float, ptr %q7, align 4
  %t7 = fadd fast float %s7, %x7
  %n7 = fadd fast float %t7, %y7
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
  store float %r0, ptr %o0, align 4
  %o1 = getelementptr float, ptr %out, i64 1
  store float %r1, ptr %o1, align 4
  %o2 = getelementptr float, ptr %out, i64 2
  store float %r2, ptr %o2, align 4
  %o3 = getelementptr float, ptr %out, i64 3
  store float %r3, ptr %o3, align 4
  %o4 = getelementptr float, ptr %out, i64 4
  store float %r4, ptr %o4, align 4
  %o5 = getelementptr float, ptr %out, i64 5
  store float %r5, ptr %o5, align 4
  %o6 = getelementptr float, ptr %out, i64 6
  store float %r6, ptr %o6, align 4
  %o7 = getelementptr float, ptr %out, i64 7
  store float %r7, ptr %o7, align 4
  ret void
}

attributes #0 = { vscale_range(2,1024) }
