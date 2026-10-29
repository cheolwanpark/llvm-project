; RUN: %python %S/Inputs/check-backend-candidate-pruning.py opt %S %t
; Gate-skip s1/s2/s4 can eliminate the required s8 probe before dispatch.
define void @gate(ptr noalias %a, ptr noalias %b, ptr noalias %o, i64 %n) vscale_range(2,2) {
entry: br label %loop
loop:
 %i = phi i64 [0,%entry],[%next,%loop]
 %j0 = add i64 %i, 0
 %p0 = getelementptr i64, ptr %a, i64 %j0
 %x0 = load i64, ptr %p0
 %j1 = add i64 %i, 1024
 %p1 = getelementptr i64, ptr %a, i64 %j1
 %x1 = load i64, ptr %p1
 %j2 = add i64 %i, 2048
 %p2 = getelementptr i64, ptr %a, i64 %j2
 %x2 = load i64, ptr %p2
 %r0 = mul i64 %x0, %x1
 %r1 = mul i64 %x1, %x2
 %q0 = getelementptr i64, ptr %o, i64 %j0
 store i64 %r0, ptr %q0
 %q1 = getelementptr i64, ptr %o, i64 %j1
 store i64 %r1, ptr %q1
 %next = add nuw i64 %i, 1
 %done = icmp eq i64 %next, 6
 br i1 %done, label %exit, label %loop
exit: ret void
}
