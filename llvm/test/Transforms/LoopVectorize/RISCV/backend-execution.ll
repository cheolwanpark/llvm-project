; REQUIRES: asserts
; RUN: %python %S/Inputs/backend-contract.py execution opt %s %t
;
; Low-pressure candidates are observed. Strict cost lower-bound pruning still
; avoids backend execution for dominated candidates.
define void @gate(ptr noalias %a, ptr noalias %b) vscale_range(2,2) {
entry: br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %loop]
  %j = add i64 %i, 1024
  %k = add i64 %i, 2048
  %p = getelementptr i64, ptr %a, i64 %i
  %q = getelementptr i64, ptr %a, i64 %j
  %r = getelementptr i64, ptr %a, i64 %k
  %x = load i64, ptr %p
  %y = load i64, ptr %q
  %z = load i64, ptr %r
  %xy = mul i64 %x, %y
  %yz = mul i64 %y, %z
  %out0 = getelementptr i64, ptr %b, i64 %i
  %out1 = getelementptr i64, ptr %b, i64 %j
  store i64 %xy, ptr %out0
  store i64 %yz, ptr %out1
  %next = add nuw i64 %i, 1
  %done = icmp eq i64 %next, 18
  br i1 %done, label %exit, label %loop
exit: ret void
}
