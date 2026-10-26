; Real register pressure exercises the spill observer on a materialized clone.
; RUN: rm -f %t.jsonl
; RUN: opt -codegen-opt-level=2 -mtriple=riscv64 -mcpu=generic-rv64 -mattr=+v -scalable-vectorization=always -force-vector-interleave=1 -riscv-v-register-bit-width-lmul=8 -enable-epilogue-vectorization=false -disable-loop-unrolling -passes=loop-vectorize -enable-vplan-backend-cost-model -vplan-backend-feedback-force-all -vplan-backend-feedback-output=%t.jsonl -verify-machineinstrs %s -disable-output
; RUN: %python %S/Inputs/check-real-vector-spills.py %t.jsonl

define void @pressure(ptr noalias %a, ptr noalias %out, i64 %n) vscale_range(2,2) {
entry:
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %loop]
  %s0 = phi double [0.0, %entry], [%r0, %loop]
  %s1 = phi double [0.0, %entry], [%r1, %loop]
  %s2 = phi double [0.0, %entry], [%r2, %loop]
  %s3 = phi double [0.0, %entry], [%r3, %loop]
  %s4 = phi double [0.0, %entry], [%r4, %loop]
  %s5 = phi double [0.0, %entry], [%r5, %loop]
  %s6 = phi double [0.0, %entry], [%r6, %loop]
  %s7 = phi double [0.0, %entry], [%r7, %loop]
  %s8 = phi double [0.0, %entry], [%r8, %loop]
  %s9 = phi double [0.0, %entry], [%r9, %loop]
  %s10 = phi double [0.0, %entry], [%r10, %loop]
  %s11 = phi double [0.0, %entry], [%r11, %loop]
  %j0 = add i64 %iv, 0
  %p0 = getelementptr double, ptr %a, i64 %j0
  %v0 = load double, ptr %p0, align 8
  %r0 = fadd fast double %s0, %v0
  %j1 = add i64 %iv, 1024
  %p1 = getelementptr double, ptr %a, i64 %j1
  %v1 = load double, ptr %p1, align 8
  %r1 = fadd fast double %s1, %v1
  %j2 = add i64 %iv, 2048
  %p2 = getelementptr double, ptr %a, i64 %j2
  %v2 = load double, ptr %p2, align 8
  %r2 = fadd fast double %s2, %v2
  %j3 = add i64 %iv, 3072
  %p3 = getelementptr double, ptr %a, i64 %j3
  %v3 = load double, ptr %p3, align 8
  %r3 = fadd fast double %s3, %v3
  %j4 = add i64 %iv, 4096
  %p4 = getelementptr double, ptr %a, i64 %j4
  %v4 = load double, ptr %p4, align 8
  %r4 = fadd fast double %s4, %v4
  %j5 = add i64 %iv, 5120
  %p5 = getelementptr double, ptr %a, i64 %j5
  %v5 = load double, ptr %p5, align 8
  %r5 = fadd fast double %s5, %v5
  %j6 = add i64 %iv, 6144
  %p6 = getelementptr double, ptr %a, i64 %j6
  %v6 = load double, ptr %p6, align 8
  %r6 = fadd fast double %s6, %v6
  %j7 = add i64 %iv, 7168
  %p7 = getelementptr double, ptr %a, i64 %j7
  %v7 = load double, ptr %p7, align 8
  %r7 = fadd fast double %s7, %v7
  %j8 = add i64 %iv, 8192
  %p8 = getelementptr double, ptr %a, i64 %j8
  %v8 = load double, ptr %p8, align 8
  %r8 = fadd fast double %s8, %v8
  %j9 = add i64 %iv, 9216
  %p9 = getelementptr double, ptr %a, i64 %j9
  %v9 = load double, ptr %p9, align 8
  %r9 = fadd fast double %s9, %v9
  %j10 = add i64 %iv, 10240
  %p10 = getelementptr double, ptr %a, i64 %j10
  %v10 = load double, ptr %p10, align 8
  %r10 = fadd fast double %s10, %v10
  %j11 = add i64 %iv, 11264
  %p11 = getelementptr double, ptr %a, i64 %j11
  %v11 = load double, ptr %p11, align 8
  %r11 = fadd fast double %s11, %v11
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  %dst0 = getelementptr double, ptr %out, i64 0
  store double %r0, ptr %dst0, align 8
  %dst1 = getelementptr double, ptr %out, i64 1
  store double %r1, ptr %dst1, align 8
  %dst2 = getelementptr double, ptr %out, i64 2
  store double %r2, ptr %dst2, align 8
  %dst3 = getelementptr double, ptr %out, i64 3
  store double %r3, ptr %dst3, align 8
  %dst4 = getelementptr double, ptr %out, i64 4
  store double %r4, ptr %dst4, align 8
  %dst5 = getelementptr double, ptr %out, i64 5
  store double %r5, ptr %dst5, align 8
  %dst6 = getelementptr double, ptr %out, i64 6
  store double %r6, ptr %dst6, align 8
  %dst7 = getelementptr double, ptr %out, i64 7
  store double %r7, ptr %dst7, align 8
  %dst8 = getelementptr double, ptr %out, i64 8
  store double %r8, ptr %dst8, align 8
  %dst9 = getelementptr double, ptr %out, i64 9
  store double %r9, ptr %dst9, align 8
  %dst10 = getelementptr double, ptr %out, i64 10
  store double %r10, ptr %dst10, align 8
  %dst11 = getelementptr double, ptr %out, i64 11
  store double %r11, ptr %dst11, align 8
  ret void
}
