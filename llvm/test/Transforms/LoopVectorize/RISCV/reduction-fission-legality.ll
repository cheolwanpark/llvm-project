; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v \
; RUN:   -tail-folding-policy=must-fold-tail \
; RUN:   -enable-vplan-reduction-fission -enable-scalar-reduction-fission=false \
; RUN:   -vplan-reduction-fission-min-chain-depth=4 -S %s \
; RUN:   | FileCheck %s --implicit-check-not=fission.scratch
;
; A vectorizable fused loop is not necessarily legal at the proposed stage VF.
; CHECK-LABEL: define void @pressure_candidate(
; CHECK: ret void
; CHECK-LABEL: define void @scipy_fma8_fixed(
; CHECK: call fast <vscale x 2 x double> @vecfoo
; CHECK: ret void

define void @pressure_candidate(ptr noalias %a, ptr noalias writeonly %out) {
entry:
  br label %loop

loop:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %loop ]
  %r0 = phi i32 [ 0, %entry ], [ %n0, %loop ]
  %r1 = phi i32 [ 0, %entry ], [ %n1, %loop ]
  %r2 = phi i32 [ 0, %entry ], [ %n2, %loop ]
  %r3 = phi i32 [ 0, %entry ], [ %n3, %loop ]
  %r4 = phi i32 [ 0, %entry ], [ %n4, %loop ]
  %r5 = phi i32 [ 0, %entry ], [ %n5, %loop ]
  %r6 = phi i32 [ 0, %entry ], [ %n6, %loop ]
  %r7 = phi i32 [ 0, %entry ], [ %n7, %loop ]
  %r8 = phi i32 [ 0, %entry ], [ %n8, %loop ]
  %r9 = phi i32 [ 0, %entry ], [ %n9, %loop ]
  %r10 = phi i32 [ 0, %entry ], [ %n10, %loop ]
  %r11 = phi i32 [ 0, %entry ], [ %n11, %loop ]
  %r12 = phi i32 [ 0, %entry ], [ %n12, %loop ]
  %r13 = phi i32 [ 0, %entry ], [ %n13, %loop ]
  %r14 = phi i32 [ 0, %entry ], [ %n14, %loop ]
  %r15 = phi i32 [ 0, %entry ], [ %n15, %loop ]
  %r16 = phi i32 [ 0, %entry ], [ %n16, %loop ]
  %p = getelementptr inbounds i32, ptr %a, i64 %iv
  store i32 1, ptr %p, align 4
  %x = load i32, ptr %p, align 4
  %c1 = mul i32 %x, 3
  %c2 = add i32 %c1, 7
  %c3 = xor i32 %c2, 11
  %value = mul i32 %c3, 13
  %n0 = add i32 %r0, %value
  %n1 = add i32 %r1, %value
  %n2 = add i32 %r2, %value
  %n3 = add i32 %r3, %value
  %n4 = add i32 %r4, %value
  %n5 = add i32 %r5, %value
  %n6 = add i32 %r6, %value
  %n7 = add i32 %r7, %value
  %n8 = add i32 %r8, %value
  %n9 = add i32 %r9, %value
  %n10 = add i32 %r10, %value
  %n11 = add i32 %r11, %value
  %n12 = add i32 %r12, %value
  %n13 = add i32 %r13, %value
  %n14 = add i32 %r14, %value
  %n15 = add i32 %r15, %value
  %n16 = add i32 %r16, %value
  %iv.next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %iv.next, 64
  br i1 %done, label %exit, label %loop

exit:
  store i32 %n0, ptr %out, align 4
  %o1 = getelementptr inbounds i32, ptr %out, i64 1
  store i32 %n1, ptr %o1, align 4
  %o2 = getelementptr inbounds i32, ptr %out, i64 2
  store i32 %n2, ptr %o2, align 4
  %o3 = getelementptr inbounds i32, ptr %out, i64 3
  store i32 %n3, ptr %o3, align 4
  %o4 = getelementptr inbounds i32, ptr %out, i64 4
  store i32 %n4, ptr %o4, align 4
  %o5 = getelementptr inbounds i32, ptr %out, i64 5
  store i32 %n5, ptr %o5, align 4
  %o6 = getelementptr inbounds i32, ptr %out, i64 6
  store i32 %n6, ptr %o6, align 4
  %o7 = getelementptr inbounds i32, ptr %out, i64 7
  store i32 %n7, ptr %o7, align 4
  %o8 = getelementptr inbounds i32, ptr %out, i64 8
  store i32 %n8, ptr %o8, align 4
  %o9 = getelementptr inbounds i32, ptr %out, i64 9
  store i32 %n9, ptr %o9, align 4
  %o10 = getelementptr inbounds i32, ptr %out, i64 10
  store i32 %n10, ptr %o10, align 4
  %o11 = getelementptr inbounds i32, ptr %out, i64 11
  store i32 %n11, ptr %o11, align 4
  %o12 = getelementptr inbounds i32, ptr %out, i64 12
  store i32 %n12, ptr %o12, align 4
  %o13 = getelementptr inbounds i32, ptr %out, i64 13
  store i32 %n13, ptr %o13, align 4
  %o14 = getelementptr inbounds i32, ptr %out, i64 14
  store i32 %n14, ptr %o14, align 4
  %o15 = getelementptr inbounds i32, ptr %out, i64 15
  store i32 %n15, ptr %o15, align 4
  %o16 = getelementptr inbounds i32, ptr %out, i64 16
  store i32 %n16, ptr %o16, align 4
  ret void
}

define void @scipy_fma8_fixed(ptr noalias readonly %x, ptr noalias readonly %y,
                              double %frequency, ptr noalias writeonly %out) {
entry:
  br label %loop

loop:
  %iv = phi i64 [ 0, %entry ], [ %iv.next, %loop ]
  %xc = phi double [ 0.0, %entry ], [ %xc.next, %loop ]
  %xs = phi double [ 0.0, %entry ], [ %xs.next, %loop ]
  %cc = phi double [ 0.0, %entry ], [ %cc.next, %loop ]
  %ss = phi double [ 0.0, %entry ], [ %ss.next, %loop ]
  %cs = phi double [ 0.0, %entry ], [ %cs.next, %loop ]
  %xp = getelementptr inbounds double, ptr %x, i64 %iv
  %xv = load double, ptr %xp, align 8
  %z.base = fmul fast double %xv, %frequency
  %z = call fast double @foo(double %z.base) #1
  %c0 = fadd fast double %z, 0.25
  %s1 = call fast double @llvm.fma.f64(double %z, double 1.0001, double 0.0003)
  %c1 = call fast double @llvm.fma.f64(double %c0, double 0.9999, double -0.0002)
  %s2 = call fast double @llvm.fma.f64(double %s1, double 1.0001, double 0.0003)
  %c2 = call fast double @llvm.fma.f64(double %c1, double 0.9999, double -0.0002)
  %s3 = call fast double @llvm.fma.f64(double %s2, double 1.0001, double 0.0003)
  %c3 = call fast double @llvm.fma.f64(double %c2, double 0.9999, double -0.0002)
  %s4 = call fast double @llvm.fma.f64(double %s3, double 1.0001, double 0.0003)
  %c4 = call fast double @llvm.fma.f64(double %c3, double 0.9999, double -0.0002)
  %s5 = call fast double @llvm.fma.f64(double %s4, double 1.0001, double 0.0003)
  %c5 = call fast double @llvm.fma.f64(double %c4, double 0.9999, double -0.0002)
  %s6 = call fast double @llvm.fma.f64(double %s5, double 1.0001, double 0.0003)
  %c6 = call fast double @llvm.fma.f64(double %c5, double 0.9999, double -0.0002)
  %s7 = call fast double @llvm.fma.f64(double %s6, double 1.0001, double 0.0003)
  %c7 = call fast double @llvm.fma.f64(double %c6, double 0.9999, double -0.0002)
  %s8 = call fast double @llvm.fma.f64(double %s7, double 1.0001, double 0.0003)
  %c8 = call fast double @llvm.fma.f64(double %c7, double 0.9999, double -0.0002)
  %yp = getelementptr inbounds double, ptr %y, i64 %iv
  %yv = load double, ptr %yp, align 8
  %xc.term = fmul fast double %yv, %c8
  %xc.next = fadd fast double %xc, %xc.term
  %xs.term = fmul fast double %yv, %s8
  %xs.next = fadd fast double %xs, %xs.term
  %cc.term = fmul fast double %c8, %c8
  %cc.next = fadd fast double %cc, %cc.term
  %ss.term = fmul fast double %s8, %s8
  %ss.next = fadd fast double %ss, %ss.term
  %cs.term = fmul fast double %c8, %s8
  %cs.next = fadd fast double %cs, %cs.term
  %iv.next = add nuw i64 %iv, 1
  %done = icmp eq i64 %iv.next, 1024
  br i1 %done, label %exit, label %loop

exit:
  store double %xc.next, ptr %out, align 8
  %o1 = getelementptr inbounds double, ptr %out, i64 1
  store double %xs.next, ptr %o1, align 8
  %o2 = getelementptr inbounds double, ptr %out, i64 2
  store double %cc.next, ptr %o2, align 8
  %o3 = getelementptr inbounds double, ptr %out, i64 3
  store double %ss.next, ptr %o3, align 8
  %o4 = getelementptr inbounds double, ptr %out, i64 4
  store double %cs.next, ptr %o4, align 8
  ret void
}

declare double @llvm.fma.f64(double, double, double)

declare double @foo(double) nounwind willreturn speculatable memory(none)
declare <vscale x 2 x double> @vecfoo(<vscale x 2 x double>) nounwind willreturn memory(none)
attributes #1 = { "vector-function-abi-variant"="_ZGVrNxv_foo(vecfoo)" }
