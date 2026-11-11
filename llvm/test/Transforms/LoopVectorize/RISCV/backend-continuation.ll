; REQUIRES: asserts
; RUN: %python %S/Inputs/backend-contract.py continuation opt %s %t
; VF1 still receives SLP from the configured native continuation.
    define void @f(ptr noalias %a, ptr noalias %b, i64 %n) vscale_range(2,2) {
    entry: br label %loop
    loop:
      %i = phi i64 [0, %entry], [%next, %loop]
      %a0 = getelementptr float, ptr %a, i64 %i
      %a1 = getelementptr float, ptr %a0, i64 1
      %a2 = getelementptr float, ptr %a0, i64 2
      %a3 = getelementptr float, ptr %a0, i64 3
      %b0 = getelementptr float, ptr %b, i64 %i
      %b1 = getelementptr float, ptr %b0, i64 1
      %b2 = getelementptr float, ptr %b0, i64 2
      %b3 = getelementptr float, ptr %b0, i64 3
      %x0 = load float, ptr %a0
      %x1 = load float, ptr %a1
      %x2 = load float, ptr %a2
      %x3 = load float, ptr %a3
      %y0 = fadd float %x0, 1.0
      %y1 = fadd float %x1, 1.0
      %y2 = fadd float %x2, 1.0
      %y3 = fadd float %x3, 1.0
      store float %y0, ptr %b0
      store float %y1, ptr %b1
      store float %y2, ptr %b2
      store float %y3, ptr %b3
      %next = add nuw i64 %i, 4
      %done = icmp eq i64 %next, %n
      br i1 %done, label %exit, label %loop
    exit: ret void
    }
