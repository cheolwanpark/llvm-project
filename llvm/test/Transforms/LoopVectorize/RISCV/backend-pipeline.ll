; REQUIRES: asserts
; RUN: %python %S/Inputs/backend-contract.py pipeline opt %s %t
;
; One ordinary map supplies scalar and vector bodies. Pressure and allocator
; failures are separate inputs in the driver, not opcode/cost snapshots.
define void @map(ptr noalias %a, ptr noalias %b, i64 %n) vscale_range(2,2) {
entry: br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %p = getelementptr i32, ptr %a, i64 %i
  %q = getelementptr i32, ptr %b, i64 %i
  %v = load i32, ptr %p, align 4
  %r = add i32 %v, 7
  store i32 %r, ptr %q, align 4
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit: ret void
}
