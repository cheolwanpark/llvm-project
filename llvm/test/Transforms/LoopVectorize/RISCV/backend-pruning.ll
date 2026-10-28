; REQUIRES: asserts
; RUN: %python %S/Inputs/check-backend-pruning.py opt %s %t %S/backend-feedback-spills.ll %S/backend-ablation.ll
;
; A four-byte dot product with a known trip count. Unrolling is deliberately
; enabled: a large fixed VF becomes straight-line code in the probe suffix.
; Its tuned TTI lower bound already loses to scalar, so no probe is required.
define i32 @dot4(ptr noalias %a, ptr noalias %b) vscale_range(2,2) {
entry:
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %loop]
  %sum = phi i32 [0, %entry], [%s3, %loop]
  %offset = shl i64 %iv, 2
  %a0 = getelementptr i8, ptr %a, i64 %offset
  %b0 = getelementptr i8, ptr %b, i64 %offset
  %a1 = getelementptr i8, ptr %a0, i64 1
  %b1 = getelementptr i8, ptr %b0, i64 1
  %a2 = getelementptr i8, ptr %a0, i64 2
  %b2 = getelementptr i8, ptr %b0, i64 2
  %a3 = getelementptr i8, ptr %a0, i64 3
  %b3 = getelementptr i8, ptr %b0, i64 3
  %x0 = load i8, ptr %a0
  %y0 = load i8, ptr %b0
  %x1 = load i8, ptr %a1
  %y1 = load i8, ptr %b1
  %x2 = load i8, ptr %a2
  %y2 = load i8, ptr %b2
  %x3 = load i8, ptr %a3
  %y3 = load i8, ptr %b3
  %xx0 = zext i8 %x0 to i32
  %yy0 = zext i8 %y0 to i32
  %xx1 = zext i8 %x1 to i32
  %yy1 = zext i8 %y1 to i32
  %xx2 = zext i8 %x2 to i32
  %yy2 = zext i8 %y2 to i32
  %xx3 = zext i8 %x3 to i32
  %yy3 = zext i8 %y3 to i32
  %m0 = mul i32 %xx0, %yy0
  %m1 = mul i32 %xx1, %yy1
  %m2 = mul i32 %xx2, %yy2
  %m3 = mul i32 %xx3, %yy3
  %s0 = add i32 %sum, %m0
  %s1 = add i32 %s0, %m1
  %s2 = add i32 %s1, %m2
  %s3 = add i32 %s2, %m3
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, 128
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %s3
}
define void @gate(ptr noalias %a, ptr noalias %b, ptr noalias %c, ptr noalias %d, ptr noalias %out) vscale_range(2,2) {
entry:
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %loop]
  %pa = getelementptr double, ptr %a, i64 %iv
  %pb = getelementptr double, ptr %b, i64 %iv
  %pc = getelementptr double, ptr %c, i64 %iv
  %pd = getelementptr double, ptr %d, i64 %iv
  %po = getelementptr double, ptr %out, i64 %iv
  %a0 = load double, ptr %pa
  %b0 = load double, ptr %pb
  %c0 = load double, ptr %pc
  %d0 = load double, ptr %pd
  %x = fadd double %a0, %b0
  %y = fadd double %c0, %d0
  %z = fmul double %x, %y
  store double %z, ptr %po
  %next = add nuw i64 %iv, 1
  %cmp = icmp eq i64 %next, 24
  br i1 %cmp, label %exit, label %loop
exit:
  ret void
}
